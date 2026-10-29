import Foundation

/// The two existing task-input and proof transports. A harness that has no
/// verified transport is unavailable to the task and peer channels.
enum SessionTaskTransport: Sendable { case terminalHook, ownedAppServer }

/// What a new terminal start hands its harness: everything `SessionRuntime.startConversation` fixed before the provider
/// part (the ids, the folder and the toolchain `withNewStart` resolved, the terminal's size and sink).
struct HarnessTerminalStart {
    let sessionID: UUID
    let runID: UUID
    let projectID: UUID?
    let directory: String
    let toolchain: ProviderToolchain
    let rows: UInt16
    let columns: UInt16
    let outputSink: (any TerminalOutputSink)?
    let opening: SessionOpening?
    let draft: NewSessionLaunch?
    let onTerminalReady: (@MainActor @Sendable (RuntimeLaunch) async -> Void)?
}

/// What a terminal resume hands its harness: the guards of `withResume` already passed.
struct HarnessTerminalResume {
    let session: ManagedSession
    let conversationID: String
    let toolchain: ProviderToolchain
    let rows: UInt16
    let columns: UInt16
    let outputSink: (any TerminalOutputSink)?
    let tee: DiagnosticOutputTee
    /// Mode, model and effort passed with the resume (Claude only reads them).
    let choices: ClaudeLaunchChoices
}

/// One harness (Claude and Codex today, others later) as the runtime sees it: the provider-specific part
/// of a session's start, resume, run end and deletion, behind one value. The runtime manages sessions and asks the harness
/// wherever the provider matters; it does not branch on `provider` for these (R7, `SESSION-SERVICE.md` §2).
///
/// A member exists only where a runtime site asks it. The bodies that need the runtime's state (`isolated` parameter) run
/// on its actor; the helpers they use (`claudeProfile`, `launchClaude`, `ensureCodex`, ...) stay runtime extensions because
/// the Chat face, the side chats and the open requests share them.
protocol Harness: Sendable {
    var provider: ManagedSession.Provider { get }
    var taskTransport: SessionTaskTransport? { get }
    /// A start of this harness may carry an opening (an Open Session request) or a draft (the new-session form).
    var takesOpeningOrDraft: Bool { get }
    /// Why a session of this harness is refused for deletion; nil when its data can be removed from Loom.
    var deletionRefusal: String? { get }

    /// A new session in the terminal face: the card, the launch profile and the spawn.
    func startTerminal(in runtime: isolated SessionRuntime, _ start: HarnessTerminalStart) async throws -> RuntimeLaunch
    /// A stopped session's resume in the terminal face.
    func resumeTerminal(in runtime: isolated SessionRuntime, _ resume: HarnessTerminalResume) async throws -> RuntimeLaunch
    /// A run of this harness ended (removed from the runtime's records): whatever its adapter watched for it stops.
    func runEnded(runID: UUID, in runtime: isolated SessionRuntime) async
    /// The CLI a run launches with was resolved (`previous` is the one it replaced): logged and journaled when the harness
    /// keeps such a record.
    func noteToolchain(_ toolchain: ProviderToolchain, previous: ProviderToolchain?, in runtime: isolated SessionRuntime)
}

extension Harness {
    var taskTransport: SessionTaskTransport? { nil }
}

/// The harnesses a runtime manages, by provider. `claude` and `codex` are also kept typed: the Chat face, the hook ingress
/// and the deletion's Claude-file work are Claude's own and call its adapter without a lookup.
struct HarnessRegistry: Sendable {
    let claude: ClaudeHarness
    let codex: CodexHarness
    let agy: AgyHarness

    init(supervisor: ProcessSupervisor, hookSilenceGrace: TimeInterval) {
        claude = ClaudeHarness(adapter: ClaudeSessionAdapter(supervisor: supervisor, hookSilenceGrace: hookSilenceGrace))
        codex = CodexHarness(adapter: CodexSessionAdapter(supervisor: supervisor))
        agy = AgyHarness()
    }

    /// The providers with a harness (a synthetic session has none).
    var providers: Set<ManagedSession.Provider> { [claude.provider, codex.provider, agy.provider] }

    subscript(provider: ManagedSession.Provider) -> (any Harness)? {
        switch provider {
        case .claude: claude
        case .codex: codex
        case .agy: agy
        case .synthetic: nil
        }
    }
}
