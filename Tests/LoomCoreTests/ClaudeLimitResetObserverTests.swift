import Foundation
import Testing
@testable import LoomCore

@Suite struct ClaudeLimitResetObserverTests {
    private actor Sink {
        var values: [ClaudeLimitResetDelivery] = []
        func append(_ value: ClaudeLimitResetDelivery) { values.append(value) }
    }
    private actor HeldReader {
        var continuation: CheckedContinuation<Void, Never>?
        var entered = false
        func read(_ context: ClaudeLimitResetContext) async -> ClaudeLimitResetSignal? {
            entered = true
            await withCheckedContinuation { continuation = $0 }
            return ClaudeLimitResetSignal(sessionID: context.sessionID, nativeSessionID: context.nativeSessionID,
                runID: context.runID, promptID: context.promptID, windowID: "five_hour",
                resetsAt: context.failedAt.addingTimeInterval(3_600))
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func event(_ name: String, run: ClaudeLimitResetObserver.Run, prompt: UUID? = nil,
                       agent: String? = nil) throws -> ClaudeHookEvent {
        var fields: [String: Any] = ["hook_event_name": name, "session_id": run.nativeSessionID]
        if let prompt { fields["prompt_id"] = prompt.uuidString }
        if let agent { fields["agent_id"] = agent }
        return try ClaudeHookEvent(payload: JSONSerialization.data(withJSONObject: fields))
    }

    private func run() -> ClaudeLimitResetObserver.Run {
        .init(sessionID: UUID(), nativeSessionID: UUID().uuidString.lowercased(), runID: UUID(),
              startedAt: Date().addingTimeInterval(-10), configDirectory: URL(fileURLWithPath: "/tmp/loom-limit-profile"),
              workingDirectory: "/tmp/loom-limit-work")
    }

    private func started(_ observer: ClaudeLimitResetObserver, run: ClaudeLimitResetObserver.Run,
                         prompt: UUID) async throws {
        let revision = try #require(observer.arrived(runID: run.runID))
        await observer.applied(try event("UserPromptSubmit", run: run, prompt: prompt), run: run,
                               revision: revision, failedAt: Date())
    }

    private func waitForReader(_ reader: HeldReader) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await reader.entered), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await reader.entered)
    }

    @Test func anAppliedMainFailureEmitsOnlyItsExactCurrentPrompt() async throws {
        let run = run(), prompt = UUID(), sink = Sink(), reader = HeldReader()
        let observer = ClaudeLimitResetObserver(read: { await reader.read($0) }, current: { _ in true }, emit: { await sink.append($0) })
        try await started(observer, run: run, prompt: prompt)
        let revision = try #require(observer.arrived(runID: run.runID))
        await observer.applied(try event("StopFailure", run: run, prompt: prompt), run: run,
                               revision: revision, failedAt: Date())
        try await waitForReader(reader)
        await reader.release(); await observer.drain()
        let values = await sink.values
        #expect(values.count == 1)
        #expect(values.first?.signal.promptID == prompt && values.first?.isCurrent() == true)
        observer.invalidate(sessionID: run.sessionID)
        _ = observer.arrived(runID: run.runID)
        #expect(values.first?.isCurrent() == false, "a late hook cannot resurrect a deleted delivery")
    }

    @Test func ingressRevokesAReadBeforeTheNextHookIsApplied() async throws {
        let run = run(), sink = Sink(), reader = HeldReader()
        let observer = ClaudeLimitResetObserver(read: { await reader.read($0) }, current: { _ in true }, emit: { await sink.append($0) })
        try await started(observer, run: run, prompt: UUID())
        let revision = try #require(observer.arrived(runID: run.runID))
        await observer.applied(try event("StopFailure", run: run), run: run, revision: revision, failedAt: Date())
        try await waitForReader(reader)
        _ = observer.arrived(runID: run.runID)
        await reader.release(); await observer.drain()
        #expect(await sink.values.isEmpty)
    }

    @Test func deletionProfileChangeAndRejectedCurrentStateSuppressLateReads() async throws {
        for change in 0..<3 {
            let run = run(), sink = Sink(), reader = HeldReader()
            let observer = ClaudeLimitResetObserver(read: { await reader.read($0) }, current: { _ in change != 2 }, emit: { await sink.append($0) })
            try await started(observer, run: run, prompt: UUID())
            let revision = try #require(observer.arrived(runID: run.runID))
            await observer.applied(try event("StopFailure", run: run), run: run, revision: revision, failedAt: Date())
            try await waitForReader(reader)
            if change == 0 { observer.invalidate(sessionID: run.sessionID) }
            if change == 1 { observer.invalidateAll() }
            await reader.release(); await observer.drain()
            #expect(await sink.values.isEmpty)
        }
    }

    @Test func anUnmatchedPromptOrSubagentNeverStartsATailRead() async throws {
        let run = run(), sink = Sink()
        let observer = ClaudeLimitResetObserver(read: { _ in Issue.record("Unmatched failure read a transcript"); return nil },
                                               current: { _ in true }, emit: { await sink.append($0) })
        try await started(observer, run: run, prompt: UUID())
        for event in [try event("StopFailure", run: run, prompt: UUID()),
                      try event("StopFailure", run: run, agent: "child")] {
            let revision = try #require(observer.arrived(runID: run.runID))
            await observer.applied(event, run: run, revision: revision, failedAt: Date())
        }
        await observer.drain()
        #expect(await sink.values.isEmpty)
    }

    @Test func disabledNotificationsDoNotReadOrWatchTheTranscript() async throws {
        let run = run(), sink = Sink()
        let observer = ClaudeLimitResetObserver(read: { _ in Issue.record("Disabled observer read a transcript"); return nil },
            enabled: { false }, current: { _ in true }, emit: { await sink.append($0) })
        try await started(observer, run: run, prompt: UUID())
        let revision = try #require(observer.arrived(runID: run.runID))
        await observer.applied(try event("StopFailure", run: run), run: run, revision: revision, failedAt: Date())
        await observer.drain()
        #expect(await sink.values.isEmpty)
    }

    @Test func lateRejectedRunsCannotExhaustTheBoundedIngressTable() {
        let observer = ClaudeLimitResetObserver(current: { _ in false }, emit: { _ in })
        for _ in 0..<300 {
            let id = UUID()
            let revision = observer.arrived(runID: id)
            #expect(revision != nil)
            observer.discard(runID: id, revision: revision)
        }
    }
}
