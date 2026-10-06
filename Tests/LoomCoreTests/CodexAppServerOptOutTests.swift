import Foundation
import Testing
@testable import LoomCore

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CodexAppServerInbound] = []
    func add(_ value: CodexAppServerInbound) { lock.withLock { values.append(value) } }
    var all: [CodexAppServerInbound] { lock.withLock { values } }
    var unknownMethods: [String] {
        all.compactMap { if case let .event(_, .unknown(method)) = $0 { method } else { nil } }
    }
    var turnCompletions: Int {
        all.filter { if case .event(_, .turnCompleted) = $0 { true } else { false } }.count
    }
    var requests: [CodexServerRequest] {
        all.compactMap { if case let .request(_, request) = $0 { request } else { nil } }
    }
    func contains(_ matches: (CodexAppServerEvent) -> Bool) -> Bool {
        all.contains { if case let .event(_, event) = $0 { matches(event) } else { false } }
    }
}

@Suite(.serialized, .timeLimit(.minutes(2)))
struct CodexAppServerOptOutTests {
    private func startServer(_ context: RuntimeContext) async throws -> (CodexAppServerManager, CodexAppServerClient, String) {
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true)
        let executable = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path
        let script = context.root.appendingPathComponent("server")
        try "#!/bin/sh\nexec '\(executable)' \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let socket = context.socketDirectory.appendingPathComponent("server.sock").path
        let manager = CodexAppServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path,
            capabilities: .init(version: "fixture", help: "--remote <ADDR>", serverHelp: "--listen <URL>"),
            home: context.profile,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": context.home.path, "LOOM_FAKE_STATE": context.state.path],
            workingDirectory: context.home.path, socketPath: socket,
            clientVersion: "test", startupTimeout: 5
        ))
        return (manager, try await manager.start(), socket)
    }

    private func collect(_ client: CodexAppServerClient) -> (Collected, Task<Void, Never>) {
        let collected = Collected()
        let stream = client.events
        return (collected, Task { for await inbound in stream { collected.add(inbound) } })
    }

    private func startTurn(_ client: CodexAppServerClient, thread: String, text: String) async throws {
        _ = try await client.request(method: "turn/start", params: .object([
            "threadId": .string(thread),
            "input": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]))
    }

    @Test func productConnectionSkipsOptedOutNotificationsButKeepsEverythingItConsumes() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let (manager, product, socket) = try await startServer(context)
        // A second connection without opt-out stands in for the TUI / diagnostics.
        let full = try await CodexAppServerClient.connect(socketPath: socket, clientName: "full", clientVersion: "test")
        let (productEvents, productTask) = collect(product)
        let (fullEvents, fullTask) = collect(full)
        defer { productTask.cancel(); fullTask.cancel() }

        let started = try await product.request(method: "thread/start", params: .object(["cwd": .string(context.home.path)]))
        let thread = try #require(started.object?["thread"]?.object?["id"]?.string)
        try await full.joinThread(thread)

        try await startTurn(product, thread: thread, text: "stream 20")
        #expect(try await SessionRuntimeTests.waitUntil { productEvents.turnCompletions == 1 && fullEvents.turnCompletions == 1 })

        // The control connection really receives the stream the product opted out of.
        #expect(fullEvents.unknownMethods.filter { $0 == "item/agentMessage/delta" }.count == 20)
        #expect(fullEvents.unknownMethods.contains("thread/tokenUsage/updated"))
        // The product connection receives none of it, so nothing is decoded for it.
        #expect(productEvents.unknownMethods.isEmpty)
        // What Loom consumes is intact: thread/turn lifecycle and status.
        #expect(productEvents.contains { if case .threadStarted = $0 { true } else { false } })
        #expect(productEvents.contains { if case .turnStarted = $0 { true } else { false } })
        #expect(productEvents.contains { if case .threadStatusChanged(_, .idle) = $0 { true } else { false } })
        #expect(productEvents.contains { if case .turnCompleted(_, _, .completed, "echo stream 20") = $0 { true } else { false } })

        // Approvals are requests, not notifications: they still arrive and resolve.
        try await startTurn(product, thread: thread, text: "approve")
        #expect(try await SessionRuntimeTests.waitUntil { !productEvents.requests.isEmpty })
        let request = try #require(productEvents.requests.first)
        #expect(request.kind == .commandExecution)
        try await product.respond(id: request.id, result: .object(["decision": .string("accept")]))
        #expect(try await SessionRuntimeTests.waitUntil {
            productEvents.contains { if case .serverRequestResolved = $0 { true } else { false } }
                && productEvents.turnCompletions == 2
        })
        #expect(productEvents.unknownMethods.isEmpty)

        await full.close()
        #expect(await manager.stop()?.succeeded == true)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func initializeAdvertisesOnlyUnconsumedMethods() {
        let list = Set(CodexAppServerClient.productOptOutNotificationMethods)
        let consumed: Set = [
            "thread/started", "thread/status/changed", "turn/started", "turn/completed",
            "error", "serverRequest/resolved", "thread/closed",
        ]
        #expect(list.isDisjoint(with: consumed))
        #expect(list.count == CodexAppServerClient.productOptOutNotificationMethods.count)
        #expect(list.contains("item/agentMessage/delta") && list.contains("thread/tokenUsage/updated"))
    }

    @Test func lastTurnComesFromTheNewestPageWithoutReadingHistory() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let (manager, client, _) = try await startServer(context)
        let (events, task) = collect(client)
        defer { task.cancel() }

        let started = try await client.request(method: "thread/start", params: .object(["cwd": .string(context.home.path)]))
        let thread = try #require(started.object?["thread"]?.object?["id"]?.string)

        // A fresh thread has no persisted turns: idle, no last turn, no error.
        let fresh = try await client.readThread(thread)
        #expect(fresh.threadID == thread)
        #expect(fresh.lastTurnID == nil && fresh.lastTurnOutcome == nil && fresh.lastAssistantMessage == nil)
        #expect(fresh.isIdle && !fresh.isActive && fresh.hasNoActiveTurn)

        for text in ["one", "two", "three"] {
            let before = events.turnCompletions
            try await startTurn(client, thread: thread, text: text)
            #expect(try await SessionRuntimeTests.waitUntil { events.turnCompletions == before + 1 })
        }
        let snapshot = try await client.readThread(thread)
        #expect(snapshot.lastTurnID?.hasPrefix("turn-3-") == true)
        #expect(snapshot.lastTurnOutcome == .completed)
        #expect(snapshot.lastAssistantMessage == "echo three")
        #expect(snapshot.lastTurnStartedAt != nil)
        #expect(snapshot.isIdle)

        // An active turn reports its in-progress outcome and the active status.
        try await startTurn(client, thread: thread, text: "work 5000")
        let active = try await client.readThread(thread)
        #expect(active.isActive && active.lastTurnID?.hasPrefix("turn-4-") == true)
        #expect(active.lastTurnOutcome == .unknown("inProgress"))

        // An unknown thread still fails instead of looking like an empty one.
        do {
            _ = try await client.readThread("00000000-0000-0000-0000-000000000000")
            Issue.record("Expected thread-not-found")
        } catch CodexAppServerError.rpc(let code, let message, _) {
            #expect(code == -32600 && message.contains("not found"))
        }

        // Only single-turn pages were requested; the whole history was never read.
        let log = (try? String(contentsOf: context.state.appendingPathComponent("codex-turns-list.log"), encoding: .utf8)) ?? ""
        #expect(!log.isEmpty && log.split(separator: "\n").allSatisfy { $0 == "limit=1 sort=desc" })
        #expect(!FileManager.default.fileExists(atPath: context.state.appendingPathComponent("codex-full-reads.log").path))

        #expect(await manager.stop()?.succeeded == true)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
