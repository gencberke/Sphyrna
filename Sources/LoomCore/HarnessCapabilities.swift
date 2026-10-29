import Foundation

/// What a session's harness may do in this build, as one value. The UI asks these, never `provider == .claude`: a later
/// harness (Codex returning, others) changes this table and nothing else (D-94). `HarnessCapabilitiesTests` keeps it so.
public struct HarnessCapabilities: Equatable, Sendable {
    /// A real harness stands behind the session (not a test fixture): the UI names it and says why it cannot start.
    public let hasHarness: Bool
    /// The build can start and resume this harness's sessions.
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

    /// A harness that has no integration in this build yet: a real harness with nothing read, started or deleted
    /// (opencode, agy and pi), or no harness at all (a synthetic fixture).
    private static func row(hasHarness: Bool, displayName: String) -> HarnessCapabilities {
        HarnessCapabilities(
            hasHarness: hasHarness, startable: false, structuredFace: false, readsTranscript: false, sideChats: false,
            readsContext: false, readsEdits: false, subagents: false, rewind: false, quickQuestion: false, deletes: false,
            usageLimits: false, modelCatalog: false, reportsRunSettings: false, displayName: displayName)
    }

    /// Claude's row: every capability.
    private static let claude = HarnessCapabilities(
        hasHarness: true, startable: false, structuredFace: true, readsTranscript: true, sideChats: true,
        readsContext: true, readsEdits: true, subagents: true, rewind: true, quickQuestion: true, deletes: true,
        usageLimits: true, modelCatalog: true, reportsRunSettings: true, displayName: "Claude")

    /// Codex's row: transcript, usage and file-change reads do not imply a structured Chat face or deletion support.
    private static let codex = HarnessCapabilities(
        hasHarness: true, startable: false, structuredFace: false, readsTranscript: true, sideChats: false,
        readsContext: true, readsEdits: true, subagents: false, rewind: false, quickQuestion: false, deletes: false,
        usageLimits: true, modelCatalog: true, reportsRunSettings: false, displayName: "Codex")

    /// What `id`'s harness can do whatever the build starts (`startable` is false here): the answer for code that has no
    /// build identity in reach and asks about the harness itself (deleting, reading a transcript). opencode, agy and pi
    /// have their own row with nothing read yet; a synthetic session (a test fixture) and an id this build does not
    /// describe have nothing.
    public static func intrinsic(ofHarness id: HarnessID) -> HarnessCapabilities {
        // A harness this build runs through a stored provider answers its provider's row, so the two spellings agree.
        if let provider = id.provider { return intrinsic(of: provider) }
        return switch id {
        case .opencode, .agy, .pi: row(hasHarness: true, displayName: id.rawValue)
        default: row(hasHarness: false, displayName: id.rawValue)
        }
    }

    /// What `provider`'s harness can do whatever the build starts.
    public static func intrinsic(of provider: ManagedSession.Provider) -> HarnessCapabilities {
        switch provider {
        case .claude: claude
        case .codex: codex
        case .agy: row(hasHarness: true, displayName: "agy")
        case .synthetic: row(hasHarness: false, displayName: "Synthetic")
        }
    }

    /// The capabilities of `id` in a build that can start the `startable` harnesses: `intrinsic(ofHarness:)`, with `startable`
    /// per the set and the harness's own `startable` fact (a harness with no start path, one that is coming later, and a
    /// synthetic session, is never startable).
    public static func ofHarness(_ id: HarnessID, startable: Set<HarnessID>) -> HarnessCapabilities {
        let base = intrinsic(ofHarness: id)
        let descriptor = HarnessCatalogue.descriptor(for: id)
        let hasStartPath = (descriptor?.startable ?? false) && descriptor?.comingLater != true
        return HarnessCapabilities(
            hasHarness: base.hasHarness, startable: base.hasHarness && hasStartPath && startable.contains(id),
            structuredFace: base.structuredFace, readsTranscript: base.readsTranscript, sideChats: base.sideChats,
            readsContext: base.readsContext, readsEdits: base.readsEdits, subagents: base.subagents, rewind: base.rewind,
            quickQuestion: base.quickQuestion, deletes: base.deletes, usageLimits: base.usageLimits,
            modelCatalog: base.modelCatalog, reportsRunSettings: base.reportsRunSettings, displayName: base.displayName)
    }

    /// The capabilities of `provider` in a build that can start the `startable` harnesses.
    public static func of(_ provider: ManagedSession.Provider, startable: Set<ManagedSession.Provider>) -> HarnessCapabilities {
        ofHarness(HarnessID(provider), startable: Set(startable.map(HarnessID.init)))
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
        case .agy: .intrinsic(of: .agy)
        }
    }
}
