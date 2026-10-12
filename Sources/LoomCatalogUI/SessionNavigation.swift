import AppKit
import Foundation
import LoomCore

/// Which way a keyboard step goes.
public enum StepDirection: Sendable {
    case next, previous
}

/// A session as the attention order, the Dock badge and the quit question read it: its indicator
/// (already including the open-session approval rule) and when it was last really used.
public struct AttentionCandidate: Equatable, Sendable {
    public let id: UUID
    public let indicator: SessionIndicator
    public let lastActivityAt: Date

    public init(id: UUID, indicator: SessionIndicator, lastActivityAt: Date) {
        self.id = id
        self.indicator = indicator
        self.lastActivityAt = lastActivityAt
    }
}

/// "Jump to Next/Previous Session That Needs You" and the Dock badge (D-45). The set is exactly
/// `SessionIndicator.needsAttention`; this orders it and walks it.
public enum AttentionOrder {
    /// Lower comes first: failure-class (failed, stop not verified, problem, identity unclear),
    /// then needs approval, then waiting for you, then finished and unviewed. Nil: not in the set.
    public static func rank(of indicator: SessionIndicator) -> Int? {
        switch indicator {
        case .failed, .stopUnverified, .problem, .identityUnclear: 0
        case .waitingForApproval: 1
        case .waitingForInput: 2
        case .unviewedCompletion: 3
        case .working, .unknown, .ready, .idle, .stale, .ended: nil
        }
    }

    /// The sessions that need the user, by class, then most recent activity first; the id breaks ties
    /// so the order never flickers between two equal sessions.
    public static func ordered(_ candidates: [AttentionCandidate]) -> [UUID] {
        candidates
            .compactMap { candidate in rank(of: candidate.indicator).map { (candidate, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.0.lastActivityAt != rhs.0.lastActivityAt { return lhs.0.lastActivityAt > rhs.0.lastActivityAt }
                return lhs.0.id.uuidString < rhs.0.id.uuidString
            }
            .map(\.0.id)
    }

    /// How many sessions need the user (the Dock badge).
    public static func count(_ candidates: [AttentionCandidate]) -> Int {
        candidates.reduce(0) { $0 + (rank(of: $1.indicator) == nil ? 0 : 1) }
    }

    /// The session to jump to from `current`. Repeated presses walk the order and wrap. A current
    /// session outside the order (nothing selected, or one that no longer needs the user) starts the
    /// walk: the first for next, the last for previous.
    public static func neighbor(of current: UUID?, in order: [UUID], _ direction: StepDirection) -> UUID? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return direction == .next ? order.first : order.last
        }
        let step = direction == .next ? 1 : order.count - 1
        return order[(index + step) % order.count]
    }
}

/// "Select Next/Previous Session": one step through the list as drawn, never wrapping.
public enum VisibleOrder {
    public static func neighbor(of current: UUID?, in visible: [UUID], _ direction: StepDirection) -> UUID? {
        guard !visible.isEmpty else { return nil }
        guard let current, let index = visible.firstIndex(of: current) else {
            return direction == .next ? visible.first : visible.last
        }
        let target = direction == .next ? index + 1 : index - 1
        return visible.indices.contains(target) ? visible[target] : nil
    }
}

/// The Window menu's session shortcuts: one place for titles and keys, used by the app's menu and its tests.
public struct SessionShortcut: Sendable {
    public let title: String
    public let keyEquivalent: String
    public let modifiers: NSEvent.ModifierFlags

    private static func functionKey(_ code: Int) -> String { String(UnicodeScalar(UInt16(code))!) }

    public static let jumpToNextAttention = SessionShortcut(
        title: "Jump to Next Session That Needs You", keyEquivalent: "j", modifiers: [.command])
    public static let jumpToPreviousAttention = SessionShortcut(
        title: "Jump to Previous Session That Needs You", keyEquivalent: "j", modifiers: [.command, .shift])
    public static let selectNextSession = SessionShortcut(
        title: "Select Next Session", keyEquivalent: functionKey(NSDownArrowFunctionKey), modifiers: [.command, .option])
    public static let selectPreviousSession = SessionShortcut(
        title: "Select Previous Session", keyEquivalent: functionKey(NSUpArrowFunctionKey), modifiers: [.command, .option])
}

extension SessionShortcut {
    /// Cmd+J and Shift+Cmd+J share a letter, and AppKit does not tell them apart when it matches a key
    /// equivalent (it neither requires nor rejects Shift for a letter, and compares the letter's case), so
    /// either menu item may be the one that fires. A key press decides by its own Shift; a click on a menu
    /// item keeps that item's direction.
    public static func attentionDirection(fromKeyDown keyDown: Bool, shift: Bool, item: StepDirection) -> StepDirection {
        guard keyDown else { return item }
        return shift ? .previous : .next
    }
}

/// The Dock tile's badge.
public enum DockBadge {
    /// Nil clears the badge: nothing needs the user.
    public static func label(count: Int) -> String? { count > 0 ? String(count) : nil }
}

/// Text the session menus copy.
public enum SessionCommandText {
    /// POSIX single-quote escaping: the text is wrapped in single quotes and each single quote in it
    /// becomes `'\''`. Nothing else is special inside single quotes, so the shell reads it back verbatim.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `cd '<dir>' && claude --resume <id>`. The id stays bare when it is made of characters no shell
    /// treats specially (a Claude session id is a UUID), otherwise it is quoted too.
    public static func resumeCommand(directory: String, providerConversationID: String) -> String {
        let bytes = providerConversationID.utf8
        let safe = bytes.first != UInt8(ascii: "-") && !bytes.isEmpty && bytes.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".")
        }
        let id = safe ? providerConversationID : shellQuoted(providerConversationID)
        return "cd \(shellQuoted(directory)) && claude --resume \(id)"
    }
}

extension SessionRowModel {
    /// The provider's id of a Claude session; nil for other providers and for a session that has none yet.
    public var claudeSessionID: String? {
        guard record.session.provider == .claude,
              let id = record.session.providerConversationID, !id.isEmpty else { return nil }
        return id
    }

    /// What "Copy Resume Command" puts on the pasteboard.
    public var resumeCommand: String? {
        claudeSessionID.map {
            SessionCommandText.resumeCommand(directory: record.session.workingDirectory, providerConversationID: $0)
        }
    }
}

/// Asks the model to scroll the sidebar to a session; the serial makes two requests for the same
/// session distinct.
public struct SessionRevealRequest: Equatable, Sendable {
    public let id: UUID
    public let serial: Int
}

/// What "Quit" asks when sessions are in flight (D-45), and how a quit is told apart from the
/// system's own (logout, restart, shutdown).
public enum QuitConfirmation {
    public struct Prompt: Equatable, Sendable {
        public let title: String
        public let text: String
        public let confirmTitle: String
        public let cancelTitle: String
    }

    /// The question for a user-initiated quit, or nil when none is needed: a system-initiated quit never
    /// asks (the logout or restart must not wait for an answer), and neither does a quit with nothing
    /// working. `busySessions`: sessions that are Working or Need approval.
    public static func prompt(busySessions: Int, systemInitiated: Bool) -> Prompt? {
        guard !systemInitiated, busySessions > 0 else { return nil }
        let noun = busySessions == 1 ? "session" : "sessions"
        return Prompt(
            title: "Quit Loom and stop \(busySessions) working \(noun)?",
            text: "Loom stops every session it started. You can resume each one later.",
            confirmTitle: "Quit", cancelTitle: "Cancel")
    }

    /// Sessions that are mid-turn: Working, or Needs approval (a provider approval, or an agent's wait
    /// on an open-session request, which the indicator already folds in). Ready, Waiting for you and
    /// Finished do not count.
    public static func busyCount(_ candidates: [AttentionCandidate]) -> Int {
        candidates.reduce(0) { $0 + ($1.indicator == .working || $1.indicator == .waitingForApproval ? 1 : 0) }
    }

    /// `keyAEQuitReason` ("why?"), the attribute of the quit Apple event that says why.
    public static let reasonKeyword = fourCharCode("why?")

    /// The reasons the system gives when it quits applications: log out, really log out, restart,
    /// shut down (and their confirmation dialogs). An ordinary Quit, from the menu or the Dock, carries none.
    public static func isSystemInitiated(reason: UInt32?) -> Bool {
        guard let reason else { return false }
        return [fourCharCode("logo"), fourCharCode("rlgo"), fourCharCode("rrst"),
                fourCharCode("rest"), fourCharCode("rsdn"), fourCharCode("shut")].contains(reason)
    }

    static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The explanation under "Loom could not verify that its processes stopped." Quit Anyway never
    /// reads as a success: it says what Loom does not know.
    public static func failedShutdownText(remaining: String, errors: [String]) -> String {
        "Remaining: \(remaining). Errors: \(errors.prefix(3).joined(separator: "; "))\n\n"
            + "Quit Anyway ends Loom without confirming that every session process stopped. "
            + "Processes Loom could not stop may keep running."
    }
}
