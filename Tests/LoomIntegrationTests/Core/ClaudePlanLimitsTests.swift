import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// The headless `get_usage` exchange against the fake provider (no model, no network, no real Claude).
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ClaudePlanLimitsTests {
    private let now = Date(timeIntervalSince1970: 1_791_374_400) // 2026-10-07T12:00:00Z

    private var fake: String { RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path }

    private struct Rig {
        let root: URL
        let profile: ClaudeProfileLayout
        let fetcher: ClaudePlanLimitsFetcher
        let log: URL
        let pidFile: URL
        let workingDirectory: URL
    }

    private func rig(
        _ mode: String, extra: [String: String] = [:], timeout: TimeInterval = 10, grace: TimeInterval = 0.2,
        explicitProfile: Bool = true, toolchainConfig: String? = nil
    ) throws -> Rig {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-limits-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let profile = ClaudeProfileLayout(
            profileDirectory: explicitProfile ? config : nil, environment: [:], home: root)
        let log = root.appendingPathComponent("request.json")
        let pidFile = root.appendingPathComponent("pid")
        var environment = [
            "PATH": "/usr/bin:/bin", "LOOM_FAKE_USAGE": mode, "LOOM_FAKE_USAGE_LOG": log.path,
            "LOOM_FAKE_PIDFILE": pidFile.path,
        ]
        if let toolchainConfig { environment["CLAUDE_CONFIG_DIR"] = toolchainConfig }
        environment.merge(extra) { $1 }
        let toolchain = ProviderToolchain(
            provider: .claude, executable: fake, capabilities: ProviderCapabilities(version: "fake", help: ""),
            environment: environment)
        let working = root.appendingPathComponent("usage-probe", isDirectory: true)
        let fetcher = ClaudePlanLimitsFetcher(
            toolchain: { toolchain }, profile: profile, workingDirectory: working, timeout: timeout, grace: grace,
            clock: { Date(timeIntervalSince1970: 1_791_374_400) })
        return Rig(root: root, profile: profile, fetcher: fetcher, log: log, pidFile: pidFile, workingDirectory: working)
    }

    private func alive(_ pid: pid_t) -> Bool {
        // A reaped child is gone; a terminated but unreaped one reports as a zombie.
        guard kill(pid, 0) == 0 else { return false }
        return (try? ProcessTable.snapshot().contains { $0.identity.pid == pid && !$0.zombie }) ?? false
    }

    private func childPID(_ rig: Rig) -> pid_t? {
        (try? String(contentsOf: rig.pidFile, encoding: .utf8)).flatMap { pid_t($0) }
    }

    private func waitUntilGone(_ pid: pid_t) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while alive(pid), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return !alive(pid)
    }

    // MARK: Exchange

    @Test func aSuccessfulAnswerGivesBothWindowsAndTheChildGetsTheRightLaunch() async throws {
        let rig = try rig("ok", extra: ["LOOM_FAKE_USAGE_FIVE": "38", "LOOM_FAKE_USAGE_WEEK": "82"])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let limits = try #require(await rig.fetcher.fetch())
        #expect(limits.fiveHour == PlanLimitWindow(usedPercent: 38, resetsAt: Date(timeIntervalSince1970: 1_791_482_400)))
        #expect(limits.weekly?.usedPercent == 82)
        #expect(limits.weekly?.remainingPercent == 18)
        #expect(limits.weekly?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z"))
        #expect(limits.fetchedAt == now)

        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: rig.log)) as? [String: Any])
        // The user's own hooks and MCP servers must not run for an ask, and no session is kept.
        #expect(record["arguments"] as? [String] == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--no-session-persistence",
        ])
        #expect(record["config"] as? String == rig.profile.configDirectory.path)
        #expect(record["cwd"] as? String == realPath(rig.workingDirectory)) // Loom's own folder, not a project
        // The CLI would read the transcripts of the last week for its behavior statistics unless the
        // request says to skip them: it must be told, so a limits ask scans nothing.
        #expect(record["skipBehaviors"] as? Bool == true)
        #expect(record["scansTranscripts"] as? Bool == false)
        let pid = try #require(childPID(rig))
        #expect(await waitUntilGone(pid)) // its input closed and it left
    }

    /// The ask goes to the account sessions use: a login-shell CLAUDE_CONFIG_DIR stays, as sessions
    /// keep it; without one the variable stays unset (the CLI's own default login and folder).
    @Test func theDefaultProfileAsksTheSameAccountSessionsUse() async throws {
        let shell = try rig("ok", explicitProfile: false, toolchainConfig: "/somewhere/else")
        defer { try? FileManager.default.removeItem(at: shell.root) }
        #expect(await shell.fetcher.fetch() != nil)
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: shell.log)) as? [String: Any])
        #expect(record["config"] as? String == "/somewhere/else")

        let plain = try rig("ok", explicitProfile: false)
        defer { try? FileManager.default.removeItem(at: plain.root) }
        #expect(await plain.fetcher.fetch() != nil)
        let unset = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: plain.log)) as? [String: Any])
        #expect(unset["config"] is NSNull)
    }

    @Test func aWeeklyOnlyAnswerGivesTheOneWindow() async throws {
        let rig = try rig("partial")
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let limits = try #require(await rig.fetcher.fetch())
        #expect(limits.fiveHour == nil)
        #expect(limits.weekly != nil)
    }

    @Test func unavailableLimitsAnErrorAndAnExitWithoutAnswerAllGiveNothing() async throws {
        let expected: [String: PlanLimitsFailure.Category] = [
            "unavailable": .notAvailable, "error": .notAvailable, "exit": .endedWithoutAnswer,
        ]
        for mode in ["unavailable", "error", "exit"] {
            let rig = try rig(mode)
            defer { try? FileManager.default.removeItem(at: rig.root) }
            #expect(await rig.fetcher.fetch() == nil, "mode \(mode)")
            #expect(rig.fetcher.lastFailure == PlanLimitsFailure(category: expected[mode]!, at: now), "mode \(mode)")
        }
    }

    @Test func garbageAndOtherAnswersBeforeTheRealOneAreSkipped() async throws {
        let rig = try rig("garbage", extra: ["LOOM_FAKE_USAGE_FIVE": "11"])
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let limits = try #require(await rig.fetcher.fetch())
        #expect(limits.fiveHour?.usedPercent == 11) // not the 99 another request got
    }

    @Test func aChildThatNeverAnswersIsTimedOutAndKilled() async throws {
        let rig = try rig("hang", timeout: 0.6, grace: 0.1)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let began = ContinuousClock.now
        #expect(await rig.fetcher.fetch() == nil)
        #expect(rig.fetcher.lastFailure?.category == .timedOut)
        #expect(ContinuousClock.now - began < .seconds(8))
        let pid = try #require(childPID(rig))
        #expect(await waitUntilGone(pid))
    }

    @Test func aChildThatKeepsRunningAfterItsAnswerIsTerminated() async throws {
        let rig = try rig("stubborn", grace: 0.1)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        #expect(await rig.fetcher.fetch() != nil)
        let pid = try #require(childPID(rig))
        #expect(await waitUntilGone(pid))
    }

    @Test func aMissingToolchainGivesNothing() async {
        let fetcher = ClaudePlanLimitsFetcher(
            toolchain: { throw ProviderToolchainError.executableNotFound(provider: .claude, searched: 0) },
            profile: ClaudeProfileLayout(profileDirectory: nil, environment: [:], home: URL(fileURLWithPath: "/nonexistent")),
            workingDirectory: FileManager.default.temporaryDirectory)
        #expect(fetcher.lastFailure == nil)                   // nothing was asked yet
        #expect(await fetcher.fetch() == nil)
        #expect(fetcher.lastFailure?.category == .noToolchain)
    }

    @Test func aSuccessfulAskClearsTheLastFailure() async throws {
        let status = PlanLimitsStatus()
        let failing = try rig("exit")
        defer { try? FileManager.default.removeItem(at: failing.root) }
        let good = try rig("ok")
        defer { try? FileManager.default.removeItem(at: good.root) }
        func fetcher(of rig: Rig) -> ClaudePlanLimitsFetcher {
            ClaudePlanLimitsFetcher(
                toolchain: rig.fetcher.toolchain, profile: rig.profile, workingDirectory: rig.workingDirectory,
                timeout: 10, grace: 0.2, clock: { Date(timeIntervalSince1970: 1_791_374_400) }, status: status)
        }
        #expect(await fetcher(of: failing).fetch() == nil)
        #expect(status.lastFailure?.category == .endedWithoutAnswer)
        #expect(await fetcher(of: good).fetch() != nil)
        #expect(status.lastFailure == nil)
    }

    @Test func aCancelledFetchStopsTheChild() async throws {
        let rig = try rig("hang", timeout: 30, grace: 0.1)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let task = Task { await rig.fetcher.fetch() }
        let deadline = ContinuousClock.now + .seconds(5)
        while childPID(rig) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let pid = try #require(childPID(rig))
        task.cancel()
        #expect(await task.value == nil)
        #expect(await waitUntilGone(pid))
    }

    // MARK: Wire format

    private func judge(_ json: String, id: String = "r1") -> PlanLimitsLine {
        PlanLimitsWire.interpret(Array(json.utf8), requestID: id)
    }

    private func answer(_ rateLimits: String, flag: String = "") -> String {
        "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"r1\","
            + "\"response\":{\(flag)\"rate_limits\":\(rateLimits),\"account\":{\"email\":\"a@b.c\"}}}}"
    }

    @Test func theRequestIsOneControlRequestLine() throws {
        let data = PlanLimitsWire.request(id: "abc")
        #expect(data.last == 0x0A)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "control_request")
        #expect(object["request_id"] as? String == "abc")
        let body = try #require(object["request"] as? [String: Any])
        #expect(body["subtype"] as? String == "get_usage")
        #expect(body["skip_behaviors"] as? Bool == true)
    }

    @Test func utilizationIsRoundedAndClampedAndResetsMayBeNullOrPlain() {
        let line = answer(#"{"five_hour":{"utilization":37.6,"resets_at":null},"seven_day":{"utilization":140,"resets_at":"2026-10-12T09:00:00Z"},"seven_day_sonnet":{"utilization":5}}"#)
        guard case let .answer(value) = judge(line) else { Issue.record("expected an answer"); return }
        #expect(value.fiveHour == PlanLimitWindow(usedPercent: 38, resetsAt: nil))
        #expect(value.weekly?.usedPercent == 100)
        #expect(value.weekly?.resetsAt == Date(timeIntervalSince1970: 1_791_795_600))
    }

    @Test func modelScopedOnlyAnswerIsNotDiscarded() {
        // Claude Code 2.1.311's get_usage schema names this server-supplied weekly bucket `model_scoped`.
        let line = answer(#"{"model_scoped":[{"display_name":"Fable","utilization":100,"resets_at":"2026-10-12T09:00:00Z"}]}"#)
        guard case let .answer(value) = judge(line) else {
            Issue.record("a reported model-scoped window is a usable limits answer")
            return
        }
        #expect(value.modelWindowsComplete)
        let mapped = ClaudeProbeSource.windows(of: PlanLimits(fiveHour: value.fiveHour, weekly: value.weekly,
                                                              fetchedAt: now, modelWindows: value.modelWindows))
        #expect(mapped.count == 1 && mapped[0].name == "Weekly · Fable" && mapped[0].remainingPercent == 0)
        #expect(mapped[0].id == "display:Fable" && mapped[0].durationMinutes == 10_080)
        #expect(mapped[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z"))
    }

    @Test func oldAndServerNamedBucketsStayDistinctAndMalformedRowsAreSkipped() {
        let line = answer(#"{"seven_day_opus":{"utilization":30},"seven_day_sonnet":{"utilization":40},"model_scoped":[null,{"display_name":"Fable","utilization":80,"resets_at":null},{"display_name":"Fable","utilization":60},{"display_name":"","utilization":10}]}"#)
        guard case let .answer(value) = judge(line) else { Issue.record("expected a limits answer"); return }
        #expect(!value.modelWindowsComplete)
        let mapped = ClaudeProbeSource.windows(of: PlanLimits(fiveHour: nil, weekly: nil, fetchedAt: now,
                                                              modelWindows: value.modelWindows))
        #expect(mapped.map(\.id) == ["seven_day_opus", "seven_day_sonnet", "display:Fable", "display:Fable:2"])
        #expect(mapped.map(\.name) == ["Weekly · Opus", "Weekly · Sonnet", "Weekly · Fable", "Weekly · Fable"])
        #expect(mapped.map(\.remainingPercent) == [70, 60, 20, 40])
    }

    @Test func absentAndOverLimitModelListsAreMarkedPartialWithoutLosingKnownWindows() throws {
        guard case let .answer(absent) = judge(answer(#"{"five_hour":{"utilization":10}}"#)) else {
            Issue.record("expected a limits answer")
            return
        }
        #expect(!absent.modelWindowsComplete && absent.fiveHour?.usedPercent == 10)
        let rows = (0..<40).map { ["display_name": "Model \($0)", "utilization": $0] as [String: Any] }
        let raw = try JSONSerialization.data(withJSONObject: ["model_scoped": rows], options: [.sortedKeys])
        guard case let .answer(capped) = judge(answer(String(decoding: raw, as: UTF8.self))) else {
            Issue.record("expected a model-window answer")
            return
        }
        #expect(capped.modelWindows.count == 32 && !capped.modelWindowsComplete)
        #expect(Set(capped.modelWindows.map(\.id)).count == 32)
    }

    @Test func aBooleanUtilizationIsUnknownRatherThanOnePercent() {
        let line = answer(#"{"five_hour":{"utilization":10},"model_scoped":[{"display_name":"Fable","utilization":true}]}"#)
        guard case let .answer(value) = judge(line) else { Issue.record("expected the valid main window"); return }
        #expect(value.fiveHour?.usedPercent == 10 && value.modelWindows.isEmpty && !value.modelWindowsComplete)
    }

    /// The shape the real CLI answers with (seen on 18 Oct 2026): microsecond fractions and a `+00:00` offset.
    @Test func theRealCliTimestampFormParses() {
        let line = answer(#"{"five_hour":{"utilization":17,"resets_at":"2026-10-18T01:49:59.781671+00:00"},"seven_day":{"utilization":30,"resets_at":"2026-10-21T08:59:59.781692+00:00"}}"#)
        guard case let .answer(value) = judge(line) else { Issue.record("expected an answer"); return }
        let expected = ISO8601DateFormatter().date(from: "2026-10-18T01:50:00Z")!   // 0.2 s past the minute, to the second
        let resets = value.fiveHour?.resetsAt ?? .distantPast
        #expect(abs(resets.timeIntervalSince(expected)) < 0.5)
        #expect(value.weekly?.resetsAt != nil)
    }

    private func initializeAnswer(account: String) -> [UInt8] {
        Array(("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"r1\","
            + "\"response\":{\"account\":\(account)}}}").utf8)
    }

    /// `initialize` lists the aliases with the release each resolves to; the draft's full names come from them.
    @Test func theModelsOfAnInitializeAnswerKeepTheirReleases() throws {
        let line = Array(("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"r1\","
            + "\"response\":{\"models\":[{\"value\":\"default\",\"displayName\":\"Default (recommended)\"},"
            + "{\"value\":\"opus\",\"displayName\":\"Opus\",\"resolvedModel\":\"claude-opus-5-5\","
            + "\"supportedEffortLevels\":[\"low\",\"high\"]},{\"displayName\":\"no value\"}]}}}").utf8)
        let models = try #require(PlanLimitsWire.models(line, requestIDs: ["r1"]))
        #expect(models.map(\.id) == ["default", "opus"])
        #expect(models[1].resolvedModel == "claude-opus-5-5" && models[1].efforts == ["low", "high"] && models[0].isDefault)
        #expect(PlanLimitsWire.models(line, requestIDs: ["other"]) == nil)
        #expect(PlanLimitsWire.models(initializeAnswer(account: "{}"), requestIDs: ["r1"]) == nil)
    }

    /// The real CLI's `initialize` account (Claude Code 2.1.300): the plan is its own words, "Claude Pro".
    @Test func theAccountOfAnInitializeAnswerIsASubscriptionAnApiKeyOrUnknown() {
        func account(_ json: String) -> HarnessAccount? { PlanLimitsWire.account(initializeAnswer(account: json), requestIDs: ["r1"]) }
        #expect(account(#"{"email":"a@example.invalid","subscriptionType":"Claude Pro","organization":"Org","apiProvider":"firstParty"}"#)
                == .subscription(email: "a@example.invalid", plan: "Claude Pro"))
        #expect(account(#"{"subscriptionType":"max"}"#) == .subscription(email: nil, plan: "max"))
        #expect(account(#"{"email":"a@example.invalid","apiProvider":"bedrock"}"#) == .apiKey, "another provider's credentials stand for the login")
        #expect(account(#"{"apiProvider":"vertex"}"#) == .apiKey)
        #expect(account(#"{"apiProvider":"firstParty"}"#) == nil, "nothing usable is unknown, not guessed")
        #expect(account("{}") == nil)
    }

    @Test func otherLinesAndOtherRequestsAreIgnoredAndBadAnswersAreUnavailable() {
        #expect(judge("not json") == .ignored)
        #expect(judge(#"{"type":"system","subtype":"init"}"#) == .ignored)
        #expect(judge(answer(#"{"five_hour":{"utilization":1}}"#), id: "other") == .ignored)
        #expect(judge(#"{"type":"control_response","response":{"subtype":"error","request_id":"r1","error":"no"}}"#) == .unavailable)
        #expect(judge(answer(#"{"five_hour":{"utilization":1}}"#, flag: #""rate_limits_available":false,"#)) == .unavailable)
        #expect(judge(answer("{}")) == .unavailable)
        #expect(judge(answer(#"{"five_hour":null,"seven_day":{"utilization":"x"}}"#)) == .unavailable)
    }
}
