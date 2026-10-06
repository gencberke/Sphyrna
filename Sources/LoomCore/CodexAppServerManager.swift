import Foundation

public struct CodexAppServerConfiguration: Sendable {
    public let executable: String
    public let capabilities: ProviderCapabilities
    public let home: URL
    public let baseEnvironment: [String: String]
    public let workingDirectory: String
    public let socketPath: String
    public let clientVersion: String
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
        socketPath: String, clientVersion: String,
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
    private struct Running: Sendable {
        let internalSessionID: UUID
        let client: CodexAppServerClient
    }

    private let supervisor: ProcessSupervisor
    private let configuration: CodexAppServerConfiguration
    private var running: Running?
    private var startTask: Task<Running, any Error>?
    private var stopTask: Task<(report: SessionStopReport?, errors: [String]), Never>?
    private var failedInternalSessionID: UUID?

    public init(supervisor: ProcessSupervisor,
                configuration: CodexAppServerConfiguration) {
        self.supervisor = supervisor
        self.configuration = configuration
    }

    public func internalSessionID() -> UUID? { running?.internalSessionID }

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
        await stopServer(graceSeconds: graceSeconds).report
    }

    /// Stops the server (or retries a failed stop) and says what could not be
    /// verified. An empty `errors` means no server process or session remains.
    /// Concurrent callers share one stop.
    public func stopServer(
        graceSeconds: Double = 0.2
    ) async -> (report: SessionStopReport?, errors: [String]) {
        if let stopTask { return await stopTask.value }
        let task = Task { await self.performStop(graceSeconds: graceSeconds) }
        stopTask = task
        let result = await task.value
        stopTask = nil
        return result
    }

    private func performStop(
        graceSeconds: Double
    ) async -> (report: SessionStopReport?, errors: [String]) {
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

    private func startServer() async throws -> Running {
        let internalSession = ManagedSession(
            provider: .synthetic,
            workingDirectory: configuration.workingDirectory
        )
        try await supervisor.createInternalSession(internalSession)
        do {
            let environment = LaunchEnvironment.make(
                base: configuration.baseEnvironment,
                runID: supervisor.ownershipRunID,
                sessionID: internalSession.id
            )
            let profile = try ProviderLaunchProfile.codex(
                route: .server(socket: configuration.socketPath),
                capabilities: configuration.capabilities,
                home: configuration.home, environment: environment
            )
            let diagnostics = DiagnosticOutputTee(downstream: nil)
            let launch = try await supervisor.launch(
                sessionID: internalSession.id,
                executable: configuration.executable,
                arguments: profile.arguments,
                environment: profile.environment,
                outputSink: diagnostics,
                scope: configuration.scope
            )
            let deadline = ProcessInfo.processInfo.systemUptime
                + max(0.02, configuration.startupTimeout)
            var lastError: (any Error)?
            repeat {
                try Task.checkCancellation()
                if let status = await launch.terminal.exitStatus() {
                    // Finish draining the existing PTY before classifying its
                    // bounded startup output. The supervisor remains its owner.
                    _ = try? await supervisor.stop(sessionID: internalSession.id, graceSeconds: 0.05)
                    throw startupExit(status, output: diagnostics.text)
                }
                do {
                    let client = try await CodexAppServerClient.connect(
                        socketPath: configuration.socketPath,
                        clientVersion: configuration.clientVersion,
                        timeout: min(1, configuration.startupTimeout),
                        optOutNotificationMethods: configuration.optOutNotificationMethods,
                        inboundObserver: configuration.inboundObserver
                    )
                    return Running(
                        internalSessionID: internalSession.id, client: client
                    )
                } catch {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(20))
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
            if let status = await launch.terminal.exitStatus() {
                _ = try? await supervisor.stop(sessionID: internalSession.id, graceSeconds: 0.05)
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
            if await supervisor.session(id: internalSession.id)?.currentRun != nil {
                let report = try? await supervisor.stop(
                    sessionID: internalSession.id, graceSeconds: 0.05
                )
                if report?.succeeded != true { failedInternalSessionID = internalSession.id }
            }
            do {
                try await supervisor.discardInternalSession(internalSession.id)
                await supervisor.events.forget(sessionID: internalSession.id)
            } catch { failedInternalSessionID = internalSession.id }
            throw error
        }
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
