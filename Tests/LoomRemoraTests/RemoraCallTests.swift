import Darwin
import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora

private final class FakeAnchor: NSObject {}

/// Remora's call against the fake provider's one-shot mode: nothing here starts a real Claude.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct RemoraCallTests {
    private static var fake: String {
        Bundle(for: FakeAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("loom-fake-provider").path
    }

    /// One call's surroundings: its own work folder, log file and pid file.
    private struct Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-\(UUID().uuidString.prefix(8))")
        var work: URL { root.appendingPathComponent("remora/run") }
        var log: URL { root.appendingPathComponent("log.json") }
        var pids: URL { root.appendingPathComponent("pid") }
        let supervisor: ProcessSupervisor
        let usage = RemoraUsage()

        init() throws {
            supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func call(_ script: [String: String] = [:], question: TimeInterval = 20, brief: TimeInterval = 20,
                  grace: TimeInterval = 1) -> RemoraCall {
            var extra = ["LOOM_FAKE_REMORA_LOG": log.path, "LOOM_FAKE_PIDFILE": pids.path]
            extra.merge(script) { _, new in new }
            return RemoraCall(
                supervisor: supervisor, executable: RemoraCallTests.fake,
                environment: RemoraCall.environment(from: ["PATH": "/usr/bin:/bin"], configDirectory: nil),
                workingDirectory: work, usage: usage, questionDeadline: question, briefDeadline: brief,
                terminationGrace: grace, additionalEnvironment: extra)
        }

        func logged() throws -> [String: Any] {
            let data = try Data(contentsOf: log)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func pid() async -> Int32? {
            for _ in 0..<500 {
                if let text = try? String(contentsOf: pids, encoding: .utf8), let value = Int32(text) { return value }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }

        func finish() async { _ = await supervisor.shutdown(); try? FileManager.default.removeItem(at: root) }
    }

    private struct Collected {
        var pieces: [String] = []
        var answer: RemoraAnswer?
        var failure: RemoraFailure?
        var other: (any Error)?
        var text: String { pieces.joined() }
    }

    private func collect(_ stream: AsyncThrowingStream<RemoraEvent, any Error>) async -> Collected {
        var collected = Collected()
        do {
            for try await event in stream {
                switch event {
                case let .text(piece): collected.pieces.append(piece)
                case let .finished(answer): collected.answer = answer
                }
            }
        } catch let failure as RemoraFailure { collected.failure = failure }
        catch { collected.other = error }
        return collected
    }

    private func gone(_ pid: Int32, within seconds: TimeInterval = 3) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    // MARK: The answer

    @Test func aQuestionStreamsItsTextInOrderAndEndsWithTheResultsUsageAndModel() async throws {
        let rig = try Rig()
        let request = RemoraRequest(kind: .question, pack: "Where did I leave off?", knownSessionIDs: ["s-one"])
        let result = await collect(rig.call().run(request))
        let answer = try #require(result.answer, "failure: \(String(describing: result.failure)) \(String(describing: result.other))")
        #expect(result.pieces.count > 3, "the text did not stream in pieces")
        #expect(result.text == answer.text)
        #expect(answer.text.hasPrefix("You left off in the loom project"))
        #expect(!result.text.contains("```") && !result.text.contains("remora"))
        #expect(answer.usage == RemoraTokenUsage(input: 2, cacheCreation: 1_200, cacheRead: 0, output: 64))
        #expect(answer.costUSD == 0.0123)
        #expect(answer.model == "claude-sonnet-5-5")
        #expect(answer.duration > .zero)
        #expect(answer.block == .valid)
        #expect(answer.cited == ["s-one"])
        #expect(answer.chips == [RemoraChip(sessionID: "s-one", why: "Waits for your review")])
        #expect(answer.drafts == [RemoraDraft(sessionID: "s-one", text: "Please run the checks again.")])
        #expect(answer.proposedFacts.isEmpty)
        await rig.finish()
    }

    @Test func theBlockIsStrippedParsedAndItsUnknownSessionsDropped() async throws {
        let rig = try Rig()
        let answerText = """
        Two sessions matter.

        ```remora
        {"cited":["a","ghost"],"chips":[{"session":"ghost","why":"x"},{"session":"b","why":"Failed twice"}],\
        "drafts":[{"session":"ghost","text":"nope"}],"facts":["Prefers short answers"]}
        ```
        """
        let result = await collect(rig.call(["LOOM_FAKE_REMORA_ANSWER": answerText]).run(
            RemoraRequest(kind: .question, pack: "p", knownSessionIDs: ["a", "b"])))
        let answer = try #require(result.answer)
        #expect(answer.text == "Two sessions matter.")
        #expect(answer.cited == ["a"])
        #expect(answer.chips == [RemoraChip(sessionID: "b", why: "Failed twice")])
        #expect(answer.drafts.isEmpty)
        #expect(answer.proposedFacts == ["Prefers short answers"])
        await rig.finish()
    }

    @Test func anInvalidBlockKeepsTheAnswerAndDropsTheChips() async throws {
        let rig = try Rig()
        let result = await collect(rig.call(["LOOM_FAKE_REMORA_ANSWER": "It is done.\n\n```remora\n{\"chips\": [oops\n```"]).run(
            RemoraRequest(kind: .question, pack: "p", knownSessionIDs: ["s-one"])))
        let answer = try #require(result.answer)
        #expect(answer.text == "It is done.")
        #expect(answer.block == .invalid)
        #expect(answer.chips.isEmpty && answer.cited.isEmpty && answer.drafts.isEmpty && answer.proposedFacts.isEmpty)
        #expect(result.text == "It is done.")
        await rig.finish()
    }

    @Test func aMissingBlockCostsOnlyTheChips() async throws {
        let rig = try Rig()
        let result = await collect(rig.call(["LOOM_FAKE_REMORA_ANSWER": "Nothing moved today."]).run(
            RemoraRequest(kind: .question, pack: "p")))
        let answer = try #require(result.answer)
        #expect(answer.text == "Nothing moved today.")
        #expect(answer.block == .missing)
        #expect(answer.chips.isEmpty)
        await rig.finish()
    }

    // MARK: Failures

    @Test func aRefusedPackIsAFailureEvenThoughItsSubtypeIsSuccess() async throws {
        let rig = try Rig()
        let result = await collect(rig.call(["LOOM_FAKE_REMORA": "refusal"]).run(RemoraRequest(kind: .brief, pack: "p")))
        #expect(result.answer == nil)
        let failure = try #require(result.failure)
        #expect(failure.kind == .refused)
        #expect(failure.usage?.total == 2_404, "a refused call is billed and says so")
        // The tokens still count in today's use.
        #expect(rig.usage.today.briefs == 1)
        #expect(rig.usage.today.tokens.cacheCreation == 2_400)
        await rig.finish()
    }

    @Test func anErrorResultIsAFailure() async throws {
        let rig = try Rig()
        let result = await collect(rig.call(["LOOM_FAKE_REMORA": "error"]).run(RemoraRequest(kind: .question, pack: "p")))
        #expect(result.answer == nil)
        #expect(result.failure?.kind == .apiError)
        #expect(result.failure?.detail.hasPrefix("API Error") == true)
        await rig.finish()
    }

    @Test func aMissingLoginIsNamed() async throws {
        let rig = try Rig()
        let result = await collect(rig.call(["LOOM_FAKE_REMORA": "login"]).run(RemoraRequest(kind: .question, pack: "p")))
        #expect(result.failure?.kind == .notLoggedIn)
        await rig.finish()
    }

    @Test func aChildThatEndsWithoutAResultIsAFailure() async throws {
        let rig = try Rig()
        let result = await collect(rig.call(["LOOM_FAKE_REMORA": "crash"]).run(RemoraRequest(kind: .question, pack: "p")))
        #expect(result.answer == nil)
        #expect(result.failure?.kind == .endedWithoutAnswer)
        await rig.finish()
    }

    @Test func noAnswerByTheDeadlineIsATimeoutAndEndsTheChild() async throws {
        let rig = try Rig()
        let clock = ContinuousClock()
        var result = Collected()
        let elapsed = await clock.measure {
            result = await collect(rig.call(["LOOM_FAKE_REMORA": "silent"], question: 0.7, grace: 1).run(
                RemoraRequest(kind: .question, pack: "p")))
        }
        #expect(result.failure?.kind == .timedOut)
        // `silent` never answers: any end is the deadline. The bound only catches a hang, with room for a loaded machine.
        #expect(elapsed < .seconds(20), "took \(elapsed)")
        let pid = try #require(await rig.pid())
        #expect(await gone(pid))
        await rig.finish()
    }

    @Test func aBriefHasTheLongerDeadline() async throws {
        let rig = try Rig()
        // Two deltas, 400 ms apart: past a 0.3 s question deadline, well inside a brief's.
        let script = ["LOOM_FAKE_REMORA": "slow", "LOOM_FAKE_REMORA_ANSWER": "Hello there"]
        let question = await collect(rig.call(script, question: 0.3, brief: 20).run(RemoraRequest(kind: .question, pack: "p")))
        #expect(question.failure?.kind == .timedOut)
        let brief = await collect(rig.call(script, question: 0.3, brief: 20).run(RemoraRequest(kind: .brief, pack: "p")))
        #expect(brief.answer?.text == "Hello there")
        #expect(RemoraCall.questionTimeout == 60 && RemoraCall.briefTimeout == 120)
        await rig.finish()
    }

    @Test func outputPastTheBoundIsAFailureAndStopsTheChild() async throws {
        let rig = try Rig()
        let result = await collect(rig.call(["LOOM_FAKE_REMORA": "flood"]).run(RemoraRequest(kind: .question, pack: "p")))
        #expect(result.failure?.kind == .outputTooLarge)
        let pid = try #require(await rig.pid())
        #expect(await gone(pid))
        await rig.finish()
    }

    // MARK: Cancel

    @Test func aCancelledCallEndsTheChildAtOnce() async throws {
        let rig = try Rig()
        let call = rig.call(["LOOM_FAKE_REMORA": "slow"], question: 60)
        let consumer = Task { await collect(call.run(RemoraRequest(kind: .question, pack: "p", knownSessionIDs: ["s-one"]))) }
        let pid = try #require(await rig.pid())
        try await Task.sleep(for: .milliseconds(900)) // a few deltas are out; the answer takes ~15 s
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            consumer.cancel()
            _ = await consumer.value
        }
        // At once, against an answer that takes ~15 s; the bound leaves room for a loaded machine.
        #expect(elapsed < .seconds(8), "the consumer waited \(elapsed)")
        #expect(await gone(pid, within: 8), "the child outlived the cancel")
        let result = await consumer.value
        #expect(result.answer == nil && result.failure == nil, "a cancelled call ends quietly")
        await rig.finish()
    }

    @Test func quitCancelsAndAwaitsACallInFlight() async throws {
        let rig = try Rig()
        let call = rig.call(["LOOM_FAKE_REMORA": "slow"], question: 60)
        let consumer = Task { await collect(call.run(RemoraRequest(kind: .question, pack: "p"))) }
        let pid = try #require(await rig.pid())
        let report = await rig.supervisor.shutdown()
        #expect(report.succeeded, "\(report.errors)")
        #expect(kill(pid, 0) != 0 && errno == ESRCH, "a child was left after Quit")
        let result = await consumer.value
        #expect(result.answer == nil)
        try? FileManager.default.removeItem(at: rig.root)
    }

    // MARK: Guards

    @Test func theArgvIsTheCallsShapeAndTheEnvironmentExactlyTheList() async throws {
        let rig = try Rig()
        let pack = "PACK-MARKER-\(UUID().uuidString) where did I leave off?"
        let result = await collect(rig.call().run(RemoraRequest(kind: .question, model: "haiku", effort: "medium", pack: pack)))
        #expect(result.answer != nil)
        let record = try rig.logged()
        let arguments = try #require(record["arguments"] as? [String])
        #expect(arguments == [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", "haiku", "--effort", "medium",
            "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--no-session-persistence",
            "--tools", "", "--system-prompt", RemoraRules.text, "--setting-sources", "",
        ])
        #expect(!arguments.contains("--input-format"))
        #expect(!arguments.contains { $0.contains("plugin") })
        #expect(arguments.filter { $0 == "--settings" }.count == 1)
        #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "")
        #expect(!arguments.joined(separator: "\n").contains("PACK-MARKER"), "the pack went on argv")
        #expect(record["packBytes"] as? Int == pack.utf8.count, "the pack did not arrive whole on stdin")
        // The environment: exactly the list (the fake's own LOOM_FAKE_* variables are the test's script).
        // (`__CF_USER_TEXT_ENCODING` is Foundation's own, set inside the fake process at start-up.)
        let keys = Set(try #require(record["environmentKeys"] as? [String])
            .filter { !$0.hasPrefix("LOOM_FAKE_") && $0 != "__CF_USER_TEXT_ENCODING" })
        #expect(keys == Self.keys.subtracting(["CLAUDE_CONFIG_DIR"]), "environment: \(keys.sorted())")
        // The work folder: the one given, made, and still empty.
        let cwd = try #require(record["cwd"] as? String)
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == rig.work.resolvingSymlinksInPath())
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.work.path).isEmpty)
        await rig.finish()
    }

    /// The list, spelled out: a key added fails the tests below, not only this file's source.
    static let keys: Set<String> = [
        "HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL", "TERM", "CLAUDE_CONFIG_DIR",
        "CLAUDE_CODE_DISABLE_AGENT_VIEW", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CODE_PROMPT_CACHE_TTL",
    ]

    /// Prompt caching stays on for both kinds (D-84), with the one-hour lifetime Sphyrna chooses (D-85); nothing switches it off.
    @Test func aBriefsChildGetsTheSameListWithTheOneHourCache() async throws {
        #expect(RemoraCall.environmentKeys == Self.keys)
        #expect(!RemoraCall.environmentKeys.contains("DISABLE_PROMPT_CACHING"))
        let rig = try Rig()
        let result = await collect(rig.call().run(RemoraRequest(kind: .brief, model: "haiku", effort: "low", pack: "brief pack")))
        #expect(result.answer != nil)
        let keys = Set(try #require(try rig.logged()["environmentKeys"] as? [String])
            .filter { !$0.hasPrefix("LOOM_FAKE_") && $0 != "__CF_USER_TEXT_ENCODING" })
        #expect(keys == Self.keys.subtracting(["CLAUDE_CONFIG_DIR"]), "environment: \(keys.sorted())")
        let built = RemoraCall.environment(from: ["DISABLE_PROMPT_CACHING": "1"], configDirectory: nil)
        #expect(built["CLAUDE_CODE_PROMPT_CACHE_TTL"] == "1h" && built["DISABLE_PROMPT_CACHING"] == nil)
        await rig.finish()
    }

    /// The stable prefix reaches the model as part of the system prompt (D-84), by a file and never by argv.
    @Test func aSuffixGoesIntoASystemPromptFileNeverOnArgvAndTheFileIsGoneAfterwards() async throws {
        let rig = try Rig()
        let suffix = "<sessions>\nSTABLE-MARKER-\(UUID().uuidString)\n</sessions>\n"
        let request = RemoraRequest(kind: .question, model: "haiku", effort: "low", pack: "STDIN-PART", systemSuffix: suffix)
        let stream = rig.call(["LOOM_FAKE_REMORA": "slow"]).run(request)
        async let collected = collect(stream)
        // While the child runs: one file, 0600, in the 0700 folder next to the run folder, rules then suffix.
        let folder = rig.root.appendingPathComponent("remora")
        var found: URL?
        for _ in 0..<500 where found == nil {
            found = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("system-") && $0.pathExtension == "txt" }
            if found == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let file = try #require(found, "the system prompt file never appeared")
        func mode(_ url: URL) throws -> Int { try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
        #expect(try mode(file) == 0o600 && mode(folder) == 0o700)
        #expect(try String(contentsOf: file, encoding: .utf8) == RemoraRules.text + "\n\n" + suffix)
        let result = await collected
        #expect(result.answer != nil)
        let record = try rig.logged()
        let arguments = try #require(record["arguments"] as? [String])
        let flag = try #require(arguments.firstIndex(of: "--system-prompt-file"))
        let named = URL(fileURLWithPath: arguments[flag + 1])
        #expect(named.lastPathComponent == file.lastPathComponent)
        #expect(named.deletingLastPathComponent().resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
        #expect(!arguments.contains("--system-prompt"), "the rules went on argv beside the file")
        #expect(!arguments.joined(separator: "\n").contains("STABLE-MARKER") && !arguments.contains(RemoraRules.text), "the text went on argv")
        #expect(arguments == RemoraCall.arguments(model: "haiku", effort: "low", systemPromptFile: arguments[flag + 1]))
        #expect(record["packBytes"] as? Int == "STDIN-PART".utf8.count, "stdin holds the rest of the pack only")
        // Gone with the call, and the run folder stayed empty.
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.work.path).isEmpty)
        await rig.finish()
    }

    @Test func aRequestWithoutASuffixKeepsTheRulesOnArgvAndWritesNoFile() async throws {
        let rig = try Rig()
        #expect(RemoraCall.arguments(model: "haiku", effort: "low").contains("--system-prompt"))
        #expect(!RemoraCall.arguments(model: "haiku", effort: "low").contains("--system-prompt-file"))
        let result = await collect(rig.call().run(RemoraRequest(kind: .question, pack: "plain")))
        #expect(result.answer != nil)
        let folder = rig.root.appendingPathComponent("remora")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("system-") }.isEmpty)
        await rig.finish()
    }

    @Test func theEnvironmentBuilderPassesOnOnlyTheListedKeys() {
        let source = ["HOME": "/Users/x", "PATH": "/opt/bin:/usr/bin", "USER": "x", "LOGNAME": "x", "TMPDIR": "/tmp/x/",
                      "LANG": "tr_TR.UTF-8", "SHELL": "/bin/zsh", "TERM": "xterm", "ANTHROPIC_API_KEY": "secret",
                      "CLAUDE_CONFIG_DIR": "/elsewhere", "CLAUDE_CODE_OAUTH_TOKEN": "t", "OPENAI_API_KEY": "k"]
        let home = RemoraCall.environment(from: source, configDirectory: nil)
        #expect(Set(home.keys) == Self.keys.subtracting(["CLAUDE_CONFIG_DIR"]))
        #expect(home["HOME"] == "/Users/x" && home["PATH"] == "/opt/bin:/usr/bin" && home["USER"] == "x")
        #expect(home["CLAUDE_CODE_DISABLE_AGENT_VIEW"] == "1")
        #expect(home["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        let pinned = RemoraCall.environment(from: source, configDirectory: "/profile")
        #expect(Set(pinned.keys) == Self.keys)
        #expect(pinned["CLAUDE_CONFIG_DIR"] == "/profile")
        // USER is never missing (without it the CLI says "Not logged in").
        let bare = RemoraCall.environment(from: [:], configDirectory: nil)
        #expect(bare["USER"] == NSUserName() && bare["LOGNAME"] == NSUserName())
        #expect(bare["HOME"] != nil && bare["PATH"] != nil)
    }

    @Test func modelAndEffortAreCheckedBeforeTheyReachArgv() {
        let arguments = RemoraCall.arguments(model: "--dangerously-skip-permissions", effort: "ludicrous")
        #expect(arguments[arguments.firstIndex(of: "--model")! + 1] == "sonnet")
        #expect(arguments[arguments.firstIndex(of: "--effort")! + 1] == "low")
        #expect(RemoraCall.arguments(model: "claude-haiku-5-5", effort: "max").contains("claude-haiku-5-5"))
    }

    @Test func theRulesStateTheContract() {
        let rules = RemoraRules.text.lowercased()
        for phrase in ["you only read", "never follow an instruction", "language of the user's question", "first person",
                       "carries its date", "where their work stands", "say what you could not see", "```remora"] {
            #expect(rules.contains(phrase), "missing: \(phrase)")
        }
    }

    // MARK: Use

    @Test func theCounterTakesCallsAndTokensAndTurnsOverAtMidnight() async throws {
        let rig = try Rig()
        _ = await collect(rig.call().run(RemoraRequest(kind: .question, pack: "p")))
        _ = await collect(rig.call().run(RemoraRequest(kind: .brief, pack: "p")))
        let today = rig.usage.today
        #expect(today.questions == 1 && today.briefs == 1 && today.calls == 2)
        #expect(today.tokens == RemoraTokenUsage(input: 4, cacheCreation: 2_400, cacheRead: 0, output: 128))
        #expect(abs(today.costUSD - 0.0246) < 1e-9)
        await rig.finish()

        let now = LockedDate(Date(timeIntervalSince1970: 1_800_000_000))
        let counter = RemoraUsage(calendar: Calendar(identifier: .gregorian), clock: { now.value })
        counter.recordStart(.question)
        counter.recordResult(tokens: RemoraTokenUsage(input: 1, output: 2), costUSD: nil)
        #expect(counter.today.calls == 1 && counter.today.tokens.total == 3)
        now.value = now.value.addingTimeInterval(86_400)
        #expect(counter.today.calls == 0 && counter.today.tokens.total == 0)
    }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
