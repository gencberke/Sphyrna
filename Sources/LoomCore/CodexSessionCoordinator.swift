import Foundation

/// Connects the shared app-server stream to run-scoped supervisor state. It is
/// the product boundary that performs serialized new-TUI identity assignment,
/// routes approvals, applies `/new`, and hydrates the last turn after a remote
/// TUI reports idle (remote-originated turns are not broadcast in full).
public actor CodexSessionCoordinator {
    public nonisolated let requests: AsyncStream<CodexServerRequest>

    private let client: CodexAppServerClient
    private let supervisor: ProcessSupervisor
    private let adapter: CodexSessionAdapter
    private let router: CodexSessionRouter
    private let requestContinuation: AsyncStream<CodexServerRequest>.Continuation
    private var consumerTask: Task<Void, Never>?
    private var recordedIssues: [String] = []
    private struct PendingRequest: Sendable {
        let request: CodexServerRequest
        let sequence: UInt64
        let binding: CodexRunBinding
    }
    private var pendingRequests: [PendingRequest] = []

    public init(
        client: CodexAppServerClient, supervisor: ProcessSupervisor,
        adapter: CodexSessionAdapter,
        router: CodexSessionRouter = CodexSessionRouter()
    ) {
        self.client = client
        self.supervisor = supervisor
        self.adapter = adapter
        self.router = router
        var continuation: AsyncStream<CodexServerRequest>.Continuation!
        requests = AsyncStream(bufferingPolicy: .bufferingNewest(256)) {
            continuation = $0
        }
        requestContinuation = continuation
    }

    deinit {
        consumerTask?.cancel()
        requestContinuation.finish()
    }

    public func start() {
        guard consumerTask == nil else { return }
        let stream = client.events
        consumerTask = Task { [weak self] in
            for await inbound in stream {
                guard !Task.isCancelled else { break }
                await self?.consume(inbound)
            }
        }
    }

    public func stop() {
        consumerTask?.cancel()
        consumerTask = nil
        pendingRequests.removeAll()
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
        _ reservation: CodexLaunchReservation, timeout: TimeInterval = 10
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
        let sequence = await client.latestSequence()
        try await adapter.bind(
            sessionID: sessionID, runID: managedRunID,
            threadID: threadID, after: sequence
        )
        try await supervisor.setIdentityState(.known, runID: managedRunID)
        try await registerStopHooks(runID: managedRunID, threadID: threadID)
        await router.register(CodexRunBinding(
            sessionID: sessionID, managedRunID: managedRunID,
            threadID: threadID, workingDirectory: workingDirectory
        ))
    }

    public func unbind(runID: UUID) async {
        await router.remove(runID: runID)
        pendingRequests.removeAll { $0.binding.managedRunID == runID }
    }

    /// Sends the user's explicit decision back to app-server and only then
    /// clears the matching idle blocker. Failed writes remain pending so the UI
    /// can retry or surface the connection failure.
    public func respond(
        to request: CodexServerRequest, result: JSONValue
    ) async throws {
        guard let index = pendingRequests.firstIndex(where: {
            $0.request.id == request.id && $0.request.method == request.method
                && $0.request.threadID == request.threadID
        }) else {
            throw CodexAppServerError.protocolViolation(
                "approval/input request is no longer pending"
            )
        }
        let pending = pendingRequests[index]
        try await client.respond(id: request.id, result: result)
        pendingRequests.remove(at: index)
        _ = await adapter.resolveRequest(
            runID: pending.binding.managedRunID,
            requestSequence: pending.sequence
        )
    }

    private func consume(_ inbound: CodexAppServerInbound) async {
        let decision = await router.route(inbound)
        do {
            switch decision {
            case let .initialLaunchMatched(binding, sequence):
                try await adapter.bind(
                    sessionID: binding.sessionID,
                    runID: binding.managedRunID,
                    threadID: binding.threadID, after: sequence
                )
                try await supervisor.setIdentityState(
                    .known, runID: binding.managedRunID
                )
                try await registerStopHooks(
                    runID: binding.managedRunID, threadID: binding.threadID
                )
                await router.register(binding)
            case let .routed(binding):
                let disposition = try await adapter.receive(
                    inbound, runID: binding.managedRunID
                )
                guard disposition == .applied else { return }
                if case let .request(sequence, request) = inbound {
                    pendingRequests.append(PendingRequest(
                        request: request, sequence: sequence, binding: binding
                    ))
                    switch requestContinuation.yield(request) {
                    case .enqueued: break
                    case .dropped:
                        recordedIssues.append("Codex approval/input consumer overflow")
                    case .terminated:
                        recordedIssues.append("Codex approval/input consumer is closed")
                    @unknown default:
                        recordedIssues.append("Codex approval/input delivery is unknown")
                    }
                }
                if case let .event(sequence, .threadStatusChanged(_, .idle)) = inbound {
                    try await hydrateIdleThread(binding: binding, after: sequence)
                }
            case let .newConversation(previous, identity):
                let sequence: UInt64
                switch inbound {
                case let .event(value, _), let .request(value, _): sequence = value
                }
                let newSessionID = try await adapter.transition(
                    runID: previous.managedRunID, to: identity.id,
                    after: sequence
                )
                try await supervisor.setIdentityState(
                    .known, runID: previous.managedRunID
                )
                try await registerStopHooks(
                    runID: previous.managedRunID, threadID: identity.id
                )
                await router.register(CodexRunBinding(
                    sessionID: newSessionID,
                    managedRunID: previous.managedRunID,
                    threadID: identity.id,
                    workingDirectory: identity.workingDirectory
                        ?? previous.workingDirectory
                ))
            case let .ambiguous(candidates):
                try await adapter.markAmbiguous(candidates)
            case .unmatched:
                break
            }
        } catch {
            recordedIssues.append(String(describing: error))
        }
    }

    private func registerStopHooks(runID: UUID, threadID: String) async throws {
        let client = self.client
        try await supervisor.registerStopHooks(
            runID: runID,
            hooks: ManagedRunStopHooks(
                prepare: { try await client.stopThreadWork(threadID) },
                completed: { try await client.unsubscribe(threadID: threadID) }
            )
        )
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
