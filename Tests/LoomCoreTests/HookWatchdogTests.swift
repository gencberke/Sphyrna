import Foundation
import Synchronization
import Testing
@testable import LoomCore

/// H1-B items 5 and 6: Loom notices that Claude runs but no hook reaches it (without a false alarm
/// for a Claude that is still at a first-run question), and a catalog that fails does not stop a
/// session's state from being tracked or a stop from being recorded.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct HookWatchdogTests {
    /// A hook command that forwards to the real `loom-hook` only while a flag file exists; otherwise
    /// it swallows the event like a Claude whose hooks do not reach Loom.
    private final class SwitchableHook {
        let folder: URL
        var script: String { folder.appendingPathComponent("hook.sh").path }
        var flag: String { folder.appendingPathComponent("deliver").path }
        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("loom-hookswitch-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let real = RuntimeFixture.binaries.appendingPathComponent("loom-hook").path
            let text = "#!/bin/sh\nif [ -f \"\(flag)\" ]; then exec \"\(real)\" \"$@\"; fi\ncat > /dev/null\nexit 0\n"
            try text.write(toFile: script, atomically: true, encoding: .utf8)
            chmod(script, 0o755)
        }
        func deliver(_ on: Bool) {
            if on { FileManager.default.createFile(atPath: flag, contents: Data()) }
            else { try? FileManager.default.removeItem(atPath: flag) }
        }
        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    private func issue(_ context: RuntimeContext, _ id: UUID) async -> String? {
        await context.events.snapshot().sessions[id]?.issue
    }

    // MARK: Watchdog

    @Test func aBusyClaudeWithNoHookEventPublishesTheIssueAndTheFirstEventClearsIt() async throws {
        let hook = try SwitchableHook()
        let context = try await SessionRuntimeTests.makeContext(hookHelperPath: hook.script, hookSilenceGrace: 0.3)
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeTests.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        // A turn runs (the registry says busy) and no hook ever arrives.
        try await screen.send("/work 2500")
        #expect(await SessionRuntimeTests.waitUntil(10) { await issue(context, launch.sessionID) == ClaudeSessionAdapter.hookSilenceIssue })
        #expect(await context.runtime.harnesses.claude.adapter.silenceIssueRuns() == [launch.runID])
        #expect(DiagnosticJournal.forDataRoot(context.catalog.dataRoot).lines().contains { $0.contains("hook_silence") })

        // Hooks start working: the first event ends the watchdog and takes the issue back.
        hook.deliver(true)
        try await screen.send("hello again")
        #expect(await screen.contains("echo: hello again", timeout: 10))
        #expect(await SessionRuntimeTests.waitUntil(4) { await issue(context, launch.sessionID) == nil })
        #expect(await context.runtime.harnesses.claude.adapter.silenceIssueRuns().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aClaudeAtAFirstRunQuestionWithNoHooksAndNoTurnIsNotReported() async throws {
        let hook = try SwitchableHook()
        let context = try await SessionRuntimeTests.makeContext(hookHelperPath: hook.script, hookSilenceGrace: 0.2)
        defer { context.cleanup() }
        // Started, registry "idle", no hook (folder trust and similar questions run no hooks): quiet.
        let (launch, screen) = try await SessionRuntimeTests.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(await issue(context, launch.sessionID) == nil)
        #expect(await context.runtime.harnesses.claude.adapter.silenceIssueRuns().isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func workingHooksNeverRaiseTheIssueEvenWithAShortGrace() async throws {
        let context = try await SessionRuntimeTests.makeContext(hookSilenceGrace: 0.05)
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeTests.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        try await screen.send("/work 800")
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(await issue(context, launch.sessionID) == nil)
        #expect(await context.runtime.harnesses.claude.adapter.silenceIssueRuns().isEmpty)
        #expect(await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    // MARK: Catalog write failures

    @Test func aFailingUseStampDoesNotBlockTheTurnsStateAndShowsNoIssue() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeTests.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        // The catalog row is gone while the run lives: `markUsed` now throws for this session.
        #expect(try await context.catalog.deleteSessionRows(sessionID: launch.sessionID))
        try await screen.send("/work 1500")
        #expect(await SessionRuntimeTests.waitUntil(4) {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .working
        })
        #expect(await issue(context, launch.sessionID) == nil)    // not "A Claude event could not be processed"
        #expect(await SessionRuntimeTests.waitUntil(4) {
            await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete
        })
        _ = try? await context.runtime.shutdown()
    }

    @Test func aRunEndThatFailsTwiceIsRecordedByTheThirdAttemptAndTheStopIsVerified() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        await context.supervisor.setCatalogFinishRetryDelaysForTesting([.milliseconds(5), .milliseconds(5)])
        let (launch, screen) = try await SessionRuntimeTests.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        await context.catalog.setFinishRunFailpointForTesting { attempt in
            if attempt <= 2 { throw SessionCatalogError.sqlite(operation: "finish run", code: 5, message: "database is locked") }
        }
        let report = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(report.succeeded, "\(report.errors)")
        #expect(try await context.catalog.runs().first { $0.id == launch.runID }?.endedAt != nil)
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun == nil)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aRunEndThatKeepsFailingIsReportedUnverifiedAndAStopAgainRecordsIt() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        await context.supervisor.setCatalogFinishRetryDelaysForTesting([.milliseconds(5), .milliseconds(5)])
        let (launch, screen) = try await SessionRuntimeTests.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        await context.catalog.setFinishRunFailpointForTesting { attempt in
            if attempt <= 3 { throw SessionCatalogError.sqlite(operation: "finish run", code: 5, message: "database is locked") }
        }
        let first = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(!first.succeeded)
        #expect(first.errors.contains { $0.contains("finish run") })
        #expect(try await context.catalog.runs().first { $0.id == launch.runID }?.endedAt == nil)

        let second = try await context.runtime.stopConversation(sessionID: launch.sessionID)
        #expect(second.succeeded, "\(second.errors)")
        #expect(try await context.catalog.runs().first { $0.id == launch.runID }?.endedAt != nil)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
