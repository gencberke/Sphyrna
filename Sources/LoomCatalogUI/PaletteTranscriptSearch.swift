import Darwin
import Foundation
import LoomCore

/// Transcript search, stage 1 (V2-PLAN V06): a scan on demand, with no index, no watcher and no timer. It runs
/// only for a query the user typed in the open palette, reads each transcript once from the front in 1 MiB
/// chunks, newest first, and stops at its budget. What it reports is what it read, never "no matches" for a
/// pass that stopped early (`PaletteTranscriptCoverage`).
///
/// A chunk is lower-cased (ASCII) into a second buffer and searched with `memmem` for the query's bytes; only a
/// line that contains them is decoded, and only its user and assistant text blocks are matched again with the
/// query folded for case and accents. Tool results, thinking and meta lines never match, so a hit is always
/// something the user or Claude said. The byte gate is ASCII-case-insensitive and accent-exact: "Cafe" finds
/// "cafe" but not "café".
struct PaletteTranscriptFile: Equatable, Sendable {
    let sessionID: UUID
    let path: String
    let title: String
    let project: String?
    let modified: Date
}

struct PaletteSearchBudget: Equatable, Sendable {
    /// Only transcripts modified within this many seconds are read.
    var window: TimeInterval
    var maxBytes: Int
    var maxSeconds: Double
    var maxHits: Int
    var hitsPerSession: Int

    /// The first pass: the last 14 days, 512 MiB, 2 s.
    static let first = PaletteSearchBudget(window: 14 * 86_400, maxBytes: 512 << 20, maxSeconds: 2, maxHits: 24,
                                           hitsPerSession: 2)
    /// "Search older": the CLI's retention (30 days), 4 GiB, 8 s.
    static let older = PaletteSearchBudget(window: 30 * 86_400, maxBytes: 4 << 30, maxSeconds: 8, maxHits: 40,
                                           hitsPerSession: 2)

    static let chunkBytes = 1 << 20
    /// A line longer than this is not decoded (a pasted file, an image): it is counted, not read.
    static let maxLineBytes = 128 << 10
    /// The shortest query that is searched in conversations.
    static let minimumQueryLength = 3

    var days: Int { Int((window / 86_400).rounded()) }
}

struct PaletteTranscriptHit: Equatable, Sendable, Identifiable {
    let sessionID: UUID
    let title: String
    let project: String?
    let snippet: PaletteSnippet
    let timestamp: Date?
    /// Where the line starts in the file; with the session it names the hit.
    let offset: UInt64

    var id: String { "hit:\(sessionID.uuidString):\(offset)" }
}

/// What a pass covered. The footer prints it, so a partial pass says so.
struct PaletteTranscriptCoverage: Equatable, Sendable {
    enum Stop: Equatable, Sendable {
        case completed
        case bytes
        case time
        case hits
        case cancelled
    }

    var filesSearched = 0
    /// Transcripts inside the window that the pass could have read.
    var filesInWindow = 0
    var bytesRead = 0
    var stop = Stop.completed
    /// Lines over the line cap that were not decoded.
    var linesSkipped = 0
    /// Lines the gate let through that were parsed as JSON: a rare word costs few, a word that fills tool results
    /// costs none (those lines are turned away before the parse).
    var linesDecoded = 0
    var windowDays = 0
    /// The profile has no `projects` folder or the setting is off: nothing was searched.
    var unavailable = false
    /// The pass looked at the newest sessions only: the catalog held more than this many, and the oldest one looked
    /// at was still inside the window, so sessions inside it were left out. Nil when the list was not cut.
    var sessionCap: Int?

    var isComplete: Bool { stop == .completed && !unavailable && sessionCap == nil }
}

struct PaletteTranscriptOutcome: Equatable, Sendable {
    var hits: [PaletteTranscriptHit] = []
    var coverage = PaletteTranscriptCoverage()
}

enum PaletteTranscriptScanner {
    /// Searches `files` for `query`. `shouldStop` is asked between chunks (by default: has the calling task been
    /// cancelled); `progress` is called after a file when a hit is new and at least `progressInterval` passed.
    /// Synchronous: the caller runs it off the main thread.
    static func scan(
        query rawQuery: String, files: [PaletteTranscriptFile], budget: PaletteSearchBudget, now: Date = Date(),
        shouldStop: () -> Bool = { Task.isCancelled },
        progress: ((PaletteTranscriptOutcome) -> Void)? = nil, progressInterval: Double = 0.15
    ) -> PaletteTranscriptOutcome {
        var outcome = PaletteTranscriptOutcome()
        outcome.coverage.windowDays = budget.days
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = gateBytes(for: query)
        guard query.count >= PaletteSearchBudget.minimumQueryLength, !needle.isEmpty else { return outcome }

        let cutoff = now.addingTimeInterval(-budget.window)
        let candidates = files.filter { $0.modified >= cutoff }.sorted { $0.modified > $1.modified }
        outcome.coverage.filesInWindow = candidates.count

        let capacity = PaletteSearchBudget.chunkBytes + PaletteSearchBudget.maxLineBytes
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        let lowered = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate(); lowered.deallocate() }

        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e9 }
        var lastProgress = elapsed()
        var shownHits = 0

        for file in candidates {
            if shouldStop() { outcome.coverage.stop = .cancelled; return outcome }
            if elapsed() >= budget.maxSeconds { outcome.coverage.stop = .time; return outcome }
            if outcome.coverage.bytesRead >= budget.maxBytes { outcome.coverage.stop = .bytes; return outcome }
            guard let descriptor = openOwnRegularFile(file.path) else { continue }
            defer { close(descriptor) }

            var fileHits = 0
            var carry = 0
            var discarding = false
            var baseOffset: UInt64 = 0
            var stop: PaletteTranscriptCoverage.Stop?
            reading: while true {
                if shouldStop() { stop = .cancelled; break }
                if elapsed() >= budget.maxSeconds { stop = .time; break }
                let remaining = budget.maxBytes - outcome.coverage.bytesRead
                if remaining <= 0 { stop = .bytes; break }
                let wanted = min(PaletteSearchBudget.chunkBytes, remaining)
                let count = read(descriptor, buffer + carry, wanted)
                if count <= 0 { break }
                outcome.coverage.bytesRead += count
                let end = carry + count

                guard let lastNewline = indexOfLastNewline(in: buffer, before: end) else {
                    // No line ends in this chunk: keep it as the start of a line, unless that line is too long.
                    if discarding || end > PaletteSearchBudget.maxLineBytes {
                        if !discarding { outcome.coverage.linesSkipped += 1 }
                        discarding = true
                        baseOffset += UInt64(end)
                        carry = 0
                    } else {
                        carry = end
                    }
                    continue
                }
                let usable = lastNewline + 1
                var start = 0
                if discarding {
                    // The rest of a too-long line: skip to its newline.
                    let firstNewline = memchr(buffer, 0x0A, end)!
                    start = buffer.distance(to: firstNewline.assumingMemoryBound(to: UInt8.self)) + 1
                    discarding = false
                }
                if start < usable {
                    lowercaseASCII(from: buffer + start, to: lowered + start, count: usable - start)
                    var cursor = start
                    while cursor < usable {
                        let found: UnsafeMutableRawPointer? = needle.withUnsafeBufferPointer { pattern in
                            memmem(lowered + cursor, usable - cursor, pattern.baseAddress, pattern.count)
                        }
                        guard let found else { break }
                        let position = lowered.distance(to: found.assumingMemoryBound(to: UInt8.self))
                        var lineStart = start
                        if let before = indexOfLastNewline(in: buffer + start, before: position - start) {
                            lineStart = start + before + 1
                        }
                        // `usable` ends with a newline, so one always follows the match.
                        let after = memchr(buffer + position, 0x0A, usable - position)!
                        let lineEnd = buffer.distance(to: after.assumingMemoryBound(to: UInt8.self))
                        cursor = lineEnd + 1
                        let length = lineEnd - lineStart
                        guard length > 0 else { continue }
                        if length > PaletteSearchBudget.maxLineBytes {
                            outcome.coverage.linesSkipped += 1
                            continue
                        }
                        let line = UnsafeRawBufferPointer(start: buffer + lineStart, count: length)
                        guard isMessageLine(line) else { continue }
                        outcome.coverage.linesDecoded += 1
                        if let hit = decode(line: line, query: query, file: file, offset: baseOffset + UInt64(lineStart)) {
                            outcome.hits.append(hit)
                            fileHits += 1
                            if outcome.hits.count >= budget.maxHits { stop = .hits; break reading }
                            if fileHits >= budget.hitsPerSession { break reading }
                        }
                    }
                }
                carry = end - usable
                if carry > 0 { memmove(buffer, buffer + usable, carry) }
                baseOffset += UInt64(usable)
                // A partial line longer than the cap will never be decoded: stop keeping it.
                if carry > PaletteSearchBudget.maxLineBytes {
                    outcome.coverage.linesSkipped += 1
                    baseOffset += UInt64(carry)
                    carry = 0
                    discarding = true
                }
            }
            if let stop {
                outcome.coverage.stop = stop
                // A file the pass stopped inside is not counted as searched; one that reached the hit limit is.
                if stop == .hits { outcome.coverage.filesSearched += 1 }
                return outcome
            }
            outcome.coverage.filesSearched += 1
            if let progress, outcome.hits.count > shownHits, elapsed() - lastProgress >= progressInterval {
                shownHits = outcome.hits.count
                lastProgress = elapsed()
                progress(outcome)
            }
        }
        return outcome
    }

    // MARK: Gate

    /// The bytes the gate looks for: the query as JSON writes it (quotes, backslashes, line breaks and tabs
    /// escaped), ASCII lower-cased.
    static func gateBytes(for query: String) -> [UInt8] {
        var escaped = ""
        for character in query {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return escaped.utf8.map { $0 &- 65 < 26 ? $0 | 0x20 : $0 }
    }

    /// The index of the last newline before `count`, if any.
    private static func indexOfLastNewline(in bytes: UnsafePointer<UInt8>, before count: Int) -> Int? {
        var index = count - 1
        while index >= 0 {
            if bytes[index] == 0x0A { return index }
            index -= 1
        }
        return nil
    }

    @inline(__always)
    private static func lowercaseASCII(from source: UnsafePointer<UInt8>, to target: UnsafeMutablePointer<UInt8>, count: Int) {
        for index in 0..<count {
            let byte = source[index]
            target[index] = byte &- 65 < 26 ? byte | 0x20 : byte
        }
    }

    // MARK: Decode

    // Claude writes compact JSON; the spaced spelling is accepted too, so a change of style costs nothing.
    private static let userMarkers = [#""type":"user""#, #""type": "user""#].map { Array($0.utf8) }
    private static let assistantMarkers = [#""type":"assistant""#, #""type": "assistant""#].map { Array($0.utf8) }
    private static let toolResultMarkers = [#""type":"tool_result""#, #""type": "tool_result""#].map { Array($0.utf8) }

    private static func contains(_ line: UnsafeRawBufferPointer, any markers: [[UInt8]]) -> Bool {
        markers.contains { marker in
            marker.withUnsafeBufferPointer { memmem(line.baseAddress, line.count, $0.baseAddress, $0.count) != nil }
        }
    }

    /// A cheap look before the parse: the line says it is a user or assistant message and holds no tool result
    /// (text a person typed carries these markers escaped, so it cannot be mistaken for one).
    static func isMessageLine(_ line: UnsafeRawBufferPointer) -> Bool {
        (contains(line, any: userMarkers) || contains(line, any: assistantMarkers)) && !contains(line, any: toolResultMarkers)
    }

    private static let snippetBefore = 48
    private static let snippetAfter = 96

    /// The hit in one transcript line, or nil when the line is not a user or assistant message or its text does not
    /// contain the query (the gate matched something else, such as a tool result).
    static func decode(line: UnsafeRawBufferPointer, query: String, file: PaletteTranscriptFile, offset: UInt64) -> PaletteTranscriptHit? {
        guard let base = line.baseAddress,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes: base, count: line.count)) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant",
              object["isMeta"] as? Bool != true, object["isCompactSummary"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return nil }
        let text: String
        switch message["content"] {
        case let string as String: text = string
        case let blocks as [Any]:
            text = blocks.compactMap { ($0 as? [String: Any]).flatMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil } }
                .joined(separator: "\n")
        default: return nil
        }
        // The snippet quotes the words, not the Markdown around them. A query that only the raw text holds (a
        // link's address) still finds its hit, quoted from the raw text.
        let plain = MarkdownPlainText.stripped(text)
        let quoted = plain.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil ? plain : text
        guard let range = quoted.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let from = quoted.index(range.lowerBound, offsetBy: -snippetBefore, limitedBy: quoted.startIndex) ?? quoted.startIndex
        let to = quoted.index(range.upperBound, offsetBy: snippetAfter, limitedBy: quoted.endIndex) ?? quoted.endIndex
        // The space between the match and its neighbours is kept (`oneLine` trims the edges of what it is given).
        let head = quoted[from..<range.lowerBound], tail = quoted[range.upperBound..<to]
        let before = edge(oneLine(head), cut: from > quoted.startIndex, leading: true)
            + (head.last?.isWhitespace == true ? " " : "")
        let after = (tail.first?.isWhitespace == true ? " " : "")
            + edge(oneLine(tail), cut: to < quoted.endIndex, leading: false)
        let snippet = PaletteSnippet(role: type == "user" ? .you : .claude, before: before,
                                     match: oneLine(quoted[range]), after: after)
        return PaletteTranscriptHit(
            sessionID: file.sessionID, title: file.title, project: file.project, snippet: snippet,
            timestamp: (object["timestamp"] as? String).flatMap(parseTimestamp), offset: offset)
    }

    /// A cut end of a snippet: one ellipsis, with the dots and spaces the cut left beside it dropped, so it
    /// never reads "…." or "……".
    static func edge(_ piece: String, cut: Bool, leading: Bool) -> String {
        guard cut else { return piece }
        let marks: Set<Character> = [".", "…", " "]
        if leading {
            return "…" + String(piece.drop { marks.contains($0) })
        }
        var trimmed = Substring(piece)
        while let last = trimmed.last, marks.contains(last) { trimmed.removeLast() }
        return String(trimmed) + "…"
    }

    /// A piece of the text on one line, cleaned the way every line of agent and user text is (`StatusReason.oneLine`:
    /// whitespace runs become one space, control, bidirectional and zero-width scalars are dropped). The pieces
    /// are a snippet's head, match and tail, so the cap is far above what any of them holds.
    private static func oneLine(_ text: Substring) -> String {
        StatusReason.oneLine(String(text), limit: snippetPartLimit) ?? ""
    }

    private static let snippetPartLimit = 1_000

    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
