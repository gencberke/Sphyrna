import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomChatTestRigs

/// V16 smoke test against the user's real `claude` (Haiku, at most four turns): argv, Ready, delivery, a request that is
/// interrupted (not a failure), Stop in the verified order, and a resume. Runs only when `LOOM_V16_REAL_CLAUDE=1`, with
/// `LOOM_V16_CLAUDE_CONFIG` (an isolated, logged-in profile) and `LOOM_V16_WORK_DIR` (outside HOME, trusted in that
/// profile). Prints phases and counts only: no content, no account data.
@Suite(.serialized, .timeLimit(.minutes(5)),
       .enabled(if: ProcessInfo.processInfo.environment["LOOM_V16_REAL_CLAUDE"] == "1"))
struct RealClaudeSmokeTests {
    private static func capture(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> String {
        try await runToEnd(executable, arguments, environment: environment).outputText
    }

    private func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func log(_ line: String) { print("[v16-real] \(line)") }

    @Test func aRealClaudeSessionStartsAnswersIsInterruptedStopsAndResumes() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = URL(fileURLWithPath: try #require(env["LOOM_V16_CLAUDE_CONFIG"]), isDirectory: true)
        let work = try #require(env["LOOM_V16_WORK_DIR"])
        #expect(!work.hasPrefix(NSHomeDirectory()))
        let claude = env["LOOM_V16_CLAUDE"] ?? "/opt/homebrew/bin/claude"
        let child = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
                     "CLAUDE_CONFIG_DIR": config.path]
        // As the app's launch environment does (`LaunchEnvironment`): the CLI finds its login by USER.
        var launchEnvironment = ["PATH": child["PATH"]!, "HOME": NSHomeDirectory(), "USER": NSUserName(),
                                 "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8"]
        launchEnvironment["TMPDIR"] = env["TMPDIR"]
        let toolEnvironment = launchEnvironment
        let version = try await Self.capture(claude, ["--version"], environment: child)
        let help = try await Self.capture(claude, ["--help"], environment: child)
        let capabilities = ProviderCapabilities(version: version.trimmingCharacters(in: .whitespacesAndNewlines), help: help)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-v16-real-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketDirectory = URL(fileURLWithPath: "/tmp/lv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer {
            RunScopeLauncher.removeOwnedBundle(in: root)
            try? FileManager.default.removeItem(at: socketDirectory)
            try? FileManager.default.removeItem(at: root)
        }
        let binaries = Bundle(for: RealAnchor.self).bundleURL.deletingLastPathComponent()
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let bundle = try RunScopeLauncher.assembleOwnedBundle(executable: binaries.appendingPathComponent("loom-run-host"), in: root)
        let supervisor = try await ProcessSupervisor.restoring(
            catalog: catalog,
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("rs")))
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: { provider in
                    ProviderToolchain(provider: provider, executable: claude, capabilities: capabilities,
                                      environment: toolEnvironment,
                                      profileDirectory: config, extraArguments: [])
                },
                hookHelperPath: binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: work, idlePolicy: SessionIdlePolicy(),
                codexIdentityTimeout: 3, hookSilenceGrace: 10, catalogBackupDelay: nil))
        try await runtime.start()
        let id = UUID()
        let driver = ChatSessionDriver(sessionID: id, runtime: runtime, readyTimeout: .seconds(30))

        // Turn 1: start (argv, Ready from `initialize`), a short answer, delivery read, context window.
        let started = ProcessInfo.processInfo.systemUptime
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(
            firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "default", model: "haiku")))
        log("ready after \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started)) s, mode \(await driver.snapshot().permissionMode ?? "-")")
        #expect(await driver.currentPhase == .ready)
        guard case let .sent(firstID) = try await driver.send("Reply with the single word: pong") else {
            Issue.record("not sent")
            return
        }
        #expect(await waitUntil(90) { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        var snapshot = await driver.snapshot()
        log("turn 1: \(snapshot.model.turns.map { "\($0.status)" }), delivery \(String(describing: snapshot.model.entry(id: firstID).map { if case let .user(p) = $0.body { "\(p.delivery)" } else { "-" } })), windows \(snapshot.contextWindows.values.sorted()), drift \(snapshot.drift.count)")
        #expect(snapshot.model.turns.last?.status == .succeeded)

        // Turn 2: a Bash call asks for approval (default mode); the driver never answers it; an interrupt ends the turn
        // and is not a failure.
        try await driver.send("Use the Bash tool to run exactly: sleep 30. Do nothing else.")
        let asked = await waitUntil(90) { await driver.currentPhase == .needsYou }
        log("turn 2: needs you \(asked), requests \(await driver.snapshot().requests.map { "\($0.kind)" })")
        try await Task.sleep(for: .seconds(2))
        #expect(await driver.snapshot().requests.count == (asked ? 1 : 0))
        await driver.interrupt()
        #expect(await waitUntil(30) { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        snapshot = await driver.snapshot()
        log("turn 2 ended: \(snapshot.model.turns.last.map { "\($0.status)" } ?? "-"), requests \(snapshot.requests.count), hub \(String(describing: await supervisor.events.snapshot().sessions[id]?.status?.activity))")
        // 2.1.300 may run `sleep` in `default` mode without asking (run 2 of the ledger): then the turn simply ends.
        #expect(snapshot.model.turns.last?.status == (asked ? .interrupted : .succeeded))

        // Turn 3: Stop during a running turn: interrupt, result, stdin, exit; no signal.
        try await driver.send("Count from 1 to 300, one number per line, nothing else.")
        #expect(await waitUntil(60) { await driver.snapshot().model.entries.contains {
            if case let .assistantText(text) = $0.body { !text.text.isEmpty } else { false } } })
        let report = try await driver.stop()
        log("turn 3 stop: succeeded \(report.succeeded), signals \(report.signals.count), \(String(format: "%.2f", report.elapsedSeconds)) s, turn \(await driver.snapshot().model.turns.last.map { "\($0.status)" } ?? "-")")
        #expect(report.succeeded && report.signals.isEmpty)

        // Turn 4: a send resumes the stopped session with the stored mode and model.
        try await driver.send("Reply with the single word: again")
        #expect(await waitUntil(90) { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        snapshot = await driver.snapshot()
        log("turn 4: \(snapshot.model.turns.last.map { "\($0.status)" } ?? "-"), choices \(snapshot.choices), drift \(snapshot.drift)")
        #expect(snapshot.model.turns.last?.status == .succeeded)
        #expect((await runtime.shutdown()).succeeded)
    }
}

private final class RealAnchor: NSObject {}
