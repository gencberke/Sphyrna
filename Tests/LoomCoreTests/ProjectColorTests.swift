import Foundation
import SQLite3
import Testing
@testable import LoomCore

/// Project colours in the catalog (D-48): the `projects.color` column is added on open, every project
/// gets a tone by the least-used rule, None is a stored choice, an unknown value is left alone.
@Suite(.serialized)
struct ProjectColorTests {
    private struct Fixture {
        let root: URL
        var url: URL { root.appendingPathComponent("catalog.sqlite3") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-colors-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func folder(_ name: String) throws -> String {
            let path = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            return path.path
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func sql(_ statement: String, at url: URL) throws -> [String] {
        var database: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, statement, -1, &prepared, nil) == SQLITE_OK else {
            throw SessionCatalogError.invalidRow("test SQL failed: \(statement)")
        }
        defer { sqlite3_finalize(prepared) }
        var rows: [String] = []
        var result = sqlite3_step(prepared)
        while result == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(prepared)).map { column in
                sqlite3_column_type(prepared, column) == SQLITE_NULL
                    ? "NULL" : String(cString: sqlite3_column_text(prepared, column))
            }.joined(separator: "|"))
            result = sqlite3_step(prepared)
        }
        guard result == SQLITE_DONE else { throw SessionCatalogError.invalidRow("test SQL failed: \(statement)") }
        return rows
    }

    private let hasColumn = "SELECT count(*) FROM pragma_table_info('projects') WHERE name = 'color'"

    @Test func aSchema3CatalogGainsTheColumnAndItsProjectsGetTonesInCreationOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Added in an order that differs from their creation dates: the dates decide.
        let late: UUID, early: UUID, middle: UUID
        do {
            let catalog = try SessionCatalog(url: fixture.url)
            late = try await catalog.addProject(path: fixture.folder("late"), at: Date(timeIntervalSince1970: 300)).project.id
            early = try await catalog.addProject(path: fixture.folder("early"), at: Date(timeIntervalSince1970: 100)).project.id
            middle = try await catalog.addProject(path: fixture.folder("middle"), at: Date(timeIntervalSince1970: 200)).project.id
        }
        // What the build before this one left on disk: schema 3 without the colour column.
        _ = try sql("ALTER TABLE projects DROP COLUMN color", at: fixture.url)
        #expect(try sql(hasColumn, at: fixture.url) == ["0"])

        for _ in 0..<2 { // the second open is idempotent
            let catalog = try SessionCatalog(url: fixture.url)
            let tones = Dictionary(uniqueKeysWithValues: try await catalog.projects().map { ($0.id, $0.tone) })
            #expect(tones[early] == .rose)
            #expect(tones[middle] == .orchid)
            #expect(tones[late] == .aqua)
            #expect(try sql(hasColumn, at: fixture.url) == ["1"])
            #expect(try sql("PRAGMA user_version", at: fixture.url) == ["3"], "no version bump")
        }
    }

    @Test func aProjectAnOlderBuildAddedWithoutAToneGetsOneOnOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first: UUID, added: UUID
        do {
            let catalog = try SessionCatalog(url: fixture.url)
            first = try await catalog.addProject(path: fixture.folder("first")).project.id
            added = try await catalog.addProject(path: fixture.folder("added")).project.id
        }
        _ = try sql("UPDATE projects SET color = NULL WHERE id = '\(added.uuidString)'", at: fixture.url)
        let catalog = try SessionCatalog(url: fixture.url)
        let projects = Dictionary(uniqueKeysWithValues: try await catalog.projects().map { ($0.id, $0.tone) })
        #expect(projects[first] == .rose)
        #expect(projects[added] == .orchid)
    }

    @Test func theFirstSixProjectsGetSixDifferentTonesInPaletteOrderAndTheSeventhTheLeastUsed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalog = try SessionCatalog(url: fixture.url)
        var added: [CatalogProject] = []
        for index in 0..<7 {
            added.append(try await catalog.addProject(path: fixture.folder("p\(index)")).project)
        }
        #expect(added.prefix(6).map(\.tone) == ProjectTone.allCases)
        #expect(added[6].tone == .rose, "all six used once: the tie goes to the first tone in palette order")
        #expect(try await catalog.addProject(path: fixture.folder("p7")).project.tone == .orchid)
    }

    @Test func leastUsedPicksTheToneWithTheFewestProjectsAndCountsOnlyKnownTones() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalog = try SessionCatalog(url: fixture.url)
        var ids: [UUID] = []
        for index in 0..<6 { ids.append(try await catalog.addProject(path: fixture.folder("p\(index)")).project.id) }
        // aqua (third) moves to rose: rose is used twice, aqua not at all.
        try await catalog.setProjectTone(id: ids[2], tone: .rose)
        #expect(try await catalog.addProject(path: fixture.folder("next")).project.tone == .aqua)
        // None does not count as a use of any tone.
        try await catalog.setProjectTone(id: ids[3], tone: nil)
        #expect(try await catalog.addProject(path: fixture.folder("after-none")).project.tone == .mint)
    }

    @Test func noneIsStoredAndNeverReassigned() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id: UUID
        do {
            let catalog = try SessionCatalog(url: fixture.url)
            id = try await catalog.addProject(path: fixture.folder("p")).project.id
            try await catalog.setProjectTone(id: id, tone: nil)
            let project = try #require(try await catalog.projects().first)
            #expect(project.tone == nil && project.colorIsNone)
        }
        let reopened = try SessionCatalog(url: fixture.url)
        let project = try #require(try await reopened.projects().first { $0.id == id })
        #expect(project.tone == nil && project.colorIsNone)
        #expect(try sql("SELECT color FROM projects", at: fixture.url) == ["none"])

        try await reopened.setProjectTone(id: id, tone: .sage)
        #expect(try await reopened.projects().first?.tone == .sage)
        await #expect(throws: SessionCatalogError.self) { try await reopened.setProjectTone(id: UUID(), tone: .sage) }
    }

    @Test func anUnknownStoredValueIsKeptAndShowsAsNeutral() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id: UUID
        do {
            let catalog = try SessionCatalog(url: fixture.url)
            id = try await catalog.addProject(path: fixture.folder("p")).project.id
        }
        _ = try sql("UPDATE projects SET color = 'ultraviolet' WHERE id = '\(id.uuidString)'", at: fixture.url)
        let catalog = try SessionCatalog(url: fixture.url)
        let project = try #require(try await catalog.projects().first)
        #expect(project.tone == nil && !project.colorIsNone)
        #expect(try sql("SELECT color FROM projects", at: fixture.url) == ["ultraviolet"])
        // It counts as no tone, so a new project still starts at the first one.
        #expect(try await catalog.addProject(path: fixture.folder("q")).project.tone == .rose)
        #expect(try sql("SELECT color FROM projects WHERE id = '\(id.uuidString)'", at: fixture.url) == ["ultraviolet"])
    }
}
