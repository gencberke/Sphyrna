import Foundation
import Testing
@testable import LoomCore

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct OpenCodeServerManagerTests {
    @Test func ownedFakeServerIsAuthenticatedAndStoppedWithItsScope() async throws {
        let context = try await SessionRuntimeTests.makeContext(startRuntime: false, scoped: true)
        defer { context.cleanup() }
        let script = context.root.appendingPathComponent("opencode-fake")
        let source = """
            #!/usr/bin/python3
            import base64, json, os, subprocess
            from http.server import HTTPServer, BaseHTTPRequestHandler
            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args): pass
                def do_GET(self):
                    key = base64.b64encode(('opencode:' + os.environ['OPENCODE_PASSWORD']).encode()).decode()
                    if self.headers.get('Authorization') != 'Basic ' + key:
                        self.send_response(401); self.end_headers(); return
                    body = json.dumps({'version':'2.2.0','pid':os.getpid(),
                        'urls':['http://127.0.0.1:%d' % self.server.server_port],
                        'paths':{'tmp':os.environ['OPEN_CODE_TEST_TMP']}}).encode()
                    self.send_response(200); self.send_header('Content-Length', str(len(body)))
                    self.end_headers(); self.wfile.write(body)
            child = subprocess.Popen(['/bin/sleep', '60'], start_new_session=True)
            with open(os.environ['OPEN_CODE_CHILD_PID_PATH'], 'w') as handle: handle.write(str(child.pid))
            server = HTTPServer(('127.0.0.1', 0), Handler)
            print('server listening on http://127.0.0.1:%d' % server.server_port, flush=True)
            server.serve_forever()
            """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let childPIDFile = context.root.appendingPathComponent("detached-child-pid")
        let scope = try await context.supervisor.openScope()
        let manager = OpenCodeServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path, workingDirectory: context.home.path,
            environment: ["PATH": "/usr/bin:/bin", "HOME": context.home.path,
                          "OPEN_CODE_TEST_TMP": context.root.appendingPathComponent("tmp/opencode").path,
                          "OPEN_CODE_CHILD_PID_PATH": childPIDFile.path],
            expectedVersion: "2.2.0", expectedTemporaryDirectory: context.root.appendingPathComponent("tmp/opencode").path,
            startupTimeout: 10, scope: scope))
        do {
            async let first = manager.start()
            async let second = manager.start()
            let (firstClient, secondClient) = try await (first, second)
            #expect(firstClient === secondClient)
            #expect(await context.supervisor.runningSessionIDs().count == 1)
            let pidText = try String(contentsOf: childPIDFile, encoding: .utf8)
            let childPID = try #require(Int32(pidText))
            #expect(ProcessTable.record(pid: childPID) != nil)
            let stopped = await manager.stop()
            #expect(stopped.errors.isEmpty)
            #expect(stopped.report?.succeeded == true)
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
        try "#!/bin/sh\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let scope = try await context.supervisor.openScope()
        let manager = OpenCodeServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path, workingDirectory: context.home.path,
            environment: ["PATH": "/usr/bin:/bin", "HOME": context.home.path], expectedVersion: "2.2.0",
            expectedTemporaryDirectory: "/tmp/fixture", startupTimeout: 4, scope: scope))
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
        try "#!/usr/bin/python3\nimport time\nprint('x' * 70000, flush=True)\ntime.sleep(30)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let scope = try await context.supervisor.openScope()
        let manager = OpenCodeServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path, workingDirectory: context.home.path,
            environment: ["PATH": "/usr/bin:/bin", "HOME": context.home.path], expectedVersion: "2.2.0",
            expectedTemporaryDirectory: "/tmp/fixture", startupTimeout: 2, scope: scope))
        await #expect(throws: OpenCodeError.responseTooLarge) { _ = try await manager.start() }
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await manager.stop()).errors.isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

}
