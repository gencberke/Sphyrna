import Darwin
import Foundation
import Testing
@testable import LoomCore

/// H1-B item 4: Loom notices a Claude CLI that changed under it (a replaced or rewritten
/// executable, a help text that no longer lists an option) and keeps starting sessions.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CliDriftTests {
    private final class Bin {
        let folder: URL
        var executable: URL { folder.appendingPathComponent("claude") }
        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-cli-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: folder) }

        func script(version: String, help: String) -> String {
            """
            #!/bin/sh
            case "$1" in
              --version) echo "\(version)" ;;
              --help) printf '%s\\n' "\(help)" ;;
            esac
            """
        }

        /// A new file moved over the path: a new inode, like a package manager's update.
        func replace(version: String, help: String) throws {
            let staging = folder.appendingPathComponent("claude.new")
            try script(version: version, help: help).write(to: staging, atomically: false, encoding: .utf8)
            chmod(staging.path, 0o755)
            #expect(rename(staging.path, executable.path) == 0)
        }

        /// The same file rewritten in place: same inode, new content and mtime.
        func rewrite(version: String, help: String) throws {
            let handle = try FileHandle(forWritingTo: executable)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(script(version: version, help: help).utf8))
            try handle.close()
        }
    }

    private static let fullHelp = "--settings <file> --session-id <uuid> --effort <level> --name <name> --plugin-dir <path>"
    private static let driftedHelp = "--config [file] --session [uuid]"

    private func toolchains(_ bin: Bin, counter: Counter) throws -> SystemProviderToolchains {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let environment = LaunchEnvironment.Resolution(environment: ["PATH": "\(bin.folder.path):/usr/bin:/bin"])
        return SystemProviderToolchains(
            supervisor: supervisor, origin: .development,
            environmentSource: { counter.bump(); return environment }
        )
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private final class ChangingEnvironment: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: String]
        init(_ value: [String: String]) { self.value = value }
        func replace(_ value: [String: String]) { lock.withLock { self.value = value } }
        func read() -> LaunchEnvironment.Resolution { lock.withLock { LaunchEnvironment.Resolution(environment: value) } }
    }

    @Test func aResolutionStartedBeforePathRefreshCannotRestoreTheOldToolchainCache() async throws {
        let oldBin = try Bin(), newBin = try Bin()
        try newBin.replace(version: "2.1.300", help: Self.fullHelp)
        let hold = oldBin.folder.appendingPathComponent("hold"), ready = oldBin.folder.appendingPathComponent("ready")
        try Data().write(to: hold)
        defer { try? FileManager.default.removeItem(at: hold) }
        try """
        #!/bin/sh
        case "$1" in
          --version)
            : > "$LOOM_TEST_READY"
            while [ -f "$LOOM_TEST_HOLD" ]; do /bin/sleep 0.01; done
            echo '2.1.299' ;;
          --help) echo '--model' ;;
        esac
        """.write(to: oldBin.executable, atomically: true, encoding: .utf8)
        chmod(oldBin.executable.path, 0o755)
        let environment = ChangingEnvironment(["PATH": oldBin.folder.path, "LOOM_TEST_READY": ready.path, "LOOM_TEST_HOLD": hold.path])
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let resolver = SystemProviderToolchains(supervisor: supervisor, origin: .development, environmentSource: { environment.read() })
        let earlier = Task { try await resolver.toolchain(for: .claude) }
        let started = try await SessionRuntimeTests.waitUntil(3) { FileManager.default.fileExists(atPath: ready.path) }
        #expect(started)
        environment.replace(["PATH": newBin.folder.path])
        _ = try await resolver.refreshTerminalEnvironment()
        try FileManager.default.removeItem(at: hold)
        _ = try await earlier.value
        let next = try await resolver.toolchain(for: .claude)
        #expect(next.executable == newBin.executable.path, "The earlier probe cannot repopulate the invalidated cache")
        #expect(next.capabilities.version == "2.1.300")
        #expect((await supervisor.shutdown()).succeeded)
    }

    // MARK: System resolver

    @Test func theCachedToolchainIsKeptWhileTheExecutableIsTheSameFile() async throws {
        let bin = try Bin()
        try bin.replace(version: "1.0.0", help: Self.fullHelp)
        let counter = Counter()
        let resolver = try toolchains(bin, counter: counter)
        let first = try await resolver.toolchain(for: .claude)
        let second = try await resolver.toolchain(for: .claude)
        #expect(first.capabilities.version == "1.0.0" && second.capabilities.version == "1.0.0")
        #expect(await resolver.resolutionCount == 1)
        #expect(first.executableStamp != nil)
    }

    @Test func aReplacedExecutableIsResolvedAgainWithItsNewHelpText() async throws {
        let bin = try Bin()
        try bin.replace(version: "1.0.0", help: Self.fullHelp)
        let resolver = try toolchains(bin, counter: Counter())
        let old = try await resolver.toolchain(for: .claude)
        #expect(old.capabilities.supportsSettings && old.capabilities.supportsSessionID)

        try bin.replace(version: "2.0.0", help: Self.driftedHelp)
        let updated = try await resolver.toolchain(for: .claude)
        #expect(updated.capabilities.version == "2.0.0")
        #expect(!updated.capabilities.supportsSettings && !updated.capabilities.supportsSessionID)
        #expect(await resolver.resolutionCount == 2)
        // And the launch profile built from it still starts (the drift is reported, not refused).
        let profile = try ProviderLaunchProfile.claude(
            capabilities: updated.capabilities, config: URL(fileURLWithPath: "/cfg"), sessionID: UUID(), environment: [:])
        #expect(profile.arguments.contains("--settings"))
    }

    @Test func anExecutableRewrittenInPlaceIsResolvedAgain() async throws {
        let bin = try Bin()
        try bin.replace(version: "1.0.0", help: Self.fullHelp)
        let resolver = try toolchains(bin, counter: Counter())
        _ = try await resolver.toolchain(for: .claude)
        try await Task.sleep(for: .milliseconds(20))
        try bin.rewrite(version: "1.0.1 patched", help: Self.fullHelp)
        #expect(try await resolver.toolchain(for: .claude).capabilities.version == "1.0.1 patched")
        #expect(await resolver.resolutionCount == 2)
    }

    @Test func aRemovedExecutableFailsCleanlyAndAReinstallIsFoundThroughAFreshEnvironment() async throws {
        let bin = try Bin()
        try bin.replace(version: "1.0.0", help: Self.fullHelp)
        let counter = Counter()
        let resolver = try toolchains(bin, counter: counter)
        _ = try await resolver.toolchain(for: .claude)
        #expect(counter.count == 1)
        try FileManager.default.removeItem(at: bin.executable)
        await #expect(throws: ProviderToolchainError.self) { _ = try await resolver.toolchain(for: .claude) }
        #expect(counter.count == 2)                       // the terminal environment was read again
        try bin.replace(version: "3.0.0", help: Self.fullHelp)
        #expect(try await resolver.toolchain(for: .claude).capabilities.version == "3.0.0")
    }

    @Test func invalidatingForgetsTheCachedToolchain() async throws {
        let bin = try Bin()
        try bin.replace(version: "1.0.0", help: Self.fullHelp)
        let resolver = try toolchains(bin, counter: Counter())
        _ = try await resolver.toolchain(for: .claude)
        await resolver.invalidate(.claude)
        _ = try await resolver.toolchain(for: .claude)
        #expect(await resolver.resolutionCount == 2)
    }

    // MARK: Runtime

    private func copiedFake(into folder: URL) throws -> String {
        let source = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path
        let target = folder.appendingPathComponent("claude")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(atPath: source, toPath: target.path)
        return target.path
    }

    @Test func theRuntimeReadsTheCliAgainBeforeALaunchAfterItsExecutableChanged() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-cli-rt-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try copiedFake(into: folder)
        let context = try await SessionRuntimeTests.makeContext(executableOverride: executable)
        defer { context.cleanup() }

        _ = try await context.runtime.toolchain(for: .claude)
        _ = try await context.runtime.toolchain(for: .claude)
        #expect(context.toolchainSwitch.calls == 1)                       // unchanged file: cached

        _ = try copiedFake(into: folder)                                  // the CLI was updated
        _ = try await context.runtime.toolchain(for: .claude)
        #expect(context.toolchainSwitch.calls == 2)
        _ = try await context.runtime.toolchain(for: .claude)
        #expect(context.toolchainSwitch.calls == 2)

        await context.runtime.invalidateToolchain(.claude)                // a launch failed
        _ = try await context.runtime.toolchain(for: .claude)
        #expect(context.toolchainSwitch.calls == 3)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aFailedLaunchMakesTheNextStartReadTheCliAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-cli-rt-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try copiedFake(into: folder)
        let context = try await SessionRuntimeTests.makeContext(executableOverride: executable)
        defer { context.cleanup() }
        _ = try await context.runtime.toolchain(for: .claude)
        #expect(context.toolchainSwitch.calls == 1)
        chmod(executable, 0o600)                                          // no longer launchable
        await #expect(throws: (any Error).self) {
            _ = try await context.runtime.startConversation(provider: .claude, projectID: nil)
        }
        chmod(executable, 0o755)
        let (_, screen) = try await SessionRuntimeTests.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        #expect(context.toolchainSwitch.calls >= 2)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aHelpTextWithoutTheRequiredOptionsStillStartsTheSessionAndIsJournaledOnce() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let drifted = ProviderToolchain(
            provider: .claude, executable: "/bin/echo",
            capabilities: ProviderCapabilities(version: "9.9.9 drifted", help: Self.driftedHelp),
            environment: ["PATH": "/usr/bin:/bin"], profileDirectory: nil)
        let hooks = try await context.runtime.ensureHooksForTesting()
        for _ in 0..<2 {
            let profile = try await context.runtime.claudeProfile(
                route: .new(UUID()), toolchain: drifted, sessionID: UUID(), hooks: hooks)
            #expect(profile.arguments.contains("--settings") && profile.arguments.contains("--session-id"))
        }
        let warnings = DiagnosticJournal.forDataRoot(context.catalog.dataRoot).lines()
            .filter { $0.contains("cli_compat_warning") && $0.contains("9.9.9 drifted") }
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("--settings") && warnings[0].contains("--session-id"))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func theCliVersionAndDetectedOptionsAreJournaledWhenItIsFirstResolved() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        _ = try await context.runtime.toolchain(for: .claude)
        let line = try #require(DiagnosticJournal.forDataRoot(context.catalog.dataRoot).lines().first { $0.contains("\"claude_cli\"") })
        #expect(line.contains("fake 1") && line.contains("--settings") && line.contains("--plugin-dir"))
        #expect((await context.runtime.shutdown()).succeeded)
    }
}

extension SessionRuntime {
    func ensureHooksForTesting() throws -> ClaudeHookLaunchConfiguration { try ensureHooks() }
}
