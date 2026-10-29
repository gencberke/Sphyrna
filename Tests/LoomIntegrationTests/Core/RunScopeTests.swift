import CLoomPOSIX
import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore
import LoomTestSupport

/// The temporary folders of one test: run host folders and the test child's copy. A suite instance
/// lives for one test, so they go when the test ends, together with their hosts' LaunchServices records.
private final class ScopeScratch: Sendable {
    private let folders = Mutex<[URL]>([])
    private let child = Mutex<String?>(nil)

    /// A folder path, created by whoever fills it, that is removed when the test ends.
    func folder(_ prefix: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
        folders.withLock { $0.append(folder) }
        return folder
    }

    /// A copy of `executable` in a folder of this test, made on first use.
    func copy(of executable: URL) -> String {
        child.withLock { path in
            if let path { return path }
            let place = self.folder("loom-scope-child")
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

/// Real LaunchServices run hosts: each run gets a fresh resource coalition.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct RunScopeTests {
    private let scratch = ScopeScratch()

    private var productsDirectory: URL {
        Products.directory
    }

    /// Run hosts are their own TCC-responsible apps. The build products live
    /// under ~/Documents, so scoped children must run copies from a temporary
    /// directory or macOS would block their exec on a Documents consent prompt.
    private var testChild: String {
        scratch.copy(of: productsDirectory.appendingPathComponent("loom-test-child"))
    }

    private func launcher(hostBundle: URL? = nil) throws -> RunScopeLauncher {
        let root = scratch.folder("loom-scope")
        let bundle = try hostBundle ?? RunScopeLauncher.assembleOwnedBundle(
            executable: productsDirectory.appendingPathComponent("loom-run-host"), in: root
        )
        return RunScopeLauncher(hostBundle: bundle,
                                socketDirectory: root.appendingPathComponent("s"))
    }

    private func start(_ mode: String, supervisor: ProcessSupervisor) async throws -> ManagedSessionLaunch {
        try await start([mode], supervisor: supervisor)
    }

    private func start(_ arguments: [String], supervisor: ProcessSupervisor) async throws -> ManagedSessionLaunch {
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic,
            workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        return try await supervisor.launch(
            sessionID: sessionID,
            executable: testChild, arguments: arguments, environment: environment
        )
    }

    /// Accumulates fixture output across reads and returns the first JSON line
    /// carrying `key`.
    private func line(with key: String, from terminal: TerminalEndpoint,
                      buffer: inout Data, timeout: Double = 5) async throws -> [String: Any] {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            buffer.append(terminal.readAvailable())
            // PTY lines end in "\r\n", a single Character: split on newlines.
            for text in String(decoding: buffer, as: UTF8.self).split(whereSeparator: \.isNewline) {
                if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                   object[key] != nil { return object }
            }
            try await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw LoomError.message("No fixture line with \(key): \(String(decoding: buffer, as: UTF8.self).suffix(300))")
    }

    private func ready(_ terminal: TerminalEndpoint) async throws -> [String: Any] {
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            data.append(terminal.readAvailable())
            if let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
               let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                return object
            }
            try await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw LoomError.message("Fixture not ready: \(String(decoding: data, as: UTF8.self))")
    }

    private func live(_ identity: ProcessIdentity) throws -> Bool {
        try ProcessTable.snapshot().contains { $0.identity == identity && !$0.zombie }
    }

    private func identity(_ pid: Int32) throws -> ProcessIdentity {
        try #require(ProcessTable.snapshot().first { $0.identity.pid == pid }).identity
    }

    private func liveMembers(_ coalition: UInt64) throws -> [RunScopeMember] {
        try RunScopeTable.members(coalitionID: coalition).filter { !$0.zombie }
    }

    @Test func detachedUnmarkedEscapeStopsWithItsRun() async throws {
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let launch = try await start("apple-escape", supervisor: supervisor)
        let result = try await ready(launch.terminal)
        let escapedPID = try #require(result["descendantPID"] as? Int32)
        let escaped = try identity(escapedPID)
        let record = try #require(ProcessTable.snapshot().first { $0.identity == escaped })
        let coalition = try #require(ProcessTable.resourceCoalition(pid: launch.terminal.pid))
        // The escape left the Unix session, carries no readable marker, and is
        // reparented, yet it is still in the run's coalition.
        #expect(record.sessionID != launch.terminal.pid)
        #expect(record.parentPID == 1)
        #expect(ProcessTable.runID(pid: escapedPID) == nil)
        #expect(ProcessTable.resourceCoalition(pid: escapedPID) == coalition)
        #expect(coalition != ProcessTable.resourceCoalition(pid: getpid()))

        let report = try await supervisor.stop(sessionID: launch.session.id)
        #expect(report.succeeded, "\(report.errors)")
        #expect(try !live(escaped))
        #expect(try liveMembers(coalition).isEmpty)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func stoppingOneScopeLeavesAnotherRunning() async throws {
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let first = try await start("apple-escape", supervisor: supervisor)
        let second = try await start("apple-escape", supervisor: supervisor)
        let firstEscape = try identity(try #require(try await ready(first.terminal)["descendantPID"] as? Int32))
        let secondEscape = try identity(try #require(try await ready(second.terminal)["descendantPID"] as? Int32))
        let secondScope = try #require(ProcessTable.resourceCoalition(pid: second.terminal.pid))
        #expect(ProcessTable.resourceCoalition(pid: first.terminal.pid) != secondScope)

        #expect(try await supervisor.stop(sessionID: first.session.id).succeeded)
        #expect(try !live(firstEscape))
        #expect(try live(secondEscape))
        #expect(try liveMembers(secondScope).count >= 3) // host, leader, escape

        #expect((await supervisor.shutdown()).succeeded)
        #expect(try !live(secondEscape))
        #expect(try liveMembers(secondScope).isEmpty)
    }

    @Test func quitDrainsAdversarialChurnWithoutTouchingOutsideProcesses() async throws {
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/bin/sleep")
        outside.arguments = ["30"]
        try outside.run()
        defer { outside.signalForTeardown(SIGTERM) }
        let outsideIdentity = try identity(outside.processIdentifier)

        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let launch = try await start("churn", supervisor: supervisor)
        _ = try await ready(launch.terminal)
        let coalition = try #require(ProcessTable.resourceCoalition(pid: launch.terminal.pid))
        try await Task.sleep(for: .milliseconds(500))
        let forked = try liveMembers(coalition).filter { !$0.launchdSpawned }.count
        #expect(forked > 20, "churn produced \(forked) members")

        let report = await supervisor.shutdown()
        #expect(report.succeeded, "\(report.errors)")
        #expect(try liveMembers(coalition).isEmpty)
        #expect(try live(outsideIdentity))
        #expect(!report.signals.contains { $0.identity == outsideIdentity })
        await outside.terminateAndAwaitExit(signal: SIGTERM)
    }

    @Test func unavailableHostFailsLaunchWithoutAGhostRun() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).app")
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher(hostBundle: missing))
        await #expect(throws: RunScopeError.self) {
            _ = try await start("inspect", supervisor: supervisor)
        }
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func requestedAppleXPCIsNeverSignaledAndScopeEmpties() async throws {
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let launch = try await start("xpc-metal-client", supervisor: supervisor)
        let coalition = try #require(ProcessTable.resourceCoalition(pid: launch.terminal.pid))
        var output = Data()
        let compiled = try await line(with: "compiled", from: launch.terminal, buffer: &output, timeout: 10)
        #expect(compiled["compiled"] as? Bool == true)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var services: [RunScopeMember] = []
        repeat {
            services = try liveMembers(coalition).filter {
                $0.launchdSpawned &&
                ProcessTable.executablePath(pid: $0.identity.pid)?.contains("MTLCompilerService") == true
            }
            if !services.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline

        // No XPC observation is a missing acceptance prerequisite, never a
        // vacuous pass. Stop still runs so a failed observation leaves no run.
        #expect(!services.isEmpty, "No live MTLCompilerService joined the run coalition")
        let report = try await supervisor.stop(sessionID: launch.session.id)
        #expect(report.succeeded, "\(report.errors)")
        #expect(report.remainingCountVerified == true)
        for service in services {
            #expect(!report.signals.contains { $0.identity == service.identity })
            #expect(try !live(service.identity))
        }
        #expect(try liveMembers(coalition).isEmpty)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func hostStopsItsScopeWhenLoomDisappears() async throws {
        let scope = try await launcher().launch()
        let coalition = scope.coalitionID
        var output: [Int32] = [-1, -1]
        #expect(pipe(&output) == 0)
        let null = open("/dev/null", O_RDWR)
        defer { close(null); close(output[0]) }
        let pid = try await scope.spawn(
            executable: testChild, arguments: ["churn"], environment: ["PATH": "/usr/bin:/bin"],
            directory: "/", stdio: .descriptors(input: null, output: output[1], error: null)
        )
        close(output[1])
        #expect(pid > 0)
        var line = Data()
        var byte: UInt8 = 0
        var watched = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
        while poll(&watched, 1, 5_000) == 1, read(output[0], &byte, 1) == 1, byte != 10 { line.append(byte) }
        #expect(String(decoding: line, as: UTF8.self).contains("churn"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(try liveMembers(coalition).count > 3)

        scope.dropConnectionForTesting()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var remaining = try liveMembers(coalition)
        while !remaining.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(50))
            remaining = try liveMembers(coalition)
        }
        #expect(remaining.isEmpty, "\(remaining.count) member(s) left")
    }

    @Test func shellStartupEscapeIsOwnedUntilQuit() async throws {
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-scope-env-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let report = root.appendingPathComponent("escape.json")
        // A startup file that leaves a detached, unmarked Apple binary behind.
        try "\(testChild) apple-escape > \(report.path) 2>/dev/null &!\nexport PATH=/usr/bin:/bin\n".write(
            to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
        )
        let parent = ["HOME": root.path, "SHELL": "/bin/zsh", "USER": NSUserName(), "PATH": "/usr/bin:/bin"]
        let resolution = try await supervisor.terminalEnvironment(
            parent: parent, session: [:], testZDOTDIR: root, timeout: 5
        )
        #expect(resolution.environment["PATH"] == "/usr/bin:/bin")
        var escapedPID: Int32?
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while escapedPID == nil, ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: report),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                escapedPID = object["descendantPID"] as? Int32
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let escaped = try identity(try #require(escapedPID))
        let coalition = try #require(ProcessTable.resourceCoalition(pid: escaped.pid))
        #expect(coalition != ProcessTable.resourceCoalition(pid: getpid()))
        // Startup work keeps running like it would after a terminal's shell
        // started it, but it stays owned: Quit stops it and empties the scope.
        #expect(try live(escaped))
        let shutdown = await supervisor.shutdown()
        #expect(shutdown.succeeded, "\(shutdown.errors)")
        #expect(try !live(escaped))
        #expect(try liveMembers(coalition).isEmpty)
    }

    /// F10: an environment capture that left no forked work behind must not
    /// keep an idle run host until Quit; the next capture opens a new scope.
    @Test func environmentScopeIsReleasedWhenTheCaptureLeavesNothingBehind() async throws {
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-scope-env-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "export PATH=/usr/bin:/bin\n".write(
            to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
        )
        let parent = ["HOME": root.path, "SHELL": "/bin/zsh", "USER": NSUserName(), "PATH": "/usr/bin:/bin"]
        var coalitions: [UInt64] = []
        for _ in 0..<2 {
            let resolution = try await supervisor.terminalEnvironment(
                parent: parent, session: [:], testZDOTDIR: root, timeout: 5
            )
            #expect(resolution.environment["PATH"] == "/usr/bin:/bin")
            #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
            #expect(try await supervisor.liveScopeMembers().isEmpty)
            coalitions += await supervisor.ledgerSnapshot().scopes?.map(\.coalitionID) ?? []
        }
        #expect(coalitions.isEmpty)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// F10: background work a startup file left behind keeps the environment
    /// scope until Quit, and a later capture reuses it instead of opening one.
    @Test func environmentScopeIsKeptWhileStartupWorkIsAlive() async throws {
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-scope-env-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let report = root.appendingPathComponent("escape.json")
        try "\(testChild) apple-escape > \(report.path) 2>/dev/null &!\nexport PATH=/usr/bin:/bin\n".write(
            to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
        )
        let parent = ["HOME": root.path, "SHELL": "/bin/zsh", "USER": NSUserName(), "PATH": "/usr/bin:/bin"]
        _ = try await supervisor.terminalEnvironment(
            parent: parent, session: [:], testZDOTDIR: root, timeout: 5
        )
        let first = await supervisor.ledgerSnapshot().scopes?.map(\.coalitionID) ?? []
        #expect(first.count == 1)
        #expect(try await !supervisor.liveScopeMembers().isEmpty)
        _ = try await supervisor.terminalEnvironment(
            parent: parent, session: [:], testZDOTDIR: root, timeout: 5
        )
        #expect(await supervisor.ledgerSnapshot().scopes?.map(\.coalitionID) == first)
        let shutdown = await supervisor.shutdown()
        #expect(shutdown.succeeded, "\(shutdown.errors)")
    }

    /// In a run scope the host reaps the environment shell as soon as it exits, so a shell that is done before the job
    /// registers it is gone from the process table: the capture is finished, not failed ("Environment shell identity
    /// unavailable"). Without a scope the shell stays a zombie until it is collected, so a missing record is an error there.
    @Test func aShellThatEndedBeforeItWasRegisteredIsNoErrorInAScopeAndIsOneWithout() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        _ = await exitStatus(of: child)
        let gone = child.processIdentifier
        #expect(ProcessTable.record(pid: gone) == nil)
        try EnvironmentResolutionJob(runID: UUID(), observes: false).register(pid: gone)
        #expect(throws: LoomError.self) { try EnvironmentResolutionJob(runID: UUID(), observes: true).register(pid: gone) }
    }

    @Test func oneShotHelperLeavesNothingBehind() async throws {
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let output = try await supervisor.captureHelper(
            testChild, ["escape-exit"], environment: ["PATH": "/usr/bin:/bin"], timeout: 5
        )
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let escapedPID = try #require(object["descendantPID"] as? Int32)
        #expect(try !ProcessTable.snapshot().contains { $0.identity.pid == escapedPID && !$0.zombie })
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// A streamed one-shot (Remora's call) runs in a run scope of its own when a launcher exists: the scope is in the
    /// ledger while it runs, stdin reaches the child through the host, chunks arrive before the exit, and nothing is left.
    @Test func aStreamedHelperRunsInItsOwnScopeAndLeavesNothingBehind() async throws {
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        // The child ends only after the test saw its first chunk (the gate file): a helper that held the output until the
        // exit would never see it and would end at the deadline. Ordering, not a clock, so load cannot fail it.
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("stream-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gate) }
        let stream = supervisor.streamHelper(
            "/bin/sh", ["-c", "read line; echo got-$line; while [ ! -e \(gate.path) ]; do sleep 0.02; done; echo end"],
            environment: ["PATH": "/usr/bin:/bin"], input: Data("pack\n".utf8), timeout: 20
        )
        var text = ""
        var scopesWhileRunning = 0
        for try await chunk in stream {
            if text.isEmpty {
                scopesWhileRunning = await supervisor.ledgerSnapshot().scopes?.count ?? 0
                FileManager.default.createFile(atPath: gate.path, contents: nil)
            }
            text += String(decoding: chunk, as: UTF8.self)
        }
        #expect(text == "got-pack\nend\n")
        #expect(scopesWhileRunning == 1)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    // MARK: One run scope per Changes git read (RS-7)

    /// A `git` that reads no user config, as a script the scoped helper can run: the live reader passes its own fixed environment.
    private func isolatedGit(in folder: URL, then extra: String = "") throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("git-isolated")
        try "#!/bin/sh\nexport GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1\n\(extra)exec /usr/bin/git \"$@\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func makeBranchRepository(in root: URL) async throws -> URL {
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ arguments: String...) async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path, "-c", "commit.gpgsign=false"] + arguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "GIT_CONFIG_GLOBAL": "/dev/null",
                                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            if await exitStatus(of: process) != 0 { throw LoomError.message("git \(arguments) failed") }
        }
        try await git("init", "-q", "-b", "main")
        try "1\n2\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git("add", "-A")
        try await git("commit", "-q", "-m", "base")
        try await git("checkout", "-q", "-b", "feature")
        try "1\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        return repo
    }

    /// A Branch list makes seven or eight git calls; each used to open a run scope of its own (a LaunchServices launch, a
    /// handshake and a ledger write apiece). The calls of one read share one scope, which is released when the read returns.
    @Test func aBranchListAndAFilesDiffEachOpenExactlyOneRunScopeAndLeaveNoneOpen() async throws {
        let root = scratch.folder("loom-git-scope")
        let repo = try await makeBranchRepository(in: root)
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let reader = GitChanges.live(supervisor: supervisor, executable: try isolatedGit(in: root.appendingPathComponent("bin")))

        let opened = await supervisor.scopesOpened
        let state = await reader.list(directory: repo.path)
        guard case let .list(list) = state else { Issue.record("not a list: \(state)"); return }
        #expect(list.files.map(\.path) == ["a.txt", "new.txt"])
        let afterList = await supervisor.scopesOpened - opened
        #expect(afterList == 1, "a list opened \(afterList) run scopes")
        let leftAfterList = await supervisor.ledgerSnapshot().scopes?.isEmpty
        #expect(leftAfterList == true, "the scope was released with the read")

        let tracked = try #require(list.files.first { $0.path == "a.txt" })
        let diff = await reader.diff(of: tracked, in: list)
        guard case .hunks = diff else { Issue.record("not hunks: \(diff)"); return }
        let afterDiff = await supervisor.scopesOpened - opened
        #expect(afterDiff == 2, "a file's diff opened exactly one more")
        let leftAfterDiff = await supervisor.ledgerSnapshot().scopes?.isEmpty
        #expect(leftAfterDiff == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// A Quit during a read: every helper of it is cancelled and awaited, and the scope is released with no helper left in it.
    @Test func aShutdownDuringAReadLeavesNoHelperRunningAndTheScopeReleased() async throws {
        let root = scratch.folder("loom-git-shutdown")
        let pids = root.appendingPathComponent("pid")
        // Every git call of the read writes its pid and then hangs.
        let hung = try isolatedGit(in: root.appendingPathComponent("bin"), then: "echo $$ >> '\(pids.path)'\nsleep 60\n")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        var limits = GitChanges.Limits()
        limits.listTimeout = 120
        let reader = GitChanges.live(supervisor: supervisor, executable: hung, limits: limits)
        let read = Task { await reader.list(directory: root.path) }

        func started() -> [Int32] {
            ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while started().isEmpty, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let helper = try #require(started().first, "the helper never started")
        let openedWhileReading = await supervisor.scopesOpened
        let scopesWhileReading = await supervisor.ledgerSnapshot().scopes?.count
        #expect(openedWhileReading == 1 && scopesWhileReading == 1)

        let report = await supervisor.shutdown()
        #expect(report.succeeded, "\(report.errors)")
        let state = await read.value
        #expect(state != .timedOut, "the read ended by the shutdown, not by its deadline: \(state)")
        // The helper is gone (a zombie of the host is reaped by it) and its scope with it.
        let gone = ProcessInfo.processInfo.systemUptime + 10
        while let record = ProcessTable.record(pid: helper), !record.zombie, ProcessInfo.processInfo.systemUptime < gone {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ProcessTable.record(pid: helper).map(\.zombie) ?? true, "the helper is still running")
        let scopesLeft = await supervisor.ledgerSnapshot().scopes?.isEmpty
        let jobsLeft = await supervisor.environmentJobs.isEmpty
        #expect(scopesLeft == true && jobsLeft)
    }

    /// SR1-F1: a run that traced an outside process (as a debugger does) must
    /// not take it over. Ancestry seen while attached is not ownership.
    @Test func debuggerTraceeOutsideTheScopeIsNeverSignaled() async throws {
        let place = scratch.folder("loom-scope-tracee")
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let tracee = place.appendingPathComponent("loom-test-child-traceable")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: testChild), to: tracee)
        let entitlements = place.appendingPathComponent("get-task-allow.plist")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
        """.utf8).write(to: entitlements)
        #expect(try RunScopeLauncher.runTool("/usr/bin/codesign", [
            "--force", "--sign", "-", "--entitlements", entitlements.path, tracee.path,
        ], timeout: 30) == 0)
        // Foundation can retain a stale completion state after another process
        // attaches to this child with ptrace. Own spawn/reap directly instead.
        var arguments = [tracee.path, "stubborn", "--silent"].map { strdup($0) }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            for pointer in arguments { free(pointer) }
            for pointer in environment { free(pointer) }
        }
        guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else {
            throw LoomError.system("tracee spawn strings", ENOMEM)
        }
        arguments.append(nil)
        var outsidePID: Int32 = -1
        let spawned = arguments.withUnsafeMutableBufferPointer {
            let argv = $0.baseAddress!
            return (environment + [nil]).withUnsafeBufferPointer {
                posix_spawn(&outsidePID, tracee.path, nil, nil, argv, $0.baseAddress!)
            }
        }
        guard spawned == 0 else { throw LoomError.system("tracee spawn", spawned) }
        var capturedIdentity: ProcessIdentity?
        var cleaned = false
        defer {
            if !cleaned {
                // An early exit: a `defer` cannot await. The signal goes now, and a thread of its own reaps the tracee.
                let pid = outsidePID, birth = signalOutsideTracee(pid: outsidePID, identity: capturedIdentity)
                Thread {
                    for _ in 0..<200 {
                        let look = Self.reapOutsideTracee(pid: pid, birth: birth)
                        if look.reaped || look.failure != nil { return }
                        usleep(10_000)
                    }
                }.start()
            }
        }
        capturedIdentity = try identity(outsidePID)
        let outsideIdentity = try #require(capturedIdentity)
        try await Task.sleep(for: .milliseconds(200))

        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let launch = try await start(["attach-detach", String(outsidePID)], supervisor: supervisor)
        var output = Data()
        _ = try await line(with: "attached", from: launch.terminal, buffer: &output)
        let traced = try #require(ProcessTable.snapshot().first { $0.identity == outsideIdentity })
        #expect(traced.parentPID == launch.terminal.pid)
        // Sampled while attached: the tracee looks like the run's child.
        let sampled = try await supervisor.sample(sessionID: launch.session.id)
        #expect(!sampled.contains { $0.identity == outsideIdentity })
        _ = try await line(with: "detached", from: launch.terminal, buffer: &output)

        let report = try await supervisor.stop(sessionID: launch.session.id)
        #expect(report.succeeded, "\(report.errors)")
        #expect(!report.signals.contains { $0.identity == outsideIdentity })
        #expect(try live(outsideIdentity))
        #expect((await supervisor.shutdown()).succeeded)
        #expect(try live(outsideIdentity))
        cleaned = true
        await cleanupOutsideTracee(pid: outsidePID, identity: capturedIdentity)
    }

    // Only this spawned child's birth identity authorizes a signal. Reaping
    // is nonblocking and does not depend on Foundation's ptrace bookkeeping.
    private func signalOutsideTracee(pid: Int32, identity captured: ProcessIdentity?) -> ProcessIdentity? {
        let birth = captured ?? (try? identity(pid))
        if let birth {
            do { try ProcessTable.signal(birth, SIGKILL) }
            catch { Issue.record("Outside tracee cleanup signal failed: \(error)") }
        }
        return birth
    }

    /// One nonblocking look: the tracee is reaped (or gone from the table), or `waitpid` failed with `failure`.
    private static func reapOutsideTracee(pid: Int32, birth: ProcessIdentity?) -> (reaped: Bool, failure: Int32?) {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        // A ptrace stop/continue status is not a reaped exit status.
        if result == pid && status & 0x7f != 0x7f { return (true, nil) }
        if result == -1 && errno == ECHILD {
            guard let records = try? ProcessTable.snapshot() else { return (false, nil) }
            return (!records.contains(where: { $0.identity.pid == pid && (birth == nil || $0.identity == birth) }), nil)
        }
        if result == -1 && errno != EINTR { return (false, errno) }
        return (false, nil)
    }

    private func cleanupOutsideTracee(pid: Int32, identity captured: ProcessIdentity?) async {
        let birth = signalOutsideTracee(pid: pid, identity: captured)
        var failure: Int32?
        await waitFor("the outside tracee fixture to be reaped", within: .seconds(2)) {
            let look = Self.reapOutsideTracee(pid: pid, birth: birth)
            failure = look.failure
            return look.reaped || look.failure != nil
        }
        if let failure { Issue.record("Outside tracee waitpid failed: \(failure)") }
    }

    /// SR1-F15: a host that never connects fails within the handshake deadline.
    @Test func hostThatNeverConnectsFailsWithinTheHandshakeDeadline() async throws {
        let root = scratch.folder("loom-scope-silent")
        let bundle = try RunScopeLauncher.assembleOwnedBundle(executable: URL(fileURLWithPath: "/usr/bin/true"), in: root)
        let launcher = RunScopeLauncher(hostBundle: bundle, socketDirectory: root.appendingPathComponent("s"),
                                        handshakeTimeout: 2)
        let supervisor = try ProcessSupervisor(scopeLauncher: launcher)
        let started = ProcessInfo.processInfo.systemUptime
        await #expect(throws: RunScopeError.self) { _ = try await start("inspect", supervisor: supervisor) }
        #expect(ProcessInfo.processInfo.systemUptime - started < 6)
        #expect(await supervisor.runningSessionIDs().isEmpty)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// SR1-F6: a scope with a live run cannot be released; after the run's own
    /// stop the scope is gone.
    @Test func sharedScopeReleaseWaitsForItsRuns() async throws {
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let scope = try await supervisor.openScope()
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic, workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        let launch = try await supervisor.launch(
            sessionID: sessionID, executable: testChild, arguments: ["apple-escape"],
            environment: LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID,
                                                sessionID: sessionID),
            scope: scope
        )
        _ = try await ready(launch.terminal)
        let refused = await supervisor.releaseScope(scope)
        #expect(refused.first?.contains("still has 1 run") == true)
        #expect(try liveMembers(scope.coalitionID).count >= 3)
        #expect(try await supervisor.stop(sessionID: sessionID).succeeded)
        #expect(try liveMembers(scope.coalitionID).isEmpty)
        #expect(await supervisor.ledgerSnapshot().scopes?.isEmpty == true)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// SR1-F15: losing the host mid-run still lets the run stop with its whole
    /// scope verified empty (the leader's status becomes unknown, not a hang).
    @Test func losingTheHostMidRunStillStopsTheScope() async throws {
        let supervisor = try ProcessSupervisor(scopeLauncher: try launcher())
        let launch = try await start("apple-escape", supervisor: supervisor)
        let escaped = try identity(try #require(try await ready(launch.terminal)["descendantPID"] as? Int32))
        let coalition = try #require(ProcessTable.resourceCoalition(pid: launch.terminal.pid))
        let host = try #require(try liveMembers(coalition).first { $0.launchdSpawned })
        #expect(kill(host.identity.pid, SIGKILL) == 0)
        let report = try await supervisor.stop(sessionID: launch.session.id)
        #expect(report.succeeded, "\(report.errors)")
        #expect(try !live(escaped))
        #expect(try liveMembers(coalition).isEmpty)
        #expect((await supervisor.shutdown()).succeeded)
    }

    /// SR1-F2: a run host may report a leader's exit after the reap window.
    /// That must fail only the current attempt; the next one finishes the run.
    @Test func lateExitStatusFromTheHostStillFinishesTheRun() async throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        #expect(loom_open_pty(24, 80, &master, &slave) == 0)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.1"]
        try child.run()
        let reportAt = ProcessInfo.processInfo.systemUptime + 2.5
        let exits = Mutex<[Int32?]>([])
        let transport = EventDrivenPTYProcess(
            process: PTYProcess(adoptingPID: child.processIdentifier, masterFD: master),
            onOutput: { _ in }, onExit: { status in exits.withLock { $0.append(status) } },
            reap: { pid, status in
                guard ProcessInfo.processInfo.systemUptime >= reportAt else { return 0 }
                status.pointee = 0
                return pid
            }
        )
        _ = await exitStatus(of: child)
        close(slave)
        await #expect(throws: (any Error).self) { _ = try await transport.finish(outputDrainSeconds: 0) }
        #expect(exits.withLock { $0 }.isEmpty)
        try await Task.sleep(for: .seconds(1.5))
        #expect(try await transport.finish(outputDrainSeconds: 0) == 0)
        #expect(exits.withLock { $0 } == [0])
    }

    /// SR1-F4: a crashed Loom whose host also died leaves forked work in a
    /// recorded scope. The next launch stops it, verifies the scope empty and
    /// prunes the directory; the current run's directory is left alone.
    @Test func nextLaunchRecoversAScopeWhoseHostAlsoDied() async throws {
        let scope = try await launcher().launch()
        var output: [Int32] = [-1, -1]
        #expect(pipe(&output) == 0)
        let null = open("/dev/null", O_RDWR)
        defer { close(null); close(output[0]) }
        _ = try await scope.spawn(executable: testChild, arguments: ["apple-escape"],
                                  environment: ["PATH": "/usr/bin:/bin"], directory: "/",
                                  stdio: .descriptors(input: null, output: output[1], error: null))
        close(output[1])
        var line = Data()
        var byte: UInt8 = 0
        var watched = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
        while poll(&watched, 1, 5_000) == 1, read(output[0], &byte, 1) == 1, byte != 10 { line.append(byte) }
        let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let escaped = try identity(try #require(object["descendantPID"] as? Int32))
        #expect(kill(scope.host.identity.pid, SIGKILL) == 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try live(escaped))

        let runs = FileManager.default.temporaryDirectory.appendingPathComponent("loom-runs-\(UUID())")
        let previous = runs.appendingPathComponent("previous")
        let current = runs.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runs) }
        var ledger = OwnershipLedger()
        ledger.register(scope: scope.record)
        try ledger.save(to: previous.appendingPathComponent("ledger.json"))
        try JSONEncoder().encode(ProcessIdentity(pid: 99_999, startSeconds: 1, startMicroseconds: 0))
            .write(to: previous.appendingPathComponent("owner.json"))
        try ledger.save(to: current.appendingPathComponent("ledger.json"))

        let report = await PreviousRunRecovery.recover(runsDirectory: runs, current: current)
        #expect(report.leftovers.isEmpty, "\(report.leftovers)")
        #expect(report.verifiedScopes == 1)
        #expect(report.stoppedProcesses >= 1)
        #expect(try !live(escaped))
        #expect(try liveMembers(scope.coalitionID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
    }

    /// SR1-F3: the host serves only the app that contains it. A caller that is
    /// not that app's code gets no hello and cannot make the host spawn.
    @Test func hostRefusesACallerThatIsNotItsOwner() async throws {
        let root = scratch.folder("loom-scope-foreign")
        let bundle = try RunScopeLauncher.assembleOwnedBundle(
            executable: productsDirectory.appendingPathComponent("loom-run-host"), in: root,
            owner: URL(fileURLWithPath: "/bin/sleep")
        )
        let launcher = RunScopeLauncher(hostBundle: bundle, socketDirectory: root.appendingPathComponent("s"),
                                        handshakeTimeout: 3)
        await #expect(throws: RunScopeError.self) { _ = try await launcher.launch() }
        try await Task.sleep(for: .milliseconds(300))
        let hostPath = bundle.appendingPathComponent("Contents/MacOS/loom-run-host").resolvingSymlinksInPath().path
        #expect(try !ProcessTable.snapshot().contains {
            !$0.zombie && ProcessTable.executablePath(pid: $0.identity.pid) == hostPath
        })
    }
}
