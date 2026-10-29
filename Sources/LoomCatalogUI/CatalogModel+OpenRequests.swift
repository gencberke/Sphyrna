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
    /// The requests of one session's agent, in arrival order: the box above its terminal.
    public func openRequests(for sessionID: UUID) -> [OpenSessionRequest] {
        openRequests.filter { $0.requesterID == sessionID }
    }

    /// "Open Session". The new session appears in its project; the selection stays where it is.
    public func approveOpenRequest(_ id: UUID) {
        guard actionsAvailable else { return }
        intents?.approveOpen(requestID: id)
        if let request = openRequests.first(where: { $0.id == id }), request.send == nil,
           projects.first(where: { $0.id == request.projectID })?.collapsed == true {
            Task { [weak self] in await self?.expandProject(request.projectID) }
        }
    }

    /// "Deny": the agent's command is answered "denied" and nothing starts.
    public func denyOpenRequest(_ id: UUID) {
        guard actionsAvailable else { return }
        intents?.denyOpen(requestID: id)
    }

    /// "Dismiss" on a failed request.
    public func dismissOpenRequest(_ id: UUID) {
        guard actionsAvailable else { return }
        intents?.dismissOpen(requestID: id)
    }

    /// The session an approved request started, once a list holds it: the folded line's "Go to Session". The session takes
    /// the request's title and names its opener, and the newest match wins if an older session shares both.
    public func openedSession(openedBy requesterID: UUID, title: String) -> UUID? {
        let records = rowModels.values.map(\.record) + lists.values.flatMap { $0.rows.map(\.record) }
        return records
            .filter { $0.openedBy == requesterID && $0.title == title }
            .max { $0.createdAt < $1.createdAt }?
            .session.id
    }
}
