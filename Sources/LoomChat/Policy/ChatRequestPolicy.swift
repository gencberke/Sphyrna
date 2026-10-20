import Foundation
import Synchronization

/// What an injected policy says about a `can_use_tool` request before it becomes a card (V22).
public enum ChatRequestDecision: Equatable, Sendable {
    /// The card, exactly as without a policy.
    case ask
    /// Answered at once: allow as asked.
    case allow
    /// Answered at once: deny, with this text as the model's tool result.
    case deny(String)
}

/// Decides tool requests for a driver whose session is not the user's to approve (a side chat). A main session has none, and
/// every request of it becomes a card.
public protocol ChatRequestPolicy: Sendable {
    func decide(_ request: ToolPermissionRequest) -> ChatRequestDecision
}

/// The side chat's policy (V22): a fork reads, and changes nothing unless the user allows edits in that side chat. The cache is
/// the reason it is a policy and not a launch option (S6: `--disallowed-tools`, `--tools` and plan mode all miss the parent's
/// cached context), and the model routes around a refused `Write` through `echo > file`, so Bash is classified too
/// (`ReadOnlyCommand`). Requests from the fork's subagents (`agent_id` set) get the same answer: the decision is by tool.
public final class SideChatPolicy: ChatRequestPolicy {
    public static let editsRefused = "Side chats don't change files. Ask in the main session, or allow edits in this side chat."
    public static let planRefused = "Side chats don't use plan mode."
    /// The tools that change files. Also the tools a side chat's launch makes ask (`SessionRuntime.sideChatAskRules` adds Bash).
    public static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private let allowing = Mutex(false)

    /// "Allow edits" (the Side tab's toggle): off by default on every launch, and never kept.
    public var allowsEdits: Bool {
        get { allowing.withLock { $0 } }
        set { allowing.withLock { $0 = newValue } }
    }

    public init() {}

    public func decide(_ request: ToolPermissionRequest) -> ChatRequestDecision {
        let edits = allowsEdits
        switch request.toolName {
        case _ where Self.editTools.contains(request.toolName):
            return edits ? .ask : .deny(Self.editsRefused)
        case "Bash":
            // A command that provably reads is answered without a card, with edits allowed or not.
            if let command = request.input["command"]?.string, ReadOnlyCommand.isReadOnly(command) { return .allow }
            return edits ? .ask : .deny(Self.editsRefused)
        case "EnterPlanMode", "ExitPlanMode":
            return .deny(Self.planRefused)
        default:
            // AskUserQuestion, MCP tools and every other tool: the card, as in a main session.
            return .ask
        }
    }
}
