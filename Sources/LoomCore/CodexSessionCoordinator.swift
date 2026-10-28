import Foundation

/// A request belongs to one binding and one occurrence, even if the server
/// reuses its JSON-RPC ID after a resolution or a new run.
public struct CodexPendingRequest: Equatable, Sendable {
    public let id = UUID()
    public let request: CodexServerRequest
    public let sequence: UInt64
    public let binding: CodexRunBinding
}

public struct CodexRequestSnapshot: Sendable {
    public let revision: UInt64
    public let pending: [CodexPendingRequest]
}

/// Connects one conversation's app-server stream to its run's supervisor
/// state. It is the product boundary that assigns the new TUI's identity,
/// routes approvals, applies `/new`, and hydrates the last turn after a remote
/// TUI reports idle (remote-originated turns are not broadcast in full).
public actor CodexSessionCoordinator {
    public nonisolated let requests: AsyncStream<CodexRequestSnapshot>

    private let client: CodexAppServerClient
    private let supervisor: ProcessSupervisor
    private let adapter: CodexSessionAdapter
    private let router: CodexSessionRouter
    private let requestContinuation: AsyncStream<CodexRequestSnapshot>.Continuation
    private var consumerTask: Task<Void, Never>?
    private var recordedIssues: [String] = []
    private var pendingRequests: [CodexPendingRequest] = []
    // A local successful write hides the UI request, but only authoritative
    // provider resolution permits the same raw ID to name a new transaction.
    private var answeredRequests: [CodexPendingRequest] = []
    private var requestRevision: UInt64 = 0
    // Only active writes retain a resolution witness, keyed by occurrence UUID
    // rather than the provider's reusable raw ID. The write's defer removes it.
    private var responding: [UUID: Bool] = [:]
    private var connectionLostHandler: (@Sendable (String) -> Void)?
    private struct Join {
        let generation: UUID
        let binding: CodexRunBinding
        var task: Task<Void, Error>?
        var awaitingPersistence = false
        var attempts = 0
        var lastStatus: CodexThreadStatus?
        var retryStatus: CodexThreadStatus?
    }
    private var joins: [UUID: Join] = [:]
    // Retained failures are barriers too: an uncertain old join must never be
    // followed by a new owner whose subscription an old cleanup could remove.
    private struct StopGate {
        let cleanupID: UUID
        let continuation: AsyncStream<Void>.Continuation
    }
    private var stopGates: [UUID: StopGate] = [:]
    private var cleanupByThread: [String: Task<Void, Error>] = [:]
    private var cleanupIDs: [String: UUID] = [:]
    private var cleanupDrains: [String: (id: UUID, task: Task<Void, Error>)] = [:]
    private enum CleanupPhase { case drainingJoin, waitingCompletion, unsubscribing, unsubscribeRejected }
    private var cleanupPhases: [String: CleanupPhase] = [:]
    private var cleanupThreadByRun: [UUID: String] = [:]
    private var acceptingJoins = true
    private var issueHandler: (@Sendable (String) -> Void)?
    private var serverGone: (@Sendable () async -> Bool)?

    public init(
        client: CodexAppServerClient, supervisor: ProcessSupervisor,
        adapter: CodexSessionAdapter,
        router: CodexSessionRouter = CodexSessionRouter()
    ) {
        self.client = client
        self.supervisor = supervisor
        self.adapter = adapter
        self.router = router
        var continuation: AsyncStream<CodexRequestSnapshot>.Continuation!
        requests = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        requestContinuation = continuation
    }

    deinit {
        consumerTask?.cancel()
        requestContinuation.finish()
    }

    /// Called once when the app-server stream ends without `stop()`: the
    /// server closed, crashed or the socket failed. Pending requests can no
    /// longer be answered after this.
    public func setConnectionLostHandler(_ handler: @escaping @Sendable (String) -> Void) {
        connectionLostHandler = handler
    }

    /// Called for every issue the coordinator records (a dropped request, a
    /// failed identity binding) so it can reach the UI and not only `issues()`.
    public func setIssueHandler(_ handler: @escaping @Sendable (String) -> Void) {
        issueHandler = handler
    }

    /// Answers whether the app-server process of this conversation is verified
    /// gone (its run ended or its leader no longer exists). Only then may a
    /// stop rely on process destruction instead of the provider's own cleanup.
    public func setServerGone(_ check: @escaping @Sendable () async -> Bool) {
        serverGone = check
    }

    private func providerServerGone() async -> Bool { await serverGone?() ?? false }

    /// Provider failure text may contain user content or credentials; only a
    /// fixed category and numeric RPC code reach a card (as in stop reports).
    static func failureText(_ what: String, _ error: any Error) -> String {
        let stage = ProviderStopStage(stage: "", threadID: nil, error: error)
        return "\(what) (\(stage.errorCategory ?? "unknown")" + (stage.rpcCode.map { ", RPC \($0)" } ?? "") + ")"
    }

    private func record(issue: String) {
        recordedIssues.append(issue)
        issueHandler?(issue)
    }

    public func start() {
        guard consumerTask == nil else { return }
        let stream = client.events
        consumerTask = Task { [weak self] in
            for await inbound in stream {
                guard !Task.isCancelled else { break }
                await self?.consume(inbound)
            }
            guard !Task.isCancelled else { return }
            await self?.streamEnded()
        }
    }

    private func streamEnded() {
        acceptingJoins = false
        for runID in Array(joins.keys) { _ = invalidateJoin(runID: runID) }
        recordedIssues.append("Codex app-server connection closed")
        connectionLostHandler?("The Codex app-server connection closed")
    }

    /// Requests the user has not answered yet (used to tell a lost connection
    /// from an answered request).
    public func pendingRequestIDs() -> [JSONValue] { pendingRequests.map(\.request.id) }

    public func pendingRequestSnapshot() -> CodexRequestSnapshot {
        CodexRequestSnapshot(revision: requestRevision, pending: pendingRequests)
    }

    private func publishRequests() {
        // Full snapshots make a skipped frame safe for both additions and removals.
        requestRevision &+= 1
        requestContinuation.yield(pendingRequestSnapshot())
    }

    public func stop() async {
        acceptingJoins = false
        for gate in stopGates.values { gate.continuation.yield(()); gate.continuation.finish() }
        stopGates.removeAll()
        let cleanup = Array(joins.keys).compactMap { invalidateJoin(runID: $0) }
        for task in cleanup { _ = await task.result }
        connectionLostHandler = nil
        issueHandler = nil
        consumerTask?.cancel()
        consumerTask = nil
        cleanupDrains.removeAll()
        pendingRequests.removeAll()
        answeredRequests.removeAll()
        publishRequests()
        requestContinuation.finish()
    }

    public func issues() -> [String] { recordedIssues }

    public func reserveNewLaunch(
        sessionID: UUID, managedRunID: UUID, workingDirectory: String
    ) async -> CodexLaunchReservation {
        let sequence = await client.latestSequence()
        return await router.launchMatcher.reserveNewLaunch(
            sessionID: sessionID, managedRunID: managedRunID,
            workingDirectory: workingDirectory, after: sequence
        )
    }

    public func waitForNewLaunch(
        _ reservation: CodexLaunchReservation, timeout: TimeInterval? = 10
    ) async throws -> String {
        try await router.launchMatcher.waitForMatch(reservation, timeout: timeout)
    }

    public func cancelNewLaunch(_ reservation: CodexLaunchReservation) async {
        await router.launchMatcher.cancel(reservation)
    }

    public func bindResume(
        sessionID: UUID, managedRunID: UUID, threadID: String,
        workingDirectory: String
    ) async throws {
        if let join = joins[managedRunID], join.binding.sessionID == sessionID,
           join.binding.threadID == threadID { return }
        let sequence = await client.latestSequence()
        let binding = CodexRunBinding(sessionID: sessionID, managedRunID: managedRunID,
            threadID: threadID, workingDirectory: workingDirectory)
        try await installBinding(binding, after: sequence)
    }

    public func unbind(runID: UUID) async {
        stopGates.removeValue(forKey: runID)?.continuation.finish()
        let cleanup = invalidateJoin(runID: runID)
            ?? cleanupThreadByRun[runID].flatMap { cleanupByThread[$0] }
        cleanupThreadByRun[runID] = nil
        await router.remove(runID: runID)
        await adapter.clearAmbiguousThreads(runID: runID)
        pendingRequests.removeAll { $0.binding.managedRunID == runID }
        answeredRequests.removeAll { $0.binding.managedRunID == runID }
        publishRequests()
        if let cleanup { _ = await cleanup.result }
    }

    /// Sends the user's explicit decision back to app-server and only then
    /// clears the matching idle blocker. Failed writes remain pending so the UI
    /// can retry or surface the connection failure.
    public func respond(
        to pending: CodexPendingRequest, result: JSONValue
    ) async throws {
        try await respond(to: pending, result: result) { [client] id, value in
            try await client.respond(id: id, result: value)
        }
    }

    // The same response transaction with a controllable transport write lets
    // regressions hold the suspension point while a provider resolution arrives.
    func respond(
        to pending: CodexPendingRequest, result: JSONValue,
        writeResponse: @Sendable (JSONValue, JSONValue) async throws -> Void
    ) async throws {
        guard pendingRequests.contains(pending), responding[pending.id] == nil else {
            throw CodexAppServerError.protocolViolation("approval/input request is no longer pending or is being answered")
        }
        responding[pending.id] = false
        defer { responding.removeValue(forKey: pending.id) }
        do {
            try await writeResponse(pending.request.id, result)
        } catch {
            // An authoritative resolution may have arrived while the write was
            // suspended. It must not be resurrected as a failed pending request.
            if responding[pending.id] == true { return }
            throw error
        }
        if pendingRequests.contains(pending) { answeredRequests.append(pending) }
        await resolve(pending)
    }

    private func resolve(_ pending: CodexPendingRequest) async {
        guard pendingRequests.contains(pending) else { return }
        pendingRequests.removeAll { $0.id == pending.id }
        publishRequests()
        _ = await adapter.resolveRequest(
            runID: pending.binding.managedRunID, requestSequence: pending.sequence
        )
    }

    func consume(_ inbound: CodexAppServerInbound) async {
        let decision = await router.route(inbound)
        do {
            switch decision {
            case let .initialLaunchMatched(binding, sequence):
                try await installBinding(binding, after: sequence)
            case let .routed(binding):
                if case let .request(_, request) = inbound,
                   (pendingRequests + answeredRequests).contains(where: {
                       $0.binding == binding && $0.request.id == request.id
                   }) {
                    // Do not replace the occurrence or the reducer sequence
                    // while a response write is suspended (or awaiting resolution).
                    return
                }
                // Pin the occurrence before crossing into the adapter actor:
                // a subsequent request may reuse the raw ID during that await.
                let resolvedOccurrence: CodexPendingRequest?
                if case let .event(sequence, .serverRequestResolved(_, requestID)) = inbound {
                    resolvedOccurrence = pendingRequests.first {
                        $0.binding == binding && $0.request.id == requestID && $0.sequence < sequence
                    }
                } else { resolvedOccurrence = nil }
                let disposition = try await adapter.receive(
                    inbound, runID: binding.managedRunID
                )
                guard disposition == .applied else { return }
                if case let .event(_, .threadStatusChanged(_, status)) = inbound {
                    retryJoin(binding, status: status)
                }
                if case let .request(sequence, request) = inbound {
                    pendingRequests.removeAll {
                        $0.binding == binding && $0.request.id == request.id
                    }
                    pendingRequests.append(CodexPendingRequest(
                        request: request, sequence: sequence, binding: binding
                    ))
                    publishRequests()
                }
                if case let .event(sequence, .serverRequestResolved(_, requestID)) = inbound {
                    answeredRequests.removeAll {
                        $0.binding == binding && $0.request.id == requestID && $0.sequence < sequence
                    }
                    if let pending = resolvedOccurrence {
                        if responding[pending.id] != nil { responding[pending.id] = true }
                        await resolve(pending)
                    }
                }
                if case let .event(sequence, .threadStatusChanged(_, .idle)) = inbound {
                    try await hydrateIdleThread(binding: binding, after: sequence)
                }
            case let .newConversation(previous, identity):
                _ = invalidateJoin(runID: previous.managedRunID)
                let sequence: UInt64
                switch inbound {
                case let .event(value, _), let .request(value, _): sequence = value
                }
                let newSessionID = try await adapter.transition(
                    runID: previous.managedRunID, to: identity.id,
                    after: sequence
                )
                pendingRequests.removeAll { $0.binding.managedRunID == previous.managedRunID }
                answeredRequests.removeAll { $0.binding.managedRunID == previous.managedRunID }
                publishRequests()
                let binding = CodexRunBinding(
                    sessionID: newSessionID,
                    managedRunID: previous.managedRunID,
                    threadID: identity.id,
                    workingDirectory: identity.workingDirectory
                        ?? previous.workingDirectory
                )
                try await installBinding(binding, after: sequence, alreadyBound: true)
            case let .ambiguous(candidates, threadID):
                try await adapter.markAmbiguous(candidates, threadID: threadID)
            case .unmatched:
                break
            }
        } catch is CancellationError {
            // The binding was invalidated by Stop/unbind while installing.
            return
        } catch {
            record(issue: Self.failureText("Codex event could not be processed", error))
        }
    }

    private func joinIssue(_ binding: CodexRunBinding, _ error: Error) async {
        let issue = Self.failureText("Codex thread subscription failed", error)
        recordedIssues.append(issue)
        await supervisor.events.publish(sessionID: binding.sessionID, change: .issue(issue))
    }

    private func installBinding(
        _ binding: CodexRunBinding, after sequence: UInt64, alreadyBound: Bool = false
    ) async throws {
        guard acceptingJoins else { throw CancellationError() }
        if joins[binding.managedRunID]?.binding == binding { return }
        _ = invalidateJoin(runID: binding.managedRunID)
        let generation = UUID()
        joins[binding.managedRunID] = Join(generation: generation, binding: binding)
        func verify() throws {
            guard acceptingJoins, joins[binding.managedRunID]?.generation == generation else {
                throw CancellationError()
            }
        }
        if !alreadyBound {
            try await adapter.bind(sessionID: binding.sessionID, runID: binding.managedRunID,
                threadID: binding.threadID, after: sequence)
            try verify()
        }
        try await supervisor.setIdentityState(.known, runID: binding.managedRunID)
        try verify()
        try await registerStopHooks(runID: binding.managedRunID, threadID: binding.threadID)
        try verify()
        await router.register(binding)
        try verify()
        launchJoin(runID: binding.managedRunID)
    }

    private func launchJoin(runID: UUID) {
        guard var join = joins[runID], join.task == nil, join.attempts < 3 else { return }
        join.attempts += 1
        join.awaitingPersistence = false
        let binding = join.binding, generation = join.generation
        let barrier = cleanupByThread[binding.threadID]
        let client = self.client
        let task = Task {
            if let barrier { try await barrier.value }
            // Never cancel a sent RPC: cancellation is not a server rollback.
            try await client.joinThread(binding.threadID)
        }
        join.task = task
        joins[runID] = join
        Task { [weak self] in
            let result = await task.result
            await self?.joinFinished(runID: runID, generation: generation, result: result)
        }
    }

    private func retryJoin(_ binding: CodexRunBinding, status: CodexThreadStatus) {
        guard var join = joins[binding.managedRunID], join.binding == binding else { return }
        let changed = join.lastStatus != status
        let wasActive: Bool
        if case .active = join.lastStatus { wasActive = true } else { wasActive = false }
        join.lastStatus = status
        if changed, case .active = status { join.retryStatus = status }
        // A short first turn may persist only after its active retry failed. Its
        // active-to-idle transition is another bounded, event-driven retry point.
        if changed, wasActive, case .idle = status { join.retryStatus = status }
        joins[binding.managedRunID] = join
        if join.awaitingPersistence, join.retryStatus != nil {
            joins[binding.managedRunID]?.retryStatus = nil
            launchJoin(runID: binding.managedRunID)
        }
    }

    private func joinFinished(runID: UUID, generation: UUID, result: Result<Void, Error>) async {
        guard var join = joins[runID], join.generation == generation else { return }
        switch result {
        case .success:
            // Keep the completed task as the wire-order barrier for cleanup.
            join.retryStatus = nil
            joins[runID] = join
        case let .failure(error):
            if case let CodexAppServerError.rpc(code, message, _) = error,
               code == -32600, message.lowercased().contains("no rollout"),
               message.contains(join.binding.threadID) {
                join.task = nil
                join.awaitingPersistence = true
                joins[runID] = join
                if join.attempts == 3 {
                    await joinIssue(join.binding, error)
                } else if join.retryStatus != nil {
                    joins[runID]?.retryStatus = nil
                    launchJoin(runID: runID)
                }
            } else {
                joins[runID] = join
                await joinIssue(join.binding, error)
            }
        }
    }

    /// Generation invalidation is synchronous; cleanup waits for the server
    /// response before unsubscribe. A timeout leaves a failed barrier, since
    /// the server may still apply that join after any subsequent unsubscribe.
    private func invalidateJoin(runID: UUID, completion: AsyncStream<Void>? = nil, cleanupID: UUID = UUID()) -> Task<Void, Error>? {
        guard let join = joins.removeValue(forKey: runID) else { return nil }
        cleanupThreadByRun[runID] = join.binding.threadID
        let prior = cleanupByThread[join.binding.threadID]
        let drain = Task {
            if let prior { try await prior.value }
            if let task = join.task {
                do { try await task.value }
                catch let error as CodexAppServerError {
                    switch error {
                    case .rpc, .protocolViolation: break // authoritative response
                    default: throw error // timeout/transport outcome is uncertain
                    }
                }
            }
            try await self.joinCleanupDrained(threadID: join.binding.threadID, id: cleanupID)
        }
        let cleanup = Task {
            try await drain.value
            if let completion { for await _ in completion { break } }
            try await self.unsubscribeForCleanup(threadID: join.binding.threadID, id: cleanupID)
        }
        cleanupByThread[join.binding.threadID] = cleanup
        cleanupIDs[join.binding.threadID] = cleanupID
        cleanupDrains[join.binding.threadID] = (cleanupID, drain)
        cleanupPhases[join.binding.threadID] = .drainingJoin
        Task { [weak self] in
            if case .success = await cleanup.result {
                await self?.forgetCleanup(threadID: join.binding.threadID, id: cleanupID)
            }
        }
        return cleanup
    }

    private func forgetCleanup(threadID: String, id: UUID) {
        guard cleanupIDs[threadID] == id else { return }
        cleanupByThread[threadID] = nil
        cleanupIDs[threadID] = nil
        cleanupDrains[threadID] = nil
        cleanupPhases[threadID] = nil
    }

    private func joinCleanupDrained(threadID: String, id: UUID) throws {
        guard cleanupIDs[threadID] == id else { throw CancellationError() }
        cleanupPhases[threadID] = .waitingCompletion
    }

    private func unsubscribeForCleanup(threadID: String, id: UUID) async throws {
        guard cleanupIDs[threadID] == id, cleanupPhases[threadID] == .waitingCompletion else {
            throw CancellationError()
        }
        cleanupPhases[threadID] = .unsubscribing
        do { try await client.unsubscribe(threadID: threadID) }
        catch let error as CodexAppServerError where error.isThreadNotFound {}
        catch let error as CodexAppServerError {
            if case .rpc = error, cleanupIDs[threadID] == id {
                // This phase can only be reached after the join/prior wire
                // barrier settled. A timeout or a prior RPC failure never
                // authorizes another unsubscribe.
                cleanupPhases[threadID] = .unsubscribeRejected
            }
            throw error
        }
    }

    private func retryRejectedCleanup(threadID: String, expectedID: UUID) -> Task<Void, Error>? {
        guard cleanupIDs[threadID] == expectedID, cleanupPhases[threadID] == .unsubscribeRejected else { return nil }
        let id = UUID()
        let task = Task { try await self.unsubscribeForCleanup(threadID: threadID, id: id) }
        cleanupByThread[threadID] = task
        cleanupIDs[threadID] = id
        if let drain = cleanupDrains[threadID] { cleanupDrains[threadID] = (id, drain.task) }
        // Preserve the settled join/prior proof while replacing only the
        // rejected unsubscribe. Never await or discard an uncertain barrier.
        cleanupPhases[threadID] = .waitingCompletion
        Task { [weak self] in
            if case .success = await task.result { await self?.forgetCleanup(threadID: threadID, id: id) }
        }
        return task
    }

    private func stopPreparationFailed(runID: UUID, sessionID: UUID?, error: Error) async {
        stopGates.removeValue(forKey: runID)?.continuation.finish()
        if let sessionID {
            await supervisor.events.publish(sessionID: sessionID,
                change: .issue(Self.failureText(
                    "Codex subscription was stopped; restart the session to receive requests", error)))
        }
    }

    /// An open run-scoped gate separates settled join ordering from provider
    /// completion. A live TUI may start more work after a failed process sample;
    /// another prepare must reach stopThreadWork without awaiting that gate.
    private func awaitOpenStopDrain(runID: UUID, threadID: String) async throws -> Bool {
        guard let gate = stopGates[runID], cleanupThreadByRun[runID] == threadID,
              let drain = cleanupDrains[threadID], gate.cleanupID == drain.id,
              cleanupIDs[threadID] == drain.id else { return false }
        try await drain.task.value
        guard stopGates[runID]?.cleanupID == drain.id, cleanupThreadByRun[runID] == threadID,
              cleanupIDs[threadID] == drain.id, cleanupPhases[threadID] == .waitingCompletion else {
            throw CancellationError()
        }
        return true
    }

    func prepareJoinStop(runID: UUID, threadID: String) async throws {
        guard let join = joins[runID] else {
            if try await awaitOpenStopDrain(runID: runID, threadID: threadID) { return }

            if let cleanup = cleanupByThread[threadID], let id = cleanupIDs[threadID] {
                do { try await cleanup.value }
                catch {
                    // A failed prepare finished its completion gate too.
                    // This later user retry may refresh only that cleanup's
                    // authoritative unsubscribe rejection, once per call.
                    guard let retry = retryRejectedCleanup(threadID: threadID, expectedID: id) else { throw error }
                    try await retry.value
                }
            }
            return
        }
        guard join.binding.threadID == threadID else { throw CancellationError() }
        let (completion, continuation) = AsyncStream<Void>.makeStream()
        let cleanupID = UUID()
        stopGates[runID] = StopGate(cleanupID: cleanupID, continuation: continuation)
        _ = invalidateJoin(runID: runID, completion: completion, cleanupID: cleanupID)
        do {
            guard try await awaitOpenStopDrain(runID: runID, threadID: threadID) else {
                throw CancellationError()
            }
        } catch {
            continuation.finish()
            // A replaced binding owns its own gate; do not close it from an
            // older prepare that resumed after its drain was invalidated.
            if stopGates[runID]?.cleanupID == cleanupID {
                stopGates.removeValue(forKey: runID)
            }
            await joinIssue(join.binding, error)
            throw error
        }
    }

    func completeJoinStop(runID: UUID, threadID: String) async throws {
        stopGates.removeValue(forKey: runID)?.continuation.finish()
        if let cleanup = cleanupByThread[threadID], let id = cleanupIDs[threadID] {
            if let retry = retryRejectedCleanup(threadID: threadID, expectedID: id) { try await retry.value }
            else { try await cleanup.value }
        } else { try await client.unsubscribe(threadID: threadID) }
    }

    private func registerStopHooks(runID: UUID, threadID: String) async throws {
        let client = self.client
        let adapter = self.adapter
        let sessionID = await supervisor.activeSessionID(runID: runID)
        try await supervisor.registerStopHooks(
            runID: runID,
            hooks: ManagedRunStopHooks(
                threadID: threadID,
                prepare: { [weak self] in
                    // A dead server cannot be asked anything: waiting for its
                    // RPCs only delays a stop that process destruction settles.
                    try await self?.requireProvider()
                    do {
                        // Invalidate at prepare entry, including automatic idle.
                        try await self?.prepareJoinStop(runID: runID, threadID: threadID)
                        do {
                            try await adapter.verifyAmbiguousStop(runID: runID) {
                                try await client.readThread($0)
                            }
                            try await client.stopThreadWork(threadID)
                        } catch let error as CodexAppServerError where error.isThreadNotFound {
                            // A resume of a thread the server never had (deleted
                            // history) has no provider work to stop.
                        } catch {
                            try await self?.requireProvider()
                            await self?.stopPreparationFailed(runID: runID, sessionID: sessionID, error: error)
                            throw error
                        }
                    } catch let error as ProviderUnavailableError {
                        throw error
                    } catch {
                        try await self?.requireProvider()
                        throw error
                    }
                },
                completed: { [weak self] in
                    // The producer is verified gone before this hook. Input
                    // accepted between prepare and PTY termination may have
                    // started more server work, so stop it before unsubscribe.
                    try await self?.requireProvider()
                    do {
                        do { try await client.stopThreadWork(threadID) }
                        catch let error as CodexAppServerError where error.isThreadNotFound {
                            // Authoritative absence means no work, but completion
                            // must still open the gate and settle subscription cleanup.
                        }
                        do { try await self?.completeJoinStop(runID: runID, threadID: threadID) }
                        catch let error as CodexAppServerError where error.isThreadNotFound {}
                    } catch {
                        try await self?.requireProvider()
                        throw error
                    }
                }
            )
        )
    }

    /// Throws `ProviderUnavailableError` when the server process is verified
    /// gone; a merely closed connection to a live server is still a failure.
    private func requireProvider() async throws {
        if await providerServerGone() {
            throw ProviderUnavailableError("the session's Codex app-server is gone")
        }
    }

    private func hydrateIdleThread(
        binding: CodexRunBinding, after sequence: UInt64
    ) async throws {
        async let snapshot = client.readThread(binding.threadID)
        async let terminals = client.backgroundTerminalCount(threadID: binding.threadID)
        let (thread, terminalCount) = try await (snapshot, terminals)
        // Use the status event being hydrated as the barrier. The client's
        // latest sequence may already include events buffered behind this
        // coordinator call; advancing to it would incorrectly discard them.
        _ = try await adapter.refresh(
            thread, runID: binding.managedRunID, after: sequence,
            backgroundTerminalCount: terminalCount
        )
    }
}
