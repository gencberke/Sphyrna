import Foundation
import LoomCore

/// Which line of work an entry belongs to: the main conversation, or a subagent's (by the `tool_use_id` of the Agent
/// call that started it).
public enum ChatThread: Hashable, Sendable {
    case main
    case subagent(String)
}

/// One row of the session's chronological list. `id` is stable: the API message id with the block index, a user
/// message's uuid, or a `tool_use_id`, so a streaming update replaces one row and no other. The same ids come out of
/// the live stream and the transcript, so a session keeps its rows when the source changes.
public struct ChatEntry: Identifiable, Equatable, Sendable {
    public var id: String
    /// The id of the turn this entry is in.
    public var turnID: String
    public var thread: ChatThread
    public var timestamp: Date?
    /// Where the line lies in its transcript, when it came from one: "Show all" and an oversized line read it again.
    public var sourceOffset: UInt64?
    public var body: Body

    public enum Body: Equatable, Sendable {
        case user(UserPrompt)
        case assistantText(AssistantText)
        case thinking(Thinking)
        /// A tool call with its result, updated in place. Agent calls are `.subagent` and ExitPlanMode is `.plan`.
        case tool(ToolCall)
        case subagent(SubagentRun)
        case plan(PlanDocument)
        /// A card the user answered (an approval, a question, a plan decision), recorded by the driver.
        case request(RequestRecord)
        case marker(Marker)
        case unknown(RawRecord)
    }
}

// MARK: Bodies

public struct UserPrompt: Equatable, Sendable {
    /// Three facts, from `command_lifecycle` and the echo (S1): the CLI has it (`queued`), Claude read it (`started`, and
    /// the `isReplay` echo, which can come seconds or minutes later), and it was dropped unread (`cancelled`). Without
    /// `msg_lifecycle_v1` only the echo exists, and `.queued` is skipped.
    public enum Delivery: Sendable, Equatable {
        /// Written to stdin; nothing came back yet.
        case pending
        /// `command_lifecycle queued`: the CLI holds it, unread.
        case queued
        /// Claude read it. Everything from a transcript is read.
        case read
        /// `command_lifecycle cancelled`: dropped unread (an interrupt with `cancel_queued`, or `cancel_async_message`).
        case cancelled
        /// The process ended before the CLI took it.
        case notDelivered
    }

    public struct Command: Equatable, Sendable {
        public var name: String
        public var arguments: String
    }

    public var text: String
    public var images: [ImageRef]
    public var delivery: Delivery
    /// A slash command the user ran (`/review src`); `text` then reads like what was typed.
    public var command: Command?
    /// A subagent transcript's first message: the task the parent gave.
    public var isBrief: Bool
    /// What became of a message that was not delivered, once the user (or Loom, at the user's word) took care of it: its
    /// row then offers neither Retry nor Copy.
    public enum FollowUp: Sendable, Equatable {
        /// "Retry" sent it again as a new message.
        case sentAgain
        /// The send failed and the text went back to where it came from (the composer, the queue).
        case handedBack
    }

    public var followUp: FollowUp?
    /// A turn was running when it was sent: only then does a message wait "for the current step" (an idle send's echo can
    /// take a moment too, and then nothing waits).
    public var sentWhileWorking = false
    /// The typed text alone (the row's text also carries pasted chips): what ↑ recalls.
    public var recallText: String?
}

public struct AssistantText: Equatable, Sendable {
    public var text: String
    public var isStreaming: Bool
}

/// A thinking block. Thinking stays thinking and text stays text: S1 found that the narrative before a tool call is an
/// ordinary text block of the same message, with no marker anywhere, so nothing is promoted or demoted by position.
/// Without `--thinking-display summarized` the text is empty (only a signature and a duration arrive).
public struct Thinking: Equatable, Sendable {
    public var text: String
    public var isStreaming: Bool
    /// `redacted_thinking`, or a block whose text is not shown: "Thinking (hidden)".
    public var isHidden: Bool
    /// Transcripts record only how long Claude thought.
    public var durationMs: Double?
}

public struct LineChanges: Equatable, Sendable {
    public var added: Int
    public var removed: Int
}

public struct ToolCall: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case running
        case succeeded
        /// `is_error`, or a command that exited non-zero.
        case failed
        /// The user denied it (or a rule did).
        case denied
        /// Ask mode refused it, as it is meant to: the session is read-only, so this is no failure and no denial.
        case refusedInAsk
        /// The turn ended before it finished.
        case interrupted
    }

    public var id: String
    public var name: String
    /// The call's input, with strings over 64 KiB cut.
    public var input: JSONValue
    public var status: Status
    public var output: ClippedText?
    public var images: [ImageRef]
    /// A shell command's exit code, from the result text ("Exit code 2"): there is no field for it. A grep or diff that
    /// exits 1 is not an error.
    public var exitCode: Int?
    /// Lines added and removed by an Edit or Write, from the result's `structuredPatch` (a Write that creates a file has an
    /// empty patch, so its lines are counted from `content`).
    public var changes: LineChanges?
    public var startedAt: Date?
    public var endedAt: Date?
}

public struct SubagentRun: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case running
        case succeeded
        case failed
        case interrupted
    }

    /// The `tool_use_id` of the Agent call (also the entry id).
    public var toolUseID: String
    public var description: String
    public var subagentType: String?
    /// What the parent asked, cut to 4 KiB.
    public var prompt: String
    public var status: Status
    /// The agent's answer.
    public var result: ClippedText?
    /// Its latest words while it works (live streams only; a subagent's own transcript has the rest).
    public var latestProgress: String?
    /// Names the agent's transcript file, once the result says.
    public var agentID: String?
    public var startedAt: Date?
    public var endedAt: Date?
}

public struct PlanDocument: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case proposed
        case approved
        case rejected
    }

    public var toolUseID: String
    public var markdown: String
    public var filePath: String?
    public var status: Status

    /// The first heading, without its marks.
    public var title: String? {
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { return trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}

/// The one line the stream keeps of a card the user answered.
public struct RequestRecord: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case approval
        case question
        case plan
    }

    public var kind: Kind
    /// For example "Allowed once: git push origin fix/webhook-sig".
    public var summary: String

    public init(kind: Kind, summary: String) {
        self.kind = kind
        self.summary = summary
    }
}

public enum Marker: Equatable, Sendable {
    public enum Face: Equatable, Sendable {
        case continuedInTerminal
        case backInChat
    }

    case sessionStart(model: String?, permissionMode: String?)
    case resumed(secondsSinceLastActivity: Double?)
    case compaction(trigger: String?, preTokens: Int?, postTokens: Int?)
    case reset(trigger: String?)
    /// The user stopped the turn.
    case interrupted(afterMs: Double?)
    case retry(attempt: Int?, maxRetries: Int?, error: String?)
    case modeChanged(String)
    case modelChanged(String)
    case face(Face)
    /// Output of a local command (`/context`, `!ls`) or a system notice.
    case notice(String)
}

/// A record kept as it came: a type this build does not know, a line over the size limit, or a line that is not
/// JSON. The renderer shows it as a collapsed row, and one drift notice per session.
public struct RawRecord: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case unknownType
        /// Not read or parsed: `byteCount` says how long it is, and the entry's `sourceOffset` where to read it.
        case oversized
        case malformed
    }

    public var reason: Reason
    public var type: String?
    public var subtype: String?
    /// The record's JSON, cut to `maximumJSONBytes`; empty for an oversized line.
    public var json: String
    /// The whole record's length in bytes (0 when unknown).
    public var byteCount: Int
    public var isTruncated: Bool

    public static let maximumJSONBytes = 64 * 1024
}

// MARK: Turns

public struct ChatTurn: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Live: the user message went out (or work began) and the main thread's `result` has not come.
        case running
        /// A transcript's newest turn: no later prompt has shown that it ended.
        case open
        /// A transcript turn that ended at the next human prompt.
        case ended
        case succeeded
        /// A `result` with an error subtype or `is_error`; the associated value is the subtype.
        case failed(String)
        /// The user stopped it.
        case interrupted
    }

    public var id: String
    public var status: Status
    public var startedAt: Date?
    public var endedAt: Date?
    /// False for a turn whose beginning lies before what was read (or for work that began without a prompt).
    public var hasUserPrompt: Bool
    public var firstEntryID: String
    /// The `result` that ended the turn (live streams only).
    public var result: TurnResult?

    /// `result.duration_ms`, else from the timestamps.
    public var durationMs: Double? {
        if let value = result?.durationMs { return value }
        guard let startedAt, let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt) * 1000
    }

    public var isRunning: Bool { status == .running }
}

/// What a change touched, so a view replaces only those rows.
public struct ModelDelta: Equatable, Sendable {
    public var inserted: [String] = []
    public var updated: [String] = []
    public var turnsChanged = false

    public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && !turnsChanged }

    public init() {}

    mutating func noteInserted(_ id: String) { inserted.append(id) }

    mutating func noteUpdated(_ id: String) {
        if !inserted.contains(id), !updated.contains(id) { updated.append(id) }
    }

    mutating func merge(_ other: ModelDelta) {
        inserted.append(contentsOf: other.inserted)
        for id in other.updated { noteUpdated(id) }
        turnsChanged = turnsChanged || other.turnsChanged
    }
}
