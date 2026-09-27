import Darwin
import Foundation

public struct ShutdownReport: Codable, Sendable {
    public let elapsedSeconds: Double
    public let signals: [SignalAttempt]
    public let remaining: [ProcessRecord]
    public let errors: [String]
    public let outsideOwnership: [ProcessRecord]
    public let ownershipGuarantee: String
    public var succeeded: Bool { remaining.isEmpty && errors.isEmpty && outsideOwnership.isEmpty }
}

public struct SignalAttempt: Codable, Sendable {
    public let identity: ProcessIdentity
    public let signal: Int32
}

/// Serializes launch, ownership sampling and shutdown. The host calls sample periodically while running.
@MainActor
public final class ShutdownCoordinator {
    public private(set) var ledger: OwnershipLedger
    public private(set) var isStopping = false
    private var children: [PTYProcess] = []
    private var environmentShell: ProcessIdentity?
    private let ledgerURL: URL?

    public init(ledger: OwnershipLedger = OwnershipLedger(), ledgerURL: URL? = nil) throws {
        self.ledger = ledger
        self.ledgerURL = ledgerURL
        // Persist run ID before spawning; recovery can find marked children even if registration is interrupted.
        if let ledgerURL { try ledger.save(to: ledgerURL) }
    }

    public func terminalEnvironment(origin: LaunchEnvironment.LaunchOrigin) throws -> LaunchEnvironment.Resolution {
        guard !isStopping else { throw LoomError.message("Environment resolution rejected: shutdown has started") }
        defer { environmentShell = nil }
        return try LaunchEnvironment.terminal(origin: origin, runID: ledger.runID,
            onSpawn: registerEnvironmentShell, onPoll: { _ = try self.sample() })
    }

    // Registration occurs while the child is still reserved, including if it has exited.
    func registerEnvironmentShell(_ pid: Int32) throws {
        guard let record = try ProcessTable.snapshot().first(where: { $0.identity.pid == pid }) else {
            throw LoomError.message("Environment shell identity unavailable")
        }
        ledger.recordDescendants([record.identity])
        environmentShell = record.identity
        if let ledgerURL { try ledger.save(to: ledgerURL) }
    }

    public func launch(executable: String, arguments: [String] = [], environment: [String: String],
                       directory: String, rows: UInt16 = 24, columns: UInt16 = 80) throws -> PTYProcess {
        guard !isStopping else { throw LoomError.message("Launch rejected: shutdown has started") }
        guard environment["LOOM_RUN_ID"] == ledger.runID.uuidString,
              environment["LOOM_SESSION_ID"].flatMap(UUID.init(uuidString:)) != nil else {
            throw LoomError.message("Launch requires this run's ownership markers")
        }
        let child = try PTYProcess(executable: executable, arguments: arguments, environment: environment,
                                   directory: directory, rows: rows, columns: columns)
        children.append(child)
        let snapshot = try ProcessTable.snapshot()
        if let record = snapshot.first(where: { $0.identity.pid == child.pid }) { ledger.register(record.identity) }
        _ = ledger.observe(snapshot)
        if let ledgerURL { try ledger.save(to: ledgerURL) }
        return child
    }

    @discardableResult public func sample() throws -> [ProcessRecord] {
        children.forEach { $0.pollExit() }
        let snapshot = try ProcessTable.snapshot()
        // The resolver retains its exited shell with WNOWAIT until its final sample.
        // Claim group members only while that exact group leader is still reserved.
        if let shell = environmentShell, snapshot.contains(where: { $0.identity == shell }) {
            ledger.recordDescendants(snapshot.filter { $0.processGroup == shell.pid }.map(\.identity))
        }
        let records = ledger.observe(snapshot)
        if let ledgerURL { try ledger.save(to: ledgerURL) }
        return records
    }

    /// Synchronous bounded shutdown for the checkpoint host.
    public func shutdown(graceSeconds: Double = 0.2) -> ShutdownReport {
        isStopping = true
        LaunchEnvironment.forget(runID: ledger.runID)
        // Close the controlling terminals before waiting for teardown, then sweep
        // descendants that ignore the hangup. Keeping them open delayed Claude's exit.
        children.forEach { $0.closeTerminal() }
        let start = Date()
        var attempts: [SignalAttempt] = []
        var errors: [String] = []
        var remaining: [ProcessRecord] = []
        for signal in [SIGHUP, SIGTERM, SIGKILL] {
            let deadline = Date().addingTimeInterval(max(0.02, graceSeconds))
            var signaled: Set<ProcessIdentity> = []
            repeat {
                do {
                    remaining = try sample()
                    for record in remaining where !record.zombie && !signaled.contains(record.identity) {
                        do {
                            try ProcessTable.signal(record.identity, signal)
                            attempts.append(SignalAttempt(identity: record.identity, signal: signal))
                            signaled.insert(record.identity)
                        } catch { errors.append(String(describing: error)) }
                    }
                } catch { errors.append(String(describing: error)); break }
                if remaining.isEmpty { break }
                usleep(10_000)
            } while Date() < deadline
            if remaining.isEmpty { break }
        }
        children.forEach { $0.closeTerminal(); $0.pollExit() }
        do { remaining = try sample() } catch { errors.append(String(describing: error)) }
        if let issue = ledger.observationIssue { errors.append(issue) }
        return ShutdownReport(elapsedSeconds: Date().timeIntervalSince(start), signals: attempts,
                              remaining: remaining, errors: errors, outsideOwnership: ledger.outsideOwnership ?? [],
                              ownershipGuarantee: ledger.observationIssue ?? ledger.coalition?.guarantee ?? "Narrowed ownership: legacy ledger has no coalition identity.")
    }
}
