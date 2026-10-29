import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

/// V05: the catalog reads behind Home. Continue lists sessions whose latest run was ended by Quit (or by the
/// recovery that closes a run a crash left open), and no session the user stopped or resumed since.
@Suite(.serialized)
struct SessionCatalogHomeTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-catalog-home-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let leader = ProcessIdentity(pid: 7, startSeconds: 1, startMicroseconds: 2)

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + seconds) }

    private func run(started: Double) -> ManagedRun {
        ManagedRun(id: UUID(), leader: leader, startedAt: at(started), state: .running, exitStatus: nil, descendants: [leader])
    }

    private func session(_ catalog: SessionCatalog, title: String, project: UUID? = nil, created: Double = 0) async throws -> UUID {
        let managed = ManagedSession(provider: .claude, workingDirectory: "/tmp/home-tests")
        try await catalog.insertSession(managed, title: title, createdAt: at(created), lastUsedAt: at(created),
                                        lifecycle: .idle, projectID: project)
        return managed.id
    }

    /// Starts a run for the session at `start` and ends it at `end` with `reason`. The session was used until
    /// the end (a finished turn), so the run's last activity is its end.
    @discardableResult
    private func ended(_ catalog: SessionCatalog, _ id: UUID, start: Double, end: Double,
                       reason: ManagedRunEndReason) async throws -> UUID {
        let value = run(started: start)
        try await catalog.startRun(value, sessionID: id)
        try await catalog.markActivity(sessionID: id, at: at(end))
        try await catalog.finishRun(value.id, endedAt: at(end), reason: reason, exitStatus: nil)
        return value.id
    }

    @Test func onlyARunQuitEndedIsOffered() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let quit = try await session(catalog, title: "quit")
        let stopped = try await session(catalog, title: "stopped by the user")
        let exited = try await session(catalog, title: "exited by itself")
        let idled = try await session(catalog, title: "idle stop")
        let running = try await session(catalog, title: "still running")
        try await ended(catalog, quit, start: 10, end: 100, reason: .applicationQuit)
        try await ended(catalog, stopped, start: 10, end: 110, reason: .requested)
        try await ended(catalog, exited, start: 10, end: 120, reason: .processExited)
        try await ended(catalog, idled, start: 10, end: 130, reason: .idle)
        try await catalog.startRun(run(started: 140), sessionID: running)

        let found = try await catalog.sessionsEndedByQuit(since: at(0), limit: 10)
        #expect(found.map(\.session.session.id) == [quit])
        #expect(found.first?.endedAt == at(100))
        #expect(found.first?.session.title == "quit")
    }

    @Test func aLaterRunTakesTheSessionOffTheList() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let resumed = try await session(catalog, title: "resumed")
        let resumedAndStopped = try await session(catalog, title: "resumed, then stopped")
        let quitAgain = try await session(catalog, title: "quit twice")
        try await ended(catalog, resumed, start: 10, end: 100, reason: .applicationQuit)
        try await catalog.startRun(run(started: 200), sessionID: resumed)
        try await ended(catalog, resumedAndStopped, start: 10, end: 100, reason: .applicationQuit)
        try await ended(catalog, resumedAndStopped, start: 200, end: 300, reason: .requested)
        try await ended(catalog, quitAgain, start: 10, end: 100, reason: .applicationQuit)
        let second = try await ended(catalog, quitAgain, start: 200, end: 400, reason: .applicationQuit)

        let found = try await catalog.sessionsEndedByQuit(since: at(0), limit: 10)
        // Only the session whose latest run Quit ended, once, with that run's end.
        #expect(found.map(\.session.session.id) == [quitAgain])
        #expect(found.first?.runID == second && found.first?.endedAt == at(400))
    }

    @Test func aRunThatMovedToAnotherSessionCountsForTheLastOne() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let first = try await session(catalog, title: "before /clear")
        let value = run(started: 10)
        try await catalog.startRun(value, sessionID: first)
        let cleared = ManagedSession(provider: .claude, workingDirectory: "/tmp/home-tests")
        try await catalog.transitionRun(value.id, from: first, to: cleared, at: at(50))
        try await catalog.finishRun(value.id, endedAt: at(100), reason: .applicationQuit, exitStatus: nil)

        let found = try await catalog.sessionsEndedByQuit(since: at(0), limit: 10)
        #expect(found.map(\.session.session.id) == [cleared.id])
    }

    @Test func aCrashLeftRunClosedAtTheNextLaunchIsOfferedToo() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let id = try await session(catalog, title: "crashed")
        try await catalog.startRun(run(started: 10), sessionID: id)
        #expect(try await catalog.sessionsEndedByQuit(since: at(0), limit: 10).isEmpty, "an open run is not an ended one")
        #expect(try await catalog.closeAbandonedRuns(at: at(500), isLive: { _ in false }) == 1)

        let found = try await catalog.sessionsEndedByQuit(since: at(0), limit: 10)
        // The run's recorded end is the relaunch; the session was last used when the run began.
        #expect(found.map(\.session.session.id) == [id] && found.first?.endedAt == at(10))
    }

    @Test func aCrashIsDatedByTheLastUseNotByTheRelaunchAndLeavesTheWindowWithIt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let day: Double = 86_400
        let recent = try await session(catalog, title: "crashed two hours before the relaunch")
        let longAgo = try await session(catalog, title: "crashed ten days before the relaunch")
        let quit = try await session(catalog, title: "quit cleanly")
        try await catalog.startRun(run(started: 1_000), sessionID: longAgo)
        try await catalog.markActivity(sessionID: longAgo, at: at(3_000))
        try await catalog.startRun(run(started: 10 * day - 9_000), sessionID: recent)
        try await catalog.markActivity(sessionID: recent, at: at(10 * day - 7_200))
        try await ended(catalog, quit, start: 500, end: 2_000, reason: .applicationQuit)
        // Loom comes back ten days later and closes both open runs at that moment.
        #expect(try await catalog.closeAbandonedRuns(at: at(10 * day), isLive: { _ in false }) == 2)

        // The week before the relaunch holds the recent crash only: the old one was last used days earlier,
        // though its recorded end is the relaunch.
        let week = try await catalog.sessionsEndedByQuit(since: at(10 * day - 7 * day), limit: 10)
        #expect(week.map(\.session.session.id) == [recent])
        #expect(week.first?.endedAt == at(10 * day - 7_200), "the last use, not the relaunch")

        let all = try await catalog.sessionsEndedByQuit(since: at(0), limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.session.session.id, $0.endedAt) })
        #expect(byID[longAgo] == at(3_000))
        #expect(byID[quit] == at(2_000), "a Quit keeps its own end")
        #expect(all.map(\.session.session.id) == [recent, longAgo, quit], "newest by that time")
    }

    @Test func aRunNeverReadsAsEndingBeforeItBeganOrAfterItsRecordedEnd() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let untouched = try await session(catalog, title: "resumed, nothing typed", created: 0)
        let later = try await session(catalog, title: "used after the run ended", created: 0)
        let value = run(started: 100)
        try await catalog.startRun(value, sessionID: untouched)
        try await catalog.finishRun(value.id, endedAt: at(160), reason: .applicationQuit, exitStatus: nil)
        let other = run(started: 100)
        try await catalog.startRun(other, sessionID: later)
        try await catalog.finishRun(other.id, endedAt: at(160), reason: .applicationQuit, exitStatus: nil)
        try await catalog.markActivity(sessionID: later, at: at(900))

        let all = try await catalog.sessionsEndedByQuit(since: at(0), limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.session.session.id, $0.endedAt) })
        #expect(byID[untouched] == at(100), "not before the run began")
        #expect(byID[later] == at(160), "not after its recorded end")
    }

    @Test func theListIsNewestFirstBoundedAndLimitedToTheWindow() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var ids: [UUID] = []
        for index in 0..<5 {
            let id = try await session(catalog, title: "s\(index)")
            try await ended(catalog, id, start: Double(10 + index), end: Double(100 + index * 10), reason: .applicationQuit)
            ids.append(id)
        }
        let all = try await catalog.sessionsEndedByQuit(since: at(0), limit: 10)
        #expect(all.map(\.session.session.id) == ids.reversed())
        let two = try await catalog.sessionsEndedByQuit(since: at(0), limit: 2)
        #expect(two.map(\.session.session.id) == [ids[4], ids[3]])
        // Runs that ended before the window are not offered any more.
        let recent = try await catalog.sessionsEndedByQuit(since: at(125), limit: 10)
        #expect(recent.map(\.session.session.id) == [ids[4], ids[3]])
        #expect(try await catalog.sessionsEndedByQuit(since: at(0), limit: 0).count == 1, "a limit below one reads one")
    }

    @Test func theReadsWriteNothingAndKeepTheSchema() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        let catalog = try SessionCatalog(url: url)
        let id = try await session(catalog, title: "quit")
        try await ended(catalog, id, start: 10, end: 100, reason: .applicationQuit)
        let before = try Data(contentsOf: url)
        _ = try await catalog.sessionsEndedByQuit(since: at(0), limit: 10)
        _ = try await catalog.sessionCount(activeSince: at(0))
        _ = try await catalog.lastUsedProjectID()
        #expect(SessionCatalog.schemaVersion == 3)
        #expect(try Data(contentsOf: url) == before, "Home's reads leave the catalog file as it was")
    }

    @Test func sessionsUsedTodayAndTheLastUsedProject() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let folder = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let other = root.appendingPathComponent("billing", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let api = try await catalog.addProject(path: folder.path).project
        let billing = try await catalog.addProject(path: other.path).project
        #expect(try await catalog.lastUsedProjectID() == nil)
        #expect(try await catalog.sessionCount(activeSince: at(0)) == 0)

        let old = try await session(catalog, title: "old", project: billing.id, created: 10)
        let recent = try await session(catalog, title: "recent", project: api.id, created: 500)
        let loose = try await session(catalog, title: "no project", created: 900)
        try await catalog.markActivity(sessionID: old, at: at(100))
        try await catalog.markActivity(sessionID: recent, at: at(600))
        try await catalog.markActivity(sessionID: loose, at: at(950))

        // Three sessions were used since 0; two since 550; the newest session has no project, so the project
        // of the newest one that has one is the answer.
        #expect(try await catalog.sessionCount(activeSince: at(0)) == 3)
        #expect(try await catalog.sessionCount(activeSince: at(550)) == 2)
        #expect(try await catalog.sessionCount(activeSince: at(2_000)) == 0)
        #expect(try await catalog.lastUsedProjectID() == api.id)
    }
}
