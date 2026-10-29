import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// CP5 C review §4.1 madde 3 and 5: capability probes are owned, bounded and
/// stopped by Quit; the Codex profile follows override > terminal > default.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ProviderToolchainTests {
    private var fake: String {
        RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path
    }

    private func supervisor() throws -> ProcessSupervisor {
        try ProcessSupervisor(ledger: OwnershipLedger())
    }

    private func alive(_ pid: Int32) throws -> Bool {
        try ProcessTable.snapshot().contains { $0.identity.pid == pid && !$0.zombie }
    }

    private func pidFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("loom-pid-\(UUID())")
    }

    private func readPID(_ file: URL, wait: TimeInterval = 5) async -> Int32? {
        var pid: Int32?
        _ = await SessionRuntimeRig.waitUntil(wait) {
            pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int32($0) }
            return pid != nil
        }
        return pid
    }

    @Test func aHelperIsBoundedByOneDeadlineEvenWhenAChildHoldsThePipeOpen() async throws {
        let supervisor = try supervisor()
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = ContinuousClock()
        var output: String?
        let elapsed = try await clock.measure {
            output = try await supervisor.captureHelper(
                fake, ["--probe-hold-pipe"], environment: ["LOOM_FAKE_PIDFILE": file.path], timeout: 0.5
            )
        }
        // The leader exited at once; a leftover child that keeps the pipe open
        // must not stretch the call (it took 4 s before) and must not survive.
        #expect(output == "")
        #expect(elapsed < .seconds(1.5), "took \(elapsed)")
        let child = try #require(await readPID(file))
        #expect(try await SessionRuntimeRig.waitUntil(3) { try !alive(child) })
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// A helper's wait (sleeps and polls until the child exits) runs on a thread of its own. More slow helpers than the
    /// cooperative pool has threads must leave it free: on the pool they held every thread, and all other async work stood
    /// still until they ended (in the full test run, every test of the process at once).
    @Test func slowHelpersLeaveTheCooperativePoolFree() async throws {
        let supervisor = try supervisor()
        let clock = ContinuousClock()
        let start = clock.now
        let hop = try await withThrowingTaskGroup(of: Duration?.self) { group in
            for _ in 0..<(ProcessInfo.processInfo.activeProcessorCount + 2) {
                group.addTask {
                    _ = try await supervisor.captureHelper("/bin/sleep", ["3"], environment: [:], timeout: 10)
                    return nil
                }
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(200))
                return clock.now - start
            }
            var hop: Duration?
            for try await value in group where value != nil { hop = value }
            return hop
        }
        let waited = try #require(hop)
        #expect(waited < .seconds(1.5), "an unrelated task resumed after \(waited), behind the helpers")
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func aSlowHelperTimesOutAndIsKilled() async throws {
        let supervisor = try supervisor()
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = ContinuousClock()
        var failure: (any Error)?
        let elapsed = await clock.measure {
            do {
                _ = try await supervisor.captureHelper(
                    fake, ["--probe-slow"], environment: ["LOOM_FAKE_PIDFILE": file.path], timeout: 0.4
                )
            } catch { failure = error }
        }
        #expect(failure != nil)
        #expect(elapsed < .seconds(2))
        let pid = try #require(await readPID(file))
        #expect(try await SessionRuntimeRig.waitUntil(3) { try !alive(pid) })
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func excessOutputStopsTheHelperAtTheQuota() async throws {
        let supervisor = try supervisor()
        var failure: (any Error)?
        do { _ = try await supervisor.captureHelper(fake, ["--probe-flood"], environment: [:], timeout: 10) }
        catch { failure = error }
        #expect(failure.map { String(describing: $0) }?.contains("exceeded") == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func aSuccessfulQuitLeavesNoHelperBehind() async throws {
        let supervisor = try supervisor()
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let probe = Task {
            try await supervisor.captureHelper(
                fake, ["--probe-slow"], environment: ["LOOM_FAKE_PIDFILE": file.path], timeout: 30
            )
        }
        let pid = try #require(await readPID(file))
        #expect(try alive(pid))
        let report = await supervisor.shutdown()
        #expect(report.succeeded)
        #expect(try await SessionRuntimeRig.waitUntil(3) { try !alive(pid) })
        await #expect(throws: (any Error).self) { _ = try await probe.value }
    }

    // MARK: Codex profile precedence

    private func toolchain(
        override: URL?, terminalHome: String?
    ) async throws -> ProviderToolchain {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-bin-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("codex"), withDestinationURL: URL(fileURLWithPath: fake)
        )
        var environment = ["PATH": folder.path]
        if let terminalHome { environment["CODEX_HOME"] = terminalHome }
        let resolved = LaunchEnvironment.Resolution(environment: environment)
        let toolchains = SystemProviderToolchains(
            supervisor: try supervisor(), origin: .development, codexHome: override,
            environmentSource: { resolved }
        )
        return try await toolchains.toolchain(for: .codex)
    }

    @Test func codexHomePrefersTheOverrideThenTheTerminalEnvironmentThenTheDefault() async throws {
        let terminal = "/tmp/loom-terminal-codex-home"
        let override = URL(fileURLWithPath: "/tmp/loom-override-codex-home")
        let withOverride = try await toolchain(override: override, terminalHome: terminal)
        #expect(withOverride.profileDirectory == override)
        // The probe itself ran with the chosen profile.
        #expect(withOverride.capabilities.version.contains("codex_home=\(override.path)"))

        let fromTerminal = try await toolchain(override: nil, terminalHome: terminal)
        #expect(fromTerminal.profileDirectory?.path == terminal)
        #expect(fromTerminal.capabilities.version.contains("codex_home=\(terminal)"))

        let fallback = try await toolchain(override: nil, terminalHome: nil)
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        #expect(fallback.profileDirectory?.path == expected)
    }
}
