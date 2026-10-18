import Foundation
import LoomChat
import LoomCore

/// Which face owns a session (V19). The owner is the runtime's persisted fact, never a view flag: while a run lives it
/// is the run's endpoint, afterwards it is the endpoint of the session's latest run, kept in the catalog
/// (`CatalogSession.runEndpoint`). A stopped session resumes in the face that owned it; only a handover (or Settings →
/// "New sessions start in", for a session that does not exist yet) changes it.
extension CatalogModel {
    /// The face that owns the session now. Nil for a session that has not run since faces were recorded (V16): it
    /// resumes in the terminal, as before.
    public func owningFace(of row: SessionRowModel) -> SessionFace? {
        if let endpoint = runEndpoint(of: row) { return SessionFace(endpoint: endpoint) }
        return row.record.runEndpoint.map(SessionFace.init(endpoint:))
    }

    /// The owning face of a session by id (the model has its row, or the live record).
    public func owningFace(of sessionID: UUID) -> SessionFace? {
        guard let row = rowModels[sessionID] else { return liveRecords[sessionID]?.runEndpoint.map(SessionFace.init(endpoint:)) }
        return owningFace(of: row)
    }

    /// A stopped Claude session that the Chat face owns shows its live chat, composer included: typing and sending
    /// resumes it in that face. Needs the Chat host, no run of any kind, and an identity to resume by.
    func showsStoppedLiveChat(_ row: SessionRowModel) -> Bool {
        guard chatSessions != nil, row.record.session.provider == .claude, !isRunning(row),
              owningFace(of: row) == .chat else { return false }
        let identity = row.live?.conversationID ?? row.record.session.providerConversationID
        return identity?.isEmpty == false
    }
}

// MARK: Evidence

extension CatalogModel {
    /// The owning face of the sessions the activity list shows, as "<id>:<chat|terminal|none>" (evidence).
    public var activityOwningFaces: [String] {
        list(for: .activity).rows.prefix(24).map { "\($0.id.uuidString):\(owningFace(of: $0)?.rawValue ?? "none")" }.sorted()
    }
}
