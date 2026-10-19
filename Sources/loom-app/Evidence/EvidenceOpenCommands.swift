#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore

/// A session opens a session (D-40): the same model calls the request box's buttons make.
///
/// - `open-approve:<request id>`: "Open Session".
/// - `open-deny:<request id>`: "Deny".
/// - `open-dismiss:<request id>`: "Dismiss" on a failed request.
///
/// The snapshot gains `openRequests[{id, requester, phase, title, project, failure}]` (title and failure text are
/// empty for real-provider runs) and
/// `catalog.awaitingOpenApproval` (the requesting sessions whose card reads "Needs approval").
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not an open-session command.
    func handleOpenRequestCommand(_ name: String, _ argument: String) -> Bool {
        guard let model = app?.model else { return false }
        let id = UUID(uuidString: String(argument.prefix(36)))
        switch name {
        case "open-approve": if let id { model.approveOpenRequest(id) }
        case "open-deny": if let id { model.denyOpenRequest(id) }
        case "open-dismiss": if let id { model.dismissOpenRequest(id) }
        default: return false
        }
        return true
    }
}

extension AppDelegate {
    var openRequestsEvidence: [[String: Any]] {
        OpenRequestEvidence.rows(model?.openRequests ?? [], redacted: redactsContent)
    }
}
#endif
