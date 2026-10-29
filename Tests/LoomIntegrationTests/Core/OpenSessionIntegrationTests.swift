import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []
    var stdout: [String] { lock.withLock { out } }
    var stderr: [String] { lock.withLock { err } }
    var output: OpenSessionCommand.Output {
        .init(standardOutput: { [self] line in lock.withLock { out.append(line) } },
              standardError: { [self] line in lock.withLock { err.append(line) } })
    }
}

// MARK: The command

@Suite(.serialized, .timeLimit(.minutes(1)))
struct OpenSessionCommandTests {
    private func environment(_ rig: OpenRig) -> [String: String] {
        ["LOOM_CONTROL_SOCKET": rig.socketPath, "LOOM_HOOK_TOKEN": rig.token,
         "LOOM_SESSION_ID": rig.requester.id.uuidString, "LOOM_MANAGED_RUN_ID": rig.runID.uuidString]
    }

    private func run(
        _ arguments: [String], environment: [String: String], stdin: Data = Data(), timeout: TimeInterval = 10
    ) async -> (code: Int32, out: CommandOutput) {
        let out = CommandOutput()
        let code = await Task.detached {
            OpenSessionCommand.run(
                arguments: arguments, environment: environment, readStandardInput: { stdin },
                output: out.output, replyTimeout: timeout
            )
        }.value
        return (code, out)
    }

    private func messageFile(_ rig: OpenRig, _ text: String) throws -> String {
        let path = rig.root.appendingPathComponent("message-\(UUID().uuidString.prefix(6)).txt")
        try Data(text.utf8).write(to: path)
        return path.path
    }

    @Test func helpPrintsTheUsageAndNeedsNoLoom() async {
        for arguments in [["--help"], ["open", "--help"], ["open", "--title", "x", "--help"]] {
            let (code, out) = await run(arguments, environment: [:])
            #expect(code == 0, "\(arguments)")
            #expect(out.stdout.joined().contains("usage: \"$SPHYRNA_CLI\" open --title"))
        }
    }

    @Test func anExplicitHarnessReachesTheServerAndAnAgentCannotRequestFullAccess() async throws {
        let entry = ModelCatalogEntry(harness: .codex, id: "codex-test", title: "Codex test",
                                      efforts: ["low", "high"], defaultEffort: "low")
        let rig = try await OpenRig.make(models: { _ in [entry] })
        defer { rig.cleanup() }
        let env = environment(rig)

        let denied = await run(["open", "--title", "T", "--harness", "codex", "--mode", "bypassPermissions",
                                "--message", "-"], environment: env, stdin: Data("go".utf8))
        #expect(denied.code == 2 && denied.out.stderr.joined().contains("Full access"))
        #expect(await rig.coordinator.snapshot().isEmpty)

        let command = Task { await run(["open", "--title", "T", "--harness", "codex", "--model", "codex-test",
                                        "--effort", "high", "--message", "-"],
                                       environment: env, stdin: Data("go".utf8)) }
        let request = try #require(await rig.waitForEntries(1).first)
        #expect(request.choices == HarnessLaunchChoices(harness: .codex, model: "codex-test", effort: "high", mode: .askBeforeEdits))
        try await rig.coordinator.deny(request.id)
        #expect(await command.value.code == 1)
    }

    @Test func badArgumentsExitTwoBeforeAnythingIsSent() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let env = environment(rig)
        let big = try messageFile(rig, String(repeating: "m", count: 65_537))
        let binary = rig.root.appendingPathComponent("binary.bin")
        try Data([0xFF, 0xFE, 0xFD]).write(to: binary)
        let ok = try messageFile(rig, "hello")
        let cases: [(String, [String])] = [
            ("no title", ["open", "--message", "-"]),
            ("no message source", ["open", "--title", "T"]),
            ("both sources", ["open", "--title", "T", "--message", "-", "--message-file", ok]),
            ("unknown option", ["open", "--title", "T", "--message", "-", "--bogus", "1"]),
            ("inline message text", ["open", "--title", "T", "--message", "do it now"]),
            ("missing value", ["open", "--title"]),
            ("duplicate", ["open", "--title", "A", "--title", "B", "--message", "-"]),
            ("empty title", ["open", "--title", "  ", "--message", "-"]),
            ("missing file", ["open", "--title", "T", "--message-file", "/nonexistent/message.txt"]),
            ("oversize file", ["open", "--title", "T", "--message-file", big]),
            ("not UTF-8", ["open", "--title", "T", "--message-file", binary.path]),
            ("unknown command", ["frobnicate"]),
        ]
        for (name, arguments) in cases {
            let (code, out) = await run(arguments, environment: env, stdin: Data("hello".utf8))
            #expect(code == 2, "\(name)")
            #expect(out.stderr.joined().hasPrefix("error: "), "\(name)")
            #expect(out.stdout.isEmpty, "\(name)")
        }
        let empty = await run(["open", "--title", "T", "--message", "-"], environment: env, stdin: Data())
        #expect(empty.code == 2, "an empty message is refused")
        let over = await run(["open", "--title", "T", "--message", "-"], environment: env,
                             stdin: Data(String(repeating: "m", count: 65_537).utf8))
        #expect(over.code == 2, "an oversize message on standard input is refused")
        #expect(await rig.coordinator.snapshot().isEmpty)
    }

    @Test func outsideLoomOrWithoutAnAnswerTheCommandExitsThree() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let arguments = ["open", "--title", "T", "--message", "-"]
        let stdin = Data("hello".utf8)

        let bare = await run(arguments, environment: [:], stdin: stdin)
        #expect(bare.code == 3)
        #expect(bare.out.stdout.first?.hasPrefix("error: not running inside a Sphyrna session") == true)

        var partial = environment(rig)
        partial["LOOM_MANAGED_RUN_ID"] = "not-a-uuid"
        #expect(await run(arguments, environment: partial, stdin: stdin).code == 3)

        var gone = environment(rig)
        gone["LOOM_CONTROL_SOCKET"] = rig.root.appendingPathComponent("nobody.sock").path
        #expect(await run(arguments, environment: gone, stdin: stdin).code == 3, "Loom unreachable")

        var wrong = environment(rig)
        wrong["LOOM_HOOK_TOKEN"] = "someone else"
        let denied = await run(arguments, environment: wrong, stdin: stdin)
        #expect(denied.code == 3)
        #expect(denied.out.stdout.first?.hasPrefix("error: ") == true)

        var stale = environment(rig)
        stale["LOOM_MANAGED_RUN_ID"] = UUID().uuidString
        #expect(await run(arguments, environment: stale, stdin: stdin).code == 3, "a run Loom does not know")
        #expect(await rig.coordinator.snapshot().isEmpty)
    }

    @Test func startedDeniedAndInvalidMapToTheirLinesAndExitCodes() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let env = environment(rig)
        let recorder = StartRecorder()
        let file = try messageFile(rig, "First line\nSecond line — çalışın")

        // started: arguments reach the request as given, from a file.
        let started = Task { await run(["open", "--title=Fix login", "--project", "beta",
                                        "--message-file", file], environment: env) }
        let entry = try #require(await rig.waitForEntries(1).first)
        #expect(entry.title == "Fix login" && entry.projectID == rig.projectB.id)
        #expect(entry.message == "First line\nSecond line — çalışın")
        let newID = try await rig.coordinator.approve(entry.id, start: recorder.start)
        let first = await started.value
        #expect(first.code == 0)
        #expect(first.out.stdout == ["started \(newID.uuidString.lowercased()) \"Fix login\""])

        // denied (the message on standard input).
        let refused = Task { await run(["open", "--title", "Nope", "--message", "-"], environment: env,
                                       stdin: Data("from stdin".utf8)) }
        let waiting = try #require(await rig.waitForEntries(1).first)
        #expect(waiting.message == "from stdin" && waiting.projectID == rig.projectA.id)
        // A second command from the same session meanwhile is refused with exit 2.
        let second = await run(["open", "--title", "Again", "--message", "-"], environment: env, stdin: Data("x".utf8))
        #expect(second.code == 2)
        #expect(second.out.stdout == ["error: a request from this session is already waiting"])
        try await rig.coordinator.deny(waiting.id)
        let denied = await refused.value
        #expect(denied.code == 1 && denied.out.stdout == ["denied"])

        #expect(recorder.recorded.count == 1)

        // invalid in Loom (unknown project): exit 2 with the reason.
        let unknown = await run(["open", "--title", "T", "--project", "nope", "--message", "-"], environment: env,
                                stdin: Data("x".utf8))
        #expect(unknown.code == 2 && unknown.out.stdout.first?.hasPrefix("error: no Sphyrna project") == true)
    }

    @Test func anOldAgentsTicketFlagStillExitsZeroAndChangesNothing() async throws {
        // Agent rules written for 0.4.x pass `--ticket <key>`. It is accepted and ignored (D-69): no validation of
        // the key, no lookup, no `exists` line, and the request is an ordinary one.
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let env = environment(rig)
        let recorder = StartRecorder()
        // A session whose title starts with the key exists: it must not turn the request into anything else.
        let held = ManagedSession(provider: .claude, workingDirectory: rig.projectA.path)
        try await rig.catalog.insertSession(held, title: "EDDP-412 Fix login", projectID: rig.projectA.id)

        for (index, ticket) in [["--ticket", "EDDP-412"], ["--ticket=eddp-412"], ["--ticket", "not even a valid key / at all"]].enumerated() {
            let command = Task { await run(["open", "--title", "EDDP-412 Fix login"] + ticket + ["--message", "-"],
                                           environment: env, stdin: Data("go \(index)".utf8)) }
            let entry = try #require(await rig.waitForEntries(1).first)
            #expect(entry.title == "EDDP-412 Fix login" && entry.phase == .waiting && entry.message == "go \(index)")
            let newID = try await rig.coordinator.approve(entry.id, start: recorder.start)
            let result = await command.value
            #expect(result.code == 0, "\(ticket)")
            #expect(result.out.stdout == ["started \(newID.uuidString.lowercased()) \"EDDP-412 Fix login\""])
            #expect(result.out.stderr.isEmpty)
        }
        #expect(recorder.recorded.count == 3)
        // Giving it twice is still a usage error, like any option.
        let twice = await run(["open", "--title", "T", "--ticket", "A-1", "--ticket", "B-2", "--message", "-"],
                              environment: env, stdin: Data("x".utf8))
        #expect(twice.code == 2)
        #expect(OpenSessionCommand.usage.contains("accepted and ignored"))
    }

    @Test func anUndecidedRequestExitsZeroWithAPendingLine() async throws {
        let rig = try await OpenRig.make(replyDelay: 0.3)
        defer { rig.cleanup() }
        let (code, out) = await run(["open", "--title", "Wait", "--message", "-"], environment: environment(rig),
                                    stdin: Data("hello".utf8))
        #expect(code == 0)
        #expect(out.stdout.first?.hasPrefix("pending: approve or deny it in Sphyrna") == true)
        #expect(out.stdout.first?.contains("lost if Sphyrna quits") == true)
        #expect(await rig.coordinator.snapshot().count == 1, "the request stays")
    }

    @Test func theClientGivesUpWhenLoomDoesNotAnswerInTime() async throws {
        let rig = try await OpenRig.make(replyDelay: 30)
        defer { rig.cleanup() }
        let (code, out) = await run(["open", "--title", "Wait", "--message", "-"], environment: environment(rig),
                                    stdin: Data("hello".utf8), timeout: 0.5)
        #expect(code == 3)
        #expect(out.stdout.first?.hasPrefix("error: Sphyrna could not be reached or did not answer") == true)
        #expect(OpenSessionLimits.clientWait > OpenSessionLimits.serverReplyDelay)
    }

    // MARK: The helper binary

    private func runHelper(_ arguments: [String], environment: [String: String], stdin: Data = Data())
        async throws -> (code: Int32, out: String, err: String) {
        let helper = Products.directory
            .appendingPathComponent("loom-hook")
        return try await Task.detached {
            let process = Process()
            process.executableURL = helper
            process.arguments = arguments
            process.environment = environment
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }.value
    }

    @Test func theHelperBinaryAsksOverTheControlSocketAndWithoutArgumentsStaysAHookHelper() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let recorder = StartRecorder()

        let help = try await runHelper(["open", "--help"], environment: [:])
        #expect(help.code == 0 && help.out.contains("usage:"))
        let outside = try await runHelper(["open", "--title", "T", "--message", "-"], environment: [:], stdin: Data("m".utf8))
        #expect(outside.code == 3 && outside.out.hasPrefix("error: not running inside a Sphyrna session"))
        let bad = try await runHelper(["open", "--title", "T"], environment: environment(rig))
        #expect(bad.code == 2 && bad.err.hasPrefix("error: "))

        // No arguments: the hook path, unchanged (no Loom connection and no payload: exit 1, no output).
        let hook = try await runHelper([], environment: [:])
        #expect(hook.code == 1 && hook.out.isEmpty && hook.err.isEmpty)

        let asked = Task { try await runHelper(
            ["open", "--title", "From the binary", "--ticket", "BIN-1", "--message", "-"], // an old agent's flag
            environment: environment(rig), stdin: Data("Do the thing".utf8)
        ) }
        let entry = try #require(await rig.waitForEntries(1).first)
        #expect(entry.message == "Do the thing" && entry.title == "From the binary")
        let newID = try await rig.coordinator.approve(entry.id, start: recorder.start)
        let result = try await asked.value
        #expect(result.code == 0)
        #expect(result.out == "started \(newID.uuidString.lowercased()) \"From the binary\"\n")
    }
}

// MARK: Through the runtime

@Suite(.serialized, .timeLimit(.minutes(2)))
struct OpenSessionRuntimeTests {
    private final class DefaultMode: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = "plan"
        var value: String {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func stub() throws -> (script: String, directory: URL) {
        let directory = URL(fileURLWithPath: "/tmp/lo-stub-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("claude-stub.sh")
        try """
            #!/bin/sh
            printf '%s\\0' "$@" > "$LOOM_FAKE_STATE/argv-$LOOM_SESSION_ID"
            printf '%s\\n%s\\n' "$LOOM_CLI" "$LOOM_CONTROL_SOCKET" > "$LOOM_FAKE_STATE/env-$LOOM_SESSION_ID"
            exec sleep 120
            """.write(to: script, atomically: true, encoding: .utf8)
        #expect(chmod(script.path, 0o755) == 0)
        return (script.path, directory)
    }

    private func arguments(of session: UUID, in context: RuntimeContext) async -> [String]? {
        let file = context.state.appendingPathComponent("argv-\(session.uuidString)")
        let appeared = await SessionRuntimeRig.waitUntil { FileManager.default.fileExists(atPath: file.path) }
        guard appeared,
              let data = try? Data(contentsOf: file) else { return nil }
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    @Test func claudeSessionsStartWithLoomsSkillFolderWrittenBeforeThem() async throws {
        let (script, directory) = try stub()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try await SessionRuntimeRig.makeContext(executableOverride: script, claudePlugin: true)
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let launch = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
        let argv = try #require(await arguments(of: launch.sessionID, in: context))
        let index = try #require(argv.firstIndex(of: "--plugin-dir"))
        let plugin = URL(fileURLWithPath: argv[index + 1])
        #expect(plugin.standardizedFileURL == context.root.appendingPathComponent("claude-plugin").standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: plugin.appendingPathComponent("skills/open-session/SKILL.md").path))
    }

    @Test func anOpenedSessionWithoutItsOwnModeTakesSphyrnasDefaultAndLeavesTheProjectsLastUsedAlone() async throws {
        let (script, directory) = try stub()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultMode = DefaultMode()
        let context = try await SessionRuntimeRig.makeContext(
            executableOverride: script, extraClaudeHelp: " --permission-mode <mode>",
            defaultOpenedMode: { _ in defaultMode.value }
        )
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let requester = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
        let hooks = try #require(await context.runtime.hookConfiguration)
        let control = try #require(hooks.controlSocketPath)
        let token = hooks.authenticationToken

        func ask(_ title: String, mode: String?) -> Task<OpenSessionReply, any Error> {
            let request = OpenSessionWireRequest(
                authenticationToken: token, sessionID: requester.sessionID, managedRunID: requester.runID,
                title: title, project: nil, message: "go", mode: mode
            )
            return Task.detached { try OpenSessionClient.exchange(request, socketPath: control) }
        }
        func approveNext() async throws -> RuntimeLaunch {
            #expect(await SessionRuntimeRig.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
            let entry = try #require(await context.runtime.openRequestSnapshot().first)
            return try await context.runtime.approveOpenRequest(entry.id)
        }

        // No `--mode`: the session starts in Sphyrna's default, as a draft does.
        let defaulted = ask("Defaulted", mode: nil)
        #expect(await SessionRuntimeRig.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        let pending = try #require(await context.runtime.openRequestSnapshot().first)
        #expect(pending.choices.mode == .plan && pending.modeFromUserDefault)
        defaultMode.value = "auto"
        let first = try await approveNext()
        #expect(try await defaulted.value.status == .started)
        let argv = try #require(await arguments(of: first.sessionID, in: context))
        let index = try #require(argv.firstIndex(of: "--permission-mode"))
        #expect(argv[index + 1] == "plan")
        #expect(try await context.catalog.launchChoices(sessionID: first.sessionID).permissionMode == "plan")
        // An agent's pick is not the project's "last used": the next draft keeps its own default.
        #expect(try await context.catalog.lastUsedLaunchChoices()[project.id.uuidString] == nil)

        // The agent's own mode wins over the default.
        let chosen = ask("Chosen", mode: ClaudePermissionMode.acceptEdits.rawValue)
        let second = try await approveNext()
        #expect(try await chosen.value.status == .started)
        let chosenArgv = try #require(await arguments(of: second.sessionID, in: context))
        let chosenIndex = try #require(chosenArgv.firstIndex(of: "--permission-mode"))
        #expect(chosenArgv[chosenIndex + 1] == ClaudePermissionMode.acceptEdits.rawValue)
        #expect(try await context.catalog.lastUsedLaunchChoices()[project.id.uuidString] == nil)

        // A user-fixed Full access default is shown and frozen; the agent did not select it.
        defaultMode.value = ClaudePermissionMode.fullAccess.rawValue
        let userDefault = ask("User default", mode: nil)
        #expect(await SessionRuntimeRig.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        let full = try #require(await context.runtime.openRequestSnapshot().first)
        #expect(full.choices.mode == .fullAccess && full.modeFromUserDefault)
        defaultMode.value = "plan"
        let third = try await approveNext()
        #expect(try await userDefault.value.status == .started)
        let fullArgv = try #require(await arguments(of: third.sessionID, in: context))
        let fullIndex = try #require(fullArgv.firstIndex(of: "--permission-mode"))
        #expect(fullArgv[fullIndex + 1] == ClaudePermissionMode.fullAccess.rawValue)
        #expect(try await context.catalog.lastUsedLaunchChoices()[project.id.uuidString] == nil)
    }

    @Test func approvedCodexOpenUsesItsOwnHarnessAndDoesNotChangeProjectMemory() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let requester = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
        let hooks = try #require(await context.runtime.hookConfiguration)
        let request = OpenSessionWireRequest(authenticationToken: hooks.authenticationToken, sessionID: requester.sessionID,
            managedRunID: requester.runID, title: "Codex request", project: nil, message: "go", harness: "codex")
        let socket = try #require(hooks.controlSocketPath)
        let reply = Task.detached { try OpenSessionClient.exchange(request, socketPath: socket) }
        #expect(await SessionRuntimeRig.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        let pending = try #require(await context.runtime.openRequestSnapshot().first)
        #expect(pending.choices.harness == .codex && pending.choices.mode == .askBeforeEdits)
        let before = try await context.catalog.lastUsedHarnessChoices()
        let screen = SessionRuntimeRig.Screen()
        let opened = try await context.runtime.approveOpenRequest(pending.id, outputSink: screen)
        screen.attach(opened.terminal)
        #expect(await screen.contains("CODEX-TURN-DONE completed echo go"))
        #expect(try await reply.value.status == .started)
        let record = try #require(try await context.catalog.session(id: opened.sessionID))
        #expect(record.session.provider == .codex && record.openedBy == requester.sessionID)
        #expect(record.title == "Codex request" && record.projectID == project.id)
        #expect(try await context.catalog.lastUsedHarnessChoices() == before)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func approvingARequestStartsANormalSessionWithTheNameTheMessageAndItsOrigin() async throws {
        let (script, directory) = try stub()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try await SessionRuntimeRig.makeContext(
            executableOverride: script, extraClaudeHelp: " --permission-mode <mode>")
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project

        // The asking session: a normal Loom session (its stub never sends hook events).
        let requester = try await context.runtime.startConversation(provider: .claude, projectID: project.id)
        try await context.catalog.renameSession(sessionID: requester.sessionID, to: "Planner")
        let hooks = try #require(await context.runtime.hookConfiguration)
        let control = try #require(hooks.controlSocketPath)
        #expect(control.hasSuffix(".sock") && control.contains("/c-"))

        func ask(_ title: String, message: String, token: String? = nil,
                 from asker: RuntimeLaunch? = nil, session: UUID? = nil, run: UUID? = nil) -> Task<OpenSessionReply, any Error> {
            let asker = asker ?? requester
            let request = OpenSessionWireRequest(
                authenticationToken: token ?? hooks.authenticationToken, sessionID: session ?? asker.sessionID,
                managedRunID: run ?? asker.runID, title: title, project: nil, message: message
            )
            return Task.detached { try OpenSessionClient.exchange(request, socketPath: control) }
        }

        // Only the live run, for the card it was launched on, with the run's token.
        #expect(try await ask("Nope", message: "x", token: "wrong").value.status == .unavailable)
        #expect(try await ask("Nope", message: "x", session: UUID()).value.status == .unavailable)
        #expect(try await ask("Nope", message: "x", run: UUID()).value.status == .unavailable)
        #expect(await context.runtime.openRequestSnapshot().isEmpty)
        let message = "--starts with a dash\nand has a second line"
        let reply = ask("EDDP-412 Fix login", message: message)
        #expect(await SessionRuntimeRig.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        let pending = try #require(await context.runtime.openRequestSnapshot().first)
        #expect(pending.requesterTitle == "Planner" && pending.projectID == project.id)
        // Asking started nothing: the catalog still has only the requester.
        #expect(try await context.catalog.sessions().map(\.session.id) == [requester.sessionID])

        let launch = try #require(try await context.runtime.approveOpenRequest(pending.id))
        let answer = try await reply.value
        #expect(answer.status == .started && answer.sessionID == launch.sessionID)
        #expect(await context.runtime.openRequestSnapshot().isEmpty)

        // The process was launched with the name and the message after every option.
        let argv = try #require(await arguments(of: launch.sessionID, in: context))
        #expect(argv.suffix(2) == ["--", message])
        let name = try #require(argv.firstIndex(of: "-n"))
        #expect(argv[name + 1] == "EDDP-412 Fix login")
        #expect(argv.starts(with: ["--session-id", launch.sessionID.uuidString]))
        let requesterArgv = try #require(await arguments(of: requester.sessionID, in: context))
        #expect(!requesterArgv.contains("-n") && !requesterArgv.contains("--"), "a user-started session is unchanged")
        // Its environment carries the command and the socket, like every Claude session.
        let envFile = context.state.appendingPathComponent("env-\(launch.sessionID.uuidString)")
        #expect(await SessionRuntimeRig.waitUntil { FileManager.default.fileExists(atPath: envFile.path) })
        let env = try String(contentsOf: envFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(env == [hooks.helperPath, control])

        // A normal Loom session: a card with the requested title (automatic), its origin and a run, and no tracker key.
        let row = try #require(try await context.catalog.session(id: launch.sessionID))
        #expect(row.title == "EDDP-412 Fix login" && row.titleIsCustom == false)
        #expect(row.openedBy == requester.sessionID)
        #expect(row.projectID == project.id && row.session.workingDirectory == project.path)
        #expect(await context.supervisor.session(id: launch.sessionID)?.currentRun != nil)
        #expect(try await context.catalog.runs().contains { $0.id == launch.runID })

        // Loom does not look up existing sessions: asking again under the same title waits like any request.
        let same = ask("EDDP-412 Fix login", message: "again")
        #expect(await SessionRuntimeRig.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        let waiting = try #require(await context.runtime.openRequestSnapshot().first)
        #expect(waiting.phase == .waiting && waiting.title == "EDDP-412 Fix login")
        try await context.runtime.denyOpenRequest(waiting.id)
        #expect(try await same.value.status == .denied)
        #expect(try await context.catalog.sessions().count == 2)

        // Deny starts nothing; a later approve of a denied request is refused.
        let no = ask("Denied", message: "no")
        #expect(await SessionRuntimeRig.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        let denied = try #require(await context.runtime.openRequestSnapshot().first)
        try await context.runtime.denyOpenRequest(denied.id)
        #expect(try await no.value.status == .denied)
        await #expect(throws: OpenSessionError.self) { _ = try await context.runtime.approveOpenRequest(denied.id) }
        #expect(try await context.catalog.sessions().count == 2)

        // A run that has ended is no longer a live run: its token and ids ask nothing of Loom.
        _ = try await context.runtime.stopConversation(sessionID: requester.sessionID)
        #expect(try await ask("Too late", message: "late").value.status == .unavailable)
        #expect(await context.runtime.openRequestSnapshot().isEmpty)

        // Quit answers anyone still waiting and removes the control socket.
        let last = ask("At quit", message: "bye", from: launch)
        #expect(await SessionRuntimeRig.waitUntil { await context.runtime.openRequestSnapshot().count == 1 })
        #expect((await context.runtime.shutdown()).succeeded)
        #expect(try await last.value.status == .unavailable)
        #expect(await SessionRuntimeRig.waitUntil { access(control, F_OK) != 0 })
    }
}
