import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora

/// The one real-CLI probe of L1a (off unless `LOOM_REAL_REMORA_PROBE` is set; at most two calls per run): Remora's call,
/// whole (supervisor, argv, environment, stream, answer), against the installed `claude` with the isolated probe profile
/// and Haiku. `LOOM_REAL_REMORA_PACK` names the synthetic pack on disk, `LOOM_REAL_REMORA_OUT` the file that receives
/// the numbers (tokens, cost, timings, the model id; never the answer, the pack or any account field). The child also
/// gets `DISABLE_PROMPT_CACHING=1` when `LOOM_REAL_REMORA_NOCACHE` is `1`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOOM_REAL_REMORA_PROBE"] != nil))
struct RemoraRealProbeTests {
    @Test func oneRealHaikuBriefThroughTheWholeCall() async throws {
        let environment = ProcessInfo.processInfo.environment
        let packPath = try #require(environment["LOOM_REAL_REMORA_PACK"])
        let outPath = try #require(environment["LOOM_REAL_REMORA_OUT"])
        let pack = try String(contentsOfFile: packPath, encoding: .utf8)
        let home = NSHomeDirectory()
        let profile = home + "/Library/Application Support/Loom-Dev/probe/claude-config"
        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        var extra: [String: String] = [:]
        if environment["LOOM_REAL_REMORA_NOCACHE"] == "1" { extra["DISABLE_PROMPT_CACHING"] = "1" }
        let usage = RemoraUsage()
        let call = RemoraCall(
            supervisor: supervisor, executable: "/opt/homebrew/bin/claude",
            environment: RemoraCall.environment(from: environment, configDirectory: profile),
            workingDirectory: URL(fileURLWithPath: "/private/tmp/loom-real/L1a/run"), usage: usage,
            questionDeadline: 60, briefDeadline: 120, terminationGrace: 2, additionalEnvironment: extra)
        let clock = ContinuousClock()
        let began = clock.now
        var firstText: Duration?
        var pieces = 0
        var answer: RemoraAnswer?
        var failure: RemoraFailure?
        do {
            for try await event in call.run(RemoraRequest(kind: .brief, model: "haiku", effort: "low", pack: pack)) {
                switch event {
                case .text:
                    pieces += 1
                    if firstText == nil { firstText = clock.now - began }
                case let .finished(done): answer = done
                }
            }
        } catch let error as RemoraFailure { failure = error }
        func seconds(_ duration: Duration?) -> Double? {
            duration.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        }
        var numbers: [String: Any] = [
            "nocache": environment["LOOM_REAL_REMORA_NOCACHE"] == "1", "packChars": pack.count, "textPieces": pieces,
            "firstTextSeconds": seconds(firstText) as Any? ?? NSNull(), "totalSeconds": seconds(clock.now - began) as Any? ?? NSNull(),
        ]
        if let answer {
            numbers["result"] = "answer"
            numbers["model"] = answer.model ?? NSNull()
            numbers["costUSD"] = answer.costUSD ?? NSNull()
            numbers["input"] = answer.usage.input
            numbers["cacheCreation"] = answer.usage.cacheCreation
            numbers["cacheRead"] = answer.usage.cacheRead
            numbers["output"] = answer.usage.output
            numbers["answerChars"] = answer.text.count
            numbers["block"] = answer.block.rawValue
        } else if let failure {
            numbers["result"] = "failure"
            numbers["kind"] = failure.kind.rawValue
            numbers["usage"] = [failure.usage?.input ?? 0, failure.usage?.cacheCreation ?? 0, failure.usage?.cacheRead ?? 0, failure.usage?.output ?? 0]
        }
        try JSONSerialization.data(withJSONObject: numbers, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL(fileURLWithPath: outPath))
        #expect(answer != nil, "no answer: \(String(describing: failure))")
        #expect((await supervisor.shutdown()).succeeded)
    }
}
