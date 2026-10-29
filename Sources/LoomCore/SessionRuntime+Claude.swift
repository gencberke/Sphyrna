import Darwin
import Foundation
import os

extension SessionRuntime {
    /// Read with `log show --predicate 'subsystem == "local.loom.desktop" && category == "ClaudeHooks"' --info`.
    static let hookLog = LoomLog.logger(.claudeHooks)

    func ensureHooks() throws -> ClaudeHookLaunchConfiguration {
        if let hookConfiguration { return hookConfiguration }
        guard access(configuration.hookHelperPath, X_OK) == 0 else {
            throw ClaudeHookTransportError.invalidConfiguration(
                "hook helper is missing or not executable: \(configuration.hookHelperPath)"
            )
        }
        let socket = configuration.socketDirectory
            .appendingPathComponent("h-\(supervisor.ownershipRunID.uuidString.prefix(8)).sock").path
        let token = UUID().uuidString + UUID().uuidString
        // One ordered path from the socket to the reducers: hook events of a
        // run are applied in arrival order, never in racing tasks.
        let ingress = ClaudeHookIngress(adapter: harnesses.claude.adapter, taskIngress: taskIngress,
                                        limitObserver: limitResetObserver())
        let events = ingress.stream
        let server = try ClaudeHookServer(socketPath: socket, authenticationToken: token) { envelope in
            ingress.receive(envelope)
        }
        hookTask = Task { [weak self] in
            for await record in events { await self?.deliver(hook: record.envelope, limitRevision: record.limitRevision) }
        }
        hookServer = server
        // The request/response socket of `loom-hook open` (D-40), next to the hook socket and
        // under the same token. A failure to open it only costs that command, never the hooks.
        let controlSocket = configuration.socketDirectory
            .appendingPathComponent("c-\(supervisor.ownershipRunID.uuidString.prefix(8)).sock").path
        let requests = openRequests
        let directory = directory
        controlServer = try? OpenSessionControlServer(
            socketPath: controlSocket, authenticationToken: token,
            sessions: { call in await requests.listSessions(call, directory: directory) },
            whoAmI: { call in await requests.whoAmI(call, directory: directory) }
        ) { call in await requests.submit(call) }
        // The skill that tells the agent about that command (D-42) and Ask's output style (D-63): every Claude start passes the
        // plugin, also without the control socket (the style needs none). A failure to write it costs the skill and Ask:
        // the CLI then lists no `sphyrna:Ask` style and the Chat driver refuses to turn Ask on.
        var plugin: String?
        if let directory = configuration.claudePluginDirectory {
            do { plugin = try ClaudeLoomPlugin.install(in: directory).path } catch {
                // The category only: a write error can carry the plugin folder's home path.
                LoomLog.error(.claudeHooks, "Sphyrna's Claude plugin could not be written (\(LoomLog.category(of: error)))")
            }
        }
        let value = ClaudeHookLaunchConfiguration(
            helperPath: configuration.hookHelperPath, socketPath: socket,
            authenticationToken: token,
            controlSocketPath: controlServer == nil ? nil : controlSocket,
            pluginDirectory: plugin
        )
        hookConfiguration = value
        return value
    }

    private func deliver(hook envelope: ClaudeHookEnvelope, limitRevision: UInt64?) async {
        defer { taskIngress.finish(runID: envelope.managedRunID) }
        do {
            let disposition = try await harnesses.claude.adapter.receive(envelope)
            let event = try? ClaudeHookEvent(payload: envelope.payload)
            var name = event?.name ?? "unreadable"
            if case let .notification(type)? = event?.kind {
                name += "(\(type ?? "no type"))"
                // Informational types keep the state; logged so a new type is visible.
                if ClaudeHookStateTracker.notificationActivity(type) == nil, type != "permission_prompt" {
                    Self.hookLog.info("informational \(name, privacy: .public)")
                }
            }
            if case .applied = disposition {
                if let event {
                    await observeClaudeTaskHook(envelope, event: event)
                    await noteLimitHook(event, envelope: envelope, revision: limitRevision)
                }
                HookDiagnostics.note(.applied)
                LoomLog.debug(.claudeHooks, "applied \(name)")
                return
            }
            // Event and reason names only: a dropped event is otherwise invisible in a daily build.
            claudeLimitObserver?.discard(runID: envelope.managedRunID, revision: limitRevision)
            let reason = String(describing: disposition)
            HookDiagnostics.noteDropped(reason: reason)
            Self.hookLog.info("dropped \(name, privacy: .public): \(reason, privacy: .public)")
        } catch {
            claudeLimitObserver?.discard(runID: envelope.managedRunID, revision: limitRevision)
            HookDiagnostics.noteDropped(reason: "error")
            LoomLog.error(.claudeHooks, key: "hook-error", "A hook event could not be processed (\(LoomLog.category(of: error)))")
            guard let sessionID = await supervisor.activeSessionID(runID: envelope.managedRunID) else { return }
            await supervisor.events.publish(
                sessionID: sessionID,
                change: .issue("A Claude event could not be processed: \(error)")
            )
        }
    }

    /// The one line the card shows when a terminal run replaced Ask.
    static let askIsChatOnlyNotice = "Ask works in Chat. This terminal session runs in Ask before edits."

    /// The rule of the terminal face about Ask (D-63), in the one place every terminal spawn goes through: `claudeProfile` with
    /// face `.terminal` (a new start, a resume, a handover to the terminal, an Open Session request). Ask is a mode of the Chat
    /// face. Its rules and style are live settings of the Chat driver, so a TUI started in `dontAsk` would refuse whatever asks
    /// with nothing behind it: the terminal runs Ask before edits (`default`) instead. A pure function: whether it replaced Ask
    /// goes into the profile (`ProviderLaunchProfile.replacedAsk`), and the spawn that follows (`launchClaude`) records what
    /// really runs, so every later spawn in either face passes it, and says so in one line. Every other mode, Full access
    /// included, goes through as chosen.
    static func terminalAskRule(_ choices: ClaudeLaunchChoices) -> (choices: ClaudeLaunchChoices, replaced: Bool) {
        guard let mode = choices.permissionMode,
              mode == ClaudePermissionMode.ask.rawValue || mode == ClaudePermissionMode.ask.cliValue else { return (choices, false) }
        var replaced = choices
        replaced.permissionMode = ClaudePermissionMode.askBeforeEdits.rawValue
        return (replaced, true)
    }

    func claudeProfile(
        route: ProviderLaunchProfile.ClaudeRoute, toolchain: ProviderToolchain,
        sessionID: UUID, hooks: ClaudeHookLaunchConfiguration,
        choices: ClaudeLaunchChoices = ClaudeLaunchChoices(),
        opening: ProviderLaunchProfile.ClaudeOpening? = nil,
        face: ProviderLaunchProfile.ClaudeFace = .terminal,
        askRules: [String] = []
    ) throws -> ProviderLaunchProfile {
        let (choices, askReplaced) = face == .terminal ? Self.terminalAskRule(choices) : (choices, false)
        let environment = LaunchEnvironment.make(
            base: toolchain.environment, runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        var effort: String?
        var model: String?
        // The session's own record names the effort and the model first (`ClaudeLaunchChoices`); the transcript is the
        // fallback, since neither face restores them on `--resume` (spike S2).
        // A fork takes them from its parent's transcript: it starts with the parent's choices, as the cache prefix needs.
        let transcriptConversation: String? = switch route {
        case let .resume(conversationID): conversationID
        case let .fork(parent, _): parent
        case .new: nil
        }
        if let conversationID = transcriptConversation {
            let layout = ClaudeProfileLayout(
                toolchain: toolchain, home: URL(fileURLWithPath: configuration.homeDirectory, isDirectory: true)
            )
            if choices.effort == nil, toolchain.capabilities.supportsEffort {
                effort = ClaudeTranscriptEffort.last(conversationID: conversationID, projectsDirectory: layout.projectsDirectory)
            }
            if choices.model == nil, toolchain.capabilities.claudeAcceptsModel {
                // The transcript's id has no `[1m]`: when the configured default is that very model, passing nothing keeps the
                // default as it is, window included.
                if let ran = ClaudeTranscriptModel.last(conversationID: conversationID, projectsDirectory: layout.projectsDirectory),
                   ClaudeLaunchChoices.isSafeToken(ran) {
                    let configured = ClaudeDefaultModel.configured(
                        configDirectory: layout.configDirectory, environment: toolchain.environment)
                    model = configured.map { ClaudeDefaultModel.matches(default: $0, transcriptModel: ran) } == true ? nil : ran
                }
            }
        }
        reportCompatibility(toolchain: toolchain, route: route, opening: opening)
        let built = try ProviderLaunchProfile.claude(
            route: route, capabilities: toolchain.capabilities,
            config: toolchain.profileDirectory ?? URL(fileURLWithPath: "/"),
            environment: environment, hooks: hooks, effort: effort, model: model, choices: choices, opening: opening, face: face,
            askRules: askRules
        )
        var profileEnvironment = built.environment
        if face == .terminal { profileEnvironment.merge(taskEnvironment(sessionID: sessionID)) { _, task in task } }
        // The provider's own default profile: do not pin a config directory.
        if toolchain.profileDirectory == nil { profileEnvironment["CLAUDE_CONFIG_DIR"] = toolchain.environment["CLAUDE_CONFIG_DIR"] }
        return ProviderLaunchProfile(
            arguments: built.arguments, environment: profileEnvironment,
            trailingArguments: built.trailingArguments, replacedAsk: askReplaced
        )
    }

    func launchClaude(
        sessionID: UUID, runID: UUID?, toolchain: ProviderToolchain,
        profile: ProviderLaunchProfile, rows: UInt16, columns: UInt16,
        outputSink: (any TerminalOutputSink)?, tee: DiagnosticOutputTee?
    ) async throws -> RuntimeLaunch {
        // The run id is chosen here so a run that ends before `launch` returns
        // (an instant provider failure) is still known and diagnosed.
        let runID = runID ?? taskRunPlans[sessionID]?.claim.managedRunID ?? UUID()
        // Ask was replaced in this spawn's profile (`terminalAskRule`): the catalog records what runs before it does.
        let askReplaced = profile.replacedAsk
        if askReplaced {
            await recordLaunchChoices(ClaudeLaunchChoices(permissionMode: ClaudePermissionMode.askBeforeEdits.rawValue), sessionID: sessionID)
        }
        let launch: ManagedSessionLaunch
        do {
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            launch = try await supervisor.launch(
                sessionID: sessionID, executable: toolchain.executable,
                arguments: profile.launchArguments(extra: toolchain.extraArguments),
                environment: profile.environment, rows: rows, columns: columns,
                outputSink: tee ?? outputSink, managedRunID: runID
            )
        } catch {
            LoomLog.error(.lifecycle, "Claude could not be started (\(LoomLog.category(of: error)))")
            // The CLI may have been replaced or removed since it was read: read it again next time.
            if !(error is SessionRuntimeError), !(error is SessionManagementError) {
                await invalidateToolchain(.claude)
            }
            await supervisor.events.publish(
                sessionID: sessionID, change: .issue("Claude could not be started: \(error)")
            )
            throw error
        }
        if tee != nil { await reactivateAfterResume(sessionID) }
        if let leader = launch.session.currentRun?.leader {
            let config = profile.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
            await harnesses.claude.observeRegistry(runID: runID, reader: ClaudeRegistryReader(
                config: config.resolvingSymlinksInPath(), leader: leader,
                directory: URL(fileURLWithPath: launch.session.workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path))
        }
        let registered = await register(launch, runID: runID, provider: .claude, server: nil, tee: tee)
        if askReplaced {
            await supervisor.events.publish(sessionID: sessionID, change: .issue(Self.askIsChatOnlyNotice))
        }
        return registered
    }
}
