import Darwin
import Foundation
import Testing
@testable import LoomCore

@MainActor
struct LaunchEnvironmentTests {
    private func fixture(_ rc: String, profile: String = "") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-environment-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rc.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try profile.write(to: directory.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        return directory
    }

    private func parent(home: URL) -> [String: String] {
        ["HOME": home.path, "SHELL": "/bin/zsh", "USER": NSUserName(),
         "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "parent-session",
         "CLAUDE_CODE_MESSAGING_TOKEN": "parent-token", "CLAUDE_CODE_MESSAGING_SOCKET": "/parent/socket",
         "CODEX_HOME": "/parent/codex", "UNRELATED_TOKEN": "parent-secret",
         "SSH_AUTH_SOCK": "/parent/agent", "PATH": "/parent/bin", "ZDOTDIR": "/parent/rc",
         "LANG": "C", "LC_ALL": "C", "LC_CTYPE": "C", "LC_MESSAGES": "C"]
    }

    @Test func cleanInteractiveLoginEnvironmentReachesChild() throws {
        let directory = try fixture("""
            [[ -o interactive ]] || exit 41
            [[ -o login ]] || exit 42
            export LOOM_TEST_RC_VALUE=$'first line\\nsecond=value'
            export CLAUDE_USER_CONFIGURED=from-rc
            export PATH="/rc/bin:$PATH"
            """, profile: "export LOOM_TEST_PROFILE_VALUE=from-profile\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = try LaunchEnvironment.resolve(parent: parent(home: directory),
            session: ["SSH_AUTH_SOCK": "/session/agent", "SESSION_CUSTOM": "session-value"], testZDOTDIR: directory)
        let run = UUID(), session = UUID()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["-0"]
        child.environment = LaunchEnvironment.make(base: resolved.environment, runID: run, sessionID: session)
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        let environment = Dictionary(uniqueKeysWithValues: bytes.split(separator: 0).map { entry in
            let parts = String(decoding: entry, as: UTF8.self).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), String(parts[1]))
        })
        #expect(environment["LOOM_TEST_RC_VALUE"] == "first line\nsecond=value")
        #expect(environment["LOOM_TEST_PROFILE_VALUE"] == "from-profile")
        #expect(environment["CLAUDE_USER_CONFIGURED"] == "from-rc")
        #expect(environment["SESSION_CUSTOM"] == "session-value")
        #expect(environment["SSH_AUTH_SOCK"] == "/session/agent")
        #expect(environment["PATH"]?.hasPrefix("/rc/bin:") == true)
        #expect(environment["PATH"]?.contains("/parent/bin") == false)
        #expect(environment["LANG"]?.hasSuffix(".UTF-8") == true)
        #expect(environment["LC_ALL"] == nil)
        #expect(environment["LC_CTYPE"] == nil)
        #expect(environment["LC_MESSAGES"] == nil)
        for key in ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_MESSAGING_TOKEN",
                    "CLAUDE_CODE_MESSAGING_SOCKET", "CODEX_HOME", "UNRELATED_TOKEN"] {
            #expect(environment[key] == nil)
        }
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["LOOM_RUN_ID"] == run.uuidString)
        #expect(environment["LOOM_SESSION_ID"] == session.uuidString)
    }

    @Test(arguments: ["false\nexport PARTIAL=present\n", "read 'answer?Continue?'\nexport PARTIAL=present\n"])
    func naturalStartupContinuesAfterFailedCommandOrInputEOF(rc: String) throws {
        let directory = try fixture(rc)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory, timeout: 0.5)
        #expect(result.environment["PARTIAL"] == "present")
        // zsh does not report the isolated false/read status after the later export.
        #expect(result.warnings.isEmpty)
    }

    @Test func slowStartupBeyondFiveSecondsSucceeds() throws {
        let directory = try fixture("/bin/sleep 5.2\nexport FOO=1\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory)
        #expect(result.environment["FOO"] == "1")
    }

    @Test func absentOptionalLocaleVariablesAreSilent() {
        let result = LaunchEnvironment.sessionEnvironment(origin: .development, parent: [:]) {
            $0 == "SSH_AUTH_SOCK" ? "/test/agent" : nil
        }
        #expect(result.warnings.isEmpty)
        let missingAgent = LaunchEnvironment.sessionEnvironment(origin: .development, parent: [:]) { _ in nil }
        #expect(missingAgent.warnings == ["launchd session variable SSH_AUTH_SOCK is unavailable"])
    }

    @Test func startupBackgroundJobIsOwnedUntilShutdownWithoutCoalition() throws {
        let directory = try fixture("/bin/sleep 60 &!\nexport LOOM_TEST_HELPER_PID=$!\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = try ShutdownCoordinator(ledger: OwnershipLedger(coalition:
            CoalitionCapability(resourceID: nil, detail: "Development startup test")))
        defer { _ = coordinator.shutdown() }
        let result = try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory,
            runID: coordinator.ledger.runID, onSpawn: coordinator.registerEnvironmentShell,
            onPoll: { _ = try coordinator.sample() })
        let pid = try #require(result.environment["LOOM_TEST_HELPER_PID"].flatMap(Int32.init))
        let identity = try #require(try ProcessTable.snapshot().first { $0.identity.pid == pid }?.identity)
        // Identity-checked test cleanup also runs if the ownership regression returns.
        defer { try? ProcessTable.signal(identity, SIGKILL) }
        #expect(try coordinator.sample().contains { $0.identity == identity })
        #expect(kill(pid, 0) == 0)
        let report = coordinator.shutdown()
        #expect(report.succeeded)
        #expect(report.signals.contains { $0.identity == identity })
        #expect(try !ProcessTable.snapshot().contains { $0.identity == identity })
    }

    @Test func startupDiagnosticsAreBoundedWarnings() throws {
        let directory = try fixture("stty -ixon\nfalse\nprint -u2 -- startup-warning\nexport FOO=1\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory)
        #expect(result.environment["FOO"] == "1")
        #expect(result.warnings.contains { $0.contains("stty") && $0.contains("startup-warning") })
        #expect(result.warnings.allSatisfy { $0.count <= 2048 })
        try "printf '%03000d\\n' 0 >&2\nexport FOO=1\n".write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let large = try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory)
        #expect(large.environment["FOO"] == "1")
        #expect(large.warnings.count == 1)
        #expect(large.warnings[0].count <= 2048)
    }

    @Test func exitBeforeEnvironmentFailsAndStopsItsChild() throws {
        let directory = try fixture("/bin/sleep 20 &\necho $! > \"$ZDOTDIR/sleeper.pid\"\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) {
            try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory)
        }
        let text = try String(contentsOf: directory.appendingPathComponent("sleeper.pid"), encoding: .utf8)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while kill(pid, 0) == 0, ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func completeEnvironmentSurvivesLogoutFailure() throws {
        let directory = try fixture("export FOO=1\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        try "print logout-message\nexit 7\n".write(to: directory.appendingPathComponent(".zlogout"), atomically: true, encoding: .utf8)
        let result = try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory)
        #expect(result.environment["FOO"] == "1")
        #expect(result.warnings.contains { $0.contains("wait status") })
    }

    @Test(arguments: ["export PATH=''\n", "/usr/bin/head -c 5000000 /dev/zero\n"])
    func unusableOrOversizedEnvironmentFails(rc: String) throws {
        let directory = try fixture(rc)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) {
            try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory)
        }
    }

    @Test func hungStartupTimesOutAndStopsItsChild() throws {
        let directory = try fixture("/bin/sleep 20 &\necho $! > \"$ZDOTDIR/sleeper.pid\"\nwait\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory, timeout: 0.2)
            Issue.record("Hung startup unexpectedly produced an environment")
        } catch {
            #expect(String(describing: error).contains("timed out"))
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
        let text = try String(contentsOf: directory.appendingPathComponent("sleeper.pid"), encoding: .utf8)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Allow launchd to reap the orphan after the bootstrap process group is killed.
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while kill(pid, 0) == 0, ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func finalConditionalIsNotAStartupFailure() throws {
        let directory = try fixture("export LOOM_TEST_VALUE=present\n[[ no == yes ]] && echo never\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory)
        #expect(result.environment["LOOM_TEST_VALUE"] == "present")
    }

    @Test(arguments: ["/bin/bash", "/opt/homebrew/bin/zsh"])
    func unsupportedShellFailsWithoutFallback(shell: String) throws {
        let directory = try fixture("")
        defer { try? FileManager.default.removeItem(at: directory) }
        var inherited = parent(home: directory)
        inherited["SHELL"] = shell
        do {
            _ = try LaunchEnvironment.resolve(parent: inherited, session: [:])
            Issue.record("Unsupported shell unexpectedly produced an environment")
        } catch {
            #expect(String(describing: error).contains("unsupported shell: \(shell)"))
        }
    }

    @Test func localeUsesExactMatchThenNativeLanguageStemOrder() throws {
        let names = ["en_NZ", "en_US.UTF-8", "en_NZ.UTF-8", "tr_TR.UTF-8"]
        #expect(LaunchEnvironment.localeLanguage(currentIdentifier: "en_US", availableNames: names).language == "en_US.UTF-8")
        #expect(LaunchEnvironment.localeLanguage(currentIdentifier: "en_TR", availableNames: names).language == "en_NZ.UTF-8")
        #expect(LaunchEnvironment.localeLanguage(currentIdentifier: "en_TR", availableNames: Array(names.reversed())).language == "en_NZ.UTF-8")
        #expect(LaunchEnvironment.localeLanguage(currentIdentifier: "en_TR", availableNames: ["en_US.UTF-8", "en_NZ", "en_NZ.UTF-8"]).language == "en_US.UTF-8")
    }

    @Test func missingLocaleFallsBackOrLeavesLanguageUnsetWithWarning() throws {
        let fallback = LaunchEnvironment.localeLanguage(currentIdentifier: "zz_ZZ", availableNames: ["en_US.UTF-8"])
        #expect(fallback.language == "en_US.UTF-8")
        #expect(!fallback.warnings.isEmpty)
        let absent = LaunchEnvironment.localeLanguage(currentIdentifier: "zz_ZZ", availableNames: [])
        #expect(absent.language == nil)
        #expect(!absent.warnings.isEmpty)
        let directory = try fixture("export FOO=1\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        try "export LOOM_TEST_INCOMING_LANG_SET=${LANG+x}\n".write(
            to: directory.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let result = try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory,
            currentLocale: "zz_ZZ", availableLocales: [])
        #expect(result.environment["FOO"] == "1")
        // /etc/zprofile may set LANG after .zshenv; trusted startup values must survive.
        #expect(result.environment["LOOM_TEST_INCOMING_LANG_SET"] == "")
        #expect(!result.warnings.isEmpty)
    }

    @Test func launchOriginSelectsTrustedEnvironmentAndFiltersLauncherKeys() throws {
        let inherited = ["SSH_AUTH_SOCK": "/trusted/agent", "USER_CUSTOM": "preserved", "__CFBundleIdentifier": "dev.loom.probe",
                         "XPC_SERVICE_NAME": "launcher", "XPC_FLAGS": "0", "LOOM_PROBE_CONTROL": "control", "TERM_PROGRAM": "launcher", "OSLogRateLimit": "64",
                         "COMMAND_MODE": "unix2003", "__CF_USER_TEXT_ENCODING": "501:0:0"]
        let app = LaunchEnvironment.sessionEnvironment(origin: .launchServices, parent: inherited)
        #expect(app.environment == ["SSH_AUTH_SOCK": "/trusted/agent", "USER_CUSTOM": "preserved"])
        let directory = try fixture("")
        defer { try? FileManager.default.removeItem(at: directory) }
        let withPath = LaunchEnvironment.sessionEnvironment(origin: .launchServices,
            parent: ["PATH": "/trusted/custom/bin:/usr/bin:/bin"])
        let resolved = try LaunchEnvironment.resolve(parent: parent(home: directory), session: withPath.environment, testZDOTDIR: directory)
        #expect(resolved.environment["PATH"]?.contains("/trusted/custom/bin") == true)
        var queried: [String] = []
        let development = LaunchEnvironment.sessionEnvironment(origin: .development,
            parent: ["CLAUDECODE": "1", "SSH_AUTH_SOCK": "/dirty/agent"]) { key in
                queried.append(key)
                if key == "SSH_AUTH_SOCK" { return "/launchd/agent" }
                if key == "LC_ALL" { throw LoomError.message("lookup failed") }
                return nil
            }
        #expect(queried == ["SSH_AUTH_SOCK", "LANG", "LC_ALL", "LC_CTYPE"])
        #expect(development.environment == ["SSH_AUTH_SOCK": "/launchd/agent"])
        #expect(development.warnings == ["Could not read launchd session variable LC_ALL"])
    }

    @Test func launchServicesIdentityAlsoRequiresAbsenceOfKnownParentContexts() {
        let bundle = "dev.loom.probe"
        let clean = ["XPC_SERVICE_NAME": "application.dev.loom.probe.123.456", "SSH_AUTH_SOCK": "/session/agent"]
        #expect(LaunchEnvironment.origin(parent: clean, bundleIdentifier: bundle, parentPID: 1) == .launchServices)
        #expect(LaunchEnvironment.origin(parent: clean, bundleIdentifier: nil, parentPID: 1) == .development)
        #expect(LaunchEnvironment.origin(parent: clean, bundleIdentifier: "", parentPID: 1) == .development)
        #expect(LaunchEnvironment.origin(parent: clean, bundleIdentifier: bundle, parentPID: 123) == .development)
        #expect(LaunchEnvironment.origin(parent: clean, bundleIdentifier: "dev.loom.other", parentPID: 1) == .development)
        #expect(LaunchEnvironment.origin(parent: [:], bundleIdentifier: bundle, parentPID: 1) == .development)
        for key in ["CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_APP_TOOLS_PIPE_PATH", "CLAUDECODE",
                    "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "SHLVL"] {
            var inherited = clean
            inherited[key] = "1"
            #expect(LaunchEnvironment.origin(parent: inherited, bundleIdentifier: bundle, parentPID: 1) == .development)
        }
        var zeroLevel = clean
        zeroLevel["SHLVL"] = "0"
        #expect(LaunchEnvironment.origin(parent: zeroLevel, bundleIdentifier: bundle, parentPID: 1) == .launchServices)
        // User provider configuration is not evidence of an enclosing agent session.
        var userConfiguration = clean
        userConfiguration["CODEX_HOME"] = "/user/config"
        #expect(LaunchEnvironment.origin(parent: userConfiguration, bundleIdentifier: bundle, parentPID: 1) == .launchServices)
    }

    @Test func trustedSessionAndRCMayOverrideLocale() throws {
        let directory = try fixture("")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ["LANG": "en_US.UTF-8", "LC_CTYPE": "en_US.UTF-8"]
        let fromSession = try LaunchEnvironment.resolve(parent: parent(home: directory), session: session, testZDOTDIR: directory)
        #expect(fromSession.environment["LANG"] == session["LANG"])
        #expect(fromSession.environment["LC_CTYPE"] == session["LC_CTYPE"])
        #expect(fromSession.environment["LC_ALL"] == nil)
        try "export LANG=C.UTF-8 LC_CTYPE=C.UTF-8\n".write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let fromRC = try LaunchEnvironment.resolve(parent: parent(home: directory), session: session, testZDOTDIR: directory)
        #expect(fromRC.environment["LANG"] == "C.UTF-8")
        #expect(fromRC.environment["LC_CTYPE"] == "C.UTF-8")
    }

    @Test func successfulWarningsAreCachedAndFailureCanBeRetried() throws {
        let cache = TerminalEnvironmentCache()
        let directory = try fixture("exit 1\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        var attempts = 0
        func resolve() throws -> LaunchEnvironment.Resolution {
            attempts += 1
            return try LaunchEnvironment.resolve(parent: parent(home: directory), session: [:], testZDOTDIR: directory)
        }
        #expect(throws: (any Error).self) { try cache.value(resolve: resolve) }
        try "print -u2 -- retry-warning\nexport FOO=1\n".write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let success = try cache.value(resolve: resolve)
        #expect(success.environment["FOO"] == "1")
        #expect(success.warnings.contains { $0.contains("retry-warning") })
        try "exit 1\n".write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        #expect(try cache.value(resolve: resolve) == success)
        #expect(attempts == 2)
    }
}
