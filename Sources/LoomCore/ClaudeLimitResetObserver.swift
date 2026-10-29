import Foundation
import Synchronization

/// A verified signal whose observation can still be revoked before the UI admits it.
public struct ClaudeLimitResetDelivery: Sendable {
    public let signal: ClaudeLimitResetSignal
    public let isCurrent: @Sendable () -> Bool
}

public struct ClaudeLimitResetCallbacks: Sendable {
    public let enabled: @Sendable () async -> Bool
    public let receive: @Sendable (ClaudeLimitResetDelivery) async -> Void
    public init(enabled: @escaping @Sendable () async -> Bool = { true },
                receive: @escaping @Sendable (ClaudeLimitResetDelivery) async -> Void) {
        self.enabled = enabled; self.receive = receive
    }
}

/// Ordered applied hooks identify the prompt; synchronous ingress invalidates a
/// pending read before the next hook reaches the actor. No timer or provider call.
actor ClaudeLimitResetObserver {
    struct Run: Equatable, Sendable {
        let sessionID: UUID
        let nativeSessionID: String
        let runID: UUID
        let startedAt: Date
        let configDirectory: URL
        let workingDirectory: String
    }

    private struct Arrival: Sendable { var revision: UInt64; var sessionID: UUID? }
    private struct ArrivalState: Sendable { var next: UInt64 = 0; var runs: [UUID: Arrival] = [:] }
    private nonisolated let arrivals = Mutex(ArrivalState())
    private struct Prompt { let run: Run; let id: UUID }
    private struct Pending { let token: UUID; let task: Task<Void, Never> }
    private var prompts: [UUID: Prompt] = [:]
    private var pending: [UUID: Pending] = [:]
    private let read: @Sendable (ClaudeLimitResetContext) async -> ClaudeLimitResetSignal?
    private let current: @Sendable (ClaudeLimitResetContext) async -> Bool
    private let enabled: @Sendable () async -> Bool
    private let emit: @Sendable (ClaudeLimitResetDelivery) async -> Void

    init(read: @escaping @Sendable (ClaudeLimitResetContext) async -> ClaudeLimitResetSignal? = { await ClaudeLimitResetSignalReader.waitForSignal($0) },
         enabled: @escaping @Sendable () async -> Bool = { true },
         current: @escaping @Sendable (ClaudeLimitResetContext) async -> Bool,
         emit: @escaping @Sendable (ClaudeLimitResetDelivery) async -> Void) {
        self.read = read; self.enabled = enabled; self.current = current; self.emit = emit
    }

    nonisolated func arrived(runID: UUID) -> UInt64? {
        arrivals.withLock { state in
            guard state.next < UInt64.max, state.runs[runID] != nil || state.runs.count < 256 else { return nil }
            state.next += 1
            state.runs[runID] = Arrival(revision: state.next, sessionID: state.runs[runID]?.sessionID)
            return state.next
        }
    }

    private nonisolated func matches(runID: UUID, revision: UInt64) -> Bool {
        arrivals.withLock { $0.runs[runID]?.revision == revision }
    }

    nonisolated func discard(runID: UUID, revision: UInt64?) {
        guard let revision else { return }
        arrivals.withLock { state in
            if state.runs[runID]?.revision == revision { state.runs[runID] = nil }
        }
    }

    nonisolated func invalidate(sessionID: UUID) {
        arrivals.withLock { state in
            for id in Array(state.runs.keys) where state.runs[id]?.sessionID == sessionID { state.runs[id] = nil }
        }
    }

    nonisolated func invalidateAll() { arrivals.withLock { $0.runs.removeAll() } }

    func forget(runID: UUID) async {
        arrivals.withLock { $0.runs[runID] = nil }
        prompts[runID] = nil
        let task = pending.removeValue(forKey: runID)?.task
        task?.cancel()
        await task?.value
    }

    func forget(sessionID: UUID) async {
        invalidate(sessionID: sessionID)
        for id in prompts.keys.filter({ prompts[$0]?.run.sessionID == sessionID }) { await forget(runID: id) }
    }

    func cancelAll() async {
        invalidateAll()
        for id in Array(prompts.keys) { await forget(runID: id) }
    }

    func applied(_ event: ClaudeHookEvent, run: Run, revision: UInt64, failedAt: Date) {
        guard event.agentID == nil, event.providerSessionID == run.nativeSessionID else { return }
        arrivals.withLock { state in
            if state.runs[run.runID] != nil { state.runs[run.runID]?.sessionID = run.sessionID }
        }
        switch event.kind {
        case .sessionStart, .sessionEnd:
            prompts[run.runID] = nil
            pending.removeValue(forKey: run.runID)?.task.cancel()
        case .userPromptSubmit:
            pending.removeValue(forKey: run.runID)?.task.cancel()
            if let text = event.promptID, let id = UUID(uuidString: text),
               prompts[run.runID] != nil || prompts.count < 256 {
                prompts[run.runID] = Prompt(run: run, id: id)
            } else { prompts[run.runID] = nil }
        case .stopFailure:
            guard let prompt = prompts[run.runID], prompt.run == run,
                  event.promptID == nil || event.promptID.flatMap(UUID.init(uuidString:)) == prompt.id,
                  matches(runID: run.runID, revision: revision), pending.count < 32 else { return }
            pending.removeValue(forKey: run.runID)?.task.cancel()
            let context = ClaudeLimitResetContext(sessionID: run.sessionID, nativeSessionID: run.nativeSessionID,
                runID: run.runID, promptID: prompt.id, runStartedAt: run.startedAt, failedAt: failedAt,
                configDirectory: run.configDirectory, workingDirectory: run.workingDirectory)
            let token = UUID()
            let task = Task { [weak self, read, current, enabled] in
                guard await enabled(), !Task.isCancelled,
                      self?.matches(runID: run.runID, revision: revision) == true else {
                    await self?.finish(runID: run.runID, token: token)
                    return
                }
                let signal = await read(context)
                guard !Task.isCancelled, let signal, await current(context) else {
                    await self?.finish(runID: run.runID, token: token)
                    return
                }
                await self?.deliver(signal, context: context, token: token, revision: revision)
            }
            pending[run.runID] = Pending(token: token, task: task)
        default: break
        }
    }

    private func deliver(_ signal: ClaudeLimitResetSignal, context: ClaudeLimitResetContext, token: UUID, revision: UInt64) async {
        defer { finish(runID: context.runID, token: token) }
        guard pending[context.runID]?.token == token,
              prompts[context.runID]?.id == context.promptID,
              signal.sessionID == context.sessionID, signal.runID == context.runID,
              signal.nativeSessionID == context.nativeSessionID, signal.promptID == context.promptID,
              matches(runID: context.runID, revision: revision) else { return }
        await emit(ClaudeLimitResetDelivery(signal: signal, isCurrent: { [weak self] in
            self?.matches(runID: context.runID, revision: revision) == true
        }))
    }

    private func finish(runID: UUID, token: UUID) {
        if pending[runID]?.token == token { pending[runID] = nil }
    }

    func drain() async {
        for task in pending.values.map(\.task) { await task.value }
    }
}
