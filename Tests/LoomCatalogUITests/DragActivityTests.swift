import AppKit
import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// FB6-5: one value says what is dragged and which targets take it, so every target shows one of the three looks and a drag that
/// ends without a drop leaves nothing behind.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DragActivityTests {
    private func fresh() -> DragActivity {
        let activity = DragActivity.shared
        activity.end(why: "test")
        return activity
    }

    @Test func aDragIsActiveUntilADropOrTheEndOfTheDrag() {
        let activity = fresh()
        let id = UUID()
        activity.begin(.project, id)
        #expect(activity.active == .init(kind: .project, id: id) && activity.project == id && ProjectDrag.current == id)
        activity.end(why: "test")
        #expect(activity.active == nil && activity.project == nil && ProjectDrag.current == nil)
        activity.begin(.session, id)
        #expect(activity.project == nil, "a session is not a project")
        activity.end(why: "test")
    }

    @Test func theSourceIsDimmedOnlyWhileNothingUnderThePointerTakesTheDrag() {
        let activity = fresh()
        let id = UUID(), other = UUID()
        #expect(!activity.refuses(id), "no drag, no dimming")
        activity.begin(.session, id)
        #expect(activity.refuses(id) && !activity.refuses(other))
        activity.enter(DragActivity.tabs)
        #expect(!activity.refuses(id), "over a target that takes it")
        activity.leave(DragActivity.tabs)
        #expect(activity.refuses(id))
        activity.end(why: "test")
        #expect(!activity.refuses(id))
    }

    @Test func twoTargetsAreToldApartWhenThePointerMovesFromOneToTheNext() {
        let activity = fresh()
        let a = DragActivity.projectBlock(UUID()), b = DragActivity.projectBlock(UUID())
        activity.begin(.project, UUID())
        activity.enter(a)
        activity.enter(b)
        activity.leave(a)
        #expect(activity.over == [b], "the second one's enter before the first one's exit leaves it standing")
        activity.end(why: "test")
        #expect(activity.over.isEmpty)
    }

    @Test func theInsertionLineBelongsToTheBlockThatSetItAndEndsWithTheDrag() {
        let activity = fresh()
        let a = UUID(), b = UUID()
        activity.begin(.project, UUID())
        activity.mark(.init(projectID: a, after: true))
        activity.clearMark(of: b)
        #expect(activity.projectMark == .init(projectID: a, after: true), "another block's exit does not clear it")
        activity.clearMark(of: a)
        #expect(activity.projectMark == nil)
        activity.mark(.init(projectID: b, after: false))
        activity.end(why: "test")
        #expect(activity.projectMark == nil)
    }

    @Test func aDragWhoseButtonIsUpEndsByItself() async throws {
        let activity = fresh()
        activity.begin(.session, UUID())
        #expect(activity.active != nil)
        // No button is down under test: the watch calls the drag over after its settling beat.
        try await Task.sleep(for: .milliseconds(700))
        #expect(activity.active == nil, "a cancelled drag leaves nothing behind")
    }

    @Test func aBlockRefusesASessionAndTakesAProject() {
        let id = UUID()
        #expect(!ProjectDrag.accepts([SessionDrag.itemProvider(for: id, title: nil)]))
        #expect(ProjectDrag.accepts([ProjectDrag.itemProvider(for: id)]))
    }

    @Test func theBlockTargetsPlaceItBeforeOrAfterByWhereTheDragCameFrom() async throws {
        let (model, ids, cleanup) = try await rig()
        defer { cleanup(); model.stop() }
        #expect(model.projectDropGap(onBlock: ids[1], dragged: ids[0]) == 2, "from above: after the block")
        #expect(model.projectDropGap(onBlock: ids[1], dragged: ids[2]) == 1, "from below: before it")
        #expect(model.projectDropGap(onBlock: ids[1], dragged: ids[1]) == nil)
        #expect(model.projectDropGap(onBlock: UUID(), dragged: ids[0]) == nil, "a block that is gone")
    }

    private func rig() async throws -> (CatalogModel, [UUID], () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-drag-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var ids: [UUID] = []
        for name in ["a", "b", "c"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ids.append(try await catalog.addProject(path: folder.path).project.id)
        }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        return (model, ids, { try? FileManager.default.removeItem(at: root) })
    }
}
