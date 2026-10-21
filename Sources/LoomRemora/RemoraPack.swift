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

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
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

/// The part of Remora's memory a pack carries (journal lines, project notes, `Remora.md`). L2 fills it; the builder puts
/// `text` first in the pack, where it belongs in the stable prefix, and counts `projectNotes` for the footer.
public struct RemoraMemoryShare: Equatable, Sendable {
    public var text: String
    public var projectNotes: Int

    public init(text: String = "", projectNotes: Int = 0) {
        self.text = text
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
    /// The memory share and the self card's fixed lines: byte-identical between two packs built on the same day with the
    /// same settings and memory, and the start of `text`.
    public var stablePrefix: String
    /// The sessions whose excerpt is in the pack, most relevant first.
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

    /// The call for this pack.
    public func request(model: String = "sonnet", effort: String = "low") -> RemoraRequest {
        RemoraRequest(kind: kind, model: model, effort: effort, pack: text,
                      knownSessionIDs: Set(namedSessionIDs.map(\.uuidString)))
    }

    static func estimate(_ text: String) -> Int { (text.utf8.count + 3) / 4 }
}
