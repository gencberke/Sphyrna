#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// Subagent panel and inspector commands (FB4-5, V09): the same model calls a click on a subagent row, the
/// inspector's back control and its header toggle make.
///
/// - `open-subagent:<session id>:<agent id>`: selects the session, opens its inspector on the Agents tab and
///   reads the subagent's transcript there; nothing when the session's live state does not list that subagent.
/// - `close-subagent`: back to the list of agents.
/// - `inspector:<open|close|overview|agents>`: the selected session's inspector: the header toggle (open, close)
///   and the tabs (a tab also opens the inspector).
///
/// The snapshot gains `subagentPanel{viewed, sessionID, agentID, entryCount, isRunning, isFeeding, phase,
/// inspectorOpen, inspectorTab}`; `viewed` is the open agent's id, and null while no panel is open (the
/// inspector keys are there either way).
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
        case "inspector":
            guard let id = model.selectedSessionID else { break }
            switch argument {
            case "open": model.setInspector(open: true, for: id)
            case "close": model.setInspector(open: false, for: id)
            case "overview": model.setInspector(open: true, for: id); model.selectInspectorTab(.overview)
            case "agents": model.setInspector(open: true, for: id); model.selectInspectorTab(.agents)
            default: return false
            }
        default: return false
        }
        return true
    }
}

extension AppDelegate {
    var subagentPanelEvidence: [String: Any] {
        var state: [String: Any] = ["viewed": NSNull()]
        if let panel = model?.subagentPanelState {
            state = ["viewed": panel.agentID, "sessionID": panel.sessionID.uuidString, "agentID": panel.agentID,
                     "entryCount": panel.entryCount, "isRunning": panel.isRunning, "isFeeding": panel.isFeeding,
                     "phase": panel.phase]
        }
        state["inspectorOpen"] = model.map { $0.inspector.isOpen(for: $0.selectedSessionID) } ?? false
        state["inspectorTab"] = model?.inspector.tab.rawValue ?? NSNull()
        return state
    }
}
#endif
