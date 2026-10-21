import Foundation

/// What a session's harness may do in this build, as one value. The UI asks these, never `provider == .claude`: a later
/// harness (Codex returning, others) changes this table and nothing else. A field exists only where a gate reads it.
public struct HarnessCapabilities: Equatable, Sendable {
    /// A real harness stands behind the session (not a test fixture): the UI names it and says why it cannot start.
    public let hasHarness: Bool
    /// The build can start and resume this harness's sessions (D-28, D-69 (5): Codex is shown, not startable, in production).
    public let startable: Bool
    /// The harness has a structured (Chat) face: a stopped session can show its live chat, send a message into it, and move
    /// from Chat to the terminal.
    public let structuredFace: Bool
    /// Loom reads the harness's own transcript: the Changes tab's edits, the project page's usage and last lines, and the
    /// composer's list of sessions to mention.
    public let readsTranscript: Bool
    /// The session can fork side chats (the Side tab).
    public let sideChats: Bool

    public init(hasHarness: Bool, startable: Bool, structuredFace: Bool, readsTranscript: Bool, sideChats: Bool) {
        self.hasHarness = hasHarness
        self.startable = startable
        self.structuredFace = structuredFace
        self.readsTranscript = readsTranscript
        self.sideChats = sideChats
    }

    /// The capabilities of `provider` in a build that can start the `startable` harnesses. Claude has everything; Codex is
    /// startable per the set and nothing else; a synthetic session (a test fixture) has nothing.
    public static func of(_ provider: ManagedSession.Provider, startable: Set<ManagedSession.Provider>) -> HarnessCapabilities {
        switch provider {
        case .claude:
            HarnessCapabilities(hasHarness: true, startable: startable.contains(.claude), structuredFace: true, readsTranscript: true, sideChats: true)
        case .codex:
            HarnessCapabilities(hasHarness: true, startable: startable.contains(.codex), structuredFace: false, readsTranscript: false, sideChats: false)
        case .synthetic:
            HarnessCapabilities(hasHarness: false, startable: false, structuredFace: false, readsTranscript: false, sideChats: false)
        }
    }
}
