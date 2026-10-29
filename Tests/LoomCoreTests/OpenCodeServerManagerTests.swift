import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct OpenCodeServerManagerTests {
    private func proof(context: RuntimeContext, executable: URL, extra: [String: String] = [:]) async throws -> (OpenCodeProfileProof, [String: String]) {
        let root = context.home.path
        let roots = OpenCodeProfileRoots(home: root, data: root, cache: root, config: root, state: root,
                                         tmp: root, bin: root, log: root, repos: root, db: root + "/fixture.db")
        let resolvedRoot = realPath(context.home)
        let resolved = OpenCodeProfileRoots(home: resolvedRoot, data: resolvedRoot, cache: resolvedRoot,
                                            config: resolvedRoot, state: resolvedRoot, tmp: resolvedRoot,
                                            bin: resolvedRoot, log: resolvedRoot, repos: resolvedRoot,
                                            db: resolvedRoot + "/fixture.db")
        let rows = ["home": roots.home, "data": roots.data, "cache": roots.cache, "config": roots.config,
                    "state": roots.state, "tmp": roots.tmp, "bin": roots.bin, "log": roots.log,
                    "repos": roots.repos, "db": roots.db].sorted { $0.key < $1.key }
            .map { "\($0.key.padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.value)\n" }.joined()
        var environment = ["PATH": "/usr/bin:/bin", "HOME": root, "OPEN_CODE_PROFILE_OUTPUT": rows]
        environment.merge(extra) { _, new in new }
        let proof = try await OpenCodeProfileProof.acquire(supervisor: context.supervisor, executable: executable.path,
                                                           environment: environment, workingDirectory: context.home.path,
                                                           expected: roots, expectedResolved: resolved)
        return (proof, environment)
    }
    @Test func ownedFakeServerIsAuthenticatedAndStoppedWithItsScope() async throws {
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup() }
        let script = context.root.appendingPathComponent("opencode-fake")
        let source = #"""
            #!/usr/bin/python3
            import base64, json, os, subprocess, sys, threading
            if sys.argv[1:] == ['debug', 'paths']:
                print(os.environ['OPEN_CODE_PROFILE_OUTPUT'], end='')
                sys.exit(0)
            from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
            class Handler(BaseHTTPRequestHandler):
                protocol_version = 'HTTP/1.1'
                def log_message(self, *args): pass
                def allowed(self):
                    key = base64.b64encode(('opencode:' + os.environ['OPENCODE_PASSWORD']).encode()).decode()
                    return self.headers.get('Authorization') == 'Basic ' + key
                def answer(self, body):
                    data = json.dumps(body).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    self.wfile.flush()
                def event(self, kind, seq, inbox=None):
                    data = {'sessionID': 'ses_fixture'}
                    if inbox is not None: data['inboxID'] = inbox
                    event = {'id': 'evt_%d' % seq, 'type': kind, 'data': data,
                             'durable': {'aggregateID': 'ses_fixture', 'seq': seq, 'version': 1}}
                    with self.server.event_lock:
                        target = self.server.subscriber
                        target.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                        target.wfile.flush()
                def do_GET(self):
                    if not self.allowed():
                        self.send_response(401); self.send_header('Content-Length', '0'); self.end_headers(); return
                    if self.path.startswith('/api/event?'):
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/event-stream')
                        self.end_headers()
                        self.server.subscriber = self
                        self.wfile.write(b'data: {"id":"evt_ready","type":"server.connected","data":{}}\n\n')
                        self.wfile.flush()
                        self.connection.recv(1)
                        return
                    self.answer({'version':'2.2.0','pid':os.getpid(),
                        'urls':['http://127.0.0.1:%d' % self.server.server_port],
                        'paths':{'tmp':os.environ['OPEN_CODE_TEST_TMP']}})
                def do_POST(self):
                    if not self.allowed():
                        self.send_response(401); self.send_header('Content-Length', '0'); self.end_headers(); return
                    payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    if self.path == '/api/session':
                        self.event('session.created', 1)
                        self.answer({'data': {'id':'ses_fixture', 'location': payload['location']}})
                        def replay_fixture():
                            with open(os.environ['OPEN_CODE_TEST_EVENT_FIFO'], 'r') as signal:
                                signal.read(1)
                            self.event('session.inbox.enqueued', 2, 'msg_one')
                            self.event('session.execution.started', 3)
                            self.event('session.inbox.delivered', 4, 'msg_one')
                            self.event('session.execution.succeeded', 5)
                        threading.Thread(target=replay_fixture, daemon=True).start()
                    else:
                        self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()
            child = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True)
            with open(os.environ['OPEN_CODE_CHILD_PID_PATH'], 'w') as handle: handle.write(str(child.pid))
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            server.event_lock = threading.Lock()
            server.subscriber = None
            print('server listening on http://127.0.0.1:%d' % server.server_port, flush=True)
            server.serve_forever()
            """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let childPIDFile = context.root.appendingPathComponent("detached-child-pid")
        let eventFIFO = context.root.appendingPathComponent("event-fifo")
        guard mkfifo(eventFIFO.path, 0o600) == 0 else { throw OpenCodeError.unavailable }
        let fifoReader = open(eventFIFO.path, O_RDONLY | O_NONBLOCK)
        guard fifoReader >= 0 else { throw OpenCodeError.unavailable }
        defer { Darwin.close(fifoReader) }
        let (verified, environment) = try await proof(context: context, executable: script,
            extra: ["OPEN_CODE_TEST_TMP": context.home.path, "OPEN_CODE_CHILD_PID_PATH": childPIDFile.path,
                    "OPEN_CODE_TEST_EVENT_FIFO": eventFIFO.path])
        let scope = try await context.supervisor.openScope()
        let manager = OpenCodeServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path, workingDirectory: context.home.path,
            environment: environment, expectedVersion: "2.2.0", profileProof: verified,
            startupTimeout: 10, scope: scope))
        do {
            let firstClient = try await manager.start()
            let secondClient = try await manager.start()
            #expect(firstClient === secondClient)
            #expect(await context.supervisor.runningSessionIDs().count == 1)
            let appID = UUID(), runID = UUID(), roundID = UUID()
            let live = try await firstClient.openLive(appSessionID: appID, runID: runID)
            let session = try await firstClient.create(directory: context.home.path, model: nil)
            #expect(session.id == "ses_fixture")
            #expect(await SessionRuntimeTests.waitUntil(2) { live.snapshot?.creationSequence == 1 })
            #expect(live.snapshot?.execution == .unknown)
            await #expect(throws: OpenCodeError.unavailable) {
                _ = try await firstClient.firstInput(sessionID: session.id, messageID: "msg_one",
                                                     roundID: roundID, text: "fixture input")
            }
            // Synthetic round evidence tests the reducer without granting API input authority.
            try live.begin(roundID: roundID, inputID: "msg_one", requireCreation: true)
            try live.receipt(inputID: "msg_one")
            let signal = Task.detached { try Data("1".utf8).write(to: eventFIFO) }
            try await signal.value
            #expect(await SessionRuntimeTests.waitUntil(2) { live.snapshot?.input?.state == .settled(.succeeded) })
            #expect(live.snapshot?.appSessionID == appID)
            #expect(live.snapshot?.runID == runID)
            #expect(live.snapshot?.input?.roundID == roundID)
            #expect(live.snapshot?.input?.creationSequence == 1)
            #expect(live.snapshot?.input?.startSequence == 3)
            #expect(live.snapshot?.input?.deliverySequence == 4)
            #expect(live.snapshot?.input?.terminalSequence == 5)
            let pidText = try String(contentsOf: childPIDFile, encoding: .utf8)
            let childPID = try #require(Int32(pidText))
            #expect(ProcessTable.record(pid: childPID) != nil)
            let stopped = await manager.stop()
            #expect(stopped.errors.isEmpty)
            #expect(stopped.report?.succeeded == true)
            #expect(!live.isConnected)
            #expect(live.snapshot?.execution == .unknown)
            #expect(live.snapshot?.input?.state == .unknown)
            #expect(live.snapshot?.input?.creationSequence == nil)
            #expect(live.snapshot?.input?.startSequence == nil)
            #expect(live.snapshot?.input?.deliverySequence == nil)
            #expect(live.snapshot?.input?.terminalSequence == nil)
            #expect(await context.supervisor.runningSessionIDs().isEmpty)
            #expect(ProcessTable.record(pid: childPID).map(\.zombie) ?? true)
        } catch {
            _ = await manager.stop()
            _ = await context.supervisor.releaseScope(scope)
            _ = await context.runtime.shutdown()
            throw error
        }
        #expect((await context.runtime.shutdown()).succeeded)
    }
    @Test func stopDuringStartupCancelsAndCleansOwnedServer() async throws {
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup() }
        let script = context.root.appendingPathComponent("silent-fake")
        try "#!/bin/sh\nif [ \"$1\" = debug ]; then printf '%s' \"$OPEN_CODE_PROFILE_OUTPUT\"; exit 0; fi\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let (verified, environment) = try await proof(context: context, executable: script)
        let scope = try await context.supervisor.openScope()
        let manager = OpenCodeServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path, workingDirectory: context.home.path,
            environment: environment, expectedVersion: "2.2.0", profileProof: verified, startupTimeout: 4, scope: scope))
        let starting = Task { try await manager.start() }
        #expect(await SessionRuntimeTests.waitUntil { !(await context.supervisor.runningSessionIDs()).isEmpty })
        let started = ProcessInfo.processInfo.systemUptime
        let stopped = await manager.stop()
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(stopped.errors.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await starting.value }
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func excessiveStartupOutputStopsInsteadOfWaitingOrRetainingIt() async throws {
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup() }
        let script = context.root.appendingPathComponent("noisy-fake")
        try "#!/usr/bin/python3\nimport os, sys, time\nif sys.argv[1:] == ['debug', 'paths']:\n    print(os.environ['OPEN_CODE_PROFILE_OUTPUT'], end='')\n    sys.exit(0)\nprint('x' * 70000, flush=True)\ntime.sleep(30)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let (verified, environment) = try await proof(context: context, executable: script)
        let scope = try await context.supervisor.openScope()
        let manager = OpenCodeServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path, workingDirectory: context.home.path,
            environment: environment, expectedVersion: "2.2.0", profileProof: verified, startupTimeout: 2, scope: scope))
        await #expect(throws: OpenCodeError.responseTooLarge) { _ = try await manager.start() }
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await manager.stop()).errors.isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func changedEnvironmentPreventsServerSpawn() async throws {
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup() }
        let script = context.root.appendingPathComponent("gated-fake")
        let marker = context.root.appendingPathComponent("server-started")
        try "#!/bin/sh\nif [ \"$1\" = debug ]; then printf '%s' \"$OPEN_CODE_PROFILE_OUTPUT\"; exit 0; fi\n/bin/touch \"$OPEN_CODE_SERVER_MARKER\"\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let (verified, environment) = try await proof(context: context, executable: script,
                                                       extra: ["OPEN_CODE_SERVER_MARKER": marker.path])
        var changed = environment
        changed["XDG_DATA_HOME"] = "/different"
        let scope = try await context.supervisor.openScope()
        let manager = OpenCodeServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path, workingDirectory: context.home.path, environment: changed,
            expectedVersion: "2.2.0", profileProof: verified, startupTimeout: 0.5, scope: scope))
        await #expect(throws: OpenCodeProfileError.changed) { _ = try await manager.start() }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await manager.stop()).errors.isEmpty)
        #expect((await context.supervisor.releaseScope(scope)).isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func cancelingTheStartupOwnerReapsItsServerWithoutAnExternalStop() async throws {
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup() }
        let script = context.root.appendingPathComponent("cancel-owner-fake")
        try "#!/bin/sh\nif [ \"$1\" = debug ]; then printf '%s' \"$OPEN_CODE_PROFILE_OUTPUT\"; exit 0; fi\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let (verified, environment) = try await proof(context: context, executable: script)
        let scope = try await context.supervisor.openScope()
        let manager = OpenCodeServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path, workingDirectory: context.home.path, environment: environment,
            expectedVersion: "2.2.0", profileProof: verified, startupTimeout: 4, scope: scope))
        let caller = Task { try await manager.start() }
        guard await SessionRuntimeTests.waitUntil(5, { !(await context.supervisor.runningSessionIDs()).isEmpty }) else {
            caller.cancel(); _ = await manager.stop(); _ = try? await caller.value
            _ = await context.runtime.shutdown(); Issue.record("fake server did not start"); return
        }
        let started = ProcessInfo.processInfo.systemUptime
        caller.cancel()
        await #expect(throws: CancellationError.self) { _ = try await caller.value }
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await context.supervisor.ledgerSnapshot().scopes ?? []).isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func startupAdmitsOnlyOneOwnerWhileReadyServerIsReusable() async throws {
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup() }
        let script = context.root.appendingPathComponent("single-owner-fake")
        try "#!/bin/sh\nif [ \"$1\" = debug ]; then printf '%s' \"$OPEN_CODE_PROFILE_OUTPUT\"; exit 0; fi\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let (verified, environment) = try await proof(context: context, executable: script)
        let scope = try await context.supervisor.openScope()
        let manager = OpenCodeServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path, workingDirectory: context.home.path, environment: environment,
            expectedVersion: "2.2.0", profileProof: verified, startupTimeout: 4, scope: scope))
        let caller = Task { try await manager.start() }
        guard await SessionRuntimeTests.waitUntil(5, { !(await context.supervisor.runningSessionIDs()).isEmpty }) else {
            caller.cancel(); _ = await manager.stop(); _ = try? await caller.value
            _ = await context.runtime.shutdown(); Issue.record("fake server did not start"); return
        }
        await #expect(throws: OpenCodeError.conflict) { _ = try await manager.start() }
        caller.cancel()
        await #expect(throws: CancellationError.self) { _ = try await caller.value }
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

}
