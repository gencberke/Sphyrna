import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// The project list's moves (W3-c): Move Up/Move Down and the live drag's release (A1, FB7-3) reach the same
/// `moveProject`, and the order persists. The suite keeps its old name because the brief's check line names it; the
/// pasteboard drag it was written for is gone.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ProjectDragTests {
    /// A release in a gap moves the project once; its own place and a release outside the list change nothing.
    @Test func aReleaseInAGapMovesTheProjectOnceAndItsOwnPlaceChangesNothing() async throws {
        let (model, ids, root, cleanup) = try await rig(["a", "b", "c"])
        defer { cleanup(); model.stop() }
        #expect(model.projects.map(\.id) == ids)
        // a down to gap 2 (after b): b, a, c.
        await model.endProjectReorder(ids[0], gap: 2)
        #expect(model.projects.map(\.id) == [ids[1], ids[0], ids[2]])
        // a down to gap 3 (after c): b, c, a.
        await model.endProjectReorder(ids[0], gap: 3)
        #expect(model.projects.map(\.id) == [ids[1], ids[2], ids[0]])
        // Its own place, before or after itself: nothing moves (a stands last now).
        await model.endProjectReorder(ids[0], gap: 2)
        await model.endProjectReorder(ids[0], gap: 3)
        #expect(model.projects.map(\.id) == [ids[1], ids[2], ids[0]])
        // A release outside the list cancels.
        await model.endProjectReorder(ids[0], gap: nil)
        #expect(model.projects.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func movingAProjectToTheStartTheMiddleAndTheEndPersistsAcrossAReload() async throws {
        let (model, ids, root, cleanup) = try await rig(["a", "b", "c", "d"])
        defer { cleanup(); model.stop() }
        #expect(model.projects.map(\.id) == ids)
        await model.moveProject(ids[2], to: 0)
        #expect(model.projects.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
        await model.moveProject(ids[2], to: 2)
        #expect(model.projects.map(\.id) == [ids[0], ids[1], ids[2], ids[3]])
        await model.moveProject(ids[0], to: 99)
        #expect(model.projects.map(\.id) == [ids[1], ids[2], ids[3], ids[0]])
        // A release in the gap before head 1 (b, c, d, a): d moves up to place 1.
        await model.endProjectReorder(ids[3], gap: 1)
        #expect(model.projects.map(\.id) == [ids[1], ids[3], ids[2], ids[0]])
        // Move Up and Move Down still step by one.
        await model.moveProject(ids[0], by: -1)
        #expect(model.projects.map(\.id) == [ids[1], ids[3], ids[0], ids[2]])

        let reopened = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        #expect(try await reopened.projects().map(\.id) == [ids[1], ids[3], ids[0], ids[2]])
    }

    private func rig(_ names: [String]) async throws -> (CatalogModel, [UUID], URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-projects-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var ids: [UUID] = []
        for name in names {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ids.append(try await catalog.addProject(path: folder.path).project.id)
        }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        return (model, ids, root, { try? FileManager.default.removeItem(at: root) })
    }
}
