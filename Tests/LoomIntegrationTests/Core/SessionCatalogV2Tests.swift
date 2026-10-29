import Foundation
import SQLite3
import Testing
@testable import LoomCore

/// CP5 B1/B5: schema 1 to 2 migration, projects, titles and keyset paging.
@Suite(.serialized)
struct SessionCatalogV2Tests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-catalog-v2-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: Schema 1 fixture

    private static let schemaOneDDL = [
        "PRAGMA application_id = 1280266061",
        """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY NOT NULL, provider TEXT NOT NULL,
            provider_conversation_id TEXT, working_directory TEXT NOT NULL, title TEXT,
            created_at REAL NOT NULL, last_used_at REAL NOT NULL,
            lifecycle TEXT NOT NULL CHECK (lifecycle IN ('active', 'idle', 'stale')),
            pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)))
        """,
        """
        CREATE TABLE runs (
            id TEXT PRIMARY KEY NOT NULL, initial_session_id TEXT NOT NULL REFERENCES sessions(id),
            leader_pid INTEGER NOT NULL, leader_start_seconds INTEGER NOT NULL,
            leader_start_microseconds INTEGER NOT NULL, started_at REAL NOT NULL,
            ended_at REAL, end_reason TEXT, exit_status INTEGER)
        """,
        """
        CREATE TABLE run_sessions (
            run_id TEXT NOT NULL REFERENCES runs(id), session_id TEXT NOT NULL REFERENCES sessions(id),
            linked_at REAL NOT NULL, unlinked_at REAL,
            PRIMARY KEY (run_id, session_id, linked_at))
        """,
        """
        CREATE TABLE provider_identity_changes (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            previous_id TEXT, new_id TEXT NOT NULL, changed_at REAL NOT NULL)
        """,
    ]

    private struct SchemaOneIDs {
        let sessions = [UUID(), UUID(), UUID()]
        let runs = [UUID(), UUID()]
    }

    /// A schema 1 database exactly as the previous build wrote it (WAL mode).
    private func writeSchemaOne(at url: URL) throws -> SchemaOneIDs {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let ids = SchemaOneIDs()
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        func run(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw SessionCatalogError.invalidRow("fixture SQL failed: \(sql)")
            }
        }
        try run("PRAGMA journal_mode = WAL")
        for statement in Self.schemaOneDDL { try run(statement) }
        try run("""
            INSERT INTO sessions VALUES
            ('\(ids.sessions[0])', 'claude', 'claude-old', '/tmp/one', 'First', 100, 200, 'idle', 1),
            ('\(ids.sessions[1])', 'claude', 'claude-new', '/tmp/one', NULL, 300, 400, 'active', 0),
            ('\(ids.sessions[2])', 'codex', NULL, '/tmp/two', 'Third', 500, 600, 'stale', 0)
            """)
        try run("""
            INSERT INTO runs VALUES
            ('\(ids.runs[0])', '\(ids.sessions[0])', 41, 1000, 2000, 110, 390, 'processExited', 256),
            ('\(ids.runs[1])', '\(ids.sessions[2])', 42, 1001, 2001, 510, NULL, NULL, NULL)
            """)
        try run("""
            INSERT INTO run_sessions VALUES
            ('\(ids.runs[0])', '\(ids.sessions[0])', 110, 300),
            ('\(ids.runs[0])', '\(ids.sessions[1])', 300, NULL),
            ('\(ids.runs[1])', '\(ids.sessions[2])', 510, NULL)
            """)
        try run("""
            INSERT INTO provider_identity_changes (session_id, previous_id, new_id, changed_at)
            VALUES ('\(ids.sessions[1])', 'claude-old', 'claude-new', 300)
            """)
        try run("PRAGMA user_version = 1")
        return ids
    }

    /// Every schema 1 column of every table, in a comparable form.
    private func schemaOneDump(at url: URL) throws -> [String] {
        var database: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        let queries = [
            "SELECT id, provider, provider_conversation_id, working_directory, title, created_at, last_used_at, lifecycle, pinned FROM sessions ORDER BY id",
            "SELECT * FROM runs ORDER BY id",
            "SELECT * FROM run_sessions ORDER BY run_id, session_id, linked_at",
            "SELECT * FROM provider_identity_changes ORDER BY sequence",
        ]
        var rows: [String] = []
        for query in queries {
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let count = sqlite3_column_count(statement)
                rows.append((0..<count).map { column in
                    sqlite3_column_type(statement, column) == SQLITE_NULL
                        ? "NULL" : String(cString: sqlite3_column_text(statement, column))
                }.joined(separator: "|"))
            }
        }
        return rows
    }

    private func pragma(_ sql: String, at url: URL) throws -> String {
        var database: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let handle = try #require(database)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: text)
    }

    // MARK: B1 migration

    @Test func schemaOneMigratesWithEveryConversationRunAndLinkIntact() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        let ids = try writeSchemaOne(at: url)
        let before = try schemaOneDump(at: url)
        #expect(before.count == 9)

        let catalog = try SessionCatalog(url: url)
        #expect(try schemaOneDump(at: url) == before)
        #expect(try pragma("PRAGMA user_version", at: url) == "\(SessionCatalog.schemaVersion)")
        #expect(try pragma("PRAGMA foreign_key_check", at: url) == "")
        #expect(try pragma("PRAGMA quick_check", at: url) == "ok")

        let sessions = try await catalog.sessions()
        #expect(sessions.map(\.session.id).sorted { $0.uuidString < $1.uuidString }
                == ids.sessions.sorted { $0.uuidString < $1.uuidString })
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.session.id, $0) })
        #expect(byID[ids.sessions[0]]?.title == "First")
        #expect(byID[ids.sessions[0]]?.pinned == true)
        #expect(byID[ids.sessions[1]]?.session.providerConversationID == "claude-new")
        #expect(byID[ids.sessions[2]]?.lifecycle == .stale)
        for session in sessions {
            #expect(session.projectID == nil)
            #expect(session.titleIsCustom == false)
        }
        let links = try await catalog.runSessionLinks()
        #expect(links.count == 3)
        #expect(try await catalog.runs().map(\.id).sorted { $0.uuidString < $1.uuidString }
                == ids.runs.sorted { $0.uuidString < $1.uuidString })

        // The migrated catalog accepts the new features and reopens at the current version.
        let added = try await catalog.addProject(path: root.path)
        try await catalog.insertSession(
            ManagedSession(provider: .codex, workingDirectory: root.path),
            projectID: added.project.id
        )
        let reopened = try SessionCatalog(url: url)
        #expect(try await reopened.sessions().count == 4)
        #expect(try await reopened.projects().count == 1)
    }

    @Test func interruptedMigrationRollsBackAndTheCatalogOpensAgain() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        _ = try writeSchemaOne(at: url)
        let before = try schemaOneDump(at: url)

        struct Interrupted: Error {}
        do {
            _ = try SessionCatalog(url: url, migrationFailpoint: { throw Interrupted() })
            Issue.record("Migration failpoint did not interrupt the migration")
        } catch is Interrupted {}

        #expect(try pragma("PRAGMA user_version", at: url) == "1")
        #expect(try pragma("SELECT count(*) FROM sqlite_master WHERE name = 'projects'", at: url) == "0")
        #expect(try pragma(
            "SELECT count(*) FROM pragma_table_info('sessions') WHERE name IN ('project_id', 'title_is_custom')",
            at: url) == "0")
        #expect(try schemaOneDump(at: url) == before)

        let catalog = try SessionCatalog(url: url)
        #expect(try await catalog.sessions().count == 3)
        #expect(try pragma("PRAGMA user_version", at: url) == "\(SessionCatalog.schemaVersion)")
        #expect(try schemaOneDump(at: url) == before)
    }

    @Test func killedMigrationTransactionLeavesSchemaOneAndReopensClean() async throws {
        // A separate process performs the same DDL in an open transaction and
        // is killed with SIGKILL before COMMIT (hot WAL, no clean close).
        let sqliteTool = URL(fileURLWithPath: "/usr/bin/sqlite3")
        guard FileManager.default.isExecutableFile(atPath: sqliteTool.path) else { return }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        _ = try writeSchemaOne(at: url)
        let before = try schemaOneDump(at: url)

        let process = Process()
        process.executableURL = sqliteTool
        process.arguments = [url.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data("""
            BEGIN IMMEDIATE;
            CREATE TABLE projects (id TEXT PRIMARY KEY NOT NULL);
            ALTER TABLE sessions ADD COLUMN project_id TEXT;
            PRAGMA user_version = 2;
            SELECT 'open';

            """.utf8))
        // Give the tool time to run the statements; then kill it mid-transaction.
        try await Task.sleep(for: .milliseconds(400))
        await process.terminateAndAwaitExit()

        let catalog = try SessionCatalog(url: url)
        #expect(try await catalog.sessions().count == 3)
        #expect(try pragma("PRAGMA user_version", at: url) == "\(SessionCatalog.schemaVersion)")
        #expect(try schemaOneDump(at: url) == before)
        #expect(try pragma("PRAGMA quick_check", at: url) == "ok")
    }

    @Test func newerForeignAndCorruptCatalogsAreNeverModified() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        func makeDatabase(_ name: String, _ statements: [String]) throws -> URL {
            let url = root.appendingPathComponent(name)
            var database: OpaquePointer?
            #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
            let handle = try #require(database)
            for statement in statements {
                #expect(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK)
            }
            sqlite3_close(handle)
            return url
        }
        let newer = try makeDatabase("newer.sqlite3", [
            "PRAGMA application_id = 1280266061", "CREATE TABLE future (x)", "PRAGMA user_version = \(SessionCatalog.schemaVersion + 1)",
        ])
        let foreign = try makeDatabase("foreign.sqlite3", [
            "PRAGMA application_id = 12345", "CREATE TABLE other (x)", "PRAGMA user_version = 2",
        ])
        let corrupt = root.appendingPathComponent("corrupt.sqlite3")
        try Data("not sqlite".utf8).write(to: corrupt)

        for url in [newer, foreign, corrupt] {
            let before = try Data(contentsOf: url)
            do {
                _ = try SessionCatalog(url: url)
                Issue.record("\(url.lastPathComponent) was accepted")
            } catch let error as SessionCatalogError {
                switch (url.lastPathComponent, error) {
                case ("newer.sqlite3", .unsupportedSchema(SessionCatalog.schemaVersion + 1)): break
                case ("foreign.sqlite3", .foreignDatabase(applicationID: 12345)): break
                case ("corrupt.sqlite3", .sqlite): break
                default: Issue.record("Unexpected \(error) for \(url.lastPathComponent)")
                }
            }
            #expect(try Data(contentsOf: url) == before)
            #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        }
    }

    // MARK: B1 paging and search at 10,000 rows

    private struct Row {
        let id: UUID
        let provider: ManagedSession.Provider
        let title: String
        let created: Double
        let used: Double
        let project: UUID?
    }

    private func seed(_ catalog: SessionCatalog, count: Int, projects: [UUID]) async throws -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(count)
        for index in 0..<count {
            // Timestamps repeat in groups of 7 so ties are exercised on both orders.
            let row = Row(
                id: UUID(), provider: index % 3 == 0 ? .codex : .claude,
                title: index == 4242 ? "Done 100%_finished" : "Task \(index)",
                created: 1_700_000_000 + Double(index / 7),
                used: 1_700_100_000 + Double((index * 31) % 1_000),
                project: index % 10 == 9 ? nil : projects[index % projects.count]
            )
            rows.append(row)
            try await catalog.insertSession(
                ManagedSession(id: row.id, provider: row.provider, workingDirectory: "/tmp/work"),
                title: row.title, createdAt: Date(timeIntervalSince1970: row.created),
                lastUsedAt: Date(timeIntervalSince1970: row.used), lifecycle: .idle,
                projectID: row.project
            )
        }
        return rows
    }

    private func drain(_ catalog: SessionCatalog, _ query: CatalogQuery) async throws -> [CatalogSession] {
        var all: [CatalogSession] = []
        var cursor: CatalogCursor?
        repeat {
            let page = try await catalog.sessionPage(query, after: cursor)
            #expect(page.sessions.count <= CatalogQuery.maxPageSize)
            all += page.sessions
            cursor = page.next
        } while cursor != nil
        return all
    }

    @Test func tenThousandRecordsPageSearchAndOrderExactly() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var projectIDs: [UUID] = []
        for name in ["alpha", "beta_x", "gamma"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projectIDs.append(try await catalog.addProject(path: folder.path).project.id)
        }
        let rows = try await seed(catalog, count: 10_000, projects: projectIDs)
        let projectNames = ["alpha": projectIDs[0], "beta_x": projectIDs[1], "gamma": projectIDs[2]]

        // First page: at most 100 rows, measured on a local disk.
        let clock = ContinuousClock()
        var first: CatalogPage?
        let firstPageTime = try await clock.measure {
            first = try await catalog.sessionPage(CatalogQuery(limit: 10_000))
        }
        #expect(first?.sessions.count == 100)
        #expect(first?.next != nil)
        print("B5 first page (10,000 rows): \(firstPageTime)")
        #expect(firstPageTime < .milliseconds(300))

        // Activity order: newest use first, ties broken by id descending.
        let activity = try await drain(catalog, CatalogQuery(order: .recentActivity))
        let expectedActivity = rows.sorted {
            $0.used != $1.used ? $0.used > $1.used : $0.id.uuidString > $1.id.uuidString
        }.map(\.id)
        #expect(activity.count == 10_000)
        #expect(activity.map(\.session.id) == expectedActivity)
        #expect(Set(activity.map(\.session.id)).count == 10_000)

        // Creation order: newest first, ties broken by id descending, unmoved by use.
        let creation = try await drain(catalog, CatalogQuery(order: .creation))
        let expectedCreation = rows.sorted {
            $0.created != $1.created ? $0.created > $1.created : $0.id.uuidString > $1.id.uuidString
        }.map(\.id)
        #expect(creation.map(\.session.id) == expectedCreation)

        // Scopes.
        for (name, id) in projectNames {
            let scoped = try await drain(catalog, CatalogQuery(scope: .project(id), order: .creation))
            #expect(Set(scoped.map(\.session.id)) == Set(rows.filter { $0.project == id }.map(\.id)), "\(name)")
        }
        let unassigned = try await drain(catalog, CatalogQuery(scope: .unassigned))
        #expect(Set(unassigned.map(\.session.id)) == Set(rows.filter { $0.project == nil }.map(\.id)))
        let counts = try await catalog.sessionCounts()
        #expect(counts[nil] == unassigned.count)
        #expect(counts[projectIDs[0]] == rows.filter { $0.project == projectIDs[0] }.count)

        // Search: provider, title (LIKE metacharacters are literal), project name, AND of terms.
        let codex = try await drain(catalog, CatalogQuery(search: "CODEX"))
        #expect(Set(codex.map(\.session.id)) == Set(rows.filter { $0.provider == .codex }.map(\.id)))
        // Terms are ANDed: "task" and "77" may match anywhere in the title.
        let task77 = try await drain(catalog, CatalogQuery(search: "task 77"))
        #expect(Set(task77.map(\.session.id)) == Set(rows.filter {
            $0.title.lowercased().contains("task") && $0.title.contains("77")
        }.map(\.id)))
        let both = try await drain(catalog, CatalogQuery(search: "codex 77"))
        #expect(Set(both.map(\.session.id))
                == Set(rows.filter { $0.provider == .codex && $0.title.contains("77") }.map(\.id)))
        let literal = try await drain(catalog, CatalogQuery(search: "100%_"))
        #expect(literal.map(\.title) == ["Done 100%_finished"])
        let percentOnly = try await drain(catalog, CatalogQuery(search: "%"))
        #expect(percentOnly.map(\.title) == ["Done 100%_finished"])
        let byProject = try await drain(catalog, CatalogQuery(search: "beta_x"))
        #expect(Set(byProject.map(\.session.id)) == Set(rows.filter { $0.project == projectIDs[1] }.map(\.id)))
        let underscoreIsLiteral = try await drain(catalog, CatalogQuery(search: "beta_"))
        #expect(underscoreIsLiteral.count == byProject.count)
        #expect(try await drain(catalog, CatalogQuery(search: "beta-x")).isEmpty)
        let scopedSearch = try await drain(
            catalog, CatalogQuery(scope: .project(projectIDs[2]), search: "task 9")
        )
        #expect(Set(scopedSearch.map(\.session.id)) == Set(rows.filter {
            $0.project == projectIDs[2] && $0.title.lowercased().contains("task")
                && $0.title.contains("9")
        }.map(\.id)))
    }

    @Test func pagingSurvivesRowsAddedAndRenamedBetweenPages() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var expected: [UUID] = []
        for index in 0..<250 {
            let id = UUID()
            expected.append(id)
            try await catalog.insertSession(
                ManagedSession(id: id, provider: .claude, workingDirectory: "/tmp"),
                title: "row \(index)", createdAt: Date(timeIntervalSince1970: Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: Double(1_000 + index))
            )
        }
        let query = CatalogQuery(order: .recentActivity, limit: 100)
        let page1 = try await catalog.sessionPage(query)
        // A newer row and a rename land between the pages of an open listing.
        try await catalog.insertSession(
            ManagedSession(provider: .codex, workingDirectory: "/tmp"), title: "late",
            lastUsedAt: Date(timeIntervalSince1970: 9_999)
        )
        try await catalog.renameSession(sessionID: expected[10], to: "renamed while paging")
        let page2 = try await catalog.sessionPage(query, after: page1.next)
        let page3 = try await catalog.sessionPage(query, after: page2.next)
        let seen = (page1.sessions + page2.sessions + page3.sessions).map(\.session.id)
        #expect(seen == expected.reversed())
        #expect(page3.next == nil)
    }

    @Test func searchFoldsCaseForNonASCIITitles() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        for title in ["Çay ve Şeker planı", "Ölçüm notları", "plain ascii"] {
            try await catalog.insertSession(ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: title)
        }
        #expect(try await catalog.sessionPage(CatalogQuery(search: "çay şeker")).sessions.count == 1)
        #expect(try await catalog.sessionPage(CatalogQuery(search: "ÇAY")).sessions.count == 1)
        #expect(try await catalog.sessionPage(CatalogQuery(search: "ölçüm")).sessions.count == 1)
        #expect(try await catalog.sessionPage(CatalogQuery(search: "ASCII")).sessions.count == 1)
        #expect(try await catalog.sessionPage(CatalogQuery(search: "cay")).sessions.isEmpty)
    }

    // MARK: Projects

    @Test func projectsAreStandardizedOrderedCollapsedAndOnlyEmptyOnesRemoved() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = root.appendingPathComponent("catalog.sqlite3")
        let folders = ["one", "two", "three"].map { root.appendingPathComponent($0, isDirectory: true) }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let link = root.appendingPathComponent("link-to-one")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folders[0])
        try Data("x".utf8).write(to: root.appendingPathComponent("file.txt"))

        let catalog = try SessionCatalog(url: catalogURL)
        let one = try await catalog.addProject(path: folders[0].path)
        #expect(!one.alreadyPresent)
        // Same folder through a trailing slash, dot segments and a symlink.
        for alias in [folders[0].path + "/", folders[0].path + "/../one", link.path] {
            let repeated = try await catalog.addProject(path: alias)
            #expect(repeated.alreadyPresent)
            #expect(repeated.project.id == one.project.id)
        }
        let two = try await catalog.addProject(path: folders[1].path)
        let three = try await catalog.addProject(path: folders[2].path)
        #expect(try await catalog.projects().map(\.name) == ["one", "two", "three"])

        do {
            _ = try await catalog.addProject(path: root.appendingPathComponent("file.txt").path)
            Issue.record("A file was accepted as a project")
        } catch SessionCatalogError.projectPathNotDirectory {}
        do {
            _ = try await catalog.addProject(path: root.appendingPathComponent("missing").path)
            Issue.record("A missing folder was accepted as a project")
        } catch SessionCatalogError.projectPathNotDirectory {}

        try await catalog.moveProject(id: three.project.id, toIndex: 0)
        try await catalog.setProjectCollapsed(id: two.project.id, collapsed: true)
        #expect(try await catalog.projects().map(\.name) == ["three", "one", "two"])
        #expect(try await catalog.projects().map(\.sortOrder) == [0, 1, 2])

        try await catalog.insertSession(
            ManagedSession(provider: .claude, workingDirectory: folders[0].path),
            projectID: one.project.id
        )
        do {
            try await catalog.removeProject(id: one.project.id)
            Issue.record("A project with conversations was removed")
        } catch SessionCatalogError.projectNotEmpty {}
        try await catalog.removeProject(id: two.project.id)
        #expect(FileManager.default.fileExists(atPath: folders[1].path))
        do {
            try await catalog.removeProject(id: two.project.id)
            Issue.record("A removed project was removed twice")
        } catch SessionCatalogError.projectNotFound {}

        let reopened = try SessionCatalog(url: catalogURL)
        let stored = try await reopened.projects()
        #expect(stored.map(\.name) == ["three", "one"])
        #expect(stored.allSatisfy { !$0.collapsed })
        try await reopened.setProjectCollapsed(id: one.project.id, collapsed: true)
        #expect(try await SessionCatalog(url: catalogURL).projects().last?.collapsed == true)
    }

    @Test func projectAndProjectlessGroupsListTheNewestCreatedFirstAcrossPages() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let folder = root.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await catalog.addProject(path: folder.path).project.id
        // Creation times repeat in pairs so the id tiebreak crosses a page boundary too; a later use
        // of the oldest row must not move it.
        var expected: [(created: Double, id: UUID)] = []
        for index in 0..<7 {
            let id = UUID()
            let created = 1_000 + Double(index / 2)
            expected.append((created, id))
            try await catalog.insertSession(
                ManagedSession(id: id, provider: .claude, workingDirectory: "/tmp/work"),
                createdAt: Date(timeIntervalSince1970: created),
                lastUsedAt: Date(timeIntervalSince1970: index == 0 ? 9_000 : created), lifecycle: .idle,
                projectID: project
            )
        }
        let loose = (0..<3).map { _ in UUID() }
        for (index, id) in loose.enumerated() {
            try await catalog.insertSession(
                ManagedSession(id: id, provider: .claude, workingDirectory: "/tmp"),
                createdAt: Date(timeIntervalSince1970: 2_000 + Double(index)), lifecycle: .idle
            )
        }
        let newestFirst = expected.sorted {
            $0.created != $1.created ? $0.created > $1.created : $0.id.uuidString > $1.id.uuidString
        }.map(\.id)

        var seen: [UUID] = []
        var cursor: CatalogCursor?
        var pages = 0
        repeat {
            let page = try await catalog.sessionPage(
                CatalogQuery(scope: .project(project), order: .creation, limit: 3), after: cursor
            )
            seen += page.sessions.map(\.session.id)
            cursor = page.next
            pages += 1
        } while cursor != nil && pages < 10
        #expect(pages == 3)
        #expect(seen == newestFirst)
        let unassigned = try await drain(catalog, CatalogQuery(scope: .unassigned, order: .creation))
        #expect(unassigned.map(\.session.id) == loose.reversed())
    }

    @Test func newConversationInheritsTheProjectAndExistingTargetsKeepTheirOwn() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var projects: [CatalogProject] = []
        for name in ["one", "two"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projects.append(try await catalog.addProject(path: folder.path).project)
        }
        let leader = ProcessIdentity(pid: 7, startSeconds: 1, startMicroseconds: 2)
        func startRun(in sessionID: UUID) async throws -> UUID {
            let run = ManagedRun(id: UUID(), leader: leader, startedAt: Date(timeIntervalSince1970: 50),
                                 state: .running, exitStatus: nil, descendants: [leader])
            try await catalog.startRun(run, sessionID: sessionID)
            return run.id
        }
        let inProject = ManagedSession(provider: .claude, providerConversationID: "old", workingDirectory: "/tmp/one")
        let projectless = ManagedSession(provider: .claude, providerConversationID: "loose", workingDirectory: "/tmp")
        let target = ManagedSession(provider: .claude, providerConversationID: "target", workingDirectory: "/tmp/two")
        try await catalog.insertSession(inProject, title: "Old", projectID: projects[0].id)
        try await catalog.insertSession(projectless, title: "Loose")
        try await catalog.insertSession(target, title: "Target", lifecycle: .idle, projectID: projects[1].id)

        // /clear or /new inside a project-bound run: the new conversation stays in the project.
        let run = try await startRun(in: inProject.id)
        let fresh = ManagedSession(provider: .claude, providerConversationID: "new", workingDirectory: "/tmp/one")
        try await catalog.transitionRun(run, from: inProject.id, to: fresh, at: Date(timeIntervalSince1970: 60))
        #expect(try await catalog.session(id: fresh.id)?.projectID == projects[0].id)
        #expect(try await catalog.session(id: inProject.id)?.projectID == projects[0].id)
        let inFirst = try await catalog.sessionPage(CatalogQuery(scope: .project(projects[0].id), order: .creation))
        #expect(Set(inFirst.sessions.map(\.session.id)) == [inProject.id, fresh.id])
        #expect(try await catalog.sessionPage(CatalogQuery(scope: .unassigned)).sessions.map(\.session.id)
                == [projectless.id])
        // The old conversation and the run link history are kept.
        #expect(try await catalog.session(id: inProject.id)?.lifecycle == .idle)
        let links = try await catalog.runSessionLinks(runID: run)
        #expect(links.map(\.sessionID) == [inProject.id, fresh.id])
        #expect(links.first?.unlinkedAt != nil && links.last?.unlinkedAt == nil)

        // Resume into an existing conversation keeps that conversation's own project.
        try await catalog.transitionRun(run, from: fresh.id, toExistingSessionID: target.id,
                                        at: Date(timeIntervalSince1970: 70))
        #expect(try await catalog.session(id: target.id)?.projectID == projects[1].id)
        #expect(try await catalog.session(id: fresh.id)?.projectID == projects[0].id)

        // A projectless source stays projectless.
        let looseRun = try await startRun(in: projectless.id)
        let looseNew = ManagedSession(provider: .claude, providerConversationID: "loose-2", workingDirectory: "/tmp")
        try await catalog.transitionRun(looseRun, from: projectless.id, to: looseNew)
        #expect(try await catalog.session(id: looseNew.id)?.projectID == nil)
        #expect(try await catalog.sessionPage(CatalogQuery(scope: .unassigned)).sessions.count == 2)
    }

    // MARK: Titles

    @Test func customTitleSurvivesTerminalTitlesAndIsBounded() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        let catalog = try SessionCatalog(url: url)
        let id = UUID()
        try await catalog.insertSession(ManagedSession(id: id, provider: .codex, workingDirectory: "/tmp"))

        #expect(try await catalog.recordTerminalTitle(sessionID: id, title: "Terminal says A"))
        #expect(try await catalog.session(id: id)?.title == "Terminal says A")
        #expect(try await catalog.session(id: id)?.titleIsCustom == false)

        #expect(try await catalog.renameSession(sessionID: id, to: "  Mine\nline two \t ") == "Mine line two")
        #expect(try await catalog.recordTerminalTitle(sessionID: id, title: "Terminal says B") == false)
        #expect(try await SessionCatalog(url: url).session(id: id)?.title == "Mine line two")
        #expect(try await SessionCatalog(url: url).session(id: id)?.titleIsCustom == true)

        let long = String(repeating: "ş", count: 200)
        #expect(try await catalog.renameSession(sessionID: id, to: long)?.count == SessionCatalog.maxTitleLength)
        #expect(try await catalog.session(id: id)?.title?.count == 160)

        // Empty input returns to automatic titles.
        #expect(try await catalog.renameSession(sessionID: id, to: "   ") == nil)
        #expect(try await catalog.session(id: id)?.titleIsCustom == false)
        #expect(try await catalog.recordTerminalTitle(sessionID: id, title: "Terminal says C"))
        #expect(try await catalog.session(id: id)?.title == "Terminal says C")

        do {
            try await catalog.renameSession(sessionID: UUID(), to: "ghost")
            Issue.record("Renaming a missing conversation reported success")
        } catch SessionCatalogError.invalidRow {}
    }

    /// SR3-P1-1: Claude Code 2.1.287 alternates `◐`/`◑` in the terminal title
    /// every 960 ms while working and shows `✳` otherwise.
    @Test func providerStatusGlyphsNeitherChangeTheTitleNorCauseWrites() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let id = UUID()
        try await catalog.insertSession(ManagedSession(id: id, provider: .claude, workingDirectory: "/tmp"))
        var changes: [Bool] = []
        for title in ["✳ a", "◐ a", "◑ a", "◐ a", "⠋ a"] {
            changes.append(try await catalog.recordTerminalTitle(sessionID: id, title: title))
        }
        #expect(changes == [true, false, false, false, false])
        #expect(try await catalog.session(id: id)?.title == "a")
        // Only the known glyph set goes; other leading symbols are content.
        #expect(try await catalog.recordTerminalTitle(sessionID: id, title: "🚀 a"))
        #expect(try await catalog.session(id: id)?.title == "🚀 a")
    }

    // MARK: B5 lifecycle helpers

    @Test func selectiveReadsHandleLargeIDListsAndOldestLifecycleRow() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var ids: [UUID] = []
        for index in 0..<1_200 {
            let id = UUID()
            ids.append(id)
            try await catalog.insertSession(
                ManagedSession(id: id, provider: .claude, workingDirectory: "/tmp"),
                lastUsedAt: Date(timeIntervalSince1970: Double(100 + index)),
                lifecycle: index % 2 == 0 ? .idle : .active
            )
        }
        let picked = Array(ids[0..<1_100]) + [UUID()]
        #expect(try await catalog.sessions(ids: picked).count == 1_100)
        #expect(try await catalog.sessions(ids: []).isEmpty)
        #expect(try await catalog.oldestLastUsed(lifecycle: .idle) == Date(timeIntervalSince1970: 100))
        #expect(try await catalog.oldestLastUsed(lifecycle: .active) == Date(timeIntervalSince1970: 101))
        #expect(try await catalog.oldestLastUsed(lifecycle: .stale) == nil)
    }
}
