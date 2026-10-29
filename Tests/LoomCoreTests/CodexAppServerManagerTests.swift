import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

private actor StartupCleanupProbe {
    private(set) var failed: SessionStopReport?
    func observe(_ report: SessionStopReport?) { failed = report }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct CodexAppServerManagerTests {
    func manager(_ context: RuntimeContext, body: String, timeout: Double = 3) throws -> CodexAppServerManager {
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: context.socketDirectory.path)
        let script = context.root.appendingPathComponent("server")
        try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return CodexAppServerManager(supervisor: context.supervisor, configuration: .init(
            executable: script.path,
            capabilities: .init(version: "fixture", help: "--remote <ADDR>", serverHelp: "--listen <URL>"),
            home: context.profile,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": context.home.path,
                              "LOOM_FAKE_STATE": context.state.path],
            workingDirectory: context.home.path,
            socketPath: context.socketDirectory.appendingPathComponent("server.sock").path,
            clientVersion: "test", startupTimeout: timeout
        ))
    }

    @Test(arguments: [
        ("echo 'LOOM_FIXTURE_STARTUP_FAILURE Permission denied secret-token=/private/value' >&2; exit 42", "exit code 42", "permission denied"),
        ("exit 7", "exit code 7", "no startup output"),
        ("kill -TERM $$", "signal 15", "no startup output")
    ])
    func earlyExit(_ fixture: (String, String, String)) async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let server = try manager(context, body: fixture.0, timeout: 30)
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await server.start()
            Issue.record("Expected startup failure")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("during startup"))
            #expect(message.contains(fixture.1))
            #expect(message.contains(fixture.2))
            #expect(!message.contains("secret-token"))
            #expect(!message.contains("/private/value"))
        }
        // The exit surfaces long before the startup timeout, which is 30 s so that load cannot reach it (it took 3.2 s once
        // under a combined run's load); the reasons above show it was the exit and not the timeout.
        #expect(ProcessInfo.processInfo.systemUptime - start < 15)
        #expect(await server.internalSessionID() == nil)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func liveServerWithoutSocketTimesOutWithConnectionReason() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let server = try manager(context, body: "exec /bin/sleep 30", timeout: 0.2)
        do {
            _ = try await server.start()
            Issue.record("Expected timeout")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("timed out during startup"))
            #expect(message.contains("No such file or directory"))
        }
        #expect(await server.internalSessionID() == nil)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func delayedStartupSucceedsAndStops() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true)
        let executable = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path
        let server = try manager(context, body: "sleep 0.15\nexec '\(executable)' \"$@\"", timeout: 30)
        _ = try await server.start()
        #expect(await server.internalSessionID() != nil)
        #expect(await server.stop()?.succeeded == true)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aPreexistingSocketPathIsNeverReplacedOrConnected() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true)
        let path = context.socketDirectory.appendingPathComponent("server.sock")
        try "foreign sentinel".write(to: path, atomically: true, encoding: .utf8)
        let executable = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path
        let server = try manager(context, body: "exec '\(executable)' \"$@\"")
        do {
            _ = try await server.start()
            Issue.record("A pre-existing path must prevent startup")
            _ = await server.stop()
        } catch {}
        #expect((try? String(contentsOf: path, encoding: .utf8)) == "foreign sentinel")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aHashedSocketIsClaimedFromTheListenerAndOnlyItsNodesAreRemoved() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let hashes = context.socketDirectory.appendingPathComponent("h", isDirectory: true)
        try FileManager.default.createDirectory(at: hashes, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let requested = context.socketDirectory.appendingPathComponent("owned.sock").path
        var ownership = try CodexSocketOwnership(requested: requested, hashedDirectory: hashes.path)
        let unrelated = hashes.appendingPathComponent("unrelated")
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)
        var listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { if listener >= 0 { Darwin.close(listener) } }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(ownership.hashed.utf8) + [0]
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0 && listen(listener, 4) == 0 && chmod(ownership.hashed, 0o600) == 0)
        try #require(symlink(ownership.hashed, requested) == 0)
        let leader = try #require(ProcessTable.record(pid: getpid())?.identity)
        #expect(try ownership.claimIfReady(leader: leader))
        #expect(try ownership.remainingSocket() == ownership.hashed)
        Darwin.close(listener)
        listener = -1
        try ownership.removeRemaining()
        var link = stat()
        #expect(lstat(requested, &link) == -1 && errno == ENOENT)
        #expect(!FileManager.default.fileExists(atPath: ownership.hashed))
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func anUnexpectedSocketLinkIsNeverFollowed() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let hashes = context.socketDirectory.appendingPathComponent("h", isDirectory: true)
        try FileManager.default.createDirectory(at: hashes, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let requested = context.socketDirectory.appendingPathComponent("link.sock").path
        var ownership = try CodexSocketOwnership(requested: requested, hashedDirectory: hashes.path)
        let foreign = context.socketDirectory.appendingPathComponent("foreign")
        try "keep".write(to: foreign, atomically: true, encoding: .utf8)
        #expect(symlink(foreign.path, requested) == 0)
        let leader = try #require(ProcessTable.record(pid: getpid())?.identity)
        #expect(throws: (any Error).self) { try ownership.claimIfReady(leader: leader) }
        #expect(throws: (any Error).self) { try ownership.removeRemaining() }
        #expect(try String(contentsOf: foreign, encoding: .utf8) == "keep")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func quitDuringStartupCancelsAndCleansUp() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let server = try manager(context, body: "exec /bin/sleep 30", timeout: 10)
        let acquire = Task { try await server.start() }
        #expect(await SessionRuntimeTests.waitUntil { !(await context.supervisor.runningSessionIDs()).isEmpty })
        let internalID = try #require(await context.supervisor.runningSessionIDs().first)
        let runID = try #require(await context.supervisor.session(id: internalID)?.currentRun?.id)
        let probe = StartupCleanupProbe()
        try await context.supervisor.registerStopHooks(runID: runID, hooks: ManagedRunStopHooks(
            prepare: {
                if Task.isCancelled {
                    // Deterministically exercise a canceled startup cleanup that
                    // cannot prove native destruction, leaving its handle owned.
                    await context.supervisor.setOwnershipSamplingFailpointForTesting {
                        throw LoomError.message("startup cleanup count unavailable")
                    }
                } else {
                    await probe.observe(await context.supervisor.lastStopReport(sessionID: internalID))
                    await context.supervisor.setOwnershipSamplingFailpointForTesting(nil)
                }
            }, completed: {}))
        let start = ProcessInfo.processInfo.systemUptime
        let stopped = await server.stop()
        let firstFailure = await probe.failed
        let lastCleanup = await context.supervisor.lastStopReport(sessionID: internalID)
        let observedCleanup = firstFailure ?? lastCleanup
        #expect(observedCleanup?.remainingCountVerified == false)
        #expect(observedCleanup?.signals.isEmpty == true)
        #expect(stopped?.succeeded == true)
        await context.supervisor.setOwnershipSamplingFailpointForTesting(nil)
        do {
            _ = try await acquire.value
            Issue.record("Quit must cancel startup")
        } catch { #expect(error is CancellationError) }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
        #expect(await server.internalSessionID() == nil)
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func outputIsBoundedAndOnlyFixedCategoriesEscape() {
        let tee = DiagnosticOutputTee(downstream: nil)
        tee.receive(Data("LOOM_FIXTURE_STARTUP_FAILURE\n".utf8))
        tee.receive(Data(repeating: 65, count: 100_000))
        #expect(tee.text.hasPrefix("LOOM_FIXTURE_STARTUP_FAILURE"))
        #expect(tee.text.utf8.count == DiagnosticOutputTee.limit)
        #expect(CodexAppServerManager.safeStartupDetail(tee.text) == "unrecognized startup output withheld")
        #expect(CodexAppServerManager.safeStartupDetail("unauthorized Bearer secret env=private")
            == "startup output reported: unauthorized")
    }
}
