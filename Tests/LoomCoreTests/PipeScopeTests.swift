import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import LoomCore

private final class PipeBundleAnchor: NSObject {}

/// Temporary folders of one test (run host bundles, the test child's copy),
/// removed with their hosts' LaunchServices records when the test ends.
private final class PipeScratch: Sendable {
    private let folders = Mutex<[URL]>([])
    private let child = Mutex<String?>(nil)

    func folder(_ prefix: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
        folders.withLock { $0.append(folder) }
        return folder
    }

    func copy(of executable: URL) -> String {
        child.withLock { path in
            if let path { return path }
            let place = self.folder("loom-pipe-child")
            try? FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            let copy = place.appendingPathComponent(executable.lastPathComponent)
            try? FileManager.default.copyItem(at: executable, to: copy)
            path = copy.path
            return copy.path
        }
    }

    deinit {
        for folder in folders.withLock({ $0 }) { RunScopeLauncher.removeOwnedBundle(in: folder) }
    }
}

/// Collects a pipe child's output. Large tests keep only counts.
private final class PipeCollector: PipeOutputSink {
    struct State {
        var output = Data()
        var error = Data()
        var outputCount = 0
        var errorCount = 0
        var outputEnded = false
        var errorEnded = false
    }

    private let state = Mutex(State())
    private let keep: Bool

    init(keep: Bool = true) { self.keep = keep }

    func receive(_ data: Data, from stream: PipeStream) {
        state.withLock {
            switch stream {
            case .standardOutput:
                $0.outputCount += data.count
                if keep { $0.output.append(data) }
            case .standardError:
                $0.errorCount += data.count
                if keep { $0.error.append(data) }
            }
        }
    }

    func ended(_ stream: PipeStream) {
        state.withLock {
            if stream == .standardOutput { $0.outputEnded = true } else { $0.errorEnded = true }
        }
    }

    var snapshot: State { state.withLock { $0 } }
    var output: String { String(decoding: snapshot.output, as: UTF8.self) }
    var error: String { String(decoding: snapshot.error, as: UTF8.self) }

    /// The first JSON line of stdout (every fixture mode announces itself with one).
    func firstObject(timeout: Double = 5) async throws -> [String: Any] {
        try await wait(timeout: timeout, "a JSON line") {
            output.split(separator: "\n").first.flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            } != nil
        }
        let line = try #require(output.split(separator: "\n").first)
        return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    func wait(timeout: Double = 10, _ what: String, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw LoomError.message("Timed out waiting for \(what): \(output.suffix(200))")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class Finished: Sendable {
    private let list = Mutex<[String]>([])
    func add(_ name: String) { list.withLock { $0.append(name) } }
    var names: [String] { list.withLock { $0 } }
}

/// Pipe children in real run scopes: ownership, Stop and Quit as for terminals.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct PipeScopeTests {
    private let scratch = PipeScratch()

    private var productsDirectory: URL {
        Bundle(for: PipeBundleAnchor.self).bundleURL.deletingLastPathComponent()
    }

    /// Run hosts are their own TCC-responsible apps: scoped children run from
    /// a copy outside ~/Documents.
    private var testChild: String {
        scratch.copy(of: productsDirectory.appendingPathComponent("loom-test-child"))
    }

    private func makeSupervisor() throws -> ProcessSupervisor {
        let root = scratch.folder("loom-pipe-scope")
        let bundle = try RunScopeLauncher.assembleOwnedBundle(
            executable: productsDirectory.appendingPathComponent("loom-run-host"), in: root
        )
        return try ProcessSupervisor(scopeLauncher: RunScopeLauncher(
            hostBundle: bundle, socketDirectory: root.appendingPathComponent("s")
        ))
    }

    private func start(_ arguments: [String], supervisor: ProcessSupervisor,
                       sink: PipeCollector, scope: RunScope? = nil,
                       inputLimit: Int = PipeEndpoint.defaultInputLimit,
                       sessionID: UUID = UUID(), conversationID: String? = nil,
                       markers: Bool = true) async throws -> ManagedPipeLaunch {
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic, providerConversationID: conversationID,
            workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: markers ? supervisor.ownershipRunID : UUID(), sessionID: sessionID
        )
        return try await supervisor.launchPipes(
            sessionID: sessionID, executable: testChild, arguments: arguments,
            environment: environment, outputSink: sink, inputLimit: inputLimit, scope: scope
        )
    }

    private func liveMembers(_ coalition: UInt64) throws -> [RunScopeMember] {
        try RunScopeTable.members(coalitionID: coalition).filter { !$0.zombie }
    }

    private func live(_ pid: Int32) throws -> Bool {
        try ProcessTable.snapshot().contains { $0.identity.pid == pid && !$0.zombie }
    }

    /// Pipes this process has open; a leak per run shows as growth.
    private func openPipeCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return names.compactMap { Int32($0) }.filter { descriptor in
            var info = stat()
            return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO
        }.count
    }

    /// Stops a run whose child may already have left. A child that exits on its
    /// own ends its run (timing-dependent: release builds are quicker), so a
    /// stop that finds no run is fine once the run is gone and its scope released.
    private func stopUnlessAlreadyEnded(_ supervisor: ProcessSupervisor, _ launch: ManagedPipeLaunch) async throws {
        do {
            let report = try await supervisor.stop(sessionID: launch.session.id)
            #expect(report.succeeded, "\(report.errors)")
        } catch SessionManagementError.sessionNotRunning {
            for _ in 0..<500 where await !supervisor.runningSessionIDs().isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(await supervisor.runningSessionIDs().isEmpty)
        for _ in 0..<500 where await supervisor.ledgerSnapshot().scopes?.isEmpty != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
    }

    @Test func echoRoundTripOnAllThreeStreams() async throws {
        let supervisor = try makeSupervisor()
        let sink = PipeCollector()
        let launch = try await start(["pipe-echo"], supervisor: supervisor, sink: sink)
        let hello = try await sink.firstObject()
        #expect(hello["pid"] as? Int32 == launch.pipe.pid)
        // The child runs in the run's own coalition, on pipes, not a terminal.
        let coalition = try #require(ProcessTable.resourceCoalition(pid: launch.pipe.pid))
        #expect(coalition != ProcessTable.resourceCoalition(pid: getpid()))

        try await launch.pipe.write(Data("hello\n".utf8))
        try await launch.pipe.write(Data("again\n".utf8))
        try await sink.wait("the echoes") {
            sink.output.hasSuffix("echo: hello\necho: again\n") && sink.error == "err: hello\nerr: again\n"
        }

        let report = try await supervisor.stop(sessionID: launch.session.id)
        // Closing stdin was enough: the child left by itself, no signal needed.
        #expect(report.succeeded, "\(report.errors)")
        #expect(report.signals.isEmpty)
        #expect(sink.snapshot.outputEnded && sink.snapshot.errorEnded)
        #expect(await launch.pipe.exitStatus() == 0)
        await #expect(throws: PipeInputError.self) { try await launch.pipe.write(Data("late\n".utf8)) }
        #expect(try liveMembers(coalition).isEmpty)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func managedPipeRejectsRevokedAdmissionBeforeWriting() async throws {
        let supervisor = try makeSupervisor()
        let sink = PipeCollector()
        do {
            let launch = try await start(["pipe-echo"], supervisor: supervisor, sink: sink)
            _ = try await sink.firstObject()
            let outcome = await launch.pipe.writeManaged(Data("revoked-input\n".utf8), admission: { _ in nil })
            #expect(outcome == .deferred)
            try await launch.pipe.write(Data("ordinary-input\n".utf8))
            try await sink.wait("the ordinary echo") { sink.output.contains("echo: ordinary-input\n") }
            #expect(!sink.output.contains("revoked-input"))
            #expect(try await supervisor.stop(sessionID: launch.session.id).succeeded)
        } catch {
            _ = await supervisor.shutdown()
            throw error
        }
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func managedPipeNeverSendsARevokedWriteAfterBackpressure() async throws {
        let supervisor = try makeSupervisor()
        let sink = PipeCollector()
        do {
            let launch = try await start(["pipe-count", "usr1"], supervisor: supervisor, sink: sink, inputLimit: 64 * 1024)
            _ = try await sink.firstObject()
            let largeCount = 200 * 1_024
            let first = Task { try await launch.pipe.write(Data(repeating: 0x41, count: largeCount)) }
            try await Task.sleep(for: .milliseconds(100))
            let pending = Task {
                await launch.pipe.writeManaged(Data("revoked-input\n".utf8), admission: { _ in nil })
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(kill(launch.pipe.pid, SIGUSR1) == 0)
            try await first.value
            #expect(await pending.value == .deferred)
            await launch.pipe.closeInput()
            try await sink.wait("the byte count") { sink.output.contains("stdinBytes") }
            let line = try #require(sink.output.split(separator: "\n").last)
            let counted = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(counted["stdinBytes"] as? Int == largeCount)
            try await stopUnlessAlreadyEnded(supervisor, launch)
        } catch {
            _ = await supervisor.shutdown()
            throw error
        }
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func managedPipeCancellationWinsBeforeSyscall() async throws {
        let supervisor = try makeSupervisor()
        let sink = PipeCollector()
        do {
            let launch = try await start(["pipe-echo"], supervisor: supervisor, sink: sink)
            _ = try await sink.firstObject()
            let entered = DispatchSemaphore(value: 0)
            let proceed = DispatchSemaphore(value: 0)
            let input = Task {
                await launch.pipe.writeManaged(Data("cancelled-input\n".utf8)) { write in
                    entered.signal()
                    _ = proceed.wait(timeout: .now() + 5)
                    return try write()
                }
            }
            let reachedGate = await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value
            input.cancel()
            proceed.signal()
            #expect(reachedGate)
            #expect(await input.value == .deferred)

            let accepted = await launch.pipe.writeManaged(Data("accepted-input\n".utf8)) { write in try write() }
            #expect(accepted == .submitted)
            try await sink.wait("the admitted echo") { sink.output.contains("echo: accepted-input\n") }
            #expect(!sink.output.contains("cancelled-input"))
            #expect(try await supervisor.stop(sessionID: launch.session.id).succeeded)
        } catch {
            _ = await supervisor.shutdown()
            throw error
        }
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func largeOutputOnBothStreamsDoesNotDeadlock() async throws {
        let supervisor = try makeSupervisor()
        let sink = PipeCollector(keep: false)
        let mebibytes = 8
        let launch = try await start(["pipe-flood", String(mebibytes)], supervisor: supervisor, sink: sink)
        // The child never reads stdin and writes both pipes in turn: it can only
        // finish if both are drained at once.
        try await sink.wait(timeout: 30, "both streams to end") {
            sink.snapshot.outputEnded && sink.snapshot.errorEnded
        }
        #expect(sink.snapshot.outputCount == mebibytes << 20)
        #expect(sink.snapshot.errorCount == mebibytes << 20)
        // The child is gone: writing to it fails with an error, not SIGPIPE.
        var status: Int32?
        for _ in 0..<200 where status == nil {
            status = await launch.pipe.exitStatus()
            if status == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(status == 0)
        await #expect(throws: PipeInputError.self) { try await launch.pipe.write(Data("x\n".utf8)) }
        try await stopUnlessAlreadyEnded(supervisor, launch)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func stdinBackpressureStallsWritersUntilTheChildReads() async throws {
        let supervisor = try makeSupervisor()
        let sink = PipeCollector()
        let limit = 64 * 1024
        let launch = try await start(["pipe-count", "usr1"], supervisor: supervisor, sink: sink,
                                     inputLimit: limit)
        _ = try await sink.firstObject()
        let pipe = launch.pipe
        let big = 200 * 1024
        let finished = Finished()
        let first = Task {
            try await pipe.write(Data(repeating: 0x41, count: big))
            finished.add("big")
        }
        try await Task.sleep(for: .milliseconds(100))
        // Queued behind a full queue: waits instead of growing memory.
        let second = Task {
            try await pipe.write(Data(repeating: 0x42, count: 10))
            finished.add("small")
        }
        try await Task.sleep(for: .milliseconds(300))
        // The child has not read a byte, so neither write can be done.
        #expect(finished.names.isEmpty)

        #expect(kill(launch.pipe.pid, SIGUSR1) == 0)
        try await first.value
        try await second.value
        #expect(finished.names.sorted() == ["big", "small"])
        await pipe.closeInput()
        try await sink.wait("the byte count") { sink.output.contains("stdinBytes") }
        let lines = sink.output.split(separator: "\n")
        let last = try #require(lines.last)
        let counted = try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        #expect(counted["stdinBytes"] as? Int == big + 10)
        try await stopUnlessAlreadyEnded(supervisor, launch)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// A child that ignores stdin end-of-file is asked first (grace period),
    /// then SIGTERM; one that also ignores SIGTERM gets SIGKILL.
    @Test func stopEscalatesAfterTheGracePeriodForAChildThatIgnoresStdinEof() async throws {
        let supervisor = try makeSupervisor()
        let grace = 0.4

        let lingerSink = PipeCollector()
        let linger = try await start(["pipe-linger"], supervisor: supervisor, sink: lingerSink)
        _ = try await lingerSink.firstObject()
        let lingerCoalition = try #require(ProcessTable.resourceCoalition(pid: linger.pipe.pid))
        let polite = try await supervisor.stop(sessionID: linger.session.id, graceSeconds: grace,
                                                  inputCloseGraceSeconds: grace)
        #expect(polite.succeeded, "\(polite.errors)")
        #expect(polite.signals.first?.signal == SIGTERM)
        #expect(!polite.signals.contains { $0.signal == SIGHUP || $0.signal == SIGKILL })
        #expect(polite.elapsedSeconds >= grace)
        #expect(try !live(linger.pipe.pid))
        #expect(try liveMembers(lingerCoalition).isEmpty)

        let stubbornSink = PipeCollector()
        let stubborn = try await start(["stubborn"], supervisor: supervisor, sink: stubbornSink)
        _ = try await stubbornSink.firstObject()
        let stubbornCoalition = try #require(ProcessTable.resourceCoalition(pid: stubborn.pipe.pid))
        let forced = try await supervisor.stop(sessionID: stubborn.session.id, graceSeconds: grace,
                                                  inputCloseGraceSeconds: grace)
        #expect(forced.succeeded, "\(forced.errors)")
        #expect(Array(forced.signals.map(\.signal).prefix(2)) == [SIGTERM, SIGKILL])
        #expect(forced.elapsedSeconds >= 2 * grace)
        #expect(try !live(stubborn.pipe.pid))
        #expect(try liveMembers(stubbornCoalition).isEmpty)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// Stop verifies the whole scope: an escaped descendant of a pipe child
    /// dies with it, and the scope is shown empty.
    @Test func stopDrainsTheScopeOfAPipeChildWithEscapedDescendants() async throws {
        let supervisor = try makeSupervisor()
        let sink = PipeCollector()
        let launch = try await start(["escape"], supervisor: supervisor, sink: sink)
        let hello = try await sink.firstObject()
        let escaped = try #require(hello["descendantPID"] as? Int32)
        let coalition = try #require(ProcessTable.resourceCoalition(pid: launch.pipe.pid))
        #expect(try live(escaped))
        #expect(try liveMembers(coalition).count >= 3)

        let report = try await supervisor.stop(sessionID: launch.session.id, graceSeconds: 0.2,
                                                    inputCloseGraceSeconds: 0.2)
        #expect(report.succeeded, "\(report.errors)")
        #expect(try !live(escaped))
        #expect(try !live(launch.pipe.pid))
        #expect(try liveMembers(coalition).isEmpty)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// Quit ends pipe children as it ends terminal ones: stdin closes, the
    /// stragglers get SIGTERM then SIGKILL (never a hang-up), all verified.
    @Test func quitEndsPipeChildren() async throws {
        let supervisor = try makeSupervisor()
        let echoSink = PipeCollector(), lingerSink = PipeCollector(), stubbornSink = PipeCollector()
        let echo = try await start(["pipe-echo"], supervisor: supervisor, sink: echoSink)
        let linger = try await start(["pipe-linger"], supervisor: supervisor, sink: lingerSink)
        let stubborn = try await start(["stubborn"], supervisor: supervisor, sink: stubbornSink)
        for sink in [echoSink, lingerSink, stubbornSink] { _ = try await sink.firstObject() }
        let coalitions = try [echo, linger, stubborn].map {
            try #require(ProcessTable.resourceCoalition(pid: $0.pipe.pid))
        }

        let report = await supervisor.shutdown(graceSeconds: 0.3, inputCloseGraceSeconds: 0.3)
        #expect(report.succeeded, "\(report.errors)")
        #expect(!report.signals.contains { $0.signal == SIGHUP })
        // The echo child left on end-of-file, before any signal.
        #expect(!report.signals.contains { $0.identity.pid == echo.pipe.pid })
        #expect(report.signals.contains { $0.identity.pid == stubborn.pipe.pid && $0.signal == SIGKILL })
        for launch in [echo, linger, stubborn] { #expect(try !live(launch.pipe.pid)) }
        for coalition in coalitions { #expect(try liveMembers(coalition).isEmpty) }
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
    }

    /// Ownership markers and the same-session guard apply to pipe launches.
    @Test func ownershipMarkersAndTheSessionGuardApplyUnchanged() async throws {
        let supervisor = try makeSupervisor()
        let sink = PipeCollector()
        await #expect(throws: SessionManagementError.self) {
            _ = try await start(["pipe-echo"], supervisor: supervisor, sink: sink, markers: false)
        }
        #expect(await supervisor.runningSessionIDs().isEmpty)

        let sessionID = UUID()
        let launch = try await start(["pipe-echo"], supervisor: supervisor, sink: sink, sessionID: sessionID,
                                     conversationID: "pipe-conversation")
        _ = try await sink.firstObject()
        // The same session cannot start a second run.
        await #expect(throws: SessionManagementError.sessionAlreadyRunning(sessionID)) {
            _ = try await supervisor.launchPipes(
                sessionID: sessionID, executable: testChild, arguments: ["pipe-echo"],
                environment: LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID,
                                                    sessionID: sessionID),
                outputSink: sink
            )
        }
        // Nor can another session own the same provider conversation, by pipes or terminal.
        await #expect(throws: SessionManagementError.conversationAlreadyRunning(
            provider: .synthetic, conversationID: "pipe-conversation")) {
            _ = try await start(["pipe-echo"], supervisor: supervisor, sink: sink,
                                conversationID: "pipe-conversation")
        }
        #expect(await supervisor.runningSessionIDs() == [sessionID])
        // The child carries its run's markers.
        let runID = try #require(launch.session.currentRun?.id)
        #expect(ProcessTable.managedRunID(pid: launch.pipe.pid) == runID.uuidString)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func pipeChildrenNeedARunScope() async throws {
        let supervisor = try ProcessSupervisor()
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic, workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        await #expect(throws: RunScopeError.self) {
            _ = try await supervisor.launchPipes(
                sessionID: sessionID, executable: "/usr/bin/true",
                environment: LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID,
                                                    sessionID: sessionID),
                outputSink: PipeCollector()
            )
        }
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func runsLeaveNoDescriptorsBehind() async throws {
        let supervisor = try makeSupervisor()
        let scope = try await supervisor.openScope()
        // A resident run keeps the scope open; the last run of a scope releases it.
        let keeperSink = PipeCollector()
        let keeper = try await start(["pipe-linger"], supervisor: supervisor, sink: keeperSink, scope: scope)
        _ = try await keeperSink.firstObject()
        func cycle() async throws {
            let sink = PipeCollector()
            let launch = try await start(["pipe-echo"], supervisor: supervisor, sink: sink, scope: scope)
            _ = try await sink.firstObject()
            try await launch.pipe.write(Data("x\n".utf8))
            try await sink.wait("the echo") { sink.output.hasSuffix("echo: x\n") }
            let report = try await supervisor.stop(sessionID: launch.session.id)
            #expect(report.succeeded, "\(report.errors)")
        }
        // The first run settles one-off descriptors (the scope's socket traffic, queues).
        try await cycle()
        let before = openPipeCount()
        let runs = 30
        for _ in 0..<runs { try await cycle() }
        // A leaked descriptor per run (three pipes each) would add at least `runs`, three times that
        // for a full leak; other suites running at the same moment account for the slack.
        #expect(openPipeCount() - before < runs, "pipes \(before) -> \(openPipeCount())")
        #expect(try await supervisor.stop(sessionID: keeper.session.id,
                                          inputCloseGraceSeconds: 0.2).succeeded)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// The descriptors this process has open, and how many of them are pipes.
    private func descriptorCounts() -> (all: Int, pipes: Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return (names.count, openPipeCount())
    }

    /// Quit with a terminal run and a pipe run: the terminal is hung up, the
    /// pipe child is not (it gets end-of-file, then SIGTERM, then SIGKILL).
    @Test func quitWithTerminalAndPipeRunsNeverHangsUpThePipeChild() async throws {
        let supervisor = try makeSupervisor()
        let terminalSession = UUID()
        try await supervisor.createSession(ManagedSession(
            id: terminalSession, provider: .synthetic,
            workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        let terminal = try await supervisor.launch(
            sessionID: terminalSession, executable: testChild, arguments: ["interactive"],
            environment: LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID,
                                                sessionID: terminalSession)
        )
        let sink = PipeCollector()
        let linger = try await start(["pipe-linger"], supervisor: supervisor, sink: sink)
        _ = try await sink.firstObject()
        let coalition = try #require(ProcessTable.resourceCoalition(pid: linger.pipe.pid))

        let report = await supervisor.shutdown(graceSeconds: 0.3, inputCloseGraceSeconds: 0.3)
        #expect(report.succeeded, "\(report.errors)")
        // The terminal child was hung up, so this Quit did take the terminal schedule.
        #expect(report.signals.contains { $0.identity.pid == terminal.terminal.pid && $0.signal == SIGHUP },
                "\(report.signals.map { "\($0.identity.pid):\($0.signal)" }) terminal \(terminal.terminal.pid) pipe \(linger.pipe.pid)")
        // The pipe child, which ignores end-of-file, was never hung up.
        #expect(!report.signals.contains { $0.identity.pid == linger.pipe.pid && $0.signal == SIGHUP })
        #expect(report.signals.contains { $0.identity.pid == linger.pipe.pid && $0.signal == SIGTERM })
        #expect(try !live(linger.pipe.pid))
        #expect(try liveMembers(coalition).isEmpty)
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
    }

    /// A child that takes 0.5 s to leave after its stdin closes (an idle CLI,
    /// spike S1) leaves by itself: the stdin-close wait is not the signal grace.
    @Test func aChildThatNeedsHalfASecondAfterEofGetsNoSignal() async throws {
        let supervisor = try makeSupervisor()
        let sink = PipeCollector()
        let launch = try await start(["pipe-exit-after-eof", "500"], supervisor: supervisor, sink: sink)
        _ = try await sink.firstObject()
        let report = try await supervisor.stop(sessionID: launch.session.id)
        #expect(report.succeeded, "\(report.errors)")
        #expect(report.signals.isEmpty, "\(report.signals.map(\.signal))")
        #expect(report.elapsedSeconds >= 0.4)
        #expect(await launch.pipe.exitStatus() == 0)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)

        // The same on Quit.
        let second = PipeCollector()
        let again = try await start(["pipe-exit-after-eof", "500"], supervisor: supervisor, sink: second)
        _ = try await second.firstObject()
        let quit = await supervisor.shutdown()
        #expect(quit.succeeded, "\(quit.errors)")
        #expect(quit.signals.isEmpty, "\(quit.signals.map(\.signal))")
        #expect(await again.pipe.exitStatus() == 0)
    }

    /// A child that is gone before its leader is looked up (a failed resume
    /// prints why and exits) still delivers its output and its exit status.
    @Test func aChildThatExitsAtOnceStillDeliversItsOutputAndStatus() async throws {
        let supervisor = try makeSupervisor()
        // Hold the launch until the child has exited and the host has reaped it,
        // so the leader is certainly no longer in the process table.
        await supervisor.setAfterSpawnFailpointForTesting { pid in
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while ProcessTable.record(pid: pid) != nil, ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let sink = PipeCollector()
        let launch = try await start(["pipe-fail"], supervisor: supervisor, sink: sink)
        #expect(ProcessTable.record(pid: launch.pipe.pid) == nil)
        try await sink.wait("the child's stderr and the ends of both streams") {
            sink.error.contains("no conversation found") && sink.snapshot.outputEnded && sink.snapshot.errorEnded
        }
        #expect(sink.output.isEmpty)
        // The exit ends the run on its own, with the status of exit(3).
        var status: Int32?
        for _ in 0..<500 where status == nil {
            status = await launch.pipe.exitStatus()
            if status == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let exited = try #require(status)
        #expect(exited & 0x7f == 0 && (exited >> 8) & 0xff == 3, "status \(exited)")
        for _ in 0..<500 where await !supervisor.runningSessionIDs().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// A launch that fails (no such executable) leaves no descriptors, no
    /// pipes and no scope behind.
    @Test func aMissingExecutableLeavesNothingBehind() async throws {
        let supervisor = try makeSupervisor()
        // Settle one-off descriptors (the run host's socket, queues) first.
        let warmSink = PipeCollector()
        let warm = try await start(["pipe-echo"], supervisor: supervisor, sink: warmSink)
        _ = try await warmSink.firstObject()
        #expect(try await supervisor.stop(sessionID: warm.session.id).succeeded)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        let before = descriptorCounts()

        // Descriptor counts are process-wide and other suites run in parallel, so the run count is large
        // enough that a leak of even one pipe a launch stays above that noise.
        let runs = 40
        for _ in 0..<runs {
            let sessionID = UUID()
            try await supervisor.createSession(ManagedSession(
                id: sessionID, provider: .synthetic,
                workingDirectory: FileManager.default.temporaryDirectory.path
            ))
            await #expect(throws: (any Error).self) {
                _ = try await supervisor.launchPipes(
                    sessionID: sessionID, executable: "/nonexistent/loom-no-such-binary",
                    environment: LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID,
                                                        sessionID: sessionID),
                    outputSink: PipeCollector()
                )
            }
        }
        let after = descriptorCounts()
        // Three pipes (six descriptors) a launch would add 3 * runs pipes; other
        // suites running at the same moment account for the slack.
        #expect(after.pipes - before.pipes < runs, "pipes \(before.pipes) -> \(after.pipes)")
        #expect(after.all - before.all < runs, "descriptors \(before.all) -> \(after.all)")
        #expect(await supervisor.runningSessionIDs().isEmpty)
        let scopes = await supervisor.ledgerSnapshot().scopes
        #expect(scopes?.isEmpty == true, "\(String(describing: scopes))")
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// One write far above the queue limit is accepted alone, completes while
    /// the child reads, and arrives whole.
    @Test func oneWriteFarAboveTheInputLimitCompletesAndIsCountedWhole() async throws {
        let supervisor = try makeSupervisor()
        let sink = PipeCollector()
        let launch = try await start(["pipe-count", "0"], supervisor: supervisor, sink: sink,
                                     inputLimit: 64 * 1024)
        _ = try await sink.firstObject()
        let size = 8 << 20
        try await launch.pipe.write(Data(repeating: 0x43, count: size))
        await launch.pipe.closeInput()
        try await sink.wait(timeout: 30, "the byte count") { sink.output.contains("stdinBytes") }
        let last = try #require(sink.output.split(separator: "\n").last)
        let counted = try #require(JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        #expect(counted["stdinBytes"] as? Int == size)
        try await stopUnlessAlreadyEnded(supervisor, launch)
        #expect((await supervisor.shutdown()).succeeded)
    }
}
