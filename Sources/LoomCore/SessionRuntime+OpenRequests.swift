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

    /// The Chat face's approval (C5b): the same request, the same coordinator and the same answer to the agent
    /// (`started <id>` once the child is spawned), but the session starts in the Chat face with the request's title and
    /// `openedBy`. The caller (the Chat driver) sends `firstMessage` over stdin once the CLI is ready, as a draft's.
    /// A failed start throws and leaves the request in the list as failed; it is never retried.
    public func approveOpenRequestInChat(
        _ requestID: UUID, sessionID: UUID = UUID(), outputSink: any PipeOutputSink
    ) async throws -> RuntimeOpenedChat {
        let launched = ChatLaunchBox()
        let started = try await openRequests.approve(requestID) { spec in
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
        try await openRequests.deny(requestID)
    }

    /// Removes a failed request (a request still waiting counts as denied).
    public func dismissOpenRequest(_ requestID: UUID) async throws {
        try await openRequests.dismiss(requestID)
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
