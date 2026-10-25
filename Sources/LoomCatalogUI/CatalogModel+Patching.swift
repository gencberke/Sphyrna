import Foundation
import LoomCore

/// A frame about one session the lists already show changes one catalog row (its lifecycle, use or activity
/// time). That row is read once and patched into the lists, instead of re-reading every visible list from the
/// top. Everything else (a batch, a skipped frame, a session no list shows, a search, any failed read) keeps
/// the full refresh.
extension CatalogModel {
    /// Whether one row's patch can stand in for the full refresh: a visible list shows the session, no
    /// search is open (its results are re-read as a whole) and no refresh is running (it re-reads everything).
    func canPatchRow(_ id: UUID) -> Bool {
        guard !isSearching, refreshTask == nil else { return false }
        return visibleListKeys().contains { lists[$0]?.rows.contains { $0.id == id } == true }
    }

    /// Waits as long as `scheduleRefresh` does (the catalog write behind a run frame may land just after the
    /// frame) and coalesces the frames of that time into one read per session.
    func schedulePatch(_ id: UUID) {
        pendingPatches.insert(id)
        guard patchTask == nil else { return }
        patchTask = Task { [weak self] in
            repeat {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                let ids = self.pendingPatches
                self.pendingPatches = []
                await self.patchRows(ids)
            } while self?.pendingPatches.isEmpty == false
            self?.patchTask = nil
        }
    }

    /// Reads each session once. A session that cannot be read, is gone or is being deleted, or whose lists
    /// cannot take the patch, hands the whole job to a full refresh.
    private func patchRows(_ ids: Set<UUID>) async {
        guard let catalog else { return }
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard refreshTask == nil else { return } // that refresh re-reads every row
            statistics.pageQueries += 1
            let record: CatalogSession?
            do { record = try await catalog.listedSession(id: id) }
            catch { scheduleRefresh(); return }
            if let record {
                await ensureBranches(for: [record])
                await ensureOrigins(for: [record])
            }
            guard refreshTask == nil else { return }
            guard let record, applyPatch(record) else { scheduleRefresh(); return }
            statistics.rowPatches += 1
        }
        refreshCardModels() // a live change of model is stored on the session
    }

    /// Puts the record into the row and the visible lists; false when a list cannot take it in place.
    private func applyPatch(_ record: CatalogSession) -> Bool {
        let id = record.session.id
        guard !isSearching, let row = rowModels[id] else { return false }
        let visible = visibleListKeys()
        let holding = visible.filter { lists[$0]?.rows.contains { $0.id == id } == true }
        guard !holding.isEmpty else { return false }
        for key in holding {
            switch key {
            case .activity: break
            case let .project(project): guard record.projectID == project else { return false }
            case .unassigned: guard record.projectID == nil else { return false }
            }
        }
        advanceNow(covering: [record])
        row.apply(record: record)
        // The project view keeps creation order, which no frame changes: the shared row model is the patch.
        if holding.contains(.activity), let list = lists[.activity] { reposition(row, in: list) }
        // Lists nobody sees re-read themselves when they are shown again.
        for (key, list) in lists where !visible.contains(key) { list.isStale = true }
        pruneRowModels()
        return true
    }

    /// Moves the row to where its activity time puts it (the top when it is the newest). A row that now sorts
    /// past the cursor leaves the loaded range: the next page, which starts at the cursor, delivers it. The
    /// cursor stays, so the list is still every row down to it.
    private func reposition(_ row: SessionRowModel, in list: SessionListModel) {
        let mine = Self.order(of: row.record)
        var rows = list.rows.filter { $0.id != row.id }
        let inside: Bool
        if list.hasMore, let cursor = list.cursor {
            inside = cursor.coversActivity(of: row.record)
        } else {
            inside = true
        }
        if inside {
            let index = rows.firstIndex { Self.sortsBefore(mine, Self.order(of: $0.record)) } ?? rows.count
            rows.insert(row, at: index)
        }
        list.setRows(rows)
    }

    /// The activity order's sort key: newest activity first, ties by session id, descending (as the SQL does).
    private static func order(of record: CatalogSession) -> (Double, String) {
        (record.lastActivityAt.timeIntervalSince1970, record.session.id.uuidString)
    }

    private static func sortsBefore(_ lhs: (Double, String), _ rhs: (Double, String)) -> Bool {
        lhs.0 > rhs.0 || (lhs.0 == rhs.0 && lhs.1 > rhs.1)
    }
}
