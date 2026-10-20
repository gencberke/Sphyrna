import Foundation
import LoomCore

/// What the activity list draws, in the order it draws it: the Active rows, then the day sections without them.
struct ActivityLayout {
    let active: [SessionRowModel]
    let days: [DaySection]

    /// The row drawn last; paging triggers when it appears (it may sit in Active when nothing else is loaded).
    var lastRowID: UUID? { days.last?.rows.last?.id ?? active.last?.id }

    var rowIDs: [UUID] { active.map(\.id) + days.flatMap { $0.rows.map(\.id) } }
}

/// The Active section of the activity view (FB4-2): sessions with a live run whose turn is under way or whose
/// end the user has not read, plus a session whose agent waits for an open-session answer (D-40).
extension CatalogModel {
    /// One O(1) check per live frame. Only the Active set, never a card, is touched here: a membership flip
    /// moves `activeRevision` (one regroup), anything else costs a set lookup.
    func updateActive(_ id: UUID) {
        let live = liveStates[id]
        // A side chat is never in Active (it has no row; the Side tab shows it).
        let member = live?.runID != nil && (live?.activePhase != .inactive || awaitingOpenApproval.contains(id))
            && (rowModels[id]?.record ?? liveRecords[id])?.isSideChat != true
        if live?.runID == nil, heldActiveID == id {
            heldActiveID = nil // a run that ended is out, even when it was the selected one
        } else if member, id == selectedSessionID {
            heldActiveID = id
        }
        let shown = member || heldActiveID == id
        let changed = shown ? activeIDs.insert(id).inserted : activeIDs.remove(id) != nil
        if changed { activeRevision &+= 1 }
        rowModels[id]?.apply(active: shown)
    }

    /// The selection moved: the held session goes (it stays only if it is a member), and a selected member is
    /// held from now on.
    func moveActiveHold(to id: UUID?) {
        let released = heldActiveID
        heldActiveID = nil
        if let released { updateActive(released) }
        if let id { updateActive(id) }
    }

    /// While searching the list is the plain result in activity order: no Active section.
    func activityLayout() -> ActivityLayout {
        let list = list(for: .activity)
        guard !isSearching else { return ActivityLayout(active: [], days: list.daySections(today: today)) }
        let revision = activeRevision
        return ActivityLayout(
            active: list.activeRows(activeIDs: activeIDs, activeRevision: revision),
            days: list.daySections(today: today, activeIDs: activeIDs, activeRevision: revision))
    }
}
