import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomChatTestRigs

// The quick question (V22) on the driver, through the real runtime and the fake provider's scripted `side_question` answers
// (LOOM_FAKE_CHAT_SIDE_ANSWER, _SIDE_DELAY_MS, _SIDE): an answer while idle, while a card waits and while a turn works, and
// nothing else in the session changing; every refusal with its own error; the timeout, the error frame and a CLI that does
// not know the request.

/// A latch a test opens to let a parked task go on.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(5)))
struct ChatSideQuestionDriverTests {
    /// Everything a quick question must leave as it was.
    private struct Frozen: Equatable {
        var phase: ChatDriverPhase
        var turnRunning: Bool
        var requestIDs: [String]
        var queueIDs: [String]
        var entryIDs: [String]
        var mode: String?

        init(_ snapshot: ChatDriverSnapshot) {
            phase = snapshot.phase
            turnRunning = snapshot.turnRunning
            requestIDs = snapshot.requests.map(\.requestID)
            queueIDs = snapshot.queue.items.map(\.id)
            entryIDs = snapshot.model.entries.map(\.id)
            mode = snapshot.permissionMode
        }
    }

    private func frozen(_ driver: ChatSessionDriver) async -> Frozen { Frozen(await driver.snapshot()) }

    private func journalEvents(_ rig: Rig) -> [[String: Any]] {
        let journal = DiagnosticJournal.forDataRoot(rig.catalog.dataRoot)
        let text = (try? String(contentsOf: journal.currentURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["event"] as? String == "chat.sideQuestion" }
    }

    private func makeDriver(_ rig: Rig, journal: Bool = false) -> ChatSessionDriver {
        ChatSessionDriver(sessionID: UUID(), runtime: rig.runtime,
                          journal: journal ? DiagnosticJournal.forDataRoot(rig.catalog.dataRoot) : nil, readyTimeout: .seconds(20))
    }

    // MARK: Answers

    @Test func anIdleSessionAnswersAndNothingInItChangesNotEvenItsJournaledText() async throws {
        let rig = try await Rig.make()
        let driver = makeDriver(rig, journal: true)
        try await driver.startNew(projectID: nil)
        try await driver.send("hello")
        #expect(await idle(driver))
        let before = await frozen(driver)
        #expect(await driver.sideQuestionAvailability() == .available)

        let answer = try await driver.sideQuestion("  what is in the file?  ")
        #expect(answer == "Fake side answer to: what is in the file?")
        #expect(await frozen(driver) == before)
        #expect(await driver.snapshot().texts.allSatisfy { !$0.contains("what is in the file") })

        // The journal has the outcome and the latency, never the question or the answer.
        let events = journalEvents(rig)
        #expect(events.count == 1 && events.first?["outcome"] as? String == "answered" && events.first?["ms"] is Int)
        #expect(Set(events.first?.keys.map { $0 } ?? []) == ["event", "time", "outcome", "ms", "session"])
        _ = try await driver.stop()
        await rig.finish()
    }

    @Test func theScriptedAnswerAndItsDelayComeThroughAsTheCliWroteThem() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_SIDE_ANSWER": "**Done** in two lines.\nSecond line.",
                                                    "LOOM_FAKE_CHAT_SIDE_DELAY_MS": "400"])
        let driver = makeDriver(rig)
        try await driver.startNew(projectID: nil)
        let started = ContinuousClock.now
        let answer = try await driver.sideQuestion("anything")
        #expect(answer == "**Done** in two lines.\nSecond line.")
        #expect(started.duration(to: .now) >= .milliseconds(350))
        _ = try await driver.stop()
        await rig.finish()
    }

    @Test func aCardThatWaitsAndATurnThatWorksBothStillTakeAQuestionAndStayAsTheyWere() async throws {
        let rig = try await Rig.make()
        let driver = makeDriver(rig)
        try await driver.startNew(projectID: nil)

        // A turn works.
        try await driver.send("/scenario work 2500")
        #expect(await waitUntil { await driver.currentPhase == .working })
        var before = await frozen(driver)
        #expect(await driver.sideQuestionAvailability() == .available)
        #expect(try await driver.sideQuestion("during the turn") == "Fake side answer to: during the turn")
        let during = await frozen(driver)
        #expect(during.phase == before.phase && during.requestIDs == before.requestIDs && during.queueIDs == before.queueIDs)
        #expect(during.turnRunning)
        await driver.interrupt()
        #expect(await idle(driver))

        // A request waits for the user.
        try await driver.send("/scenario approval")
        #expect(await waitUntil { await driver.currentPhase == .needsYou })
        before = await frozen(driver)
        #expect(before.requestIDs.count == 1)
        #expect(try await driver.sideQuestion("while a card waits") == "Fake side answer to: while a card waits")
        #expect(await frozen(driver) == before)
        // The card is still there to answer, and the turn goes on to its end.
        let request = try #require(await driver.snapshot().requests.first)
        try await driver.answer(requestID: request.requestID, .deny(note: nil))
        #expect(await idle(driver))
        _ = try await driver.stop()
        await rig.finish()
    }

    // MARK: Refusals

    @Test func aStoppedSessionRefusesAndIsNeverResumedByTheQuestion() async throws {
        let rig = try await Rig.make()
        let driver = makeDriver(rig)
        // Never started.
        await #expect(throws: SideQuestionError.notAvailable(.stopped)) { try await driver.sideQuestion("hello?") }
        #expect(await driver.currentPhase == .stopped)

        // Stopped after a run: the question does not resume it.
        try await driver.startNew(projectID: nil)
        try await driver.send("hello")
        #expect(await idle(driver))
        _ = try await driver.stop()
        #expect(await driver.sideQuestionAvailability() == .stopped)
        await #expect(throws: SideQuestionError.notAvailable(.stopped)) { try await driver.sideQuestion("hello again?") }
        #expect(await driver.currentPhase == .stopped)
        #expect(await driver.snapshot().processID == nil)
        #expect(SideQuestionAvailability.stopped.reason == "Quick questions need a running Chat session")
        await rig.finish()
    }

    @Test func aSessionThatIsStartingRefusesWithItsOwnError() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_INIT_DELAY_MS": "1500"])
        let driver = makeDriver(rig)
        let start = Task { try await driver.startNew(projectID: nil) }
        #expect(await waitUntil { await driver.currentPhase == .starting })
        #expect(await driver.sideQuestionAvailability() == .launching)
        await #expect(throws: SideQuestionError.notAvailable(.launching)) { try await driver.sideQuestion("too early?") }
        _ = try await start.value
        #expect(try await driver.sideQuestion("now?") == "Fake side answer to: now?")
        _ = try await driver.stop()
        await rig.finish()
    }

    @Test func aHandoverToTheTerminalHoldsTheSessionAndTheQuestionIsRefused() async throws {
        let rig = try await Rig.make()
        let driver = makeDriver(rig)
        try await driver.startNew(projectID: nil)
        try await driver.send("hello")
        #expect(await idle(driver))
        let parked = Gate()
        await driver.setHandoverParked { await parked.wait() }
        let handover = Task { try await driver.handOverToTerminal() }
        #expect(await waitUntil { await driver.isHandingOver })
        #expect(await driver.currentPhase.isLive)
        #expect(await driver.sideQuestionAvailability() == .handover)
        await #expect(throws: SideQuestionError.notAvailable(.handover)) { try await driver.sideQuestion("while moving?") }
        await driver.cancelHandover()
        await parked.open()
        await #expect(throws: CancellationError.self) { try await handover.value }
        #expect(await driver.sideQuestionAvailability() == .available)
        #expect(try await driver.sideQuestion("after the move was cancelled") == "Fake side answer to: after the move was cancelled")
        _ = try await driver.stop()
        await rig.finish()
    }

    @Test func anEmptyQuestionIsRefusedBeforeAnythingIsSent() async throws {
        let rig = try await Rig.make()
        let driver = makeDriver(rig, journal: true)
        try await driver.startNew(projectID: nil)
        for empty in ["", "   ", "\n \t\n"] {
            await #expect(throws: SideQuestionError.emptyQuestion) { try await driver.sideQuestion(empty) }
        }
        #expect(journalEvents(rig).isEmpty, "nothing was asked, so nothing was journaled")
        _ = try await driver.stop()
        await rig.finish()
    }

    @Test func eachPhaseHasItsOwnAnswerToTheRule() {
        typealias Rule = SideQuestionAvailability
        #expect(Rule.of(phase: .stopped, handoverHolds: false) == .stopped)
        #expect(Rule.of(phase: .failed(.ended), handoverHolds: false) == .stopped)
        #expect(Rule.of(phase: .starting, handoverHolds: false) == .launching)
        #expect(Rule.of(phase: .stopping, handoverHolds: false) == .stopping)
        for phase in [ChatDriverPhase.ready, .working, .needsYou] {
            #expect(Rule.of(phase: phase, handoverHolds: false) == .available)
            #expect(Rule.of(phase: phase, handoverHolds: true) == .handover)
        }
        #expect(Rule.available.reason == nil)
        #expect(Set([Rule.launching, .stopping, .stopped, .handover].compactMap(\.reason)).count == 4)
    }

    // MARK: Failures

    @Test func noAnswerInTimeIsItsOwnErrorAndTheSessionGoesOnWorking() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_SIDE": "silent"])
        let driver = makeDriver(rig, journal: true)
        try await driver.startNew(projectID: nil)
        await driver.setSideQuestionTimeout(.milliseconds(400))
        let before = await frozen(driver)
        await #expect(throws: SideQuestionError.noAnswer) { try await driver.sideQuestion("anyone there?") }
        #expect(await frozen(driver) == before)
        #expect(SideQuestionError.noAnswer.text == "No answer came back. Try again.")
        #expect(journalEvents(rig).first?["outcome"] as? String == "timeout")
        // The session is fine: a turn runs.
        try await driver.send("still working?")
        #expect(await idle(driver))
        _ = try await driver.stop()
        await rig.finish()
    }

    @Test func anErrorFrameIsTheCliOwnMessageAndAnOldCliIsAnUnsupportedRequest() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_SIDE": "error"])
        let driver = makeDriver(rig, journal: true)
        try await driver.startNew(projectID: nil)
        await #expect(throws: SideQuestionError.failed("The side question could not be answered")) {
            try await driver.sideQuestion("will this fail?")
        }
        #expect(SideQuestionError.failed("The side question could not be answered").text == "The side question could not be answered")
        #expect(journalEvents(rig).first?["outcome"] as? String == "failed")
        _ = try await driver.stop()
        await rig.finish()

        let old = try await Rig.make(environment: ["LOOM_FAKE_CHAT_SIDE": "unsupported"])
        let oldDriver = makeDriver(old, journal: true)
        try await oldDriver.startNew(projectID: nil)
        await #expect(throws: SideQuestionError.unsupported) { try await oldDriver.sideQuestion("is this known?") }
        #expect(SideQuestionError.unsupported.text == "This Claude version has no quick questions")
        #expect(journalEvents(old).first?["outcome"] as? String == "unsupported")
        _ = try await oldDriver.stop()
        await old.finish()
    }

    @Test func aQuestionThatIsCancelledWhileWaitingEndsAsACancellationAndTellsTheCli() async throws {
        let rig = try await Rig.make(environment: ["LOOM_FAKE_CHAT_SIDE": "silent"])
        let driver = makeDriver(rig)
        try await driver.startNew(projectID: nil)
        let asking = Task { try await driver.sideQuestion("never answered") }
        try await Task.sleep(for: .milliseconds(300))
        asking.cancel()
        await #expect(throws: CancellationError.self) { try await asking.value }
        try await driver.send("the session still works")
        #expect(await idle(driver))
        _ = try await driver.stop()
        await rig.finish()
    }
}
