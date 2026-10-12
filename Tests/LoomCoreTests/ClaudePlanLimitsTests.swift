import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore

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
        #expect((object["request"] as? [String: Any])?["subtype"] as? String == "get_usage")
    }

    @Test func utilizationIsRoundedAndClampedAndResetsMayBeNullOrPlain() {
        let line = answer(#"{"five_hour":{"utilization":37.6,"resets_at":null},"seven_day":{"utilization":140,"resets_at":"2026-10-12T09:00:00Z"},"seven_day_sonnet":{"utilization":5}}"#)
        guard case let .answer(value) = judge(line) else { Issue.record("expected an answer"); return }
        #expect(value.fiveHour == PlanLimitWindow(usedPercent: 38, resetsAt: nil))
        #expect(value.weekly?.usedPercent == 100)
        #expect(value.weekly?.resetsAt == Date(timeIntervalSince1970: 1_791_795_600))
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

struct PlanLimitsRuleTests {
    private let now = Date(timeIntervalSince1970: 1_791_374_400)

    private func window(_ used: Int, _ seconds: TimeInterval?) -> PlanLimitWindow {
        PlanLimitWindow(usedPercent: used, resetsAt: seconds.map { now.addingTimeInterval($0) })
    }

    @Test func theBottleneckIsTheLeastRemainingThenTheEarlierResetAndExpiredWindowsAreIgnored() {
        func limits(_ five: PlanLimitWindow?, _ week: PlanLimitWindow?) -> PlanLimits {
            PlanLimits(fiveHour: five, weekly: week, fetchedAt: now)
        }
        #expect(limits(window(38, 3_600), window(82, 86_400)).bottleneck(at: now)?.kind == .weekly)
        #expect(limits(window(90, 3_600), window(82, 86_400)).bottleneck(at: now)?.kind == .fiveHour)
        #expect(limits(window(50, 7_200), window(50, 3_600)).bottleneck(at: now)?.kind == .weekly)
        #expect(limits(window(50, 3_600), window(50, 7_200)).bottleneck(at: now)?.kind == .fiveHour)
        #expect(limits(window(99, -1), window(10, 86_400)).bottleneck(at: now)?.kind == .weekly)
        #expect(limits(window(99, -1), window(10, 0)).bottleneck(at: now) == nil)
        #expect(limits(nil, window(10, nil)).bottleneck(at: now)?.kind == .weekly)
    }
}
