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

/// The subagent panel (FB4-5, P1): a click on a subagent row shows its transcript in place of the terminal.
/// The terminal stays with its controller and keeps running; only the detail pane stops showing it.
extension CatalogModel {
    /// Selects the subagent's session if needed and opens its transcript. A subagent the session's live state
    /// does not list (it dropped out meanwhile) opens nothing.
    public func openSubagent(_ agentID: String, in sessionID: UUID) {
        guard let record = liveStates[sessionID]?.subagents.first(where: { $0.id == agentID }) else { return }
        // A second click on the subagent already shown changes nothing: its panel goes on reading.
        if viewedSubagent == ViewedSubagent(sessionID: sessionID, agentID: agentID), subagentPanel != nil { return }
        // Selecting closes a panel that is open, so this is also how one subagent's panel gives way to the next.
        select(sessionID, revealInList: false)
        let panel = SubagentTranscriptModel(
            agentID: agentID, transcriptPath: record.transcriptPath, isRunning: record.isRunning,
            windowVisible: windowIsVisible,
            locate: { [weak self] path in await self?.intents?.subagentTranscript(path: path, agentID: agentID) })
        subagentPanel = panel
        viewedSubagent = ViewedSubagent(sessionID: sessionID, agentID: agentID)
    }

    /// Back to the session's terminal (Esc, the Session control, and every other way out).
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
