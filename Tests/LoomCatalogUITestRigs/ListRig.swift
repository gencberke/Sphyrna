import AppKit
import Foundation
import Observation
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// A catalog with several projects and sessions, a model started over it and a hand-fed event stream
/// (the model's own consumer is stopped, so each test applies exactly the frames it publishes).
@MainActor
final class ListRig {
    let root: URL
    let catalog: SessionCatalog
    let hub: SessionEventHub
    let model: CatalogModel
    private(set) var projects: [CatalogProject] = []
    /// Session ids by project (nil: no project), oldest first.
    private(set) var ids: [UUID?: [UUID]] = [:]
    var frames: FrameReader?

    init(root: URL, catalog: SessionCatalog, hub: SessionEventHub, model: CatalogModel) {
        self.root = root
        self.catalog = catalog
        self.hub = hub
        self.model = model
    }

    var everyID: [UUID] { ids.values.flatMap { $0 } }

    static func make(projects projectCount: Int, perProject: Int, unassigned: Int, mode: CatalogViewMode,
                     collapsedProjects: Int = 0) async throws -> ListRig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-lists-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
        try preferences.update { $0.viewMode = mode }
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub, preferences: preferences)
        model.branchReader = { _ in .unavailable }
        let rig = ListRig(root: root, catalog: catalog, hub: hub, model: model)
        var clock = 0.0
        func stamp() -> Date { clock += 1; return Date(timeIntervalSince1970: 1_000_000 + clock) }
        for index in 0..<projectCount {
            let folder = root.appendingPathComponent("project-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let project = try await catalog.addProject(path: folder.path).project
            rig.projects.append(project)
            for item in 0..<perProject {
                let id = UUID()
                try await catalog.insertSession(
                    ManagedSession(id: id, provider: item % 2 == 0 ? .claude : .codex, workingDirectory: folder.path),
                    title: "\(item % 3 == 0 ? "Alpha" : "Beta") p\(index) n\(item)",
                    createdAt: stamp(), lastUsedAt: stamp(), lifecycle: .idle, projectID: project.id)
                rig.ids[project.id, default: []].append(id)
            }
        }
        for item in 0..<unassigned {
            let id = UUID()
            try await catalog.insertSession(
                ManagedSession(id: id, provider: .claude, workingDirectory: root.path),
                title: "\(item % 3 == 0 ? "Alpha" : "Beta") free n\(item)",
                createdAt: stamp(), lastUsedAt: stamp(), lifecycle: .idle)
            rig.ids[nil, default: []].append(id)
        }
        for index in 0..<collapsedProjects {
            try await catalog.setProjectCollapsed(id: rig.projects[projectCount - 1 - index].id, collapsed: true)
        }
        await model.start()
        await model.stopAndWait() // the test feeds frames itself
        await model.settle()
        let reader = FrameReader(await rig.hub.subscribe())
        rig.frames = reader
        try await rig.applyNextFrame() // the initial snapshot
        return rig
    }

    func cleanup() {
        model.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Publishes a change and applies the frame it produced.
    func feed(_ change: SessionEventChange, for id: UUID) async throws {
        await hub.publish(sessionID: id, change: change)
        try await applyNextFrame()
    }

    func feedActivity(for id: UUID) async throws {
        await hub.publishActivity(sessionID: id)
        try await applyNextFrame()
    }

    func applyNextFrame() async throws {
        let reader = try #require(frames)
        model.apply(try #require(await reader.next()))
    }

    /// What every visible list shows now: rows in order with their records, and the paging state.
    func shape() -> [CatalogListKey: ListShape] {
        var result: [CatalogListKey: ListShape] = [:]
        for key in model.visibleListKeys() {
            let list = model.list(for: key)
            result[key] = ListShape(records: list.rows.map(\.record), hasMore: list.hasMore)
        }
        return result
    }

    /// A full re-read of every visible list, the way the old code answered every frame.
    func fullReload() async -> [CatalogListKey: ListShape] {
        model.scheduleRefresh()
        await model.settle()
        return shape()
    }
}

/// Reads one subscription frame by frame; the stream keeps only the newest frame for a slow reader.
final class FrameReader: @unchecked Sendable {
    var iterator: AsyncStream<SessionEventFrame>.Iterator
    init(_ stream: AsyncStream<SessionEventFrame>) { iterator = stream.makeAsyncIterator() }
    func next() async -> SessionEventFrame? { await iterator.next() }
}

struct ListShape: Equatable {
    let records: [CatalogSession]
    let hasMore: Bool
    var ids: [UUID] { records.map(\.session.id) }
}
