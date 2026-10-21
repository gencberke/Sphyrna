import Foundation
import LoomChat
import LoomCore

/// Which face runs a session (V19, D-69). A live run is driven by its endpoint and keeps it until it stops. The face
/// of a start or a resume is the app-wide switch (Settings → General → "Sessions run in", `newSessionFace`); the
/// persisted endpoint of the latest run (`CatalogSession.runEndpoint`) only says how that run was driven. A handover
/// (the policy banner) moves a running session.
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

    /// A stopped Claude session shows its live chat, composer included, while the switch says Chat: typing and sending
    /// resumes it in that face. With the switch on Terminal it shows the terminal face's stopped screen. Needs the Chat
    /// host, no run of any kind, and an identity to resume by.
    func showsStoppedLiveChat(_ row: SessionRowModel) -> Bool {
        guard chatSessions != nil, capabilities(of: row.record.session.provider).structuredFace, !isRunning(row),
              newSessionFace == .chat else { return false }
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
