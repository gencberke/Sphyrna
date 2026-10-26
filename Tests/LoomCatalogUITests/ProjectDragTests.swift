import AppKit
import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// W3-c: projects reordered by drag; FB6-4: the whole block of a project is the target. The payload refuses sessions, the gap maps to the project's final place, and the
/// model's move persists in the catalog's order.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ProjectDragTests {
    @Test func theHeadsTakeAProjectAndRefuseASessionOrText() async {
        let id = UUID()
        let project = ProjectDrag.itemProvider(for: id)
        #expect(ProjectDrag.accepts([project]))
        #expect(await ProjectDrag.projectID(from: [project]) == id)
        let session = SessionDrag.itemProvider(for: id, title: "A session")
        let text = NSItemProvider(object: id.uuidString as NSString)
        #expect(!ProjectDrag.accepts([session]) && !ProjectDrag.accepts([text]) && !ProjectDrag.accepts([]))
        #expect(await ProjectDrag.projectID(from: [session, text]) == nil)
        #expect(!SessionDrag.accepts([project]), "and a project is not a session")
    }

    @Test func aDropOnABlockTakesItsPlaceWhicheverPartOfItItLandsOn() {
        #expect(ProjectDrag.gap(onBlock: 2, from: 0) == 3, "from above: after the block")
        #expect(ProjectDrag.gap(onBlock: 2, from: 3) == 2, "from below: before it")
        #expect(ProjectDrag.gap(onBlock: 2, from: 2) == nil, "its own block: nothing moves")
        #expect(ProjectDrag.gap(onBlock: 2, from: nil) == 2, "with the source unknown: before it")
        // A project moving down leaves its own place first.
        #expect(ProjectDrag.position(forGap: 3, from: 0) == 2)
        #expect(ProjectDrag.position(forGap: 0, from: 2) == 0)
        #expect(ProjectDrag.position(forGap: 1, from: 1) == 1 && ProjectDrag.position(forGap: 2, from: 1) == 1)
    }

    /// RESCUE C3: dragging a project onto the next expanded project's head did nothing, since the drop landed in the gap the
    /// project already stood in. It takes that head's place now, down as well as up, and the order persists.
    @Test func aProjectDroppedOnTheNextExpandedProjectTakesItsPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-projects-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: url)
        var ids: [UUID] = []
        for name in ["a", "b", "c"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ids.append(try await catalog.addProject(path: folder.path).project.id)
        }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        defer { model.stop() }
        await model.start()
        #expect(model.projects.allSatisfy { !$0.collapsed })
        // a onto b's block, from above: a, b, c → b, a, c.
        await model.dropProject(ids[0], onBlock: ids[1])
        #expect(model.projects.map(\.id) == [ids[1], ids[0], ids[2]])
        // c onto a's block, from below: b, a, c → b, c, a.
        await model.dropProject(ids[2], onBlock: ids[0])
        // A project on its own block stays where it is.
        await model.dropProject(ids[2], onBlock: ids[2])
        #expect(model.projects.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(try await SessionCatalog(url: url).projects().map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func movingAProjectToTheStartTheMiddleAndTheEndPersistsAcrossAReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-projects-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: url)
        var ids: [UUID] = []
        for name in ["a", "b", "c", "d"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ids.append(try await catalog.addProject(path: folder.path).project.id)
        }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        defer { model.stop() }
        await model.start()
        #expect(model.projects.map(\.id) == ids)
        await model.moveProject(ids[2], to: 0)
        #expect(model.projects.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
        await model.moveProject(ids[2], to: 2)
        #expect(model.projects.map(\.id) == [ids[0], ids[1], ids[2], ids[3]])
        await model.moveProject(ids[0], to: 99)
        #expect(model.projects.map(\.id) == [ids[1], ids[2], ids[3], ids[0]])
        // A drop in the gap before head 1 (b, c, d, a): d moves up to place 1.
        await model.dropProject(ids[3], gap: 1)
        #expect(model.projects.map(\.id) == [ids[1], ids[3], ids[2], ids[0]])
        // Move Up and Move Down still step by one.
        await model.moveProject(ids[0], by: -1)
        #expect(model.projects.map(\.id) == [ids[1], ids[3], ids[0], ids[2]])

        let reopened = try SessionCatalog(url: url)
        #expect(try await reopened.projects().map(\.id) == [ids[1], ids[3], ids[0], ids[2]])
    }
}
