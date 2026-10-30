import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

/// `searchSessions` (one search for every list) and `listedSession` (one row for a patch) against the
/// per-list `sessionPage` reads they replace.
@Suite(.serialized)
struct SessionCatalogSearchTests {
    struct World {
        let root: URL
        let catalog: SessionCatalog
        let projects: [CatalogProject]
        var ids: [UUID?: [UUID]] = [:]
    }

    /// Projects with 130, 20 and 0 matching sessions, a project with only a non-matching one, and loose sessions.
    private func makeWorld() async throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-search-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var projects: [CatalogProject] = []
        var world = World(root: root, catalog: catalog, projects: [])
        var clock = 0.0
        for (index, matching) in [130, 20, 0, 0].enumerated() {
            let folder = root.appendingPathComponent("p\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await catalog.addProject(path: folder.path).project
            projects.append(project)
            let count = index == 3 ? 1 : matching
            for item in 0..<count {
                clock += 1
                let id = UUID()
                try await catalog.insertSession(
                    ManagedSession(id: id, provider: .claude, workingDirectory: folder.path),
                    title: index == 3 ? "Other" : "Needle \(item)", createdAt: Date(timeIntervalSince1970: 1_000 + clock),
                    lastUsedAt: Date(timeIntervalSince1970: 5_000 + Double((item * 7) % 31)), lifecycle: .idle,
                    projectID: project.id)
                world.ids[project.id, default: []].append(id)
            }
        }
        for item in 0..<5 {
            clock += 1
            let id = UUID()
            try await catalog.insertSession(
                ManagedSession(id: id, provider: .claude, workingDirectory: root.path), title: "Loose needle \(item)",
                createdAt: Date(timeIntervalSince1970: 1_000 + clock), lastUsedAt: Date(timeIntervalSince1970: 5_000), lifecycle: .idle)
            world.ids[nil, default: []].append(id)
        }
        return World(root: root, catalog: catalog, projects: projects, ids: world.ids)
    }

    @Test func creationOrderSearchHoldsEachProjectsOwnFirstPageAndItsCursor() async throws {
        let world = try await makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let result = try await world.catalog.searchSessions(search: "needle", order: .creation, groupLimit: 100)
        let groups: [(UUID?, CatalogScope)] = world.projects.map { ($0.id, .project($0.id)) } + [(nil, .unassigned)]
        for (group, scope) in groups {
            let own = try await world.catalog.sessionPage(CatalogQuery(scope: scope, order: .creation, search: "needle"))
            let mine = result.sessions.filter { $0.projectID == group }
            #expect(mine.map(\.session.id) == own.sessions.map(\.session.id), "group \(String(describing: group))")
            #expect(result.nextByProject[group] == own.next)
        }
        #expect(result.nextByProject[world.projects[0].id] != nil, "130 matches: more than one page")
        #expect(result.nextByProject.count == 1)
        // Merged newest first, like the single scan it replaces.
        #expect(result.sessions.map(\.createdAt) == result.sessions.map(\.createdAt).sorted(by: >))
        #expect(result.next == nil)
    }

    @Test func activityOrderSearchIsTheFirstPageOfTheWholeCatalog() async throws {
        let world = try await makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let result = try await world.catalog.searchSessions(search: "NEEDLE", order: .recentActivity, groupLimit: 100)
        let page = try await world.catalog.sessionPage(CatalogQuery(scope: .all, order: .recentActivity, search: "NEEDLE"))
        #expect(result.sessions == page.sessions)
        #expect(result.next == page.next && result.next != nil)
        #expect(result.nextByProject.isEmpty)
        let deeper = try await world.catalog.searchSessions(search: "needle", order: .recentActivity, groupLimit: 40)
        #expect(deeper.sessions.count == 40)
    }

    @Test func aResultCutAtTheRowCapGivesEveryGroupACursorToReadOn() async throws {
        let world = try await makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let result = try await world.catalog.searchSessions(search: "needle", order: .creation, groupLimit: 100, rowCap: 12)
        #expect(result.sessions.count == 12)
        let groups = Set(result.sessions.map(\.projectID))
        #expect(Set(result.nextByProject.keys) == groups)
    }

    @Test func searchAndSingleReadsLeaveOutASessionBeingDeleted() async throws {
        let world = try await makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let doomed = try #require(world.ids[world.projects[1].id]?.first)
        let kept = try #require(world.ids[world.projects[1].id]?.last)
        #expect(try await world.catalog.listedSession(id: doomed)?.session.id == doomed)
        try await world.catalog.beginDeletion(
            sessionID: doomed, plan: CatalogDeletionPlan(provider: .claude, providerIDs: [], configDirectory: nil, workingDirectory: nil))
        #expect(try await world.catalog.listedSession(id: doomed) == nil)
        #expect(try await world.catalog.listedSession(id: kept)?.session.id == kept)
        #expect(try await world.catalog.listedSession(id: UUID()) == nil)
        for order in [CatalogOrder.creation, .recentActivity] {
            let result = try await world.catalog.searchSessions(search: "needle", order: order, groupLimit: 200)
            #expect(!result.sessions.contains { $0.session.id == doomed })
            #expect(result.sessions.contains { $0.session.id == kept })
        }
    }

    @Test func aCancelledSearchDoesNotScanAndThrowsCancellation() async throws {
        let world = try await makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let catalog = world.catalog
        let task = Task { () -> Bool in
            // Cancelled before the catalog is asked: the read must refuse instead of scanning.
            await waitFor("the test to cancel the search") { Task.isCancelled }
            do {
                _ = try await catalog.searchSessions(search: "needle", order: .creation, groupLimit: 100)
                return false
            } catch is CancellationError {
                return true
            }
        }
        task.cancel()
        #expect(try await task.value)
        let fresh = try await catalog.searchSessions(search: "needle", order: .creation, groupLimit: 100)
        #expect(!fresh.sessions.isEmpty)
    }
}
