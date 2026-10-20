import Foundation
import SQLite3
import Testing
@testable import LoomCore

/// V22 part 2: the side chat's card in the catalog. Three nullable columns link it to its parent (added on open, no version
/// bump), and every list, count and search leaves it out.
@Suite(.serialized)
struct SideChatCatalogTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-sidechat-catalog-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let leader = ProcessIdentity(pid: 7, startSeconds: 1, startMicroseconds: 2)
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + seconds) }

    private func run(started: Double) -> ManagedRun {
        ManagedRun(id: UUID(), leader: leader, startedAt: at(started), state: .running, exitStatus: nil, descendants: [leader])
    }

    /// A session and, forked from it, a side chat created later whose last use is the oldest of the catalog.
    private struct Pair {
        let catalog: SessionCatalog
        let project: UUID
        let parent: UUID
        let side: UUID
        let root: URL
    }

    private func pair(lifecycle: SessionLifecycle = .idle) async throws -> Pair {
        let root = try temporaryRoot()
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await catalog.addProject(path: folder.path).project.id
        let parent = ManagedSession(provider: .claude, providerConversationID: "parent-conv", workingDirectory: folder.path)
        try await catalog.insertSession(parent, title: "Parent", createdAt: at(10), lastUsedAt: at(10), lifecycle: lifecycle,
                                        projectID: project)
        let side = ManagedSession(provider: .claude, providerConversationID: "side-conv", workingDirectory: folder.path)
        try await catalog.insertSession(
            side, title: "Parent side", createdAt: at(20), lastUsedAt: at(5), lifecycle: lifecycle, projectID: project,
            sideChat: SideChatLink(parentSessionID: parent.id, forkedAt: at(19)))
        return Pair(catalog: catalog, project: project, parent: parent.id, side: side.id, root: root)
    }

    @Test func theLinkIsStoredAndDecoded() async throws {
        let p = try await pair()
        defer { try? FileManager.default.removeItem(at: p.root) }
        let side = try #require(try await p.catalog.session(id: p.side))
        #expect(side.isSideChat)
        #expect(side.sideChat == SideChatLink(parentSessionID: p.parent, forkedAt: at(19), firstUUID: nil))
        #expect(try await p.catalog.session(id: p.parent)?.isSideChat == false)
        // The first message's uuid is written once, and the title is the first line, written once.
        try await p.catalog.setSideFirstUUID("uuid-1", sessionID: p.side)
        try await p.catalog.setSideFirstUUID("uuid-2", sessionID: p.side)
        try await p.catalog.setSideChatTitle("Why does the second line fail?", sessionID: p.side)
        try await p.catalog.setSideChatTitle("A later question", sessionID: p.side)
        let again = try #require(try await p.catalog.session(id: p.side))
        #expect(again.sideChat?.firstUUID == "uuid-1")
        // The seed row was inserted with a title; a fresh card has none and takes the first question's.
        #expect(again.title == "Parent side")
        // Neither is ever written for a session that is not a side chat.
        try await p.catalog.setSideFirstUUID("nope", sessionID: p.parent)
        try await p.catalog.setSideChatTitle("nope", sessionID: p.parent)
        let parent = try #require(try await p.catalog.session(id: p.parent))
        #expect(parent.sideChat == nil && parent.title == "Parent")
        #expect(try await p.catalog.sideChats(of: p.parent).map(\.session.id) == [p.side])
        #expect(try await p.catalog.sideChatCount(of: p.parent) == 1)
        #expect(try await p.catalog.sideChatProviderIDs() == ["side-conv"])
    }

    /// A relaunch restores the supervisor's sessions from the catalog. A side chat is no list's, but it is the runtime's: without
    /// it there, its next launch (a plain resume of the fork's id) would find no session.
    @Test func aRelaunchedSupervisorStillKnowsTheSideChatsItCanResume() async throws {
        let p = try await pair()
        defer { try? FileManager.default.removeItem(at: p.root) }
        let reopened = try await ProcessSupervisor.restoring(ledger: OwnershipLedger(), catalog: p.catalog)
        #expect(await reopened.session(id: p.parent) != nil)
        #expect(await reopened.session(id: p.side)?.providerConversationID == "side-conv", "the side chat is restored")
        // Every list still leaves it out.
        #expect(try await p.catalog.sessions().map(\.session.id) == [p.parent])
        #expect((await reopened.shutdown()).succeeded)
    }

    @Test func theColumnsAreAddedOnOpenAndAbsentInAnOldCatalog() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        let id: UUID
        do {
            let catalog = try SessionCatalog(url: url)
            let session = ManagedSession(provider: .claude, providerConversationID: "old", workingDirectory: "/tmp/old")
            try await catalog.insertSession(session, title: "Old")
            id = session.id
        }
        // The catalog an earlier build wrote: no side chat columns, and the version it always had.
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        for column in ["parent_session_id", "forked_at", "side_first_uuid"] {
            #expect(sqlite3_exec(handle, "ALTER TABLE sessions DROP COLUMN \(column)", nil, nil, nil) == SQLITE_OK)
        }
        var version: Int32 = 0
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil)
        if sqlite3_step(statement) == SQLITE_ROW { version = sqlite3_column_int(statement, 0) }
        sqlite3_finalize(statement)
        sqlite3_close(handle)
        #expect(version == SessionCatalog.schemaVersion)

        let reopened = try SessionCatalog(url: url)
        let old = try #require(try await reopened.session(id: id))
        #expect(old.sideChat == nil && old.title == "Old")
        #expect(try await reopened.sessions().map(\.session.id) == [id])
        // And the opened catalog takes a side chat, with the same version.
        let side = ManagedSession(provider: .claude, providerConversationID: "new", workingDirectory: "/tmp/old")
        try await reopened.insertSession(side, sideChat: SideChatLink(parentSessionID: id, forkedAt: at(1)))
        #expect(try await reopened.session(id: side.id)?.sideChat?.parentSessionID == id)
        #expect(try await reopened.sessions().map(\.session.id) == [id])
    }

    /// Every list, count and search of the catalog, over a project that holds a session and a newer side chat: none shows it.
    @Test func everyFencedQueryLeavesOutASideChat() async throws {
        let p = try await pair(lifecycle: .active)
        defer { try? FileManager.default.removeItem(at: p.root) }
        let catalog = p.catalog
        let parent = p.parent, side = p.side, project = p.project
        // A quit-ended run of each, for Continue.
        for id in [parent, side] {
            let started = run(started: 30)
            try await catalog.startRun(started, sessionID: id)
            try await catalog.finishRun(started.id, endedAt: at(40), reason: .applicationQuit, exitStatus: nil)
        }

        func ids(_ sessions: [CatalogSession]) -> [UUID] { sessions.map(\.session.id) }
        var sites: [(String, [UUID])] = []
        sites.append(("sessions()", ids(try await catalog.sessions())))
        for order in [CatalogOrder.recentActivity, .creation] {
            for scope in [CatalogScope.all, .project(project)] {
                let page = try await catalog.sessionPage(CatalogQuery(scope: scope, order: order), after: nil)
                sites.append(("sessionPage \(order) \(scope)", ids(page.sessions)))
            }
            let found = try await catalog.searchSessions(search: "Parent", order: order, groupLimit: 10)
            sites.append(("searchSessions \(order)", ids(found.sessions)))
        }
        sites.append(("listedSession(side)", ids(try await catalog.listedSession(id: side).map { [$0] } ?? [])))
        sites.append(("sessionsEndedByQuit", try await catalog.sessionsEndedByQuit(since: at(0), limit: 10).map(\.session.session.id)))
        for (name, found) in sites {
            #expect(!found.contains(side), "\(name) lists a side chat")
        }
        // The parent is where it was, in every list that could show it.
        #expect(sites.first { $0.0 == "sessions()" }?.1 == [parent])
        #expect(sites.first { $0.0 == "sessionsEndedByQuit" }?.1 == [parent])

        // Counts and single values.
        #expect(try await catalog.sessionCounts() == [project: 1])
        #expect(try await catalog.sessionCount(activeSince: at(0)) == 1)
        #expect(try await catalog.oldestLastUsed(lifecycle: .active) == at(10), "the side chat's older use time is not counted")
        #expect(try await catalog.oldestStaleCandidate() == at(10))
        #expect(try await catalog.lastUsedProjectID() == project)
        // Cleanup never classifies a side chat as stale.
        let stale = try await catalog.classifyStale(before: at(1_000))
        #expect(stale == [parent])
        #expect(try await catalog.session(id: side)?.lifecycle == .active)

        // The project's removal count: only its listed sessions block it, and the side chat's own rows stay for the runtime.
        do {
            try await catalog.removeProject(id: project)
            Issue.record("a project with a listed session was removed")
        } catch SessionCatalogError.projectNotEmpty {}
        // The selective reads the runtime uses still find it.
        #expect(try await catalog.session(id: side) != nil)
        #expect(try await catalog.session(provider: .claude, conversationID: "side-conv")?.session.id == side)
    }
}
