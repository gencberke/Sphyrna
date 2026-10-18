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
/// Loom's own queue for the turn's end. `now` is "Read now" (`readNow`), never a send of its own.
public enum ChatSendTiming: Sendable, Equatable {
    case next
    case afterTurn
}

/// Something that goes out with a message besides its text (CHAT-SPEC → Attachments). Images are image blocks; a large
/// paste is a text block of its own, in the same message. A file is an `@path` in the text, not an attachment.
public enum ChatOutgoingAttachment: Sendable, Equatable {
    case image(mediaType: String, base64: String)
    case pastedText(String)
}

/// What Loom wrote to the CLI as one message: its text, then its attachments' text blocks, and its images.
struct ChatSentMessage: Sendable, Equatable {
    var text: String
    var attachments: [ChatOutgoingAttachment]

    /// Text first, then each pasted text, then the images (a model reads images before the words about them, but the
    /// CLI keeps the order as sent; the row shows them above the text anyway).
    var blocks: [OutgoingUserMessage.Block] {
        var blocks: [OutgoingUserMessage.Block] = []
        for case let .image(mediaType, base64) in attachments { blocks.append(.image(mediaType: mediaType, base64: base64)) }
        if !text.isEmpty { blocks.append(.text(text)) }
        for case let .pastedText(pasted) in attachments where !pasted.isEmpty { blocks.append(.text(pasted)) }
        return blocks
    }

    /// What the row of the message reads: the typed text, then the pasted ones (the echo joins the text blocks).
    var rowText: String {
        ([text] + attachments.compactMap { if case let .pastedText(pasted) = $0 { pasted } else { nil } })
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var images: [ImageRef] {
        attachments.compactMap {
            if case let .image(mediaType, base64) = $0 {
                ImageRef(mediaType: mediaType, byteCount: base64.utf8.count, data: base64)
            } else { nil }
        }
    }
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
    /// Its images and pasted text come back with it.
    public var attachments: [ChatOutgoingAttachment] = []
    /// When the driver wrote it into the session's draft file (nil: not written). A composer made after that moment
    /// restored it from the file already and must not take it again.
    public var persistedAt: Date?

    public init(messageID: String, text: String, attachments: [ChatOutgoingAttachment] = [], persistedAt: Date? = nil) {
        self.messageID = messageID
        self.text = text
        self.attachments = attachments
        self.persistedAt = persistedAt
    }
}

/// A `can_use_tool` request that waits for the user. The driver never answers one by itself, in any mode (CHAT-SPEC →
/// Requests). It retires only on its own request id (an answer, the CLI withdrawing it) or its own `tool_use_id` (the
/// tool's result arrived), or when the process ends.
public struct ChatPendingRequest: Sendable, Equatable, Identifiable {
    public var id: String { requestID }
    public let requestID: String
    public let request: ToolPermissionRequest
    public let arrivedAt: Date
    /// The subagent that asked, when `agent_id` names one (joined with its `task_started` when the request arrived).
    public let agent: ChatRequestAgent?

    public init(requestID: String, request: ToolPermissionRequest, arrivedAt: Date, agent: ChatRequestAgent? = nil) {
        self.requestID = requestID
        self.request = request
        self.arrivedAt = arrivedAt
        self.agent = agent
    }

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

    /// The provider-independent summary the event hub carries (`ProviderPendingRequest`): what Home, the sidebar's reason
    /// line and the notifications word a request from.
    public var summary: ProviderPendingRequest {
        let kind: ProviderPendingRequest.Kind
        let text: String
        var note: String?
        switch self.kind {
        case .approval:
            kind = .approval
            text = detail ?? request.toolName
            note = request.description
        case .question:
            kind = .question
            let first = request.input["questions"]?.array?.first
            text = first?["header"]?.string ?? first?["question"]?.string ?? ""
        case .plan:
            kind = .plan
            text = "Plan ready"
        }
        return ProviderPendingRequest(requestID: requestID, toolUseID: request.toolUseID, kind: kind,
                                      toolName: request.toolName, summary: text, note: note, arrivedAt: arrivedAt)
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
    /// The requests that wait for the user, in order of arrival: the pinned cards.
    public var requests: [ChatPendingRequest]
    /// The newest requests that left (answered, cancelled, resolved, or cut off by the process ending).
    public var settled: [ChatSettledRequest]
    /// The texts of Loom's own messages that never reached the CLI ("Not delivered"): the ended view offers them.
    public var undelivered: [String]
    /// Ask is the session's mode: a plan is approved in Ask there, so its card offers no other mode.
    public var isAsk: Bool

    public init(sessionID: UUID, conversationID: String? = nil, phase: ChatDriverPhase = .stopped, turnRunning: Bool = false,
                lastActivity: Date? = nil, drift: [ChatDrift] = [], policySignal: ChatPolicySignal? = nil,
                runStart: LiveHistoryJoin.RunStart = LiveHistoryJoin.RunStart(), requests: [ChatPendingRequest] = [],
                settled: [ChatSettledRequest] = [], undelivered: [String] = [], isAsk: Bool = false) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.phase = phase
        self.turnRunning = turnRunning
        self.lastActivity = lastActivity
        self.drift = drift
        self.policySignal = policySignal
        self.runStart = runStart
        self.requests = requests
        self.settled = settled
        self.undelivered = undelivered
        self.isAsk = isAsk
    }
}

/// What the live chat view reads from a driver: its model changes, a snapshot when it missed one, the live state and when
/// that changed. `ChatSessionDriver` is the one in the app; tests script one.
public protocol ChatLiveSource: AnyObject, Sendable {
    func modelChanges() async -> ChatModelChanges
    func snapshotChange() async -> ModelChange
    func liveState() async -> ChatLiveState
    func updates() async -> AsyncStream<Void>
    /// A card's answer. Only a user action calls this.
    func answer(requestID: String, _ answer: ChatRequestAnswer) async throws
    /// Resumes the stopped session ("Claude stopped before you answered" offers it).
    func resume() async throws
}

extension ChatLiveSource {
    /// A source that answers nothing (a scripted stream in a test): every request is gone as far as it can tell.
    public func answer(requestID: String, _ answer: ChatRequestAnswer) async throws {
        throw ChatDriverError.noSuchRequest(requestID)
    }

    public func resume() async throws {}
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
    /// The newest requests that left the list, and how (`ChatSessionDriver.settledLimit` of them).
    public var settled: [ChatSettledRequest]
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

/// What the composer reads from a driver (V17): the small part of the snapshot it draws, without the model (copying the
/// model out would make the driver copy its buffers on the next change). `Equatable`, so a view redraws only when
/// something it shows changed.
public struct ChatComposerState: Sendable, Equatable {
    /// The card the driver's run is on now: a `/clear` moves it to a new one.
    public var sessionID: UUID
    public var phase: ChatDriverPhase
    /// A turn runs (also while a request waits).
    public var turnRunning: Bool
    /// How many requests (cards) wait for the user. Esc never interrupts while one does.
    public var requestCount: Int
    public var queue: ChatQueue
    public var queueIssue: ChatQueueIssue?
    /// The session's mode, model and effort as Loom passes them on the next spawn.
    public var choices: ClaudeLaunchChoices
    /// The mode the CLI runs in now (`initialize`, `system/init`, `system/status`).
    public var permissionMode: String?
    /// The model the CLI named in its newest `system/init`, once there is one (a turn has begun).
    public var resolvedModel: String?
    /// The effort `system/init` reported.
    public var reportedEffort: String?
    /// The `initialize` answer's model menu (alias, resolved name, display name, supported effort levels).
    public var models: [ModelOption]
    /// The commands the CLI listed in its `initialize` answer, with their descriptions.
    public var commands: [CommandInfo]
    /// The names `system/init` lists: slash commands, skills, and the commands that only run in the terminal.
    public var slashCommands: [String]
    public var skills: [String]
    public var terminalOnlyCommands: [String]
    public var backgroundTaskCount: Int
    /// Messages Loom sent that the CLI holds unread (their rows offer "Read now").
    public var unreadMessageIDs: [String]
    /// Returned drafts wait for the composer (`takeReturnedDrafts`).
    public var hasReturnedDrafts: Bool
    /// Returned drafts that were sent again: the composer takes them out of its text (`takeWithdrawnDrafts`).
    public var hasWithdrawnDrafts: Bool
    /// The context of the newest main-thread message (input, cache and output tokens; after a compaction the size
    /// after it), and the window of the session's model once a result named it.
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var contextModel: String?
}

extension ChatComposerState {
    /// What a composer shows before its driver has been asked: nothing runs and nothing is known.
    public static func idle(sessionID: UUID) -> ChatComposerState {
        ChatComposerState(
            sessionID: sessionID, phase: .stopped, turnRunning: false, requestCount: 0, queue: ChatQueue(), queueIssue: nil,
            choices: ClaudeLaunchChoices(), permissionMode: nil, resolvedModel: nil, reportedEffort: nil, models: [],
            commands: [], slashCommands: [], skills: [], terminalOnlyCommands: [], backgroundTaskCount: 0,
            unreadMessageIDs: [], hasReturnedDrafts: false, hasWithdrawnDrafts: false, contextTokens: nil, contextWindow: nil,
            contextModel: nil)
    }
}
