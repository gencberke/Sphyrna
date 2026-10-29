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
    /// Release C's real-Claude check, V23 in the foreground (one Haiku turn; the card is answered by the test, never a bypass).
    /// The prompt asks for a foreground subagent (`run_in_background` false) that first writes one sentence and then runs
    /// `touch`, which the profile asks about. While that card waits: the hub's request carries the subagent's `agent_id`, the
    /// hook ledger lists it, and the subagent's newest words (`SubagentRun.latestProgress` in the driver's model) are not empty.
    /// After the card is allowed, the turn ends and the session is stopped: `SubagentFolderReader` and `AgentCallScan` over the
    /// real folder list the subagent with its type and its description, as done (it ended, and its Agent call has a result).
    /// If the CLI launches the subagent in the background again (the Agent call already has a result, or the ledger says
    /// background), the test fails with that finding and sends nothing more. Output: counts, booleans and key names.
    @Test func v23ForegroundSubagentCarriesItsWordsAndItsAgentIdWhileItsCardWaitsAndItsFolderListsItDone() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = URL(fileURLWithPath: try #require(env["LOOM_V23_CLAUDE_CONFIG"]), isDirectory: true)
        let work = URL(fileURLWithPath: try #require(env["LOOM_V23_WORK"]), isDirectory: true)
        #expect(work.path.hasPrefix("/private/tmp/loom-real/") && !work.path.hasPrefix(NSHomeDirectory()))
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        try #require(existing.filter { $0 != ".claude" }.isEmpty, "the work folder is not new")
        let rig = try await AgentsRig.make(config: config, work: work)
        let runtime = rig.runtime, supervisor = rig.supervisor
        defer { rig.cleanup() }

        let id = UUID()
        let driver = ChatSessionDriver(sessionID: id, runtime: runtime, rewindStore: nil, readyTimeout: .seconds(30), onMoved: { _, _ in })
        try await driver.startNew(projectID: nil, draft: NewSessionLaunch(
            firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: "default", model: "haiku")))

        AgentsLiveRealShared.log("model turn 1 of 1: a foreground subagent writes one sentence, then runs a command that needs approval")
        try await driver.send("Use the Agent tool exactly once, with subagent_type general-purpose and run_in_background set to false, "
            + "so that it runs in the foreground and you wait for it. The subagent must first write one short sentence saying what it is "
            + "about to do, and then run exactly this Bash command and nothing else: touch v23-fg.txt . When it is back, reply with the "
            + "single word: done")
        var request: ChatPendingRequest?
        let asked = await waitUntil(120) {
            request = await driver.liveState().requests.first
            return request != nil
        }
        let card = try #require(request, "no card arrived within 120 s")
        AgentsLiveRealShared.log("request arrived \(asked); kind \(card.kind), tool \(card.request.toolName), agent_id on the request \(card.request.agentID != nil)")
        func subagentRuns() async -> [SubagentRun] {
            await driver.snapshot().model.entries.compactMap { entry -> SubagentRun? in
                if case let .subagent(run) = entry.body { run } else { nil }
            }
        }
        _ = await waitUntil(15) { (await subagentRuns()).isEmpty == false }
        // The ledger is fed by the hooks, a moment behind the stream: it gets the same time to list the asking subagent.
        let askingID = card.agent?.id
        _ = await waitUntil(15) {
            let ledger = await supervisor.events.snapshot().sessions[id]?.subagents ?? []
            return askingID.map { asking in ledger.contains { $0.id == asking } } ?? false
        }
        let state = try #require(await supervisor.events.snapshot().sessions[id])
        let ledger = state.subagents
        let runs = await subagentRuns()
        let callHasResult = runs.first?.result != nil
        AgentsLiveRealShared.log("subagent cards \(runs.count); the Agent call already has a result \(callHasResult); "
            + "ledger lists \(ledger.count), background flags \(ledger.map(\.isBackground))")
        if callHasResult || ledger.contains(where: \.isBackground) {
            let finding = "FINDING: the CLI launched the subagent in the background although the prompt asked for the foreground; "
                + "the check stops here and sends nothing more"
            AgentsLiveRealShared.log(finding)
            Issue.record(Comment(rawValue: finding))
            return
        }
        let agent = try #require(card.agent, "the request names no subagent")
        AgentsLiveRealShared.log("card names the subagent: type \(agent.type ?? "-"), name \(agent.name), has a description \(agent.description?.isEmpty == false)")
        #expect(!agent.id.isEmpty && !agent.name.isEmpty)

        // While the card waits: the hub's request, the ledger, and the subagent's words.
        let hubAgent = state.pendingRequests.first?.agent
        AgentsLiveRealShared.log("hub request agent id equals the request's \(hubAgent?.id == agent.id), ledger lists the asking one \(ledger.map(\.id).contains(agent.id))")
        #expect(hubAgent?.id == agent.id)
        #expect(ledger.map(\.id).contains(agent.id))
        let words = await waitUntil(30) { (await subagentRuns()).first?.latestProgress?.isEmpty == false }
        let wordCount = (await subagentRuns()).first?.latestProgress?.count ?? 0
        let waitingNow = await driver.liveState().requests.first?.requestID == card.requestID
        AgentsLiveRealShared.log("the subagent's newest words are not empty \(words) (\(wordCount) characters); the card still waits \(waitingNow)")
        #expect(waitingNow, "the card went away before the check was done")
        #expect(words, "the subagent card has no words of its own while it works")

        // The card is allowed, the turn ends, and the session is stopped.
        try await driver.answer(requestID: card.requestID, .allowOnce)
        let finished = await waitUntil(150) { await driver.snapshot().isIdle }
        let endRuns = await subagentRuns()
        let touched = FileManager.default.fileExists(atPath: work.appendingPathComponent("v23-fg.txt").path)
        AgentsLiveRealShared.log("turn finished \(finished); subagent cards \(endRuns.count), status \(endRuns.first.map { "\($0.status)" } ?? "-"), "
            + "agent id on the card equals the request's \(endRuns.first?.agentID == agent.id), file made by the approved command \(touched)")
        #expect(finished)
        #expect(touched)
        let conversation = try #require(await driver.liveState().conversationID)
        let report = try await driver.stop()
        AgentsLiveRealShared.log("session stopped, succeeded \(report.succeeded)")

        // The stopped session's list, read as the Agents tab reads it.
        let main = try #require(ClaudeTranscriptLocator.locate(sessionID: conversation, configDirectory: config, workingDirectory: work.path),
                                "the session's transcript was not found")
        let folder = URL(fileURLWithPath: main.path).deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        let entries = SubagentFolderReader.read(folder: folder)
        let unanswered = AgentCallScan.scan(file: main, wanting: Set(entries.compactMap(\.toolUseID))).unanswered
        let entry = entries.first { $0.record.id == agent.id }
        AgentsLiveRealShared.log("folder lists \(entries.count) subagent(s), the asking one among them \(entry != nil); type \(entry?.record.agentType ?? "-"), "
            + "has a description \(entry?.record.description?.isEmpty == false), ended \(entry?.record.endedAt != nil), background \(entry?.record.isBackground ?? false), "
            + "its Agent call has no result \(entry?.toolUseID.map(unanswered.contains) ?? false)")
        let listed = try #require(entry, "the folder does not list the subagent")
        #expect(listed.record.agentType == (agent.type ?? "general-purpose"))
        #expect(listed.record.description?.isEmpty == false)
        #expect(listed.record.endedAt != nil && !listed.record.isBackground)
        #expect(listed.toolUseID != nil && !(listed.toolUseID.map(unanswered.contains) ?? true), "the list would read Interrupted, not Done")
    }
}
