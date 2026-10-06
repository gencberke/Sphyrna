import Foundation
import LoomCore

extension Probe {
    /// Attaches to an already-running server. Does not launch a provider or start/answer a turn.
    static func codexObservers(socket: String, thread: String, directory: URL, seconds: Double, capacity: Int) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready.json").path),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshot.json").path) else {
            throw LoomError.message("Observer output directory already used")
        }
        let a = CodexWireDiagnostics(connection: "A", threadID: thread, capacity: capacity)
        let b = CodexWireDiagnostics(connection: "B", threadID: thread, capacity: capacity)
        var clients: [CodexAppServerClient] = []
        var drains: [Task<Void, Never>] = []
        var barriers: [UInt64] = [0, 0]
        struct Output: Codable {
            let ready: Bool
            let observationCompleted: Bool
            let comparisonWindowValid: Bool
            let A: CodexWireDiagnostics.Snapshot
            let B: CodexWireDiagnostics.Snapshot
        }
        func write(ready: Bool, completed: Bool) throws {
            let sa = a.snapshot(), sb = b.snapshot()
            func turns(_ snapshot: CodexWireDiagnostics.Snapshot, after: UInt64) -> Set<String> {
                Set(snapshot.entries.filter { $0.sequence > after && $0.method == "turn/started" && $0.routing == "target-run" }.compactMap(\.turnLabel))
            }
            let sameSingleTurn = turns(sa, after: barriers[0]).count == 1 && turns(sa, after: barriers[0]) == turns(sb, after: barriers[1])
            let observedTurn = turns(sa, after: barriers[0]).first
            let sameRunLabels = zip([sa, sb], barriers).allSatisfy { snapshot, barrier in
                snapshot.entries.filter { $0.sequence > barrier && $0.routing == "target-run" }
                    .compactMap(\.turnLabel).allSatisfy { $0 == observedTurn }
            }
            let routingComplete = (sa.entries + sb.entries).allSatisfy { $0.decode != "pending" && $0.routing != "pending" }
            try encoder.encode(Output(ready: ready, observationCompleted: completed,
                                      comparisonWindowValid: ready && completed && sameSingleTurn && sameRunLabels && routingComplete && !sa.invalidated && !sb.invalidated,
                                      A: sa, B: sb)).write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        }
        do {
            for diagnostics in [a, b] {
                clients.append(try await CodexAppServerClient.connect(socketPath: socket,
                    clientName: "loom-observer-diagnosis", clientVersion: "1", timeout: 3, wireDiagnostics: diagnostics))
                let stream = clients.last!.events
                drains.append(Task { for await _ in stream {} })
            }
            for (index, method) in ["thread/read", "thread/resume"].enumerated() {
                let result = try await clients[index].request(method: method,
                    params: .object(["threadId": .string(thread)]), timeout: 3)
                guard result.object?["thread"]?.object?["id"]?.string == thread else {
                    throw LoomError.message("Observer preparation identity mismatch")
                }
            }
            guard !a.snapshot().invalidated, !b.snapshot().invalidated else {
                throw LoomError.message("Observer preparation invalidated")
            }
            barriers = [a.snapshot().entries.last?.sequence ?? 0, b.snapshot().entries.last?.sequence ?? 0]
            // The barrier contains no real thread/socket/run identifiers.
            try encoder.encode(JSONValue.object(["ready": .bool(true), "AInitialized": .bool(true), "BInitialized": .bool(true),
                                "AReadMatched": .bool(true), "BResumeMatched": .bool(true),
                                "ASequence": .number(Double(barriers[0])), "BSequence": .number(Double(barriers[1]))])).write(
                                    to: directory.appendingPathComponent("ready.json"), options: .atomic)
            print("OBSERVERS_READY")
            try await Task.sleep(for: .seconds(seconds))
            try write(ready: true, completed: true)
            for client in clients { await client.close() }
            for drain in drains { await drain.value }
            print("OBSERVERS_SNAPSHOT")
        } catch {
            a.invalidate("preparation"); b.invalidate("preparation")
            try? write(ready: false, completed: false)
            for client in clients { await client.close() }
            for drain in drains { await drain.value }
            // Provider errors can contain content; never render the underlying error.
            throw LoomError.message("Observer preparation or observation failed; see content-free snapshot")
        }
    }
}
