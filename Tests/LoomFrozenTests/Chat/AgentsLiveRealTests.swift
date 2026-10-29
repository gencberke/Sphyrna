import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomChatTestRigs

private typealias AgentsRig = AgentsLiveRealShared.AgentsRig
private typealias AgentsRealAnchor = AgentsLiveRealShared.AgentsRealAnchor

/// V23, against the user's real `claude` (Haiku) under the isolated profile: a foreground subagent whose command needs approval
/// (the profile asks before `touch`) gives a request that names the subagent. Runs only when `LOOM_V23_REAL=1`, and only by the
/// exact name of its test. Environment:
///
/// - `LOOM_V23_CLAUDE_CONFIG`: the isolated, logged-in profile (`Loom-Dev/probe/claude-config`);
/// - `LOOM_V23_WORK`: a new, empty work folder under `/private/tmp/loom-real/`, trusted in that profile (the test writes a
///   project `PermissionRequest` hook into its `.claude/settings.json` that appends the hook's payload to `hook-permission.jsonl`
///   there, to see whether the payload carries an agent id; only key names and ids are logged);
/// - `LOOM_V23_DIR`: the evidence folder, where `real-agents.log` collects one line per phase.
///
/// The parent runs in the Chat driver (permission mode `default`, never a bypass); the one card is answered by `allowOnce`.
/// Output holds counts, booleans and key names: no content of a prompt, an answer or a file.
///
/// Release C's real-Claude check adds a second test, by its own exact name, for the foreground case: the same switches, one
/// model turn. `LOOM_V23_WORK` is a new, empty folder for each of them.
@Suite(.serialized, .timeLimit(.minutes(6)),
       .enabled(if: ProcessInfo.processInfo.environment["LOOM_V23_REAL"] == "1"))
struct AgentsLiveRealTests {
    @Test func v23ASubagentsRequestNamesTheSubagentAndTheHubCarriesItsAgentId() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = URL(fileURLWithPath: try #require(env["LOOM_V23_CLAUDE_CONFIG"]), isDirectory: true)
        let work = URL(fileURLWithPath: try #require(env["LOOM_V23_WORK"]), isDirectory: true)
        #expect(work.path.hasPrefix("/private/tmp/loom-real/") && !work.path.hasPrefix(NSHomeDirectory()))
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        try #require(existing.filter { $0 != ".claude" }.isEmpty, "the work folder is not new")
        // The project's own hook sees the permission request next to Loom's: it records the payload.
        let hookLog = work.appendingPathComponent("hook-permission.jsonl")
        let settings = work.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hook = ["hooks": ["PermissionRequest": [["hooks": [["type": "command",
                                                                   "command": "{ /bin/cat; /bin/echo; } >> \(hookLog.path)"]]]]]]
        try JSONSerialization.data(withJSONObject: hook).write(to: settings)

        let rig = try await AgentsRig.make(config: config, work: work)
        let runtime = rig.runtime, supervisor = rig.supervisor
        defer { rig.cleanup() }

        let id = UUID()
        let driver = ChatSessionDriver(sessionID: id, runtime: runtime, rewindStore: nil, readyTimeout: .seconds(30), onMoved: { _, _ in })
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(
            firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "default", model: "haiku")))

        AgentsLiveRealShared.log("model turn 1 of 3: a foreground subagent runs a command that needs approval")
        try await driver.send("Use the Agent tool exactly once, with subagent_type general-purpose, and wait for it. The subagent must run "
            + "exactly this Bash command and nothing else: touch v23-sub.txt . When it is back, reply with the single word: done")
        var request: ChatPendingRequest?
        let asked = await waitUntil(120) {
            request = await driver.liveState().requests.first
            return request != nil
        }
        let card = try #require(request)
        AgentsLiveRealShared.log("request arrived \(asked); kind \(card.kind), tool \(card.request.toolName), agent_id on the request \(card.request.agentID != nil)")
        let agent = try #require(card.agent, "the request names no subagent")
        AgentsLiveRealShared.log("card names the subagent: type \(agent.type ?? "-"), name \(agent.name), has a description \(agent.description?.isEmpty == false)")
        #expect(!agent.id.isEmpty && !agent.name.isEmpty)

        // The hub's request carries the same agent id; the ledger (fed by the hooks) lists a running subagent with that id.
        let state = try #require(await supervisor.events.snapshot().sessions[id])
        let hubAgent = state.pendingRequests.first?.agent
        let ledgerIDs = state.subagents.map(\.id)
        AgentsLiveRealShared.log("hub request agent id equals the request's \(hubAgent?.id == agent.id), hub name \(hubAgent?.name ?? "-"), "
            + "ledger lists \(ledgerIDs.count) subagent(s), the asking one among them \(ledgerIDs.contains(agent.id)) (agent_id = task_id = hook agent_id)")
        #expect(hubAgent?.id == agent.id)
        #expect(ledgerIDs.contains(agent.id))

        // Does the PermissionRequest hook's payload carry an agent id? (The project hook ran next to Loom's.)
        let recorded = await waitUntil(15) { (try? String(contentsOf: hookLog, encoding: .utf8))?.contains("PermissionRequest") == true }
        let payloads = ((try? String(contentsOf: hookLog, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let withAgent = payloads.filter { ($0["agent_id"] as? String)?.isEmpty == false }
        AgentsLiveRealShared.log("PermissionRequest hook payloads recorded \(payloads.count) (seen \(recorded)); key names \(Set(payloads.flatMap(\.keys)).sorted()); "
            + "with agent_id \(withAgent.count); agent_id equals the request's \(withAgent.contains { ($0["agent_id"] as? String) == agent.id })")

        try await driver.answer(requestID: card.requestID, .allowOnce)
        let finished = await waitUntil(150) { await driver.snapshot().isIdle }
        let snapshot = await driver.snapshot()
        let runs = snapshot.model.entries.compactMap { entry -> SubagentRun? in
            if case let .subagent(run) = entry.body { run } else { nil }
        }
        let touched = FileManager.default.fileExists(atPath: work.appendingPathComponent("v23-sub.txt").path)
        AgentsLiveRealShared.log("turn finished \(finished); subagent cards \(runs.count), status \(runs.first.map { "\($0.status)" } ?? "-"), "
            + "agent id on the card equals the request's \(runs.first?.agentID == agent.id), the card kept words of its own \(runs.first?.latestProgress?.isEmpty == false), "
            + "file made by the approved command \(touched)")
        #expect(finished)
        #expect(touched)
        #expect(runs.first?.agentID == agent.id)
        let report = await runtime.shutdown()
        AgentsLiveRealShared.log("shutdown succeeded \(report.succeeded)")
    }
}
