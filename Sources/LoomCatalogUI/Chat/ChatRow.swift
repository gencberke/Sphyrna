import Foundation
import LoomChat

/// The three views of the stream, cycled with ⌃O (CHAT-SPEC → Views). Normal folds work and shows the thought as one
/// line; Thinking adds each thinking block where it happened; Verbose also opens every fold and group.
enum ChatViewMode: String, CaseIterable, Sendable {
    case normal
    case thinking
    case verbose

    var next: ChatViewMode {
        switch self {
        case .normal: .thinking
        case .thinking: .verbose
        case .verbose: .normal
        }
    }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .thinking: "Thinking"
        case .verbose: "Verbose"
        }
    }

    var showsThinkingBlocks: Bool { self != .normal }
    var opensFoldsAndGroups: Bool { self == .verbose }
}

/// One row the stream draws. The id is stable (an entry id, or a derived id such as `fold:<turn>`), so a change replaces
/// the rows it touched and no others. `open` is the row's one open/closed state; the rest of its payload is value data,
/// so two rows are equal exactly when they would draw the same.
struct ChatRow: Identifiable, Equatable {
    let id: String
    var kind: Kind
    /// A fold, a group, a tool body, a thinking block, a raw record, a long message or plan, shown open.
    var open = false
    /// Small per-row choices that change what it draws: "wrap:3" (code block 3 wraps its lines), "all" (a body shows
    /// everything, not its tail).
    var flags: Set<String> = []
    /// One step of nesting: the tools of an open group.
    var indent = 0
    /// What "Show all" read from the transcript for a clipped tool result: its text (cut at about 1 MiB), or that it
    /// could not be read.
    var fullOutput: ChatFullOutput?
    var fullText: String? {
        if case let .text(text)? = fullOutput { text } else { nil }
    }

    enum Kind: Equatable {
        /// "Session started · 14:02", at the top when nothing older exists.
        case start(Date?)
        case marker(Marker, Date?)
        /// A hairline with text, derived (for example "You stopped after 1m 4s").
        case divider(String)
        case user(ChatEntry)
        /// Claude's prose. `settled` marks the final answer of a finished turn, the only prose with hover actions.
        case prose(ChatEntry, settled: Bool)
        case thinking(ChatEntry)
        case tool(ChatEntry)
        case group(ToolGroup)
        case subagent(ChatEntry)
        case plan(ChatEntry)
        case request(ChatEntry)
        case raw(ChatEntry)
        case turnFold(TurnFold)
        case changedFiles(ChangedFiles)
        /// The live thought line above the live row (Normal view).
        case thought(String)
        case live(LiveRow)
        /// A transcript with nothing to show yet.
        case empty
    }
}

/// Two or more tools in a row: one summary line that opens into the tools.
struct ToolGroup: Equatable {
    var id: String
    var members: [ChatEntry]
    var summary: String
    /// The latest tool's state decides the group's (T3).
    var status: ToolCall.Status
    var failedCount: Int
}

/// A settled turn's work, folded into one row between your message and the answer.
struct TurnFold: Equatable {
    var turnID: String
    var title: String
    /// What the work did: "changed 5 files and ran 3 commands".
    var detail: String
    var failedCount: Int
}

struct ChangedFile: Equatable {
    var path: String
    var added: Int
    var removed: Int
}

/// The card under the final answer of a turn that edited files.
struct ChangedFiles: Equatable {
    var turnID: String
    var files: [ChangedFile]
    var lines: [ChangedFileLine]

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

/// One line of the card's file tree: single-child folders are merged ("src/auth/").
struct ChangedFileLine: Equatable {
    var depth: Int
    var name: String
    var isFolder: Bool
    var added: Int
    var removed: Int
}

/// The one row at the end of a running turn.
struct LiveRow: Equatable {
    var turnID: String
    /// "Editing migrations/0042.py", "Thinking", "Working".
    var label: String
    var startedAt: Date?
    /// When something last arrived; after 40 s without, the row says so.
    var lastActivity: Date?
    /// Tools that trail the turn and are collapsed into this row.
    var hiddenTools: [ChatEntry]
}
