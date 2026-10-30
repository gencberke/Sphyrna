import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// H1-B item 7: what a crash leaves behind is cleaned up at the next start, without touching
/// another live Loom's sockets or a run whose process still lives.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CrashResidueTests {
    private func socketDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/lr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    /// A socket file nothing listens on: bound, then closed without unlinking (what a crash leaves).
    private func staleSocket(_ path: String) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(descriptor) }
        var address = try unixAddress(path: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    // MARK: Sockets

    @Test func onlySocketsNothingListensOnAreRemovedAndALiveOnesSurvive() async throws {
        let directory = try socketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = directory.appendingPathComponent("h-DEADBEEF.sock").path
        let staleControl = directory.appendingPathComponent("c-0badf00d.sock").path
        let own = directory.appendingPathComponent("h-AAAA1111.sock").path
        let unrelated = directory.appendingPathComponent("notes.sock").path
        let plainFile = directory.appendingPathComponent("h-12345678.sock").path
        for path in [stale, staleControl, own, unrelated] { try staleSocket(path) }
        try Data("x".utf8).write(to: URL(fileURLWithPath: plainFile))
        // Another Loom instance's live hook server.
        let live = directory.appendingPathComponent("h-CAFEF00D.sock").path
        let counters = HookDiagnostics.snapshot()
        let server = try ClaudeHookServer(socketPath: live, authenticationToken: "t") { _ in }
        defer { server.stop() }

        let result = StaleSocketSweep.sweep(directory: directory, ownRunPrefix: "aaaa1111")
        #expect(result.removed == 2)
        #expect(!exists(stale) && !exists(staleControl))
        #expect(exists(live) && exists(own) && exists(unrelated) && exists(plainFile))
        // The live server answered the probe and treated the empty connection as nothing.
        await holds("the probe counts as no malformed message", for: .milliseconds(100)) {
            HookDiagnostics.snapshot().malformedMessages == counters.malformedMessages
        }
        // A second sweep finds nothing more.
        #expect(StaleSocketSweep.sweep(directory: directory, ownRunPrefix: "aaaa1111").removed == 0)
    }

    @Test func theSocketNamesAreExactlyTheOnesTheRuntimeCreates() {
        #expect(StaleSocketSweep.isLoomSocketName("h-0F3A9C21.sock"))
        #expect(StaleSocketSweep.isLoomSocketName("c-0f3a9c21.sock"))
        #expect(!StaleSocketSweep.isLoomSocketName("h-0F3A9C2.sock"))
        #expect(!StaleSocketSweep.isLoomSocketName("x-0F3A9C21.sock"))
        #expect(!StaleSocketSweep.isLoomSocketName("h-0F3A9C2Z.sock"))
        #expect(!StaleSocketSweep.isLoomSocketName("h-0F3A9C21.sock.lock"))
    }

    // MARK: Runs at runtime start

    @Test func startingTheRuntimeClosesRunsAnEarlierLoomLeftOpenAndSweepsItsSockets() async throws {
        let context = try await SessionRuntimeRig.makeContext(startRuntime: false)
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let staleHook = context.socketDirectory.appendingPathComponent("h-DEADBEEF.sock").path
        try staleSocket(staleHook)

        let session = ManagedSession(provider: .claude, workingDirectory: context.home.path)
        try await context.catalog.insertSession(session)
        let gone = ProcessIdentity(pid: 2_999_999, startSeconds: 1_700_000_000, startMicroseconds: 5)
        let me = try #require(ProcessTable.record(pid: getpid())).identity
        let crashed = ManagedRun(id: UUID(), leader: gone, startedAt: Date(timeIntervalSinceNow: -3_600),
                                 state: .running, exitStatus: nil, descendants: [gone])
        let alive = ManagedRun(id: UUID(), leader: me, startedAt: Date(timeIntervalSinceNow: -60),
                               state: .running, exitStatus: nil, descendants: [me])
        let finished = ManagedRun(id: UUID(), leader: gone, startedAt: Date(timeIntervalSinceNow: -7_200),
                                  state: .exited, exitStatus: 0, descendants: [gone])
        for run in [crashed, alive, finished] { try await context.catalog.startRun(run, sessionID: session.id) }
        let endedAt = Date(timeIntervalSinceNow: -7_000)
        try await context.catalog.finishRun(finished.id, endedAt: endedAt, reason: .processExited, exitStatus: 0)

        try await context.runtime.start()

        let runs = try await context.catalog.runs()
        let closed = try #require(runs.first { $0.id == crashed.id })
        #expect(closed.endedAt != nil)
        #expect(closed.endReason == .applicationQuit)
        #expect(closed.exitStatus == nil)
        #expect(try #require(runs.first { $0.id == alive.id }).endedAt == nil)       // its leader lives
        let untouched = try #require(runs.first { $0.id == finished.id })
        #expect(untouched.endReason == .processExited)                               // an ended run is not rewritten
        #expect(abs((untouched.endedAt ?? .distantPast).timeIntervalSince(endedAt)) < 1)
        #expect(!exists(staleHook))
        let journal = DiagnosticJournal.forDataRoot(context.catalog.dataRoot).lines()
        #expect(journal.contains { $0.contains("recovery_runs_closed") })
        #expect(journal.contains { $0.contains("recovery_sockets") })
        #expect((await context.runtime.shutdown()).succeeded)
    }

    /// What the runtime's "runs recovered" hook found in the catalog when it was called.
    private final class RecoveryProbe: Sendable {
        private struct State {
            var catalog: SessionCatalog?
            var openRunsWhenCalled: [Int] = []
        }
        private let state = Mutex(State())
        func use(_ catalog: SessionCatalog) { state.withLock { $0.catalog = catalog } }
        var openRunsWhenCalled: [Int] { state.withLock { $0.openRunsWhenCalled } }
        func called() async {
            let catalog = state.withLock { $0.catalog }
            let open = (try? await catalog?.runs().filter { $0.endedAt == nil }.count) ?? -1
            state.withLock { $0.openRunsWhenCalled.append(open) }
        }
    }

    @Test func theRuntimeSaysRunsAreRecoveredOnlyAfterTheCrashedOnesAreClosed() async throws {
        let probe = RecoveryProbe()
        let context = try await SessionRuntimeRig.makeContext(startRuntime: false, runsRecovered: { await probe.called() })
        defer { context.cleanup() }
        probe.use(context.catalog)
        let session = ManagedSession(provider: .claude, workingDirectory: context.home.path)
        try await context.catalog.insertSession(session)
        let gone = ProcessIdentity(pid: 2_999_999, startSeconds: 1_700_000_000, startMicroseconds: 5)
        let crashed = ManagedRun(id: UUID(), leader: gone, startedAt: Date(timeIntervalSinceNow: -3_600),
                                 state: .running, exitStatus: nil, descendants: [gone])
        try await context.catalog.startRun(crashed, sessionID: session.id)

        #expect(probe.openRunsWhenCalled.isEmpty, "nothing is said before the runtime starts")
        try await context.runtime.start()
        #expect(probe.openRunsWhenCalled == [0], "called once, with the crashed run already closed in the catalog")
        let found = try await context.catalog.sessionsEndedByQuit(since: Date(timeIntervalSinceNow: -86_400), limit: 5)
        #expect(found.map(\.session.session.id) == [session.id], "what Home reads then lists the crashed session")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func runsThatAreOpenWhenNothingCrashedStayTheirOwn() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let (launch, screen) = try await SessionRuntimeRig.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        // A run of this process is open while the app runs; closing abandoned runs leaves it alone.
        #expect(try await context.catalog.closeAbandonedRuns() == 0)
        #expect(try await context.catalog.runs().first { $0.id == launch.runID }?.endedAt == nil)
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(try await context.catalog.runs().first { $0.id == launch.runID }?.endedAt != nil)
    }

    // MARK: Run directories

    @Test func aRunDirectoryWithAnUnreadableLedgerIsReportedOnceAndMovedToQuarantine() throws {
        let runs = FileManager.default.temporaryDirectory.appendingPathComponent("loom-runs-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runs) }
        let broken = runs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("this is not a ledger".utf8).write(to: broken.appendingPathComponent("ledger.json"))

        let first = PreviousRunRecovery.recoverBlocking(runsDirectory: runs, current: nil, scopeTimeout: 1)
        #expect(first.leftovers.count == 1)
        #expect(first.leftovers[0].contains("unreadable"))
        #expect(first.quarantinedDirectories == 1)
        #expect(!exists(broken.path))
        let quarantined = runs.appendingPathComponent("quarantine/\(broken.lastPathComponent)/ledger.json").path
        #expect(exists(quarantined))

        // The next launch does not report or rewrite it again.
        let second = PreviousRunRecovery.recoverBlocking(runsDirectory: runs, current: nil, scopeTimeout: 1)
        #expect(second.leftovers.isEmpty && second.quarantinedDirectories == 0 && second.removedDirectories == 0)
        #expect(exists(quarantined))
    }

    @Test func theQuarantineKeepsOnlyTheNewestFew() throws {
        let runs = FileManager.default.temporaryDirectory.appendingPathComponent("loom-runs-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runs) }
        for _ in 0..<(PreviousRunRecovery.quarantineKeepCount + 3) {
            let broken = runs.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: broken.appendingPathComponent("ledger.json"))
            _ = PreviousRunRecovery.recoverBlocking(runsDirectory: runs, current: nil, scopeTimeout: 1)
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: runs.appendingPathComponent("quarantine").path)
        #expect(kept.count == PreviousRunRecovery.quarantineKeepCount)
    }
}
