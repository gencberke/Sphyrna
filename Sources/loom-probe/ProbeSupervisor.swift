import Foundation
import LoomCore

private final class BlockingResultBox<Value>: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<Value, any Error>?
}

/// The probe is intentionally synchronous, but its lifecycle authority is the
/// same ProcessSupervisor used by the product core. Blocking is confined to
/// this command-line adapter and never reintroduces a second owner/terminator.
@MainActor
func blockingAwait<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let box = BlockingResultBox<Value>()
    Task.detached {
        do { box.result = .success(try await operation()) }
        catch { box.result = .failure(error) }
        box.semaphore.signal()
    }
    box.semaphore.wait()
    return try box.result!.get()
}

@MainActor
final class ProbeTerminal {
    private let endpoint: TerminalEndpoint

    init(_ endpoint: TerminalEndpoint) { self.endpoint = endpoint }

    var pid: Int32 { endpoint.pid }

    func readAvailable() -> Data { endpoint.readAvailable() }

    func write(_ data: Data) throws -> Int {
        let endpoint = endpoint
        return try blockingAwait { try await endpoint.write(data) }
    }

    func resize(rows: UInt16, columns: UInt16) throws {
        let endpoint = endpoint
        try blockingAwait { try await endpoint.resize(rows: rows, columns: columns) }
    }
}

@MainActor
final class ProbeSupervisor {
    let ownershipRunID: UUID
    private let supervisor: ProcessSupervisor
    private(set) var isStopping = false

    init(ledger: OwnershipLedger = OwnershipLedger(), ledgerURL: URL? = nil) throws {
        ownershipRunID = ledger.runID
        supervisor = try ProcessSupervisor(ledger: ledger, ledgerURL: ledgerURL)
    }

    func terminalEnvironment(
        origin: LaunchEnvironment.LaunchOrigin
    ) throws -> LaunchEnvironment.Resolution {
        let supervisor = supervisor
        return try blockingAwait { try await supervisor.terminalEnvironment(origin: origin) }
    }

    func launch(
        executable: String, arguments: [String] = [], environment: [String: String],
        directory: String, provider: ManagedSession.Provider = .synthetic,
        rows: UInt16 = 24, columns: UInt16 = 80
    ) throws -> ProbeTerminal {
        guard let value = environment["LOOM_SESSION_ID"],
              let sessionID = UUID(uuidString: value) else {
            throw LoomError.message("Launch requires a valid session ownership marker")
        }
        let supervisor = supervisor
        let launch = try blockingAwait {
            try await supervisor.createSession(ManagedSession(
                id: sessionID, provider: provider, workingDirectory: directory
            ))
            return try await supervisor.launch(
                sessionID: sessionID, executable: executable, arguments: arguments,
                environment: environment, rows: rows, columns: columns
            )
        }
        return ProbeTerminal(launch.terminal)
    }

    func sample() throws -> [ProcessRecord] {
        let supervisor = supervisor
        return try blockingAwait { try await supervisor.ownedProcesses() }
    }

    func shutdown(graceSeconds: Double = 0.2) -> ShutdownReport {
        isStopping = true
        let supervisor = supervisor
        return try! blockingAwait {
            await supervisor.shutdown(graceSeconds: graceSeconds)
        }
    }
}
