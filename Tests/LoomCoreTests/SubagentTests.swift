import Foundation
import Testing
@testable import LoomCore

private final class SubagentTestBundleAnchor: NSObject {}

/// The subagents a Claude session runs (D-39): the hook rules, the `meta.json` reader, the event hub
/// state, and one pass through the real adapter. Payload shapes follow the 12 Oct 2026 research of
/// Claude 2.1.293 (ids and paths are made up).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SubagentTests {
    private let conversation = "11111111-2222-3333-4444-555555555555"
    private let transcript = "/tmp/cfg/projects/-tmp-ws/11111111-2222-3333-4444-555555555555.jsonl"

    private func envelope(
        _ sessionID: UUID, _ runID: UUID, _ event: String, fields: [String: Any] = [:], sentAt: Date = Date()
    ) throws -> ClaudeHookEnvelope {
        var object: [String: Any] = [
            "session_id": conversation, "hook_event_name": event, "cwd": "/tmp/ws",
            "transcript_path": transcript, "prompt_id": "p1",
        ]
        object.merge(fields) { _, new in new }
        return ClaudeHookEnvelope(
            sessionID: sessionID, managedRunID: runID,
            payload: try JSONSerialization.data(withJSONObject: object), sentAt: sentAt)
    }

    private func start(_ id: String, _ type: String = "Explore") -> [String: Any] {
        ["agent_id": id, "agent_type": type]
    }

    private func stop(_ id: String, _ type: String = "Explore", running: [[String: Any]] = []) -> [String: Any] {
        ["agent_id": id, "agent_type": type, "stop_hook_active": false, "background_tasks": running,
         "agent_transcript_path": "/tmp/cfg/projects/-tmp-ws/\(conversation)/subagents/agent-\(id).jsonl"]
    }

    private func task(_ id: String, _ type: String = "Explore", _ description: String = "List directories") -> [String: Any] {
        ["id": id, "type": "subagent", "status": "running", "description": description, "agent_type": type]
    }

    private func sample(_ status: String, at milliseconds: Double) -> ClaudeRegistryRead {
        .snapshot(ClaudeRegistrySnapshot(sessionID: conversation, startedAt: 1, status: status, statusUpdatedAt: milliseconds))
    }

    private func tracker(
        _ events: [(String, [String: Any])] = [("SessionStart", ["source": "startup"])]
    ) async throws -> (ClaudeHookStateTracker, UUID, UUID) {
        let session = UUID(), run = UUID()
        let tracker = ClaudeHookStateTracker(sessionID: session, managedRunID: run)
        for (event, fields) in events { _ = try await tracker.receive(envelope(session, run, event, fields: fields)) }
        return (tracker, session, run)
    }

    // MARK: Tracker rules

    @Test func startAndStopGiveRunningThenFinishedRecordsWithoutTouchingTheStatus() async throws {
        let (tracker, session, run) = try await tracker([("SessionStart", [:]), ("UserPromptSubmit", ["prompt": "go"])])
        let before = await tracker.status()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let started = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("a1"), sentAt: t0))
        #expect(started == .applied(try ClaudeHookEvent(payload: envelope(session, run, "SubagentStart", fields: start("a1")).payload)))
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("a2", "general-purpose"), sentAt: t0))
        var records = await tracker.subagentRecords()
        #expect(records.map(\.id) == ["a1", "a2"])
        #expect(records.allSatisfy { $0.isRunning })
        #expect(records[0].agentType == "Explore" && records[0].depth == 1 && !records[0].isBackground)
        _ = try await tracker.receive(envelope(session, run, "SubagentStop", fields: stop("a1"), sentAt: t0.addingTimeInterval(18)))
        records = await tracker.subagentRecords()
        #expect(!records[0].isRunning && records[0].endedAt == t0.addingTimeInterval(18))
        #expect(records[1].isRunning)
        // Neither the activity nor the last-event stamp moved: these are not turn events.
        #expect(await tracker.status() == before)
    }

    @Test func claudesInternalAgentsAreIgnored() async throws {
        let (tracker, session, run) = try await tracker()
        _ = try await tracker.receive(envelope(session, run, "SubagentStop", fields: stop("internal", "")))
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("internal2", "")))
        #expect(await tracker.subagentRecords().isEmpty)
    }

    @Test func otherChildAgentPayloadsAndOtherConversationsStayDropped() async throws {
        let (tracker, session, run) = try await tracker()
        for kind in ["Stop", "UserPromptSubmit", "Notification"] {
            #expect(try await tracker.receive(envelope(session, run, kind, fields: ["agent_id": "child"])) == .childAgent)
        }
        #expect(try await tracker.receive(envelope(
            session, run, "SubagentStart", fields: start("x").merging(["session_id": "other-conversation"]) { _, n in n }))
            == .wrongConversation)
        #expect(await tracker.subagentRecords().isEmpty)
    }

    @Test func aBackgroundSubagentsPermissionPromptShowsNeedsApprovalUntilTheRegistrySaysItWasAnswered() async throws {
        // FB2-6, seen with real Claude: the parent's turn had ended with the subagent in the background,
        // the subagent asked for Bash, and the card stayed on Working.
        let t0 = Date()
        let (tracker, session, run) = try await tracker([("SessionStart", ["source": "startup"]), ("UserPromptSubmit", ["prompt": "go"])])
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("a1", "general-purpose"), sentAt: t0))
        _ = try await tracker.receive(envelope(
            session, run, "Stop", fields: ["background_tasks": [task("a1", "general-purpose")]], sentAt: t0))
        let asked = try await tracker.receive(envelope(
            session, run, "PermissionRequest", fields: start("a1", "general-purpose").merging(["tool_name": "Bash"]) { _, n in n },
            sentAt: t0.addingTimeInterval(1)))
        guard case .applied = asked else { Issue.record("dropped: \(asked)"); return }
        #expect(await tracker.status().activity == .waitingForApproval)
        // The prompt is still up; then it is answered while the subagent runs on: the finished turn with its
        // background work is back (the card shows Working from the count).
        let ms = t0.timeIntervalSince1970 * 1_000
        let generation = await tracker.registryGeneration()
        _ = await tracker.receiveRegistry(sample("waiting", at: ms + 1_100), generation: generation, now: t0.addingTimeInterval(3))
        #expect(await tracker.status().activity == .waitingForApproval)
        _ = await tracker.receiveRegistry(sample("busy", at: ms + 2_000), generation: generation, now: t0.addingTimeInterval(3))
        let status = await tracker.status()
        #expect(status.activity == .turnComplete && status.backgroundTaskCount == 1)
        #expect(await tracker.registryGeneration() == nil)
    }

    @Test func aForegroundSubagentsPromptReturnsToWorkingAndOtherConversationsStayDropped() async throws {
        let t0 = Date()
        let (tracker, session, run) = try await tracker([("SessionStart", ["source": "startup"]), ("UserPromptSubmit", ["prompt": "go"])])
        let other = try await tracker.receive(envelope(
            session, run, "PermissionRequest", fields: ["agent_id": "a1", "session_id": "other-conversation"], sentAt: t0))
        #expect(other == .wrongConversation)
        #expect(await tracker.status().activity == .working)
        _ = try await tracker.receive(envelope(
            session, run, "Notification", fields: ["agent_id": "a1", "notification_type": "permission_prompt"],
            sentAt: t0.addingTimeInterval(1)))
        #expect(await tracker.status().activity == .waitingForApproval)
        let ms = t0.timeIntervalSince1970 * 1_000
        _ = await tracker.receiveRegistry(
            sample("busy", at: ms + 1_500), generation: await tracker.registryGeneration(), now: t0.addingTimeInterval(3))
        #expect(await tracker.status().activity == .working)
    }

    @Test func aSubagentEventBeforeTheConversationIsKnownDoesNotSpoilTheFirstStart() async throws {
        let session = UUID(), run = UUID()
        let tracker = ClaudeHookStateTracker(sessionID: session, managedRunID: run)
        #expect(try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("a1"))) == .wrongConversation)
        _ = try await tracker.receive(envelope(session, run, "SessionStart", fields: ["source": "startup"]))
        #expect(await tracker.status().activity == .atPrompt)
    }

    @Test func aStopBeforeItsStartIsNotUndoneByTheStart() async throws {
        let (tracker, session, run) = try await tracker()
        _ = try await tracker.receive(envelope(session, run, "SubagentStop", fields: stop("a1")))
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("a1")))
        let records = await tracker.subagentRecords()
        #expect(records.count == 1 && !records[0].isRunning)
    }

    @Test func aBackgroundSubagentWhoseStartWasMissedShowsAsRunningFromTheStopList() async throws {
        let (tracker, session, run) = try await tracker([("SessionStart", [:]), ("UserPromptSubmit", ["prompt": "go"])])
        _ = try await tracker.receive(envelope(session, run, "Stop", fields: [
            "background_tasks": [task("bg1", "Explore", "List directories")]]))
        var records = await tracker.subagentRecords()
        #expect(records.count == 1 && records[0].isRunning && records[0].isBackground)
        #expect(records[0].description == "List directories" && records[0].agentType == "Explore")
        // Its start (and the second Stop) fill in the same record; they never duplicate it.
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("bg1")))
        _ = try await tracker.receive(envelope(session, run, "Stop", fields: ["background_tasks": [task("bg1")]]))
        #expect(await tracker.subagentRecords().count == 1)
        // Only its own SubagentStop ends it, even though that payload lists it as running.
        _ = try await tracker.receive(envelope(session, run, "SubagentStop", fields: stop("bg1", running: [task("bg1")])))
        records = await tracker.subagentRecords()
        #expect(!records[0].isRunning)
    }

    @Test func theParentsStopEndsAForegroundSubagentWhoseStopWasLost() async throws {
        let (tracker, session, run) = try await tracker([("SessionStart", [:]), ("UserPromptSubmit", ["prompt": "go"])])
        let t0 = Date(timeIntervalSince1970: 2_000)
        for id in ["lost", "listed", "knownBackground"] {
            _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start(id), sentAt: t0))
        }
        #expect(await tracker.applySubagentMeta(id: "knownBackground", SubagentMeta(isBackground: true)))
        // The foreground "lost" never got its SubagentStop; "listed" is a background one the Stop reports.
        _ = try await tracker.receive(envelope(
            session, run, "Stop", fields: ["background_tasks": [task("listed")]], sentAt: t0.addingTimeInterval(30)))
        var records = await tracker.subagentRecords()
        #expect(records.map(\.id) == ["lost", "listed", "knownBackground"])
        #expect(!records[0].isRunning && records[0].endedAt == t0.addingTimeInterval(30))
        #expect(records[1].isRunning && records[1].isBackground)
        #expect(records[2].isRunning, "a known-background subagent that is not listed stays running")
        // The late real stop does not change the end, and the ended one does not come back.
        _ = try await tracker.receive(envelope(session, run, "SubagentStop", fields: stop("lost"), sentAt: t0.addingTimeInterval(90)))
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("lost"), sentAt: t0.addingTimeInterval(91)))
        records = await tracker.subagentRecords()
        #expect(records[0].endedAt == t0.addingTimeInterval(30))
    }

    @Test func aStaleStopListCannotBringAFinishedSubagentBack() async throws {
        let (tracker, session, run) = try await tracker()
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("bg1")))
        _ = try await tracker.receive(envelope(session, run, "SubagentStop", fields: stop("bg1")))
        _ = try await tracker.receive(envelope(session, run, "Stop", fields: ["background_tasks": [task("bg1")]]))
        #expect(await tracker.subagentRecords().allSatisfy { !$0.isRunning })
        // Not even after the next real prompt dropped the finished record.
        _ = try await tracker.receive(envelope(session, run, "UserPromptSubmit", fields: ["prompt": "next"]))
        _ = try await tracker.receive(envelope(session, run, "Stop", fields: ["background_tasks": [task("bg1")]]))
        #expect(await tracker.subagentRecords().isEmpty)
    }

    @Test func finishedSubagentsEndWithTheNextRealPromptButNotWithHandBacks() async throws {
        let (tracker, session, run) = try await tracker([("SessionStart", [:]), ("UserPromptSubmit", ["prompt": "go"])])
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("done")))
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("busy", "general-purpose")))
        _ = try await tracker.receive(envelope(session, run, "SubagentStop", fields: stop("done")))
        for synthetic in ["<agent-message from=\"busy\">\n[Subagent hand-back] ...</agent-message>",
                          "  <task-notification>done</task-notification>"] {
            _ = try await tracker.receive(envelope(session, run, "UserPromptSubmit", fields: ["prompt": synthetic]))
            #expect(await tracker.subagentRecords().map(\.id) == ["done", "busy"], "\(synthetic.prefix(20))")
        }
        _ = try await tracker.receive(envelope(session, run, "UserPromptSubmit", fields: ["prompt": "now do the next thing"]))
        // The finished one is gone; the one still running stays.
        #expect(await tracker.subagentRecords().map(\.id) == ["busy"])
    }

    @Test func aNewConversationOfTheRunStartsWithoutSubagents() async throws {
        let (tracker, session, run) = try await tracker()
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("a1")))
        _ = try await tracker.receive(envelope(session, run, "SessionStart", fields: [
            "session_id": "66666666-2222-3333-4444-555555555555", "source": "clear"]))
        #expect(await tracker.subagentRecords().isEmpty)
    }

    @Test func aNewRunStartsWithoutSubagents() async throws {
        let (tracker, session, run) = try await tracker()
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("a1")))
        await tracker.beginRun(UUID())
        #expect(await tracker.subagentRecords().isEmpty)
    }

    @Test func theListIsBounded() async throws {
        let (tracker, session, run) = try await tracker()
        for index in 0..<(SubagentLedger.maximumFinished + 7) {
            _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("f\(index)")))
            _ = try await tracker.receive(envelope(session, run, "SubagentStop", fields: stop("f\(index)")))
        }
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("running")))
        let records = await tracker.subagentRecords()
        #expect(records.filter { !$0.isRunning }.count == SubagentLedger.maximumFinished)
        #expect(records.first?.id == "f7" && records.last?.id == "running")
        for index in 0..<(SubagentLedger.maximumRunning + 5) {
            _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("r\(index)")))
        }
        #expect(await tracker.subagentRecords().filter { $0.isRunning }.count == SubagentLedger.maximumRunning)
    }

    // MARK: meta.json

    @Test func metaFileFieldsAreReadAndBounded() throws {
        let json = #"{"agentType":"Explore","description":"  Find login\n   flow handlers ","toolUseId":"toolu_x","spawnDepth":2,"requestShape":"background","requestNonInteractive":true}"#
        let meta = try #require(SubagentMeta.parse(Data(json.utf8)))
        #expect(meta == SubagentMeta(agentType: "Explore", description: "Find login flow handlers", depth: 2, isBackground: true))
        let foreground = try #require(SubagentMeta.parse(Data(#"{"requestShape":"foreground","spawnDepth":0}"#.utf8)))
        #expect(foreground.isBackground == false && foreground.depth == 1 && foreground.description == nil)
        let long = try #require(SubagentMeta.parse(Data(#"{"description":"\#(String(repeating: "x", count: 500))"}"#.utf8)))
        #expect(long.description?.count == SubagentMeta.maximumDescriptionLength)
        #expect(SubagentMeta.parse(Data("not json".utf8)) == nil)
    }

    @Test func metaFileLocationFollowsThePayloadPathsAndRefusesOddIds() throws {
        let own = "/tmp/cfg/projects/-tmp-ws/\(conversation)/subagents/agent-a1.jsonl"
        #expect(SubagentMeta.fileURL(agentID: "a1", transcriptPath: transcript, agentTranscriptPath: own)?.path
                == "/tmp/cfg/projects/-tmp-ws/\(conversation)/subagents/agent-a1.meta.json")
        #expect(SubagentMeta.fileURL(agentID: "a1", transcriptPath: transcript, agentTranscriptPath: nil)?.path
                == "/tmp/cfg/projects/-tmp-ws/\(conversation)/subagents/agent-a1.meta.json")
        // The subagent's transcript must be the one named by its id.
        #expect(SubagentMeta.fileURL(agentID: "a2", transcriptPath: nil, agentTranscriptPath: own) == nil)
        #expect(SubagentMeta.fileURL(agentID: "../etc", transcriptPath: transcript, agentTranscriptPath: nil) == nil)
        #expect(SubagentMeta.fileURL(agentID: "a1", transcriptPath: "relative/x.jsonl", agentTranscriptPath: nil) == nil)
    }

    @Test func metaDetailsFillTheRecordOnceAndOnlyOnce() async throws {
        let (tracker, session, run) = try await tracker()
        _ = try await tracker.receive(envelope(session, run, "SubagentStart", fields: start("a1")))
        let meta = SubagentMeta(agentType: "Explore", description: "Find it", depth: 2, isBackground: true)
        #expect(await tracker.applySubagentMeta(id: "a1", meta))
        #expect(!(await tracker.applySubagentMeta(id: "a1", meta)))
        #expect(!(await tracker.applySubagentMeta(id: "unknown", meta)))
        let record = try #require(await tracker.subagentRecords().first)
        #expect(record.description == "Find it" && record.depth == 2 && record.isBackground)
    }

    // MARK: Event hub

    @Test func subagentsLiveAndDieWithTheRun() async {
        let hub = SessionEventHub()
        let session = UUID(), run = UUID()
        let record = SubagentRecord(id: "a1", agentType: "Explore", startedAt: Date())
        // No run: a late update is ignored.
        await hub.publish(sessionID: session, change: .subagents([record]))
        #expect(await hub.snapshot().sessions[session] == nil)
        await hub.publish(sessionID: session, change: .runStarted(run))
        await hub.publish(sessionID: session, change: .subagents([record]))
        #expect(await hub.snapshot().sessions[session]?.subagents == [record])
        await hub.publish(sessionID: session, change: .runEnded(run, .idle))
        #expect(await hub.snapshot().sessions[session]?.subagents == [])
        await hub.publish(sessionID: session, change: .subagents([record]))
        #expect(await hub.snapshot().sessions[session]?.subagents == [])
        // A detach (the run moved to another card) and a new run clear it as well.
        await hub.publish(sessionID: session, change: .runStarted(run))
        await hub.publish(sessionID: session, change: .subagents([record]))
        await hub.publish(sessionID: session, change: .runDetached(run))
        #expect(await hub.snapshot().sessions[session]?.subagents == [])
        await hub.publish(sessionID: session, change: .runStarted(run))
        await hub.publish(sessionID: session, change: .subagents([record]))
        await hub.publish(sessionID: session, change: .runStarted(UUID()))
        #expect(await hub.snapshot().sessions[session]?.subagents == [])
    }

    // MARK: Through the real adapter

    private var childPath: String {
        Bundle(for: SubagentTestBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-test-child").path
    }

    private func settle(_ supervisor: ProcessSupervisor, _ session: UUID, until: ([SubagentRecord]) -> Bool) async -> [SubagentRecord] {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var records: [SubagentRecord] = []
        repeat {
            records = await supervisor.events.snapshot().sessions[session]?.subagents ?? []
            if until(records) { break }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return records
    }

    @Test func theAdapterShowsSubagentsWithLateMetaDetailsAndClearsThemWhenTheRunEnds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-subagent-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let subagents = root.appendingPathComponent("projects/-tmp-ws/\(conversation)/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let parent = root.appendingPathComponent("projects/-tmp-ws/\(conversation).jsonl").path

        let supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
        let session = UUID()
        try await supervisor.createSession(ManagedSession(
            id: session, provider: .claude, providerConversationID: conversation,
            workingDirectory: FileManager.default.temporaryDirectory.path))
        let launched = try await supervisor.launch(
            sessionID: session, executable: childPath, arguments: ["stubborn"],
            environment: LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: session))
        let run = try #require(launched.session.currentRun?.id)
        let adapter = ClaudeSessionAdapter(supervisor: supervisor)
        func send(_ event: String, _ fields: [String: Any] = [:]) async throws {
            var all = fields
            all["transcript_path"] = parent
            _ = try await adapter.receive(envelope(session, run, event, fields: all))
        }

        try await send("SessionStart", ["source": "resume"])
        try await send("UserPromptSubmit", ["prompt": "review the diff"])
        try await send("SubagentStart", start("a1"))
        var records = await settle(supervisor, session) { $0.count == 1 }
        #expect(records.map(\.agentType) == ["Explore"] && records[0].description == nil)

        // Claude writes the meta file a few milliseconds after the start hook: it is picked up off the hook path.
        let meta = #"{"agentType":"Explore","description":"Find login flow handlers","spawnDepth":1,"requestShape":"foreground"}"#
        try meta.write(to: subagents.appendingPathComponent("agent-a1.meta.json"), atomically: true, encoding: .utf8)
        records = await settle(supervisor, session) { $0.first?.description != nil }
        #expect(records.first?.description == "Find login flow handlers")

        try await send("SubagentStop", stop("a1"))
        records = await settle(supervisor, session) { $0.first?.isRunning == false }
        #expect(records.count == 1 && !records[0].isRunning)

        // A stop with no meta file yet is read at the stop (here: it exists only then).
        try await send("SubagentStart", start("a2", "general-purpose"))
        try #"{"agentType":"general-purpose","description":"Fix token refresh race","spawnDepth":2,"requestShape":"background"}"#
            .write(to: subagents.appendingPathComponent("agent-a2.meta.json"), atomically: true, encoding: .utf8)
        records = await settle(supervisor, session) { $0.count == 2 && $0[1].description != nil }
        #expect(records[1].depth == 2 && records[1].isBackground)

        // The next real prompt drops the finished one and leaves the running one.
        try await send("UserPromptSubmit", ["prompt": "<agent-message from=\"a2\">x</agent-message>"])
        #expect(await supervisor.events.snapshot().sessions[session]?.subagents.count == 2)
        try await send("UserPromptSubmit", ["prompt": "and now the tests"])
        records = await settle(supervisor, session) { $0.count == 1 }
        #expect(records.map(\.id) == ["a2"])

        #expect(try await supervisor.stop(sessionID: session, graceSeconds: 0.05).succeeded)
        #expect(await supervisor.events.snapshot().sessions[session]?.subagents == [])
        #expect((await supervisor.shutdown(graceSeconds: 0.2)).succeeded)
    }
}
