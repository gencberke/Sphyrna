import CLoomPOSIX
import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore

private final class RunScopeBundleAnchor: NSObject {}

/// Real LaunchServices run hosts: each run gets a fresh resource coalition.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RunScopeTests {
    private var productsDirectory: URL {
        Bundle(for: RunScopeBundleAnchor.self).bundleURL.deletingLastPathComponent()
    }

    /// Run hosts are their own TCC-responsible apps. The build products live
    /// under ~/Documents, so scoped children must run copies from a temporary
    /// directory or macOS would block their exec on a Documents consent prompt.
    private static let fixtureRoot: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-scope-fixtures-\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    private var testChild: String {
        let copy = Self.fixtureRoot.appendingPathComponent("loom-test-child")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.copyItem(
                at: productsDirectory.appendingPathComponent("loom-test-child"), to: copy
            )
        }
        return copy.path
    }

    private func launcher(hostBundle: URL? = nil) throws -> RunScopeLauncher {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-scope-\(UUID().uuidString.prefix(8))")
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
        defer { outside.terminateAndAwaitExit(signal: SIGTERM) }
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

    /// SR1-F1: a run that traced an outside process (as a debugger does) must
    /// not take it over. Ancestry seen while attached is not ownership.
    @Test func debuggerTraceeOutsideTheScopeIsNeverSignaled() async throws {
        let tracee = Self.fixtureRoot.appendingPathComponent("loom-test-child-traceable")
        if !FileManager.default.fileExists(atPath: tracee.path) {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: testChild), to: tracee)
            let entitlements = Self.fixtureRoot.appendingPathComponent("get-task-allow.plist")
            try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
            """.utf8).write(to: entitlements)
            #expect(try RunScopeLauncher.runTool("/usr/bin/codesign", [
                "--force", "--sign", "-", "--entitlements", entitlements.path, tracee.path,
            ], timeout: 30) == 0)
        }
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
        defer { cleanupOutsideTracee(pid: outsidePID, identity: capturedIdentity) }
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
    }

    private func cleanupOutsideTracee(pid: Int32, identity captured: ProcessIdentity?) {
        // Only this spawned child's birth identity authorizes a signal. Reaping
        // is nonblocking and does not depend on Foundation's ptrace bookkeeping.
        let birth = captured ?? (try? identity(pid))
        if let birth {
            do { try ProcessTable.signal(birth, SIGKILL) }
            catch { Issue.record("Outside tracee cleanup signal failed: \(error)") }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            // A ptrace stop/continue status is not a reaped exit status.
            if result == pid && status & 0x7f != 0x7f { return }
            if result == -1 && errno == ECHILD {
                if let records = try? ProcessTable.snapshot(),
                   !records.contains(where: { $0.identity.pid == pid && (birth == nil || $0.identity == birth) }) {
                    return
                }
            } else if result == -1 && errno != EINTR {
                Issue.record("Outside tracee waitpid failed: \(errno)")
                return
            }
            usleep(10_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        Issue.record("Outside tracee fixture was not reaped within two seconds")
    }

    /// SR1-F15: a host that never connects fails within the handshake deadline.
    @Test func hostThatNeverConnectsFailsWithinTheHandshakeDeadline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-scope-silent-\(UUID().uuidString.prefix(8))")
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
        child.waitUntilExit()
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loom-scope-foreign-\(UUID().uuidString.prefix(8))")
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
