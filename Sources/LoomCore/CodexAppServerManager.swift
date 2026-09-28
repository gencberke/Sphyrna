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

    public init(
        executable: String, capabilities: ProviderCapabilities, home: URL,
        baseEnvironment: [String: String], workingDirectory: String,
        socketPath: String, clientVersion: String,
        startupTimeout: TimeInterval = 5
    ) {
        self.executable = executable
        self.capabilities = capabilities
        self.home = home
        self.baseEnvironment = baseEnvironment
        self.workingDirectory = workingDirectory
        self.socketPath = socketPath
        self.clientVersion = clientVersion
        self.startupTimeout = startupTimeout
    }
}

/// Owns the single Codex app-server shared by remote TUI sessions. Its process
/// is an internal supervisor session, so stop, app quit, crash recovery, and
/// descendant cleanup use the same ownership boundary as provider terminals.
public actor CodexAppServerManager {
    private struct Running: Sendable {
        let internalSessionID: UUID
        let client: CodexAppServerClient
    }

    private let supervisor: ProcessSupervisor
    private let configuration: CodexAppServerConfiguration
    private var leases: Set<UUID> = []
    private var running: Running?
    private var startTask: Task<Running, any Error>?
    private var serverStopInProgress = false
    private var failedInternalSessionID: UUID?

    public init(supervisor: ProcessSupervisor,
                configuration: CodexAppServerConfiguration) {
        self.supervisor = supervisor
        self.configuration = configuration
    }

    public func activeSessionCount() -> Int { leases.count }
    public func internalSessionID() -> UUID? { running?.internalSessionID }

    public func acquire(for sessionID: UUID) async throws -> CodexAppServerClient {
        while serverStopInProgress {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard failedInternalSessionID == nil else {
            throw LoomError.message(
                "Previous Codex app-server cleanup is incomplete"
            )
        }
        leases.insert(sessionID)
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
            leases.remove(sessionID)
            startTask = nil
            throw error
        }
    }

    @discardableResult
    public func release(
        for sessionID: UUID, graceSeconds: Double = 0.2
    ) async throws -> SessionStopReport? {
        guard leases.remove(sessionID) != nil else { return nil }
        guard leases.isEmpty else { return nil }
        if let startTask {
            do { running = try await startTask.value }
            catch {
                self.startTask = nil
                throw error
            }
            self.startTask = nil
        }
        // Another acquire may have arrived while the shared startup task was
        // awaited. That lease keeps the just-started server alive.
        guard leases.isEmpty else { return nil }
        guard let running else { return nil }
        self.running = nil
        serverStopInProgress = true
        defer { serverStopInProgress = false }
        await running.client.close()
        let report: SessionStopReport
        do {
            report = try await supervisor.stop(
                sessionID: running.internalSessionID, graceSeconds: graceSeconds
            )
        } catch {
            failedInternalSessionID = running.internalSessionID
            throw error
        }
        if report.succeeded {
            do {
                try await supervisor.discardInternalSession(running.internalSessionID)
                failedInternalSessionID = nil
            } catch {
                failedInternalSessionID = running.internalSessionID
                throw error
            }
        } else {
            failedInternalSessionID = running.internalSessionID
        }
        return report
    }

    @discardableResult
    public func stop(graceSeconds: Double = 0.2) async -> SessionStopReport? {
        leases.removeAll()
        while serverStopInProgress {
            try? await Task.sleep(for: .milliseconds(1))
        }
        if let startTask {
            running = try? await startTask.value
            self.startTask = nil
        }
        let active = running
        self.running = nil
        guard let sessionID = active?.internalSessionID ?? failedInternalSessionID else {
            return nil
        }
        serverStopInProgress = true
        defer { serverStopInProgress = false }
        if let active { await active.client.close() }
        let report: SessionStopReport?
        if await supervisor.session(id: sessionID)?.currentRun != nil {
            report = try? await supervisor.stop(
                sessionID: sessionID, graceSeconds: graceSeconds
            )
        } else {
            report = nil
        }
        if report?.succeeded != false {
            do {
                try await supervisor.discardInternalSession(sessionID)
                failedInternalSessionID = nil
            } catch {
                failedInternalSessionID = sessionID
            }
        } else {
            failedInternalSessionID = sessionID
        }
        return report
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
            _ = try await supervisor.launch(
                sessionID: internalSession.id,
                executable: configuration.executable,
                arguments: profile.arguments,
                environment: profile.environment
            )
            let deadline = ProcessInfo.processInfo.systemUptime
                + max(0.02, configuration.startupTimeout)
            var lastError: (any Error)?
            repeat {
                do {
                    let client = try await CodexAppServerClient.connect(
                        socketPath: configuration.socketPath,
                        clientVersion: configuration.clientVersion,
                        timeout: min(1, configuration.startupTimeout)
                    )
                    return Running(
                        internalSessionID: internalSession.id, client: client
                    )
                } catch {
                    lastError = error
                    try await Task.sleep(for: .milliseconds(20))
                }
            } while ProcessInfo.processInfo.systemUptime < deadline
            throw lastError ?? CodexAppServerError.timeout("startup")
        } catch {
            if await supervisor.session(id: internalSession.id)?.currentRun != nil {
                _ = try? await supervisor.stop(
                    sessionID: internalSession.id, graceSeconds: 0.05
                )
            }
            try? await supervisor.discardInternalSession(internalSession.id)
            throw error
        }
    }
}
