import Foundation
import LoomCore

/// A settled search is one query over the whole catalog; the result is grouped into the visible lists in
/// memory (the project view by project in creation order, the activity view as one list in activity order).
/// The old way ran a scan per visible list, collapsed projects included.
extension CatalogModel {
    func reloadSearchResults() async {
        guard let catalog else { return }
        let term = trimmedSearch
        let order: CatalogOrder = viewMode == .activity ? .recentActivity : .creation
        let keys = visibleListKeys()
        let visible = keys.map { list(for: $0) }
        searchGeneration += 1
        let generation = searchGeneration
        for list in visible {
            list.generation += 1 // a "load more" page read for the previous result is outdated now
            list.activeReloads += 1
        }
        defer { for (key, list) in zip(keys, visible) { endReload(of: list, key) } }
        // As deep as the user had scrolled, at least a page, so a refresh never throws them back to the top.
        let depth = max(CatalogQuery.maxPageSize, visible.map(\.rows.count).max() ?? 0)
        do {
            statistics.pageQueries += 1
            statistics.searchQueries += 1
            let result = try await catalog.searchSessions(search: term, order: order, groupLimit: depth)
            await ensureBranches(for: result.sessions)
            await ensureOrigins(for: result.sessions)
            await afterSearchRead?()
            // A newer search (or a newer text) owns the lists now.
            guard generation == searchGeneration, term == trimmedSearch else { return }
            advanceNow(covering: result.sessions)
            var byProject: [UUID?: [CatalogSession]] = [:]
            if order == .creation {
                for record in result.sessions { byProject[record.projectID, default: []].append(record) }
            }
            for (key, list) in zip(keys, visible) {
                let records: [CatalogSession]
                let cursor: CatalogCursor?
                switch key {
                case .activity: (records, cursor) = (result.sessions, result.next)
                case let .project(id): (records, cursor) = (byProject[id] ?? [], result.nextByProject[id])
                case .unassigned: (records, cursor) = (byProject[nil] ?? [], result.nextByProject[nil])
                }
                list.replace(rows: records.map(row(for:)), cursor: cursor)
            }
        } catch is CancellationError {
            return // a newer keystroke cancelled this read
        } catch {
            report(error, "Sessions could not be read")
        }
    }
}
