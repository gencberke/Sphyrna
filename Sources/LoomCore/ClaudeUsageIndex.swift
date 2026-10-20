import CryptoKit
import Darwin
import Dispatch
import Foundation
import SQLite3

/// Incremental, bounded, deduplicated usage aggregates built from the transcripts
/// Claude Code already writes (`<config>/projects/**/<session>.jsonl`). No process
/// is spawned, nothing touches the network and nothing polls: callers decide when
/// to `refresh` (a Stop hook's `transcript_path`, Settings opening, app activation).
///
/// The index is a disposable SQLite file. Transcripts are append-only in practice,
/// so each file keeps a byte offset and a 64-byte guard hash of the bytes just
/// before it; growth reads only the new bytes, and a shrink, a new inode or a
/// guard mismatch drops that file's rows and parses it again. A partial last line
/// is never consumed. Messages are keyed by `message.id` (Claude writes one
/// assistant message once per content block, and a sidechain replay reuses the id
/// under a new request id), keeping the larger total and preferring non-sidechain
/// rows. Rows are history: a transcript Claude deletes later never lowers totals.
/// Prices are applied at query time, so a price-table update re-prices history.
public actor ClaudeUsageIndex {
    static let schemaVersion: Int32 = 2
    static let applicationID: Int32 = 0x4C55_5347 // "LUSG"
    static let bucketMs: Int64 = 900_000 // 15 minutes: every real UTC offset is a multiple
    static let blockSeconds: Int64 = 5 * 3_600
    static let activityHorizonSeconds: TimeInterval = 7 * 86_400

    private let queue = DispatchSerialQueue(label: "loom.usage.index", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let databaseURL: URL
    private let profile: ClaudeProfileLayout
    private let coldStartWindow: TimeInterval
    private let clock: @Sendable () -> Date
    private let chunkBytes: Int
    private let maximumLineBytes: Int

    private var database: UsageDatabase?
    private var lastScanReport: UsageScanReport?
    private var lastScanDate: Date?
    private var malformedLinesTotal = 0
    private var symbols: [String: Int64] = [:]
    private var forgotten: ForgottenSessions?
    /// The provider ids of the side chats (V22), lower case: a fork copies the parent's messages under their own ids, so a record
    /// read from a side chat's file must never take a message another session holds (`insert`, `UsageDatabase.upsert`).
    private var sideChatSessions: Set<String> = []
    private var sideChatSource: (@Sendable () async -> Set<String>)?

    /// - Parameters:
    ///   - databaseURL: `usage-index.sqlite3` in the data root.
    ///   - profile: which Claude profile's `projects/` to read.
    ///   - coldStartWindow: files not indexed yet and older than this are skipped (default 90 days).
    ///   - sideChats: the provider ids of the side chats (V22), asked before every refresh; see `setSideChatSource`.
    public init(
        databaseURL: URL, profile: ClaudeProfileLayout, coldStartWindow: TimeInterval = 90 * 86_400,
        clock: @escaping @Sendable () -> Date = { Date() }, sideChats: (@Sendable () async -> Set<String>)? = nil
    ) {
        self.init(databaseURL: databaseURL, profile: profile, coldStartWindow: coldStartWindow, clock: clock,
                  chunkBytes: 4 * 1024 * 1024, maximumLineBytes: ClaudeUsageParser.defaultMaximumLineBytes,
                  sideChats: sideChats)
    }

    init(
        databaseURL: URL, profile: ClaudeProfileLayout, coldStartWindow: TimeInterval = 90 * 86_400,
        clock: @escaping @Sendable () -> Date = { Date() }, chunkBytes: Int, maximumLineBytes: Int,
        sideChats: (@Sendable () async -> Set<String>)? = nil
    ) {
        sideChatSource = sideChats
        self.databaseURL = databaseURL
        self.profile = profile
        self.coldStartWindow = coldStartWindow
        self.clock = clock
        self.chunkBytes = max(chunkBytes, 1_024)
        self.maximumLineBytes = max(maximumLineBytes, 1_024)
    }

    // MARK: side chats

    /// The side chats' provider ids, lower case or not. Replaces the earlier set; read before every refresh when a source is set.
    public func setSideChatSessions(_ ids: Set<String>) {
        sideChatSessions = Set(ids.map { $0.lowercased() })
    }

    /// Where the ids come from (the catalog): asked once at the start of every refresh, so a side chat made since is known
    /// before its file is read.
    public func setSideChatSource(_ source: @escaping @Sendable () async -> Set<String>) {
        sideChatSource = source
    }

    // MARK: refresh

    /// Brings the index up to date. `paths == nil` visits every transcript under the
    /// profile; explicit paths (a hook's `transcript_path`) tail just those files.
    /// Cancellable between files and between chunks; committed progress is kept.
    @discardableResult
    public func refresh(paths: [URL]? = nil) async throws -> UsageScanReport {
        let report: UsageScanReport
        do {
            report = try await refreshOnce(paths: paths)
        } catch let error as ClaudeUsageIndexError where error.isCorruption {
            LoomLog.error(.usage, "The usage index was damaged and is being rebuilt")
            discardDatabase()
            report = try await refreshOnce(paths: paths)
        }
        record(report)
        return report
    }

    private func record(_ report: UsageScanReport) {
        lastScanReport = report
        lastScanDate = clock()
        malformedLinesTotal += report.linesMalformed
        if report.linesMalformed > 0 {
            LoomLog.notice(.usage, "Usage scan met \(report.linesMalformed) line(s) it could not understand")
        } else {
            LoomLog.debug(.usage, "Usage scan: \(report.filesParsed) file(s) parsed, \(report.recordsAccepted) record(s)")
        }
    }

    /// What the scans report about themselves, for "N usage lines not understood" and the export.
    /// The lines are counted when a scan reads them, so the total is per app run: a line read
    /// by an earlier run is not read, or counted, again.
    public func diagnostics() -> UsageDiagnostics {
        UsageDiagnostics(lastScan: lastScanReport, lastScanAt: lastScanDate, linesNotUnderstood: malformedLinesTotal)
    }

    private func refreshOnce(paths: [URL]?) async throws -> UsageScanReport {
        if let sideChatSource { setSideChatSessions(await sideChatSource()) }
        let database = try openDatabase()
        var report = UsageScanReport()
        let parser = ClaudeUsageParser(maximumLineBytes: maximumLineBytes)
        let candidates: [UsageTranscriptFile]
        let explicit: Bool
        if let paths {
            candidates = paths.compactMap { UsageTranscriptWalker.candidate(at: $0, profile: profile) }
            explicit = true
        } else {
            candidates = UsageTranscriptWalker.candidates(profile: profile)
            explicit = false
        }
        let coldCutoffNs = Int64((clock().timeIntervalSince1970 - coldStartWindow) * 1_000_000_000)
        for candidate in candidates {
            try Task.checkCancellation()
            report.filesSeen += 1
            try scan(candidate, explicit: explicit, coldCutoffNs: coldCutoffNs, parser: parser, database: database, report: &report)
            await Task.yield()
        }
        return report
    }

    private func scan(
        _ candidate: UsageTranscriptFile, explicit: Bool, coldCutoffNs: Int64, parser: ClaudeUsageParser,
        database: UsageDatabase, report: inout UsageScanReport
    ) throws {
        let state = try database.file(path: candidate.path)
        if let state, state.dev == candidate.dev, state.ino == candidate.ino,
           state.size == candidate.size, state.mtimeNs == candidate.mtimeNs {
            report.filesUnchanged += 1
            return
        }
        if state == nil, !explicit, candidate.mtimeNs < coldCutoffNs {
            report.filesSkippedOld += 1
            return
        }
        let descriptor = open(candidate.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return } // vanished or unreadable since the walk
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return }
        let observed = UsageTranscriptFile(path: candidate.path, session: candidate.session, info: info)

        var startOffset: Int64 = 0
        var reset = false
        if let state {
            if state.dev != observed.dev || state.ino != observed.ino
                || observed.size < state.offset || observed.size < state.size
                || !Self.guardMatches(descriptor, offset: state.offset, length: state.guardLength, hash: state.guardHash) {
                reset = true
            } else {
                startOffset = state.offset
            }
        }
        let fileID: Int64
        if let state, !reset {
            fileID = state.id
        } else {
            fileID = try database.transaction {
                if let state { try database.deleteMessages(fileID: state.id) }
                return try database.saveFile(path: observed.path, session: observed.session, dev: observed.dev, ino: observed.ino)
            }
            if state != nil { report.filesReset += 1 }
        }
        report.filesParsed += 1
        let committed = try readLines(
            descriptor: descriptor, fileID: fileID, from: startOffset, to: observed.size,
            fallbackSession: observed.session, parser: parser, database: database, report: &report)
        if committed >= 0 {
            try database.updateObserved(fileID: fileID, size: observed.size, mtimeNs: observed.mtimeNs)
        }
    }

    /// Reads whole lines in `[from, to)` in chunks, one transaction per chunk. Returns the
    /// offset after the last whole line. A partial tail (no newline yet) is never consumed;
    /// a line over the cap is skipped once its newline arrives.
    private func readLines(
        descriptor: Int32, fileID: Int64, from: Int64, to end: Int64, fallbackSession: String,
        parser: ClaudeUsageParser, database: UsageDatabase, report: inout UsageScanReport
    ) throws -> Int64 {
        var capacity = chunkBytes
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var committed = from   // file position of buffer[0] while not discarding
        var filled = 0         // carried bytes at buffer[0..<filled]
        var readPos = from
        var discarding = false // inside a line longer than the cap, looking for its newline
        let forgottenSessions = try forgottenSet(database)
        let fromSideChat = sideChatSessions.contains(fallbackSession.lowercased())

        while readPos < end {
            try Task.checkCancellation()
            if !discarding && filled == capacity {
                if capacity < parser.maximumLineBytes + 1 {
                    let grown = min(capacity * 2, parser.maximumLineBytes + 1)
                    let replacement = UnsafeMutableRawPointer.allocate(byteCount: grown, alignment: 16)
                    replacement.copyMemory(from: buffer, byteCount: filled)
                    buffer.deallocate()
                    buffer = replacement
                    capacity = grown
                } else {
                    discarding = true
                    filled = 0
                }
                continue
            }
            let room = discarding ? capacity : capacity - filled
            let want = Int(min(Int64(room), end - readPos))
            let target = discarding ? buffer : buffer + filled
            let count = pread(descriptor, target, want, off_t(readPos))
            guard count > 0 else { break }
            report.bytesRead += Int64(count)
            let chunkStart = readPos
            readPos += Int64(count)
            if discarding {
                guard let newline = memchr(buffer, 0x0A, count) else { continue }
                let skipped = buffer.distance(to: newline) + 1
                committed = chunkStart + Int64(skipped)
                discarding = false
                report.linesMalformed += 1
                memmove(buffer, buffer + skipped, count - skipped)
                filled = count - skipped
            } else {
                filled += count
            }
            var cursor = 0
            try database.begin()
            do {
                while cursor < filled, let newline = memchr(buffer + cursor, 0x0A, filled - cursor) {
                    let length = (buffer + cursor).distance(to: newline)
                    switch parser.parse(UnsafeRawBufferPointer(start: buffer + cursor, count: length)) {
                    case let .record(record):
                        report.recordsAccepted += 1
                        try insert(record, fileID: fileID, fallbackSession: fallbackSession,
                                   forgotten: forgottenSessions, fromSideChat: fromSideChat, database: database)
                    case .ignored:
                        break
                    case .malformed:
                        report.linesMalformed += 1
                    }
                    cursor += length + 1
                }
                committed += Int64(cursor)
                let (guardLength, guardHash) = Self.guardBytes(descriptor, before: committed)
                try database.updateProgress(fileID: fileID, offset: committed, guardLength: guardLength, guardHash: guardHash)
                try database.commit()
            } catch {
                database.rollback()
                throw error
            }
            if cursor > 0 && cursor < filled { memmove(buffer, buffer + cursor, filled - cursor) }
            filled -= cursor
        }
        return committed
    }

    private func insert(
        _ record: ClaudeUsageRecord, fileID: Int64, fallbackSession: String, forgotten: ForgottenSessions,
        fromSideChat: Bool, database: UsageDatabase
    ) throws {
        let sessionText = record.sessionID ?? fallbackSession
        let session: Int64? = forgotten.contains(sessionText) ? nil : try symbol(sessionText, database)
        let model = try symbol(record.model, database)
        let key: String
        if let id = record.messageID { key = "m|" + id }
        else { key = "r|\(record.requestID ?? "")|\(sessionText)|\(record.timestampMs)" }
        let flags: Int64 = (record.sidechain ? 1 : 0) | (record.fast ? 2 : 0) | (record.usGeo ? 4 : 0)
            | (fromSideChat ? UsageDatabase.sideChatFlag : 0)
        try database.upsert(UsageRow(
            key: Self.hash(Array(key.utf8)), fileID: fileID, timestampMs: record.timestampMs, session: session,
            model: model, tokens: record.tokens, flags: flags, total: record.tokens.total + record.tokens.webSearches,
            legacyCost: record.legacyCostUSD))
    }

    // MARK: forget

    /// Detaches sessions from their messages (a deleted conversation): tokens and cost stay in
    /// the totals, the session link goes, and the session's transcript rows are forgotten so a
    /// later re-read of a surviving file does not link them again. Ids are matched without regard
    /// to case. Nothing of the id stays in the index file: its symbol and file rows are deleted
    /// (`secure_delete`), the re-link guard keeps only a SHA-256 digest, and the WAL is truncated.
    /// Returns messages unlinked.
    @discardableResult
    public func forget(sessionIDs: [String]) throws -> Int {
        do {
            return try forgetOnce(sessionIDs)
        } catch let error as ClaudeUsageIndexError where error.isCorruption {
            discardDatabase()
            return 0
        }
    }

    private func forgetOnce(_ sessionIDs: [String]) throws -> Int {
        let database = try openDatabase()
        guard !sessionIDs.isEmpty else { return 0 }
        let guardSet = try forgottenSet(database)
        let lowered = Set(sessionIDs.map { $0.lowercased() })
        let unlinked = try database.transaction { try database.forget(lowercasedSessions: lowered) }
        for id in lowered { guardSet.insert(id) }
        symbols = symbols.filter { !lowered.contains($0.key.lowercased()) }
        try database.checkpointTruncate()
        return unlinked
    }

    // MARK: snapshot

    public func snapshot(range: UsageRange, now: Date, timeZone: TimeZone) throws -> UsageSnapshot {
        try snapshot(range: range, now: now, timeZone: timeZone, includeActivityWindow: true)
    }

    /// The same numbers as `snapshot` without the activity window, which scans the last week of
    /// messages: for callers (the footer chip) that do not show it.
    public func summary(range: UsageRange, now: Date, timeZone: TimeZone) throws -> UsageSnapshot {
        try snapshot(range: range, now: now, timeZone: timeZone, includeActivityWindow: false)
    }

    private func snapshot(range: UsageRange, now: Date, timeZone: TimeZone, includeActivityWindow: Bool) throws -> UsageSnapshot {
        do {
            return try snapshotOnce(range: range, now: now, timeZone: timeZone, includeActivityWindow: includeActivityWindow)
        } catch let error as ClaudeUsageIndexError where error.isCorruption {
            discardDatabase()
            return try snapshotOnce(range: range, now: now, timeZone: timeZone, includeActivityWindow: includeActivityWindow)
        }
    }

    /// Token and message totals of `count` consecutive calendar hours or days, the last one
    /// containing `now`, from one grouped query. Each bucket equals `snapshot(range: .interval)` over
    /// its own interval; no sessions, models or costs are computed (the bar chart needs tokens).
    public func buckets(size: UsageBucketSize, count: Int, endingAt now: Date, timeZone: TimeZone) throws -> [UsageBucket] {
        do {
            return try bucketsOnce(size: size, count: count, now: now, timeZone: timeZone)
        } catch let error as ClaudeUsageIndexError where error.isCorruption {
            discardDatabase()
            return try bucketsOnce(size: size, count: count, now: now, timeZone: timeZone)
        }
    }

    /// Whether any message is indexed at all (an existence check, not a snapshot).
    public func hasUsage() throws -> Bool {
        do {
            return try openDatabase().hasMessages()
        } catch let error as ClaudeUsageIndexError where error.isCorruption {
            discardDatabase()
            return try openDatabase().hasMessages()
        }
    }

    /// The latest main-thread message of each given session, for the context ring: one indexed
    /// lookup per session in the index's own database, no transcript is opened and nothing is
    /// scanned. A session with no indexed main-thread message (or a forgotten one) is left out.
    /// Subagent (sidechain) messages never count: they run in their own context.
    public func latestMainMessages(sessions: [String]) throws -> [String: SessionContextSample] {
        do {
            return try latestMainMessagesOnce(sessions)
        } catch let error as ClaudeUsageIndexError where error.isCorruption {
            discardDatabase()
            return try latestMainMessagesOnce(sessions)
        }
    }

    private func latestMainMessagesOnce(_ sessions: [String]) throws -> [String: SessionContextSample] {
        let database = try openDatabase()
        var found: [String: SessionContextSample] = [:]
        for session in sessions where found[session] == nil {
            // Ids are written in lower case; a catalog id in another case still finds its rows.
            let candidates = session == session.lowercased() ? [session] : [session, session.lowercased()]
            for text in candidates {
                guard let symbol = try database.symbolID(text),
                      let row = try database.latestMainMessage(session: symbol) else { continue }
                found[session] = SessionContextSample(
                    model: try database.symbolText(row.model) ?? "",
                    timestamp: Date(timeIntervalSince1970: Double(row.timestampMs) / 1_000), tokens: row.tokens)
                break
            }
        }
        return found
    }

    /// The most sessions one `projectUsage` lookup reads (the rest are left out; the caller passes the
    /// sessions active in the range, newest first).
    public static let maxProjectUsageSessions = 500

    /// What the given sessions (a project's) used in `range`: one indexed seek per session in the
    /// index's own database, like `latestMainMessages`. No transcript is opened and nothing is scanned;
    /// at most `maxProjectUsageSessions` sessions are read. Sidechain (subagent) messages count: the
    /// project paid for them.
    public func projectUsage(sessions: [String], range: UsageRange, now: Date, timeZone: TimeZone) throws -> ProjectUsage {
        do {
            return try projectUsageOnce(sessions, range: range, now: now, timeZone: timeZone)
        } catch let error as ClaudeUsageIndexError where error.isCorruption {
            discardDatabase()
            return try projectUsageOnce(sessions, range: range, now: now, timeZone: timeZone)
        }
    }

    private func projectUsageOnce(_ sessions: [String], range: UsageRange, now: Date, timeZone: TimeZone) throws -> ProjectUsage {
        let database = try openDatabase()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let bounds = range.bounds(now: now, calendar: calendar)
        let lower = bounds.start.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) } ?? Int64.min
        let upper = bounds.end.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) } ?? Int64.max
        var total = Accumulator()
        var used = 0
        var seen: Set<Int64> = []
        var prices: [Int64: UsageModelPrice?] = [:]
        for session in sessions.prefix(Self.maxProjectUsageSessions) {
            // Ids are written in lower case; a catalog id in another case still finds its rows.
            let candidates = session == session.lowercased() ? [session] : [session, session.lowercased()]
            for text in candidates {
                guard let symbol = try database.symbolID(text) else { continue }
                guard seen.insert(symbol).inserted else { break }
                var found = false
                for group in try database.sessionAggregates(session: symbol, lower: lower, upper: upper) {
                    found = true
                    if prices[group.model] == nil {
                        prices[group.model] = .some(UsagePricing.price(forModel: try database.symbolText(group.model) ?? ""))
                    }
                    let cost = Self.cost(price: prices[group.model] ?? nil, tokens: group.tokens, flags: group.flags,
                                         legacy: group.hasLegacyCost ? group.legacyCost : nil)
                    total.add(tokens: group.tokens, cost: cost, messages: group.messages)
                }
                if found { used += 1 }
                break
            }
        }
        return ProjectUsage(
            tokens: total.tokens, estimatedCostUSD: total.hasUnknownCost ? nil : total.cost,
            messageCount: total.messages, sessionCount: used)
    }

    private func bucketsOnce(size: UsageBucketSize, count: Int, now: Date, timeZone: TimeZone) throws -> [UsageBucket] {
        let database = try openDatabase()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let edges = size.edges(count: count, endingAt: now, calendar: calendar)
        guard edges.count > 1 else { return [] }
        let milliseconds = edges.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) }
        var buckets = (0..<edges.count - 1).map {
            UsageBucket(start: edges[$0], end: edges[$0 + 1], tokens: UsageTokens(), messageCount: 0)
        }
        // Every real UTC offset is a multiple of 15 minutes, so a local hour or day starts on a
        // quarter-hour group; anything else is summed per bucket instead of guessed.
        if milliseconds.allSatisfy({ $0 % Self.bucketMs == 0 }) {
            var index = 0
            for group in try database.quarterTotals(lower: milliseconds[0], upper: milliseconds[milliseconds.count - 1]) {
                let at = group.bucket * Self.bucketMs
                while index + 1 < buckets.count, milliseconds[index + 1] <= at { index += 1 }
                buckets[index].tokens.add(group.tokens)
                buckets[index].messageCount += group.messages
            }
        } else {
            for index in buckets.indices {
                let total = try database.rangeTotals(lower: milliseconds[index], upper: milliseconds[index + 1])
                buckets[index].tokens = total.tokens
                buckets[index].messageCount = total.messages
            }
        }
        return buckets
    }

    private struct Accumulator {
        var tokens = UsageTokens()
        var cost = 0.0
        var hasUnknownCost = false
        var messages = 0

        mutating func add(tokens other: UsageTokens, cost: Double?, messages count: Int) {
            tokens.add(other)
            if let cost { self.cost += cost } else { hasUnknownCost = true }
            messages += count
        }
    }

    private struct DayAccumulator {
        var total = Accumulator()
        var models: [String: Accumulator] = [:]
        var sessions: Set<Int64> = []
    }

    /// Maps quarter-hour buckets to local days; exact because every real UTC offset and DST
    /// change falls on a quarter hour.
    private struct DayResolver {
        let calendar: Calendar
        var cache: [Int64: Date] = [:]

        mutating func day(ofBucket bucket: Int64) -> Date {
            if let cached = cache[bucket] { return cached }
            let start = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(bucket * ClaudeUsageIndex.bucketMs) / 1_000))
            cache[bucket] = start
            return start
        }
    }

    private static func cost(
        price: UsageModelPrice?, tokens: UsageTokens, flags: Int64, legacy: Double?
    ) -> Double? {
        if let legacy { return legacy }
        guard let price else { return nil }
        return UsagePricing.costUSD(price: price, tokens: tokens, fast: flags & 2 != 0, usGeo: flags & 4 != 0,
                                    longPrompt: flags & Self.longPromptFlag != 0)
    }

    /// Bit 3 of the flags a query returns (never stored): the message's prompt is above `UsagePricing.longPromptThreshold`.
    /// A group of messages is split by it, since the price tier is a property of one request and a sum has no length.
    static let longPromptFlag: Int64 = 8

    private static func ordered(_ models: [String: Accumulator], names: [String: String]) -> [UsageModelTotal] {
        models.map { key, accumulator in
            UsageModelTotal(
                model: key, displayName: names[key] ?? key, tokens: accumulator.tokens,
                estimatedCostUSD: accumulator.hasUnknownCost ? nil : accumulator.cost, messageCount: accumulator.messages)
        }.sorted {
            $0.tokens.total != $1.tokens.total ? $0.tokens.total > $1.tokens.total : $0.model < $1.model
        }
    }

    private func snapshotOnce(
        range: UsageRange, now: Date, timeZone: TimeZone, includeActivityWindow: Bool
    ) throws -> UsageSnapshot {
        let database = try openDatabase()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let bounds = range.bounds(now: now, calendar: calendar)
        let lower = bounds.start.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) } ?? Int64.min
        let upper = bounds.end.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) } ?? Int64.max

        var total = Accumulator()
        var byModel: [String: Accumulator] = [:]
        var displayNames: [String: String] = [:]
        var unknownModels: Set<String> = []
        var byDay: [Date: DayAccumulator] = [:]
        var resolver = DayResolver(calendar: calendar)

        for group in try database.aggregates(lower: lower, upper: upper) {
            let raw = try database.symbolText(group.model) ?? ""
            let price = UsagePricing.price(forModel: raw)
            let key = price == nil ? raw : UsagePricing.canonicalModelID(raw)
            displayNames[key] = price?.displayName ?? raw
            let cost = Self.cost(price: price, tokens: group.tokens, flags: group.flags,
                                 legacy: group.hasLegacyCost ? group.legacyCost : nil)
            if cost == nil { unknownModels.insert(raw) }
            total.add(tokens: group.tokens, cost: cost, messages: group.messages)
            byModel[key, default: Accumulator()].add(tokens: group.tokens, cost: cost, messages: group.messages)
            let dayStart = resolver.day(ofBucket: group.bucket)
            byDay[dayStart, default: DayAccumulator()].total.add(tokens: group.tokens, cost: cost, messages: group.messages)
            byDay[dayStart, default: DayAccumulator()].models[key, default: Accumulator()]
                .add(tokens: group.tokens, cost: cost, messages: group.messages)
        }
        var allSessions: Set<Int64> = []
        for (bucket, session) in try database.sessionBuckets(lower: lower, upper: upper) {
            allSessions.insert(session)
            byDay[resolver.day(ofBucket: bucket), default: DayAccumulator()].sessions.insert(session)
        }

        var days: [UsageDay] = []
        for start in byDay.keys.sorted() {
            let accumulator = byDay[start]!
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            days.append(UsageDay(
                day: String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0), start: start,
                tokens: accumulator.total.tokens, estimatedCostUSD: accumulator.total.cost,
                hasUnknownCost: accumulator.total.hasUnknownCost, messageCount: accumulator.total.messages,
                sessionCount: accumulator.sessions.count, models: Self.ordered(accumulator.models, names: displayNames)))
        }
        return UsageSnapshot(
            provider: .claude, asOf: now, priceTableAsOf: UsagePricing.asOf, range: range, tokens: total.tokens,
            estimatedCostUSD: total.cost, unknownModels: unknownModels.sorted(), messageCount: total.messages,
            sessionCount: allSessions.count, days: days, models: Self.ordered(byModel, names: displayNames),
            activityWindow: includeActivityWindow ? try activityWindow(now: now, database: database) : nil)
    }

    /// ccusage's block rule over the last week of messages: a block starts at its first message
    /// floored to the UTC hour and runs five hours; a message more than five hours after the
    /// block start or after the previous message opens a new block. Only the block containing
    /// `now` is returned, and only while it is still open.
    private func activityWindow(now: Date, database: UsageDatabase) throws -> UsageActivityWindow? {
        let nowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        let horizon = Int64((now.timeIntervalSince1970 - Self.activityHorizonSeconds) * 1_000)
        let span = Self.blockSeconds * 1_000
        var startMs: Int64 = 0
        var lastMs: Int64 = 0
        var accumulator = Accumulator()
        var open = false
        var prices: [Int64: UsageModelPrice?] = [:]
        let cursor = try database.messages(lower: horizon, upper: nowMs)
        while let row = try cursor.next() {
            if open, row.timestampMs - startMs > span || row.timestampMs - lastMs > span { open = false }
            if !open {
                startMs = row.timestampMs / 3_600_000 * 3_600_000
                accumulator = Accumulator()
                open = true
            }
            lastMs = row.timestampMs
            if prices[row.model] == nil {
                prices[row.model] = .some(UsagePricing.price(forModel: try database.symbolText(row.model) ?? ""))
            }
            accumulator.add(
                tokens: row.tokens,
                cost: Self.cost(price: prices[row.model] ?? nil, tokens: row.tokens, flags: row.flags, legacy: row.legacyCost),
                messages: 1)
        }
        guard open, nowMs < startMs + span, nowMs - lastMs < span else { return nil }
        return UsageActivityWindow(
            start: Date(timeIntervalSince1970: Double(startMs) / 1_000),
            end: Date(timeIntervalSince1970: Double(startMs + span) / 1_000),
            lastActivity: Date(timeIntervalSince1970: Double(lastMs) / 1_000),
            tokens: accumulator.tokens, estimatedCostUSD: accumulator.cost,
            hasUnknownCost: accumulator.hasUnknownCost, messageCount: accumulator.messages)
    }

    // MARK: database lifecycle

    private func openDatabase() throws -> UsageDatabase {
        if let database { return database }
        let opened: UsageDatabase
        do {
            opened = try UsageDatabase(url: databaseURL)
        } catch let error as ClaudeUsageIndexError where error.isCorruption || error.isSchemaMismatch {
            Self.removeDatabaseFiles(databaseURL)
            opened = try UsageDatabase(url: databaseURL)
        }
        database = opened
        symbols = [:]
        forgotten = nil
        return opened
    }

    private func discardDatabase() {
        database = nil
        symbols = [:]
        forgotten = nil
        Self.removeDatabaseFiles(databaseURL)
    }

    private static func removeDatabaseFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            unlink(url.path + suffix)
        }
    }

    private func symbol(_ text: String, _ database: UsageDatabase) throws -> Int64 {
        if let known = symbols[text] { return known }
        let id = try database.internSymbol(text)
        symbols[text] = id
        return id
    }

    private func forgottenSet(_ database: UsageDatabase) throws -> ForgottenSessions {
        if let forgotten { return forgotten }
        let loaded = ForgottenSessions(digests: try database.forgottenDigests())
        forgotten = loaded
        return loaded
    }

    // MARK: hashing and guards

    /// FNV-1a, 64 bit: stable across runs (unlike `Hasher`), collision odds negligible at this scale.
    static func hash(_ bytes: some Sequence<UInt8>) -> Int64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return Int64(bitPattern: value)
    }

    /// The up-to-64 bytes ending at `offset`, hashed.
    static func guardBytes(_ descriptor: Int32, before offset: Int64) -> (Int, Int64) {
        let length = Int(min(offset, 64))
        guard length > 0 else { return (0, hash([UInt8]())) }
        var bytes = [UInt8](repeating: 0, count: length)
        let read = pread(descriptor, &bytes, length, off_t(offset) - off_t(length))
        guard read == length else { return (0, hash([UInt8]())) }
        return (length, hash(bytes))
    }

    static func guardMatches(_ descriptor: Int32, offset: Int64, length: Int, hash expected: Int64) -> Bool {
        guard length > 0 else { return true }
        guard offset >= Int64(length) else { return false }
        var bytes = [UInt8](repeating: 0, count: length)
        guard pread(descriptor, &bytes, length, off_t(offset) - off_t(length)) == length else { return false }
        return hash(bytes) == expected
    }
}

// MARK: - forgotten sessions

/// The sessions whose link to messages must stay cut, kept as SHA-256 digests of their lowercased
/// ids so the index file never holds an id of a deleted conversation. Owned by the index actor.
final class ForgottenSessions {
    private var digests: Set<String>
    private var answers: [String: Bool] = [:]

    init(digests: Set<String>) { self.digests = digests }

    static func digest(of id: String) -> String {
        SHA256.hash(data: Data(id.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func insert(_ id: String) {
        digests.insert(Self.digest(of: id))
        answers.removeAll()
    }

    /// Hashes each distinct session text once; most records of a file repeat one session.
    func contains(_ text: String) -> Bool {
        guard !digests.isEmpty else { return false }
        if let known = answers[text] { return known }
        if answers.count >= 4_096 { answers.removeAll() }
        let found = digests.contains(Self.digest(of: text))
        answers[text] = found
        return found
    }
}

// MARK: - transcript discovery

struct UsageTranscriptFile {
    let path: String
    /// Owning session: the file stem, or the parent session directory for subagent files.
    let session: String
    let dev: Int64
    let ino: Int64
    let size: Int64
    let mtimeNs: Int64

    init(path: String, session: String, info: stat) {
        self.path = path
        self.session = session
        dev = Int64(info.st_dev)
        ino = Int64(bitPattern: info.st_ino)
        size = Int64(info.st_size)
        mtimeNs = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}

/// Finds transcripts without following symlinks, keeping the registry reader's stance:
/// the config and `projects` directories and every file must belong to this user and the
/// config directory must not be group- or world-writable.
enum UsageTranscriptWalker {
    static let skippedDirectories: Set<String> = ["memory", "tool-results"]
    private static let maximumDepth = 6

    static func isTranscriptName(_ name: String) -> Bool {
        name.hasSuffix(".jsonl") && !name.contains(".orphaned-") && !name.contains(".superseded-")
    }

    static func session(forRelativeComponents components: [String]) -> String {
        guard let name = components.last else { return "" }
        if components.count >= 3, components[components.count - 2] == "subagents" {
            return components[components.count - 3]
        }
        return String(name.dropLast(".jsonl".count))
    }

    private static func openProjects(_ profile: ClaudeProfileLayout) -> Int32? {
        let root = open(profile.configDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return nil }
        defer { close(root) }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { return nil }
        let projects = openat(root, "projects", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard projects >= 0 else { return nil }
        guard fstat(projects, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(projects)
            return nil
        }
        return projects
    }

    static func candidates(profile: ClaudeProfileLayout) -> [UsageTranscriptFile] {
        guard let projects = openProjects(profile) else { return [] }
        defer { close(projects) }
        var found: [UsageTranscriptFile] = []
        walk(descriptor: projects, path: profile.projectsDirectory.path, components: [], depth: 0, into: &found)
        return found.sorted { $0.path < $1.path }
    }

    private static func walk(
        descriptor: Int32, path: String, components: [String], depth: Int, into found: inout [UsageTranscriptFile]
    ) {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            return
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        for name in names {
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid() else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard depth < maximumDepth, !skippedDirectories.contains(name) else { continue }
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { continue }
                walk(descriptor: child, path: path + "/" + name, components: components + [name], depth: depth + 1, into: &found)
                close(child)
            case S_IFREG:
                guard isTranscriptName(name) else { continue }
                found.append(UsageTranscriptFile(
                    path: path + "/" + name, session: session(forRelativeComponents: components + [name]), info: info))
            default:
                continue
            }
        }
    }

    /// A single transcript named by the caller (a hook's `transcript_path`). Accepted only when
    /// its real path (symlinks resolved) lies inside the profile's `projects` directory and is a
    /// regular file of this user, so a link cannot lead the scan outside the profile.
    static func candidate(at url: URL, profile: ClaudeProfileLayout) -> UsageTranscriptFile? {
        guard url.isFileURL, let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        let path = String(cString: resolved)
        guard let projectsReal = realpath(profile.projectsDirectory.path, nil) else { return nil }
        defer { free(projectsReal) }
        let prefix = String(cString: projectsReal) + "/"
        guard path.hasPrefix(prefix), isTranscriptName((path as NSString).lastPathComponent) else { return nil }
        guard let projects = openProjects(profile) else { return nil }
        close(projects)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
        let relative = String(path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        return UsageTranscriptFile(path: path, session: session(forRelativeComponents: relative), info: info)
    }
}

// MARK: - SQLite

struct UsageRow {
    var key: Int64
    var fileID: Int64
    var timestampMs: Int64
    var session: Int64?
    var model: Int64
    var tokens: UsageTokens
    var flags: Int64
    var total: Int64
    var legacyCost: Double?
}

struct UsageFileState {
    var id: Int64
    var dev: Int64
    var ino: Int64
    var size: Int64
    var mtimeNs: Int64
    var offset: Int64
    var guardLength: Int
    var guardHash: Int64
}

struct UsageAggregate {
    var bucket: Int64
    var model: Int64
    var flags: Int64
    var hasLegacyCost: Bool
    var legacyCost: Double
    var tokens: UsageTokens
    var messages: Int
}

extension ClaudeUsageIndexError {
    var isCorruption: Bool {
        guard case let .sqlite(_, code, _) = self else { return false }
        return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }

    var isSchemaMismatch: Bool {
        guard case let .sqlite(operation, _, _) = self else { return false }
        return operation == "schema"
    }
}

/// Owned by the index actor; never shared.
final class UsageDatabase {
    private let handle: OpaquePointer
    /// `msg_session_main` exists; without it `latestMainMessage` answers nil instead of scanning `msg`.
    private(set) var hasMainThreadIndex = false
    private var statements: [String: OpaquePointer] = [:]

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "could not allocate connection"
            if let connection { sqlite3_close(connection) }
            throw ClaudeUsageIndexError.sqlite(operation: "open", code: opened, message: message)
        }
        handle = connection
        do { try configure() } catch {
            sqlite3_close(connection)
            throw error
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    private func configure() throws {
        sqlite3_busy_timeout(handle, 2_000)
        // Deleted rows are overwritten, not just unlinked: a forgotten id must not stay in free pages.
        try execute("PRAGMA secure_delete = ON")
        let integrity = try scalarText("PRAGMA quick_check")
        guard integrity == "ok" else {
            throw ClaudeUsageIndexError.sqlite(operation: "integrity check", code: SQLITE_CORRUPT, message: integrity)
        }
        let version = Int32(try scalarInt("PRAGMA user_version"))
        let applicationID = Int32(try scalarInt("PRAGMA application_id"))
        let tables = try scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        var needsMigration = false
        if version == 0 && applicationID == 0 && tables == 0 {
            try transaction { try createSchema() }
        } else if version == 1 && applicationID == ClaudeUsageIndex.applicationID {
            needsMigration = true
        } else if version != ClaudeUsageIndex.schemaVersion || applicationID != ClaudeUsageIndex.applicationID {
            // Newer, older or foreign: the file is disposable, the transcripts are the source.
            throw ClaudeUsageIndexError.sqlite(
                operation: "schema", code: SQLITE_SCHEMA, message: "user_version \(version), application_id \(applicationID)")
        }
        guard try scalarText("PRAGMA journal_mode = WAL").lowercased() == "wal" else {
            throw ClaudeUsageIndexError.sqlite(operation: "enable WAL", code: SQLITE_ERROR, message: "journal mode did not become WAL")
        }
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA cache_size = -8192") // 8 MiB page cache
        if needsMigration { try migrateFromSchemaOne() }
        // Added after schema 2 shipped, so it is created on open for files that predate it. Best effort:
        // a full disk or a busy file must not make all usage unavailable; the context lookup then
        // reports nothing (it never falls back to scanning).
        hasMainThreadIndex = (try? execute(Self.mainThreadIndexSQL)) != nil
    }

    /// Makes "the latest main-thread message of a session" an index seek (`latestMainMessage`).
    static let mainThreadIndexSQL =
        "CREATE INDEX IF NOT EXISTS msg_session_main ON msg(session, ts_ms) WHERE session IS NOT NULL AND flags & 1 = 0"

    /// Schema 1 kept forgotten ids in clear text and left the session's symbol row. The ids become
    /// digests, their rows go, and the file is rewritten so none of the old bytes survive in it.
    private func migrateFromSchemaOne() throws {
        let old: [String] = try withTransient("SELECT session FROM forgotten") { statement in
            var result: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
            }
            return result
        }
        try transaction {
            try execute("CREATE TABLE forgotten_v2 (digest TEXT PRIMARY KEY) WITHOUT ROWID")
            for digest in Set(old.map { ForgottenSessions.digest(of: $0) }) {
                try execute("INSERT OR IGNORE INTO forgotten_v2(digest) VALUES ('\(digest)')")
            }
            _ = try forget(lowercasedSessions: Set(old.map { $0.lowercased() }), recordDigests: false)
            try execute("DROP TABLE forgotten")
            try execute("ALTER TABLE forgotten_v2 RENAME TO forgotten")
            try execute("PRAGMA user_version = \(ClaudeUsageIndex.schemaVersion)")
        }
        try checkpointTruncate()
        if !old.isEmpty {
            try execute("VACUUM")
            try checkpointTruncate()
        }
    }

    private func createSchema() throws {
        try execute("PRAGMA application_id = \(ClaudeUsageIndex.applicationID)")
        try execute("CREATE TABLE symbol (id INTEGER PRIMARY KEY, text TEXT NOT NULL UNIQUE)")
        try execute("""
            CREATE TABLE file (
                id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, session TEXT NOT NULL,
                dev INTEGER NOT NULL, ino INTEGER NOT NULL, size INTEGER NOT NULL DEFAULT 0,
                mtime_ns INTEGER NOT NULL DEFAULT 0, offset INTEGER NOT NULL DEFAULT 0,
                guard_len INTEGER NOT NULL DEFAULT 0, guard_hash INTEGER NOT NULL DEFAULT 0)
            """)
        try execute("CREATE INDEX file_session ON file(session)")
        // flags: bit 0 sidechain, bit 1 fast speed, bit 2 US inference geography.
        try execute("""
            CREATE TABLE msg (
                key INTEGER PRIMARY KEY, file_id INTEGER NOT NULL, ts_ms INTEGER NOT NULL, session INTEGER,
                model INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL,
                cw5 INTEGER NOT NULL, cw1 INTEGER NOT NULL, cr INTEGER NOT NULL, web INTEGER NOT NULL,
                flags INTEGER NOT NULL, total INTEGER NOT NULL, cost REAL)
            """)
        try execute("CREATE INDEX msg_ts ON msg(ts_ms)")
        try execute("CREATE INDEX msg_file ON msg(file_id)")
        try execute("CREATE INDEX msg_session ON msg(session) WHERE session IS NOT NULL")
        // SHA-256 of a forgotten session's lowercased id, hex: the re-link guard without the ids.
        try execute("CREATE TABLE forgotten (digest TEXT PRIMARY KEY) WITHOUT ROWID")
        try execute("PRAGMA user_version = \(ClaudeUsageIndex.schemaVersion)")
    }

    // MARK: primitives

    fileprivate func error(_ operation: String, _ code: Int32) -> ClaudeUsageIndexError {
        .sqlite(operation: operation, code: code, message: String(cString: sqlite3_errmsg(handle)))
    }

    func begin() throws { try execute("BEGIN IMMEDIATE") }
    func commit() throws { try execute("COMMIT") }
    func rollback() { try? execute("ROLLBACK") }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw ClaudeUsageIndexError.sqlite(operation: "execute", code: result, message: detail)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        try withTransient(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw error("scalar", sqlite3_errcode(handle)) }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func scalarText(_ sql: String) throws -> String {
        try withTransient(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                throw error("scalar", sqlite3_errcode(handle))
            }
            return String(cString: text)
        }
    }

    private func withTransient<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw error("prepare", result) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    /// A cached prepared statement, reset and cleared before use.
    private func cached<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement: OpaquePointer
        if let known = statements[sql] {
            statement = known
        } else {
            var prepared: OpaquePointer?
            let result = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil)
            guard result == SQLITE_OK, let prepared else { throw error("prepare", result) }
            statements[sql] = prepared
            statement = prepared
        }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        defer { sqlite3_reset(statement) }
        return try body(statement)
    }

    private func done(_ statement: OpaquePointer, _ operation: String) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw error(operation, result) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: String, _ index: Int32, _ statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Int64?, _ index: Int32, _ statement: OpaquePointer) {
        if let value { sqlite3_bind_int64(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    // MARK: symbols, files, messages

    func internSymbol(_ text: String) throws -> Int64 {
        try cached("INSERT OR IGNORE INTO symbol(text) VALUES (?1)") { statement in
            bind(text, 1, statement)
            try done(statement, "intern symbol")
        }
        return try cached("SELECT id FROM symbol WHERE text = ?1") { statement in
            bind(text, 1, statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw error("intern symbol", sqlite3_errcode(handle)) }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func symbolID(_ text: String) throws -> Int64? {
        try cached("SELECT id FROM symbol WHERE text = ?1") { statement in
            bind(text, 1, statement)
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
        }
    }

    func symbolText(_ id: Int64) throws -> String? {
        try cached("SELECT text FROM symbol WHERE id = ?1") { statement in
            bind(id, 1, statement)
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    func file(path: String) throws -> UsageFileState? {
        try cached("SELECT id, dev, ino, size, mtime_ns, offset, guard_len, guard_hash FROM file WHERE path = ?1") { statement in
            bind(path, 1, statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return UsageFileState(
                id: sqlite3_column_int64(statement, 0), dev: sqlite3_column_int64(statement, 1),
                ino: sqlite3_column_int64(statement, 2), size: sqlite3_column_int64(statement, 3),
                mtimeNs: sqlite3_column_int64(statement, 4), offset: sqlite3_column_int64(statement, 5),
                guardLength: Int(sqlite3_column_int64(statement, 6)), guardHash: sqlite3_column_int64(statement, 7))
        }
    }

    /// Creates the file row or resets an existing one to "nothing indexed yet" under the given identity.
    func saveFile(path: String, session: String, dev: Int64, ino: Int64) throws -> Int64 {
        try cached("""
            INSERT INTO file(path, session, dev, ino) VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(path) DO UPDATE SET session = ?2, dev = ?3, ino = ?4, size = 0, mtime_ns = 0,
                offset = 0, guard_len = 0, guard_hash = 0
            """) { statement in
            bind(path, 1, statement)
            bind(session, 2, statement)
            bind(dev, 3, statement)
            bind(ino, 4, statement)
            try done(statement, "save file")
        }
        return try cached("SELECT id FROM file WHERE path = ?1") { statement in
            bind(path, 1, statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw error("save file", sqlite3_errcode(handle)) }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func updateProgress(fileID: Int64, offset: Int64, guardLength: Int, guardHash: Int64) throws {
        try cached("UPDATE file SET offset = ?2, guard_len = ?3, guard_hash = ?4 WHERE id = ?1") { statement in
            bind(fileID, 1, statement)
            bind(offset, 2, statement)
            bind(Int64(guardLength), 3, statement)
            bind(guardHash, 4, statement)
            try done(statement, "update progress")
        }
    }

    func updateObserved(fileID: Int64, size: Int64, mtimeNs: Int64) throws {
        try cached("UPDATE file SET size = ?2, mtime_ns = ?3 WHERE id = ?1") { statement in
            bind(fileID, 1, statement)
            bind(size, 2, statement)
            bind(mtimeNs, 3, statement)
            try done(statement, "update observed")
        }
    }

    func deleteMessages(fileID: Int64) throws {
        try cached("DELETE FROM msg WHERE file_id = ?1") { statement in
            bind(fileID, 1, statement)
            try done(statement, "delete messages")
        }
    }

    /// Removes a forgotten session from the index: its file rows (their paths carry the id and the
    /// encoded project path), its symbol rows and the messages' links to them. Returns messages
    /// unlinked. `recordDigests` is false only while converting a schema 1 file, which stored them.
    func forget(lowercasedSessions ids: Set<String>, recordDigests: Bool = true) throws -> Int {
        var unlinked = 0
        for id in ids {
            if recordDigests {
                try cached("INSERT OR IGNORE INTO forgotten(digest) VALUES (?1)") { statement in
                    bind(ForgottenSessions.digest(of: id), 1, statement)
                    try done(statement, "forget session")
                }
            }
            try cached("DELETE FROM file WHERE lower(session) = ?1") { statement in
                bind(id, 1, statement)
                try done(statement, "delete files")
            }
            let symbolIDs: [Int64] = try cached("SELECT id FROM symbol WHERE lower(text) = ?1") { statement in
                bind(id, 1, statement)
                var found: [Int64] = []
                while sqlite3_step(statement) == SQLITE_ROW { found.append(sqlite3_column_int64(statement, 0)) }
                return found
            }
            for symbol in symbolIDs {
                unlinked += try cached("UPDATE msg SET session = NULL WHERE session = ?1") { statement in
                    bind(symbol, 1, statement)
                    try done(statement, "unlink session")
                    return Int(sqlite3_changes(handle))
                }
                try cached("DELETE FROM symbol WHERE id = ?1") { statement in
                    bind(symbol, 1, statement)
                    try done(statement, "delete symbol")
                }
            }
        }
        return unlinked
    }

    func forgottenDigests() throws -> Set<String> {
        try cached("SELECT digest FROM forgotten") { statement in
            var result: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) { result.insert(String(cString: text)) }
            }
            return result
        }
    }

    /// Truncating checkpoint: the WAL is emptied into the main file, so what a delete removed is
    /// gone from both (`secure_delete` already overwrote it in the pages).
    func checkpointTruncate() throws {
        try withTransient("PRAGMA wal_checkpoint(TRUNCATE)") { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw error("checkpoint", result) }
            guard sqlite3_column_int(statement, 0) == 0 else {
                throw ClaudeUsageIndexError.sqlite(operation: "checkpoint", code: SQLITE_BUSY,
                                                   message: "checkpoint was blocked by another connection")
            }
        }
    }

    /// Insert, or replace an existing row of the same message when the new one is a better copy:
    /// non-sidechain beats sidechain, then the larger total wins (streaming partials).
    ///
    /// A side chat's file (V22) holds copies of its parent's messages under the same ids (bit 4 of the stored flags marks a row
    /// held by a side chat): a record from such a file never takes a message another session holds, and a record from any other
    /// file takes the message back from a side chat, whatever the totals. So a copied message stays the parent's whichever file is
    /// read first, and forgetting a side chat never unlinks it. The side chat's own messages are new ids and count as usual.
    func upsert(_ row: UsageRow) throws {
        try cached("""
            INSERT INTO msg(key, file_id, ts_ms, session, model, input, output, cw5, cw1, cr, web, flags, total, cost)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            ON CONFLICT(key) DO UPDATE SET
                file_id = excluded.file_id, ts_ms = excluded.ts_ms, session = excluded.session, model = excluded.model,
                input = excluded.input, output = excluded.output, cw5 = excluded.cw5, cw1 = excluded.cw1,
                cr = excluded.cr, web = excluded.web, flags = excluded.flags, total = excluded.total, cost = excluded.cost
            WHERE ((excluded.flags & 16) = 0 OR (msg.flags & 16) != 0)
              AND (((msg.flags & 16) != 0 AND (excluded.flags & 16) = 0)
                   OR (excluded.flags & 1) < (msg.flags & 1)
                   OR ((excluded.flags & 1) = (msg.flags & 1) AND excluded.total > msg.total))
            """) { statement in
            bind(row.key, 1, statement)
            bind(row.fileID, 2, statement)
            bind(row.timestampMs, 3, statement)
            bind(row.session, 4, statement)
            bind(row.model, 5, statement)
            bind(row.tokens.input, 6, statement)
            bind(row.tokens.output, 7, statement)
            bind(row.tokens.cacheWrite5m, 8, statement)
            bind(row.tokens.cacheWrite1h, 9, statement)
            bind(row.tokens.cacheRead, 10, statement)
            bind(row.tokens.webSearches, 11, statement)
            bind(row.flags, 12, statement)
            bind(row.total, 13, statement)
            if let cost = row.legacyCost { sqlite3_bind_double(statement, 14, cost) } else { sqlite3_bind_null(statement, 14) }
            try done(statement, "upsert message")
        }
    }

    // MARK: queries

    /// Bit 4 of the stored flags: the row is held by a side chat's file (see `upsert`). Never returned by a query.
    static let sideChatFlag: Int64 = 16

    /// The speed and geography bits of a row plus the long-prompt bit (`ClaudeUsageIndex.longPromptFlag`), for grouping.
    static let queryFlagsSQL =
        "(flags & 6) | (CASE WHEN input + cw5 + cw1 + cr > \(UsagePricing.longPromptThreshold) THEN 8 ELSE 0 END)"
    /// All stored bits of a row plus the long-prompt bit.
    static let messageFlagsSQL =
        "((flags & 7) | (CASE WHEN input + cw5 + cw1 + cr > \(UsagePricing.longPromptThreshold) THEN 8 ELSE 0 END))"

    /// Totals grouped by quarter-hour bucket, model, speed/geography flags and whether the rows
    /// carry a legacy cost.
    func aggregates(lower: Int64, upper: Int64) throws -> [UsageAggregate] {
        try cached("""
            SELECT ts_ms / 900000, model, \(UsageDatabase.queryFlagsSQL), cost IS NOT NULL, SUM(COALESCE(cost, 0)),
                   SUM(input), SUM(output), SUM(cw5), SUM(cw1), SUM(cr), SUM(web), COUNT(*)
            FROM msg WHERE ts_ms >= ?1 AND ts_ms < ?2 GROUP BY 1, 2, 3, 4
            """) { statement in
            bind(lower, 1, statement)
            bind(upper, 2, statement)
            var result: [UsageAggregate] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw error("aggregate", step) }
                result.append(UsageAggregate(
                    bucket: sqlite3_column_int64(statement, 0), model: sqlite3_column_int64(statement, 1),
                    flags: sqlite3_column_int64(statement, 2), hasLegacyCost: sqlite3_column_int(statement, 3) != 0,
                    legacyCost: sqlite3_column_double(statement, 4),
                    tokens: UsageTokens(
                        input: sqlite3_column_int64(statement, 5), output: sqlite3_column_int64(statement, 6),
                        cacheWrite5m: sqlite3_column_int64(statement, 7), cacheWrite1h: sqlite3_column_int64(statement, 8),
                        cacheRead: sqlite3_column_int64(statement, 9), webSearches: sqlite3_column_int64(statement, 10)),
                    messages: Int(sqlite3_column_int64(statement, 11))))
            }
            return result
        }
    }

    struct QuarterTotal {
        var bucket: Int64
        var tokens: UsageTokens
        var messages: Int
    }

    private static func quarterTotal(_ statement: OpaquePointer, offset: Int32) -> (UsageTokens, Int) {
        (UsageTokens(
            input: sqlite3_column_int64(statement, offset), output: sqlite3_column_int64(statement, offset + 1),
            cacheWrite5m: sqlite3_column_int64(statement, offset + 2), cacheWrite1h: sqlite3_column_int64(statement, offset + 3),
            cacheRead: sqlite3_column_int64(statement, offset + 4), webSearches: sqlite3_column_int64(statement, offset + 5)),
         Int(sqlite3_column_int64(statement, offset + 6)))
    }

    /// Tokens and message counts per quarter-hour group; no model, session or cost dimension.
    func quarterTotals(lower: Int64, upper: Int64) throws -> [QuarterTotal] {
        try cached("""
            SELECT ts_ms / 900000, SUM(input), SUM(output), SUM(cw5), SUM(cw1), SUM(cr), SUM(web), COUNT(*)
            FROM msg WHERE ts_ms >= ?1 AND ts_ms < ?2 GROUP BY 1 ORDER BY 1
            """) { statement in
            bind(lower, 1, statement)
            bind(upper, 2, statement)
            var result: [QuarterTotal] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw error("quarter totals", step) }
                let (tokens, messages) = Self.quarterTotal(statement, offset: 1)
                result.append(QuarterTotal(bucket: sqlite3_column_int64(statement, 0), tokens: tokens, messages: messages))
            }
            return result
        }
    }

    func rangeTotals(lower: Int64, upper: Int64) throws -> (tokens: UsageTokens, messages: Int) {
        try cached("""
            SELECT 0, COALESCE(SUM(input), 0), COALESCE(SUM(output), 0), COALESCE(SUM(cw5), 0), COALESCE(SUM(cw1), 0),
                   COALESCE(SUM(cr), 0), COALESCE(SUM(web), 0), COUNT(*)
            FROM msg WHERE ts_ms >= ?1 AND ts_ms < ?2
            """) { statement in
            bind(lower, 1, statement)
            bind(upper, 2, statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw error("range totals", sqlite3_errcode(handle)) }
            let (tokens, messages) = Self.quarterTotal(statement, offset: 1)
            return (tokens, messages)
        }
    }

    /// The SQL of `latestMainMessage`, shared with the test that checks it is answered from
    /// `msg_session_main` and not by a table scan.
    static let latestMainMessageSQL = """
        SELECT ts_ms, model, input, output, cw5, cw1, cr, web FROM msg
        WHERE session = ?1 AND session IS NOT NULL AND flags & 1 = 0 ORDER BY ts_ms DESC, key DESC LIMIT 1
        """

    /// The newest non-sidechain message of a session (a symbol id), or nil.
    func latestMainMessage(session: Int64) throws -> UsageRow? {
        guard hasMainThreadIndex else { return nil }
        return try cached(Self.latestMainMessageSQL) { statement in
            bind(session, 1, statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return UsageRow(
                key: 0, fileID: 0, timestampMs: sqlite3_column_int64(statement, 0), session: session,
                model: sqlite3_column_int64(statement, 1),
                tokens: UsageTokens(
                    input: sqlite3_column_int64(statement, 2), output: sqlite3_column_int64(statement, 3),
                    cacheWrite5m: sqlite3_column_int64(statement, 4), cacheWrite1h: sqlite3_column_int64(statement, 5),
                    cacheRead: sqlite3_column_int64(statement, 6), webSearches: sqlite3_column_int64(statement, 7)),
                flags: 0, total: 0, legacyCost: nil)
        }
    }

    /// The SQL of `sessionAggregates`, shared with the test that checks it is answered from the
    /// `msg_session` index and not by a table scan.
    static let sessionAggregatesSQL = """
        SELECT model, \(queryFlagsSQL), cost IS NOT NULL, SUM(COALESCE(cost, 0)),
               SUM(input), SUM(output), SUM(cw5), SUM(cw1), SUM(cr), SUM(web), COUNT(*)
        FROM msg WHERE session = ?1 AND session IS NOT NULL AND ts_ms >= ?2 AND ts_ms < ?3 GROUP BY 1, 2, 3
        """

    /// One session's totals in a range, grouped by model, speed/geography flags and legacy cost.
    func sessionAggregates(session: Int64, lower: Int64, upper: Int64) throws -> [UsageAggregate] {
        try cached(Self.sessionAggregatesSQL) { statement in
            bind(session, 1, statement)
            bind(lower, 2, statement)
            bind(upper, 3, statement)
            var result: [UsageAggregate] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw error("session aggregate", step) }
                result.append(UsageAggregate(
                    bucket: 0, model: sqlite3_column_int64(statement, 0),
                    flags: sqlite3_column_int64(statement, 1), hasLegacyCost: sqlite3_column_int(statement, 2) != 0,
                    legacyCost: sqlite3_column_double(statement, 3),
                    tokens: UsageTokens(
                        input: sqlite3_column_int64(statement, 4), output: sqlite3_column_int64(statement, 5),
                        cacheWrite5m: sqlite3_column_int64(statement, 6), cacheWrite1h: sqlite3_column_int64(statement, 7),
                        cacheRead: sqlite3_column_int64(statement, 8), webSearches: sqlite3_column_int64(statement, 9)),
                    messages: Int(sqlite3_column_int64(statement, 10))))
            }
            return result
        }
    }

    func hasMessages() throws -> Bool {
        try cached("SELECT EXISTS(SELECT 1 FROM msg)") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw error("has messages", sqlite3_errcode(handle)) }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    func sessionBuckets(lower: Int64, upper: Int64) throws -> [(Int64, Int64)] {
        try cached("""
            SELECT DISTINCT ts_ms / 900000, session FROM msg
            WHERE ts_ms >= ?1 AND ts_ms < ?2 AND session IS NOT NULL
            """) { statement in
            bind(lower, 1, statement)
            bind(upper, 2, statement)
            var result: [(Int64, Int64)] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw error("session buckets", step) }
                result.append((sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1)))
            }
            return result
        }
    }

    /// Messages in time order, read one row at a time.
    final class MessageCursor {
        private let database: UsageDatabase
        private let statement: OpaquePointer

        fileprivate init(database: UsageDatabase, statement: OpaquePointer) {
            self.database = database
            self.statement = statement
        }

        deinit { sqlite3_finalize(statement) }

        func next() throws -> UsageRow? {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw database.error("messages", step) }
            return UsageRow(
                key: 0, fileID: 0, timestampMs: sqlite3_column_int64(statement, 0), session: nil,
                model: sqlite3_column_int64(statement, 1),
                tokens: UsageTokens(
                    input: sqlite3_column_int64(statement, 3), output: sqlite3_column_int64(statement, 4),
                    cacheWrite5m: sqlite3_column_int64(statement, 5), cacheWrite1h: sqlite3_column_int64(statement, 6),
                    cacheRead: sqlite3_column_int64(statement, 7), webSearches: sqlite3_column_int64(statement, 8)),
                flags: sqlite3_column_int64(statement, 2), total: 0,
                legacyCost: sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 9))
        }
    }

    func messages(lower: Int64, upper: Int64) throws -> MessageCursor {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, """
            SELECT ts_ms, model, \(Self.messageFlagsSQL), input, output, cw5, cw1, cr, web, cost FROM msg
            WHERE ts_ms >= ?1 AND ts_ms <= ?2 ORDER BY ts_ms
            """, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw error("prepare", result) }
        sqlite3_bind_int64(statement, 1, lower)
        sqlite3_bind_int64(statement, 2, upper)
        return MessageCursor(database: self, statement: statement)
    }
}
