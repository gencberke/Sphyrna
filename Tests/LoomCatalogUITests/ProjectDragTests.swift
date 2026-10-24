import AppKit
import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// W3-c: project heads reordered by drag. The payload refuses sessions, the gap maps to the project's final place, and the
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

    @Test func aDropOnAHeadLandsBeforeItOrAfterItOnlyWhereNothingFollows() {
        let row = LoomTheme.InkHeight.sidebarRow
        #expect(ProjectDrag.gap(onHead: 2, y: 4, height: row, canDropAfter: true) == 2)
        #expect(ProjectDrag.gap(onHead: 2, y: row - 4, height: row, canDropAfter: true) == 3)
        #expect(ProjectDrag.gap(onHead: 2, y: row - 4, height: row, canDropAfter: false) == 2, "an expanded head: before it")
        // A project moving down leaves its own place first.
        #expect(ProjectDrag.position(forGap: 3, from: 0) == 2)
        #expect(ProjectDrag.position(forGap: 0, from: 2) == 0)
        #expect(ProjectDrag.position(forGap: 1, from: 1) == 1 && ProjectDrag.position(forGap: 2, from: 1) == 1)
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
