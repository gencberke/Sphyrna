import Darwin
import Foundation

/// Resources belong to one native run, not to the provider profile or project.
final class AgyRunState: @unchecked Sendable {
    let sessionID: UUID
    let runID: UUID
    let directory: String
    let profileRoot: URL
    let discovery: URL
    let discoveryWitness: AgyDiscoveryWitness
    let scope: RunScope
    let server: AgyHookServer
    let ingress: AgyHookIngress
    var consumer: Task<Void, Never>?
    var nativeID: UUID?
    var reportedModel: String?

    init(sessionID: UUID, runID: UUID, directory: String, profileRoot: URL, discovery: URL,
         witness: AgyDiscoveryWitness, scope: RunScope, server: AgyHookServer,
         ingress: AgyHookIngress, nativeID: UUID?) {
        self.sessionID = sessionID; self.runID = runID; self.directory = directory
        self.profileRoot = profileRoot; self.discovery = discovery
        discoveryWitness = witness
        self.scope = scope; self.server = server; self.ingress = ingress; self.nativeID = nativeID
    }
}

extension SessionRuntime {
    func startAgy(_ start: HarnessTerminalStart) async throws -> RuntimeLaunch {
        guard start.opening?.approvedTask == nil else { throw SessionTaskError.unauthorized }
        let choices = start.draft?.choices ?? start.opening?.choices ?? HarnessLaunchChoices(harness: .agy)
        let message = start.draft?.firstMessage ?? start.opening?.firstMessage
        // Validate every native choice before a workspace or catalog mutation.
        _ = try AgyLaunchProfile.terminal(route: .new(firstMessage: message), choices: choices,
            discoveryDirectory: catalog.dataRoot, environment: [:])
        guard start.toolchain.extraArguments.isEmpty else { throw AgyLaunchError.unsupportedChoice }
        guard supervisor.runScopesEnabled, let home = start.toolchain.environment["HOME"],
              home.hasPrefix("/"), !home.utf8.contains(0) else { throw AgyLaunchError.invalidTarget }
        _ = try ensureHooks()
        let prepared = try await GitWorkspace.begin(start.draft?.workspace ?? .projectFolder, projectFolder: start.directory)
        do {
            try await supervisor.createSession(ManagedSession(id: start.sessionID, provider: .agy,
                workingDirectory: prepared.folder), projectID: start.projectID,
                title: start.opening?.title, openedBy: start.opening?.openedBy)
            startingSessions.insert(start.sessionID)
            defer { startingSessions.remove(start.sessionID) }
            let launch = try await launchAgy(sessionID: start.sessionID, runID: start.runID,
                directory: prepared.folder, toolchain: start.toolchain, route: .new(firstMessage: message),
                choices: choices, rows: start.rows, columns: start.columns, output: start.outputSink, tee: nil)
            do {
                try await catalog.recordLaunchChoices(choices, sessionID: start.sessionID,
                    rememberingInProject: start.opening == nil, completeNewStart: start.draft != nil)
            } catch {
                LoomLog.error(.catalog, "AGY launch choices could not be recorded (\(LoomLog.category(of: error)))")
            }
            await start.onTerminalReady?(launch)
            return launch
        } catch {
            if error as? AgyLaunchError == .cleanupUnverified { throw error }
            let failures = await GitWorkspace.undo(prepared)
            guard !failures.isEmpty else { throw error }
            throw LoomError.message("\(error). Not undone: \(failures.joined(separator: "; "))")
        }
    }

    func resumeAgy(_ resume: HarnessTerminalResume) async throws -> RuntimeLaunch {
        guard let native = UUID(uuidString: resume.conversationID), resume.toolchain.extraArguments.isEmpty else {
            throw AgyLaunchError.invalidTarget
        }
        guard !agyRuns.values.contains(where: { $0.sessionID == resume.session.id }) else {
            throw SessionRuntimeError.unverifiedStop(resume.session.id)
        }
        let runID = taskRunPlans[resume.session.id]?.claim.managedRunID ?? UUID()
        let launch = try await launchAgy(sessionID: resume.session.id, runID: runID,
            directory: resume.session.workingDirectory, toolchain: resume.toolchain, route: .resume(native),
            choices: HarnessLaunchChoices(harness: .agy), rows: resume.rows, columns: resume.columns,
            output: resume.tee, tee: resume.tee)
        await reactivateAfterResume(resume.session.id)
        return launch
    }

    private func launchAgy(sessionID: UUID, runID: UUID, directory: String, toolchain: ProviderToolchain,
                           route: AgyLaunchProfile.Route, choices: HarnessLaunchChoices, rows: UInt16, columns: UInt16,
                           output: (any TerminalOutputSink)?, tee: DiagnosticOutputTee?) async throws -> RuntimeLaunch {
        guard !shuttingDown, supervisor.runScopesEnabled,
              let home = toolchain.environment["HOME"], home.hasPrefix("/"), !home.utf8.contains(0) else {
            throw AgyLaunchError.invalidTarget
        }
        let profileRoot = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        let discovery = try makeAgyDiscovery(runID: runID)
        var rootInfo = stat()
        guard lstat(discovery.path, &rootInfo) == 0, rootInfo.st_uid == geteuid(),
              rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw AgyLaunchError.cleanupUnverified
        }
        var witness: AgyDiscoveryWitness?
        var scope: RunScope?
        var server: AgyHookServer?
        do {
            _ = try AgySessionDiscovery.install(in: discovery, helper: URL(fileURLWithPath: configuration.hookHelperPath))
            guard let installed = AgyDiscoveryWitness.capture(root: discovery) else { throw AgyLaunchError.invalidTarget }
            witness = installed
            let hooks = try ensureHooks()
            let ownedScope = try await supervisor.openScope()
            scope = ownedScope
            let ingress = AgyHookIngress(supervisor: supervisor, runID: runID)
            var random = [UInt8](repeating: 0, count: 32)
            random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            let token = random.map { String(format: "%02x", $0) }.joined()
            // Reuse the existing stale-hook socket sweep after an app crash.
            let socket = configuration.socketDirectory.appendingPathComponent("h-\(runID.uuidString.prefix(8)).sock").path
            let hookServer = try AgyHookServer(path: socket, token: token, sessionID: sessionID,
                runID: runID, scope: ownedScope, helperPath: configuration.hookHelperPath, ingress: ingress)
            server = hookServer
            let native: UUID? = if case let .resume(id) = route { id } else { nil }
            let state = AgyRunState(sessionID: sessionID, runID: runID, directory: directory,
                profileRoot: profileRoot, discovery: discovery, witness: installed,
                scope: ownedScope, server: hookServer, ingress: ingress, nativeID: native)
            agyRuns[runID] = state
            var environment = LaunchEnvironment.make(base: toolchain.environment,
                runID: supervisor.ownershipRunID, sessionID: sessionID)
            for key in Array(environment.keys) where key.hasPrefix("SPHYRNA_TASK_") { environment[key] = nil }
            environment["LOOM_AGY_SOCKET"] = socket
            environment["LOOM_AGY_TOKEN"] = token
            environment["SPHYRNA_CLI"] = configuration.hookHelperPath
            environment["LOOM_CLI"] = configuration.hookHelperPath
            environment["LOOM_HOOK_TOKEN"] = hooks.authenticationToken
            if let control = hooks.controlSocketPath { environment["LOOM_CONTROL_SOCKET"] = control }
            let profile = try AgyLaunchProfile.terminal(route: route, choices: choices,
                                                        discoveryDirectory: discovery, environment: environment)
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            let launched = try await supervisor.launch(sessionID: sessionID, executable: toolchain.executable,
                arguments: profile.launchArguments(), environment: profile.environment, rows: rows, columns: columns,
                outputSink: output, managedRunID: runID, scope: ownedScope)
            let result = await register(launched, runID: runID, provider: .agy, server: nil, tee: tee)
            guard agyRuns[runID] === state else { throw AgyLaunchError.invalidTarget }
            state.consumer = Task { [weak self] in
                for await event in ingress.stream { await self?.receiveAgyHook(event, runID: runID) }
            }
            return result
        } catch {
            if let scope {
                let errors = await supervisor.releaseScope(scope)
                guard errors.isEmpty else { throw AgyLaunchError.cleanupUnverified }
            }
            if agyRuns[runID] != nil {
                guard (await finishAgyRun(runID)).isEmpty else { throw AgyLaunchError.cleanupUnverified }
            } else {
                if let server, !(await server.stopAndWait()) { throw AgyLaunchError.cleanupUnverified }
                // If installation failed before a complete witness existed,
                // remove only an empty root and preserve partial resources.
                let removed = if let witness { witness.remove() }
                    else { removeEmptyAgyDiscovery(discovery, device: rootInfo.st_dev, inode: rootInfo.st_ino) }
                guard removed else {
                    throw AgyLaunchError.cleanupUnverified
                }
            }
            throw error
        }
    }

    func receiveAgyHook(_ event: AgyHookEvent, runID: UUID) async {
        guard let state = agyRuns[runID], !shuttingDown,
              let context = await supervisor.runContext(runID: runID),
              context.launchSessionID == state.sessionID, context.activeSessionID == state.sessionID,
              context.session.currentRun?.id == runID, context.session.currentRun?.state == .running,
              supervisor.providerWorkStateIsReliable(runID: runID),
              validAgyPaths(event, state: state) else { return }
        if let expected = state.nativeID {
            guard expected == event.conversationID else {
                try? await supervisor.setIdentityState(.ambiguous, runID: runID)
                try? await supervisor.updateProviderWorkState(runID: runID, state: ProviderWorkState(activity: .unknown))
                return
            }
        } else {
            guard event.kind == .sessionStart else { return }
            do {
                let adopted = try await supervisor.adoptConversation(runID: runID,
                    conversationID: event.conversationID.uuidString.lowercased(), transition: .bind)
                guard adopted == state.sessionID, agyRuns[runID] === state,
                      await supervisor.runContext(runID: runID)?.activeSessionID == state.sessionID else { return }
                state.nativeID = event.conversationID
            } catch { return }
        }
        guard agyRuns[runID] === state, !shuttingDown else { return }
        if let model = event.modelName { state.reportedModel = model }
        let activity: AgentActivity
        switch event.kind {
        case .sessionStart: activity = .unknown
        case .preInvocation, .postInvocation, .postToolUse: activity = .working
        // The hook runs before the native policy decides whether to ask the user.
        case .preToolUse: activity = .unknown
        case .stop:
            if event.fullyIdle == false { activity = .working }
            else if event.terminationReason == "model_stop" { activity = .turnComplete }
            else if event.terminationReason == "error" || event.terminationReason == "max_steps_exceeded" { activity = .failed(nil) }
            else { activity = .unknown }
        }
        try? await supervisor.updateAgyWorkState(sessionID: state.sessionID, runID: runID,
                                                 state: ProviderWorkState(activity: activity))
    }

    private func validAgyPaths(_ event: AgyHookEvent, state: AgyRunState) -> Bool {
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let paths = Set(event.workspacePaths.map(canonical))
        guard paths.contains(canonical(state.directory)), paths.contains(canonical(state.discovery.path)) else { return false }
        let root = state.profileRoot.appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent(event.conversationID.uuidString.lowercased(), isDirectory: true)
        let transcript = root.appendingPathComponent(".system_generated/logs/transcript.jsonl")
        return canonical(event.artifactDirectoryPath) == canonical(root.path) &&
            canonical(event.transcriptPath) == canonical(transcript.path)
    }

    /// Native-reported model only; nil is unknown. Requested catalog choices
    /// remain separate and are never overwritten by this observation.
    public func agyReportedModel(sessionID: UUID) -> String? {
        agyRuns.values.first { $0.sessionID == sessionID }?.reportedModel
    }

    func finishAgyRun(_ runID: UUID) async -> [String] {
        guard let state = agyRuns[runID] else { return [] }
        state.ingress.finish(); state.consumer?.cancel()
        guard await state.server.stopAndWait() else { return ["AGY hook socket cleanup could not be verified"] }
        guard state.discoveryWitness.remove() else {
            return ["AGY discovery cleanup could not be verified"]
        }
        if agyRuns[runID] === state { agyRuns[runID] = nil }
        return []
    }

    private func makeAgyDiscovery(runID: UUID) throws -> URL {
        let parent = catalog.dataRoot.appendingPathComponent("agy-runs", isDirectory: true)
        if mkdir(parent.path, 0o700) != 0 && errno != EEXIST { throw AgyLaunchError.invalidTarget }
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_mode & 0o077 == 0 else { throw AgyLaunchError.invalidTarget }
        let root = parent.appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw AgyLaunchError.invalidTarget }
        return root
    }

    private func removeEmptyAgyDiscovery(_ root: URL, device: dev_t, inode: ino_t) -> Bool {
        var info = stat()
        if lstat(root.path, &info) != 0 { return errno == ENOENT }
        guard info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_dev == device, info.st_ino == inode else { return false }
        return rmdir(root.path) == 0 || errno == ENOENT
    }

}

extension ProcessSupervisor {
    /// Stop and identity changes win before a hook's state is published.
    func updateAgyWorkState(sessionID: UUID, runID: UUID, state: ProviderWorkState) async throws {
        guard !stopping, !stoppingRuns.contains(runID), let runtime = runtimes[runID],
              runtime.activeSessionID == sessionID, runtime.run.state == .running else {
            throw SessionManagementError.runNotFound(runID)
        }
        try await updateProviderWorkState(runID: runID, state: state)
    }
}
