import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// Whether a stopped Codex server's socket node still has a listener is decided in-process: no helper and no run scope.
// serialized: one fake server and its run scope per test, like CodexAppServerManagerTests
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct CodexSocketCleanupTests {
    @Test func aStoppedServersLeftoverSocketIsRemovedWithoutAHelperOrAScope() async throws {
        let context = try await SessionRuntimeRig.makeContext(scoped: true)
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: context.socketDirectory.path)
        let socket = context.socketDirectory.appendingPathComponent("server.sock").path
        let server = CodexAppServerManager(supervisor: context.supervisor, configuration: .init(
            executable: context.root.appendingPathComponent("bin/loom-fake-provider").path,
            capabilities: .init(version: "fixture", help: "--remote <ADDR>", serverHelp: "--listen <URL>"),
            home: context.profile,
            // The fake server leaves its socket node behind when it is stopped, as an abnormal exit does.
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": context.home.path, "LOOM_FAKE_STATE": context.state.path,
                              "LOOM_FAKE_CODEX_LEAVE_SOCKET": "1"],
            workingDirectory: context.home.path, socketPath: socket, clientVersion: "test", startupTimeout: 30
        ))
        _ = try await server.start()
        #expect(FileManager.default.fileExists(atPath: socket))
        let opened = await context.supervisor.scopesOpened
        let report = await server.stop()
        #expect(report?.succeeded == true, "stop: \(report?.errors ?? [])")
        var node = stat()
        #expect(lstat(socket, &node) == -1 && errno == ENOENT, "the unbound node is removed")
        #expect(await context.supervisor.scopesOpened == opened, "no run scope was opened for the socket check")
        #expect(await context.supervisor.liveScopes.isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aNodeAnotherProcessListensOnIsNotRemoved() async throws {
        let directory = URL(fileURLWithPath: "/tmp/lsc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let hashes = directory.appendingPathComponent("h", isDirectory: true)
        try FileManager.default.createDirectory(at: hashes, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let requested = directory.appendingPathComponent("owned.sock").path
        var ownership = try CodexSocketOwnership(requested: requested, hashedDirectory: hashes.path)
        var listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { if listener >= 0 { Darwin.close(listener) } }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(requested.utf8) + [0]
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(listener, 4) == 0 && chmod(requested, 0o600) == 0)
        let leader = try #require(ProcessTable.record(pid: getpid())?.identity)
        #expect(try ownership.claimIfReady(leader: leader))

        // Another process inherits the listener; this one closes its copy.
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("600"), nil]
        defer { arguments.forEach { free($0) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        // Only the listener is inherited, never another test's descriptors.
        try #require(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
                     && posix_spawn_file_actions_addinherit_np(&actions, listener) == 0)
        try #require(posix_spawn(&pid, "/bin/sleep", &actions, &attributes, &arguments, nil) == 0)
        let child = pid
        var reaped = false
        defer { if !reaped { kill(child, SIGKILL); _ = try? reap(child) } }
        Darwin.close(listener)
        listener = -1

        #expect(throws: (any Error).self, "a listening node is not cleared for removal") { try ownership.verifyNoListener() }
        #expect(FileManager.default.fileExists(atPath: requested))

        try #require(kill(child, SIGKILL) == 0)
        try await onOwnThread("loom.test.reap") { try reap(child) }
        reaped = true
        try ownership.verifyNoListener()
        try ownership.removeRemaining()
        var node = stat()
        #expect(lstat(requested, &node) == -1 && errno == ENOENT, "once nothing listens the node is removed")
    }
}

private func reap(_ pid: pid_t) throws {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        guard errno == EINTR else { throw LoomError.system("waitpid", errno) }
    }
}
