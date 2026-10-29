import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomChatTestRigs

// Pinned cards, driver side (V18): what each answer sends the CLI and what it leaves in the stream (pure), and the rules a
// card lives by on the fake provider: the driver never answers, a card retires only on its own id or `tool_use_id`, a CLI
// cancel or the process ending (never on a `result`), and Stop interrupts first.

private let bashSuggestion: JSONValue = [
    "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "rm -rf build"]], "behavior": "allow",
    "destination": "localSettings",
]

private extension PermissionDecision {
    var fields: [String: JSONValue] { payload.object ?? [:] }
}

struct ChatRequestAnswerTests {
    @Test func allowOnceSendsTheOriginalInputAndNothingElse() throws {
        let request = ChatRequestCardsShared.pending("Bash", ChatRequestCardsShared.bashInput, suggestions: [bashSuggestion])
        let plan = try request.answerPlan(for: .allowOnce)
        #expect(plan.decision.fields["behavior"] == "allow")
        #expect(plan.decision.fields["updatedInput"] == ChatRequestCardsShared.bashInput)
        #expect(plan.decision.fields["updatedPermissions"] == nil)
        #expect(plan.decision.fields["toolUseID"] == "toolu_1")
        #expect(plan.record == RequestRecord(kind: .approval, summary: "Allowed once: rm -rf build"))
    }

    @Test func allowForTheSessionKeepsTheRequestsOwnSuggestionsForTheSessionOnly() throws {
        let request = ChatRequestCardsShared.pending("Bash", ChatRequestCardsShared.bashInput, suggestions: [bashSuggestion])
        #expect(request.canAllowForSession)
        let plan = try request.answerPlan(for: .allowForSession)
        let updates = plan.decision.fields["updatedPermissions"]?.array ?? []
        #expect(updates.count == 1)
        // The CLI's suggestion pointed at a settings file; the session is the only place this writes.
        #expect(updates.first?["destination"] == "session")
        #expect(updates.first?["type"] == "addRules")
        #expect(updates.first?["rules"]?.array?.first?["ruleContent"] == "rm -rf build")
        #expect(plan.record.summary == "Allowed for this session: Bash(rm -rf build)")

        // An edit's suggestion is a mode.
        let edit = ChatRequestCardsShared.pending("Edit", ["file_path": "/a.swift", "old_string": "a", "new_string": "b"],
                           suggestions: [["type": "setMode", "mode": "acceptEdits", "destination": "session"]])
        let editPlan = try edit.answerPlan(for: .allowForSession)
        #expect(editPlan.decision.fields["updatedPermissions"]?.array?.first?["mode"] == "acceptEdits")
        #expect(editPlan.record.summary == "Allowed for this session: Accept edits mode")
    }

    @Test func aToolWithoutSuggestionsGetsARuleForTheToolButACommandGetsNone() throws {
        let web = ChatRequestCardsShared.pending("WebFetch", ["url": "https://example.com/x"])
        let plan = try web.answerPlan(for: .allowForSession)
        let rule = plan.decision.fields["updatedPermissions"]?.array?.first
        #expect(rule?["destination"] == "session")
        #expect(rule?["rules"]?.array?.first?["toolName"] == "WebFetch")
        // A rule for the whole shell would allow every command: the CLI offers no such choice, and neither does the card.
        let bash = ChatRequestCardsShared.pending("Bash", ChatRequestCardsShared.bashInput)
        #expect(!bash.canAllowForSession)
        #expect(throws: ChatAnswerError.notOffered) { try bash.answerPlan(for: .allowForSession) }
    }

    @Test func aCommandThatRedirectsOutputOffersAllowOnceOnly() {
        let suggestions = [bashSuggestion]
        #expect(!ChatRequestCardsShared.pending("Bash", ["command": "echo hi > out.txt"], suggestions: suggestions).canAllowForSession)
        #expect(!ChatRequestCardsShared.pending("Bash", ["command": "make 2>> log.txt"], suggestions: suggestions).canAllowForSession)
        // A file descriptor merge is not a write to a file.
        #expect(ChatRequestCardsShared.pending("Bash", ["command": "make 2>&1 | tail"], suggestions: suggestions).canAllowForSession)
        #expect(ChatRequestCardsShared.pending("Bash", ["command": "make"], suggestions: suggestions).canAllowForSession)
    }

    @Test func denyCarriesTheNoteOrAShortDefaultAndDenyAndStopInterrupts() throws {
        let request = ChatRequestCardsShared.pending("Bash", ChatRequestCardsShared.bashInput)
        let noted = try request.answerPlan(for: .deny(note: "  use make clean  "))
        #expect(noted.decision == .deny(message: "use make clean", interrupt: false))
        #expect(noted.record.summary == "Denied: rm -rf build · use make clean")
        let plain = try request.answerPlan(for: .deny(note: nil))
        #expect(plain.decision == .deny(message: ChatRequestAnswer.defaultDenyMessage, interrupt: false))
        #expect(plain.record.summary == "Denied: rm -rf build")
        let blank = try request.answerPlan(for: .deny(note: "   "))
        #expect(blank.decision == .deny(message: ChatRequestAnswer.defaultDenyMessage, interrupt: false))
        let stop = try request.answerPlan(for: .denyAndStop(note: nil))
        #expect(stop.decision == .deny(message: ChatRequestAnswer.defaultDenyMessage, interrupt: true))
        #expect(stop.record.summary == "Denied and stopped: rm -rf build")
    }

    @Test func questionsAreAnsweredByTextAndNeverDismissed() throws {
        let questions: JSONValue = [
            ["question": "Which database?", "header": "Database", "multiSelect": false,
             "options": [["label": "SQLite", "description": "One file"], ["label": "Postgres", "description": "A server"]]],
            ["question": "Which extras?", "header": "Extras", "multiSelect": true,
             "options": [["label": "Logging", "description": "Logs"], ["label": "Metrics", "description": "Counters"]]],
        ]
        let request = ChatRequestCardsShared.pending("AskUserQuestion", ["questions": questions])
        #expect(request.kind == .question)
        #expect(request.questions.map(\.header) == ["Database", "Extras"])
        #expect(request.questions[1].multiSelect)

        let plan = try request.answerPlan(for: .answers([
            ChatQuestionAnswer(question: "Which database?", picks: ["SQLite"]),
            ChatQuestionAnswer(question: "Which extras?", picks: ["Logging", "Metrics"]),
        ]))
        let input = plan.decision.fields["updatedInput"]
        // The original input plus `answers`, keyed by the question's text; multi-select labels joined with ", ".
        #expect(input?["questions"] == questions)
        #expect(input?["answers"]?["Which database?"] == "SQLite")
        #expect(input?["answers"]?["Which extras?"] == "Logging, Metrics")
        #expect(plan.record.summary == "Asked: Database, Extras · You chose: SQLite / Logging, Metrics")

        // The user's own words replace the picks.
        let typed = try request.answerPlan(for: .answers([
            ChatQuestionAnswer(question: "Which database?", picks: ["SQLite"], other: "DuckDB"),
            ChatQuestionAnswer(question: "Which extras?", picks: ["Logging"]),
        ]))
        #expect(typed.decision.fields["updatedInput"]?["answers"]?["Which database?"] == "DuckDB")

        // Submit needs every question answered.
        #expect(throws: ChatAnswerError.incomplete) {
            try request.answerPlan(for: .answers([ChatQuestionAnswer(question: "Which database?", picks: ["SQLite"])]))
        }
        // No dismiss: a question has no plain Deny, only the answers or stopping the turn.
        #expect(throws: ChatAnswerError.notOffered) { try request.answerPlan(for: .deny(note: nil)) }
        #expect(throws: ChatAnswerError.notOffered) { try request.answerPlan(for: .allowOnce) }
        #expect(try request.answerPlan(for: .denyAndStop(note: nil)).decision == .deny(
            message: ChatRequestAnswer.defaultDenyMessage, interrupt: true))
    }

    @Test func aPlanAlwaysSendsTheChosenModeAndKeepPlanningDeniesWithFeedback() throws {
        let request = ChatRequestCardsShared.pending("ExitPlanMode", ["plan": "# Fake plan\n\n1. Do it.", "planFilePath": "/tmp/p.md"])
        #expect(request.kind == .plan)
        #expect(request.plan?.markdown.hasPrefix("# Fake plan") == true)
        for mode in ["default", "acceptEdits", "auto"] {
            let plan = try request.answerPlan(for: .approvePlan(mode: mode))
            let update = plan.decision.fields["updatedPermissions"]?.array?.first
            // A plain allow would return to the mode before planning, so the mode is sent every time, `default` included.
            #expect(update?["type"] == "setMode")
            #expect(update?["mode"] == .string(mode))
            #expect(update?["destination"] == "session")
            #expect(plan.mode == mode)
        }
        #expect(try request.answerPlan(for: .approvePlan(mode: "acceptEdits")).record.summary == "Approved the plan · Accept edits")
        let keep = try request.answerPlan(for: .keepPlanning(feedback: "Add a rollback step."))
        #expect(keep.decision == .deny(message: "Add a rollback step.", interrupt: false))
        #expect(keep.record.summary == "Kept planning: Add a rollback step.")
        #expect(try request.answerPlan(for: .keepPlanning(feedback: nil)).decision
            == .deny(message: ChatRequestAnswer.defaultFeedback, interrupt: false))
        // A plan is not an approval.
        #expect(throws: ChatAnswerError.notOffered) { try request.answerPlan(for: .allowOnce) }
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(4)))
struct ChatRequestDriverTests {
    private func waiting(_ driver: ChatSessionDriver, _ count: Int = 1) async -> Bool {
        await waitUntil {
            let snapshot = await driver.snapshot()
            return snapshot.requests.count == count && snapshot.phase == .needsYou
        }
    }

    private func toolOutputs(_ snapshot: ChatDriverSnapshot) -> [String] {
        snapshot.model.entries.compactMap { if case let .tool(call) = $0.body { call.output?.head } else { nil } }
    }

    private func records(_ snapshot: ChatDriverSnapshot) -> [String] {
        snapshot.model.entries.compactMap { if case let .request(record) = $0.body { record.summary } else { nil } }
    }

    @Test func eachCardKindIsAnsweredThroughTheDriverAndLeavesOneLineInTheStream() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)

        // An approval, allowed once.
        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        var request = try #require(await driver.snapshot().requests.first)
        #expect(request.agent == nil)
        try await driver.answer(requestID: request.requestID, .allowOnce)
        #expect(await idle(driver))
        #expect(await driver.snapshot().texts.last == "The build folder is gone.")

        // A file edit, allowed for the session: the CLI got the suggestion with the destination `session`.
        try await driver.send("/scenario approval edit")
        #expect(await waiting(driver))
        request = try #require(await driver.snapshot().requests.first)
        #expect(request.canAllowForSession)
        try await driver.answer(requestID: request.requestID, .allowForSession)
        #expect(await idle(driver))
        let granted = try #require(await driver.snapshot().texts.last)
        #expect(granted.contains("\"destination\":\"session\""), "\(granted)")
        #expect(granted.contains("acceptEdits"))

        // A command that redirects: the card offers Allow once only, and the driver refuses the other answer.
        try await driver.send("/scenario approval redirect")
        #expect(await waiting(driver))
        request = try #require(await driver.snapshot().requests.first)
        #expect(!request.canAllowForSession)
        await #expect(throws: ChatDriverError.notOffered) { try await driver.answer(requestID: request.requestID, .allowForSession) }
        #expect(await driver.snapshot().requests.count == 1)
        try await driver.answer(requestID: request.requestID, .allowOnce)
        #expect(await idle(driver))

        // A denial carries the note to Claude.
        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        request = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: request.requestID, .deny(note: "use make clean"))
        #expect(await idle(driver))
        #expect(toolOutputs(await driver.snapshot()).contains("use make clean"))
        #expect(await driver.snapshot().texts.last == "Understood, I left the build folder alone.")

        // A question.
        try await driver.send("/scenario question")
        #expect(await waiting(driver))
        request = try #require(await driver.snapshot().requests.first)
        await #expect(throws: ChatDriverError.incompleteAnswer) {
            try await driver.answer(requestID: request.requestID, .answers([ChatQuestionAnswer(question: "Which database should the app use?", picks: ["SQLite"])]))
        }
        try await driver.answer(requestID: request.requestID, .answers([
            ChatQuestionAnswer(question: "Which database should the app use?", picks: ["SQLite"]),
            ChatQuestionAnswer(question: "Which extras do you want?", picks: ["Logging", "Metrics"]),
        ]))
        #expect(await idle(driver))
        #expect(await driver.snapshot().texts.last == "You chose: SQLite; Logging, Metrics")

        // A plan: kept planning with feedback, then approved with the mode.
        try await driver.send("/scenario plan")
        #expect(await waiting(driver))
        request = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: request.requestID, .keepPlanning(feedback: "Add a rollback step."))
        #expect(await idle(driver))
        #expect(await driver.snapshot().texts.last == "Staying in plan mode.")
        try await driver.send("/scenario plan")
        #expect(await waiting(driver))
        request = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: request.requestID, .approvePlan(mode: "default"))
        #expect(await idle(driver))
        let done = await driver.snapshot()
        // `default` is sent too: the mode is the user's choice, not whatever Claude would fall back to.
        #expect(done.texts.last == "Implementing the plan in default mode.")
        #expect(done.permissionMode == "default")

        #expect(records(done) == [
            "Allowed once: rm -rf build",
            "Allowed for this session: Accept edits mode",
            "Allowed once: echo done > out.txt",
            "Denied: rm -rf build · use make clean",
            "Asked: Database, Extras · You chose: SQLite / Logging, Metrics",
            "Kept planning: Add a rollback step.",
            "Approved the plan · Ask before edits",
        ])
        #expect(done.settled.suffix(2).map(\.outcome) == [.answered, .answered])
        await rig.finish()
    }

    @Test func aRequestFromASubagentNamesTheSubagent() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario subagent 30 approval")
        #expect(await waiting(driver))
        let request = try #require(await driver.snapshot().requests.first)
        // `agent_id` joined with `task_started`: the request has no name of its own.
        #expect(request.agent?.type == "explorer")
        #expect(request.agent?.description == "Map the fake module")
        #expect(request.agent?.name == "explorer")
        try await driver.answer(requestID: request.requestID, .allowOnce)
        #expect(await idle(driver, 20))
        await rig.finish()
    }

    @Test func theDriverNeverAnswersAnyRequestKindInAnyMode() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        for mode in ["plan", "auto", "dontAsk", "acceptEdits", "bypassPermissions", "default"] {
            try await driver.setPermissionMode(mode)
            for scenario in ["approval", "question", "plan"] {
                try await driver.send("/scenario \(scenario)")
                #expect(await waiting(driver))
                try await Task.sleep(for: .milliseconds(250))
                let held = await driver.snapshot()
                #expect(held.requests.count == 1, "\(mode) \(scenario)")
                #expect(held.phase == .needsYou)
                #expect(await rig.status(id) == .waitingForApproval)
                // Only the user's answer ends it (here: stop the turn, so the next scenario starts clean).
                try await driver.answer(requestID: held.requests[0].requestID, .denyAndStop(note: nil))
                #expect(await idle(driver))
            }
        }
        // Not one of the 18 requests was answered but by the explicit call above.
        let outcomes = await driver.snapshot().settled.map(\.outcome)
        #expect(outcomes.allSatisfy { $0 == .answered })
        await rig.finish()
    }

    @Test func severalCardsRetireOnlyOnTheirOwnIdWhateverTheOrderOfTheAnswers() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approvals 3")
        #expect(await waiting(driver, 3))
        let all = await driver.snapshot().requests
        #expect(all.map(\.request.toolUseID).count == 3)
        #expect(Set(all.map(\.requestID)).count == 3)
        // Order of arrival.
        #expect(all.map { $0.request.input["command"]?.string } == ["make step1", "make step2", "make step3"])
        #expect(await rig.events.snapshot().sessions[id]?.pendingRequests.count == 3)

        // The second is answered first: only it leaves.
        try await driver.answer(requestID: all[1].requestID, .allowOnce)
        #expect(await waitUntil { await driver.snapshot().requests.count == 2 })
        #expect(await driver.snapshot().requests.map(\.requestID) == [all[0].requestID, all[2].requestID])
        #expect(await driver.currentPhase == .needsYou)
        #expect(await rig.status(id) == .waitingForApproval)
        #expect(await rig.events.snapshot().sessions[id]?.pendingRequests.map(\.requestID) == [all[0].requestID, all[2].requestID])

        // Answering an id that already left changes nothing.
        await #expect(throws: ChatDriverError.noSuchRequest(all[1].requestID)) {
            try await driver.answer(requestID: all[1].requestID, .allowOnce)
        }
        #expect(await driver.snapshot().requests.count == 2)

        try await driver.answer(requestID: all[0].requestID, .deny(note: "no"))
        #expect(await waitUntil { await driver.snapshot().requests.map(\.requestID) == [all[2].requestID] })
        // One still waits, so the session still reads Needs you.
        #expect(await driver.currentPhase == .needsYou)
        try await driver.answer(requestID: all[2].requestID, .allowOnce)
        #expect(await idle(driver))
        #expect(await driver.snapshot().texts.last == "2 of 3 steps ran.")
        #expect(await rig.events.snapshot().sessions[id]?.pendingRequests.isEmpty == true)
        await rig.finish()
    }

    @Test func aResultNeverRetiresACardOnlyItsOwnAnswerDoes() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario orphan")
        #expect(await waitUntil { await driver.snapshot().model.turns.last?.status == .succeeded })
        // The turn ended with its `result` while both requests still waited (the fake does what the CLI never does).
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = await driver.snapshot()
        #expect(snapshot.requests.count == 2, "the result retired a card")
        #expect(snapshot.settled.isEmpty)
        // The hub still says requests wait, whatever the work state last said.
        let hub = await rig.events.snapshot().sessions[id]
        #expect(hub?.pendingRequests.count == 2)
        #expect(hub?.waitingRequests.first?.summary == "make deploy")
        // A card's own answer retires it, and only it.
        try await driver.answer(requestID: snapshot.requests[0].requestID, .allowOnce)
        #expect(await driver.snapshot().requests.map(\.requestID) == [snapshot.requests[1].requestID])
        #expect(await driver.snapshot().settled.map(\.outcome) == [.answered])
        await rig.finish()
    }

    @Test func aFinishedToolCallRetiresItsOwnCardAndNoOther() async throws {
        let rig = try await Rig.make()
        let driver = rig.driver()
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario orphan resolve")
        #expect(await waitUntil { await driver.snapshot().model.turns.last?.status == .succeeded })
        #expect(await waitUntil { await driver.snapshot().requests.count == 1 })
        let snapshot = await driver.snapshot()
        // The first tool call's result arrived: its own card folded as resolved, the other still waits.
        #expect(snapshot.requests.first?.request.input["command"]?.string == "make notify")
        #expect(snapshot.settled.map(\.outcome) == [.resolved])
        #expect(snapshot.settled.first?.subject == "make deploy")
        // A tool row says how it ended; the stream gets no card line for it.
        #expect(records(snapshot).isEmpty)
        await rig.finish()
    }

    @Test func stopWithACardWaitingInterruptsFirstAndTheCardRetiresAsCancelled() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        let request = try #require(await driver.snapshot().requests.first)
        let report = try await driver.stop()
        #expect(report.succeeded)
        #expect(await waitUntil { await driver.currentPhase == .stopped })
        let snapshot = await driver.snapshot()
        #expect(snapshot.requests.isEmpty)
        let settled = try #require(snapshot.settled.last)
        #expect(settled.id == request.requestID)
        #expect(settled.outcome == .cancelled)
        #expect(settled.summary == "Cancelled: rm -rf build")
        #expect(records(snapshot) == ["Cancelled: rm -rf build"])
        // The interrupt went first: the turn ended as the user's stop. Closing stdin alone would have failed the tool and
        // let Claude carry on with a second try (S1 Q12).
        #expect(snapshot.model.turns.last?.status == .interrupted)
        #expect(snapshot.youStopped)
        #expect(!toolOutputs(snapshot).contains { $0.contains("stream closed") })
        #expect(await rig.events.snapshot().sessions[id]?.pendingRequests.isEmpty == true)
        await rig.finish()
    }

    @Test func anInterruptMakesTheCliWithdrawTheCardAndTheSessionGoesOn() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        let request = try #require(await driver.snapshot().requests.first)
        await driver.interrupt()
        #expect(await waitUntil { await driver.snapshot().requests.isEmpty })
        let snapshot = await driver.snapshot()
        // The CLI withdrew the request (control_cancel_request): the card is cancelled, the process lives on.
        let settled = try #require(snapshot.settled.last)
        #expect(settled.id == request.requestID && settled.outcome == .cancelled)
        #expect(records(snapshot) == ["Cancelled: rm -rf build"])
        #expect(snapshot.phase.isLive)
        #expect(await rig.events.snapshot().sessions[id]?.pendingRequests.isEmpty == true)
        // A later request is a card of its own again.
        try await driver.send("/scenario approval edit")
        #expect(await waiting(driver))
        #expect(await driver.snapshot().requests.first?.requestID != request.requestID)
        await rig.finish()
    }

    @Test func aCardKeepsItsPlaceWhenClaudeStopsOnItsOwnAndResumeClearsIt() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        let request = try #require(await driver.snapshot().requests.first)
        let pid = try #require(await driver.snapshot().processID)
        kill(pid, SIGKILL)
        #expect(await waitUntil { if case .failed = await driver.currentPhase { true } else { false } })
        var snapshot = await driver.snapshot()
        #expect(snapshot.requests.isEmpty)
        // Claude stopped before the user answered: the card is kept, as cut off, and the stream says so.
        let cut = try #require(snapshot.settled.last)
        #expect(cut.id == request.requestID)
        #expect(cut.outcome == .processEnded)
        #expect(records(snapshot) == ["Not answered, Claude stopped: rm -rf build"])
        #expect(await rig.events.snapshot().sessions[id]?.pendingRequests.isEmpty == true)
        // An answer to it goes nowhere.
        await #expect(throws: ChatDriverError.noSuchRequest(request.requestID)) {
            try await driver.answer(requestID: request.requestID, .allowOnce)
        }
        // Resume starts the session again, and the cut-off card goes.
        #expect(await waitUntil { await rig.supervisor.session(id: id)?.currentRun == nil })
        try await driver.resume()
        snapshot = await driver.snapshot()
        #expect(snapshot.phase == .ready)
        #expect(snapshot.settled.allSatisfy { $0.outcome != .processEnded })
        await rig.finish()
    }

    @Test func aHubSummaryReachesEveryConsumerThroughWaitingRequests() async throws {
        let rig = try await Rig.make()
        let id = UUID()
        let driver = rig.driver(id)
        try await driver.startNew(projectID: nil)
        try await driver.send("/scenario approval")
        #expect(await waiting(driver))
        let state = try #require(await rig.events.snapshot().sessions[id])
        #expect(state.waitingRequests.map(\.kind) == [.approval])
        #expect(state.waitingRequests.first?.summary == "rm -rf build")
        #expect(state.waitingRequests.first?.note == "Remove the build folder")
        let reason = try #require(state.displayReason)
        #expect(reason.kind == .approval(tool: "Bash"))
        #expect(reason.detail == "rm -rf build")
        #expect(reason.note == "Remove the build folder")
        try await driver.answer(requestID: try #require(await driver.snapshot().requests.first).requestID, .denyAndStop(note: nil))
        #expect(await idle(driver))
        #expect(await rig.events.snapshot().sessions[id]?.waitingRequests.isEmpty == true)
        await rig.finish()
    }
}
