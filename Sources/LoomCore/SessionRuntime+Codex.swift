import Darwin
import Foundation

extension SessionRuntime {
    /// One app-server per Codex conversation run. It owns its socket, scope,
    /// client, coordinator and approval state, so nothing is shared between
    /// conversations. The run record references it; it is kept (even after the
    /// run ended) until its stop is verified.
    final class CodexServer {
        let id = UUID()
        /// The card a failed teardown is retried for (resume of that card).
        var ownerCard: UUID
        let manager: CodexAppServerManager
        let socket: String
        let scope: RunScope?
        var runID: UUID?
        var client: CodexAppServerClient?
        var coordinator: CodexSessionCoordinator?
        var resumeSettings: CodexResumeSettings?
        var taskSkillRoot: URL?
        var taskDiscovery: SessionTaskDiscovery = .unavailable
        var setup: (id: UUID, task: Task<CodexSessionCoordinator, any Error>)?
        var requestTask: Task<Void, Never>?
        var requests: [String: CodexPendingRequest] = [:]
        var requestRevision: UInt64 = 0
        var requestOwners: [String: UUID] = [:]
        var failedRequests: [String: String] = [:]
        var teardownTask: Task<[String], Never>?
        var finished = false
        init(ownerCard: UUID, manager: CodexAppServerManager, socket: String, scope: RunScope?) {
            self.ownerCard = ownerCard
            self.manager = manager
            self.socket = socket
            self.scope = scope
        }
    }

    /// Test access: the coordinator of the oldest live Codex server.
    var codexCoordinator: CodexSessionCoordinator? {
        codexServers.lazy.compactMap(\.coordinator).first
    }
    func codexCoordinator(forSession key: UUID) async -> CodexSessionCoordinator? {
        await codexServer(forCard: key)?.coordinator
    }

    /// The provider's settings when this run resumed, not a second saved default.
    public func codexResumeSettings(forSession key: UUID) async -> CodexResumeSettings? {
        await codexServer(forCard: key)?.resumeSettings
    }

    /// Whether the owned server listed the enabled Sphyrna task skill. This
    /// does not promise that the provider selected it for the model's context.
    public func codexTaskDiscovery(forSession key: UUID) async -> SessionTaskDiscovery {
        await codexServer(forCard: key)?.taskDiscovery ?? .unavailable
    }

    public func codexRoutingDiagnostics() async -> CodexRoutingDiagnostics.Snapshot {
        await routingDiagnostics.snapshot()
    }

    /// The Codex app-servers that exist: one per live Codex run, kept until
    /// its stop is verified. `internalSessionID` is the oldest running one's
    /// internal (never catalogued) server session.
    public func codexServerState() async -> (servers: Int, internalSessionID: UUID?) {
        (codexServers.count, await codexServerSessionIDs().first)
    }

    /// Internal server sessions of every conversation server that is running.
    public func codexServerSessionIDs() async -> [UUID] {
        var ids: [UUID] = []
        for server in codexServers {
            if let id = await server.manager.internalSessionID() { ids.append(id) }
        }
        return ids
    }

    /// The internal server session and scope of the server a card is using:
    /// the run now on that card, else the run launched under it.
    func codexServerIdentity(forSession key: UUID) async -> (internalSessionID: UUID?, scope: RunScope?)? {
        guard let server = await codexServer(forCard: key) else { return nil }
        return (await server.manager.internalSessionID(), server.scope)
    }

    private func codexServer(forCard key: UUID) async -> CodexServer? {
        for record in runs.values {
            if let server = record.server, await supervisor.activeSessionID(runID: record.runID) == key { return server }
        }
        for record in runs.values where record.launchSessionID == key {
            if let server = record.server { return server }
        }
        return codexServers.last { $0.ownerCard == key }
    }

    /// Sends the user's decision to Codex. A failed write keeps the request
    /// open with the failure; it is never treated as an answer.
    public func respond(
        sessionID: UUID, requestID: String, decision: ProviderRequestDecision
    ) async throws {
        guard let server = codexServers.first(where: { $0.requestOwners[requestID] == sessionID }),
              let pending = server.requests[requestID], let coordinator = server.coordinator else {
            throw SessionRuntimeError.requestNotPending(requestID)
        }
        let request = pending.request
        guard request.kind == .commandExecution || request.kind == .fileChange else {
            throw SessionRuntimeError.requestNotPending(requestID)
        }
        let answer: JSONValue = .object([
            "decision": .string(decision == .accept ? "accept" : "decline"),
        ])
        do {
            try await coordinator.respond(to: pending, result: answer)
        } catch {
            // The coordinator alone recognizes an authoritative resolution
            // winning the write race. Cleanup removing a request is not success.
            await received(requests: await coordinator.pendingRequestSnapshot(), from: coordinator)
            if server.requests[requestID] != nil {
                await markRequestFailed(
                    requestID, CodexSessionCoordinator.failureText("The answer was not delivered", error), in: server
                )
            }
            throw error
        }
        await received(requests: await coordinator.pendingRequestSnapshot(), from: coordinator)
    }

    private func codexHome(_ toolchain: ProviderToolchain) -> URL {
        toolchain.profileDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    func codexNewProfile(
        toolchain: ProviderToolchain, sessionID: UUID, directory: String, server: CodexServer,
        choices: HarnessLaunchChoices? = nil, firstMessage: String? = nil
    ) throws -> ProviderLaunchProfile {
        var environment = LaunchEnvironment.make(
            base: toolchain.environment, runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        environment.merge(taskEnvironment(sessionID: sessionID)) { _, task in task }
        return try ProviderLaunchProfile.codex(
            route: .remote(socket: server.socket, threadID: nil, workingDirectory: directory),
            capabilities: toolchain.capabilities, home: codexHome(toolchain),
            environment: environment, choices: choices, firstMessage: firstMessage
        )
    }

    func launchNewCodex(
        sessionID: UUID, runID: UUID, directory: String, toolchain: ProviderToolchain,
        profile: ProviderLaunchProfile, server: CodexServer, coordinator: CodexSessionCoordinator,
        rows: UInt16, columns: UInt16, outputSink: (any TerminalOutputSink)?,
        onTerminalReady: (@MainActor @Sendable (RuntimeLaunch) async -> Void)?
    ) async throws -> RuntimeLaunch {
        await refreshTaskDiscovery(server: server, directory: directory)
        let reservation = await coordinator.reserveNewLaunch(
            sessionID: sessionID, managedRunID: runID, workingDirectory: directory
        )
        reservations[sessionID] = (reservation, coordinator)
        defer {
            reservations[sessionID] = nil
            stopRequestedRuns.remove(runID)
            startupConnectionFailures[sessionID] = nil
        }
        let launch: ManagedSessionLaunch
        do {
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            launch = try await supervisor.launch(
                sessionID: sessionID, executable: toolchain.executable,
                arguments: profile.launchArguments(extra: toolchain.extraArguments),
                environment: profile.environment, rows: rows,
                columns: columns, outputSink: outputSink, managedRunID: runID,
                scope: server.scope
            )
        } catch {
            await coordinator.cancelNewLaunch(reservation)
            let failure = await startFailure(error, cleaning: server)
            await supervisor.events.publish(
                sessionID: sessionID, change: .issue("Codex could not be started: \(error)")
            )
            throw failure
        }
        let registered = await register(launch, runID: runID, provider: .codex, server: server, tee: nil)
        await onTerminalReady?(registered)
        do {
            _ = try await coordinator.waitForNewLaunch(
                reservation, timeout: onTerminalReady == nil ? configuration.codexIdentityTimeout : nil
            )
        } catch {
            if shuttingDown || stopRequestedRuns.contains(runID) {
                throw CancellationError()
            }
            if let failure = startupConnectionFailures[sessionID] {
                await undoLaunch(registered, reason: failure)
                throw LoomError.message(failure)
            }
            let exited = await supervisor.runContext(runID: registered.runID) == nil
            await undoLaunch(registered, reason: shuttingDown
                ? "Sphyrna was quitting"
                : exited ? "Codex exited before it reported a session identity"
                : "Codex did not report its session identity in time")
            if exited { throw LoomError.message("Codex exited before it reported a session identity") }
            throw SessionRuntimeError.providerIdentityTimeout(.codex)
        }
        return registered
    }

    func resumeCodex(
        session: ManagedSession, conversationID: String, toolchain: ProviderToolchain,
        server: CodexServer, coordinator: CodexSessionCoordinator,
        rows: UInt16, columns: UInt16, tee: DiagnosticOutputTee
    ) async throws -> RuntimeLaunch {
        let socket = server.socket
        let runID = taskRunPlans[session.id]?.claim.managedRunID ?? UUID()
        let launch: ManagedSessionLaunch
        do {
            guard let client = server.client else { throw CodexAppServerError.closed }
            server.resumeSettings = try await client.resumeThread(conversationID, workingDirectory: session.workingDirectory)
            await refreshTaskDiscovery(server: server, directory: session.workingDirectory)
            var environment = LaunchEnvironment.make(
                base: toolchain.environment, runID: supervisor.ownershipRunID, sessionID: session.id
            )
            environment.merge(taskEnvironment(sessionID: session.id)) { _, task in task }
            let profile = try ProviderResumePlanner.codex(
                session: session, socketPath: socket, capabilities: toolchain.capabilities,
                home: codexHome(toolchain), environment: environment
            )
            launch = try await supervisor.launch(
                sessionID: session.id, executable: toolchain.executable,
                arguments: profile.launchArguments(extra: toolchain.extraArguments),
                environment: profile.environment, rows: rows,
                columns: columns, outputSink: tee, managedRunID: runID,
                scope: server.scope
            )
        } catch {
            let reason: any Error
            if let rpc = error as? CodexAppServerError, rpc.isThreadNotFound {
                reason = LoomError.providerHistoryUnavailable(provider: .codex, conversationID: conversationID)
            } else { reason = error }
            let failure = await startFailure(reason, cleaning: server)
            await supervisor.events.publish(
                sessionID: session.id, change: .issue("Codex could not be resumed: \(reason)")
            )
            throw failure
        }
        await reactivateAfterResume(session.id)
        let registered = await register(launch, runID: runID, provider: .codex, server: server, tee: tee)
        do {
            try await coordinator.bindResume(
                sessionID: session.id, managedRunID: registered.runID,
                threadID: conversationID, workingDirectory: session.workingDirectory
            )
        } catch {
            // A TUI that already exited (deleted history) has no run to bind;
            // its own output explains why and is reported from the end handler.
            if await supervisor.runContext(runID: registered.runID) == nil {
                await reconcileEnded()
                return registered
            }
            await undoLaunch(registered, reason: "Codex resume could not be bound: \(error)")
            throw error
        }
        return registered
    }

    // MARK: Codex plumbing

    /// Starts a new app-server (in its own run scope when scopes are on) and
    /// the coordinator that watches it, for one run of the conversation on
    /// `card`. Nothing is shared with any other run; a server a live run still
    /// references is never touched. On any failure what started is stopped again.
    func ensureCodex(
        card: UUID, toolchain: ProviderToolchain, choices: HarnessLaunchChoices? = nil
    ) async throws -> (CodexServer, CodexSessionCoordinator) {
        try Task.checkCancellation()
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        // A server this card left behind by an earlier run (a Stop that could
        // not be verified, or a teardown still finishing) must be gone first.
        let referenced = Set(runs.values.compactMap { $0.server?.id })
        for previous in codexServers where previous.ownerCard == card && !referenced.contains(previous.id) {
            let errors = await tearDown(previous)
            guard errors.isEmpty else {
                throw LoomError.message(
                    "The previous Codex app-server of this session could not be stopped: \(errors.joined(separator: "; "))"
                )
            }
        }
        let server = try await makeCodexServer(card: card, toolchain: toolchain, choices: choices)
        codexServers.append(server)
        do {
            let client = try await server.manager.start()
            try Task.checkCancellation()
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            let id = UUID()
            let task = Task { try await self.installCodexCoordinator(server: server, client: client, setupID: id) }
            // Published before the first suspension so Quit can find and cancel it.
            server.setup = (id, task)
            let coordinator = try await task.value
            if server.setup?.id == id { server.setup = nil }
            try Task.checkCancellation()
            guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
            guard server.client === client, server.coordinator === coordinator else { throw CancellationError() }
            return (server, coordinator)
        } catch {
            server.setup = nil
            throw await startFailure(error, cleaning: server)
        }
    }

    /// A start that failed after its server existed: stop the server again.
    /// A cleanup that cannot be verified is part of the error the caller gets,
    /// because the card it would belong on does not exist (yet).
    func startFailure(_ error: any Error, cleaning server: CodexServer) async -> any Error {
        let cleanup = await tearDown(server)
        guard !cleanup.isEmpty else { return error }
        return LoomError.message(
            "\(error); the Codex app-server could not be fully stopped: \(cleanup.joined(separator: "; "))"
        )
    }

    private func makeCodexServer(card: UUID, toolchain: ProviderToolchain, choices: HarnessLaunchChoices?) async throws -> CodexServer {
        try FileManager.default.createDirectory(
            at: configuration.socketDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Unique per server and short: Unix socket paths are limited to ~100 bytes.
        let socket = configuration.socketDirectory
            .appendingPathComponent("c-\(UUID().uuidString.prefix(8)).sock").path
        var scope: RunScope?
        if supervisor.runScopesEnabled {
            scope = try await supervisor.openScope()
            if shuttingDown {
                _ = await supervisor.releaseScope(scope!)
                throw SessionRuntimeError.shuttingDown
            }
        }
        var serverEnvironment = toolchain.environment
        serverEnvironment.merge(taskEnvironment(sessionID: card)) { _, task in task }
        let manager = CodexAppServerManager(
            supervisor: supervisor,
            configuration: CodexAppServerConfiguration(
                executable: toolchain.executable, capabilities: toolchain.capabilities,
                home: codexHome(toolchain),
                baseEnvironment: serverEnvironment,
                workingDirectory: configuration.homeDirectory, socketPath: socket,
                clientVersion: configuration.clientVersion, launchChoices: choices,
                startupTimeout: configuration.codexServerStartupTimeout,
                scope: scope,
                optOutNotificationMethods: taskRunPlans[card] == nil
                    ? CodexAppServerClient.productOptOutNotificationMethods
                    : CodexAppServerClient.productOptOutNotificationMethods.filter { $0 != "item/started" }
            )
        )
        return CodexServer(ownerCard: card, manager: manager, socket: socket, scope: scope)
    }

    private func requireCodexSetup(_ server: CodexServer, _ id: UUID) throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        guard server.setup?.id == id else { throw CancellationError() }
    }

    private func installCodexCoordinator(
        server: CodexServer, client: CodexAppServerClient, setupID: UUID
    ) async throws -> CodexSessionCoordinator {
        let coordinator = CodexSessionCoordinator(
            client: client, supervisor: supervisor, adapter: harnesses.codex.adapter,
            router: CodexSessionRouter(diagnostics: routingDiagnostics)
        )
        do {
            await codexSetupObserverForTesting?(.installing)
            try requireCodexSetup(server, setupID)
            // Only this conversation's private server receives the extra root.
            // A failed or disabled discovery entry must not break ordinary starts.
            do {
                let root = try SessionTaskSkill.install(in: catalog.dataRoot)
                _ = try await client.request(method: "skills/extraRoots/set", params: .object([
                    "extraRoots": .array([.string(root.path)]),
                ]), timeout: 2)
                server.taskSkillRoot = root
            } catch is CancellationError { throw CancellationError() }
            catch { server.taskSkillRoot = nil }
            try requireCodexSetup(server, setupID)
            if let lease = taskRunPlans[server.ownerCard]?.lease {
                await coordinator.fenceTaskEvents(with: lease)
                await client.fenceTaskEvents(with: lease)
                await coordinator.setIdentityChangeHandler { [weak self] sessionID, runID in
                    await self?.revokeTaskRun(sessionID: sessionID, runID: runID, identityChanged: true)
                }
                let serverID = server.id
                await client.observeTaskInputs { [weak self, lease] observation in
                    let runtime = self
                    Task {
                        defer { lease.finishCodexEvent(observation.sequence) }
                        await runtime?.observeCodexTaskInput(serverID: serverID, observation: observation)
                    }
                }
            }
            await coordinator.setConnectionLostHandler { [weak self, weak coordinator] detail in
                guard let coordinator else { return }
                Task { await self?.codexConnectionLost(detail, from: coordinator) }
            }
            try requireCodexSetup(server, setupID)
            await coordinator.setIssueHandler { [weak self, weak coordinator] issue in
                guard let coordinator else { return }
                Task { await self?.codexIssue(issue, from: coordinator) }
            }
            try requireCodexSetup(server, setupID)
            let serverID = server.id
            await coordinator.setServerGone { [weak self] in
                await self?.serverProcessGone(serverID: serverID) ?? true
            }
            try requireCodexSetup(server, setupID)
            await coordinator.start()
            try requireCodexSetup(server, setupID)
            server.client = client
            server.coordinator = coordinator
            server.requestRevision = 0
            let requests = coordinator.requests
            server.requestTask = Task { [weak self] in
                for await snapshot in requests {
                    await self?.received(requests: snapshot, from: coordinator)
                }
            }
            return coordinator
        } catch {
            await coordinator.stop()
            throw error
        }
    }

    private func refreshTaskDiscovery(server: CodexServer, directory: String) async {
        server.taskDiscovery = .unavailable
        guard let root = server.taskSkillRoot, let client = server.client else { return }
        do {
            let response = try await client.request(method: "skills/list", params: .object([
                "cwds": .array([.string(directory)]), "forceReload": .bool(true),
            ]), timeout: 2)
            let expected = root.appendingPathComponent("sphyrna/SKILL.md").standardizedFileURL.path
            let entries = response.object?["data"]?.array ?? []
            let skills = entries.flatMap { $0.object?["skills"]?.array ?? [] }
            if skills.contains(where: { skill in
                guard let item = skill.object, item["name"]?.string == SessionTaskSkill.name,
                      item["enabled"]?.bool == true, let path = item["path"]?.string else { return false }
                return URL(fileURLWithPath: path).standardizedFileURL.path == expected
            }) { server.taskDiscovery = .available }
        } catch { /* Ordinary starts remain available; discovery is reported unavailable. */ }
    }

    /// True only when the server process is verified gone: it is no longer
    /// running, its run ended, or its leader does not exist (or is a zombie).
    /// A failed process check is "not verified".
    private func serverProcessGone(serverID: UUID) async -> Bool {
        guard let server = codexServers.first(where: { $0.id == serverID }) else { return true }
        guard let id = await server.manager.internalSessionID(),
              let run = await supervisor.session(id: id)?.currentRun else { return true }
        // No record only counts as gone when the pid is really absent; any other
        // lookup failure stays "not verified".
        guard let leader = ProcessTable.record(pid: run.leader.pid) else {
            return kill(run.leader.pid, 0) == -1 && errno == ESRCH
        }
        return leader.identity != run.leader || leader.zombie
    }

    private func codexServer(for coordinator: CodexSessionCoordinator) -> CodexServer? {
        codexServers.first { $0.coordinator === coordinator }
    }

    /// Ends a run's server after its TUI run is over: coordinator, then the
    /// server run (the scope's last run, so the supervisor sweeps what the
    /// conversation forked and releases the scope). Returns what could not be
    /// verified; a failed teardown is retryable and is shown on `card`, the
    /// card the run was on (nothing is published when no card exists).
    @discardableResult
    func tearDown(_ server: CodexServer, card: UUID? = nil) async -> [String] {
        if server.finished { return [] }
        if let running = server.teardownTask { return await running.value }
        let task = Task { await self.performTearDown(server) }
        server.teardownTask = task
        let errors = await task.value
        if errors.isEmpty {
            server.finished = true
            codexServers.removeAll { $0 === server }
        } else {
            server.teardownTask = nil
            if let card {
                server.ownerCard = card
                await publishServerStopFailure(errors, sessionID: card)
            }
        }
        return errors
    }

    private func performTearDown(_ server: CodexServer) async -> [String] {
        let setup = server.setup
        server.setup = nil
        setup?.task.cancel()
        _ = await setup?.task.result
        server.requestTask?.cancel()
        server.requestTask = nil
        await server.coordinator?.stop()
        server.coordinator = nil
        server.client = nil
        var errors = await server.manager.stopServer().errors
        if errors.isEmpty, let scope = server.scope {
            // Normally already released by the server run's stop; this covers a
            // server that never started. Never success unless shown empty.
            errors += await supervisor.releaseScope(scope)
        }
        if errors.isEmpty { errors += await server.manager.cleanupSocket() }
        return errors
    }

    private func publishServerStopFailure(_ errors: [String], sessionID: UUID) async {
        await supervisor.events.publish(
            sessionID: sessionID,
            change: .stopFailure("Stop could not be verified: Codex app-server: " + errors.joined(separator: "; "))
        )
    }

    private func received(requests snapshot: CodexRequestSnapshot, from coordinator: CodexSessionCoordinator) async {
        guard let server = codexServer(for: coordinator), snapshot.revision >= server.requestRevision else { return }
        var accepted: [String: CodexPendingRequest] = [:]
        for pending in snapshot.pending {
            guard let context = await supervisor.runContext(runID: pending.binding.managedRunID),
                  context.activeSessionID == pending.binding.sessionID,
                  context.session.providerConversationID == pending.binding.threadID else { continue }
            accepted[pending.id.uuidString] = pending
        }
        // Actor reentrancy can deliver a newer local-response snapshot while
        // owner validation is suspended. Never restore an older pending list.
        guard server.coordinator === coordinator, snapshot.revision >= server.requestRevision else { return }
        server.requestRevision = snapshot.revision
        let affected = Set(server.requestOwners.values).union(accepted.values.map { $0.binding.sessionID })
        server.requests = accepted
        server.requestOwners = accepted.mapValues { $0.binding.sessionID }
        server.failedRequests = server.failedRequests.filter { accepted[$0.key] != nil }
        for owner in affected { await publishRequests(for: owner, in: server) }
    }

    private func markRequestFailed(_ id: String, _ failure: String, in server: CodexServer) async {
        server.failedRequests[id] = failure
        if let owner = server.requestOwners[id] { await publishRequests(for: owner, in: server) }
    }

    private func publishRequests(for sessionID: UUID, in server: CodexServer) async {
        var list: [ProviderUserRequest] = []
        for (id, owner) in server.requestOwners where owner == sessionID {
            guard let request = server.requests[id]?.request else { continue }
            list.append(ProviderUserRequest(
                id: id, kind: Self.kind(of: request.kind),
                summary: Self.summary(of: request), failure: server.failedRequests[id]
            ))
        }
        list.sort { $0.id < $1.id }
        await supervisor.events.publish(sessionID: sessionID, change: .userRequests(list))
    }

    private static func kind(of kind: CodexApprovalKind) -> ProviderUserRequest.Kind {
        switch kind {
        case .commandExecution: .command
        case .fileChange: .fileChange
        case .permissions: .unsupported("permissions")
        case .userInput: .unsupported("input")
        case let .other(method): .unsupported(method)
        }
    }

    private static func summary(of request: CodexServerRequest) -> String {
        let object = request.params.object ?? [:]
        switch request.kind {
        case .commandExecution:
            return object["command"]?.string.map { "Run: \($0)" } ?? "Run a command"
        case .fileChange:
            return object["reason"]?.string ?? "Change files"
        case .permissions:
            return "Codex asks for extra permissions. Answer it in the terminal."
        case .userInput:
            return "Codex asks a question. Answer it in the terminal."
        case let .other(method):
            return "Codex sent a request Sphyrna cannot answer (\(method)). Answer it in the terminal."
        }
    }

    /// A coordinator problem that cannot be tied to one card (a dropped
    /// request, a failed binding) is shown on every live card of that
    /// conversation's server: better a visible warning than an approval nobody sees.
    private func codexIssue(_ issue: String, from coordinator: CodexSessionCoordinator) async {
        guard let server = codexServer(for: coordinator) else { return }
        for record in runs.values where record.server === server {
            guard let session = await supervisor.activeSessionID(runID: record.runID) else { continue }
            guard server.coordinator === coordinator else { return }
            await supervisor.events.publish(sessionID: session, change: .issue(issue))
        }
    }

    private func codexConnectionLost(_ detail: String, from coordinator: CodexSessionCoordinator) async {
        guard let server = codexServer(for: coordinator) else { return }
        for (sessionID, (reservation, reservationCoordinator)) in reservations
        where reservationCoordinator === coordinator {
            guard server.coordinator === coordinator else { return }
            startupConnectionFailures[sessionID] = "Codex app-server connection closed before session identity was received"
            await reservationCoordinator.cancelNewLaunch(reservation)
        }
        let message = "\(detail). Requests and status from Codex are no longer received; the session may need to be restarted."
        for record in runs.values where record.server === server {
            guard let session = await supervisor.activeSessionID(runID: record.runID) else { continue }
            guard server.coordinator === coordinator else { return }
            await supervisor.events.publish(sessionID: session, change: .issue(message))
        }
        guard server.coordinator === coordinator else { return }
        for id in server.requests.keys { server.failedRequests[id] = "The connection to Codex was lost" }
        for owner in Set(server.requestOwners.values) { await publishRequests(for: owner, in: server) }
    }

    func dropRequests(ofRun runID: UUID, in server: CodexServer) async {
        var affected: Set<UUID> = []
        for (id, owner) in server.requestOwners {
            let ownerRun = await supervisor.session(id: owner)?.currentRun?.id
            if ownerRun == nil || ownerRun == runID {
                server.requests[id] = nil
                server.requestOwners[id] = nil
                server.failedRequests[id] = nil
                affected.insert(owner)
            }
        }
        for owner in affected { await publishRequests(for: owner, in: server) }
    }
}
