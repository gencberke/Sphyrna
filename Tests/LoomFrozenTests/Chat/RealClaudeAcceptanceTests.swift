import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomChatTestRigs

/// Release B acceptance, driver level (checks 1 to 8), against the user's real `claude` (Haiku) under the isolated
/// profile. Runs only when `LOOM_ACC_REAL_CLAUDE=1`. Environment:
///
/// - `LOOM_ACC_CLAUDE_CONFIG`: the isolated, logged-in profile (`Loom-Dev/probe/claude-config`);
/// - `LOOM_ACC_WORK_ROOT`: a folder outside HOME whose subfolders `join`, `approve`, `qplan`, `interrupt`, `stoptask`,
///   `fullaccess`, `ask` and `clear` exist and are trusted in that profile (`perf_paths.real_work_dir`);
/// - `LOOM_ACC_DIR`: the evidence folder, where `harness.log` collects one line per phase.
///
/// Every test is a check of its own, with its own runtime and child, so a failed check stops only itself. Output holds
/// phases, counts, booleans and key names: no content of a prompt, an answer or a file, and no account data.
@Suite(.serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["LOOM_ACC_REAL_CLAUDE"] == "1"))
struct RealClaudeAcceptanceTests {
    // MARK: A1. The uuid join

    @Test func a1QueuedCommandSourceUuidIsTheUuidLoomSent() async throws {
        try await AccRig.run("a1-join") { rig in
            for index in 1...8 {
                try rig.write("c\(index).txt", index == 8 ? "END\n" : "next: c\(index + 1).txt\n")
            }
            let driver = rig.driver()
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "default"))
            rig.turn("A1 chain of Read calls")
            try await driver.send("Use the Read tool on c1.txt. It names the next file to read; follow the chain one file per call, "
                                  + "one call at a time, until a file says END. Then reply with the single word: done")
            let running = await rig.wait(90) { await driver.hasToolEntry() }
            rig.log("first tool call seen \(running)")
            rig.turn("A1 message sent while the turn runs")
            let receipt = try await driver.send("Also reply, after that, with the single word: second", timing: .next)
            guard case let .sent(uuid) = receipt else { Issue.record("not sent"); return }
            #expect(await rig.waitIdle(driver, 120))
            let conversation = try #require(await driver.liveState().conversationID)
            let records = rig.transcript(conversation)
            let queued = records.filter { ($0["attachment"] as? [String: Any])?["type"] as? String == "queued_command" }
            let humanQueued = queued.filter { (($0["attachment"] as? [String: Any])?["commandMode"] as? String) == "prompt" }
            let joined = humanQueued.filter { (($0["attachment"] as? [String: Any])?["source_uuid"] as? String) == uuid }
            let users = records.filter { ($0["type"] as? String) == "user" && ($0["uuid"] as? String) == uuid }
            rig.log("transcript records \(records.count), queued_command \(queued.count), human prompt \(humanQueued.count)")
            if let sample = humanQueued.first { rig.log("queued_command record keys \(Self.keys(sample)), attachment keys \(Self.keys(sample["attachment"]))") }
            rig.log("queued_command with source_uuid == sent uuid: \(joined.count); user record under the sent uuid: \(users.count)")
            if let user = users.first { rig.log("user record keys \(Self.keys(user))") }
            if let first = records.first(where: { ($0["type"] as? String) == "user" && ($0["isMeta"] as? Bool) != true }) {
                rig.log("first user record keys \(Self.keys(first)), has uuid \(first["uuid"] != nil)")
            }
            let sampleSource = (humanQueued.first.flatMap { ($0["attachment"] as? [String: Any])?["source_uuid"] as? String })
            rig.log("sent uuid shape \(Self.shape(uuid)); source_uuid shape \(sampleSource.map(Self.shape) ?? "none"); record uuid shape \(humanQueued.first.flatMap { $0["uuid"] as? String }.map(Self.shape) ?? "none")")
            let snapshot = await driver.snapshot()
            let rows = snapshot.model.entries.filter { if case let .user(p) = $0.body { p.text.contains("second") } else { false } }
            rig.log("live model rows for the sent message \(rows.count), delivery \(rows.compactMap { if case let .user(p) = $0.body { "\(p.delivery)" } else { nil } })")
            #expect(joined.count == 1 || users.count == 1)
        }
    }

    // MARK: A2. Approval: allow, and deny with a note

    @Test func a2ApprovalAllowAndDenyWithNote() async throws {
        try await AccRig.run("a2-approval") { rig in
            let driver = rig.driver()
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "default"))
            rig.turn("A2 allow: touch")
            try await driver.send("Use the Bash tool to run exactly: touch allowed.txt. Then reply with the single word: done")
            let first = try #require(await rig.waitRequest(driver, 90))
            rig.log("request: kind \(first.kind), tool \(first.request.toolName), input keys \(Self.keys(first.request.input)), suggestions \(first.request.permissionSuggestions.count), reason type \(first.request.decisionReasonType ?? "-"), phase \(await driver.currentPhase)")
            #expect(first.kind == .approval)
            #expect(await !rig.exists("allowed.txt"))
            try await driver.answer(requestID: first.requestID, .allowOnce)
            #expect(await rig.waitIdle(driver, 90))
            rig.log("allowed.txt exists \(await rig.exists("allowed.txt"))")
            #expect(await rig.exists("allowed.txt"))

            rig.turn("A2 deny with a note: touch")
            let note = "NOTE-ACC-7: do not create files here, use the Write tool next time"
            try await driver.send("Use the Bash tool to run exactly: touch denied.txt. If it is refused, quote the reason you were given in one sentence.")
            let second = try #require(await rig.waitRequest(driver, 90))
            try await driver.answer(requestID: second.requestID, .deny(note: note))
            #expect(await rig.waitIdle(driver, 90))
            let snapshot = await driver.snapshot()
            let conversation = try #require(await driver.liveState().conversationID)
            let noteInTranscript = rig.transcriptContains(conversation, "NOTE-ACC-7")
            let noteInAnswer = snapshot.model.entries.contains { if case let .assistantText(t) = $0.body { t.text.contains("NOTE-ACC-7") || t.text.lowercased().contains("do not create files") } else { false } }
            rig.log("denied.txt exists \(await rig.exists("denied.txt")); note reached the transcript (tool result) \(noteInTranscript); note quoted back by Claude \(noteInAnswer); tool statuses \(Self.toolStatuses(snapshot))")
            #expect(await !rig.exists("denied.txt"))
            #expect(noteInTranscript)
        }
    }

    // MARK: A3. A question, and a plan approved with a mode

    @Test func a3QuestionAnsweredAndPlanApprovedWithAMode() async throws {
        try await AccRig.run("a3-question-plan") { rig in
            let driver = rig.driver()
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "default"))
            rig.turn("A3 AskUserQuestion")
            try await driver.send("Use the AskUserQuestion tool once to ask which colour I prefer, with exactly the options Red and Blue. "
                                  + "After my answer reply with the colour I chose, one word.")
            let question = try #require(await rig.waitRequest(driver, 90))
            let questions = question.request.input["questions"]?.array ?? []
            let text = questions.first?["question"]?.string ?? ""
            let labels = (questions.first?["options"]?.array ?? []).compactMap { $0["label"]?.string }
            rig.log("question request: kind \(question.kind), questions \(questions.count), option count \(labels.count), input keys \(Self.keys(question.request.input)), first question keys \(Self.keys(questions.first))")
            #expect(question.kind == .question)
            let pick = labels.first(where: { $0.lowercased().contains("blue") }) ?? labels.last ?? "Blue"
            try await driver.answer(requestID: question.requestID, .answers([ChatQuestionAnswer(question: text, picks: [pick])]))
            #expect(await rig.waitIdle(driver, 90))
            var snapshot = await driver.snapshot()
            let said = snapshot.model.entries.contains { if case let .assistantText(t) = $0.body { t.text.lowercased().contains("blue") } else { false } }
            rig.log("after the answer: assistant named the chosen colour \(said); tools \(Self.toolStatuses(snapshot)); settled \(snapshot.settled.map { "\($0.toolName):\($0.outcome)" })")
            #expect(said)

            // Plan: the mode is chosen live (the harness has no mode menu), the plan is approved with acceptEdits.
            try await driver.setPermissionMode("plan")
            rig.log("mode after setPermissionMode(plan): \(await driver.snapshot().permissionMode ?? "-")")
            rig.turn("A3 ExitPlanMode")
            try await driver.send("In plan mode, plan how to create a file plan-made.txt that contains the single word hello. "
                                  + "When the plan is ready, leave plan mode with ExitPlanMode, then create the file.")
            let plan = try #require(await rig.waitRequest(driver, 120))
            rig.log("plan request: kind \(plan.kind), tool \(plan.request.toolName), input keys \(Self.keys(plan.request.input))")
            #expect(plan.kind == .plan)
            try await driver.answer(requestID: plan.requestID, .approvePlan(mode: "acceptEdits"))
            #expect(await rig.waitIdle(driver, 120))
            snapshot = await driver.snapshot()
            rig.log("after the approval: mode \(snapshot.permissionMode ?? "-"), choices mode \(snapshot.choices.permissionMode ?? "-"), plan-made.txt exists \(await rig.exists("plan-made.txt")), requests \(snapshot.requests.count), tools \(Self.toolStatuses(snapshot))")
            #expect(snapshot.permissionMode == "acceptEdits")
            #expect(await rig.exists("plan-made.txt"))
        }
    }

    // MARK: A4. Interrupt with a queued message

    @Test func a4InterruptPausesTheQueueAndReturnsTheUnreadMessage() async throws {
        try await AccRig.run("a4-interrupt") { rig in
            let driver = rig.driver()
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "default"))
            rig.turn("A4 long answer")
            try await driver.send("Count from 1 to 500, one number per line, nothing else.")
            let streaming = await rig.wait(60) { await driver.snapshot().model.entries.contains {
                if case let .assistantText(t) = $0.body { !t.text.isEmpty } else { false } } }
            rig.log("text streaming \(streaming)")
            let unread = try await driver.send("UNREAD-ACC-1 say banana", timing: .next)
            guard case let .sent(unreadID) = unread else { Issue.record("not sent"); return }
            let queuedItem = try await driver.send("AFTER-ACC-2 say apple", timing: .afterTurn)
            guard case .queued = queuedItem else { Issue.record("not queued"); return }
            try await Task.sleep(for: .milliseconds(800))
            let before = await driver.snapshot()
            rig.log("before the interrupt: delivery of the unread message \(Self.delivery(before, unreadID)), queue items \(before.queue.items.count), unread \(before.model.pendingUserMessageIDs.count)")
            await driver.interrupt()
            #expect(await rig.waitIdle(driver, 30))
            try await Task.sleep(for: .seconds(3))
            let after = await driver.snapshot()
            let drafts = await driver.takeReturnedDrafts()
            rig.log("after the interrupt: turn \(after.model.turns.last.map { "\($0.status)" } ?? "-"), queue paused \(String(describing: after.queue.paused)), queue items \(after.queue.items.count), returned drafts \(drafts.count) (contains the unread message \(drafts.contains { $0.text.contains("UNREAD-ACC-1") })), delivery now \(Self.delivery(after, unreadID)), turn running \(after.turnRunning)")
            #expect(after.queue.paused == .interrupted)
            #expect(after.queue.items.count == 1)
            #expect(drafts.contains { $0.text.contains("UNREAD-ACC-1") })
            #expect(!after.turnRunning)
        }
    }

    // MARK: A5. stop_task

    @Test func a5StopTaskShapes() async throws {
        try await AccRig.run("a5-stop-task") { rig in
            let before = await Self.processes(matching: "sleep 60")
            let sink = ChatPipeSink()
            let id = UUID()
            let launched = try await rig.runtime.startChatConversation(
                projectID: nil, sessionID: id, draft: rig.draft(mode: "default"), outputSink: sink)
            let channel = ControlChannel()
            let writer = Task { for await line in channel.outgoing { do { try await launched.pipe.write(line) } catch { break } } }
            let log = WireLog()
            let reader = Task {
                for await input in sink.inputs {
                    guard case let .frames(frames, _, bytes) = input else { continue }
                    for frame in frames {
                        guard case let .message(message) = frame else { continue }
                        await channel.receive(message)
                        log.note(message)
                    }
                    sink.taken(bytes)
                }
            }
            // Approvals the harness answers itself: only the one background `sleep 60`.
            let answerer = Task {
                for await event in channel.events {
                    guard case let .request(request) = event, case let .canUseTool(tool) = request.kind else { continue }
                    let command = tool.input["command"]?.string ?? ""
                    let allowed = tool.toolName == "Bash" && command.hasPrefix("sleep 60") && !command.contains(";") && !command.contains("&&")
                    rig.log("A5 request: tool \(tool.toolName), allowed by the harness \(allowed), input keys \(Self.keys(tool.input))")
                    if allowed {
                        _ = await channel.respond(to: request.requestID, with: .allow(updatedInput: tool.input, toolUseID: tool.toolUseID))
                    } else {
                        _ = await channel.respond(to: request.requestID, with: .deny(message: "The harness allows only the background sleep."))
                    }
                }
            }
            defer { writer.cancel(); reader.cancel(); answerer.cancel() }
            let ready = try await channel.request(.initialize, timeout: .seconds(30))
            rig.log("A5 initialize answered, models \(ready.initializeResponse.models.count)")
            rig.turn("A5 background sleep")
            try await channel.write(OutgoingUserMessage(
                text: "Use the Bash tool with run_in_background set to true to run exactly: sleep 60. Do not wait for it. Then reply with the single word: started").line())
            let started = await rig.wait(120) { log.taskID() != nil }
            rig.log("A5 background task seen \(started); records: \(log.kindsSeen())")
            let taskID = try #require(log.taskID())
            _ = await rig.wait(30) { await Self.processes(matching: "sleep 60").count > before.count }
            let running = await Self.processes(matching: "sleep 60")
            rig.log("A5 sleep 60 processes before \(before.count), running now \(running.count)")
            let sent = OutgoingControlRequest.other(subtype: "stop_task", fields: ["task_id": .string(taskID)])
            let line = ControlWire.requestLine(id: "acc-stop-task", sent)
            log.markStopRequested()
            rig.log("A5 stop_task request line keys \(Self.keys(Self.parse(line))), request keys \(Self.keys(Self.parse(line)?["request"]))")
            do {
                let reply = try await channel.request(sent, timeout: .seconds(20))
                rig.log("A5 stop_task response: success, payload shape \(Self.describe(reply.payload))")
            } catch {
                rig.log("A5 stop_task response: error \(error)")
            }
            let ended = await rig.wait(20) { await Self.processes(matching: "sleep 60").count <= before.count }
            try await Task.sleep(for: .seconds(2))
            let left = await Self.processes(matching: "sleep 60").count
            rig.log("A5 after stop_task: sleep 60 processes \(left) (ended \(ended)); records after the request: \(log.afterStopKinds())")
            #expect(ended)
            #expect(await rig.wait(60) { log.resultCount() >= 1 })
        }
    }

    // MARK: A6. Full access, live

    @Test func a6FullAccessLive() async throws {
        try await AccRig.run("a6-full-access") { rig in
            try rig.write("marker.txt", "x\n")
            let driver = rig.driver()
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "default"))
            rig.log("started in mode \(await driver.snapshot().permissionMode ?? "-")")
            try await driver.setPermissionMode("bypassPermissions")
            let full = await driver.snapshot()
            rig.log("after the live switch: CLI mode \(full.permissionMode ?? "-"), choices \(full.choices.permissionMode ?? "-")")
            #expect(full.permissionMode == "bypassPermissions")
            rig.turn("A6 ls in Full access")
            try await driver.send("Use the Bash tool to run exactly: ls. Then reply with the single word: listed")
            #expect(await rig.waitIdle(driver, 90))
            let ran = await driver.snapshot()
            rig.log("ls turn: requests seen \(rig.spyCount(driver)), tools \(Self.toolStatuses(ran)), turn \(ran.model.turns.last.map { "\($0.status)" } ?? "-")")
            try await driver.setPermissionMode("default")
            let back = await driver.snapshot()
            rig.log("after switching back: CLI mode \(back.permissionMode ?? "-"), choices \(back.choices.permissionMode ?? "-")")
            #expect(back.permissionMode == "default")
            // Proof that Full access is gone: a `touch` (an ask rule of the profile) asks again, and is denied here.
            rig.turn("A6 ask again after leaving Full access (denied)")
            try await driver.send("Use the Bash tool to run exactly: touch afterfull.txt. If it is refused, just reply with the single word: refused")
            let request = await rig.waitRequest(driver, 90)
            rig.log("a request arrived after leaving Full access: \(request != nil)")
            if let request { try await driver.answer(requestID: request.requestID, .deny(note: "Not needed.")) }
            #expect(await rig.waitIdle(driver, 90))
            #expect(await !rig.exists("afterfull.txt"))
            #expect(request != nil)
        }
    }

    // MARK: A7. Ask on the real CLI

    @Test func a7AskChangesNothingAndLeavingItWorksInTheSameProcess() async throws {
        try await AccRig.run("a7-ask") { rig in
            try rig.write("notes.txt", "alpha\n")
            try rig.write("code.py", "print('hi')\n")
            try rig.write(".claude/settings.local.json", "{\"permissions\":{\"allow\":[\"Bash(mkdir:*)\"]}}\n")
            let driver = rig.driver()
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "default"))
            let pid = await driver.snapshot().processID
            rig.turn("A7 warm-up turn")
            try await driver.send("Reply with the single word: ready")
            #expect(await rig.waitIdle(driver, 90))
            let conversation = try #require(await driver.liveState().conversationID)
            let warmup = rig.usage(conversation)
            rig.log("warm-up turn: assistant calls \(warmup.count), last call cache read \(warmup.last?.cacheRead ?? -1), created \(warmup.last?.cacheCreation ?? -1)")

            let baseline = rig.digest()
            try await driver.setPermissionMode("ask")
            let entered = await driver.snapshot()
            rig.log("entered Ask: CLI mode \(entered.permissionMode ?? "-"), choices \(entered.choices.permissionMode ?? "-"), isAsk \(await driver.liveState().isAsk), pid same \(entered.processID == pid)")
            #expect(await driver.liveState().isAsk)
            let prompt = "1) Write tool: create made.txt containing hello. 2) Edit tool: in notes.txt replace alpha with beta. "
                + "3) Bash tool: run exactly `echo viabash > bash.txt`. 4) Bash tool: run exactly `mkdir madedir`. "
                + "Do not skip a step because an earlier one failed. Report each step's outcome line by line."
            rig.turn("A7 edit prompt in Ask")
            try await driver.send(prompt)
            #expect(await rig.waitIdle(driver, 120))
            let askSnapshot = await driver.snapshot()
            let afterAsk = rig.digest()
            let askUsage = rig.usage(conversation)
            let firstAfterAsk = askUsage.dropFirst(warmup.count).first
            rig.log("Ask turn: work dir identical to the baseline \(afterAsk == baseline) (files now \(afterAsk.keys.sorted().count)); requests that reached Loom \(rig.spyCount(driver)); settled \(askSnapshot.settled.count); tools \(Self.toolStatuses(askSnapshot)); mkdir dir exists \(await rig.exists("madedir"))")
            rig.log("cache read on the first call after entering Ask: \(firstAfterAsk?.cacheRead ?? -1), created \(firstAfterAsk?.cacheCreation ?? -1), input \(firstAfterAsk?.input ?? -1); previous call read \(warmup.last?.cacheRead ?? -1)")
            #expect(afterAsk == baseline)
            #expect(rig.spyCount(driver) == 0)
            #expect(askSnapshot.settled.isEmpty)
            #expect(await !rig.exists("madedir"))

            try await driver.leaveAsk()
            let left = await driver.snapshot()
            rig.log("left Ask: CLI mode \(left.permissionMode ?? "-"), choices \(left.choices.permissionMode ?? "-"), isAsk \(await driver.liveState().isAsk), pid same \(left.processID == pid)")
            #expect(!(await driver.liveState().isAsk))
            rig.turn("A7 same edit prompt after leaving Ask")
            let beforeLeaveCount = rig.usage(conversation).count
            try await driver.send(prompt)
            // The harness answers the approvals of the restored mode, for these steps only.
            let outcome = await rig.waitIdleAnswering(driver, 180) { tool, input in
                let command = input["command"]?.string ?? ""
                switch tool {
                case "Write", "Edit": return true
                case "Bash": return command == "echo viabash > bash.txt" || command == "mkdir madedir"
                default: return false
                }
            }
            rig.log("second turn: finished \(outcome.idle), approvals answered \(outcome.answered.sorted()), refused by the harness \(outcome.refused.sorted())")
            let finished = await driver.snapshot()
            let leftUsage = rig.usage(conversation)
            let firstAfterLeave = leftUsage.dropFirst(beforeLeaveCount).first
            rig.log("cache read on the first call after leaving Ask: \(firstAfterLeave?.cacheRead ?? -1), created \(firstAfterLeave?.cacheCreation ?? -1), input \(firstAfterLeave?.input ?? -1); previous call read \(askUsage.last?.cacheRead ?? -1)")
            let after = rig.digest()
            rig.log("edit worked after leaving Ask: made.txt \(await rig.exists("made.txt")), notes.txt now beta \(rig.read("notes.txt")?.contains("beta") == true), bash.txt \(await rig.exists("bash.txt")), madedir \(await rig.exists("madedir")); same pid \(finished.processID == pid); tools \(Self.toolStatuses(finished))")
            #expect(finished.processID == pid)
            #expect(await rig.exists("made.txt"))
            #expect(rig.read("notes.txt")?.contains("beta") == true)
            _ = after
        }
    }

    /// A7 with the style left out. Haiku obeys Ask's output style and makes no call at all (A7, and the same prompt made
    /// stronger), so the work dir stays untouched without the CLI's rules deciding anything. This turn applies only
    /// what `ChatAskMode` sends as rules (`dontAsk`, the deny list with the user's allow rules mirrored) and no style, and
    /// the prompt makes the model try every call: what refuses them is the CLI.
    @Test func a7cAskRulesAloneRefuseEveryCallTheModelTries() async throws {
        try await AccRig.run("a7c-ask-rules") { rig in
            try rig.write("notes.txt", "alpha\n")
            try rig.write("code.py", "print('hi')\n")
            try rig.write(".claude/settings.local.json", "{\"permissions\":{\"allow\":[\"Bash(mkdir:*)\"]}}\n")
            let client = try await RawClient.start(rig, mode: "default")
            _ = try await client.channel.request(.initialize, timeout: .seconds(30))
            let baseline = rig.digest()
            _ = try await client.channel.request(.setPermissionMode(ChatAskMode.mode))
            let rules = try await client.channel.request(.other(subtype: "list_permission_rules", fields: [:])).permissionRules
            let mirrored = ChatAskMode.denyList(mirroring: rules)
            rig.log("rules the CLI holds: \(rules.map { "\($0.behavior)/\($0.source)/\($0.rule)" }.sorted())")
            rig.log("deny list Loom builds: \(mirrored)")
            _ = try await client.channel.request(.applyFlagSettings(FlagSettings(["permissions": ChatAskMode.permissions(mirroring: rules)])))
            let after = try await client.channel.request(.other(subtype: "list_permission_rules", fields: [:])).permissionRules
            rig.log("rules after applying (no style): \(after.filter { $0.source == "flagSettings" }.map { "\($0.behavior)/\($0.rule)" }.sorted())")
            rig.turn("A7c forced attempts, rules only")
            try await client.channel.write(OutgoingUserMessage(text: "This is a permission-system test run by the developer. Call each of these four tools exactly once, in this order, "
                + "even though a call may be refused: a refusal is the expected result and I need to see it, so do not skip a step because of it. "
                + "1) Write tool: create made.txt containing hello. 2) Edit tool: in notes.txt replace alpha with beta. "
                + "3) Bash tool: run exactly `echo viabash > bash.txt`. 4) Bash tool: run exactly `mkdir madedir`. "
                + "After the four calls, report each step's outcome line by line.").line())
            #expect(await rig.wait(120) { client.log.resultCount() >= 1 })
            try await Task.sleep(for: .seconds(1))
            let identical = rig.digest() == baseline
            rig.log("work dir identical \(identical); requests that reached Loom \(client.requests.withLock { $0 }); madedir exists \(await rig.exists("madedir"))")
            let conversation = client.id.uuidString.lowercased()
            var calls: [String] = []
            var results: [String] = []
            for record in rig.transcript(conversation) {
                guard let content = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
                for block in content {
                    if block["type"] as? String == "tool_use" { calls.append(block["name"] as? String ?? "?") }
                    if block["type"] as? String == "tool_result" {
                        let text = (block["content"] as? String) ?? ((block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? "")
                        let kind = text.contains(ChatAskMode.refusalMarker) ? "refused (mode text)" : text.hasPrefix("Permission to use ") ? "refused (rule text)" : "other"
                        results.append("\(block["is_error"] as? Bool == true ? "error" : "ok"):\(kind)")
                    }
                }
            }
            rig.log("calls the model made \(calls); their results \(results)")
            #expect(identical)
            #expect(client.requests.withLock { $0 } == 0)
            #expect(await !rig.exists("madedir"))
            #expect(calls.count >= 3)
        }
    }

    // MARK: V21. Rewind files

    /// Release C, V21, against the real CLI (two Haiku turns): a dry run, the marks from the real transcript, a real rewind that
    /// replaced a file the user had changed (Loom's copy holds the user's version), and Undo from that copy.
    @Test func v21RewindFilesDryRunMarksRealRewindAndUndoAgainstTheRealCli() async throws {
        try await AccRig.run("v21-rewind") { rig in
            let store = ChatRewindStore(directory: rig.root.appendingPathComponent("chat-rewinds", isDirectory: true), trash: { url in
                try FileManager.default.removeItem(at: url)
            })
            let driver = rig.driver(rewinds: store)
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "acceptEdits"))
            rig.turn("V21 turn 1: Write creates v21.txt")
            try await driver.send("Use the Write tool to create the file v21.txt in the current folder with exactly one line: one. "
                                  + "Then reply with the single word: done")
            #expect(await rig.waitIdle(driver, 120))
            rig.turn("V21 turn 2: Edit changes v21.txt")
            let second = try await driver.send("Use the Edit tool to change the line in v21.txt from one to two (read the file first if the "
                                               + "tool needs that). Then reply with the single word: done")
            #expect(await rig.waitIdle(driver, 120))
            #expect(rig.read("v21.txt") == "two\n")

            // The dry run: the CLI names the file and the totals; Loom can keep a copy.
            let preview = try await driver.rewindPreview(userMessageID: second.id)
            rig.log("dry run: \(preview.files.count) file(s), +\(preview.insertions) -\(preview.deletions), copy \(preview.copy), path shapes \(preview.files.map { URL(fileURLWithPath: $0).lastPathComponent })")
            #expect(preview.files.map { URL(fileURLWithPath: $0).lastPathComponent } == ["v21.txt"])
            #expect(preview.insertions == 1 && preview.deletions == 1 && preview.canKeepCopy)
            #expect(rig.read("v21.txt") == "two\n")
            await #expect(throws: ChatRewindError.cannot(.noCheckpoint)) { try await driver.rewindPreview(userMessageID: UUID().uuidString.lowercased()) }

            // The marks, from the real transcript's edit records: as Claude left it, then changed by the user after 3 s.
            let conversation = try #require(await driver.liveState().conversationID)
            let transcript = try #require(ClaudeTranscriptLocator.locate(sessionID: conversation, configDirectory: rig.config,
                                                                         workingDirectory: rig.work.path))
            let scan = EditScan.scan(file: transcript, scope: .wholeSession)
            rig.log("edit scan: \(scan.files.count) file(s), last edit time known \(scan.files.first?.lastEdit?.timestamp != nil), truncated \(scan.truncated)")
            func marks() -> [String: RewindFileMark] {
                RewindOutsideChange.marks(files: preview.files, scan: scan) { path in
                    let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                    return RewindOutsideChange.FileState(exists: modified != nil, modified: modified)
                }
            }
            rig.log("marks before the user's edit: \(marks().values.map(\.text))")
            #expect(marks().isEmpty)
            try await Task.sleep(for: .seconds(3))
            try rig.write("v21.txt", "two\nthe user's own line\n")
            rig.log("marks after the user's edit: \(marks().values.map(\.text))")
            #expect(marks().values.first == .changedSinceClaude)

            // The real rewind restores the file Claude's tools touched, over the user's line; the copy holds the user's version.
            let result = try await driver.rewindFiles(userMessageID: second.id, messageTitle: "Use the Edit tool")
            #expect(rig.read("v21.txt") == "one\n")
            let manifest = try store.load(sessionID: await driver.snapshot().sessionID, rewindID: result.rewindID)
            rig.log("rewound: \(result.files.count) file(s); manifest completed \(manifest.completed), hash before == user's version \(manifest.files.first?.sha256 == ChatRewindStore.hash(Data("two\nthe user's own line\n".utf8)))")
            #expect(manifest.completed && manifest.files.first?.sha256 == ChatRewindStore.hash(Data("two\nthe user's own line\n".utf8)))
            #expect(manifest.files.first?.sha256After == ChatRewindStore.hash(Data("one\n".utf8)))
            #expect(await driver.openUndoRewindID() == result.rewindID)

            // Undo puts the user's version back from Loom's copy.
            let undone = try await driver.undoRewind(rewindID: result.rewindID)
            rig.log("undo restored \(undone.restored.count) file(s), trashed \(undone.trashed.count)")
            #expect(rig.read("v21.txt") == "two\nthe user's own line\n")
        }
    }

    /// Release C's real-Claude check, V21 after a resume (two Haiku turns, every card answered by the test): a Write makes
    /// `notes.txt` with ONE and an Edit makes it TWO; the session stops and resumes, so the second prompt is a row of the
    /// transcript's history (named by its record's uuid, read from the file) in a process that never saw it. "Rewind files to
    /// before this message" on that row: when the dry run lists `notes.txt` the rewind leaves ONE and Undo gives TWO back; when
    /// it lists nothing (or the CLI has no checkpoint for the message) the sheet says so and no file changes. The log records
    /// which of the three it was (`V21-RESUME OUTCOME`). Output: counts, booleans and hashes, no content.
    @Test func v21RewindFilesOfAHistoryRowAfterAResumeListsOrRefusesAndNeverTouchesAFileUnlessItRewindsIt() async throws {
        try await AccRig.run("v21-resume") { rig in
            let store = ChatRewindStore(directory: rig.root.appendingPathComponent("chat-rewinds", isDirectory: true), trash: { url in
                try FileManager.default.removeItem(at: url)
            })
            let driver = rig.driver(rewinds: store)
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "default"))

            rig.turn("V21 resume turn 1: Write creates notes.txt with ONE")
            try await driver.send("Use the Write tool to create the file notes.txt in the current folder with exactly one line: ONE. "
                                  + "Then reply with the single word: done")
            let first = await rig.waitIdleAnswering(driver, 120) { tool, _ in tool == "Write" }
            rig.log("turn 1 finished \(first.idle), approvals answered \(first.answered.sorted()), refused by the harness \(first.refused.sorted())")
            try #require(first.idle, "turn 1 did not end: the check stops here, with no further turn")
            let afterOne = try #require(rig.read("notes.txt"), "the Write made no notes.txt")
            #expect(afterOne.trimmingCharacters(in: .whitespacesAndNewlines) == "ONE")

            rig.turn("V21 resume turn 2: Edit changes notes.txt to TWO")
            let second = try await driver.send("Use the Edit tool to change the line in notes.txt from ONE to TWO (read the file first if the "
                                               + "tool needs that). Then reply with the single word: done")
            let next = await rig.waitIdleAnswering(driver, 120) { tool, _ in tool == "Edit" }
            rig.log("turn 2 finished \(next.idle), approvals answered \(next.answered.sorted()), refused by the harness \(next.refused.sorted())")
            try #require(next.idle, "turn 2 did not end: the check stops here, with no further turn")
            let afterTwo = try #require(rig.read("notes.txt"))
            #expect(afterTwo.trimmingCharacters(in: .whitespacesAndNewlines) == "TWO")
            let conversation = try #require(await driver.liveState().conversationID)

            // The session stops and resumes: a new process that never saw the prompt; the prompt is a row of the history.
            let report = try await driver.stop()
            rig.log("session stopped, succeeded \(report.succeeded), phase \(await driver.currentPhase)")
            try #require(report.succeeded)
            try await driver.resume()
            #expect(await rig.waitIdle(driver, 60))
            rig.log("session resumed, phase \(await driver.currentPhase), availability \(await driver.rewindAvailability())")
            let userRecords = rig.transcript(conversation).filter { record in
                guard (record["type"] as? String) == "user", (record["isMeta"] as? Bool) != true,
                      let message = record["message"], let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
                return String(decoding: data, as: UTF8.self).contains("from ONE to TWO")
            }
            let historyUUID = try #require(userRecords.first?["uuid"] as? String, "the second prompt is not in the transcript")
            rig.log("the second prompt's record in the transcript: \(userRecords.count) (want 1); its uuid is the id Loom sent \(historyUUID.lowercased() == second.id.lowercased())")
            #expect(userRecords.count == 1)
            let uuid = await driver.messageUUID(ofRow: historyUUID)

            // The dry run of "Rewind files to before this message" on that row.
            var outcome = "lists"
            var listed: [String] = []
            do {
                let preview = try await driver.rewindPreview(userMessageID: uuid)
                listed = preview.files.map { URL(fileURLWithPath: $0).lastPathComponent }
                outcome = listed.isEmpty ? "empty" : "lists"
                rig.log("dry run: \(preview.files.count) file(s) \(listed), +\(preview.insertions) -\(preview.deletions), copy \(preview.copy)")
            } catch let error as ChatRewindError {
                outcome = "cannot"
                rig.log("dry run refused: \(error) (the sheet would say it, no file is asked about)")
            }
            rig.log("V21-RESUME OUTCOME: \(outcome)")
            #expect(rig.read("notes.txt") == afterTwo, "the dry run changed a file")

            switch outcome {
            case "lists":
                #expect(listed == ["notes.txt"])
                let result = try await driver.rewindFiles(userMessageID: uuid, messageTitle: "Use the Edit tool")
                let rewound = rig.read("notes.txt")
                rig.log("rewound: \(result.files.count) file(s); notes.txt is back to the first version \(rewound == afterOne)")
                #expect(rewound == afterOne)
                #expect(await driver.openUndoRewindID() == result.rewindID)
                let undone = try await driver.undoRewind(rewindID: result.rewindID)
                rig.log("undo restored \(undone.restored.count) file(s), trashed \(undone.trashed.count); notes.txt is the second version again \(rig.read("notes.txt") == afterTwo)")
                #expect(rig.read("notes.txt") == afterTwo)
            default:
                // The sheet cannot confirm: "No files would change." for an empty list, the CLI's own text for a refusal. A real
                // rewind attempt is refused too, and still no file changes.
                do {
                    _ = try await driver.rewindFiles(userMessageID: uuid, messageTitle: "Use the Edit tool")
                    Issue.record("a rewind went through where the dry run listed nothing")
                } catch let error as ChatRewindError {
                    rig.log("a rewind attempt is refused: \(error)")
                }
                rig.log("notes.txt unchanged \(rig.read("notes.txt") == afterTwo)")
                #expect(rig.read("notes.txt") == afterTwo)
            }
        }
    }

    // MARK: V22 part 1. The quick question

    /// Release C, V22 part 1, against the real CLI (two Haiku turns and two side questions): a quick question while the session
    /// is idle and one while a Bash tool runs, each answered from the session's context, and the session's transcript is the
    /// same file before and after each (SHA-256), without the question in it. Output: counts, booleans and hashes, no content.
    @Test func v22aQuickQuestionAnswersWhileIdleAndWhileAToolRunsAndLeavesTheTranscriptAlone() async throws {
        try await AccRig.run("v22a-quick") { rig in
            try rig.write("note.txt", "The code word is PERSIMMON-42.\n")
            let driver = rig.driver()
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "default"))
            rig.turn("V22a turn 1: Read reads note.txt")
            try await driver.send("Use the Read tool on note.txt, then reply with the single word: done")
            #expect(await rig.waitIdle(driver, 120))
            let conversation = try #require(await driver.liveState().conversationID)
            func transcriptHash() -> String {
                let data = (try? Data(contentsOf: rig.transcriptURL(conversation))) ?? Data()
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            func milliseconds(_ since: ContinuousClock.Instant) -> Int {
                let elapsed = since.duration(to: .now)
                return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            }

            // Idle.
            let idleBefore = transcriptHash()
            let entriesBefore = await driver.snapshot().model.entries.map(\.id)
            rig.log("side question 1 of 2, idle; availability \(await driver.sideQuestionAvailability())")
            var clock = ContinuousClock.now
            let first = try await driver.sideQuestion("What is the code word you read in note.txt? Answer in one short sentence.")
            rig.log("side question 1 answered in \(milliseconds(clock)) ms, \(first.count) characters, names the code word \(first.contains("PERSIMMON"))")
            #expect(first.contains("PERSIMMON"))
            #expect(transcriptHash() == idleBefore)
            #expect(await driver.snapshot().model.entries.map(\.id) == entriesBefore)
            #expect(await driver.currentPhase == .ready)
            #expect(!rig.transcriptContains(conversation, "code word you read"))

            // While a Bash tool runs. The default mode asks before the command (in the first run the second question met that
            // waiting card, not a running tool): this one command is allowed once, so the tool really runs, and the question
            // is asked only when no card waits, the phase is working and the tool is running. Not `sleep`: Claude Code 2.1.300
            // blocks a standalone `sleep 60` before it runs ("Blocked: standalone sleep"), so a ping holds the tool ~44 s. By its
            // full path: the rig's PATH has no /sbin, so a plain `ping` failed at once and the model asked for another command.
            rig.turn("V22a turn 2: Bash pings for 44 s")
            try await driver.send("Use the Bash tool to run exactly: /sbin/ping -c 45 127.0.0.1 > /dev/null. Then reply with the single word: done")
            let card = await rig.waitRequest(driver, 45)
            rig.log("the profile asked before the Bash command: \(card != nil)")
            if let card { try await driver.answer(requestID: card.requestID, .allowOnce) }
            let running = await rig.wait(60) {
                let state = await driver.snapshot()
                return state.phase == .working && state.requests.isEmpty && state.model.tools.contains { $0.status == .running }
            }
            rig.log("a tool is running and no card waits: \(running)")
            #expect(running)
            // The transcript settles before it is hashed: first the Bash call's own record is in the file (it is written when the
            // call is made, before the tool runs), then the file stays the same for a second.
            func bashCallRecorded() -> Bool {
                rig.transcript(conversation).contains { record in
                    let content = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    return content.contains { ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == "Bash" }
                }
            }
            let recorded = await rig.wait(30) { bashCallRecorded() }
            rig.log("the Bash call's record is in the transcript: \(recorded)")
            #expect(recorded)
            var busyBefore = transcriptHash()
            var steady = false
            for _ in 0..<10 {
                try await Task.sleep(for: .seconds(1))
                let now = transcriptHash()
                if now == busyBefore { steady = true; break }
                busyBefore = now
            }
            rig.log("the transcript is steady before the question: \(steady)")
            #expect(steady)
            rig.log("side question 2 of 2, while the tool runs; availability \(await driver.sideQuestionAvailability())")
            clock = ContinuousClock.now
            let second = try await driver.sideQuestion("What is the code word you read in note.txt? Answer in one short sentence.")
            rig.log("side question 2 answered in \(milliseconds(clock)) ms, \(second.count) characters, names the code word \(second.contains("PERSIMMON"))")
            #expect(second.contains("PERSIMMON"))
            #expect(transcriptHash() == busyBefore)
            #expect(await driver.currentPhase == .working, "the question changed no phase")
            let stillRunning = await driver.snapshot().model.tools.contains { $0.status == .running }
            rig.log("the Bash tool still runs after the answer: \(stillRunning)")
            #expect(stillRunning, "the answer came after the tool, not while it ran")
            // Another card (the model trying a different command) is refused, so the turn ends instead of waiting on it.
            let end = await rig.waitIdleAnswering(driver, 120) { _, _ in false }
            rig.log("the turn ended \(end.idle); tools refused after the allowed command: \(end.refused.sorted())")
            #expect(end.idle)
            #expect(end.refused.isEmpty, "the model asked again after the allowed command")
            #expect(!rig.transcriptContains(conversation, "code word you read"))
            rig.log("transcript unchanged by both questions (hashes compared above); question text in the transcript: \(rig.transcriptContains(conversation, "code word you read"))")
        }
    }

    // MARK: A8. /clear

    @Test func a8ClearMovesTheRunToANewCardAndASendWorks() async throws {
        try await AccRig.run("a8-clear") { rig in
            let moves = Mutex<[UUID]>([])
            let driver = rig.driver(onMoved: { _, to in moves.withLock { $0.append(to) } })
            let first = await driver.sessionID
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "default"))
            let pid = await driver.snapshot().processID
            try await driver.send("/clear")
            let moved = await rig.wait(60) { await driver.sessionID != first }
            let card = await driver.sessionID
            rig.log("/clear: card changed \(moved), same process \(await driver.snapshot().processID == pid), phase \(await driver.currentPhase)")
            #expect(moved)
            #expect(await rig.waitIdle(driver, 30))
            // Release B fix round (F1): the CLI writes the reset, the SessionStart hook and `system/init`, and the hook and the
            // init carry the session the transcript is written under. Wait past a late second signal.
            try await Task.sleep(for: .seconds(3))
            rig.log("moves after one /clear: \(moves.withLock { $0.count }), the last one is the active card \(moves.withLock { $0.last } == card)")
            #expect(moves.withLock { $0 } == [card])
            rig.turn("A8 send on the new card")
            try await driver.send("Reply with the single word: pong")
            #expect(await rig.waitIdle(driver, 90))
            let snapshot = await driver.snapshot()
            rig.log("send on the new card: turn \(snapshot.model.turns.last.map { "\($0.status)" } ?? "-"), card is the new one \(snapshot.sessionID == card), markers \(snapshot.model.entries.compactMap { if case let .marker(m) = $0.body { "\(m)" } else { nil } }.count)")
            #expect(snapshot.model.turns.last?.status == .succeeded)
            // The card's conversation id is the one the transcript is written under, and no card is left without a transcript.
            let conversation = try #require(await driver.liveState().conversationID)
            let cards = try await rig.catalog.sessions().filter { $0.session.workingDirectory == rig.work.path }
                .compactMap(\.session.providerConversationID)
            rig.log("cards for the work folder \(cards.count); the active card's conversation has the pong in its transcript \(rig.transcriptContains(conversation, "pong")); every card but the first has a transcript \(cards.filter { rig.transcript($0).isEmpty }.count == 1)")
            #expect(rig.transcriptContains(conversation, "pong"))
            #expect(try await rig.catalog.session(id: card)?.session.providerConversationID == conversation)
            #expect(cards.count == 2)
            #expect(cards.filter { rig.transcript($0).isEmpty }.count <= 1)
        }
    }

    // MARK: A2b. A denied tool reads as denied (release B fix round, F2)

    @Test func a2bADeniedToolIsDeniedNotFailed() async throws {
        try await AccRig.run("a2-approval") { rig in
            let driver = rig.driver()
            try await driver.startNew(projectID: nil, draft: rig.draft(mode: "default"))
            rig.turn("A2b deny with a note: touch")
            try await driver.send("Use the Bash tool to run exactly: touch denied-b.txt. If it is refused, say so in one sentence.")
            let request = try #require(await rig.waitRequest(driver, 90))
            try await driver.answer(requestID: request.requestID, .deny(note: "NOTE-ACC-8: do not create files here"))
            #expect(await rig.waitIdle(driver, 90))
            let statuses = Self.toolStatuses(await driver.snapshot())
            rig.log("denied with a note: tool statuses \(statuses), denied-b.txt exists \(await rig.exists("denied-b.txt"))")
            #expect(statuses == ["Bash:denied"])
            #expect(await !rig.exists("denied-b.txt"))
        }
    }

    // MARK: Helpers

    static func keys(_ value: Any?) -> [String] {
        if let object = value as? [String: Any] { return object.keys.sorted() }
        if let json = value as? JSONValue, let object = json.object { return object.keys.sorted() }
        return []
    }

    /// The shape of an id, never the id: its length and which characters it uses.
    static func shape(_ id: String) -> String {
        let hex = id.allSatisfy { $0.isHexDigit || $0 == "-" }
        return "\(id.count) chars, \(hex ? "hex with dashes" : "other"), lowercase \(id == id.lowercased())"
    }

    static func delivery(_ snapshot: ChatDriverSnapshot, _ id: String) -> String {
        if let entry = snapshot.model.entry(id: id), case let .user(prompt) = entry.body { return "\(prompt.delivery)" }
        return "-"
    }

    static func toolStatuses(_ snapshot: ChatDriverSnapshot) -> [String] {
        snapshot.model.entries.compactMap { if case let .tool(call) = $0.body { "\(call.name):\(call.status)" } else { nil } }
    }

    static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func describe(_ value: JSONValue) -> String {
        switch value {
        case let .object(object): "{" + object.keys.sorted().map { "\($0): \(describe(object[$0]!))" }.joined(separator: ", ") + "}"
        case let .array(array): "array(\(array.count))"
        case .string: "string"
        case .bool: "bool"
        case .null: "null"
        default: "number"
        }
    }

    static func processes(matching text: String) async -> [Int32] {
        guard let found = try? await runToEnd("/usr/bin/pgrep", ["-f", "--", text]) else { return [] }
        let own = getpid()
        return found.outputText.split(separator: "\n").compactMap { Int32($0) }.filter { $0 != own }
    }
}

// MARK: - Raw client

/// A Chat-face child driven without `ChatSessionDriver` (the driver does not expose its channel): the same start, the same
/// `ControlChannel`, so the lines on the wire are the ones Loom writes. Every `can_use_tool` request is counted and denied.
private final class RawClient: Sendable {
    let id: UUID
    let channel: ControlChannel
    let log = WireLog()
    let requests = Mutex(0)
    private let tasks = Mutex<[Task<Void, Never>]>([])

    init(id: UUID, channel: ControlChannel) {
        self.id = id
        self.channel = channel
    }

    static func start(_ rig: AccRig, mode: String) async throws -> RawClient {
        let sink = ChatPipeSink()
        let id = UUID()
        let launched = try await rig.runtime.startChatConversation(
            projectID: nil, sessionID: id, draft: rig.draft(mode: mode), outputSink: sink)
        let client = RawClient(id: id, channel: ControlChannel())
        let channel = client.channel
        let writer = Task { for await line in channel.outgoing { do { try await launched.pipe.write(line) } catch { break } } }
        let reader = Task { [log = client.log] in
            for await input in sink.inputs {
                guard case let .frames(frames, _, bytes) = input else { continue }
                for frame in frames {
                    guard case let .message(message) = frame else { continue }
                    await channel.receive(message)
                    log.note(message)
                }
                sink.taken(bytes)
            }
        }
        let answerer = Task { [weak client] in
            for await event in channel.events {
                guard case let .request(request) = event, case .canUseTool = request.kind else { continue }
                client?.requests.withLock { $0 += 1 }
                _ = await channel.respond(to: request.requestID, with: .deny(message: "The harness answers no request in this check."))
            }
        }
        client.tasks.withLock { $0 = [writer, reader, answerer] }
        return client
    }

    deinit { tasks.withLock { $0.forEach { $0.cancel() } } }
}

// MARK: - Rig

private final class RealAnchor: NSObject {}

/// Counts and shapes of what a raw client (A5) read, never content.
private final class WireLog: Sendable {
    private struct State {
        var kinds: [String: Int] = [:]
        var task: String?
        var afterStop: [String: Int] = [:]
        var stopped = false
        var results = 0
    }

    private let state = Mutex(State())

    func note(_ message: StreamMessage) {
        state.withLock { state in
            var kind: String
            switch message {
            case let .taskStarted(task):
                kind = "system/task_started(background \(task.isBackgrounded), type \(task.taskType ?? "-"))"
                if task.isBackgrounded, state.task == nil { state.task = task.taskID }
            case let .unknown(unknown):
                kind = "\(unknown.type ?? "-")/\(unknown.subtype ?? "-")"
                if unknown.subtype == "background_tasks_changed", state.task == nil,
                   let id = unknown.raw["tasks"]?.array?.first?["task_id"]?.string { state.task = id }
                if unknown.subtype == "task_updated", let id = unknown.raw["task_id"]?.string, state.task == nil,
                   unknown.raw["patch"]?["is_backgrounded"]?.bool == true { state.task = id }
            case .result:
                kind = "result"
                state.results += 1
            case .assistant: kind = "assistant"
            case .user: kind = "user"
            case .streamEvent: return
            default: kind = "other"
            }
            state.kinds[kind, default: 0] += 1
            if state.stopped { state.afterStop[kind, default: 0] += 1 }
        }
    }

    func taskID() -> String? { state.withLock { $0.task } }
    func resultCount() -> Int { state.withLock { $0.results } }
    func kindsSeen() -> String { state.withLock { $0.kinds.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: "; ") } }
    func afterStopKinds() -> String {
        state.withLock { $0.afterStop.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: "; ") }
    }
    func markStopRequested() { state.withLock { $0.stopped = true } }
}

private struct UsageRow {
    var input: Int
    var cacheRead: Int
    var cacheCreation: Int
}

private final class AccRig: Sendable {
    let runtime: SessionRuntime
    let supervisor: ProcessSupervisor
    let catalog: SessionCatalog
    let config: URL
    let work: URL
    let root: URL
    let socketDirectory: URL
    let name: String
    let evidence: URL?
    let spiedIDs = Mutex<Set<String>>([])
    let turns = Mutex(0)

    init(runtime: SessionRuntime, supervisor: ProcessSupervisor, catalog: SessionCatalog, config: URL, work: URL, root: URL,
         socketDirectory: URL, name: String, evidence: URL?) {
        self.runtime = runtime
        self.supervisor = supervisor
        self.catalog = catalog
        self.config = config
        self.work = work
        self.root = root
        self.socketDirectory = socketDirectory
        self.name = name
        self.evidence = evidence
    }

    static func run(_ name: String, _ body: (AccRig) async throws -> Void) async throws {
        let rig = try await make(name)
        do {
            try await body(rig)
            let report = await rig.runtime.shutdown()
            rig.log("shutdown succeeded \(report.succeeded), model turns sent \(rig.turns.withLock { $0 })")
            rig.cleanup()
        } catch {
            _ = await rig.runtime.shutdown()
            rig.log("failed with \(error); model turns sent \(rig.turns.withLock { $0 })")
            rig.cleanup()
            throw error
        }
    }

    static func make(_ name: String) async throws -> AccRig {
        let env = ProcessInfo.processInfo.environment
        let config = URL(fileURLWithPath: try #require(env["LOOM_ACC_CLAUDE_CONFIG"]), isDirectory: true)
        let workRoot = try #require(env["LOOM_ACC_WORK_ROOT"])
        #expect(!workRoot.hasPrefix(NSHomeDirectory()))
        let folder = String(name.prefix { $0 != "-" })
        let sub = ["a1": "join", "a2": "approve", "a3": "qplan", "a4": "interrupt", "a5": "stoptask", "a6": "fullaccess",
                   "a7": "ask", "a7c": "askrules", "a8": "clear"][folder] ?? name
        let work = URL(fileURLWithPath: workRoot, isDirectory: true).appendingPathComponent(sub, isDirectory: true)
        try #require(FileManager.default.fileExists(atPath: work.path))
        let claude = env["LOOM_ACC_CLAUDE"] ?? "/opt/homebrew/bin/claude"
        let child = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(), "USER": NSUserName(),
                     "CLAUDE_CONFIG_DIR": config.path]
        var launchEnvironment = ["PATH": child["PATH"]!, "HOME": NSHomeDirectory(), "USER": NSUserName(),
                                 "LOGNAME": NSUserName(), "LANG": "en_US.UTF-8"]
        launchEnvironment["TMPDIR"] = env["TMPDIR"]
        let toolEnvironment = launchEnvironment
        let version = try await capture(claude, ["--version"], environment: child)
        let help = try await capture(claude, ["--help"], environment: child)
        let capabilities = ProviderCapabilities(version: version.trimmingCharacters(in: .whitespacesAndNewlines), help: help)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-acc-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socketDirectory = URL(fileURLWithPath: "/tmp/la-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let binaries = Bundle(for: RealAnchor.self).bundleURL.deletingLastPathComponent()
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let bundle = try RunScopeLauncher.assembleOwnedBundle(executable: binaries.appendingPathComponent("loom-run-host"), in: root)
        let supervisor = try await ProcessSupervisor.restoring(
            catalog: catalog,
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("rs")))
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: { provider in
                    ProviderToolchain(provider: provider, executable: claude, capabilities: capabilities,
                                      environment: toolEnvironment, profileDirectory: config, extraArguments: [])
                },
                hookHelperPath: binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: work.path, idlePolicy: SessionIdlePolicy(),
                codexIdentityTimeout: 3, claudeProfileDirectory: config,
                claudePluginDirectory: root.appendingPathComponent("claude-plugin", isDirectory: true),
                hookSilenceGrace: 10, catalogBackupDelay: nil))
        try await runtime.start()
        let evidence = env["LOOM_ACC_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return AccRig(runtime: runtime, supervisor: supervisor, catalog: catalog, config: config, work: work, root: root,
                      socketDirectory: socketDirectory, name: name, evidence: evidence)
    }

    private static func capture(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> String {
        try await runToEnd(executable, arguments, environment: environment).outputText
    }

    func cleanup() {
        RunScopeLauncher.removeOwnedBundle(in: root)
        try? FileManager.default.removeItem(at: socketDirectory)
        try? FileManager.default.removeItem(at: root)
    }

    func driver(rewinds: ChatRewindStore? = nil, onMoved: @escaping @Sendable (UUID, UUID) -> Void = { _, _ in }) -> ChatSessionDriver {
        ChatSessionDriver(sessionID: UUID(), runtime: runtime, rewindStore: rewinds, readyTimeout: .seconds(30), onMoved: onMoved)
    }

    func draft(mode: String) -> NewSessionLaunch {
        NewSessionLaunch(firstMessage: "", choices: ClaudeLaunchChoices(permissionMode: mode, model: "haiku"))
    }

    // MARK: Log and ledger

    func log(_ line: String) {
        let text = "[acc \(name)] \(line)"
        print(text)
        guard let evidence else { return }
        let url = evidence.appendingPathComponent("harness.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: url)
        }
    }

    func turn(_ purpose: String) {
        let count = turns.withLock { value -> Int in value += 1; return value }
        log("model turn \(count) of this check: \(purpose)")
    }

    // MARK: Waiting

    func wait(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    func waitIdle(_ driver: ChatSessionDriver, _ seconds: Double) async -> Bool {
        await wait(seconds) {
            let state = await driver.liveState()
            self.noteRequests(state.requests)
            return state.phase == .ready && !state.turnRunning
        }
    }

    /// The next request that waits for the user, without answering it.
    func waitRequest(_ driver: ChatSessionDriver, _ seconds: Double) async -> ChatPendingRequest? {
        var found: ChatPendingRequest?
        _ = await wait(seconds) {
            let requests = await driver.liveState().requests
            self.noteRequests(requests)
            found = requests.first
            return found != nil
        }
        return found
    }

    /// Waits for the turn to end while answering the approvals `allow` accepts (allow once); everything else is denied.
    func waitIdleAnswering(_ driver: ChatSessionDriver, _ seconds: Double,
                           allow: (String, JSONValue) -> Bool) async -> (idle: Bool, answered: Set<String>, refused: Set<String>) {
        var answered: Set<String> = [], refused: Set<String> = []
        let idle = await wait(seconds) {
            let state = await driver.liveState()
            self.noteRequests(state.requests)
            for request in state.requests {
                let tool = request.request.toolName
                if allow(tool, request.request.input) {
                    if (try? await driver.answer(requestID: request.requestID, .allowOnce)) != nil { answered.insert(tool) }
                } else {
                    if (try? await driver.answer(requestID: request.requestID, .deny(note: "Not part of this check."))) != nil {
                        refused.insert(tool)
                    }
                }
            }
            return state.phase == .ready && !state.turnRunning
        }
        return (idle, answered, refused)
    }

    private func noteRequests(_ requests: [ChatPendingRequest]) {
        for request in requests { spiedIDs.withLock { _ = $0.insert(request.requestID) } }
    }

    /// How many distinct requests reached Loom (counted at every poll of the waits and of `spyCount`).
    func spyCount(_ driver: ChatSessionDriver) -> Int { spiedIDs.withLock { $0.count } }

    // MARK: Work dir

    func write(_ relative: String, _ text: String) throws {
        let url = work.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ relative: String) -> String? {
        try? String(contentsOf: work.appendingPathComponent(relative), encoding: .utf8)
    }

    func exists(_ relative: String) async -> Bool { FileManager.default.fileExists(atPath: work.appendingPathComponent(relative).path) }

    /// Every file and folder under the work dir, with a hash of each file: "byte-identical" is a comparison of two of these.
    func digest() -> [String: String] {
        var result: [String: String] = [:]
        let base = work.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(atPath: work.path) else { return result }
        for case let relative as String in walker {
            var directory: ObjCBool = false
            let path = base + "/" + relative
            FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            if directory.boolValue { result[relative] = "dir"; continue }
            let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            result[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    // MARK: Transcript

    func transcriptURL(_ conversation: String) -> URL {
        let folder = String(work.path.unicodeScalars.map { scalar in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
        return config.appendingPathComponent("projects/\(folder)/\(conversation).jsonl")
    }

    func transcript(_ conversation: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: transcriptURL(conversation), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func transcriptContains(_ conversation: String, _ marker: String) -> Bool {
        (try? String(contentsOf: transcriptURL(conversation), encoding: .utf8))?.contains(marker) == true
    }

    /// Token counts of every assistant message of the main thread, in file order (numbers only).
    func usage(_ conversation: String) -> [UsageRow] {
        transcript(conversation).compactMap { record in
            guard record["type"] as? String == "assistant", record["isSidechain"] as? Bool != true,
                  let message = record["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return nil }
            return UsageRow(input: usage["input_tokens"] as? Int ?? 0, cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                            cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0)
        }
    }
}

private extension ChatSessionDriver {
    func hasToolEntry() -> Bool {
        snapshot().model.entries.contains { if case .tool = $0.body { true } else { false } }
    }
}
