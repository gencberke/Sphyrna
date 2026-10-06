#if LOOM_EVIDENCE
import AppKit
import CryptoKit
import Foundation
import LoomCore
import LoomTerminal
import Synchronization

/// Only DevelopmentEvidence creates this pool. Each run has the production
/// surface sink and PTY, with an audit forwarding to that same sink.
@MainActor
final class EvidenceResourcePool {
    private final class WeakResource {
        let kind: String
        weak var object: AnyObject?
        init(_ kind: String, _ object: AnyObject) { self.kind = kind; self.object = object }
    }
    private struct Entry {
        let sessionID: UUID
        let runID: UUID
        let identity: ProcessIdentity
        let surface: TerminalSurface
        let endpoint: TerminalEndpoint
        let audit: EvidenceStreamAudit
        let rate: Int
        let total: Int
        let spinnerFrames: Int?
    }
    private weak var app: AppDelegate?
    private let supervisor: ProcessSupervisor
    private let executable: String
    private let directory: String
    private var entries: [Entry] = []
    private var weakResources: [WeakResource] = []
    private var created: [String: Int] = [:]
    private var selected: Int?
    private var cycleResults: [[String: Any]] = []

    init(app: AppDelegate, supervisor: ProcessSupervisor, executable: String, directory: String) {
        self.app = app; self.supervisor = supervisor
        self.executable = executable; self.directory = directory
    }

    private func track(_ kind: String, _ object: AnyObject) {
        created[kind, default: 0] += 1
        weakResources.append(WeakResource(kind, object))
    }

    private var alive: [String: Int] {
        var result = created.mapValues { _ in 0 }
        for item in weakResources where item.object != nil { result[item.kind, default: 0] += 1 }
        return result
    }

    func open(count: Int, rate: Int, total: Int, spinnerFrames: Int? = nil) async throws -> [String: Any] {
        guard entries.isEmpty, alive.values.allSatisfy({ $0 == 0 }) else {
            throw LoomError.message("Resource pool still owns live resources; stop and release it first")
        }
        guard (0...50).contains(count), rate >= -1, total >= 0,
              (rate == -1 && total == 0) || (rate >= 0 && total > 0) else {
            throw LoomError.message("Expected count 0...50, idle rate=-1/total=0, or a finite stream")
        }
        for _ in 0..<count {
            try await openOne(rate: rate, total: total, spinnerFrames: spinnerFrames)
        }
        if count > 0 { try select(index: 0) }
        return try await snapshot()
    }

    private func openOne(rate: Int, total: Int, spinnerFrames: Int?) async throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let surface = TerminalSurface(fontSize: CGFloat(app?.model?.terminalFontSize ?? 14))
        let downstream = surface.outputSink
        let audit = EvidenceStreamAudit(downstream: downstream, payloadBytes: rate == -1 ? nil : total)
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(id: sessionID, provider: .synthetic, workingDirectory: directory))
        let size = surface.gridSize
        let launch = try await supervisor.launch(sessionID: sessionID, executable: executable,
            arguments: rate == -1 ? ["interactive"]
                : spinnerFrames.map { ["spinner", String(rate), String($0)] } ?? ["stream", String(rate), String(total)],
            environment: LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID),
            rows: size.rows, columns: size.columns, outputSink: audit)
        guard let run = launch.session.currentRun else { throw LoomError.message("Fixture run identity missing") }
        surface.attach(runID: run.id, endpoint: launch.terminal)
        track("surface", surface); track("view", surface.view)
        track("auditSink", audit); track("surfaceSink", downstream as AnyObject)
        track("endpoint", launch.terminal)
        for object in surface.resourceObjectsForEvidence { track("surfaceOwned-\(String(describing: type(of: object)))", object) }
        entries.append(Entry(sessionID: sessionID, runID: run.id, identity: run.leader,
            surface: surface, endpoint: launch.terminal, audit: audit, rate: rate, total: total, spinnerFrames: spinnerFrames))
    }

    func select(index: Int?) throws {
        guard index == nil || entries.indices.contains(index!) else { throw LoomError.message("Resource index out of range") }
        selected = index
        app?.showResourceSurfaceForEvidence(index.map { entries[$0].surface })
    }

    func selectedSurfaceForLatency() throws -> TerminalSurface {
        guard let selected, entries.indices.contains(selected) else {
            throw LoomError.message("Resource latency requires a selected terminal surface")
        }
        return entries[selected].surface
    }

    private func row(_ entry: Entry, processes: [ProcessRecord]) -> [String: Any] {
        let current = processes.first { $0.identity.pid == entry.identity.pid }
        return [
            "sessionID": entry.sessionID.uuidString, "runID": entry.runID.uuidString,
            "identity": Self.json(entry.identity), "identityMatches": current?.identity == entry.identity,
            "alive": current != nil && current?.zombie == false,
            "rate": entry.rate, "totalPayloadBytes": entry.total,
            "spinnerFrames": entry.spinnerFrames.map { $0 as Any } ?? NSNull(),
            "secondScrollback": entry.endpoint.scrollback != nil,
            "renderer": entry.surface.view.isUsingMetalRenderer ? "metal" : "coregraphics",
            "usage": ProcessTable.resourceUsage(pid: entry.identity.pid).map(Self.json) ?? NSNull(),
            "terminal": Self.json(entry.surface.statistics), "audit": entry.audit.snapshot,
        ]
    }

    func snapshot() async throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        let processes = try ProcessTable.snapshot()
        let appRecord = processes.first { $0.identity.pid == getpid() }
        let windowServers = processes.filter { ProcessTable.executablePath(pid: $0.identity.pid)?.hasSuffix("/WindowServer") == true }
        var supervisorRuns: [[String: Any]] = []
        var leaders: Set<ProcessIdentity> = []
        for id in await supervisor.runningSessionIDs() {
            if let session = await supervisor.session(id: id), let run = session.currentRun {
                leaders.insert(run.leader)
                supervisorRuns.append(["sessionID": id.uuidString, "runID": run.id.uuidString,
                    "identity": Self.json(run.leader), "provider": session.provider.rawValue,
                    "identityMatches": processes.contains { $0.identity == run.leader && !$0.zombie },
                    "usage": ProcessTable.resourceUsage(pid: run.leader.pid).map(Self.json) ?? NSNull()])
            }
        }
        let scope = await scopeAccounting(leaders: leaders)
        return [
            "scope": scope,
            "uptime": started, "pid": Int(getpid()), "appIdentity": appRecord.map { Self.json($0.identity) } ?? NSNull(),
            "appUsage": ProcessTable.resourceUsage(pid: getpid()).map(Self.json) ?? NSNull(),
            "windowServers": windowServers.map { ["identity": Self.json($0.identity),
                "usage": ProcessTable.resourceUsage(pid: $0.identity.pid).map(Self.json) ?? NSNull()] },
            "runs": entries.map { row($0, processes: processes) },
            "supervisorRuns": supervisorRuns, "selectedIndex": selected.map { $0 as Any } ?? NSNull(),
            "weakAlive": alive, "created": created,
            "cycleResults": cycleResults,
            "unavailableMetrics": ["PTY transport object lifetime and open descriptor count", "global event subscriber count"],
            "definition": "N real surface/PTY pairs, one selected view in the existing panel; other views detached",
            "snapshotCostMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
        ]
    }

    /// Run hosts, launchd-started service instances and non-leader scope
    /// members use real CPU and memory too. A member that is alive but whose
    /// usage cannot be read makes the whole sample invalid; nothing is skipped.
    private func scopeAccounting(leaders: Set<ProcessIdentity>) async -> [String: Any] {
        var invalid: [String] = []
        var hosts: [[String: Any]] = []
        var others: [[String: Any]] = []
        let members: [RunScopeMember]
        do { members = try await supervisor.liveScopeMembers() } catch {
            return ["valid": false, "invalid": ["scope members unreadable: \(error)"],
                    "hosts": [], "others": []]
        }
        for member in members {
            if !member.launchdSpawned, leaders.contains(member.identity) { continue }
            let usage = ProcessTable.resourceUsage(pid: member.identity.pid)
            if usage == nil { invalid.append("pid \(member.identity.pid) usage unreadable") }
            let row: [String: Any] = [
                "identity": Self.json(member.identity),
                "path": ProcessTable.executablePath(pid: member.identity.pid) ?? NSNull(),
                "launchdSpawned": member.launchdSpawned,
                "usage": usage.map(Self.json) ?? NSNull(),
            ]
            if member.launchdSpawned { hosts.append(row) } else { others.append(row) }
        }
        return ["valid": invalid.isEmpty, "invalid": invalid, "hosts": hosts, "others": others]
    }

    func stop() async throws -> [String: Any] {
        try select(index: nil)
        var stopped: [[String: Any]] = []
        while !entries.isEmpty { stopped.append(try await stopOne()) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while alive.values.contains(where: { $0 > 0 }), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        weakResources.removeAll { $0.object == nil }
        guard alive.values.allSatisfy({ $0 == 0 }) else {
            throw LoomError.message("Resource release timed out: \(alive)")
        }
        return ["stopped": stopped, "weakAlive": alive, "releaseVerified": true]
    }

    private func stopOne() async throws -> [String: Any] {
        // Keep ownership until verified Stop; a failed Stop remains retryable.
        let entry = entries[entries.count - 1]
        let report = try await supervisor.stop(sessionID: entry.sessionID)
        guard report.succeeded else { throw LoomError.message("Fixture Stop failed: \(report.errors)") }
        entry.surface.runEnded()
        let result = row(entry, processes: try ProcessTable.snapshot())
        entries.removeLast()
        return result
    }

    func cycles(count: Int) async throws -> [String: Any] {
        guard (1...100).contains(count), entries.isEmpty else { throw LoomError.message("Cycles require empty pool and count 1...100") }
        cycleResults.removeAll()
        for index in 0..<count {
            _ = try await open(count: 1, rate: 0, total: 64)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while entries.first?.audit.hasFooter != true, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard entries.first?.audit.hasFooter == true else { throw LoomError.message("Cycle output drain timed out") }
            let result = try await stop()
            cycleResults.append(["cycle": index, "result": result])
        }
        return ["cycles": cycleResults, "weakAlive": alive, "releaseVerified": true]
    }

    private static func json<T: Encodable>(_ value: T) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) ?? NSNull()
    }
}

/// No terminal history or second reader: fixed-size digests and at most 256
/// footer bytes. The oracle is in the external driver, independently generated.
final class EvidenceStreamAudit: TerminalOutputSink, @unchecked Sendable {
    private struct State {
        var wire = SHA256()
        var payload = SHA256()
        var wireBytes = 0
        var payloadBytes = 0
        var footer = Data()
        var footerOverflow = false
        var firstUptime: Double?
        var lastUptime: Double?
    }
    private let state = Mutex(State())
    private let downstream: any TerminalOutputSink
    private let expectedPayload: Int?
    init(downstream: any TerminalOutputSink, payloadBytes: Int?) {
        self.downstream = downstream; expectedPayload = payloadBytes
    }
    func receive(_ data: Data) {
        state.withLock { current in
            let now = ProcessInfo.processInfo.systemUptime
            if current.firstUptime == nil { current.firstUptime = now }
            current.lastUptime = now
            current.wire.update(data: data)
            current.wireBytes += data.count
            let payloadCount = min(data.count, max(0, (expectedPayload ?? Int.max) - current.payloadBytes))
            if payloadCount > 0 {
                current.payload.update(data: data.prefix(payloadCount))
                current.payloadBytes += payloadCount
            }
            if payloadCount < data.count {
                let remaining = data.suffix(data.count - payloadCount)
                if current.footer.count + remaining.count > 256 { current.footerOverflow = true }
                current.footer.append(contentsOf: remaining.prefix(max(0, 256 - current.footer.count)))
            }
        }
        downstream.receive(data)
    }
    var hasFooter: Bool {
        state.withLock { String(decoding: $0.footer, as: UTF8.self)
            .range(of: "^\\r\\nEND bytes=[0-9]+ seconds=[0-9]+\\.[0-9]{3}\\r\\n$", options: .regularExpression) != nil }
    }
    var snapshot: [String: Any] {
        state.withLock { current in
            let wire = current.wire
            let payload = current.payload
            return ["wireBytes": current.wireBytes, "payloadBytes": current.payloadBytes,
             "wireSHA256": wire.finalize().map { String(format: "%02x", $0) }.joined(),
             "payloadSHA256": payload.finalize().map { String(format: "%02x", $0) }.joined(),
             "footer": String(decoding: current.footer, as: UTF8.self), "footerOverflow": current.footerOverflow,
             "firstUptime": current.firstUptime.map { $0 as Any } ?? NSNull(), "lastUptime": current.lastUptime.map { $0 as Any } ?? NSNull()]
        }
    }
}
#endif
