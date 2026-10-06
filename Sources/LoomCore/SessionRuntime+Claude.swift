import Darwin
import Foundation

extension SessionRuntime {
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
        let value = ClaudeHookLaunchConfiguration(
            helperPath: configuration.hookHelperPath, socketPath: socket,
            authenticationToken: token
        )
        hookConfiguration = value
        return value
    }

    private func deliver(hook envelope: ClaudeHookEnvelope) async {
        do {
            _ = try await claudeAdapter.receive(envelope)
        } catch {
            guard let sessionID = await supervisor.activeSessionID(runID: envelope.managedRunID) else { return }
            await supervisor.events.publish(
                sessionID: sessionID,
                change: .issue("A Claude event could not be processed: \(error)")
            )
        }
    }

    func claudeProfile(
        route: ProviderLaunchProfile.ClaudeRoute, toolchain: ProviderToolchain,
        sessionID: UUID, hooks: ClaudeHookLaunchConfiguration
    ) throws -> ProviderLaunchProfile {
        let environment = LaunchEnvironment.make(
            base: toolchain.environment, runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        let profile = try ProviderLaunchProfile.claude(
            route: route, capabilities: toolchain.capabilities,
            config: toolchain.profileDirectory ?? URL(fileURLWithPath: "/"),
            environment: environment, hooks: hooks
        )
        guard toolchain.profileDirectory == nil else { return profile }
        // The provider's own default profile: do not pin a config directory.
        var defaulted = profile.environment
        defaulted["CLAUDE_CONFIG_DIR"] = toolchain.environment["CLAUDE_CONFIG_DIR"]
        return ProviderLaunchProfile(arguments: profile.arguments, environment: defaulted)
    }

    func launchClaude(
        sessionID: UUID, runID: UUID?, toolchain: ProviderToolchain,
        profile: ProviderLaunchProfile, rows: UInt16, columns: UInt16,
        outputSink: (any TerminalOutputSink)?, tee: DiagnosticOutputTee?
    ) async throws -> RuntimeLaunch {
        // The run id is chosen here so a run that ends before `launch` returns
        // (an instant provider failure) is still known and diagnosed.
        let runID = runID ?? UUID()
        let launch: ManagedSessionLaunch
        do {
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            launch = try await supervisor.launch(
                sessionID: sessionID, executable: toolchain.executable,
                arguments: profile.arguments + toolchain.extraArguments,
                environment: profile.environment, rows: rows, columns: columns,
                outputSink: tee ?? outputSink, managedRunID: runID
            )
        } catch {
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
        return await register(launch, runID: runID, provider: .claude, server: nil, tee: tee)
    }
}
