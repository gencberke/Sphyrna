import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

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
        let nonce = String(repeating: "a", count: 64)
        let secret = token ?? environment["SPHYRNA_OPENCODE_TUI_TOKEN"]!
        return ["version": 1, "type": "hello", "generation": generation,
         "nonce": nonce, "proof": OpenCodeTUIAuthentication.proof(role: "hello", token: secret, nonce: nonce,
             generation: Int64(generation), appSessionID: app, runID: run, instanceID: instance),
         "appSessionID": app.uuidString, "runID": run.uuidString, "instanceID": instance.uuidString]
    }
    func authenticate(_ fd: Int32, generation: Int) async throws {
        try send(fd, [hello(generation)])
        let bytes = try await Task.detached { try readTUIFrame(fd, timeout: 2) }.value
        let welcome = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let nonce = try #require(welcome["nonce"] as? String)
        #expect(welcome["type"] as? String == "welcome")
        #expect(welcome["proof"] as? String == OpenCodeTUIAuthentication.proof(
            role: "welcome", token: environment["SPHYRNA_OPENCODE_TUI_TOKEN"]!, nonce: nonce,
            generation: Int64(generation), appSessionID: app, runID: run, instanceID: instance))
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

private actor OpenCodeTUIInputGate: OpenCodeTUIInputAdmission, OpenCodeTUIInputLease {
    private(set) var contexts: [OpenCodeTUIInputContext] = []
    private(set) var completions: [OpenCodeTUIInputAdmissionOutcome] = []
    var allowed = true
    func acquire(for input: OpenCodeTUIInputContext) async throws -> any OpenCodeTUIInputLease {
        contexts.append(input)
        guard allowed else { throw OpenCodeError.unavailable }
        return self
    }
    func finish(_ outcome: OpenCodeTUIInputAdmissionOutcome) async { completions.append(outcome) }
    func deny() { allowed = false }
    func allow() { allowed = true }
}

private actor OpenCodeTUIInputHTTP {
    func response(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let value: [String: Any]
        switch url.path {
        case "/api/info":
            value = ["pid": 1234, "version": "2.2.0", "urls": ["http://127.0.0.1:43123"],
                     "paths": ["tmp": "/private/tmp"]]
        case "/api/session":
            value = ["data": ["id": "ses_one", "location": ["directory": "/private/tmp"]]]
        default: throw OpenCodeError.invalidTarget
        }
        return (try JSONSerialization.data(withJSONObject: value),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private func selectedTUIClient(_ fixture: OpenCodeTUIBridgeFixture) async throws -> OpenCodeClient {
    let peer = OpenCodeTUIInputHTTP()
    let client = OpenCodeClient(base: URL(string: "http://127.0.0.1:43123")!, password: "fixture",
                                liveFeed: fixture.feed) { try await peer.response($0) }
    try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/private/tmp")
    _ = try await client.create(directory: "/private/tmp", model: nil)
    guard fixture.feed.receive(OpenCodeEvent(id: "evt_created", type: "session.created", sessionID: "ses_one",
                                              sequence: 1, inboxID: nil, version: 1)) else {
        throw OpenCodeError.unavailable
    }
    return client
}

private func readTUIFrame(_ fd: Int32, timeout: TimeInterval = 1) throws -> Data {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var bytes = Data()
    var byte: UInt8 = 0
    while bytes.count < 80 * 1024 {
        let n = recv(fd, &byte, 1, MSG_DONTWAIT)
        if n == 1 {
            if byte == 10 { return bytes }
            bytes.append(byte)
        } else if n == 0 { throw OpenCodeError.closed }
        else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            try LocalSocket.wait(descriptor: fd, events: Int16(POLLIN), deadline: deadline, operation: "fixture read")
        } else { throw OpenCodeError.unavailable }
    }
    throw OpenCodeError.responseTooLarge
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2))) struct OpenCodeTUIBridgeTests {
    @Test func handshakeMatchesIndependentHMACVectorAndSeparatesDirections() throws {
        let app = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let run = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        let instance = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000003"))
        let token = String(repeating: "a", count: 64), nonce = String(repeating: "c", count: 64)
        let hello = OpenCodeTUIAuthentication.proof(role: "hello", token: token, nonce: nonce,
                                                     generation: 1, appSessionID: app, runID: run, instanceID: instance)
        #expect(hello == "09e8ad65175e5382d922b52b2a4848887ac75690d6df95a52d9cc4d83997fb55")
        #expect(hello != OpenCodeTUIAuthentication.proof(role: "welcome", token: token, nonce: nonce,
                                                         generation: 1, appSessionID: app, runID: run, instanceID: instance))
    }

    @Test func authorizedInputGetsAnExactNativeReceiptWithoutClaimingDelivery() async throws {
        let owner = try #require(RunScopeTable.lineage(pid: getpid())).identity
        let fixture = try OpenCodeTUIBridgeFixture.make { $0.identity == owner }
        let fd = try fixture.connect()
        defer { Darwin.close(fd) }
        do {
            try await fixture.authenticate(fd, generation: 1)
            try fixture.send(fd, [fixture.route(2, "session", "ses_one")])
            #expect(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .session("ses_one") })
            let peer = OpenCodeTUIInputHTTP()
            let client = OpenCodeClient(base: URL(string: "http://127.0.0.1:43123")!, password: "fixture",
                                        liveFeed: fixture.feed) { try await peer.response($0) }
            try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/private/tmp")
            _ = try await client.create(directory: "/private/tmp", model: nil)
            #expect(fixture.feed.receive(OpenCodeEvent(id: "evt_created", type: "session.created",
                                                       sessionID: "ses_one", sequence: 1, inboxID: nil, version: 1)))
            let gate = OpenCodeTUIInputGate(), round = UUID()
            await gate.deny()
            await #expect(throws: OpenCodeError.unavailable) {
                _ = try await client.firstInput(sessionID: "ses_one", messageID: "msg_one", roundID: round,
                                                text: "approved", bridge: fixture.bridge, admission: gate, timeout: 2)
            }
            #expect(await gate.contexts.count == 1)
            #expect(await gate.completions.isEmpty)
            var input = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            #expect(poll(&input, 1, 0) == 0)
            await gate.allow()
            let task = Task {
                try await client.firstInput(sessionID: "ses_one", messageID: "msg_one", roundID: round,
                                            text: "approved", bridge: fixture.bridge, admission: gate, timeout: 2)
            }
            let bytes = try? await Task.detached { try readTUIFrame(fd) }.value
            #expect(bytes != nil, "An authorized input must reach the authenticated TUI socket")
            if let bytes {
                let frame = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                #expect(frame["type"] as? String == "prompt")
                #expect(frame["nativeSessionID"] as? String == "ses_one")
                #expect(frame["messageID"] as? String == "msg_one")
                #expect(frame["text"] as? String == "approved")
                let request = try #require(frame["requestID"] as? String)
                let admitted = try #require(await gate.contexts.last)
                #expect(admitted.requestID.uuidString == request)
                #expect(admitted.appSessionID == fixture.app && admitted.runID == fixture.run)
                #expect(admitted.instanceID == fixture.instance && admitted.roundID == round)
                #expect(admitted.nativeSessionID == "ses_one" && admitted.messageID == "msg_one")
                #expect(admitted.payloadFingerprint.count == 32)
                try fixture.send(fd, [["version": 1, "type": "receipt", "generation": 3, "requestID": request,
                                       "appSessionID": fixture.app.uuidString, "runID": fixture.run.uuidString,
                                       "instanceID": fixture.instance.uuidString, "nativeSessionID": "ses_one",
                                       "roundID": round.uuidString, "messageID": "msg_one",
                                       "inputType": "user", "text": "approved"]])
                #expect(try await task.value == "msg_one")
                #expect(fixture.feed.snapshot?.input?.state == .accepted)
                #expect(fixture.feed.snapshot?.input?.deliverySequence == nil)
                #expect(await gate.contexts.count == 2)
                #expect(await gate.completions == [.accepted])
                #expect(try await client.firstInput(sessionID: "ses_one", messageID: "msg_one", roundID: round,
                                                    text: "approved", bridge: fixture.bridge, admission: gate, timeout: 2) == "msg_one")
                await #expect(throws: OpenCodeError.conflict) {
                    _ = try await client.firstInput(sessionID: "ses_one", messageID: "msg_one", roundID: round,
                                                    text: "different", bridge: fixture.bridge, admission: gate, timeout: 2)
                }
                #expect(await gate.contexts.count == 2)
                #expect(poll(&input, 1, 0) == 0)
                let events: [(String, String, Int64, String?)] = [
                    ("evt_2", "session.inbox.enqueued", Int64(2), "msg_one"),
                    ("evt_3", "session.execution.started", Int64(3), nil),
                    ("evt_4", "session.inbox.delivered", Int64(4), "msg_one"),
                    ("evt_5", "session.execution.succeeded", Int64(5), nil)
                ]
                for (id, type, sequence, inbox) in events {
                    #expect(fixture.feed.receive(OpenCodeEvent(id: id, type: type, sessionID: "ses_one",
                                                               sequence: sequence, inboxID: inbox, version: 1)))
                }
                #expect(fixture.feed.snapshot?.input?.state == .settled(.succeeded))
                #expect(fixture.feed.snapshot?.input?.deliverySequence == 4)
            } else { _ = try? await task.value }
            await client.close()
        } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    @Test func wrongReplyOrLossIsIndeterminateAndCannotReplay() async throws {
        let owner = try #require(RunScopeTable.lineage(pid: getpid())).identity
        for fault in ["run", "instance", "request", "round", "session", "message", "type", "text", "native", "disconnect", "cancel", "timeout"] {
            let fixture = try OpenCodeTUIBridgeFixture.make { $0.identity == owner }
            let fd = try fixture.connect()
            do {
                try await fixture.authenticate(fd, generation: 1)
                try fixture.send(fd, [fixture.route(2, "session", "ses_one")])
                try #require(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .session("ses_one") })
                let client = try await selectedTUIClient(fixture)
                let gate = OpenCodeTUIInputGate(), round = UUID()
                let task = Task {
                    try await client.firstInput(sessionID: "ses_one", messageID: "msg_one", roundID: round,
                                                text: "approved", bridge: fixture.bridge, admission: gate, timeout: 2)
                }
                let bytes = try await Task.detached { try readTUIFrame(fd, timeout: 2) }.value
                let command = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                var reply: [String: Any] = ["version": 1, "type": "receipt", "generation": 3,
                    "requestID": try #require(command["requestID"] as? String), "appSessionID": fixture.app.uuidString,
                    "runID": fixture.run.uuidString, "instanceID": fixture.instance.uuidString, "roundID": round.uuidString,
                    "nativeSessionID": "ses_one", "messageID": "msg_one", "inputType": "user", "text": "approved"]
                switch fault {
                case "run": reply["runID"] = UUID().uuidString
                case "instance": reply["instanceID"] = UUID().uuidString
                case "request": reply["requestID"] = UUID().uuidString
                case "round": reply["roundID"] = UUID().uuidString
                case "session": reply["nativeSessionID"] = "ses_other"
                case "message": reply["messageID"] = "msg_other"
                case "type": reply["inputType"] = "assistant"
                case "text": reply["text"] = "different"
                case "native":
                    reply["type"] = "indeterminate"
                    for key in ["nativeSessionID", "messageID", "inputType", "text"] { reply.removeValue(forKey: key) }
                case "disconnect": _ = Darwin.shutdown(fd, SHUT_RDWR)
                case "cancel": task.cancel()
                case "timeout": break
                default: Issue.record("Unexpected fixture case")
                }
                if fault != "disconnect" && fault != "cancel" && fault != "timeout" { try? fixture.send(fd, [reply]) }
                await #expect(throws: (any Error).self) { _ = try await task.value }
                #expect(await gate.completions == [.indeterminate])
                #expect(fixture.feed.snapshot?.input?.state == .unknown)
                await #expect(throws: OpenCodeError.indeterminate) {
                    _ = try await client.firstInput(sessionID: "ses_one", messageID: "msg_one", roundID: round,
                                                    text: "approved", bridge: fixture.bridge, admission: gate, timeout: 2)
                }
                #expect(await gate.contexts.count == 1)
                if fault == "text" {
                    reply["generation"] = 4
                    reply["text"] = "approved"
                    try? fixture.send(fd, [reply])
                    #expect(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .unavailable })
                    #expect(fixture.feed.snapshot?.input?.state == .unknown)
                }
                await client.close()
                Darwin.close(fd)
                await fixture.cleanup()
            } catch {
                Darwin.close(fd)
                await fixture.cleanup()
                throw error
            }
        }
    }

    @Test func definiteRouteRejectionCanRetryOnlyWithoutInterveningNativeInput() async throws {
        let owner = try #require(RunScopeTable.lineage(pid: getpid())).identity
        for intervening in [false, true] {
            let fixture = try OpenCodeTUIBridgeFixture.make { $0.identity == owner }
            let fd = try fixture.connect()
            do {
                try await fixture.authenticate(fd, generation: 1)
                try fixture.send(fd, [fixture.route(2, "session", "ses_one")])
                try #require(await SessionRuntimeTests.waitUntil(2) { fixture.bridge.snapshot.route == .session("ses_one") })
                let client = try await selectedTUIClient(fixture)
                let gate = OpenCodeTUIInputGate(), round = UUID()
                let first = Task {
                    try await client.firstInput(sessionID: "ses_one", messageID: "msg_one", roundID: round,
                                                text: "approved", bridge: fixture.bridge, admission: gate, timeout: 2)
                }
                let firstBytes = try await Task.detached { try readTUIFrame(fd, timeout: 2) }.value
                let firstFrame = try #require(JSONSerialization.jsonObject(with: firstBytes) as? [String: Any])
                if intervening {
                    #expect(fixture.feed.receive(OpenCodeEvent(id: "evt_human", type: "session.inbox.enqueued",
                                                               sessionID: "ses_one", sequence: 2,
                                                               inboxID: "msg_human", version: 1)))
                }
                try fixture.send(fd, [["version": 1, "type": "rejected", "generation": 3,
                                       "requestID": try #require(firstFrame["requestID"] as? String),
                                       "appSessionID": fixture.app.uuidString, "runID": fixture.run.uuidString,
                                       "instanceID": fixture.instance.uuidString, "roundID": round.uuidString]])
                await #expect(throws: OpenCodeError.unavailable) { _ = try await first.value }
                if intervening {
                    #expect(await gate.completions == [.indeterminate])
                    #expect(fixture.feed.snapshot?.input?.state == .unknown)
                    await #expect(throws: OpenCodeError.indeterminate) {
                        _ = try await client.firstInput(sessionID: "ses_one", messageID: "msg_one", roundID: round,
                                                        text: "approved", bridge: fixture.bridge, admission: gate, timeout: 2)
                    }
                } else {
                    #expect(await gate.completions == [.notDispatched])
                    #expect(fixture.feed.snapshot?.creationSequence == 1)
                    #expect(fixture.feed.snapshot?.input == nil)
                    let retry = Task {
                        try await client.firstInput(sessionID: "ses_one", messageID: "msg_one", roundID: round,
                                                    text: "approved", bridge: fixture.bridge, admission: gate, timeout: 2)
                    }
                    let retryBytes = try? await Task.detached { try readTUIFrame(fd, timeout: 1) }.value
                    #expect(retryBytes != nil, "A definite non-dispatch must allow the same approved input to retry")
                    if let retryBytes {
                        let retryFrame = try #require(JSONSerialization.jsonObject(with: retryBytes) as? [String: Any])
                        try fixture.send(fd, [["version": 1, "type": "receipt", "generation": 4,
                            "requestID": try #require(retryFrame["requestID"] as? String),
                            "appSessionID": fixture.app.uuidString, "runID": fixture.run.uuidString,
                            "instanceID": fixture.instance.uuidString, "roundID": round.uuidString,
                            "nativeSessionID": "ses_one", "messageID": "msg_one", "inputType": "user", "text": "approved"]])
                        #expect(try await retry.value == "msg_one")
                        #expect(await gate.completions == [.notDispatched, .accepted])
                    } else { _ = try? await retry.value }
                }
                await client.close()
                Darwin.close(fd)
                await fixture.cleanup()
            } catch {
                Darwin.close(fd)
                await fixture.cleanup()
                throw error
            }
        }
    }
    @Test func realPeerValidatorDenialCannotPublishSelection() async throws {
        let probe = OpenCodeTUIValidationProbe()
        let fixture = try OpenCodeTUIBridgeFixture.make { member in
            probe.record(member)
            return false
        }
        do {
            let fd = try fixture.connect()
            defer { Darwin.close(fd) }
            // A successful denial can close the socket before this write finishes.
            try? fixture.send(fd, [fixture.hello(1), fixture.route(2, "session", "ses_denied")])
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
            try await fixture.authenticate(first, generation: 1)
            try fixture.send(first, [fixture.route(2, "session", "ses_one")])
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
            try await fixture.authenticate(second, generation: 3)
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
        try await fixture.authenticate(fd, generation: 1)
        try fixture.send(fd, [fixture.route(2, "session", "ses_one")])
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
            try await fixture.authenticate(fd, generation: 1)
            try fixture.send(fd, [fixture.route(2, "session", "ses_one")])
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
            import hashlib, hmac, json, os, socket, sys
            env = os.environ
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.settimeout(7)
            peer.connect(env['SPHYRNA_OPENCODE_TUI_SOCKET'])
            generation = int(env['FIXTURE_GENERATION'])
            nonce = os.urandom(32).hex()
            app = env['SPHYRNA_OPENCODE_TUI_APP_SESSION_ID']
            run = env['SPHYRNA_OPENCODE_TUI_RUN_ID']
            instance = env['SPHYRNA_OPENCODE_TUI_INSTANCE_ID']
            def signature(role):
                value = '\n'.join(['sphyrna.opencode.tui.v1', role, nonce, app, run, instance, str(generation)])
                return hmac.new(env['SPHYRNA_OPENCODE_TUI_TOKEN'].encode(), value.encode(), hashlib.sha256).hexdigest()
            hello = dict(version=1, type='hello', generation=generation,
                nonce=nonce, proof=signature('hello'), appSessionID=app, runID=run, instanceID=instance)
            route = dict(version=1, type='route', generation=generation + 1,
                kind='session', nativeSessionID=env['FIXTURE_SESSION'])
            try:
                peer.sendall((json.dumps(hello) + '\n').encode())
                welcome = b''
                while not welcome.endswith(b'\n') and len(welcome) < 4096:
                    part = peer.recv(1)
                    if not part: sys.exit(0)
                    welcome += part
                value = json.loads(welcome)
                if value.get('nonce') != nonce or not hmac.compare_digest(value.get('proof', ''), signature('welcome')):
                    sys.exit(4)
                peer.sendall((json.dumps(route) + '\n').encode())
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
