import Foundation
import LoomCore
import Testing
@testable import LoomChat

// V23, Agents live, on the chat side: the hub's agent field, which Agent calls of a transcript have a result (a stopped
// session's "Interrupted"), and the newest words of a running subagent.

struct AgentCallScanTests {
    private struct Tree {
        let root: URL
        var url: URL { root.appendingPathComponent("projects/-tmp-work/sess1.jsonl") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-agentscan-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/-tmp-work"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func write(_ lines: [String]) throws -> ClaudeTranscriptFile {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return try #require(ClaudeTranscriptLocator.locate(sessionID: "sess1", configDirectory: root))
        }
    }

    private static func call(_ id: String, _ name: String = "Agent", sidechain: Bool = false) -> String {
        Fixture.line(["type": "assistant", "uuid": .string("a-" + id), "sessionId": "sess1", "isSidechain": .bool(sidechain),
                      "message": ["id": .string("m-" + id), "role": "assistant", "model": "claude-opus-5-5",
                                  "content": [Fixture.toolUse(id, name, ["description": "d", "subagent_type": "Explore", "prompt": "p"])]]])
    }

    private static func result(_ id: String, sidechain: Bool = false) -> String {
        Fixture.line(["type": "user", "uuid": .string("r-" + id), "sessionId": "sess1", "isSidechain": .bool(sidechain),
                      "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": "ok"]]]])
    }

    @Test func aCallWithoutAResultIsUnansweredAndOneWithAResultIsNot() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let file = try tree.write([
            Self.call("toolu_done"), Self.result("toolu_done"),
            Self.call("toolu_cut"),
            Self.call("toolu_task", "Task"), Self.result("toolu_task"),
            Self.call("toolu_unrelated", "Bash"),
        ])
        let outcome = AgentCallScan.scan(file: file, wanting: ["toolu_done", "toolu_cut", "toolu_task", "toolu_unrelated", "toolu_gone"])
        // The join is the id; a call of another tool, and an id the transcript never names, are not Agent calls found.
        #expect(outcome.calls == ["toolu_done", "toolu_cut", "toolu_task"])
        #expect(outcome.unanswered == ["toolu_cut"])
    }

    @Test func aSubagentsOwnRecordsAreNotTheMainSessionsCallsOrResults() throws {
        let tree = try Tree()
        defer { tree.remove() }
        // A result written on a subagent's thread does not answer the main thread's call.
        let file = try tree.write([Self.call("toolu_a"), Self.result("toolu_a", sidechain: true), Self.call("toolu_b", sidechain: true)])
        let outcome = AgentCallScan.scan(file: file, wanting: ["toolu_a", "toolu_b"])
        #expect(outcome.calls == ["toolu_a"] && outcome.unanswered == ["toolu_a"])
    }

    @Test func theReadStopsAtTheByteBoundAndAnOlderCallIsNotJudged() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let filler = (0..<200).map { _ in Fixture.line(["type": "system", "subtype": "x", "padding": .string(String(repeating: "p", count: 400))]) }
        // The old call lies before 200 lines of filler; the read covers only the tail.
        let file = try tree.write([Self.call("toolu_old")] + filler + [Self.call("toolu_new"), Self.result("toolu_new")])
        let bounded = AgentCallScan.scan(file: file, wanting: ["toolu_old", "toolu_new"], byteLimit: 10_000, pageBytes: 4_000)
        #expect(bounded.calls == ["toolu_new"] && bounded.unanswered.isEmpty)
        let whole = AgentCallScan.scan(file: file, wanting: ["toolu_old", "toolu_new"])
        #expect(whole.calls == ["toolu_old", "toolu_new"] && whole.unanswered == ["toolu_old"])
        // Nothing wanted, nothing read.
        #expect(AgentCallScan.scan(file: file, wanting: []) == AgentCallScan.Result())
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(4)))
struct HubAgentFieldTests {
    private func waiting(_ driver: ChatSessionDriver) async -> Bool {
        await waitUntil {
            let snapshot = await driver.snapshot()
            return snapshot.requests.count == 1 && snapshot.phase == .needsYou
        }
    }

    /// A subagent's request reaches the hub with its `agent_id`, name and description; a main-thread request carries none. The
    /// Agents tab marks a subagent from this field alone, so a main-thread request marking none rests on the second half.
    @Test func aSubagentsRequestCarriesItsAgentToTheHubAndAMainThreadRequestCarriesNone() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)

        try await driver.send("/scenario subagent 30 approval")
        #expect(await waiting(driver))
        let request = try #require(await driver.snapshot().requests.first)
        let published = try #require(await rig.events.snapshot().sessions[id]?.pendingRequests.first)
        let agent = try #require(published.agent)
        // The same id the stream's `task_started` names: `agent_id` = `task_id`.
        #expect(agent.id == request.agent?.id && !agent.id.isEmpty)
        #expect(agent.name == "explorer" && agent.description == "Map the fake module")
        #expect(published.requestID == request.requestID)
        try await driver.answer(requestID: request.requestID, .allowOnce)
        #expect(await idle(driver, 20))
        #expect(await rig.events.snapshot().sessions[id]?.pendingRequests.isEmpty == true)

        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        let main = try #require(await rig.events.snapshot().sessions[id]?.pendingRequests.first)
        #expect(main.agent == nil, "a main-thread request names no agent")
        try await driver.answer(requestID: main.requestID, .denyAndStop(note: nil))
        #expect(await idle(driver))
        await rig.finish()
    }

    /// The words of the running subagent's card, read from the driver's live model.
    private func subagentWords(_ driver: ChatSessionDriver) async -> String? {
        for entry in await driver.snapshot().model.entries {
            if case let .subagent(run) = entry.body { return run.latestProgress }
        }
        return nil
    }

    /// R4: Claude Code forwards a subagent's text to the parent's stream only with `--forward-subagent-text`, and the fake
    /// sends it only with the flag too. Loom's Chat spawn passes the flag where the help lists it, so the card of a subagent
    /// whose request waits shows its last sentence; a CLI whose help does not list the flag gets none (and starts without error).
    @Test func aWaitingSubagentsCardShowsItsWordsOnlyBecauseTheChatSpawnForwardsThem() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario subagent 30 approval")
        #expect(await waiting(driver))
        let shown = await waitUntil { await subagentWords(driver) == "Looking at the module." }
        let words = await subagentWords(driver)
        #expect(shown, "the card shows: \(String(describing: words))")
        let request = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: request.requestID, .allowOnce)
        #expect(await idle(driver, 20))
        await rig.finish()

        // The same fake behind a help text without the flag: no flag is passed, the fake keeps the words off the stream, and
        // the card is empty while the request waits (what R4 found against the real CLI).
        let plain = try await Rig.make(listsForwardSubagentText: false)
        let plainDriver = plain.driver()
        try await plainDriver.startNew(projectID: nil)
        try await plainDriver.send("/scenario subagent 30 approval")
        #expect(await waiting(plainDriver))
        // The Agent entry exists and its Bash call arrived; only the words are missing.
        #expect(await waitUntil {
            await plainDriver.snapshot().model.entries.contains { if case .subagent = $0.body { true } else { false } }
        })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await subagentWords(plainDriver) == nil)
        let plainRequest = try #require(await plainDriver.snapshot().requests.first)
        try await plainDriver.answer(requestID: plainRequest.requestID, .allowOnce)
        #expect(await idle(plainDriver, 20))
        await plain.finish()
    }

    /// The card's line follows the newest block of the subagent's own words, live: a second block replaces the first.
    @Test func theSubagentCardsLineFollowsTheNewestTextBlockOfItsThread() throws {
        var model = TurnModel(source: .live)
        model.appendPendingUser(uuid: "u1", text: "review", at: Date(timeIntervalSince1970: 1_800_000_000))
        func progress() -> String? {
            if case let .subagent(run)? = model.entry(id: "agent_1")?.body { run.latestProgress } else { nil }
        }
        let apply: (String) -> Void = { _ = model.apply(Fixture.message($0), at: Date(timeIntervalSince1970: 1_800_000_001)) }
        apply(Fixture.assistant(messageID: "m1", uuid: "a1", blocks: [Fixture.toolUse("agent_1", "Agent", ["description": "Review auth", "subagent_type": "reviewer", "prompt": "Look"])]))
        #expect(progress() == nil)
        apply(Fixture.assistant(messageID: "s1", uuid: "sa1", blocks: [Fixture.textBlock("Reading auth.py")], parent: "agent_1"))
        #expect(progress() == "Reading auth.py")
        // A tool call of the subagent is not words; the line keeps the last text.
        apply(Fixture.assistant(messageID: "s2", uuid: "sa2", blocks: [Fixture.toolUse("sub_t1", "Read", ["file_path": "auth.py"])], parent: "agent_1"))
        #expect(progress() == "Reading auth.py")
        apply(Fixture.assistant(messageID: "s3", uuid: "sa3", blocks: [Fixture.textBlock("The login handler checks the token twice.")], parent: "agent_1"))
        #expect(progress() == "The login handler checks the token twice.")
        // The main thread's own text does not touch the card.
        apply(Fixture.assistant(messageID: "m2", uuid: "a2", blocks: [Fixture.textBlock("While it works, I wait.")]))
        #expect(progress() == "The login handler checks the token twice.")
    }
}
