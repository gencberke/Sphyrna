import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora

/// The real-CLI probe of Remora's call (off unless `LOOM_REAL_REMORA_PROBE` is set): the whole call (supervisor, argv,
/// environment, stream, answer) against the installed `claude` with the isolated probe profile, on a synthetic workspace
/// built by Remora's own pack builder. It calls with what Remora ships with (`RemoraPreferences.defaultModel` and
/// `defaultEffort`), so its timings and cost are the product's. One run is a cold brief and then, straight after, a question on the same
/// catalog (what a user's rhythm does), so the second call shows what the cache gives back of the first.
///
/// - `LOOM_REAL_REMORA_MODEL` names another model for both calls (`haiku` for a cheap rerun); the effort stays the product's.
/// - `LOOM_REAL_REMORA_OUT` names the file that receives the numbers (tokens with the cache split, cost, timings, the
///   model id; never the answer, the pack or any account field).
/// - `LOOM_REAL_REMORA_LAYOUT`: `system` (the product's: the stable prefix goes after the rules in a system prompt file,
///   the rest on stdin; the default) or `plain` (the whole pack on stdin: L1c's first probe, which read back only the rules).
/// - `LOOM_REAL_REMORA_TTL` overrides the cache lifetime (Remora's own is `1h`), `LOOM_REAL_REMORA_MESSAGES_TTL` overrides
///   the CLI's undocumented `CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL` (Remora's own is `5m`, which caps the messages' writes
///   while the system prompt keeps its lifetime; any other value lets them follow it) and `LOOM_REAL_REMORA_NOCACHE=1` adds
///   `DISABLE_PROMPT_CACHING=1`: all for the probe only.
/// - `LOOM_REAL_REMORA_CALLS`: `both` (the default: the brief, then a question a minute later), `brief` (stops after the
///   first call) or `later` (those two, then a different question `LOOM_REAL_REMORA_GAP_SECONDS` after the second, 600 by
///   default: the user's case of asking again after a pause, which reads what the 1 h lifetime kept).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOOM_REAL_REMORA_PROBE"] != nil))
struct RemoraRealProbeTests {
    @Test func aColdBriefThenAQuestionOnTheSameCatalogThroughTheWholeCall() async throws {
        let environment = ProcessInfo.processInfo.environment
        let outPath = try #require(environment["LOOM_REAL_REMORA_OUT"])
        let layout = environment["LOOM_REAL_REMORA_LAYOUT"] ?? "system"
        let (model, effort) = Self.modelAndEffort(environment)
        let profile = NSHomeDirectory() + "/Library/Application Support/Loom-Dev/probe/claude-config"
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        var extra: [String: String] = [:]
        if environment["LOOM_REAL_REMORA_NOCACHE"] == "1" { extra["DISABLE_PROMPT_CACHING"] = "1" }
        if let ttl = environment["LOOM_REAL_REMORA_TTL"] { extra["CLAUDE_CODE_PROMPT_CACHE_TTL"] = ttl }
        if let ttl = environment["LOOM_REAL_REMORA_MESSAGES_TTL"] { extra["CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL"] = ttl }
        let call = RemoraCall(
            supervisor: supervisor, executable: "/opt/homebrew/bin/claude",
            environment: RemoraCall.environment(from: environment, configDirectory: profile),
            workingDirectory: URL(fileURLWithPath: "/private/tmp/loom-real/L1c/run"), usage: RemoraUsage(),
            questionDeadline: 90, briefDeadline: 150, terminationGrace: 2, additionalEnvironment: extra)

        let world = try RemoraPackWorld()
        defer { world.remove() }
        try Self.fill(world)
        let builder = world.builder()
        let now = world.base
        func pack(_ request: RemoraPackRequest, at offset: TimeInterval) async throws -> RemoraPack {
            try await builder.build(request, settings: RemoraPackSettings(model: model, effort: effort), today: RemoraUsage().today,
                                    now: now.addingTimeInterval(offset), timeZone: TimeZone(identifier: "Europe/Istanbul")!)
        }
        let brief = try await pack(.brief(since: now.addingTimeInterval(-20 * 3600)), at: 0)
        let question = try await pack(.question("What did I leave open on billing?", scope: .allProjects, previous: nil), at: 60)
        var results: [[String: Any]] = []
        let calls = environment["LOOM_REAL_REMORA_CALLS"] ?? "both"
        var steps = calls == "brief" ? [brief] : [brief, question]
        var gaps: [Duration] = [.zero, .zero]
        if calls == "later" {
            steps.append(try await pack(.question("Which sessions need me today?", scope: .allProjects, previous: nil), at: 60 + 600))
            gaps.append(.seconds(Int(environment["LOOM_REAL_REMORA_GAP_SECONDS"] ?? "") ?? 600))
        }
        for (pack, gap) in zip(steps, gaps) {
            try await Task.sleep(for: gap)
            var request = pack.request(model: model, effort: effort)
            if layout == "plain" { request = RemoraRequest(kind: pack.kind, model: model, effort: effort, pack: pack.text, knownSessionIDs: request.knownSessionIDs) }
            var result = await Self.run(call, request, pack: pack, layout: layout, nocache: extra["DISABLE_PROMPT_CACHING"] != nil,
                                        ttl: extra["CLAUDE_CODE_PROMPT_CACHE_TTL"] ?? "1h")
            result["messagesTTL"] = extra["CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL"] ?? "5m"
            result["requestedModel"] = model
            result["effort"] = effort
            results.append(result)
            try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: outPath))
        }
        for result in results { #expect(result["result"] as? String == "answer", "no answer: \(result)") }
        #expect((await supervisor.shutdown()).succeeded)
        #expect(try FileManager.default.contentsOfDirectory(atPath: "/private/tmp/loom-real/L1c/run").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: "/private/tmp/loom-real/L1c").filter { $0.hasPrefix("system-") }.isEmpty)
    }

    /// The model and effort both calls use: Remora's shipped ones, unless `LOOM_REAL_REMORA_MODEL` names another model.
    static func modelAndEffort(_ environment: [String: String]) -> (model: String, effort: String) {
        let named = environment["LOOM_REAL_REMORA_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (named.isEmpty ? RemoraPreferences.defaultModel : named, RemoraPreferences.defaultEffort)
    }

    private static func run(_ call: RemoraCall, _ request: RemoraRequest, pack: RemoraPack, layout: String, nocache: Bool,
                            ttl: String) async -> [String: Any] {
        let clock = ContinuousClock()
        let began = clock.now
        var firstText: Duration?
        var answer: RemoraAnswer?
        var failure: RemoraFailure?
        do {
            for try await event in call.run(request) {
                switch event {
                case .text: if firstText == nil { firstText = clock.now - began }
                case let .finished(done): answer = done
                }
            }
        } catch let error as RemoraFailure { failure = error } catch { failure = RemoraFailure(kind: .couldNotStart, detail: "\(error)") }
        func seconds(_ duration: Duration?) -> Double? {
            duration.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        }
        var numbers: [String: Any] = [
            "kind": pack.kind == .brief ? "brief" : "question", "layout": layout, "nocache": nocache, "ttl": ttl,
            "packEstimatedTokens": pack.estimatedTokens, "stablePrefixTokens": pack.stablePrefixTokens,
            "stdinTokens": RemoraPack.estimate(request.pack), "systemSuffixTokens": RemoraPack.estimate(request.systemSuffix),
            "firstTextSeconds": seconds(firstText) as Any? ?? NSNull(), "totalSeconds": seconds(clock.now - began) as Any? ?? NSNull(),
        ]
        if let answer {
            numbers["result"] = "answer"
            numbers["model"] = answer.model ?? NSNull()
            numbers["costUSD"] = answer.costUSD ?? NSNull()
            numbers["input"] = answer.usage.input
            numbers["cacheCreation"] = answer.usage.cacheCreation
            numbers["cacheCreation5m"] = answer.usage.cacheCreation5m
            numbers["cacheCreation1h"] = answer.usage.cacheCreation1h
            numbers["cacheRead"] = answer.usage.cacheRead
            numbers["output"] = answer.usage.output
            numbers["answerChars"] = answer.text.count
            numbers["block"] = answer.block.rawValue
        } else if let failure {
            numbers["result"] = "failure"
            numbers["failure"] = failure.kind.rawValue
            numbers["usage"] = [failure.usage?.input ?? 0, failure.usage?.cacheCreation ?? 0, failure.usage?.cacheRead ?? 0, failure.usage?.output ?? 0]
        }
        return numbers
    }

    // MARK: A synthetic workspace

    /// 40 sessions in 4 projects of plain software work (varied, templated text; the first synthetic pack of S10, made of
    /// random nature words, was refused by the model). Nothing here is real.
    private static func fill(_ world: RemoraPackWorld) throws {
        var seed: UInt64 = 0x5EED_1C0F
        func next(_ count: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(count))
        }
        func pick(_ items: [String]) -> String { items[next(items.count)] }
        let projects = ["billing", "search", "mobile-app", "infra"].map { (id: UUID(), name: $0) }
        let areas = ["webhook dispatcher", "invoice export", "retry backoff", "index rebuild", "query planner", "login redirect",
                     "push notifications", "deploy pipeline", "log shipping", "rate limiter", "session cache", "schema migration"]
        let files = ["Sources/Dispatcher.swift", "Sources/InvoiceExport.swift", "Sources/Backoff.swift", "Sources/IndexJob.swift",
                     "Sources/Planner.swift", "Sources/Redirect.swift", "Tests/RetryTests.swift", "ops/deploy.yaml", "ops/shipper.toml"]
        let findings = ["the failure came from a stale cache entry", "two handlers raced on the same row",
                        "the timeout was shorter than the upstream's p99", "the migration ran twice on the replica",
                        "a missing index made the query scan the whole table", "the retry loop never reset its counter",
                        "the config key was renamed but the old one was still read"]
        func turns(_ area: String, project: String) -> [String] {
            var lines: [String] = []
            for turn in 0..<9 {
                lines.append(RemoraPackWorld.user("Turn \(turn): the \(area) in \(project) is misbehaving after the last release; "
                    + "can you look at \(pick(files)) and tell me why \(pick(["it times out", "it drops events", "it returns stale data", "the test is flaky"]))?",
                    promptID: "p-\(turn)"))
                lines.append(RemoraPackWorld.assistant("I read \(pick(files)) and ran the tests. \(pick(findings).capitalized), which explains it. "
                    + "I changed the \(area) so that it \(pick(["checks the version first", "backs off with jitter", "takes the lock before it writes", "logs the failure with the request id"])) "
                    + "and added a test for the \(pick(["empty", "duplicate", "late", "oversized"])) case. The suite passes except one slow test I left alone."))
                lines.append(RemoraPackWorld.assistant(tool: ("Bash", ["command": "swift test --filter \(area.replacingOccurrences(of: " ", with: ""))"])))
                lines.append(RemoraPackWorld.toolResult("Test run finished: \(next(40) + 10) passed, \(next(2)) failed in \(next(9) + 1).\(next(10)) seconds"))
            }
            return lines
        }
        for index in 0..<40 {
            let project = projects[index % 4]
            let area = areas[index % areas.count]
            try world.add(title: "Fix the \(area) (\(project.name) #\(index + 100))", project: project, minutesAgo: Double(index) * 20 + 5,
                          state: index % 5 == 0 ? .working : .idle, lines: turns(area, project: project.name))
        }
    }
}

/// The probe's model needs no real call to check: it runs what Remora ships with unless it is told otherwise.
struct RemoraRealProbeSettingsTests {
    @Test func theProbeCallsWithWhatRemoraShipsUnlessAnotherModelIsNamed() {
        let shipped = RemoraRealProbeTests.modelAndEffort([:])
        #expect(shipped.model == RemoraPreferences.defaultModel && shipped.effort == RemoraPreferences.defaultEffort)
        #expect(RemoraRealProbeTests.modelAndEffort(["LOOM_REAL_REMORA_MODEL": " "]).model == RemoraPreferences.defaultModel)
        let cheap = RemoraRealProbeTests.modelAndEffort(["LOOM_REAL_REMORA_MODEL": "haiku"])
        #expect(cheap.model == "haiku" && cheap.effort == RemoraPreferences.defaultEffort)
    }
}
