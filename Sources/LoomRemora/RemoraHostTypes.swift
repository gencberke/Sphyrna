import Foundation

/// A call's answer as the host hands it to the app: the answer, the facts it proposes, and what the pack read.
public struct RemoraHostAnswer: Equatable, Sendable {
    public var kind: RemoraKind
    /// The question; nil for a brief.
    public var question: String?
    public var answer: RemoraAnswer
    /// Facts the answer proposes that `Remora.md` does not hold yet, for "Remember this?". Empty when proposals are off.
    public var proposedFacts: [String]
    /// The sessions the pack read, in its order.
    public var readSessionIDs: [UUID]
    /// "read 6 sessions and 3 project notes".
    public var footer: String
    /// False when the journal line or a note could not be written (the answer stands).
    public var journaled: Bool

    /// What a follow-up question carries as `previous`; nil for a brief.
    public var exchange: RemoraExchange? {
        question.map { RemoraExchange(question: $0, answer: answer.text, sessions: readSessionIDs) }
    }
}

/// How `ask`, `brief` and `briefIfDue` end. Nothing is thrown past the host.
public enum RemoraOutcome: Equatable, Sendable {
    case answered(RemoraHostAnswer)
    /// "Remember …" saved the fact to `Remora.md`; no call was made. The token takes the line out again.
    case remembered(fact: String, undo: RemoraUndoToken)
    /// "Remember …" could not be saved; the line says why (it is `RemoraDurableNote.Refusal.reason`).
    case notSaved(String)
    case failed(RemoraFailure)
    /// Stopped by the user.
    case cancelled
    /// Another call is running; nothing was started.
    case busy
    /// Remora is off in Settings; nothing was started.
    case off
    /// `briefIfDue` decided not to run, and why; nothing was recorded.
    case notDue(RemoraBriefDecision)
}

/// What the calls used (Settings' "Use" line): today, the last days with any use, and the calls whose cache write drifted.
public struct RemoraUsageSnapshot: Equatable, Sendable {
    public var today: RemoraUsage.Day
    /// The last 14 days with any use, today's included, oldest first.
    public var days: [RemoraUsage.Day]
    /// Calls in the kept days in which the CLI ignored the five-minute cache key (D-86); today's are `today.cacheDriftCalls`.
    public var cacheDriftCalls: Int { days.reduce(0) { $0 + $1.cacheDriftCalls } }
}

/// A project's note with the project's name, for the notes list.
public struct RemoraHostNote: Equatable, Sendable {
    public var project: UUID
    public var name: String?
    public var note: RemoraProjectNote
}
