import Foundation
import LoomCore

/// Counts inbound frames on Loom's own app-server connection.
private final class InboundTally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: (count: Int, bytes: Int)] = [:]
    func add(_ method: String?, _ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        let key = method ?? "<response>"
        let old = counts[key] ?? (0, 0)
        counts[key] = (old.count + 1, old.bytes + bytes)
    }
    func snapshot() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        var total = (count: 0, bytes: 0), notifications = (count: 0, bytes: 0)
        var perMethod: [String: JSONValue] = [:]
        for (key, value) in counts {
            total.count += value.count; total.bytes += value.bytes
            if key != "<response>" { notifications.count += value.count; notifications.bytes += value.bytes }
            perMethod[key] = .object(["count": .number(Double(value.count)), "bytes": .number(Double(value.bytes))])
        }
        return .object([
            "framesTotal": .number(Double(total.count)), "bytesTotal": .number(Double(total.bytes)),
            "methodFrames": .number(Double(notifications.count)), "methodBytes": .number(Double(notifications.bytes)),
            "perMethod": .object(perMethod),
        ])
    }
}

private final class ObservedState: @unchecked Sendable {
    private let lock = NSLock()
    private var transitions: [JSONValue] = []
    private var completed: [(String, String?)] = []
    private var requests: [String] = []
    func note(_ value: String) { lock.lock(); transitions.append(.string(value)); lock.unlock() }
    func complete(_ id: String, _ message: String?) { lock.lock(); completed.append((id, message)); lock.unlock() }
    func request(_ method: String) { lock.lock(); requests.append(method); transitions.append(.string("request")); lock.unlock() }
    func completedCount() -> Int { lock.lock(); defer { lock.unlock() }; return completed.count }
    func snapshot() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        return .object([
            "transitions": .array(transitions), "requestMethods": .array(requests.map(JSONValue.string)),
            "completedTurnIDs": .array(completed.map { .string($0.0) }),
            "completedMessages": .array(completed.map { .string($0.1 ?? "<nil>") }),
        ])
    }
}

private func shape(_ value: JSONValue?) -> JSONValue {
    switch value {
    case let .object(object): return .object(object.mapValues { shape($0) })
    case let .array(items): return .array(items.isEmpty ? [] : [shape(items[0]), .string("x\(items.count)")])
    case .string: return .string("string")
    case .number: return .string("number")
    case .bool: return .string("bool")
    case .null, .none: return .string("null")
    }
}

extension Probe {
    /// Real-Codex measurement of Loom's own app-server connection with and without
    /// notification opt-out. Content-free output: counts, bytes, shapes, booleans.
    /// `mode` is `optout` (product list) or `none`; `approval` adds one approval turn.
    static func codexObserverMeasure(root: URL, mode: String, approval: Bool, outputDirectory: URL) async throws {
        let ledger = OwnershipLedger()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent("runs/\(ledger.runID.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let supervisor = try ProcessSupervisor(ledger: ledger, ledgerURL: directory.appendingPathComponent("ledger.json"))
        guard let owner = try ProcessTable.snapshot().first(where: { $0.identity.pid == getpid() }) else {
            throw LoomError.message("Cannot record probe owner identity")
        }
        try JSONEncoder().encode(owner.identity).write(to: directory.appendingPathComponent("owner.json"), options: .atomic)
        let tally = InboundTally()
        var result: [String: JSONValue] = ["mode": .string(mode)]
        do {
            let resolution = try await supervisor.terminalEnvironment(origin: .development)
            var env = resolution.environment
            env["CODEX_HOME"] = root.appendingPathComponent("codex-home").path
            let version = try capture("codex", ["--version"], environment: env)
            let help = try capture("codex", ["--help"], environment: env)
            let serverHelp = try capture("codex", ["app-server", "--help"], environment: env)
            result["codexVersion"] = .string(version.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let executable = resolution.environment["PATH"]?.split(separator: ":")
                .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path })
                .first(where: { access($0, X_OK) == 0 }) else { throw LoomError.message("Codex executable not found") }
            let socket = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".loom-dev/m-\(ledger.runID.uuidString.prefix(8)).sock")
            let workspace = root.appendingPathComponent("workspace").path
            let manager = CodexAppServerManager(supervisor: supervisor, configuration: CodexAppServerConfiguration(
                executable: executable,
                capabilities: ProviderCapabilities(version: version, help: help, serverHelp: serverHelp),
                home: root.appendingPathComponent("codex-home"), baseEnvironment: resolution.environment,
                workingDirectory: workspace, socketPath: socket.path, clientVersion: "probe-\(version)",
                optOutNotificationMethods: mode == "none" ? [] : CodexAppServerClient.productOptOutNotificationMethods
                    + (mode == "bogus" ? ["loom/nonexistent/method", "item/futureDelta"] : []),
                inboundObserver: { tally.add($0, $1) }))
            let client = try await manager.start()
            if mode == "edges" {
                var edges: [String: JSONValue] = [:]
                func attempt(_ label: String, _ method: String, _ params: [String: JSONValue]) async {
                    do { edges[label] = shape(try await client.request(method: method, params: .object(params))) }
                    catch let error as CodexAppServerError {
                        edges[label] = .string("\(error) | isThreadNotFound=\(error.isThreadNotFound)")
                    } catch { edges[label] = .string("\(error)") }
                }
                let listed = try await client.request(method: "thread/list", params: .object(["limit": .number(20)]))
                let ids = (listed.object?["data"]?.array ?? []).compactMap { $0.object?["id"]?.string }
                edges["persistedThreadsListed"] = .number(Double(ids.count))
                var chosen: String?
                for id in ids {
                    if let page = try? await client.request(method: "thread/read", params: .object(["threadId": .string(id), "includeTurns": .bool(true)])),
                       !(page.object?["thread"]?.object?["turns"]?.array ?? []).isEmpty { chosen = id; break }
                }
                if let id = chosen {
                    let loaded = try await client.request(method: "thread/loaded/list")
                    edges["loadedBeforeCount"] = .number(Double(loaded.object?["data"]?.array?.count ?? -1))
                    await attempt("persisted_readNoTurns", "thread/read", ["threadId": .string(id), "includeTurns": .bool(false)])
                    await attempt("persisted_turnsList", "thread/turns/list", ["threadId": .string(id), "limit": .number(1), "sortDirection": .string("desc"), "itemsView": .string("summary")])
                    await attempt("persisted_readFullOld", "thread/read", ["threadId": .string(id), "includeTurns": .bool(true)])
                    do { edges["persisted_newReadThread"] = .string("\(try await client.readThread(id))") }
                    catch { edges["persisted_newReadThread"] = .string("error: \(error)") }
                }
                let ghost = "00000000-0000-4000-8000-000000000000"
                await attempt("unknown_readNoTurns", "thread/read", ["threadId": .string(ghost), "includeTurns": .bool(false)])
                await attempt("unknown_turnsList", "thread/turns/list", ["threadId": .string(ghost), "limit": .number(1)])
                await attempt("unknown_readFullOld", "thread/read", ["threadId": .string(ghost), "includeTurns": .bool(true)])
                do { edges["unknown_newReadThread"] = .string("ok?\(try await client.readThread(ghost))") }
                catch let error as CodexAppServerError { edges["unknown_newReadThread"] = .string("\(error) | isThreadNotFound=\(error.isThreadNotFound)") }
                result["edges"] = .object(edges)
                _ = await manager.stop(graceSeconds: 0.2)
                _ = await supervisor.shutdown(graceSeconds: 0.2)
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(JSONValue.object(result)).write(to: outputDirectory.appendingPathComponent("measure-edges.json"), options: .atomic)
                return
            }
            let started = try await client.request(method: "thread/start", params: .object(["cwd": .string(workspace)]))
            guard let threadID = started.object?["thread"]?.object?["id"]?.string else {
                throw LoomError.message("thread/start returned no thread id")
            }
            // Fresh thread: no persisted turns yet.
            var fresh: [String: JSONValue] = [:]
            for (label, params) in [
                ("turnsListSummary", ["threadId": JSONValue.string(threadID), "limit": .number(1)]),
                ("turnsListNotLoaded", ["threadId": .string(threadID), "limit": .number(1), "itemsView": .string("notLoaded")]),
            ] {
                do {
                    fresh[label] = shape(try await client.request(method: "thread/turns/list", params: .object(params)))
                } catch { fresh[label] = .string("error: \(error)") }
            }
            do {
                fresh["readNoTurns"] = shape(try await client.request(method: "thread/read",
                    params: .object(["threadId": .string(threadID), "includeTurns": .bool(false)])))
            } catch { fresh["readNoTurns"] = .string("error: \(error)") }
            do {
                fresh["readWithTurns"] = shape(try await client.request(method: "thread/read",
                    params: .object(["threadId": .string(threadID), "includeTurns": .bool(true)])))
            } catch { fresh["readWithTurns"] = .string("error: \(error)") }
            do { fresh["snapshot"] = .string("\(try await client.readThread(threadID))") } catch { fresh["snapshot"] = .string("error: \(error)") }
            do {
                _ = try await client.request(method: "thread/turns/list", params: .object(["threadId": .string("00000000-0000-0000-0000-000000000000"), "limit": .number(1)]))
                fresh["missingThread"] = .string("ok")
            } catch { fresh["missingThread"] = .string("\(error)") }
            result["freshThread"] = .object(fresh)

            var turns: [JSONValue] = []
            let prompts = mode == "bogus" ? [] : approval
                ? [("plain", "Reply with the single word OK. Do not use tools."),
                   ("approval", "Run the shell command `touch loom-approval-probe.txt` in the current directory, then reply DONE.")]
                : [("plain", "Reply with the single word OK. Do not use tools.")]
            let observed = ObservedState()
            let stream = client.events
            let reader = Task { [client] in
                for await inbound in stream {
                    switch inbound {
                    case let .event(_, event):
                        switch event {
                        case let .threadStatusChanged(_, status): observed.note("status:\(status)")
                        case .turnStarted: observed.note("turnStarted")
                        case let .turnCompleted(_, id, outcome, message):
                            observed.note("turnCompleted:\(outcome)")
                            observed.complete(id, message)
                        case .error: observed.note("error")
                        case .serverRequestResolved: observed.note("serverRequestResolved")
                        default: break
                        }
                    case let .request(_, request):
                        observed.request(request.method)
                        try? await client.respond(id: request.id, result: .object(["decision": .string("decline")]))
                    }
                }
            }
            for (index, (label, prompt)) in prompts.enumerated() {
                let before = tally.snapshot()
                _ = try await client.request(method: "turn/start", params: .object([
                    "threadId": .string(threadID),
                    "input": .array([.object(["type": .string("text"), "text": .string(prompt)])]),
                ]), timeout: 60)
                let deadline = Date().addingTimeInterval(150)
                while observed.completedCount() <= index, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                turns.append(.object(["label": .string(label), "tallyBefore": before,
                                      "completed": .bool(observed.completedCount() > index)]))
            }
            reader.cancel()
            result["observed"] = observed.snapshot()
            result["modelTurns"] = .number(Double(prompts.count))
            let snapshot = try await client.readThread(threadID)
            result["finalSnapshot"] = .object([
                "lastTurnID": .string(snapshot.lastTurnID ?? "<nil>"),
                "outcome": .string("\(String(describing: snapshot.lastTurnOutcome))"),
                "lastMessage": .string(snapshot.lastAssistantMessage ?? "<nil>"),
                "startedAtPresent": .bool(snapshot.lastTurnStartedAt != nil),
                "status": .string("\(snapshot.status)"),
            ])
            let old = try await client.request(method: "thread/read", params: .object([
                "threadId": .string(threadID), "includeTurns": .bool(true)]))
            let oldTurns = old.object?["thread"]?.object?["turns"]?.array ?? []
            let oldLast = oldTurns.last?.object
            result["legacyRead"] = .object([
                "turnCount": .number(Double(oldTurns.count)),
                "lastTurnID": .string(oldLast?["id"]?.string ?? "<nil>"),
                "lastMessage": .string((oldLast?["items"]?.array ?? []).reversed()
                    .compactMap { $0.object?["type"]?.string == "agentMessage" ? $0.object?["text"]?.string : nil }.first ?? "<nil>"),
            ])
            let listFull = try await client.request(method: "thread/turns/list", params: .object([
                "threadId": .string(threadID), "limit": .number(1), "itemsView": .string("summary")]))
            result["turnsListSummaryShape"] = shape(listFull)
            result["inboundTally"] = tally.snapshot()
            result["perTurnTally"] = .array(turns)
            let release = await manager.stop(graceSeconds: 0.2)
            let shutdown = await supervisor.shutdown(graceSeconds: 0.2)
            result["releaseSucceeded"] = .bool(release?.succeeded == true)
            result["shutdownSucceeded"] = .bool(shutdown.succeeded)
        } catch {
            result["failure"] = .string("\(error)")
            _ = await supervisor.shutdown(graceSeconds: 0.2)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(JSONValue.object(result)).write(
            to: outputDirectory.appendingPathComponent("measure-\(mode)-\(approval ? "approval" : "plain").json"), options: .atomic)
    }
}
