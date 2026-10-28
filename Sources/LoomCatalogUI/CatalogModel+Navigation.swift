import AppKit
import Foundation
import LoomCore
import LoomTerminal

/// Keyboard navigation between sessions, the Dock badge's count and the sidebar following the selection (D-45).
extension CatalogModel {
    // MARK: Sessions that need the user

    /// Every live session whose record is known, as the attention order reads it. A row that is only
    /// loaded (no live state) is History and never needs the user, so the live states are the whole set;
    /// the awaiting rule is the one `SessionRowModel.indicator` and the project dots apply.
    ///
    /// A failed turn is read once the user has looked at it, the way a finished turn is: the card keeps its red
    /// dot, but it leaves this set (the Dock badge, Home's lists, the jump shortcut), as it leaves the sidebar's
    /// Active section. One rule for "not read" on every surface (UI-MAP, Active).
    func attentionCandidates() -> [AttentionCandidate] {
        liveStates.compactMap { id, state in
            // A side chat that waits for the user raises nothing here (the Dock badge, Home, the menu bar and the
            // notifications all read this set): the Side tab shows it.
            guard let record = rowModels[id]?.record ?? liveRecords[id], !record.isSideChat else { return nil }
            let indicator = SessionIndicator(record: record, live: state,
                                             awaitingOpenApproval: awaitingOpenApproval.contains(id))
            if case .failed = indicator, state.activePhase != .endedUnread { return nil }
            // Work a finished turn left running counts for Quit only (D-103); the indicator says Ready.
            let background = state.runID != nil && state.status?.activity == .turnComplete
                ? state.status?.pendingProviderWorkCount ?? 0 : 0
            return AttentionCandidate(id: id, indicator: indicator, lastActivityAt: record.lastActivityAt,
                                      backgroundWork: background)
        }
    }

    /// The sessions that need the user, most urgent first (`AttentionOrder`).
    public func sessionsNeedingAttention() -> [UUID] { AttentionOrder.ordered(attentionCandidates()) }

    /// Sessions that are Working, Need approval or run background work after their turn: what quitting would interrupt.
    public func busySessionCount() -> Int { QuitConfirmation.busyCount(attentionCandidates()) }

    public var canJumpToAttention: Bool { !sessionsNeedingAttention().isEmpty }

    /// "Jump to Next/Previous Session That Needs You". Selecting loads the row when no list holds it.
    @discardableResult
    public func jumpToAttention(_ direction: StepDirection) -> Bool {
        guard let target = AttentionOrder.neighbor(of: selectedSessionID, in: sessionsNeedingAttention(), direction)
        else { return false }
        select(target)
        return true
    }

    /// Recomputes the count behind the Dock badge; called wherever a live state, a record or an
    /// open-session wait changes, never on a timer.
    func updateAttentionCount() {
        let candidates = attentionCandidates()
        let count = AttentionOrder.count(candidates)
        if count != attentionCount {
            attentionCount = count
            onAttentionCountChange?(count)
        }
        let summary = MenuBarSummary.derive(candidates)
        if workingSessionCount != summary.working { workingSessionCount = summary.working }
        if summary != menuBarSummary {
            menuBarSummary = summary
            onMenuBarChange?(summary)
        }
    }

    // MARK: The menu bar item

    /// The sessions the menu bar menu lists, with the titles and projects as the cards show them. Built
    /// when the menu opens, never per frame. The set is the Dock's (`attentionCandidates`, one rule for
    /// "not read" on every surface, DESIGN §19) plus its working rows, which the badge never counts.
    func menuBarEntries() -> [MenuBarEntry] {
        attentionCandidates().compactMap { candidate in
            guard ProjectAttention(candidate.indicator) != nil || candidate.indicator == .working else { return nil }
            guard let record = rowModels[candidate.id]?.record ?? liveRecords[candidate.id] else { return nil }
            let project = projectName(for: record)
            return MenuBarEntry(id: candidate.id, indicator: candidate.indicator,
                                lastActivityAt: candidate.lastActivityAt,
                                title: record.displayTitle(projectName: project), project: project)
        }
    }

    /// The menu bar's menu: New Claude Session where the model offers it (C2B).
    public func menuBarState() -> MenuBarState {
        MenuBarState.derive(menuBarEntries(), offersNewSession: offersNewSession(.newSessionDefault))
    }

    /// A session's title and project as a notification prints them; nil when its record is not known.
    public func titleAndProject(of id: UUID) -> (title: String, project: String?)? {
        guard let record = rowModels[id]?.record ?? liveRecords[id] else { return nil }
        let project = projectName(for: record)
        return (record.displayTitle(projectName: project), project)
    }

    /// The name of the session's harness as a notification speaks it; the default harness's when its record is not known.
    public func harnessName(of id: UUID) -> String {
        capabilities(of: knownProvider(of: id) ?? liveRecords[id]?.session.provider ?? .newSessionDefault).displayName
    }

    /// What the first request that waits for this session is (an approval, a question or a plan), whichever provider and
    /// face asked it: the notification's wording.
    public func firstWaitingRequestKind(of id: UUID) -> ProviderPendingRequest.Kind? {
        liveStates[id]?.waitingRequests.first?.kind
    }

    // MARK: Select next and previous

    /// The sessions in the order the current view draws them: the activity list's Active rows, then its day
    /// sections (`ActivityLayout`, the one order the list draws); in the project
    /// view the projects in their order (a collapsed project contributes nothing unless a search forces
    /// it open), then the projectless "Sessions" group.
    public func visibleSessionIDs() -> [UUID] {
        switch viewMode {
        case .activity:
            return activityLayout().rowIDs
        case .projects:
            var ids: [UUID] = []
            for project in projects {
                let rows = list(for: .project(project.id)).rows
                if isSearching ? !rows.isEmpty : !project.collapsed { ids += rows.map(\.id) }
            }
            return ids + list(for: .unassigned).rows.map(\.id)
        }
    }

    public func adjacentSession(_ direction: StepDirection) -> UUID? {
        VisibleOrder.neighbor(of: selectedSessionID, in: visibleSessionIDs(), direction)
    }

    public func canSelectAdjacentSession(_ direction: StepDirection) -> Bool { adjacentSession(direction) != nil }

    /// "Select Next/Previous Session": one step through the list as drawn, never wrapping.
    @discardableResult
    public func selectAdjacentSession(_ direction: StepDirection) -> Bool {
        guard let target = adjacentSession(direction) else { return false }
        select(target)
        return true
    }

    // MARK: The sidebar follows the selection

    func requestReveal(_ id: UUID) {
        revealTask = Task { [weak self] in await self?.reveal(id) }
    }

    /// Expands the session's project when it is collapsed, then asks the sidebar to scroll to its card.
    /// A card that is not loaded (outside the pages read so far) is skipped: nothing is paged for it.
    func reveal(_ id: UUID) async {
        var record = rowModels[id]?.record
        if record == nil, let catalog { record = try? await catalog.session(id: id) }
        guard selectedSessionID == id, let record else { return }
        if viewMode == .projects, !isSearching, let projectID = record.projectID,
           projects.first(where: { $0.id == projectID })?.collapsed == true {
            await expandProject(projectID)
        }
        guard selectedSessionID == id, visibleSessionIDs().contains(id) else { return }
        revealSerial &+= 1
        revealRequest = SessionRevealRequest(id: id, serial: revealSerial)
    }
}

// MARK: Ended screens

extension ConversationIntents {
    public func endedScreen(sessionID: UUID) -> TerminalScreenSnapshot? { nil }
    public func closeEndedScreen(sessionID: UUID) {}
}

extension ConversationIntents {
    public func subagentTranscript(path: String, agentID: String) async -> SubagentTranscriptFile? { nil }
    public func toolchainVersion(provider: ManagedSession.Provider) async -> String? { nil }
}
