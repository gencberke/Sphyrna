import Foundation
import LoomCore

extension ConversationIntents {
    public func approveOpen(requestID: UUID) {}
    public func denyOpen(requestID: UUID) {}
    public func dismissOpen(requestID: UUID) {}
}

/// What the user can do with an agent's request to open a session (D-40). The model only forwards the
/// answer; the runtime starts the session, and the controller adopts its terminal. Nothing here
/// selects a session by itself.
extension CatalogModel {
    /// The requests and notices of one session's agent, in arrival order: the box above its terminal.
    public func openRequests(for sessionID: UUID) -> [OpenSessionRequest] {
        openRequests.filter { $0.requesterID == sessionID }
    }

    /// "Open Session". The new session appears in its project; the selection stays where it is.
    public func approveOpenRequest(_ id: UUID) {
        guard actionsAvailable else { return }
        intents?.approveOpen(requestID: id)
        if let projectID = openRequests.first(where: { $0.id == id })?.projectID,
           projects.first(where: { $0.id == projectID })?.collapsed == true {
            Task { [weak self] in await self?.expandProject(projectID) }
        }
    }

    /// "Deny": the agent's command is answered "denied" and nothing starts.
    public func denyOpenRequest(_ id: UUID) {
        guard actionsAvailable else { return }
        intents?.denyOpen(requestID: id)
    }

    /// "Dismiss" on a failed request or an "already has a session" notice.
    public func dismissOpenRequest(_ id: UUID) {
        guard actionsAvailable else { return }
        intents?.dismissOpen(requestID: id)
    }

    /// "Show Session" on an "already has a session" notice: the one place a request changes the selection,
    /// and only because the user asked.
    public func showExistingSession(of request: OpenSessionRequest) {
        guard let id = request.existingSessionID else { return }
        select(id)
    }
}
