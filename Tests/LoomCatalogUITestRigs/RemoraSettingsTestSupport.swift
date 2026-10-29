import Foundation
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI
import LoomTestSupport

/// A model with a Remora host over a temporary data root and a call that never starts: the memory and the settings can be read and
/// changed, and no Claude, no profile and no vault is reached. With `projects` the catalog holds those projects (the first one is
/// `project`), each with the tone the catalog gave it.
@MainActor
final class RemoraMemoryRig {
    let root: URL
    var remora: URL { root.appendingPathComponent("remora") }
    let project: UUID
    let projectIDs: [UUID]
    let model: CatalogModel
    let host: RemoraHost

    convenience init() throws { try self.init(catalog: nil, projectIDs: [UUID()]) }

    /// A catalog of projects named `names`.
    static func withProjects(_ names: [String]) async throws -> RemoraMemoryRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-projects-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var ids: [UUID] = []
        for name in names {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ids.append(try await catalog.addProject(path: folder.path).project.id)
        }
        let rig = try RemoraMemoryRig(catalog: catalog, projectIDs: ids, root: root, names: names)
        await rig.model.start()
        await rig.model.stopAndWait()
        await rig.model.settle()
        return rig
    }

    init(catalog: SessionCatalog?, projectIDs: [UUID], root existing: URL? = nil, names: [String] = ["loom"]) throws {
        root = existing ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-remora-memory-\(UUID().uuidString.prefix(8))")
        self.projectIDs = projectIDs
        project = projectIDs[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                             preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        let maps = RemoraCatalogMaps(sessionProjects: [:], projectNames: Dictionary(uniqueKeysWithValues: zip(projectIDs, names)),
                                     recency: [])
        host = RemoraHost(dataRoot: root, settings: model.remora.preferences, sessions: { _ in [] }, transcript: { _ in nil },
                          maps: { maps }, makeCall: { _ in throw RemoraFailure(kind: .couldNotStart, detail: "not in a test", usage: nil) })
        model.installRemora(host: host)
    }

    /// Journal lines, one note for each project (`notes`, with those texts), and a `Remora.md`.
    func seed(journal: [RemoraJournalEntry] = [], notes: [String] = ["Waits on review"]) async throws {
        let memory = try RemoraMemory(directory: remora)
        for entry in journal { try await memory.appendJournal(entry) }
        for (id, text) in zip(projectIDs, notes) { try await memory.replaceNote(project: id, items: [RemoraNoteItem(text: text, sessions: [])]) }
        try Data("# Remora\n".utf8).write(to: remora.appendingPathComponent("Remora.md"))
    }

    func finish() { try? FileManager.default.removeItem(at: root) }
}
