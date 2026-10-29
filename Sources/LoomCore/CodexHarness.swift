import Foundation

/// Codex's terminal start and resume; the app-server work stays in `SessionRuntime+Codex`.
struct CodexHarness: Harness {
    let adapter: CodexSessionAdapter

    var provider: ManagedSession.Provider { .codex }
    var taskTransport: SessionTaskTransport? { .ownedAppServer }
    var takesOpeningOrDraft: Bool { true }
    var deletionRefusal: String? { "Codex sessions cannot be deleted from Sphyrna yet" }

    func startTerminal(in runtime: isolated SessionRuntime, _ start: HarnessTerminalStart) async throws -> RuntimeLaunch {
        let choices = start.draft?.choices ?? start.opening?.choices
        if let choices { _ = try CodexLaunchSettings(choices) }
        // An omitted mode is a safe new-session default, never the user's
        // potentially broader CLI config. Keep the requested value unchanged.
        var effective = choices ?? HarnessLaunchChoices(harness: .codex)
        if effective.mode == nil { effective.mode = .askBeforeEdits }
        guard start.toolchain.capabilities.supportsListen, start.toolchain.capabilities.supportsRemote else {
            throw LoomError.message("Codex needs app-server --listen and --remote")
        }
        let prepared = try await GitWorkspace.begin(start.draft?.workspace ?? .projectFolder, projectFolder: start.directory)
        do {
            let (server, coordinator) = try await runtime.ensureCodex(card: start.sessionID, toolchain: start.toolchain,
                                                                      choices: effective)
            let profile: ProviderLaunchProfile
            do {
                profile = try runtime.codexNewProfile(
                    toolchain: start.toolchain, sessionID: start.sessionID, directory: prepared.folder, server: server,
                    choices: effective, firstMessage: start.opening?.approvedTask == nil
                        ? start.draft?.firstMessage ?? start.opening?.firstMessage : nil
                )
                try await runtime.supervisor.createSession(
                    ManagedSession(id: start.sessionID, provider: .codex, workingDirectory: prepared.folder),
                    projectID: start.projectID, title: start.opening?.title, openedBy: start.opening?.openedBy
                )
            } catch {
                throw await runtime.startFailure(error, cleaning: server)
            }
            runtime.startingSessions.insert(start.sessionID)
            defer { runtime.startingSessions.remove(start.sessionID) }
            let launch = try await runtime.launchNewCodex(
                sessionID: start.sessionID, runID: start.runID, directory: prepared.folder,
                toolchain: start.toolchain, profile: profile, server: server, coordinator: coordinator,
                rows: start.rows, columns: start.columns, outputSink: start.outputSink,
                onTerminalReady: start.onTerminalReady
            )
            do {
                try await runtime.catalog.recordLaunchChoices(choices ?? HarnessLaunchChoices(harness: HarnessID(provider)),
                    sessionID: start.sessionID, rememberingInProject: start.opening == nil,
                    completeNewStart: start.draft != nil)
            } catch {
                LoomLog.error(.catalog, "Launch choices could not be recorded (\(LoomLog.category(of: error)))")
            }
            return launch
        } catch {
            let problems = await GitWorkspace.undo(prepared)
            guard !problems.isEmpty else { throw error }
            throw LoomError.message("\(error). Not undone: \(problems.joined(separator: "; "))")
        }
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
