import Foundation
import LoomCore

/// A subagent whose transcript is open (FB4-5): its session and Claude's id for it.
public struct ViewedSubagent: Equatable, Sendable {
    public let sessionID: UUID
    public let agentID: String
    /// Listed from the stopped session's folder (V23), not by a live run: the panel stays until a run starts.
    public let fromFolder: Bool

    public init(sessionID: UUID, agentID: String, fromFolder: Bool = false) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.fromFolder = fromFolder
    }
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
        guard let (record, fromFolder) = listedSubagent(agentID, in: sessionID) else { return }
        // A second click on the subagent already shown changes nothing: its panel goes on reading.
        if viewedSubagent == ViewedSubagent(sessionID: sessionID, agentID: agentID, fromFolder: fromFolder), subagentPanel != nil,
           inspector.isOpen(for: sessionID), inspector.tab == .agents { return }
        // Selecting closes a panel that is open, so this is also how one subagent's panel gives way to the next.
        select(sessionID, revealInList: false)
        let panel = SubagentTranscriptModel(
            agentID: agentID, transcriptPath: record.transcriptPath, isRunning: record.isRunning,
            windowVisible: windowIsVisible,
            locate: { [weak self] path in await self?.intents?.subagentTranscript(path: path, agentID: agentID) })
        subagentPanel = panel
        viewedSubagent = ViewedSubagent(sessionID: sessionID, agentID: agentID, fromFolder: fromFolder)
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

    /// The subagent the Agents tab lists under this id, and whether the list is the stopped session's folder: the live run's
    /// ledger while the session has a run, else the folder's list as it was read.
    func listedSubagent(_ agentID: String, in sessionID: UUID) -> (record: SubagentRecord, fromFolder: Bool)? {
        if liveStates[sessionID]?.runID != nil {
            return liveStates[sessionID]?.subagents.first { $0.id == agentID }.map { ($0, false) }
        }
        guard let row = rowModels[sessionID] ?? (selectedRow?.id == sessionID ? selectedRow : nil),
              let records = agentRecords(for: row) else { return nil }
        return records.first { $0.id == agentID }.map { ($0, true) }
    }

    /// The record the open panel shows.
    func viewedSubagentRecord() -> SubagentRecord? {
        guard let viewed = viewedSubagent else { return nil }
        return listedSubagent(viewed.agentID, in: viewed.sessionID)?.record
    }

    /// The viewed session's live state changed: the panel follows its subagent, and closes when the subagent
    /// dropped out of the list (the next real prompt) or the run ended (the list is empty then too). A stopped
    /// session's entry has no run to follow: it stays until a run starts and the live list takes over.
    func syncViewedSubagent(with state: SessionViewState?) {
        guard let viewed = viewedSubagent else { return }
        if viewed.fromFolder {
            if state?.runID != nil { closeSubagent() }
            return
        }
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

/// A subagent that waits for the user, as the Agents tab, the sidebar tree and the open subagent's notice say it (V23).
enum SubagentWaiting {
    /// The subagents whose request waits:
    /// - the Chat face: the hub's pending requests that name an agent (the driver fills it from the request's `agent_id`); a
    ///   main-thread request names none, so it marks no subagent;
    /// - the terminal face has no hub request: the ledger marks the subagent the `PermissionRequest` hook named
    ///   (`SubagentRecord.awaitsApproval`). A Chat-face run ignores that mark, because only its driver knows when a card ends.
    static func ids(in state: SessionViewState?) -> Set<String> {
        guard let state else { return [] }
        var ids = Set(state.pendingRequests.compactMap { $0.agent?.id })
        if state.runEndpoint != .pipe { ids.formUnion(state.subagents.filter(\.awaitsApproval).map(\.id)) }
        return ids
    }

    /// Where the open subagent's request is answered.
    enum Notice: Equatable {
        /// In the chat: its card is pinned in the main chat ("Show the request" brings it into view).
        case chat
        /// In the session's terminal, which stays on screen beside the inspector.
        case terminal

        var text: String {
            switch self {
            case .chat: "Waiting for you: answer it in the chat"
            case .terminal: "Waiting for approval: answer it in the session's terminal"
            }
        }
    }

    /// The notice for the subagent open in the Agents tab, nil when nothing waits on it:
    /// - the Chat face knows the asker: the notice shows on the subagent whose request waits, and on no other;
    /// - the terminal face knows it when the hook named the subagent: the notice shows on that one;
    /// - when no hook did and the session still waits (only Claude's registry says so, no request was reported), the request
    ///   cannot be tied to a main-thread one: the notice shows on the running open subagent, as it always did.
    static func notice(agentID: String, record: SubagentRecord?, state: SessionViewState?, indicator: SessionIndicator,
                       endpoint: RunEndpointKind?) -> Notice? {
        if state?.pendingRequests.contains(where: { $0.agent?.id == agentID }) == true { return .chat }
        guard endpoint == .terminal else { return nil }
        if ids(in: state).contains(agentID) { return .terminal }
        guard indicator == .waitingForApproval, state?.reason == nil, record?.isRunning == true,
              state?.subagents.contains(where: \.awaitsApproval) != true else { return nil }
        return .terminal
    }
}

extension CatalogModel {
    /// "Show the request": brings the pinned card of the request this subagent asked into view in the session's main chat.
    /// False when the session has no live chat or no waiting request names the subagent.
    @discardableResult
    func showAgentRequest(agentID: String, in sessionID: UUID) -> Bool {
        guard let driver = liveChatDriver(for: sessionID),
              let feed: LiveChatFeed = chatSessions?.existingAttachment(for: driver) else { return false }
        return feed.cards.reveal(agentID: agentID)
    }
}
