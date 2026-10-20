import Foundation
import LoomCore

// The side chat (V22 part 2), on the driver: a fork of another session that answers on the side. The fork is a session of its
// own to the CLI and to the catalog (`SessionRuntime.startSideChat`), and an ordinary Chat driver to everything else; what this
// file adds is what a side chat is not allowed to be. It changes files only if the user allows edits in it (the request policy,
// `SideChatPolicy`), runs no slash command (so `/clear` can never make a visible card), is never titled by Claude, never changes
// its mode, model or effort (the cache prefix is the parent's), never moves to the terminal, and rewinds no files (the host
// gives it no rewind store: the fork shares the parent's working folder, and a rewind there would change files under the main
// session). The request intake is in ChatSessionDriver+Requests.swift.

/// What the Side tab reads of a side chat's driver.
public struct SideChatState: Equatable, Sendable {
    /// The session this side chat was forked from.
    public let parentSessionID: UUID
    /// "Allow edits" (off on every launch, never kept).
    public let allowsEdits: Bool
    /// How many requests the policy refused (each left a line in the stream), and how many read-only commands it allowed.
    public let refusedCount: Int
    public let allowedCount: Int
    /// The first question was sent: the card holds its uuid and its title.
    public let hasSentFirstMessage: Bool
}

extension ChatSessionDriver {
    public static let commandsRefusedText = "Commands don't run in a side chat"

    /// Whether this driver is a side chat's.
    public var isSideChat: Bool { sideChatParent != nil }

    /// The side chat's state; nil for a main session's driver.
    public func sideChatState() -> SideChatState? {
        guard let parent = sideChatParent else { return nil }
        return SideChatState(
            parentSessionID: parent, allowsEdits: (requestPolicy as? SideChatPolicy)?.allowsEdits ?? false,
            refusedCount: policyRefusals, allowedCount: policyAllowed, hasSentFirstMessage: sideFirstSent)
    }

    /// The process lives and nothing is going on in it: ready, no turn, no waiting card, nothing queued. A side chat that is no longer
    /// the open one is stopped at this point (D-72), not before.
    public var isLiveAndSettled: Bool { phase == .ready && !turnRunning && requests.isEmpty && queue.isEmpty }

    /// "Allow edits": the edit tools and the commands that may write become cards instead of refusals. Applies to the requests that
    /// arrive from now on; a refusal already given stays. A main session's driver has no such switch.
    public func setAllowsEdits(_ allowed: Bool) {
        guard let policy = requestPolicy as? SideChatPolicy else { return }
        policy.allowsEdits = allowed
        changed()
    }

    /// The side chat's first launch: forks the parent (`SessionRuntime.startSideChat` makes the card and spawns the fork). Ready
    /// when it returns, as `startNew`; a start that fails throws with the card already gone. Every later launch is a plain
    /// resume of the fork's own id (`resume()` or the next `send`), in `--permission-mode default` with the same ask rules.
    public func startFork() async throws {
        guard let parent = sideChatParent else { throw ChatDriverError.notASideChat }
        let id = sessionID
        try await launch(isResume: false) { sink in
            try await self.runtime.startSideChat(parentSessionID: parent, sessionID: id, outputSink: sink)
        }
    }

    /// Throws for what a side chat does not do (a mode, model or effort change, the handover to the terminal).
    func refuseInSideChat() throws {
        if sideChatParent != nil { throw ChatDriverError.notInSideChat }
    }

    /// The first message of the side chat went out: its uuid and its first line go to the card, once. The title is the first
    /// question's first line, not custom (a rename still wins), and Claude is never asked for one.
    func recordSideChatFirstSend(uuid: String, text: String) async {
        guard sideChatParent != nil, !sideFirstSent else { return }
        sideFirstSent = true
        await runtime.recordSideChatFirstMessage(sessionID: sessionID, uuid: uuid, text: text)
        changed()
    }
}
