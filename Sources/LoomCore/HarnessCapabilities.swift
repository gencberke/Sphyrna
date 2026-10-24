import Foundation

/// What a session's harness may do in this build, as one value. The UI asks these, never `provider == .claude`: a later
/// harness (Codex returning, others) changes this table and nothing else (D-94). `HarnessCapabilitiesGuardTests` keeps it so.
public struct HarnessCapabilities: Equatable, Sendable {
    /// A real harness stands behind the session (not a test fixture): the UI names it and says why it cannot start.
    public let hasHarness: Bool
    /// The build can start and resume this harness's sessions (D-28, D-69 (5): Codex is shown, not startable, in production).
    public let startable: Bool
    /// The harness has a structured (Chat) face: a stopped session can show its live chat, send a message into it, and move
    /// from Chat to the terminal.
    public let structuredFace: Bool
    /// Loom reads the harness's own transcript: the project page's usage and last lines, the palette's transcript search, the
    /// composer's list of sessions to mention, and the packs Remora reads.
    public let readsTranscript: Bool
    /// The session can fork side chats (the Side tab).
    public let sideChats: Bool
    /// Loom reads the session's context use (the Overview's context bar, the Chat composer's ring).
    public let readsContext: Bool
    /// Loom reads the files the session edited (the Changes tab, Overview's last turn).
    public let readsEdits: Bool
    /// Loom lists the session's subagents (the Agents tab), live or from the stopped session's folder.
    public let subagents: Bool
    /// The session can rewind its files to before a message (Chat's rewind).
    public let rewind: Bool
    /// The session can take a quick question (the panel, ⌘;).
    public let quickQuestion: Bool
    /// Loom can delete the session's data (the harness's own files), and remove the session from Sphyrna only.
    public let deletes: Bool
    /// The harness reports its plan limits and usage (read by the usage package).
    public let usageLimits: Bool
    /// The harness lists the models it offers (read by the model UI).
    public let modelCatalog: Bool
    /// The run reports its own model, effort and mode, and its CLI's version: Overview's rows for them.
    public let reportsRunSettings: Bool
    /// The harness's name as the user reads it ("Claude", "Codex").
    public let displayName: String

    public init(hasHarness: Bool, startable: Bool, structuredFace: Bool, readsTranscript: Bool, sideChats: Bool,
                readsContext: Bool, readsEdits: Bool, subagents: Bool, rewind: Bool, quickQuestion: Bool, deletes: Bool,
                usageLimits: Bool, modelCatalog: Bool, reportsRunSettings: Bool, displayName: String) {
        self.hasHarness = hasHarness
        self.startable = startable
        self.structuredFace = structuredFace
        self.readsTranscript = readsTranscript
        self.sideChats = sideChats
        self.readsContext = readsContext
        self.readsEdits = readsEdits
        self.subagents = subagents
        self.rewind = rewind
        self.quickQuestion = quickQuestion
        self.deletes = deletes
        self.usageLimits = usageLimits
        self.modelCatalog = modelCatalog
        self.reportsRunSettings = reportsRunSettings
        self.displayName = displayName
    }

    /// What `provider`'s harness can do whatever the build starts (`startable` is false here): the answer for code that has
    /// no build identity in reach and asks about the harness itself (deleting, reading a transcript). A synthetic session (a
    /// test fixture) has nothing.
    public static func intrinsic(of provider: ManagedSession.Provider) -> HarnessCapabilities {
        switch provider {
        case .claude:
            HarnessCapabilities(
                hasHarness: true, startable: false, structuredFace: true, readsTranscript: true, sideChats: true,
                readsContext: true, readsEdits: true, subagents: true, rewind: true, quickQuestion: true, deletes: true,
                usageLimits: true, modelCatalog: true, reportsRunSettings: true, displayName: "Claude")
        case .codex:
            HarnessCapabilities(
                hasHarness: true, startable: false, structuredFace: false, readsTranscript: false, sideChats: false,
                readsContext: false, readsEdits: false, subagents: false, rewind: false, quickQuestion: false, deletes: false,
                usageLimits: true, modelCatalog: true, reportsRunSettings: false, displayName: "Codex")
        case .synthetic:
            HarnessCapabilities(
                hasHarness: false, startable: false, structuredFace: false, readsTranscript: false, sideChats: false,
                readsContext: false, readsEdits: false, subagents: false, rewind: false, quickQuestion: false, deletes: false,
                usageLimits: false, modelCatalog: false, reportsRunSettings: false, displayName: "Synthetic")
        }
    }

    /// The capabilities of `provider` in a build that can start the `startable` harnesses: `intrinsic(of:)`, with `startable`
    /// per the set (a synthetic session is never startable).
    public static func of(_ provider: ManagedSession.Provider, startable: Set<ManagedSession.Provider>) -> HarnessCapabilities {
        let base = intrinsic(of: provider)
        return HarnessCapabilities(
            hasHarness: base.hasHarness, startable: base.hasHarness && startable.contains(provider),
            structuredFace: base.structuredFace, readsTranscript: base.readsTranscript, sideChats: base.sideChats,
            readsContext: base.readsContext, readsEdits: base.readsEdits, subagents: base.subagents, rewind: base.rewind,
            quickQuestion: base.quickQuestion, deletes: base.deletes, usageLimits: base.usageLimits,
            modelCatalog: base.modelCatalog, reportsRunSettings: base.reportsRunSettings, displayName: base.displayName)
    }
}

extension ManagedSession.Provider {
    /// The harness a plain "New Session" starts (the entries, ⌘N, the Dock menu), until the new-session composer lets the
    /// user choose one.
    public static let newSessionDefault: ManagedSession.Provider = .claude
}

extension SessionHarness {
    /// What this harness can do (`HarnessCapabilities.intrinsic(of:)`), for the code that holds a `SessionSummary`.
    public var capabilities: HarnessCapabilities {
        switch self {
        case .claude: .intrinsic(of: .claude)
        case .codex: .intrinsic(of: .codex)
        }
    }
}
