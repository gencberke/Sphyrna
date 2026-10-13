#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// Subagent panel commands (FB4-5): the same model calls a click on a subagent row and Esc make.
///
/// - `open-subagent:<session id>:<agent id>`: selects the session and opens the subagent's transcript in place
///   of its terminal; nothing when the session's live state does not list that subagent.
/// - `close-subagent`: back to the terminal (Esc, the Session control).
///
/// The snapshot gains `subagentPanel{viewed, sessionID, agentID, entryCount, isRunning, isFeeding, phase}`;
/// `viewed` is the open agent's id, and null (the only key) while no panel is open.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not a subagent command.
    func handleSubagentCommand(_ name: String, _ argument: String) -> Bool {
        guard let model = app?.model else { return false }
        switch name {
        case "open-subagent":
            if argument.count > 37, let id = UUID(uuidString: String(argument.prefix(36))) {
                model.openSubagent(String(argument.dropFirst(37)), in: id)
            }
        case "close-subagent": model.closeSubagent()
        default: return false
        }
        return true
    }
}

extension AppDelegate {
    var subagentPanelEvidence: [String: Any] {
        guard let panel = model?.subagentPanelState else { return ["viewed": NSNull()] }
        return ["viewed": panel.agentID, "sessionID": panel.sessionID.uuidString, "agentID": panel.agentID,
                "entryCount": panel.entryCount, "isRunning": panel.isRunning, "isFeeding": panel.isFeeding,
                "phase": panel.phase]
    }
}
#endif
