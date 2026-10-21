import Foundation

/// A Chat-face run handed to its driver (`LoomChat.ChatSessionDriver`): the pipes of a `claude -p` stream-json child
/// in the session's run scope. The driver writes every line and reads every line; nothing else does.
public struct RuntimePipeLaunch: Sendable {
    public let sessionID: UUID
    public let runID: UUID
    public let pipe: PipeEndpoint
}

/// The Chat face's entry into the runtime (V16). A Chat-face run is an ordinary managed run with pipes instead of a
/// terminal (V14): the same run scope, ownership markers, same-session guard, hooks, plugin and choices as a terminal
/// run, verified Stop and Quit. Two things differ:
///
/// - **Work state.** The driver reads the child's own stream and publishes the run's work state
///   (`ProcessSupervisor.updateProviderWorkState`); the hook adapter keeps doing everything else for the run but no
///   longer publishes its activity (`ClaudeSessionAdapter.handOverWorkState`), and the run has no registry watch: the
///   child's registry entry (`entrypoint: sdk-cli`) would only repeat the stream late.
/// - **Stop order.** The driver registers a `leave` stop hook: interrupt a running turn or a waiting request, wait
///   for the turn's `result`, then the supervisor closes stdin and waits for the exit (S1 §D6). Quit runs the same
///   order for every Chat-face run at once.
extension SessionRuntime {
    /// Starts a new Claude session in the Chat face, through the same guards and steps as a terminal start
    /// (`withNewStart`, `startClaude`): one start per project, the first message's size, the toolchain and profile
    /// before the card, the draft's branch or worktree right before it (undone when the start fails), the choices
    /// recorded with it. `sessionID` is chosen by the caller so its driver exists before the first byte arrives. The
    /// draft's first message is not an argument here: the driver sends it over stdin once the CLI is ready. An
    /// `opening` (an agent's approved request, C5b) is the other source of a first message and is sent the same way;
    /// it gives the card its title and `openedBy`. Never both an opening and a draft (`withNewStart` refuses that).
    public func startChatConversation(
        projectID: UUID?, sessionID: UUID = UUID(), draft: NewSessionLaunch? = nil,
        opening: SessionOpening? = nil, outputSink: any PipeOutputSink
    ) async throws -> RuntimePipeLaunch {
        try await withNewStart(provider: .claude, projectID: projectID, opening: opening, draft: draft) {
            directory, toolchain in
            try await self.startClaude(
                sessionID: sessionID, projectID: projectID, directory: directory, toolchain: toolchain,
                opening: opening, draft: draft, face: .chat
            ) { profile in
                try await self.launchChatClaude(sessionID: sessionID, toolchain: toolchain, profile: profile,
                                                outputSink: outputSink, isResume: false)
            }
        }
    }

    /// Resumes a stopped Claude session in the Chat face (`--resume`), through the same guards as a terminal resume
    /// (`withResume`), with the mode, model and effort the catalog holds for it; `choices` that are set replace them.
    public func resumeChatConversation(
        sessionID: UUID, choices: ClaudeLaunchChoices = ClaudeLaunchChoices(), outputSink: any PipeOutputSink
    ) async throws -> RuntimePipeLaunch {
        try await withResume(sessionID: sessionID, providers: [.claude]) { _, conversationID, toolchain in
            let hooks = try self.ensureHooks()
            var launchChoices = try await self.resumeChoices(sessionID: sessionID, passed: choices)
            // A side chat resumes as what it is (V22): `--permission-mode default` and the ask rules, so every edit still waits
            // for Loom's answer. Its stored mode is `default` already; this keeps it so whatever a row holds.
            let isSideChat = try await self.catalog.session(id: sessionID)?.isSideChat == true
            if isSideChat { launchChoices.permissionMode = ClaudePermissionMode.askBeforeEdits.rawValue }
            let profile = try self.claudeProfile(
                route: .resume(conversationID), toolchain: toolchain, sessionID: sessionID, hooks: hooks,
                choices: launchChoices, face: .chat, askRules: isSideChat ? Self.sideChatAskRules : []
            )
            return try await self.launchChatClaude(sessionID: sessionID, toolchain: toolchain, profile: profile,
                                                   outputSink: outputSink, isResume: true)
        }
    }

    func launchChatClaude(
        sessionID: UUID, toolchain: ProviderToolchain, profile: ProviderLaunchProfile,
        outputSink: any PipeOutputSink, isResume: Bool, isFork: Bool = false
    ) async throws -> RuntimePipeLaunch {
        let runID = UUID()
        // Before the spawn: the child's first hook (SessionStart) must not publish a work state for it.
        await harnesses.claude.handOverWorkState(runID: runID)
        // A fork's `SessionStart` (source `fork`) names the id its card already holds: it never makes a card (V22).
        if isFork { await harnesses.claude.markForkRun(runID: runID) }
        let launch: ManagedPipeLaunch
        do {
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            launch = try await supervisor.launchPipes(
                sessionID: sessionID, executable: toolchain.executable,
                arguments: profile.launchArguments(extra: toolchain.extraArguments),
                environment: profile.environment, outputSink: outputSink, managedRunID: runID
            )
        } catch {
            await harnesses.claude.runEnded(runID: runID, in: self)
            LoomLog.error(.lifecycle, "Claude could not be started in the Chat face (\(LoomLog.category(of: error)))")
            if !(error is SessionRuntimeError), !(error is SessionManagementError) {
                await invalidateToolchain(.claude)
            }
            await supervisor.events.publish(
                sessionID: sessionID, change: .issue("Claude could not be started: \(error)")
            )
            throw error
        }
        if isResume { await reactivateAfterResume(sessionID) }
        runs[runID] = RunRecord(
            runID: runID, launchSessionID: sessionID, provider: .claude, server: nil, startedAt: Date(),
            isResume: isResume, diagnostics: nil, endpoint: .pipe(launch.pipe), activeSession: sessionID
        )
        // The run may already be over (an instant exit): release it now.
        await reconcileEnded()
        return RuntimePipeLaunch(sessionID: launch.session.id, runID: runID, pipe: launch.pipe)
    }
}
