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
        let ingress = ClaudeHookIngress(adapter: claudeAdapter)
        let events = ingress.stream
        let server = try ClaudeHookServer(socketPath: socket, authenticationToken: token) { envelope in
            ingress.receive(envelope)
        }
        hookTask = Task { [weak self] in
            for await envelope in events { await self?.deliver(hook: envelope) }
        }
        hookServer = server
        // The request/response socket of `loom-hook open` (D-40), next to the hook socket and
        // under the same token. A failure to open it only costs that command, never the hooks.
        let controlSocket = configuration.socketDirectory
            .appendingPathComponent("c-\(supervisor.ownershipRunID.uuidString.prefix(8)).sock").path
        let requests = openRequests
        controlServer = try? OpenSessionControlServer(
            socketPath: controlSocket, authenticationToken: token
        ) { call in await requests.submit(call) }
        // The skill that tells the agent about that command (D-42) and Ask's output style (D-63): every Claude start passes the
        // plugin, also without the control socket (the style needs none). A failure to write it costs the skill and Ask:
        // the CLI then lists no `loom:Ask` style and the Chat driver refuses to turn Ask on.
        var plugin: String?
        if let directory = configuration.claudePluginDirectory {
            do { plugin = try ClaudeLoomPlugin.install(in: directory).path } catch {
                Self.hookLog.error("Loom's Claude plugin could not be written: \(String(describing: error), privacy: .public)")
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

    private func deliver(hook envelope: ClaudeHookEnvelope) async {
        do {
            let disposition = try await claudeAdapter.receive(envelope)
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
                HookDiagnostics.note(.applied)
                LoomLog.debug(.claudeHooks, "applied \(name)")
                return
            }
            // Event and reason names only: a dropped event is otherwise invisible in a daily build.
            let reason = String(describing: disposition)
            HookDiagnostics.noteDropped(reason: reason)
            Self.hookLog.info("dropped \(name, privacy: .public): \(reason, privacy: .public)")
        } catch {
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
    /// with nothing behind it: the terminal runs Ask before edits (`default`) instead. The spawn that follows (`launchClaude`)
    /// records what really runs, so every later spawn in either face passes it, and says so in one line. Every other mode,
    /// Full access included, goes through as chosen.
    func terminalAskRule(_ choices: ClaudeLaunchChoices, sessionID: UUID) -> ClaudeLaunchChoices {
        askReplacedInTerminal.remove(sessionID)
        guard let mode = choices.permissionMode,
              mode == ClaudePermissionMode.ask.rawValue || mode == ClaudePermissionMode.ask.cliValue else { return choices }
        askReplacedInTerminal.insert(sessionID)
        var replaced = choices
        replaced.permissionMode = ClaudePermissionMode.askBeforeEdits.rawValue
        return replaced
    }

    func claudeProfile(
        route: ProviderLaunchProfile.ClaudeRoute, toolchain: ProviderToolchain,
        sessionID: UUID, hooks: ClaudeHookLaunchConfiguration,
        choices: ClaudeLaunchChoices = ClaudeLaunchChoices(),
        opening: ProviderLaunchProfile.ClaudeOpening? = nil,
        face: ProviderLaunchProfile.ClaudeFace = .terminal
    ) throws -> ProviderLaunchProfile {
        let choices = face == .terminal ? terminalAskRule(choices, sessionID: sessionID) : choices
        let environment = LaunchEnvironment.make(
            base: toolchain.environment, runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        var effort: String?
        // The session's own record names the effort first (`ClaudeLaunchChoices`); the transcript is the fallback.
        if choices.effort == nil, case let .resume(conversationID) = route, toolchain.capabilities.supportsEffort {
            let profile = ClaudeProfileLayout(
                toolchain: toolchain, home: URL(fileURLWithPath: configuration.homeDirectory, isDirectory: true)
            )
            effort = ClaudeTranscriptEffort.last(conversationID: conversationID, projectsDirectory: profile.projectsDirectory)
        }
        reportCompatibility(toolchain: toolchain, route: route, opening: opening)
        let profile = try ProviderLaunchProfile.claude(
            route: route, capabilities: toolchain.capabilities,
            config: toolchain.profileDirectory ?? URL(fileURLWithPath: "/"),
            environment: environment, hooks: hooks, effort: effort, choices: choices, opening: opening, face: face
        )
        guard toolchain.profileDirectory == nil else { return profile }
        // The provider's own default profile: do not pin a config directory.
        var defaulted = profile.environment
        defaulted["CLAUDE_CONFIG_DIR"] = toolchain.environment["CLAUDE_CONFIG_DIR"]
        return ProviderLaunchProfile(
            arguments: profile.arguments, environment: defaulted,
            trailingArguments: profile.trailingArguments
        )
    }

    func launchClaude(
        sessionID: UUID, runID: UUID?, toolchain: ProviderToolchain,
        profile: ProviderLaunchProfile, rows: UInt16, columns: UInt16,
        outputSink: (any TerminalOutputSink)?, tee: DiagnosticOutputTee?
    ) async throws -> RuntimeLaunch {
        // The run id is chosen here so a run that ends before `launch` returns
        // (an instant provider failure) is still known and diagnosed.
        let runID = runID ?? UUID()
        // Ask was replaced for this spawn (`terminalAskRule`): the catalog records what runs before it does.
        let askReplaced = askReplacedInTerminal.remove(sessionID) != nil
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
            await claudeAdapter.observeRegistry(runID: runID, reader: ClaudeRegistryReader(
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
