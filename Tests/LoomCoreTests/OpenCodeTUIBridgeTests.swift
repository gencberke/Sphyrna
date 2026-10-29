import Darwin
import Foundation
import Testing
@testable import LoomCore

private final class OpenCodeTUIValidationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [RunScopeMember] = []
    private var firstIdentity: ProcessIdentity?
    func record(_ member: RunScopeMember) { lock.withLock { seen.append(member) } }
    var members: [RunScopeMember] { lock.withLock { seen } }
    func admitFirst(_ member: RunScopeMember) -> Bool {
        lock.withLock {
            seen.append(member)
            if firstIdentity == nil { firstIdentity = member.identity }
            return member.identity == firstIdentity
        }
    }
}

private struct OpenCodeTUIBridgeFixture {
    let root: URL
    let bridge: OpenCodeTUIBridge
    let environment: [String: String]
    let owner: RunScopeMember
    let feed: OpenCodeLiveFeed
    let policy: OpenCodeTUIPolicyProof
    let app: UUID
    let run: UUID
    let instance: UUID

    static func make(validate: @escaping OpenCodeTUIBridge.Validator) throws -> Self {
        let root = URL(fileURLWithPath: "/private/tmp/sphyrna-tui-\(UUID().uuidString.prefix(12))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let app = UUID(), run = UUID(), instance = UUID()
        let owner = try #require(RunScopeTable.lineage(pid: getpid()))
        let feed = OpenCodeLiveFeed(appSessionID: app, runID: run)
        feed.didConnect()
        let revision = try #require(feed.beginPolicyCheck())
        let policy = try #require(feed.finishPolicyCheck(revision: revision, allowed: true,
                                                         serverURL: URL(string: "http://127.0.0.1:43123")!,
                                                         directory: "/private/tmp", pluginDirectory: root.path))
        let bridge = try OpenCodeTUIBridge.start(socketPath: root.appendingPathComponent("observe.sock").path,
                                                 appSessionID: app, runID: run, instanceID: instance,
                                                 policy: policy,
                                                 validateOwnedTUI: validate)
        let terminal = ProviderLaunchProfile(arguments: ["--server", "http://127.0.0.1:43123",
                                                          "--session", "ses_one", "/private/tmp"], environment: ["PATH": "/usr/bin"])
        let environment = try bridge.applyingToTerminal(terminal).environment
        return Self(root: root, bridge: bridge, environment: environment, owner: owner, feed: feed, policy: policy,
                    app: app, run: run, instance: instance)
    }

    func connect() throws -> Int32 { try LocalSocket.connect(path: root.appendingPathComponent("observe.sock").path, timeout: 2) }
    func hello(_ generation: Int, token: String? = nil) -> [String: Any] {
        ["version": 1, "type": "hello", "generation": generation,
         "token": token ?? environment["SPHYRNA_OPENCODE_TUI_TOKEN"]!,
         "appSessionID": app.uuidString, "runID": run.uuidString, "instanceID": instance.uuidString]
    }
    func route(_ generation: Int, _ kind: String, _ session: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["version": 1, "type": "route", "generation": generation, "kind": kind]
        if let session { result["nativeSessionID"] = session }
        return result
    }
    func send(_ fd: Int32, _ messages: [[String: Any]]) throws {
        var data = Data()
        for message in messages {
            data.append(try JSONSerialization.data(withJSONObject: message))
            data.append(10)
        }
        try LocalSocket.writeAll(data, to: fd, deadline: ProcessInfo.processInfo.systemUptime + 2)
    }
    func cleanup() async {
        await bridge.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

private func tuiPeerClosed(_ fd: Int32) -> Bool {
    var byte: UInt8 = 0
    let result = recv(fd, &byte, 1, MSG_DONTWAIT)
    return result == 0 || (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2))) struct OpenCodeTUIBridgeTests {
    @Test func realPeerValidatorDenialCannotPublishSelection() async throws {
        let probe = OpenCodeTUIValidationProbe()
        let fixture = try OpenCodeTUIBridgeFixture.make { member in
            probe.record(member)
            return false
        }
        do {
            let fd = try fixture.connect()
            defer { Darwin.close(fd) }
            try fixture.send(fd, [fixture.hello(1), fixture.route(2, "session", "ses_denied")])
            #expect(await SessionRuntimeTests.waitUntil(2) { !probe.members.isEmpty })
            #expect(probe.members.first?.identity == fixture.owner.identity)
            #expect(probe.members.first?.idVersion == fixture.owner.idVersion)
            #expect(await SessionRuntimeTests.waitUntil(2) { tuiPeerClosed(fd) })
            #expect(fixture.bridge.snapshot.route == .unavailable)
        } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    @Test func authenticatedRouteReloadAndStaleGenerationFailClosed() async throws {
        let owner = try #require(RunScopeTable.lineage(pid: getpid())).identity
        let fixture = try OpenCodeTUIBridgeFixture.make { $0.identity == owner }
        do {
            let first = try fixture.connect()
            defer { Darwin.close(first) }
            try fixture.send(first, [fixture.hello(1), fixture.route(2, "session", "ses_one")])
            #expect(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .session("ses_one") })
            #expect(fixture.bridge.snapshot.generation == 2)
            #expect(fixture.bridge.snapshot.instanceID == fixture.instance)

            let denied = try fixture.connect()
            defer { Darwin.close(denied) }
            try fixture.send(denied, [fixture.hello(3, token: String(repeating: "0", count: 64)),
                                       fixture.route(4, "session", "ses_bad")])
            #expect(await SessionRuntimeTests.waitUntil(2) { tuiPeerClosed(denied) })
            #expect(fixture.bridge.snapshot.route == .session("ses_one"))

            let second = try fixture.connect()
            defer { Darwin.close(second) }
            try fixture.send(second, [fixture.hello(3)])
            #expect(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .unavailable })
            try fixture.send(second, [fixture.route(4, "session", "ses_other")])
            #expect(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .session("ses_other") })
            #expect(tuiPeerClosed(first))
            #expect(fixture.bridge.snapshot.route == .session("ses_other"))

            try fixture.send(second, [fixture.route(5, "home")])
            #expect(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .home })
            try fixture.send(second, [fixture.route(6, "plugin")])
            #expect(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .plugin })
            try fixture.send(second, [fixture.route(6, "session", "ses_old")])
            #expect(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .unavailable })
            #expect(fixture.bridge.snapshot.generation == nil)
        } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    @Test func stopClosesOnlyItsSocketAndNeverUnlinksAReplacement() async throws {
        let owner = try #require(RunScopeTable.lineage(pid: getpid())).identity
        let fixture = try OpenCodeTUIBridgeFixture.make { $0.identity == owner }
        let fd = try fixture.connect()
        defer { Darwin.close(fd) }
        try fixture.send(fd, [fixture.hello(1), fixture.route(2, "session", "ses_one")])
        #expect(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .session("ses_one") })
        let path = fixture.root.appendingPathComponent("observe.sock")
        try FileManager.default.removeItem(at: path)
        try Data("replacement".utf8).write(to: path)
        await fixture.bridge.stop()
        #expect(await SessionRuntimeTests.waitUntil(2) { tuiPeerClosed(fd) })
        #expect(fixture.bridge.snapshot.route == .unavailable)
        #expect(try String(contentsOf: path, encoding: .utf8) == "replacement")
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test func capabilityCannotBeAppliedToTheServerProfile() async throws {
        let owner = try #require(RunScopeTable.lineage(pid: getpid())).identity
        let fixture = try OpenCodeTUIBridgeFixture.make { $0.identity == owner }
        let server = try OpenCodeLaunchProfile.server(environment: [:], password: "fixture-server")
        #expect(throws: OpenCodeError.invalidTarget) { try fixture.bridge.applyingToTerminal(server) }
        await fixture.cleanup()
    }

    @Test func configChangeAndFeedLossRevokeAnActiveRoute() async throws {
        let owner = try #require(RunScopeTable.lineage(pid: getpid())).identity
        for event in ["config.updated", "plugin.updated", "disconnect"] {
            let fixture = try OpenCodeTUIBridgeFixture.make { $0.identity == owner }
            let fd = try fixture.connect()
            try fixture.send(fd, [fixture.hello(1), fixture.route(2, "session", "ses_one")])
            #expect(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .session("ses_one") })
            if event == "disconnect" { fixture.feed.didDisconnect() }
            else {
                #expect(fixture.feed.receive(OpenCodeEvent(id: "evt_update", type: event,
                                                          sessionID: nil, sequence: nil, inboxID: nil)))
            }
            #expect(!fixture.policy.isValid)
            #expect(fixture.bridge.snapshot.route == .unavailable)
            #expect(await SessionRuntimeTests.waitUntil(2) { tuiPeerClosed(fd) })
            Darwin.close(fd)
            await fixture.cleanup()
        }
    }

    @Test func anotherSupervisedProcessWithTheSameDirectoryCannotRebindTheTUI() async throws {
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        let probe = OpenCodeTUIValidationProbe()
        let fixture = try OpenCodeTUIBridgeFixture.make { probe.admitFirst($0) }
        let script = #"""
            import json, os, socket, sys
            env = os.environ
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(7)
            peer.connect(env['SPHYRNA_OPENCODE_TUI_SOCKET'])
            generation = int(env['FIXTURE_GENERATION'])
            hello = dict(version=1, type='hello', generation=generation,
                token=env['SPHYRNA_OPENCODE_TUI_TOKEN'],
                appSessionID=env['SPHYRNA_OPENCODE_TUI_APP_SESSION_ID'],
                runID=env['SPHYRNA_OPENCODE_TUI_RUN_ID'],
                instanceID=env['SPHYRNA_OPENCODE_TUI_INSTANCE_ID'])
            route = dict(version=1, type='route', generation=generation + 1,
                kind='session', nativeSessionID=env['FIXTURE_SESSION'])
            try:
                peer.sendall((json.dumps(hello) + '\n' + json.dumps(route) + '\n').encode())
                data = peer.recv(1)
                sys.exit(0 if data == b'' else 3)
            except (BrokenPipeError, ConnectionResetError):
                sys.exit(0)
            """#
        let supervisor = context.supervisor
        let baseEnvironment = fixture.environment
        let launch: @Sendable (Int, String) async throws -> Int32 = { generation, session in
            var environment = baseEnvironment
            environment["FIXTURE_GENERATION"] = String(generation)
            environment["FIXTURE_SESSION"] = session
            let inputEnvironment = environment
            return try await supervisor.runOwnedJob(scope: .perCall) { _, job, spawner in
                let result = try LaunchEnvironment.capture("/usr/bin/python3", ["-c", script], environment: inputEnvironment,
                                                           directory: "/private/tmp", timeout: 8, outputLimit: 1024,
                                                           spawner: spawner, onSpawn: { try job.register(pid: $0) },
                                                           onPoll: { try job.sample() })
                defer { spawner.abort(result.pid) }
                return result.status
            }
        }
        let first = Task { try await launch(1, "ses_one") }
        do {
            try #require(await SessionRuntimeTests.waitUntil(4) { fixture.bridge.snapshot.route == .session("ses_one") })
            #expect(try await launch(3, "ses_other") == 0)
            #expect(probe.members.count >= 2)
            #expect(Set(probe.members.map(\.identity)).count >= 2)
            #expect(fixture.bridge.snapshot.route == .session("ses_one"))
            await fixture.cleanup()
            #expect(try await first.value == 0)
            #expect((await context.supervisor.ledgerSnapshot().scopes ?? []).isEmpty)
        } catch {
            await fixture.cleanup()
            _ = try? await first.value
            _ = await context.runtime.shutdown()
            context.cleanup()
            throw error
        }
        _ = await context.runtime.shutdown()
        context.cleanup()
    }
}
