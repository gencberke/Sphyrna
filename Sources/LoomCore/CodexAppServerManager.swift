import Foundation

public struct CodexAppServerConfiguration: Sendable {
    public let executable: String
    public let capabilities: ProviderCapabilities
    public let home: URL
    public let baseEnvironment: [String: String]
    public let workingDirectory: String
    public let socketPath: String
    public let clientVersion: String
    public let launchChoices: HarnessLaunchChoices?
    public let startupTimeout: TimeInterval
    /// The conversation's run scope. The server is launched into it so that
    /// stopping the conversation's last run also ends everything it forked.
    public let scope: RunScope?
    /// Notification methods this product connection asks the server not to send.
    public let optOutNotificationMethods: [String]
    /// Measurement hook for development probes; nil in the product.
    public let inboundObserver: CodexInboundObserver?

    public init(
        executable: String, capabilities: ProviderCapabilities, home: URL,
        baseEnvironment: [String: String], workingDirectory: String,
        socketPath: String, clientVersion: String, launchChoices: HarnessLaunchChoices? = nil,
        startupTimeout: TimeInterval = 5, scope: RunScope? = nil,
        optOutNotificationMethods: [String] = CodexAppServerClient.productOptOutNotificationMethods,
        inboundObserver: CodexInboundObserver? = nil
    ) {
        self.executable = executable
        self.capabilities = capabilities
        self.home = home
        self.baseEnvironment = baseEnvironment
        self.workingDirectory = workingDirectory
        self.socketPath = socketPath
        self.clientVersion = clientVersion
        self.launchChoices = launchChoices
        self.startupTimeout = startupTimeout
        self.scope = scope
        self.optOutNotificationMethods = optOutNotificationMethods
        self.inboundObserver = inboundObserver
    }
}

/// Owns one Codex app-server for one Codex conversation run. Its process is an
/// internal supervisor session, so stop, app quit, crash recovery, and
/// descendant cleanup use the same ownership boundary as provider terminals.
public actor CodexAppServerManager {
    struct ManagedOwner: Equatable, Sendable {
        let sessionID: UUID
        let runID: UUID
    }
    private struct Running: Sendable {
        let internalSessionID: UUID
        let launch: ManagedSessionLaunch
        let client: CodexAppServerClient
    }

    private let supervisor: ProcessSupervisor
    private let configuration: CodexAppServerConfiguration
    private let managedOwner: ManagedOwner?
    private var running: Running?
    private var startTask: Task<Running, any Error>?
    private var stopTask: Task<(report: SessionStopReport?, errors: [String]), Never>?
    private var failedInternalSessionID: UUID?
    private var socketOwnership: CodexSocketOwnership?
    private var socketCleanupPrepared = false
    private var socketPreparationTask: Task<[String], Never>?

    public init(supervisor: ProcessSupervisor,
                configuration: CodexAppServerConfiguration) {
        self.supervisor = supervisor
        self.configuration = configuration
        self.managedOwner = nil
    }

    init(supervisor: ProcessSupervisor, configuration: CodexAppServerConfiguration, managedOwner: ManagedOwner) {
        self.supervisor = supervisor
        self.configuration = configuration
        self.managedOwner = managedOwner
    }

    public func internalSessionID() -> UUID? { managedOwner == nil ? running?.internalSessionID : nil }

    /// The managed server is the child's own run, not an internal helper.
    func managedLaunch() -> ManagedSessionLaunch? { managedOwner == nil ? nil : running?.launch }
    func ownedSessionID() -> UUID? { running?.internalSessionID ?? failedInternalSessionID }
    func ownedLeader() -> ProcessIdentity? { running?.launch.session.currentRun?.leader }

    /// Starts the server and connects to it; a running server's client is returned again.
    public func start() async throws -> CodexAppServerClient {
        if let stopTask { _ = await stopTask.value }
        guard failedInternalSessionID == nil else {
            throw LoomError.message(
                "Previous Codex app-server cleanup is incomplete"
            )
        }
        if let running { return running.client }
        let task: Task<Running, any Error>
        if let startTask {
            task = startTask
        } else {
            let created = Task { try await self.startServer() }
            startTask = created
            task = created
        }
        do {
            let value = try await task.value
            if running == nil { running = value }
            startTask = nil
            return value.client
        } catch {
            startTask = nil
            throw error
        }
    }

    @discardableResult
    public func stop(graceSeconds: Double = 0.2) async -> SessionStopReport? {
        let result = await stopServer(graceSeconds: graceSeconds)
        var errors = result.errors
        if errors.isEmpty, let scope = configuration.scope { errors += await supervisor.releaseScope(scope) }
        if errors.isEmpty { errors += await cleanupSocket() }
        return result.report.map { errors.isEmpty ? $0 : $0.adding(errors: errors) }
    }

    /// Stops the server (or retries a failed stop) and says what could not be
    /// verified. An empty `errors` means no server process or session remains.
    /// Concurrent callers share one stop.
    public func stopServer(
        graceSeconds: Double = 0.2
    ) async -> (report: SessionStopReport?, errors: [String]) {
        if let stopTask { return await stopTask.value }
        let task = Task { await self.performStop(graceSeconds: graceSeconds, allowMovedManagedRun: false) }
        stopTask = task
        let result = await task.value
        stopTask = nil
        return result
    }

    /// Quit stops every owned run, including this exact run if its card moved.
    /// A task-specific Stop never uses this route.
    func stopServerForShutdown(graceSeconds: Double = 0.2) async -> (report: SessionStopReport?, errors: [String]) {
        if let stopTask { return await stopTask.value }
        let task = Task { await self.performStop(graceSeconds: graceSeconds, allowMovedManagedRun: true) }
        stopTask = task
        let result = await task.value
        stopTask = nil
        return result
    }

    private func performStop(
        graceSeconds: Double, allowMovedManagedRun: Bool
    ) async -> (report: SessionStopReport?, errors: [String]) {
        if let managedOwner {
            return await performManagedStop(managedOwner, graceSeconds: graceSeconds, allowMoved: allowMovedManagedRun)
        }
        if let startTask {
            startTask.cancel()
            running = try? await startTask.value
            self.startTask = nil
        }
        let active = running
        self.running = nil
        guard let sessionID = active?.internalSessionID ?? failedInternalSessionID else {
            return (nil, [])
        }
        if let active { await active.client.close() }
        var errors: [String] = []
        var report: SessionStopReport?
        if await supervisor.session(id: sessionID)?.currentRun != nil {
            do { report = try await supervisor.stop(sessionID: sessionID, graceSeconds: graceSeconds) }
            catch { errors.append("Codex app-server stop failed: \(error)") }
            if let report, !report.succeeded {
                errors.append("Codex app-server stop could not be verified"
                    + (report.errors.first.map { ": \($0)" } ?? ""))
            }
        }
        if errors.isEmpty {
            do {
                try await supervisor.discardInternalSession(sessionID)
                await supervisor.events.forget(sessionID: sessionID)
                failedInternalSessionID = nil
            } catch {
                failedInternalSessionID = sessionID
                errors.append("Codex app-server session could not be discarded: \(error)")
            }
        } else {
            failedInternalSessionID = sessionID
        }
        return (report, errors)
    }

    private func performManagedStop(_ owner: ManagedOwner, graceSeconds: Double, allowMoved: Bool)
        async -> (report: SessionStopReport?, errors: [String]) {
        if let startTask {
            startTask.cancel()
            running = try? await startTask.value
            self.startTask = nil
        }
        let active = running
        guard active != nil || failedInternalSessionID == owner.sessionID else { return (nil, []) }
        let report: SessionStopReport?
        if let context = await supervisor.runContext(runID: owner.runID) {
            guard context.launchSessionID == owner.sessionID, context.session.currentRun?.id == owner.runID,
                  allowMoved || context.activeSessionID == owner.sessionID else {
                return (nil, ["Managed Codex server no longer owns the expected run"])
            }
            report = await supervisor.stop(sessionID: context.activeSessionID, runID: owner.runID,
                                           graceSeconds: graceSeconds, endReason: .requested,
                                           requiringSessionID: context.activeSessionID)
        } else {
            if allowMoved { report = await supervisor.lastStopReport(runID: owner.runID) }
            else { report = await supervisor.lastStopReport(sessionID: owner.sessionID) }
        }
        guard let report, (allowMoved || report.sessionID == owner.sessionID), report.runID == owner.runID,
              report.succeeded else {
            failedInternalSessionID = owner.sessionID
            return (report, ["Managed Codex server stop could not be verified"])
        }
        // Keep the client alive during Stop's provider preparation. Never
        // discard the child's durable session when its run has stopped.
        await active?.client.close()
        running = nil
        failedInternalSessionID = nil
        return (report, [])
    }

    private func startServer() async throws -> Running {
        guard socketOwnership == nil else { throw LoomError.message("Previous Codex socket cleanup is incomplete") }
        socketOwnership = try CodexSocketOwnership(requested: configuration.socketPath)
        let sessionID: UUID
        if let managedOwner {
            guard configuration.scope != nil,
                  let session = await supervisor.session(id: managedOwner.sessionID),
                  let choices = configuration.launchChoices, choices.harness.provider == session.provider,
                  (try? CodexLaunchSettings(choices)) != nil,
                  session.currentRun == nil, session.providerConversationID == nil,
                  URL(fileURLWithPath: session.workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path ==
                    URL(fileURLWithPath: configuration.workingDirectory).resolvingSymlinksInPath().standardizedFileURL.path else {
                throw LoomError.message("Managed Codex server requires its reserved child and owned scope")
            }
            sessionID = managedOwner.sessionID
        } else {
            let internalSession = ManagedSession(provider: .synthetic, workingDirectory: configuration.workingDirectory)
            try await supervisor.createInternalSession(internalSession)
            sessionID = internalSession.id
        }
        do {
            let environment = LaunchEnvironment.make(
                base: configuration.baseEnvironment,
                runID: supervisor.ownershipRunID,
                sessionID: sessionID
            )
            let profile = try ProviderLaunchProfile.codex(
                route: .server(socket: configuration.socketPath),
                capabilities: configuration.capabilities,
                home: configuration.home, environment: environment, choices: configuration.launchChoices
            )
            let diagnostics = DiagnosticOutputTee(downstream: nil)
            let launch = try await supervisor.launch(
                sessionID: sessionID,
                executable: configuration.executable,
                arguments: profile.arguments,
                environment: profile.environment,
                outputSink: diagnostics, managedRunID: managedOwner?.runID,
                scope: configuration.scope
            )
            guard let leader = launch.session.currentRun?.leader else {
                throw LoomError.message("Codex app-server process identity is unavailable")
            }
            let deadline = ProcessInfo.processInfo.systemUptime
                + max(0.02, configuration.startupTimeout)
            var lastError: (any Error)?
            repeat {
                try Task.checkCancellation()
                if let status = await launch.terminal.exitStatus() {
                    // Finish draining the existing PTY before classifying its
                    // bounded startup output. The supervisor remains its owner.
                    _ = await stopStartingRun(sessionID: sessionID)
                    throw startupExit(status, output: diagnostics.text)
                }
                do {
                    guard try socketOwnership?.claimIfReady(leader: leader) == true else {
                        lastError = CodexAppServerError.system(operation: "connect", code: ENOENT)
                        try await Task.sleep(for: .milliseconds(20))
                        continue
                    }
                    let client = try await CodexAppServerClient.connect(
                        socketPath: configuration.socketPath,
                        clientVersion: configuration.clientVersion,
                        timeout: min(1, configuration.startupTimeout),
                        optOutNotificationMethods: configuration.optOutNotificationMethods,
                        inboundObserver: configuration.inboundObserver
                    )
                    return Running(
                        internalSessionID: sessionID, launch: launch, client: client
                    )
                } catch {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(20))
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
            if let status = await launch.terminal.exitStatus() {
                _ = await stopStartingRun(sessionID: sessionID)
                throw startupExit(status, output: diagnostics.text)
            }
            // Never forward arbitrary RPC text (which can contain credentials).
            let connection: String
            if let error = lastError as? CodexAppServerError,
               case let .system(operation, code) = error {
                connection = CodexAppServerError.system(operation: operation, code: code).description
            } else {
                connection = "connection/initialization did not complete"
            }
            throw LoomError.message("Codex app-server timed out during startup; \(connection)")
        } catch {
            if let current = await supervisor.session(id: sessionID)?.currentRun {
                let report: SessionStopReport?
                if let managedOwner {
                    if current.id == managedOwner.runID {
                        report = await supervisor.stop(sessionID: sessionID, runID: managedOwner.runID,
                                                       graceSeconds: 0.05, endReason: .requested,
                                                       requiringSessionID: sessionID)
                    } else { report = nil }
                } else {
                    report = try? await supervisor.stop(sessionID: sessionID, graceSeconds: 0.05)
                }
                if report?.succeeded != true { failedInternalSessionID = sessionID }
            }
            if managedOwner == nil {
                do {
                    try await supervisor.discardInternalSession(sessionID)
                    await supervisor.events.forget(sessionID: sessionID)
                } catch { failedInternalSessionID = sessionID }
            }
            throw error
        }
    }

    private func stopStartingRun(sessionID: UUID) async -> SessionStopReport? {
        if let owner = managedOwner {
            guard owner.sessionID == sessionID,
                  await supervisor.session(id: sessionID)?.currentRun?.id == owner.runID else { return nil }
            return await supervisor.stop(sessionID: sessionID, runID: owner.runID,
                                         graceSeconds: 0.05, endReason: .requested,
                                         requiringSessionID: sessionID)
        }
        return try? await supervisor.stop(sessionID: sessionID, graceSeconds: 0.05)
    }

    /// Check that the recorded node has no remaining listener while helpers
    /// can still run. Quit may then stop its last TUI before the final unlink.
    func prepareSocketCleanup() async -> [String] {
        // Stop, the end observer, and Quit may all arrive together. One
        // inspection is shared, and a later caller must not invalidate a proof
        // already made just before supervisor shutdown stopped helper launches.
        if socketCleanupPrepared || socketOwnership == nil { return [] }
        if let socketPreparationTask { return await socketPreparationTask.value }
        let task = Task { await self.inspectSocketCleanup() }
        socketPreparationTask = task
        let errors = await task.value
        socketPreparationTask = nil
        return errors
    }

    private func inspectSocketCleanup() async -> [String] {
        guard let ownership = socketOwnership else { return [] }
        do {
            if let path = try ownership.remainingSocket() {
                do {
                    _ = try await supervisor.captureHelper("/usr/sbin/lsof", ["-nP", "-a", "-U", path],
                        environment: ["PATH": "/usr/bin:/bin"], timeout: 5, outputLimit: 16_384)
                    throw LoomError.message("Codex socket is still open")
                } catch let LoomError.helperExit(status, detail) where status == 1 && detail.isEmpty {
                    // lsof reports no matching open Unix socket with this exit.
                }
                _ = try ownership.remainingSocket()
            }
            socketCleanupPrepared = true
            return []
        } catch {
            socketCleanupPrepared = false
            return ["Codex socket cleanup could not be verified: \(error)"]
        }
    }

    func finishSocketCleanup() -> [String] {
        guard let ownership = socketOwnership else { return [] }
        guard socketCleanupPrepared else { return ["Codex socket cleanup was not verified"] }
        do {
            try ownership.removeRemaining()
            socketOwnership = nil
            socketCleanupPrepared = false
            return []
        } catch { return ["Codex socket cleanup could not be verified: \(error)"] }
    }

    func cleanupSocket() async -> [String] {
        let errors = await prepareSocketCleanup()
        return errors.isEmpty ? finishSocketCleanup() : errors
    }

    private func startupExit(_ status: Int32, output: String) -> LoomError {
        // waitpid status: low seven bits are the terminating signal; otherwise
        // the high byte is the exit code. Do not present the encoded wait status.
        let signal = status & 0x7f
        let result = signal == 0 ? "exit code \((status >> 8) & 0xff)" : "signal \(signal)"
        return .message("Codex app-server exited during startup (\(result)); \(Self.safeStartupDetail(output))")
    }

    /// Fixed categories only: provider output may contain secrets even on lines
    /// that look like errors. No raw line, path or environment value escapes.
    static func safeStartupDetail(_ output: String) -> String {
        let text = output.lowercased()
        for phrase in ["permission denied", "address already in use", "no such file or directory",
                       "invalid configuration", "failed to load config", "error parsing", "unauthorized"] {
            if text.contains(phrase) { return "startup output reported: \(phrase)" }
        }
        return output.isEmpty ? "no startup output" : "unrecognized startup output withheld"
    }

}
