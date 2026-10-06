import Foundation
import LoomCore
import SQLite3

/// Development and acceptance tool (CP5 B): writes an isolated catalog and
/// inspects one. Never bundled into the app and never pointed at real data:
/// it refuses a data root that already holds a catalog, except for `inspect`.
///
///   loom-catalog-fixture seed <data-root> <sessions> [projects]
///   loom-catalog-fixture seed-v1 <data-root>
///   loom-catalog-fixture inspect <data-root> [session-id ...]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func printJSON(_ object: Any) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, arguments.count >= 2 else {
    fail("usage: loom-catalog-fixture seed <data-root> <sessions> [projects] | seed-v1 <data-root> | inspect <data-root> [session-id ...]")
}
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
let catalogURL = root.appendingPathComponent("catalog.sqlite3")

func requireEmptyRoot() {
    if FileManager.default.fileExists(atPath: catalogURL.path) {
        fail("\(catalogURL.path) already exists; fixtures only seed a fresh isolated data root")
    }
}

func run() async throws {
    switch command {
    case "seed":
        requireEmptyRoot()
        guard arguments.count >= 3, let count = Int(arguments[2]), count >= 0 else { fail("seed needs a session count") }
        let projectCount = arguments.count >= 4 ? Int(arguments[3]) ?? 3 : 3
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let catalog = try SessionCatalog(url: catalogURL)
        let names = ["rocketarena", "herdr-desktop", "personal-site", "playground", "notes"]
        var projects: [CatalogProject] = []
        for index in 0..<projectCount {
            let name = index < names.count ? names[index] : "project-\(index)"
            let folder = root.appendingPathComponent("projects/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projects.append(try await catalog.addProject(path: folder.path).project)
        }
        let now = Date()
        let words = ["Refactor", "Fix", "Explain", "Review", "Summarize", "Draft", "Investigate", "Polish"]
        let topics = ["sidebar cards", "catalog paging", "terminal input", "migration", "search field",
                      "release notes", "hook adapter", "window restore"]
        for index in 0..<count {
            // Newest first; every 5th row shares a timestamp with its neighbour.
            let used = now.addingTimeInterval(-Double(index - index % 5) * 1_500)
            let project = index % 8 == 7 || projects.isEmpty ? nil : projects[index % projects.count]
            let provider: ManagedSession.Provider = index % 3 == 0 ? .codex : .claude
            try await catalog.insertSession(
                ManagedSession(provider: provider, workingDirectory: project?.path ?? NSHomeDirectory()),
                title: index % 11 == 10 ? nil : "\(words[index % words.count]) \(topics[(index / 3) % topics.count]) #\(index)",
                createdAt: used.addingTimeInterval(-600), lastUsedAt: used,
                lifecycle: index < 6 ? .active : (index % 4 == 0 ? .stale : .idle),
                projectID: project?.id
            )
        }
        var summary: [String: Any] = [
            "dataRoot": root.path, "sessions": count,
            "projects": projects.map { ["id": $0.id.uuidString, "name": $0.name, "path": $0.path] },
        ]
        let newest = try await catalog.sessionPage(CatalogQuery(limit: 3)).sessions
        summary["newest"] = newest.map { $0.session.id.uuidString }
        let inProject = try await catalog.sessionPage(
            CatalogQuery(scope: projects.first.map { .project($0.id) } ?? .all, order: .creation, limit: 2)
        ).sessions
        summary["firstInFirstProject"] = inProject.map { $0.session.id.uuidString }
        let noProject = try await catalog.sessionPage(CatalogQuery(scope: .unassigned, limit: 2)).sessions
        summary["unassigned"] = noProject.map { $0.session.id.uuidString }
        printJSON(summary)

    case "seed-v1":
        requireEmptyRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var database: OpaquePointer?
        guard sqlite3_open(catalogURL.path, &database) == SQLITE_OK, let handle = database else { fail("open failed") }
        defer { sqlite3_close(handle) }
        let first = UUID(), second = UUID(), run = UUID()
        let statements = [
            "PRAGMA journal_mode = WAL", "PRAGMA application_id = 1280266061",
            "CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, provider TEXT NOT NULL, provider_conversation_id TEXT, working_directory TEXT NOT NULL, title TEXT, created_at REAL NOT NULL, last_used_at REAL NOT NULL, lifecycle TEXT NOT NULL CHECK (lifecycle IN ('active', 'idle', 'stale')), pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)))",
            "CREATE TABLE runs (id TEXT PRIMARY KEY NOT NULL, initial_session_id TEXT NOT NULL REFERENCES sessions(id), leader_pid INTEGER NOT NULL, leader_start_seconds INTEGER NOT NULL, leader_start_microseconds INTEGER NOT NULL, started_at REAL NOT NULL, ended_at REAL, end_reason TEXT, exit_status INTEGER)",
            "CREATE TABLE run_sessions (run_id TEXT NOT NULL REFERENCES runs(id), session_id TEXT NOT NULL REFERENCES sessions(id), linked_at REAL NOT NULL, unlinked_at REAL, PRIMARY KEY (run_id, session_id, linked_at))",
            "CREATE TABLE provider_identity_changes (sequence INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), previous_id TEXT, new_id TEXT NOT NULL, changed_at REAL NOT NULL)",
            "INSERT INTO sessions VALUES ('\(first)', 'claude', 'claude-before', '\(NSHomeDirectory())', 'Schema one: before /clear', \(Date().timeIntervalSince1970 - 7_200), \(Date().timeIntervalSince1970 - 3_600), 'idle', 0)",
            "INSERT INTO sessions VALUES ('\(second)', 'claude', 'claude-after', '\(NSHomeDirectory())', NULL, \(Date().timeIntervalSince1970 - 3_600), \(Date().timeIntervalSince1970 - 600), 'active', 0)",
            "INSERT INTO runs VALUES ('\(run)', '\(first)', 41, 1000, 2000, \(Date().timeIntervalSince1970 - 7_200), \(Date().timeIntervalSince1970 - 600), 'processExited', 0)",
            "INSERT INTO run_sessions VALUES ('\(run)', '\(first)', \(Date().timeIntervalSince1970 - 7_200), \(Date().timeIntervalSince1970 - 3_600))",
            "INSERT INTO run_sessions VALUES ('\(run)', '\(second)', \(Date().timeIntervalSince1970 - 3_600), NULL)",
            "INSERT INTO provider_identity_changes (session_id, previous_id, new_id, changed_at) VALUES ('\(second)', 'claude-before', 'claude-after', \(Date().timeIntervalSince1970 - 3_600))",
            "PRAGMA user_version = 1",
        ]
        for statement in statements where sqlite3_exec(handle, statement, nil, nil, nil) != SQLITE_OK {
            fail("schema 1 fixture failed: \(statement)")
        }
        printJSON(["dataRoot": root.path, "schemaVersion": 1, "sessions": [first.uuidString, second.uuidString],
                   "run": run.uuidString])

    case "inspect":
        let catalog = try SessionCatalog(url: catalogURL)
        var summary: [String: Any] = ["schemaVersion": Int(SessionCatalog.schemaVersion)]
        let projects = try await catalog.projects()
        summary["projects"] = projects.map {
            ["id": $0.id.uuidString, "name": $0.name, "order": $0.sortOrder, "collapsed": $0.collapsed]
        }
        let counts = try await catalog.sessionCounts()
        summary["total"] = counts.values.reduce(0, +)
        summary["unassigned"] = counts[nil] ?? 0
        summary["runs"] = try await catalog.runs().count
        summary["runLinks"] = try await catalog.runSessionLinks().count
        var details: [[String: Any]] = []
        for text in arguments.dropFirst(2) {
            guard let id = UUID(uuidString: text), let row = try await catalog.session(id: id) else {
                details.append(["id": text, "found": false]); continue
            }
            details.append([
                "id": text, "found": true, "title": row.title ?? NSNull(), "titleIsCustom": row.titleIsCustom,
                "lifecycle": row.lifecycle.rawValue, "provider": row.session.provider.rawValue,
                "conversationID": row.session.providerConversationID ?? NSNull(),
                "projectID": row.projectID?.uuidString ?? NSNull(),
            ])
        }
        summary["sessions"] = details
        printJSON(summary)

    default:
        fail("unknown command \(command)")
    }
}

do { try await run() } catch { fail("error: \(error)") }
