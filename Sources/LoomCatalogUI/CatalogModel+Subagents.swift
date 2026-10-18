import Foundation
import LoomCore

/// A subagent whose transcript is open (FB4-5): its session and Claude's id for it.
public struct ViewedSubagent: Equatable, Sendable {
    public let sessionID: UUID
    public let agentID: String
}

/// What acceptance tooling reads about the open subagent panel.
public struct SubagentPanelState: Equatable, Sendable {
    public let sessionID: UUID
    public let agentID: String
    public let entryCount: Int
    public let isRunning: Bool
    public let isFeeding: Bool
    public let phase: String
}

/// The subagent panel (FB4-5, P1; V09): a click on a subagent row shows its transcript in the Agents tab of its
/// session's inspector. The terminal stays on screen beside it, untouched.
extension CatalogModel {
    /// Selects the subagent's session if needed, opens its inspector on the Agents tab and starts reading the
    /// subagent's transcript. A subagent the session's live state does not list (it dropped out meanwhile)
    /// opens nothing. Opening the inspector is the click's doing, so a terminal resizes once, here.
    public func openSubagent(_ agentID: String, in sessionID: UUID) {
        guard let record = liveStates[sessionID]?.subagents.first(where: { $0.id == agentID }) else { return }
        // A second click on the subagent already shown changes nothing: its panel goes on reading.
        if viewedSubagent == ViewedSubagent(sessionID: sessionID, agentID: agentID), subagentPanel != nil,
           inspector.isOpen(for: sessionID), inspector.tab == .agents { return }
        // Selecting closes a panel that is open, so this is also how one subagent's panel gives way to the next.
        select(sessionID, revealInList: false)
        let panel = SubagentTranscriptModel(
            agentID: agentID, transcriptPath: record.transcriptPath, isRunning: record.isRunning,
            windowVisible: windowIsVisible,
            locate: { [weak self] path in await self?.intents?.subagentTranscript(path: path, agentID: agentID) })
        subagentPanel = panel
        viewedSubagent = ViewedSubagent(sessionID: sessionID, agentID: agentID)
        _ = inspector.select(.agents)
        setInspectorOpen(true, for: sessionID)
    }

    /// Back to the list of agents (the inspector's back control, and every other way out).
    public func closeSubagent() {
        guard viewedSubagent != nil else { return }
        subagentPanel?.close()
        subagentPanel = nil
        viewedSubagent = nil
    }

    /// The record the open panel shows, from its session's live state.
    func viewedSubagentRecord() -> SubagentRecord? {
        guard let viewed = viewedSubagent else { return nil }
        return liveStates[viewed.sessionID]?.subagents.first { $0.id == viewed.agentID }
    }

    /// The viewed session's live state changed: the panel follows its subagent, and closes when the subagent
    /// dropped out of the list (the next real prompt) or the run ended (the list is empty then too).
    func syncViewedSubagent(with state: SessionViewState?) {
        guard let viewed = viewedSubagent else { return }
        guard let state, state.runID != nil,
              let record = state.subagents.first(where: { $0.id == viewed.agentID }) else {
            closeSubagent()
            return
        }
        subagentPanel?.setRunning(record.isRunning)
        subagentPanel?.setTranscriptPath(record.transcriptPath)
    }

    public var subagentPanelState: SubagentPanelState? {
        guard let viewed = viewedSubagent, let panel = subagentPanel else { return nil }
        return SubagentPanelState(
            sessionID: viewed.sessionID, agentID: viewed.agentID, entryCount: panel.entryCount,
            isRunning: panel.isRunning, isFeeding: panel.isFeeding, phase: String(describing: panel.phase))
    }
}
