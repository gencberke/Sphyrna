import Foundation

/// Claude as a harness: the live one. It holds the adapter (hook events to work state) and the provider part of a terminal
/// start and resume. The profile and launch helpers (`claudeProfile`, `launchClaude`, `startClaude`) stay runtime extensions
/// in `SessionRuntime+Claude`: the Chat face, the side chats and the open requests share them.
struct ClaudeHarness: Harness {
    let adapter: ClaudeSessionAdapter

    var provider: ManagedSession.Provider { .claude }
    var taskTransport: SessionTaskTransport? { .terminalHook }
    var takesOpeningOrDraft: Bool { true }
    var deletionRefusal: String? { nil }

    func startTerminal(in runtime: isolated SessionRuntime, _ start: HarnessTerminalStart) async throws -> RuntimeLaunch {
        try await runtime.startClaude(
            sessionID: start.sessionID, projectID: start.projectID, directory: start.directory, toolchain: start.toolchain,
            opening: start.opening, draft: start.draft, face: .terminal
        ) { profile in
            try await runtime.launchClaude(
                sessionID: start.sessionID, runID: start.runID, toolchain: start.toolchain, profile: profile,
                rows: start.rows, columns: start.columns, outputSink: start.outputSink, tee: nil
            )
        }
    }

    func resumeTerminal(in runtime: isolated SessionRuntime, _ resume: HarnessTerminalResume) async throws -> RuntimeLaunch {
        let hooks = try runtime.ensureHooks()
        let profile = try runtime.claudeProfile(
            route: .resume(resume.conversationID), toolchain: resume.toolchain,
            sessionID: resume.session.id, hooks: hooks,
            choices: try await runtime.resumeChoices(sessionID: resume.session.id, passed: resume.choices)
        )
        return try await runtime.launchClaude(
            sessionID: resume.session.id, runID: nil, toolchain: resume.toolchain, profile: profile,
            rows: resume.rows, columns: resume.columns, outputSink: resume.outputSink, tee: resume.tee
        )
    }

    // MARK: Run hooks (Claude's own: the Chat face, the hook ingress and the deletion call these typed)

    /// The registry watch of a run stops with the run.
    func runEnded(runID: UUID, in runtime: isolated SessionRuntime) async {
        await adapter.stopRegistry(runID: runID)
    }

    func observeRegistry(runID: UUID, reader: ClaudeRegistryReader) async {
        await adapter.observeRegistry(runID: runID, reader: reader)
    }

    /// Before a Chat-face spawn: the child's first hook (SessionStart) must not publish a work state for it.
    func handOverWorkState(runID: UUID) async { await adapter.handOverWorkState(runID: runID) }

    /// A fork's `SessionStart` (source `fork`) names the id its card already holds: it never makes a card (V22).
    func markForkRun(runID: UUID) async { await adapter.markForkRun(runID: runID) }

    /// A deleted conversation: the adapter drops what it keeps for it.
    func forget(sessionID: UUID) async { await adapter.forget(sessionID: sessionID) }

    /// The CLI this run launches with: logged, and journaled when it is new or its version changed.
    func noteToolchain(_ toolchain: ProviderToolchain, previous: ProviderToolchain?, in runtime: isolated SessionRuntime) {
        let capabilities = toolchain.capabilities
        let changed = previous.map { $0.capabilities.version != capabilities.version } ?? false
        LoomLog.notice(.toolchain, "Claude CLI \(capabilities.version) resolved (\(capabilities.detectedClaudeOptions.count) of 6 known options listed)")
        runtime.journal.record("claude_cli", [
            "version": .string(capabilities.version),
            "path": .string(DiagnosticPaths.abbreviate(toolchain.executable)),
            "detectedOptions": .strings(capabilities.detectedClaudeOptions),
            "changedFromPrevious": .bool(changed),
        ])
    }
}
