import Foundation
import Synchronization
import Testing
@testable import LoomCore

/// The Codex probe against the fake provider's `app-server` (no real Codex, no network), the probe's cache and the connect
/// switch, and Claude's side in the same neutral types.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct HarnessProbeTests {
    // MARK: Rigs

    private func source(
        _ context: RuntimeContext, mode: String = "ok", timeout: TimeInterval = 10, executable: String? = nil
    ) -> CodexProbeSource {
        let toolchain = ProviderToolchain(
            provider: .codex,
            executable: executable ?? RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path,
            capabilities: ProviderCapabilities(version: "fake", help: "--remote <ADDR>", serverHelp: "--listen <URL>"),
            environment: ["PATH": "/usr/bin:/bin", "HOME": context.home.path, "LOOM_FAKE_STATE": context.state.path,
                          "LOOM_FAKE_CODEX_PROBE": mode],
            profileDirectory: context.profile)
        return CodexProbeSource(
            supervisor: context.supervisor, toolchain: { toolchain }, workingDirectory: context.home.path,
            socketDirectory: context.socketDirectory, clientVersion: "test", timeout: timeout)
    }

    private func methods(_ context: RuntimeContext) -> [String] {
        ((try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// The sockets in the runtime's socket directory. A started runtime keeps its own there (the task channel's since 1.8.0),
    /// so an ask is judged by what it adds: nothing may outlive it.
    private func sockets(_ context: RuntimeContext) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: context.socketDirectory.path)) ?? []).filter { $0.hasSuffix(".sock") })
    }

    // MARK: Codex

    @Test func probeCleanupPreservesAPathItNeverOwned() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true)
        let socket = context.socketDirectory.appendingPathComponent("occupied.sock")
        try "foreign sentinel".write(to: socket, atomically: true, encoding: .utf8)
        let manager = CodexAppServerManager(supervisor: context.supervisor, configuration: .init(
            executable: RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path,
            capabilities: .init(version: "fake", help: "--remote <ADDR>", serverHelp: "--listen <URL>"),
            home: context.profile, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": context.home.path],
            workingDirectory: context.home.path, socketPath: socket.path, clientVersion: "test"))
        let run = ProbeRun()
        await run.keep(manager: manager)
        await #expect(throws: (any Error).self) { _ = try await manager.start() }
        await run.close(using: context.supervisor)
        #expect(try String(contentsOf: socket, encoding: .utf8) == "foreign sentinel")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func probeReportsWhenItsSocketWasReplacedBeforeCleanup() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let socket = context.socketDirectory.appendingPathComponent("probe.sock")
        let manager = CodexAppServerManager(supervisor: context.supervisor, configuration: .init(
            executable: RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path,
            capabilities: .init(version: "fake", help: "--remote <ADDR>", serverHelp: "--listen <URL>"),
            home: context.profile, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": context.home.path],
            workingDirectory: context.home.path, socketPath: socket.path, clientVersion: "test"))
        _ = try await manager.start()
        try FileManager.default.removeItem(at: socket)
        try "foreign replacement".write(to: socket, atomically: true, encoding: .utf8)
        let run = ProbeRun()
        await run.keep(manager: manager)
        let since = Date()
        await run.close(using: context.supervisor)
        let lines = try await LogReadBack.lines(category: .usage, since: since,
            containing: "The Codex probe's server could not be fully stopped", seconds: 3)
        #expect(!lines.isEmpty)
        #expect(try String(contentsOf: socket, encoding: .utf8) == "foreign replacement")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func allFiveAnswersAreReadAndTheServerAskedOnlyToRead() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let before = sockets(context)
        let answer = try #require(await source(context).read())

        #expect(answer.version == "0.0.1")
        #expect(answer.account == .subscription(email: "probe@example.invalid", plan: "pro"))
        let windows = try #require(answer.windows)
        #expect(windows.map(\.id) == ["codex.primary", "codex.secondary", "codex_spark.primary"], "the codex bucket first, primary before secondary")
        #expect(windows.map(\.name) == ["5-hour", "Weekly", "Spark 5-hour"])
        #expect(windows.map(\.usedPercent) == [23, 61, 5])
        #expect(windows.map(\.durationMinutes) == [300, 10_080, 300])
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_791_482_400))
        #expect(answer.lifetimeTokens == 123_456_789)
        #expect(answer.tokenDays == [HarnessTokenDay(day: "2026-10-23", tokens: 1_200), HarnessTokenDay(day: "2026-10-24", tokens: 3_400)])
        #expect(answer.models == [
            HarnessModel(id: "fake-codex-alpha", displayName: "Fake Codex Alpha", isDefault: true, efforts: ["low", "medium", "high"],
                         defaultEffort: "medium"),
            HarnessModel(id: "fake-codex-beta", displayName: "Fake Codex Beta", isDefault: false, efforts: ["low", "medium", "high"],
                         defaultEffort: "medium"),
        ], "the hidden model is dropped; the fixture's empty description is none")

        // Never a thread, never a turn: the connection made exactly the handshake and the four reads.
        #expect(methods(context) == ["initialize", "initialized", "account/read", "account/rateLimits/read", "account/usage/read", "model/list"])
        // And nothing is left: no run, no socket file of its own.
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(sockets(context) == before, "left: \(sockets(context).subtracting(before))")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aPagedModelListIsFollowedAndASignedOutOrApiKeyAccountIsNamed() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let paged = try #require(await source(context, mode: "paged").read())
        #expect(paged.models?.map(\.id) == ["fake-codex-alpha", "fake-codex-beta"])
        #expect(try #require(await source(context, mode: "signed-out").read()).account == HarnessAccount.none)
        #expect(try #require(await source(context, mode: "api-key").read()).account == .apiKey)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aReadThatFailsLeavesOnlyItsOwnPartUnread() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let answer = try #require(await source(context, mode: "limits-error").read())
        #expect(answer.windows == nil, "not empty: not read, so the probe keeps the last good ones")
        #expect(answer.account != nil && answer.tokenDays?.count == 2 && answer.models?.count == 2)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aServerThatNeverAnswersTimesOutAndEverythingIsReaped() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let before = sockets(context)
        let start = ProcessInfo.processInfo.systemUptime
        let timedOut = await source(context, mode: "hang", timeout: 1.5).ask()
        #expect(timedOut.answer == nil && timedOut.failure?.category == .timedOut, "the reason is the timeout, not an empty answer")
        #expect(ProcessInfo.processInfo.systemUptime - start < 8, "the ask is bounded by its timeout, not by the request's")
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(sockets(context) == before, "left: \(sockets(context).subtracting(before))")
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aTimeoutInARunScopeReleasesTheScope() async throws {
        let context = try await SessionRuntimeTests.makeContext(scoped: true)
        defer { context.cleanup() }
        let copy = context.root.appendingPathComponent("bin/loom-fake-provider").path
        let opened = await context.supervisor.scopesOpened
        let before = sockets(context)
        #expect(await source(context, mode: "hang", timeout: 3, executable: copy).read() == nil)
        #expect(await context.supervisor.scopesOpened == opened + 1, "the probe ran in a scope of its own")
        #expect(await context.supervisor.liveScopes.isEmpty, "and the scope is released")
        #expect(await context.supervisor.runningSessionIDs().isEmpty)
        #expect(sockets(context) == before, "left: \(sockets(context).subtracting(before))")
        // A good ask in a scope reads the same answer and releases the scope too.
        #expect(await source(context, executable: copy).read()?.models?.count == 2)
        #expect(await context.supervisor.liveScopes.isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func aMissingToolchainGivesNothing() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let missing = CodexProbeSource(
            supervisor: context.supervisor,
            toolchain: { throw ProviderToolchainError.executableNotFound(provider: .codex, searched: 0) },
            workingDirectory: context.home.path, socketDirectory: context.socketDirectory, clientVersion: "test")
        let none = await missing.ask()
        #expect(none.answer == nil && none.failure?.category == .noToolchain)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func effortLevelsAreCheckedByShapeAndTheDefaultAndDescriptionAreKeptWhenTheyHaveOne() {
        // A level by shape (a newer CLI's level passes, a malformed one is dropped); a default that is not a level is none.
        #expect(HarnessEffort.isToken("low") && HarnessEffort.isToken("x-high") && HarnessEffort.isToken("level2"))
        #expect(!HarnessEffort.isToken("") && !HarnessEffort.isToken("High") && !HarnessEffort.isToken("2fast") && !HarnessEffort.isToken("a b"))
        #expect(!HarnessEffort.isToken(String(repeating: "a", count: 33)) && HarnessEffort.isToken(String(repeating: "a", count: 32)))
        let listed: [JSONValue] = [
            ["model": "m-a", "displayName": "", "description": "Fast", "defaultReasoningEffort": "Medium",
             "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "Not Valid"], ["reasoningEffort": "x-high"]]],
            ["model": "m-b", "description": "", "defaultReasoningEffort": "high", "supportedReasoningEfforts": []],
        ]
        #expect(CodexProbeSource.models(from: listed) == [
            HarnessModel(id: "m-a", displayName: "m-a", isDefault: false, efforts: ["low", "x-high"], description: "Fast"),
            HarnessModel(id: "m-b", displayName: "m-b", isDefault: false, efforts: [], defaultEffort: "high"),
        ])
    }

    @Test func theAnswersAreReadFromTheirWireShapes() {
        #expect(CodexProbeSource.version(fromUserAgent: "codex_cli_rs/0.160.0 (Mac OS 26.0; arm64) Terminal") == "0.160.0")
        #expect(CodexProbeSource.version(fromUserAgent: "no version") == nil)
        let bedrock: JSONValue = ["account": ["type": "amazonBedrock", "usesCodexManagedCredentials": true]]
        #expect(CodexProbeSource.account(from: bedrock) == .apiKey)
        #expect(CodexProbeSource.account(from: ["account": ["type": "somethingNew"]]) == nil, "an account of an unknown type is unknown")
        #expect(CodexProbeSource.account(from: ["requiresOpenaiAuth": true]) == nil)
        // The single-bucket view, an absurd percent and a reset in milliseconds.
        let single: JSONValue = ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 140, "windowDurationMins": 45, "resetsAt": 1_791_482_400_000],
                                                "secondary": ["usedPercent": 3]]]
        let windows = CodexProbeSource.windows(from: single)
        #expect(windows?.map(\.usedPercent) == [100, 3])
        #expect(windows?.map(\.name) == ["45-minute", "Secondary"])
        #expect(windows?[0].resetsAt == Date(timeIntervalSince1970: 1_791_482_400))
        #expect(windows?[1].resetsAt == nil && windows?[1].durationMinutes == nil)
        #expect(CodexProbeSource.windows(from: ["unrelated": true]) == nil)
    }

    // MARK: The model catalog

    @MainActor @Test func theCatalogTakesCodexsModelsFromAProbeAndFallsBackBeforeOne() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let connections = HarnessConnections()
        let catalog = ModelCatalog(connections: connections)
        #expect(catalog.models(for: .codex) == ModelCatalog.codexFallback, "no probe has answered: today's names")

        let probe = HarnessProbe(connections: connections, sources: [.codex: source(context)])
        let reading = try #require(await probe.probe(harness: .codex))
        catalog.apply(reading)
        #expect(catalog.models(for: .codex).map(\.title) == ["Fake Codex Alpha", "Fake Codex Beta"], "hidden models are not offered")
        #expect(catalog.models(for: .codex).map(\.note) == ["Default", nil])
        // Each Codex model carries its own levels and default, from the CLI, and the harness that offers it.
        #expect(catalog.models(for: .codex).map(\.efforts) == [["low", "medium", "high"], ["low", "medium", "high"]])
        #expect(catalog.models(for: .codex).map(\.defaultEffort) == ["medium", "medium"])
        #expect(catalog.models(for: .codex).allSatisfy { $0.harness == .codex })
        #expect(catalog.validationModels(for: .codex).first?.isDefault == true)

        // A reading with no models (their ask failed) leaves the list; Claude's reading changes Claude's list only.
        catalog.apply(HarnessReading(provider: .codex, readAt: Date()))
        #expect(catalog.models(for: .claude) == ModelCatalog.claude, "before a Claude reading: the fixed three")
        catalog.apply(HarnessReading(provider: .claude, models: [HarnessModel(id: "x", displayName: "X", isDefault: false,
                                                                              efforts: ["low", "high"])], readAt: Date()))
        #expect(catalog.models(for: .codex).count == 2 && catalog.models(for: .claude).map(\.title) == ["X"])
        #expect(catalog.models(for: .claude).first?.efforts == ["low", "high"] && catalog.models(for: .claude).first?.harness == .claude)

        catalog.apply(HarnessReading(provider: .claude, models: [
            HarnessModel(id: "default", displayName: "Default", isDefault: true, efforts: ["low"]),
            HarnessModel(id: "opus", displayName: "Opus", isDefault: false, efforts: ["low", "high"]),
        ], readAt: Date()))
        #expect(catalog.models(for: .claude).map(\.id) == ["opus"], "the alias stays out of the picker")
        #expect(catalog.validationModels(for: .claude).first(where: \.isDefault)?.efforts == ["low"])

        connections.setConnected(.codex, false)
        #expect(catalog.models(for: .codex).isEmpty, "a switched-off harness offers no models")
        connections.setConnected(.codex, true)
        #expect(catalog.models(for: .synthetic).isEmpty)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    // MARK: The account stays in memory

    @Test func anAccountPrintsWithoutItsEmailAndHasNoCodableForm() {
        let account = HarnessAccount.subscription(email: "private@example.invalid", plan: "max")
        let reading = HarnessReading(provider: .codex, account: account, readAt: Date(timeIntervalSince1970: 0))
        for text in [String(describing: account), String(reflecting: account), String(describing: reading),
                     String(reflecting: reading), { var out = ""; dump(reading, to: &out); return out }()] {
            #expect(!text.contains("private@example"), "the email is not in \(text.prefix(40))")
        }
        #expect(!(account is any Encodable))
    }

    // MARK: The cache with a floor

    private final class Script: HarnessProbeSource, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [HarnessProbeAnswer?]
        private(set) var asks = 0
        var delay: Duration = .zero

        init(_ answers: [HarnessProbeAnswer?]) { self.answers = answers }

        func read() async -> HarnessProbeAnswer? {
            let next: HarnessProbeAnswer? = lock.withLock {
                asks += 1
                return answers.isEmpty ? nil : answers.removeFirst()
            }
            if delay > .zero { try? await Task.sleep(for: delay) }
            return next
        }
    }

    private final class Clock: @unchecked Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private func window(_ id: String, _ percent: Int) -> HarnessLimitWindow {
        HarnessLimitWindow(id: id, name: id, durationMinutes: 300, usedPercent: percent, resetsAt: nil)
    }

    private func answer(_ percent: Int, account: HarnessAccount? = .subscription(email: "a@example.invalid", plan: "pro")) -> HarnessProbeAnswer {
        HarnessProbeAnswer(account: account, windows: [window("w", percent)])
    }

    @Test func anAnswerStandsForFiveMinutesUnlessForced() async throws {
        let clock = Clock()
        let script = Script([answer(10), answer(20), answer(30)])
        let probe = HarnessProbe(connections: HarnessConnections(), sources: [.codex: script], clock: { clock.now })

        #expect(await probe.probe(harness: .codex)?.windows.first?.usedPercent == 10)
        clock.advance(299)
        #expect(await probe.probe(harness: .codex)?.windows.first?.usedPercent == 10, "inside the floor: the last answer, no ask")
        #expect(script.asks == 1)
        #expect(await probe.probe(harness: .codex, force: true)?.windows.first?.usedPercent == 20, "forced: asked again")
        clock.advance(301)
        #expect(await probe.probe(harness: .codex)?.windows.first?.usedPercent == 30, "past the floor: asked again")
        #expect(script.asks == 3)
    }

    @Test func aFailedAskKeepsTheLastGoodWindowsUnlessTheAccountChanged() async throws {
        let clock = Clock()
        let other = HarnessAccount.subscription(email: "b@example.invalid", plan: "plus")
        // 1 good; 2 failed outright; 3 account read but limits not (same account); 4 another account, limits not read.
        let script = Script([answer(10), nil, HarnessProbeAnswer(account: .subscription(email: "a@example.invalid", plan: "pro")),
                             HarnessProbeAnswer(account: other, tokenDays: [])])
        let probe = HarnessProbe(connections: HarnessConnections(), sources: [.codex: script], clock: { clock.now })
        _ = await probe.probe(harness: .codex)

        #expect(await probe.probe(harness: .codex, force: true)?.windows.map(\.usedPercent) == [10], "a failed ask keeps what was read")
        #expect(await probe.probe(harness: .codex, force: true)?.windows.map(\.usedPercent) == [10], "same account, windows unread: kept")
        let changed = await probe.probe(harness: .codex, force: true)
        #expect(changed?.account == other)
        #expect(changed?.windows == [], "another account's numbers are not these")
    }

    @Test func aFailedFirstAskIsNotAskedAgainInsideTheFloor() async {
        let clock = Clock()
        let script = Script([nil, answer(5)])
        let probe = HarnessProbe(connections: HarnessConnections(), sources: [.codex: script], clock: { clock.now })
        #expect(await probe.probe(harness: .codex) == nil)
        #expect(await probe.probe(harness: .codex) == nil)
        #expect(script.asks == 1, "a broken CLI is not started again and again")
        #expect(await probe.probe(harness: .codex, force: true)?.windows.first?.usedPercent == 5)
    }

    /// A probe source that answers each ask with the next scripted `HarnessProbeAsk`, the last one for ever; counts its asks.
    private final class Asks: HarnessProbeSource, @unchecked Sendable {
        private let lock = NSLock()
        private var scripted: [HarnessProbeAsk]
        private(set) var count = 0

        init(_ scripted: [HarnessProbeAsk]) { self.scripted = scripted }

        func read() async -> HarnessProbeAnswer? { await ask().answer }

        func ask() async -> HarnessProbeAsk {
            lock.withLock {
                count += 1
                return scripted.count > 1 ? scripted.removeFirst() : (scripted.first ?? HarnessProbeAsk())
            }
        }
    }

    private static func kind(_ outcome: HarnessProbeOutcome) -> String {
        switch outcome {
        case .answered: "answered"
        case .failed: "failed"
        case .cached: "cached"
        case .notAsked: "notAsked"
        }
    }

    @Test func theOutcomeSaysWhatWasAskedWhyAnAskFailedAndWhatItKept() async {
        let clock = Clock()
        let connections = HarnessConnections()
        let source = Asks([HarnessProbeAsk(answer: answer(10)),
                           HarnessProbeAsk(failure: PlanLimitsFailure(category: .timedOut, at: clock.now)),
                           HarnessProbeAsk(answer: answer(30))])
        let probe = HarnessProbe(connections: connections, sources: [.codex: source], clock: { clock.now })

        #expect(Self.kind(await probe.ask(harness: .codex)) == "answered")
        clock.advance(301)
        let failed = await probe.ask(harness: .codex)
        #expect(Self.kind(failed) == "failed" && failed.failure?.category == .timedOut, "the reason of the failed ask")
        #expect(failed.reading?.windows.first?.usedPercent == 10, "the last good windows stay")
        clock.advance(10)
        let within = await probe.ask(harness: .codex)
        #expect(Self.kind(within) == "failed" && within.failure?.category == .timedOut, "inside the floor the failure stands")
        #expect(source.count == 2, "and nothing is asked again inside the floor")
        clock.advance(300)
        #expect(Self.kind(await probe.ask(harness: .codex)) == "answered", "past the floor: asked again")
        #expect(Self.kind(await probe.ask(harness: .codex)) == "cached", "a new answer inside the floor is cached")
        #expect(source.count == 3)
        connections.setConnected(.codex, false)
        #expect(Self.kind(await probe.ask(harness: .codex, force: true)) == "notAsked", "switched off: not asked")
        #expect(source.count == 3)
    }

    @Test func aSwitchedOffHarnessIsNeverAskedAndItsReadingIsDropped() async {
        let connections = HarnessConnections()
        let script = Script([answer(10), answer(20)])
        let probe = HarnessProbe(connections: connections, sources: [.codex: script])
        #expect(await probe.probe(harness: .codex) != nil)
        connections.setConnected(.codex, false)
        #expect(await probe.probe(harness: .codex) == nil)
        #expect(await probe.probe(harness: .codex, force: true) == nil)
        #expect(await probe.lastReading(of: .codex) == nil)
        #expect(script.asks == 1)
        connections.setConnected(.codex, true)
        #expect(await probe.probe(harness: .codex)?.windows.first?.usedPercent == 20, "switched on again: a fresh ask, not the dropped reading")
        // A harness with no source, and a provider that is no harness, are not asked either.
        #expect(await probe.probe(harness: .claude) == nil)
        #expect(await probe.probe(harness: .synthetic) == nil)
    }

    @Test func askersOfOneHarnessShareOneRun() async {
        let script = Script([answer(10), answer(99)])
        script.delay = .milliseconds(200)
        let probe = HarnessProbe(connections: HarnessConnections(), sources: [.codex: script])
        async let first = probe.probe(harness: .codex)
        async let second = probe.probe(harness: .codex, force: true)
        let readings = await [first, second]
        #expect(script.asks == 1)
        #expect(readings[0] == readings[1] && readings[0]?.windows.first?.usedPercent == 10)
    }

    @Test func switchingOffWhileAnAskRunsKeepsNothing() async {
        let connections = HarnessConnections()
        let script = Script([answer(10)])
        script.delay = .milliseconds(200)
        let probe = HarnessProbe(connections: connections, sources: [.codex: script])
        async let reading = probe.probe(harness: .codex)
        try? await Task.sleep(for: .milliseconds(50))
        connections.setConnected(.codex, false)
        #expect(await reading == nil)
        connections.setConnected(.codex, true)
        #expect(await probe.lastReading(of: .codex) == nil)
    }

    // MARK: The connect switch

    @Test func theSwitchIsOnByDefaultTellsItsOwnerAndOffersNoSyntheticHarness() {
        let seen = Mutex<[String]>([])
        let connections = HarnessConnections { provider, on in seen.withLock { $0.append("\(provider.rawValue):\(on)") } }
        #expect(connections.isConnected(.claude) && connections.isConnected(.codex))
        #expect(!connections.isConnected(.synthetic))
        connections.setConnected(.codex, false)
        connections.setConnected(.codex, false)
        connections.setConnected(.synthetic, false)
        #expect(!connections.isConnected(.codex) && connections.isConnected(.claude))
        connections.setConnected(.codex, true)
        #expect(seen.withLock { $0 } == ["codex:false", "codex:true"], "each real change is told once")
        #expect(!HarnessConnections(disconnected: [.claude, .synthetic]).isConnected(.claude))
    }

    // MARK: Claude in the same types

    private func claudeFetcher(mode: String, grace: TimeInterval = 0.2) throws -> (ClaudePlanLimitsFetcher, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-probe-claude-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("request.json")
        let toolchain = ProviderToolchain(
            provider: .claude, executable: RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider").path,
            capabilities: ProviderCapabilities(version: "fake", help: ""),
            environment: ["PATH": "/usr/bin:/bin", "LOOM_FAKE_USAGE": mode, "LOOM_FAKE_USAGE_LOG": log.path])
        return (ClaudePlanLimitsFetcher(
            toolchain: { toolchain }, profile: ClaudeProfileLayout(profileDirectory: config, environment: [:], home: root),
            workingDirectory: root.appendingPathComponent("usage-probe", isDirectory: true), timeout: 10, grace: grace,
            clock: { Date(timeIntervalSince1970: 1_791_374_400) }), root)
    }

    @Test func claudeIsReadInTheSameTypesWithItsAccountBesideTheWindows() async throws {
        let (fetcher, root) = try claudeFetcher(mode: "ok")
        defer { try? FileManager.default.removeItem(at: root) }
        let reading = await fetcher.fetchReading()
        #expect(reading.account == .subscription(email: "someone@example.invalid", plan: "Claude Max"))
        #expect(reading.limits?.weekly?.usedPercent == 82)
        // The exchange sent `initialize` before `get_usage`.
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("request.json"))) as? [String: Any])
        #expect(record["initialized"] as? Bool == true)

        let answer = try #require(await ClaudeProbeSource(fetcher: fetcher).read())
        #expect(answer.windows == [
            HarnessLimitWindow(id: "five_hour", name: "5-hour", durationMinutes: 300, usedPercent: 38,
                               resetsAt: Date(timeIntervalSince1970: 1_791_482_400)),
            HarnessLimitWindow(id: "seven_day", name: "Weekly", durationMinutes: 10_080, usedPercent: 82,
                               resetsAt: ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z")),
            HarnessLimitWindow(id: "seven_day_opus", name: "Weekly · Opus", durationMinutes: 10_080,
                               usedPercent: 5, resetsAt: nil),
        ])
        #expect(!answer.windowsComplete, "the legacy fixture reports Opus but no model_scoped coverage")
        #expect(answer.account == .subscription(email: "someone@example.invalid", plan: "Claude Max"))
        #expect(answer.tokenDays == nil && answer.models == nil, "the usage index and the model catalog own those for Claude")
        // Through the probe: the reading holds them in memory beside the windows.
        let probe = HarnessProbe(connections: HarnessConnections(), sources: [.claude: ClaudeProbeSource(fetcher: fetcher)])
        let kept = await probe.probe(harness: .claude)
        #expect(kept?.account == .subscription(email: "someone@example.invalid", plan: "Claude Max") && kept?.windows == answer.windows)
        #expect(kept?.windowsComplete == false)
    }

    @Test func claudeWhoseLimitsAreUnavailableStillNamesTheAccountAndKeepsNoWindows() async throws {
        let (fetcher, root) = try claudeFetcher(mode: "unavailable")
        defer { try? FileManager.default.removeItem(at: root) }
        let reading = await fetcher.fetchReading()
        #expect(reading.limits == nil)
        #expect(reading.account == .subscription(email: "someone@example.invalid", plan: "Claude Max"))
        let answer = try #require(await ClaudeProbeSource(fetcher: fetcher).read())
        #expect(answer.windows == nil, "unread, not empty: the last good windows stay")
    }

    @Test func anInitializeThatIsNeverAnsweredCostsOnlyAShortWait() async throws {
        let (fetcher, root) = try claudeFetcher(mode: "no-account")
        defer { try? FileManager.default.removeItem(at: root) }
        let start = ProcessInfo.processInfo.systemUptime
        let reading = await fetcher.fetchReading()
        #expect(reading.limits?.fiveHour?.usedPercent == 38)
        // The account then comes from the `get_usage` answer, which names the email only.
        #expect(reading.account == .subscription(email: "someone@example.invalid", plan: nil))
        #expect(ProcessInfo.processInfo.systemUptime - start < 6)
    }
}
