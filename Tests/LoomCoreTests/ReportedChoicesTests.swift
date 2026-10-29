import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

private final class ProbeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// C6a: what the inspector's Overview reads for a terminal-face session (ink's I2c): the live permission mode and effort
/// Claude reports at its hooks, and the CLI's version from the cached probe. The payloads are the S0 recordings.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReportedChoicesTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func event(_ fields: [String: Any]) throws -> ClaudeHookEvent {
        try ClaudeHookEvent(payload: JSONSerialization.data(withJSONObject: fields))
    }

    // MARK: The payload

    @Test func aHookReportsTheModeAndEffortInTheCLIsWordsAndDropsWhatLoomDoesNotKnow() throws {
        let permission = try event(S0Hooks.writePermission)
        #expect(permission.permissionMode == "default" && permission.effort == "high")
        let prompt = try event(S0Hooks.prompt("go"))
        #expect(prompt.permissionMode == "default" && prompt.effort == nil, "2.1.300's prompt carries the mode alone")
        let start = try event(S0Hooks.sessionStart)
        #expect(start.permissionMode == nil && start.effort == nil)

        let ask = try event(S0Hooks.payload("UserPromptSubmit", ["permission_mode": "dontAsk", "effort": ["level": "max"]]))
        #expect(ask.permissionMode == "dontAsk" && ask.effort == "max")
        // A word that is not the CLI's for a mode Loom knows (Loom's own `ask` included), an unknown level and a level
        // that is not where 2.1.300 puts it are not reported.
        for fields: [String: Any] in [
            ["permission_mode": "turbo", "effort": ["level": "extreme"]],
            ["permission_mode": "ask", "effort": "high"],
            ["permission_mode": 3, "effort": ["level": 2]],
        ] {
            let unknown = try event(S0Hooks.payload("PermissionRequest", fields))
            #expect(unknown.permissionMode == nil && unknown.effort == nil, "\(fields)")
        }
    }

    // MARK: The hub

    @Test func theHubKeepsTheLastKnownValuesWhileTheRunLivesAndDropsThemWithIt() async {
        let hub = SessionEventHub()
        let id = UUID(), run = UUID()
        await hub.publish(sessionID: id, change: .reportedChoices(permissionMode: "plan", effort: "low"))
        #expect(await hub.snapshot().sessions[id] == nil, "no run, nothing to report")

        await hub.publish(sessionID: id, change: .runStarted(run))
        await hub.publish(sessionID: id, change: .reportedChoices(permissionMode: "default", effort: nil))
        await hub.publish(sessionID: id, change: .reportedChoices(permissionMode: nil, effort: "high"))
        var state = await hub.snapshot().sessions[id]
        #expect(state?.permissionMode == "default" && state?.effort == "high")
        let base = await hub.snapshot().sequence
        await hub.publish(sessionID: id, change: .reportedChoices(permissionMode: "default", effort: "high"))
        await hub.publish(sessionID: id, change: .reportedChoices(permissionMode: nil, effort: nil))
        #expect(await hub.snapshot().sequence == base, "a report that changes nothing is silent")
        await hub.publish(sessionID: id, change: .reportedChoices(permissionMode: "acceptEdits", effort: nil))
        state = await hub.snapshot().sessions[id]
        #expect(state?.permissionMode == "acceptEdits" && state?.effort == "high")

        await hub.publish(sessionID: id, change: .runEnded(run, .idle))
        state = await hub.snapshot().sessions[id]
        #expect(state?.permissionMode == nil && state?.effort == nil, "the stored choices are the next start's again")
        await hub.publish(sessionID: id, change: .reportedChoices(permissionMode: "plan", effort: "max"))
        state = await hub.snapshot().sessions[id]
        #expect(state?.permissionMode == nil && state?.effort == nil, "a late report of the ended run does not come back")

        let next = UUID()
        await hub.publish(sessionID: id, change: .runStarted(next))
        await hub.publish(sessionID: id, change: .reportedChoices(permissionMode: "plan", effort: "max"))
        await hub.publish(sessionID: id, change: .runDetached(next))
        state = await hub.snapshot().sessions[id]
        #expect(state?.permissionMode == nil && state?.effort == nil)
        await hub.publish(sessionID: id, change: .runStarted(next))
        await hub.publish(sessionID: id, change: .reportedChoices(permissionMode: "plan", effort: "max"))
        await hub.publish(sessionID: id, change: .runStarted(UUID()))
        state = await hub.snapshot().sessions[id]
        #expect(state?.permissionMode == nil && state?.effort == nil, "a new run starts from its launch choices")
    }

    // MARK: Through the real adapter

    private var childPath: String {
        Products.directory
            .appendingPathComponent("loom-test-child").path
    }

    @Test func aTerminalRunsShiftTabShowsAtItsNextHookAndASubagentsModeDoesNot() async throws {
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let session = UUID()
        try await supervisor.createSession(ManagedSession(
            id: session, provider: .claude, providerConversationID: S0Hooks.conversation,
            workingDirectory: FileManager.default.temporaryDirectory.path))
        let launched = try await supervisor.launch(
            sessionID: session, executable: childPath, arguments: ["stubborn"],
            environment: LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: session))
        let run = try #require(launched.session.currentRun?.id)
        let adapter = ClaudeSessionAdapter(supervisor: supervisor)
        @discardableResult
        func deliver(_ fields: [String: Any], _ seconds: Double) async throws -> ClaudeHookDisposition {
            try await adapter.receive(S0Hooks.envelope(fields, session: session, run: run, sentAt: at(seconds)), receivedAt: at(seconds))
        }
        func reported() async -> (String?, String?) {
            let state = await supervisor.events.snapshot().sessions[session]
            return (state?.permissionMode, state?.effort)
        }

        try await deliver(S0Hooks.sessionStart, 0)
        #expect(await reported() == (nil, nil))
        try await deliver(S0Hooks.prompt("go"), 1)
        #expect(await reported() == ("default", nil))
        try await deliver(S0Hooks.writePermission, 2)
        #expect(await reported() == ("default", "high"))
        // Shift+Tab in the terminal, then the next prompt says so; the effort it does not carry stays.
        try await deliver(S0Hooks.payload("UserPromptSubmit", ["permission_mode": "acceptEdits", "prompt": "next"]), 3)
        #expect(await reported() == ("acceptEdits", "high"))
        // A word Loom does not know keeps what it knew.
        try await deliver(S0Hooks.payload("UserPromptSubmit", ["permission_mode": "turbo", "effort": ["level": "extreme"],
                                                               "prompt": "more"]), 4)
        #expect(await reported() == ("acceptEdits", "high"))
        // A subagent's own mode is not the session's.
        let subagent = S0Hooks.subagentBashPermission.merging(
            ["permission_mode": "bypassPermissions", "effort": ["level": "low"]]) { _, new in new }
        let disposition = try await deliver(subagent, 5)
        guard case .applied = disposition else {
            Issue.record("the subagent's request must reach the adapter's publishing: \(disposition)")
            return
        }
        #expect(await reported() == ("acceptEdits", "high"))
        try await deliver(S0Hooks.stopDone.merging(["permission_mode": "plan", "effort": ["level": "max"]]) { _, new in new }, 6)
        #expect(await reported() == ("plan", "max"))

        #expect(try await supervisor.stop(sessionID: session, graceSeconds: 0.05).succeeded)
        #expect(await reported() == (nil, nil))
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }

    // MARK: The CLI's version

    @Test func theCLIsVersionComesFromTheCachedProbeAndAskingStartsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c6a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let probes = ProbeCount()
        let runtime = SessionRuntime(
            supervisor: try ProcessSupervisor(ledger: OwnershipLedger()),
            catalog: try SessionCatalog(url: dir.appendingPathComponent("catalog.sqlite")),
            configuration: SessionRuntimeConfiguration(
                toolchains: { provider in
                    probes.bump()
                    let version = provider == .claude ? "2.1.300 (Claude Code)\n" : "codex-cli 0.48.0"
                    return ProviderToolchain(provider: provider, executable: "/usr/bin/true",
                                             capabilities: ProviderCapabilities(version: version, help: ""), environment: [:])
                },
                hookHelperPath: "/usr/bin/true", socketDirectory: dir, homeDirectory: dir.path, claudeTemporaryRoot: dir,
                forgetters: ConversationForgetters(), claudeEnvironment: [:]
            )
        )
        #expect(await runtime.toolchainVersion(for: .claude) == nil, "nothing resolved yet")
        #expect(probes.count == 0, "asking runs no probe")
        _ = try await runtime.toolchain(for: .claude)
        #expect(await runtime.toolchainVersion(for: .claude) == "2.1.300")
        #expect(await runtime.toolchainVersion(for: .codex) == nil)
        _ = try await runtime.toolchain(for: .codex)
        #expect(await runtime.toolchainVersion(for: .codex) == "0.48.0", "the same accessor answers Codex")
        #expect(probes.count == 2)
        _ = await runtime.shutdown()
    }
}
