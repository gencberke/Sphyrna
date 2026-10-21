import Foundation

/// Codex as a harness: frozen but kept (D-28, D-69 (5): not startable in a production build, working in a development one).
/// It holds the adapter and the provider part of a terminal start and resume; the app-server work stays in `SessionRuntime+Codex`.
struct CodexHarness: Harness {
    let adapter: CodexSessionAdapter

    var provider: ManagedSession.Provider { .codex }
    var takesOpeningOrDraft: Bool { false }
    var deletionRefusal: String? { "Codex sessions cannot be deleted from Loom yet" }

    func startTerminal(in runtime: isolated SessionRuntime, _ start: HarnessTerminalStart) async throws -> RuntimeLaunch {
        let (server, coordinator) = try await runtime.ensureCodex(card: start.sessionID, toolchain: start.toolchain)
        let profile: ProviderLaunchProfile
        do {
            profile = try runtime.codexNewProfile(
                toolchain: start.toolchain, sessionID: start.sessionID, directory: start.directory, server: server
            )
            try await runtime.supervisor.createSession(
                ManagedSession(id: start.sessionID, provider: .codex, workingDirectory: start.directory),
                projectID: start.projectID
            )
        } catch {
            // No card exists to show a failed cleanup on: the caller gets it.
            throw await runtime.startFailure(error, cleaning: server)
        }
        runtime.startingSessions.insert(start.sessionID)
        defer { runtime.startingSessions.remove(start.sessionID) }
        return try await runtime.launchNewCodex(
            sessionID: start.sessionID, runID: start.runID, directory: start.directory,
            toolchain: start.toolchain, profile: profile, server: server, coordinator: coordinator,
            rows: start.rows, columns: start.columns, outputSink: start.outputSink,
            onTerminalReady: start.onTerminalReady
        )
    }

    func resumeTerminal(in runtime: isolated SessionRuntime, _ resume: HarnessTerminalResume) async throws -> RuntimeLaunch {
        let (server, coordinator) = try await runtime.ensureCodex(card: resume.session.id, toolchain: resume.toolchain)
        return try await runtime.resumeCodex(
            session: resume.session, conversationID: resume.conversationID, toolchain: resume.toolchain,
            server: server, coordinator: coordinator,
            rows: resume.rows, columns: resume.columns, tee: resume.tee
        )
    }

    /// Codex's per-run teardown (its app-server and scope) is the runtime's `tearDown`, which acts on the run's record.
    func runEnded(runID: UUID, in runtime: isolated SessionRuntime) async {}

    func noteToolchain(_ toolchain: ProviderToolchain, previous: ProviderToolchain?, in runtime: isolated SessionRuntime) {}
}
