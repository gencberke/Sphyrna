import Foundation

/// How wide a question looks.
public enum RemoraScope: Equatable, Sendable {
    case allProjects
    case project(UUID)
    case session(UUID)
}

/// The question before and Remora's visible answer to it, for a follow-up.
public struct RemoraExchange: Equatable, Sendable {
    public var question: String
    public var answer: String
    /// The sessions that pack read (`RemoraPack.readSessionIDs`), in its order: the follow-up reads them again, in the same
    /// order, before any session of its own.
    public var sessions: [UUID]

    public init(question: String, answer: String, sessions: [UUID] = []) {
        self.question = question
        self.answer = answer
        self.sessions = sessions
    }
}

public enum RemoraPackRequest: Equatable, Sendable {
    case question(String, scope: RemoraScope, previous: RemoraExchange?)
    /// The morning brief: what moved since `since`.
    case brief(since: Date)

    var kind: RemoraKind {
        switch self {
        case .question: .question
        case .brief: .brief
        }
    }
}

/// The settings that shape a pack.
public struct RemoraPackSettings: Equatable, Sendable {
    /// Sessions of these projects never appear in a pack, not even for "All projects".
    public var excludedProjects: Set<UUID>
    /// Shown on the self card (the call's own arguments are `RemoraRequest`'s).
    public var model: String
    public var effort: String

    public init(excludedProjects: Set<UUID> = [], model: String = "sonnet", effort: String = "low") {
        self.excludedProjects = excludedProjects
        self.model = model
        self.effort = effort
    }
}

/// The part of Remora's memory a pack carries, in two parts because they change at different rates (D-85): a cached prefix
/// is only as long as what comes before the first change, and one journal line is added after every call. L2 fills both.
public struct RemoraMemoryShare: Equatable, Sendable {
    /// The stable part: `Remora.md` and the project notes, which change when the user or Remora edits them. The builder puts
    /// it first, in `<memory>`, in the pack's stable prefix.
    public var text: String
    /// The recent part: today's and yesterday's journal lines, oldest first, newest last. It goes late, in its own
    /// `<journal>` block just before `<previous>`, so a new line does not break the cache of anything before it.
    public var recent: String
    /// How many project notes `text` holds, for the footer ("read 6 sessions and 3 project notes").
    public var projectNotes: Int

    public init(text: String = "", recent: String = "", projectNotes: Int = 0) {
        self.text = text
        self.recent = recent
        self.projectNotes = projectNotes
    }
}

/// The sizes and counts a pack is built within. `standard` is the product's; a test passes smaller ones to reach a
/// budget with a small workspace.
public struct RemoraPackLimits: Equatable, Sendable {
    public var questionTokens = 14_000
    public var briefTokens = 30_000
    public var pickedSessions = 8
    public var indexRows = 40
    /// Text kept per session before the budget shortens it.
    public var excerptBytes = RemoraTranscriptReading.textBytes
    /// The budget never shortens an excerpt below this.
    public var minimumExcerptBytes = 512
    /// Over budget, excerpts are dropped one by one down to this many; the rest of the trimming comes first, then the last go.
    public var keptWholeExcerpts = 3
    /// The brief's subject: this many projects that moved.
    public var briefProjects = 3
    /// A follow-up reads at most this many sessions besides the ones the last pack read (only ones its words match).
    public var followUpPicks = 3

    public static let standard = RemoraPackLimits()

    public init() {}
}

/// What a pack read, for the footer: "read 6 sessions and 3 project notes".
public struct RemoraPackFacts: Equatable, Sendable {
    public var sessionsRead: Int
    /// Sessions picked whose transcript could not be read (named as unread in the pack).
    public var sessionsUnread: Int
    public var projectNotes: Int

    public var text: String {
        func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }
        var line = "read \(count(sessionsRead, "session")) and \(count(projectNotes, "project note"))"
        if sessionsUnread > 0 { line += "; \(count(sessionsUnread, "session")) could not be read" }
        return line
    }
}

/// A pack: the text for stdin and what is known about it.
public struct RemoraPack: Equatable, Sendable {
    public var kind: RemoraKind
    public var text: String
    /// `<memory>`, `<self>` and `<sessions>`, the start of `text`: byte-identical between two packs built on the same
    /// catalog (the sessions listed, not what they are doing) with the same settings and stable memory, whoever asks (brief
    /// or question), whatever the time.
    public var stablePrefix: String
    /// The sessions whose excerpt is in the pack, most relevant first (the excerpts are written in order of last activity).
    public var readSessionIDs: [UUID]
    /// Every session the pack names (index and excerpts): the ids an answer's block may cite.
    public var namedSessionIDs: Set<UUID>
    /// Characters / 4, counted in UTF-8 bytes.
    public var estimatedTokens: Int
    public var facts: RemoraPackFacts
    /// Excerpts the budget left out, in the order they went.
    public var droppedExcerpts: [UUID]
    /// The per-session text cap the remaining excerpts ended with.
    public var excerptBytes: Int
    /// Index rows the budget (or the row limit) left out.
    public var omittedIndexRows: Int

    public var stablePrefixTokens: Int { RemoraPack.estimate(stablePrefix) }

    /// What follows the stable prefix.
    public var afterStablePrefix: String { String(decoding: text.utf8.dropFirst(stablePrefix.utf8.count), as: UTF8.self) }

    /// The call for this pack, in the layout L1c's probe kept (D-84): the stable prefix goes into the system prompt after
    /// the rules (a file, `RemoraRequest.systemSuffix`), the rest is stdin. The API matches a cached prefix at a content
    /// block boundary and the CLI sends stdin as one block, so a stable prefix inside stdin was never read back (842 of
    /// 17,000 tokens); in the system prompt the next call on the same catalog reads it (4,193).
    public func request(model: String = "sonnet", effort: String = "low") -> RemoraRequest {
        RemoraRequest(kind: kind, model: model, effort: effort, pack: afterStablePrefix,
                      knownSessionIDs: Set(namedSessionIDs.map(\.uuidString)), systemSuffix: stablePrefix)
    }

    static func estimate(_ text: String) -> Int { (text.utf8.count + 3) / 4 }
}
