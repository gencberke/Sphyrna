import Foundation
import LoomCore

/// Builds the pack of one call: a bounded, masked text Sphyrna writes fresh for every question and every brief (design/
/// DESIGN.md §20; LOMBOT §2, §3.4, §3.5, §5).
///
/// The layout, in the order of the prompt cache (D-84, D-85: what changes least comes first; the rules, the system prompt
/// of the call, come before all of it):
///
///     <memory>      the stable memory (Remora.md, project notes), when there is any
///     <self>        what Remora is and cannot see: fixed lines only
///     <sessions>    the index: id, title, project and harness of the newest rows, written in id order
///     <excerpt>     the tail of each picked session, the one that moved last at the end
///     <journal>     the recent journal lines, newest last (one is added after every call)
///     <previous>    the last question and answer (follow-ups)
///     <activity>    the index's moving fields: state, last activity, in order of last activity
///     <now>         local date and time, today's calls and tokens   (changes on every call)
///     <question>    or <request> for the brief
///
/// Nothing before `<now>` depends on the clock. On an unchanged catalog a brief and a question write `<memory>`, `<self>`
/// and `<sessions>` byte for byte alike: the index lists the same sessions whoever asks (the brief's `since` only chooses
/// which sessions are read), and nothing a session does or a call does with it is written there, so one session's change
/// alters its row of `<activity>` and its excerpt, never the index.
///
/// Everything inside `<sessions>`, `<activity>`, `<excerpt>`, `<previous>`, `<journal>` and `<memory>` is data; the rules (`RemoraRules`) say so.
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
        let (picked, added) = pick(request, from: candidates)
        let excerpts = await read(picked)
        try Task.checkCancellation()
        var layout = PackLayout(
            request: request, settings: settings, memory: memory, today: today, now: now, stamps: Stamps(timeZone),
            candidates: candidates,
            picks: zip(picked, excerpts).map { PackLayout.Pick(summary: $0, excerpt: $1, isNew: added.contains($0.id)) },
            limits: limits)
        layout.fit(toTokens: request.kind == .question ? limits.questionTokens : limits.briefTokens)
        return layout.pack()
    }

    // MARK: Which sessions

    /// The sessions the pack may name, newest first: the scope's, minus the excluded projects' (never listed, whatever
    /// the scope). A brief's `since` does not narrow them (that would make its index differ from a question's): it only
    /// chooses what is read.
    private func candidateSessions(_ request: RemoraPackRequest, _ settings: RemoraPackSettings) async throws -> [SessionSummary] {
        var project: UUID?
        var only: UUID?
        switch request {
        case let .question(_, scope, _):
            switch scope {
            case .allProjects: break
            case let .project(id): project = id
            case let .session(id): only = id
            }
        case let .draft(id):
            project = id
        case .brief:
            break
        }
        if let project, settings.excludedProjects.contains(project) { return [] }
        let all = try await sessions(SessionQuery(project: project, limit: SessionQuery.maxLimit))
        return all
            .filter { summary in
                if let id = summary.projectID, settings.excludedProjects.contains(id) { return false }
                if let only, summary.id != only { return false }
                return true
            }
            .sorted(by: Self.newestFirst)
    }

    private static func newestFirst(_ left: SessionSummary, _ right: SessionSummary) -> Bool {
        left.lastActivityAt != right.lastActivityAt ? left.lastActivityAt > right.lastActivityAt : left.id.uuidString > right.id.uuidString
    }

    /// The sessions whose transcript is read, most relevant first, and which of them a follow-up added to the last pack's.
    /// Codex sessions are listed, never read (D-28).
    private func pick(_ request: RemoraPackRequest, from candidates: [SessionSummary]) -> (picked: [SessionSummary], added: Set<UUID>) {
        let readable = candidates.filter { $0.harness == .claude }
        switch request {
        case let .question(text, scope, previous):
            if case .session = scope { return (Array(readable.prefix(1)), []) }
            let words = Self.keywords(of: text)
            func score(_ summary: SessionSummary) -> Int {
                let haystack = ((summary.title ?? "") + " " + (summary.projectName ?? "")).lowercased()
                return words.filter { haystack.contains($0) }.count
            }
            let scored = readable.map { ($0, score($0)) }.sorted { left, right in
                left.1 != right.1 ? left.1 > right.1 : Self.newestFirst(left.0, right.0)
            }
            // A follow-up keeps what the last pack read, in its order, so those excerpts are written as before (and a prompt
            // cache can read them); the question's own matches come after, only when they match something.
            if let previous, !previous.sessions.isEmpty {
                let byID = Dictionary(readable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let earlier = previous.sessions.compactMap { byID[$0] }.prefix(limits.pickedSessions)
                let have = Set(earlier.map(\.id))
                let added = scored.filter { $0.1 > 0 && !have.contains($0.0.id) }.prefix(limits.followUpPicks).map(\.0)
                return (Array(earlier) + added, Set(added.map(\.id)))
            }
            return (scored.prefix(limits.pickedSessions).map(\.0), [])
        case .draft:
            // The project's most recent sessions (the candidates are only the project's, newest first).
            return (Array(readable.prefix(limits.pickedSessions)), [])
        case let .brief(since):
            // The projects that moved, at most `briefProjects` of them (a session without a project is one group), newest first.
            let readable = readable.filter { $0.lastActivityAt >= since }
            var newestOfProject: [UUID?: Date] = [:]
            for summary in readable { newestOfProject[summary.projectID] = max(newestOfProject[summary.projectID] ?? .distantPast, summary.lastActivityAt) }
            let subjects = Set(newestOfProject.sorted { $0.value > $1.value }.prefix(limits.briefProjects).map(\.key))
            return (Array(readable.filter { subjects.contains($0.projectID) }.prefix(limits.pickedSessions)), [])
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
