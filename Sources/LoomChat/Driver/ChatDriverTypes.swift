import Foundation
import LoomCore

/// Where a Chat-face session stands (concept §5.6, corrected by spike S1 §D1). "Finished" is not a phase: it is a
/// finished turn nobody has read, which the event hub derives from the `turnComplete` the driver publishes.
public enum ChatDriverPhase: Sendable, Equatable {
    /// No process. Sending resumes the session (`--resume`).
    case stopped
    /// The child is spawning, or it has not answered `initialize` yet.
    case starting
    /// `initialize` answered and no turn runs: the composer is free.
    case ready
    /// A turn runs: from a send (or a turn the CLI started itself) to the main thread's `result`.
    case working
    /// A turn waits for the user: at least one request (approval, question, plan) is pending.
    case needsYou
    /// Stop, Quit or a face switch is under way: interrupt, wait for the result, close stdin, wait for the exit.
    case stopping
    /// The child could not start, or it ended without Loom stopping it. Sending resumes the session.
    case failed(ChatFailure)

    /// A process lives and takes input.
    public var isLive: Bool {
        switch self {
        case .starting, .ready, .working, .needsYou: true
        case .stopped, .stopping, .failed: false
        }
    }
}

public enum ChatFailure: Sendable, Equatable {
    /// The launch failed (the runtime's issue says why). The terminal face is the fallback (concept §5.6).
    case couldNotStart(String)
    /// The child never answered `initialize`.
    case notReady
    /// The child ended on its own: a crash, a kill, an exit Loom did not ask for.
    case ended
}

/// When a message goes out. CHAT-SPEC → Keys: ↵ is `next` (read after the running tool; cancels nothing), ⌘↵ waits in
/// Loom's own queue for the turn's end. `now` is only "Read now" (`readNow`).
public enum ChatSendTiming: Sendable, Equatable {
    case next
    case afterTurn
}

public enum ChatSendReceipt: Sendable, Equatable {
    /// Written to the CLI with this uuid: the row of the message in the model, and the id `command_lifecycle` names.
    case sent(String)
    /// Kept in Loom's queue with this id.
    case queued(String)
}

/// A message the CLI held unread when an interrupt (or a Stop) cancelled it: its text goes back to the composer.
public struct ChatReturnedDraft: Sendable, Equatable {
    public var messageID: String
    public var text: String
}

/// A `can_use_tool` request that waits for the user. The driver never answers one by itself, in any mode (CHAT-SPEC →
/// Requests). It retires only on its own request id (an answer, the CLI withdrawing it) or its own `tool_use_id` (the
/// tool's result arrived), or when the process ends.
public struct ChatPendingRequest: Sendable, Equatable, Identifiable {
    public var id: String { requestID }
    public let requestID: String
    public let request: ToolPermissionRequest
    public let arrivedAt: Date

    public var kind: Kind {
        switch request.toolName {
        case "AskUserQuestion": .question
        case "ExitPlanMode": .plan
        default: .approval
        }
    }

    public enum Kind: Sendable, Equatable {
        case approval
        case question
        case plan
    }

    /// The provider-independent summary the event hub carries (`ProviderPendingRequest`).
    public var summary: ProviderPendingRequest {
        let kind: ProviderPendingRequest.Kind
        let text: String
        switch self.kind {
        case .approval:
            kind = .approval
            text = request.title ?? request.displayName ?? request.description ?? request.toolName
        case .question:
            kind = .question
            let first = request.input["questions"]?.array?.first
            text = first?["header"]?.string ?? first?["question"]?.string ?? "Question"
        case .plan:
            kind = .plan
            text = "Plan ready"
        }
        return ProviderPendingRequest(requestID: requestID, toolUseID: request.toolUseID, kind: kind,
                                      toolName: request.toolName, summary: text, arrivedAt: arrivedAt)
    }
}

/// Something about the wire this build did not expect (CHAT-SPEC → Lifecycle additions → Drift signals). One notice per
/// session per signal: the stream view shows the first unknown record once, and nothing here holds content.
public enum ChatDrift: Sendable, Equatable {
    /// A record of a type or subtype this build does not know; it is kept as a raw row.
    case unknownRecord(type: String?, subtype: String?)
    /// `system/init` lists capabilities, and one the driver relies on is not among them.
    case missingCapability(String)
    /// An API error category on `assistant.error`, or a `result` with `terminal_reason: api_error` (S1 §D16). A safety
    /// refusal is not drift.
    case apiError(category: String?, status: Int?)
}

/// A sign that the headless surface may not be usable under the user's plan (concept §5.8): `billing_error` or
/// `oauth_org_not_allowed` on an assistant error or an API retry. The UI offers "Continue in terminal" (V19).
public struct ChatPolicySignal: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case assistantError
        case apiRetry
    }

    public var category: String
    public var source: Source

    public init(category: String, source: Source) {
        self.category = category
        self.source = source
    }

    public static let categories: Set<String> = ["billing_error", "oauth_org_not_allowed"]
}

/// A driver's live model changes (`ChatSessionDriver.modelChanges`): a `ModelChangeSource`.
public struct ChatModelChanges: ModelChangeSource {
    public let changes: AsyncStream<ModelChange>

    public init(changes: AsyncStream<ModelChange>) { self.changes = changes }
}

/// What a live chat stream follows besides the rows: the card, the work state, the newest stdout line, the notices.
public struct ChatLiveState: Sendable, Equatable {
    /// The card the driver's run is on now: a `/clear` moves it to a new one.
    public var sessionID: UUID
    /// The Claude conversation the run is in (its transcript's name), once known.
    public var conversationID: String?
    public var phase: ChatDriverPhase
    public var turnRunning: Bool
    /// When the last stdout line arrived: the live row's 40 s no-activity rule reads it.
    public var lastActivity: Date?
    public var drift: [ChatDrift]
    public var policySignal: ChatPolicySignal?
    /// Where the newest run began in the live model: what came before it is in the transcript too.
    public var runStart: LiveHistoryJoin.RunStart

    public init(sessionID: UUID, conversationID: String? = nil, phase: ChatDriverPhase = .stopped, turnRunning: Bool = false,
                lastActivity: Date? = nil, drift: [ChatDrift] = [], policySignal: ChatPolicySignal? = nil,
                runStart: LiveHistoryJoin.RunStart = LiveHistoryJoin.RunStart()) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.phase = phase
        self.turnRunning = turnRunning
        self.lastActivity = lastActivity
        self.drift = drift
        self.policySignal = policySignal
        self.runStart = runStart
    }
}

/// What the live chat view reads from a driver: its model changes, a snapshot when it missed one, the live state and when
/// that changed. `ChatSessionDriver` is the one in the app; tests script one.
public protocol ChatLiveSource: AnyObject, Sendable {
    func modelChanges() async -> ChatModelChanges
    func snapshotChange() async -> ModelChange
    func liveState() async -> ChatLiveState
    func updates() async -> AsyncStream<Void>
}

extension ChatSessionDriver: ChatLiveSource {}

/// Everything a view needs from a driver at one moment. Reading it changes nothing (the rows that changed come with
/// `modelChanges`).
public struct ChatDriverSnapshot: Sendable {
    /// The card the driver's run is on now: a `/clear` moves it to a new one.
    public var sessionID: UUID
    public var phase: ChatDriverPhase
    public var model: TurnModel
    public var runID: UUID?
    /// The child's pid while a run lives (diagnostics and tests).
    public var processID: Int32?
    /// The mode the CLI runs in now: `initialize`, then `system/init` and `system/status` (S2: never the transcript).
    public var permissionMode: String?
    /// The session's mode, model and effort as Loom passes them on the next spawn.
    public var choices: ClaudeLaunchChoices
    public var requests: [ChatPendingRequest]
    public var queue: ChatQueue
    /// Why the queue is not as it should be. Shown where the queue is; cleared by the next change that works.
    public var queueIssue: ChatQueueIssue?
    /// Background tasks of the run (a Bash moved to the background, a background subagent): work that outlives the
    /// turn.
    public var backgroundTaskCount: Int
    public var returnedDrafts: [ChatReturnedDraft]
    public var drift: [ChatDrift]
    public var policySignal: ChatPolicySignal?
    /// When the last stdout line arrived, on Loom's clock: the 40 s no-activity rule reads it (S1 §D13).
    public var lastActivity: Date?
    /// `modelUsage.<model>.contextWindow` of the newest results, keyed as the context ring keys windows.
    public var contextWindows: [String: Int]
    /// A turn runs (from a send, or a turn the CLI started) until its `result`; also while a request waits.
    public var turnRunning: Bool
}

/// What went wrong with the "After this turn" queue (CHAT-SPEC → Queue); the composer shows it beside the queue.
public enum ChatQueueIssue: Sendable, Equatable {
    /// The queue could not be written to its file (the error's category): it lives in memory until a save works.
    case notSaved(String)
    /// The saved queue could not be read when its driver was made; the file was set aside under this name.
    case unreadable(keptAs: String?)
    /// The next item could not be sent (the error's category); it is back at the head of the queue.
    case notSent(String)
}
