import Foundation

/// The approval API for requests of agents to open a session (D-40). The UI shows the list
/// and calls approve, deny or dismiss; nothing starts without an approve call (contract section 7).
extension SessionRuntime {
    /// The current list first, then the whole list after every change (new request, notice, state
    /// change, removal). Finishes at Quit.
    public func openRequestUpdates() async -> AsyncStream<[OpenSessionRequest]> {
        await openRequests.updates()
    }

    public func openRequestSnapshot() async -> [OpenSessionRequest] {
        await openRequests.snapshot()
    }

    /// Starts the approved session through the normal start path and answers the waiting agent
    /// (`started <id>`). The caller adopts the returned launch
    /// like `startConversation`'s: it passes the terminal sink and size the same way. A failed
    /// start throws and leaves the request in the list as failed; it is never retried.
    public func approveOpenRequest(
        _ requestID: UUID, rows: UInt16 = 24, columns: UInt16 = 80,
        outputSink: (any TerminalOutputSink)? = nil,
        expectedProvider: ManagedSession.Provider? = nil,
        onTerminalReady: (@MainActor @Sendable (RuntimeLaunch) async -> Void)? = nil
    ) async throws -> RuntimeLaunch {
        if await openRequests.snapshot().first(where: { $0.id == requestID })?.send != nil {
            throw SessionTaskError.unauthorized
        }
        if let expectedProvider {
            guard let request = await openRequests.snapshot().first(where: { $0.id == requestID }) else {
                throw OpenSessionError.unknownRequest(requestID)
            }
            guard request.choices.harness.provider == expectedProvider else {
                throw SessionRuntimeError.openRequestHarnessMismatch
            }
        }
        let launched = LaunchBox()
        let sessionID = try await openRequests.approve(requestID) { spec in
            guard spec.send == nil else { throw SessionTaskError.unauthorized }
            guard spec.task == nil else { throw SessionTaskError.notReady }
            guard let provider = spec.choices.harness.provider else {
                let name = HarnessCatalogue.descriptor(for: spec.choices.harness)?.displayName ?? spec.choices.harness.rawValue
                throw LoomError.message("\(name) cannot start an opened session in this build")
            }
            let launch = try await self.startConversation(
                provider: provider, projectID: spec.projectID, rows: rows, columns: columns,
                outputSink: outputSink,
                opening: SessionOpening(
                    title: spec.title, firstMessage: spec.message, openedBy: spec.requesterID,
                    choices: spec.choices, modeFromUserDefault: spec.modeFromUserDefault
                ), onTerminalReady: onTerminalReady
            )
            launched.value = launch
            return launch.sessionID
        }
        // `approve` returns the id `start` returned, so the launch is always there.
        guard let launch = launched.value, launch.sessionID == sessionID else {
            throw OpenSessionError.unknownRequest(requestID)
        }
        return launch
    }

    /// Approves a task-owned child without allocating or retaining a terminal
    /// surface. Its process remains owned by this runtime's supervisor.
    public func approveManagedTaskRequest(_ requestID: UUID,
                                          expectedProvider: ManagedSession.Provider? = nil) async throws -> UUID {
        guard let request = await openRequests.snapshot().first(where: { $0.id == requestID }),
              request.task != nil, request.send == nil else { throw OpenSessionError.unknownRequest(requestID) }
        if let expectedProvider, request.choices.harness.provider != expectedProvider {
            throw SessionRuntimeError.openRequestHarnessMismatch
        }
        return try await openRequests.approve(requestID) { spec in
            guard spec.task != nil, spec.send == nil else { throw SessionTaskError.unauthorized }
            return try await self.approveManagedTaskRequest(spec)
        }
    }

    /// The Chat face's approval (C5b): the same request, the same coordinator and the same answer to the agent
    /// (`started <id>` once the child is spawned), but the session starts in the Chat face with the request's title and
    /// `openedBy`. The caller (the Chat driver) sends `firstMessage` over stdin once the CLI is ready, as a draft's.
    /// A failed start throws and leaves the request in the list as failed; it is never retried.
    public func approveOpenRequestInChat(
        _ requestID: UUID, sessionID: UUID = UUID(), outputSink: any PipeOutputSink
    ) async throws -> RuntimeOpenedChat {
        if await openRequests.snapshot().first(where: { $0.id == requestID })?.send != nil {
            throw SessionTaskError.unauthorized
        }
        let launched = ChatLaunchBox()
        let started = try await openRequests.approve(requestID) { spec in
            guard spec.send == nil else { throw SessionTaskError.unauthorized }
            guard spec.task == nil else { throw SessionTaskError.notReady }
            guard spec.choices.claudeChoices != nil else {
                let name = HarnessCatalogue.descriptor(for: spec.choices.harness)?.displayName ?? spec.choices.harness.rawValue
                throw LoomError.message("\(name) cannot start an opened session in this build")
            }
            let launch = try await self.startChatConversation(
                projectID: spec.projectID, sessionID: sessionID,
                opening: SessionOpening(title: spec.title, firstMessage: spec.message, openedBy: spec.requesterID,
                                        choices: spec.choices, modeFromUserDefault: spec.modeFromUserDefault),
                outputSink: outputSink
            )
            launched.value = RuntimeOpenedChat(launch: launch, firstMessage: spec.message)
            return launch.sessionID
        }
        guard let opened = launched.value, opened.launch.sessionID == started else {
            throw OpenSessionError.unknownRequest(requestID)
        }
        return opened
    }

    /// The agent's command is answered `denied`; nothing starts.
    public func denyOpenRequest(_ requestID: UUID) async throws {
        let request = await openRequests.snapshot().first { $0.id == requestID }
        let taskID = request?.task?.taskID
        try await openRequests.deny(requestID)
        if request?.send != nil {
            _ = try await peerMailbox?.decide(id: requestID, accept: false)
            peerPendingRequests[requestID] = nil
        }
        if let taskID { taskChildReservations[taskID] = nil }
    }

    /// Removes a failed request (a request still waiting counts as denied).
    public func dismissOpenRequest(_ requestID: UUID) async throws {
        let request = await openRequests.snapshot().first { $0.id == requestID }
        let taskID = request?.task?.taskID
        try await openRequests.dismiss(requestID)
        if request?.send != nil {
            if request?.phase == .waiting { _ = try await peerMailbox?.decide(id: requestID, accept: false) }
            peerPendingRequests[requestID] = nil
        }
        if let taskID { taskChildReservations[taskID] = nil }
    }
}

private final class LaunchBox: @unchecked Sendable {
    var value: RuntimeLaunch?
}

private final class ChatLaunchBox: @unchecked Sendable {
    var value: RuntimeOpenedChat?
}

/// The Chat launch of an approved opening: the pipes, and the request's message the driver sends once ready.
public struct RuntimeOpenedChat: Sendable {
    public let launch: RuntimePipeLaunch
    public let firstMessage: String
}
