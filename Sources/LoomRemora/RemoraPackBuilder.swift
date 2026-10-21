import Foundation
import LoomCore

/// Builds the pack of one call: a bounded, masked text Sphyrna writes fresh for every question and every brief (design/
/// DESIGN.md §20; LOMBOT §2, §3.4, §3.5, §5).
///
/// The layout, in this order (the first two blocks are the stable prefix, so a prompt cache can reuse them):
///
///     <memory>      the memory share (when there is one)
///     <self>        what Remora is and cannot see: fixed lines only
///     <now>         local date and time, today's calls and tokens   (changes on every call)
///     <sessions>    the index: one row per session, with what became of its transcript
///     <excerpt>     the tail of each picked session, most relevant first
///     <previous>    the last question and answer (follow-ups)
///     <question>    or <request> for the brief
///
/// Everything inside `<sessions>`, `<excerpt>`, `<previous>` and `<memory>` is data; the rules (`RemoraRules`) say so.
/// Any text that could close or open one of these blocks is defused, and secrets are masked (`RemoraSecretMask`).
public struct RemoraPackBuilder: Sendable {
    public typealias Sessions = @Sendable (SessionQuery) async throws -> [SessionSummary]
    /// The transcript of a Claude session; nil when it cannot be found or fails the location rules.
    public typealias Transcript = @Sendable (SessionSummary) async -> ClaudeTranscriptFile?

    private let sessions: Sessions
    private let transcript: Transcript
    private let limits: RemoraPackLimits

    public init(sessions: @escaping Sessions, transcript: @escaping Transcript, limits: RemoraPackLimits = .standard) {
        self.sessions = sessions
        self.transcript = transcript
        self.limits = limits
    }

    public init(directory: SessionDirectory, transcript: @escaping Transcript, limits: RemoraPackLimits = .standard) {
        self.init(sessions: { try await directory.summaries($0) }, transcript: transcript, limits: limits)
    }

    /// Finds a session's transcript through the catalog's record (provider conversation id and working directory) in the
    /// one project folder Claude names after the working directory, and nowhere else (a miss is a miss: no folder is listed).
    public static func catalogTranscripts(_ catalog: SessionCatalog, configDirectory: URL) -> Transcript {
        { summary in
            guard let record = try? await catalog.session(id: summary.id), record.session.provider == .claude,
                  let conversation = record.session.providerConversationID else { return nil }
            return ClaudeTranscriptLocator.locate(sessionID: conversation, configDirectory: configDirectory,
                                                  onlyIn: record.session.workingDirectory)
        }
    }

    // MARK: Build

    public func build(_ request: RemoraPackRequest, settings: RemoraPackSettings = RemoraPackSettings(),
                      memory: RemoraMemoryShare = RemoraMemoryShare(), today: RemoraUsage.Day,
                      now: Date = Date(), timeZone: TimeZone = .current) async throws -> RemoraPack {
        let candidates = try await candidateSessions(request, settings)
        let picked = pick(request, from: candidates)
        let excerpts = await read(picked)
        try Task.checkCancellation()
        var layout = PackLayout(
            request: request, settings: settings, memory: memory, today: today, now: now, stamps: Stamps(timeZone),
            candidates: candidates,
            picks: zip(picked, excerpts).map { PackLayout.Pick(summary: $0, excerpt: $1) },
            limits: limits)
        layout.fit(toTokens: request.kind == .question ? limits.questionTokens : limits.briefTokens)
        return layout.pack()
    }

    // MARK: Which sessions

    /// The sessions the pack may name, newest first: the scope's, minus the excluded projects' (never listed, whatever
    /// the scope), and for a brief only those active since.
    private func candidateSessions(_ request: RemoraPackRequest, _ settings: RemoraPackSettings) async throws -> [SessionSummary] {
        var project: UUID?
        var only: UUID?
        var since: Date?
        switch request {
        case let .question(_, scope, _):
            switch scope {
            case .allProjects: break
            case let .project(id): project = id
            case let .session(id): only = id
            }
        case let .brief(date):
            since = date
        }
        if let project, settings.excludedProjects.contains(project) { return [] }
        let all = try await sessions(SessionQuery(project: project, limit: SessionQuery.maxLimit))
        return all
            .filter { summary in
                if let id = summary.projectID, settings.excludedProjects.contains(id) { return false }
                if let only, summary.id != only { return false }
                if let since, summary.lastActivityAt < since { return false }
                return true
            }
            .sorted(by: Self.newestFirst)
    }

    private static func newestFirst(_ left: SessionSummary, _ right: SessionSummary) -> Bool {
        left.lastActivityAt != right.lastActivityAt ? left.lastActivityAt > right.lastActivityAt : left.id.uuidString > right.id.uuidString
    }

    /// The sessions whose transcript is read, most relevant first. Codex sessions are listed, never read (D-28).
    private func pick(_ request: RemoraPackRequest, from candidates: [SessionSummary]) -> [SessionSummary] {
        let readable = candidates.filter { $0.harness == .claude }
        switch request {
        case let .question(text, scope, _):
            if case .session = scope { return Array(readable.prefix(1)) }
            let words = Self.keywords(of: text)
            func score(_ summary: SessionSummary) -> Int {
                let haystack = ((summary.title ?? "") + " " + (summary.projectName ?? "")).lowercased()
                return words.filter { haystack.contains($0) }.count
            }
            let scored = readable.map { ($0, score($0)) }
            return scored.sorted { left, right in
                left.1 != right.1 ? left.1 > right.1 : Self.newestFirst(left.0, right.0)
            }.prefix(limits.pickedSessions).map(\.0)
        case .brief:
            // The projects that moved, at most `briefProjects` of them (a session without a project is one group), newest first.
            var newestOfProject: [UUID?: Date] = [:]
            for summary in readable { newestOfProject[summary.projectID] = max(newestOfProject[summary.projectID] ?? .distantPast, summary.lastActivityAt) }
            let subjects = Set(newestOfProject.sorted { $0.value > $1.value }.prefix(limits.briefProjects).map(\.key))
            return Array(readable.filter { subjects.contains($0.projectID) }.prefix(limits.pickedSessions))
        }
    }

    static func keywords(of text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 3 && seen.insert($0).inserted }
    }

    // MARK: Reading

    /// The excerpt of each pick, in the picks' order; nil where the transcript could not be read. Reads run off the main
    /// actor and side by side (a handful of small files).
    private func read(_ picks: [SessionSummary]) async -> [RemoraExcerpt?] {
        let transcript = transcript
        let bytes = limits.excerptBytes
        return await withTaskGroup(of: (Int, RemoraExcerpt?).self) { group in
            for (index, summary) in picks.enumerated() {
                group.addTask {
                    guard let file = await transcript(summary) else { return (index, nil) }
                    return (index, await Self.load(file, textBytes: bytes))
                }
            }
            var result = [RemoraExcerpt?](repeating: nil, count: picks.count)
            for await (index, excerpt) in group { result[index] = excerpt }
            return result
        }
    }

    @concurrent
    private static func load(_ file: ClaudeTranscriptFile, textBytes: Int) async -> RemoraExcerpt? {
        RemoraTranscriptReading.read(file, textBytes: textBytes)
    }
}

/// Local date and time, formatted the way the pack writes them.
struct Stamps {
    let timeZone: TimeZone
    private let calendar: Calendar

    init(_ timeZone: TimeZone) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    func stamp(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0)
    }

    func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}
