import Foundation
import Testing
import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

private final class RemoraModelAnchor: NSObject {}

/// L3a: the model's Remora API over a real host and the fake provider's Remora mode. No real Claude, no real profile, and no
/// view: the state the UI will observe is read directly.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct RemoraModelTests {
    /// A model, a host over a temporary data root, the fake provider and a list of one session.
    @MainActor
    private final class Rig {
        let supervisor: ProcessSupervisor
        let model: CatalogModel
        private(set) var host: RemoraHost?
        let project = UUID()
        let session = UUID()
        var remora: URL { root.appendingPathComponent("remora") }
        var preferencesURL: URL { root.appendingPathComponent("ui-preferences.json") }
        var pids: URL { root.appendingPathComponent("fake-pid") }
        var log: URL { root.appendingPathComponent("fake-log.json") }

        let root: URL

        /// `root`: an earlier rig's data root, for a relaunch (the same folder, a new model and a new host).
        init(script: [String: String] = [:], withHost: Bool = true, root existing: URL? = nil) throws {
            root = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-model-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            supervisor = try ProcessSupervisor(ledger: OwnershipLedger())
            let store = UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json"))
            model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: store)
            guard withHost else { return }
            let now = Date()
            let moved = now.addingTimeInterval(-3_600)
            let summary = SessionSummary(id: session, harness: .claude, title: "Billing", projectID: project, projectName: "loom",
                                         state: .idle, face: nil, lastActivityAt: moved)
            let maps = RemoraCatalogMaps(sessionProjects: [session: project], projectNames: [project: "loom"], recency: [(project, moved)])
            var environment = ["LOOM_FAKE_REMORA_LOG": log.path, "LOOM_FAKE_PIDFILE": pids.path]
            environment.merge(script) { _, new in new }
            let supervisor = supervisor
            let work = remora.appendingPathComponent("run")
            let fake = Bundle(for: RemoraModelAnchor.self).bundleURL.deletingLastPathComponent()
                .appendingPathComponent("loom-fake-provider").path
            let extra = environment
            let created = RemoraHost(
                dataRoot: root, settings: model.remora.preferences,
                sessions: { _ in [summary] }, transcript: { _ in nil }, maps: { maps },
                makeCall: { usage in
                    RemoraCall(supervisor: supervisor, executable: fake,
                               environment: RemoraCall.environment(from: ["PATH": "/usr/bin:/bin"], configDirectory: nil),
                               workingDirectory: work, usage: usage, questionDeadline: 20, briefDeadline: 20,
                               terminationGrace: 1, additionalEnvironment: extra)
                })
            host = created
            model.installRemora(host: created)
        }

        var ranAProcess: Bool {
            FileManager.default.fileExists(atPath: pids.path) || FileManager.default.fileExists(atPath: log.path)
        }

        func pid() async -> Int32? {
            for _ in 0..<500 {
                if let text = try? String(contentsOf: pids, encoding: .utf8), let value = Int32(text) { return value }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }

        func finish() async {
            model.stop()
            _ = await supervisor.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Calls

    @Test func theStateMovesFromIdleToAskingAndBackWithTheAnswerAndTheUse() async throws {
        let rig = try Rig(script: ["LOOM_FAKE_REMORA_ANSWER": "Hello there"])
        let remora = rig.model.remora
        #expect(remora.phase == .idle && !remora.isBusy && remora.usage == nil)
        #expect(rig.model.askRemora("What moved?"))
        #expect(remora.phase == .asking && remora.isBusy)
        // One at a time: nothing else starts while it runs.
        #expect(!rig.model.askRemora("And now?"))
        #expect(!rig.model.briefRemora())
        await remora.settle()
        #expect(remora.phase == .idle)
        #expect(remora.lastAnswer?.answer.text == "Hello there" && remora.streamedText == "Hello there")
        #expect(remora.lastFailure == nil)
        #expect(remora.usage?.today.questions == 1 && remora.usage?.today.tokens.total == 1_266)
        #expect(remora.usage?.cacheDriftCalls == 0)
        await rig.finish()
    }

    @Test func aFailureShowsItsKindAndLeavesTheModelIdle() async throws {
        let rig = try Rig(script: ["LOOM_FAKE_REMORA": "login"])
        let remora = rig.model.remora
        #expect(rig.model.askRemora("What moved?"))
        await remora.settle()
        #expect(remora.phase == .idle)
        #expect(remora.lastFailure == .notLoggedIn)
        #expect(remora.lastAnswer == nil)
        // The next call starts clean.
        #expect(rig.model.askRemora("Again?"))
        #expect(remora.lastFailure == nil)
        await remora.settle()
        await rig.finish()
    }

    @Test func stopEndsTheCallAndShowsNoFailure() async throws {
        let rig = try Rig(script: ["LOOM_FAKE_REMORA": "slow"])
        let remora = rig.model.remora
        #expect(rig.model.askRemora("What moved?"))
        let pid = try #require(await rig.pid())
        rig.model.stopRemora()
        await remora.settle()
        #expect(remora.phase == .idle && remora.lastFailure == nil && remora.lastAnswer == nil)
        var gone = false
        for _ in 0..<800 where !gone {
            gone = kill(pid, 0) != 0 && errno == ESRCH
            if !gone { try? await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(gone, "the child outlived stop")
        await rig.finish()
    }

    @Test func rememberThroughTheModelSavesWithAnUndoAndMakesNoCall() async throws {
        let rig = try Rig()
        let remora = rig.model.remora
        #expect(rig.model.askRemora("Remember that I prefer tabs"))
        await remora.settle()
        #expect(remora.lastRemembered == "I prefer tabs" && remora.lastUndo != nil && !rig.ranAProcess)
        let token = try #require(remora.lastUndo)
        rig.model.undoRemora(token)
        await remora.settle()
        #expect(remora.lastUndo == nil)
        #expect(!(try String(contentsOf: rig.remora.appendingPathComponent("Remora.md"), encoding: .utf8).contains("I prefer tabs")))
        await rig.finish()
    }

    @Test func aProposedFactIsConfirmedIntoTheNoteOrDismissed() async throws {
        let answer = "Done.\n\n```remora\n{\"cited\":[],\"facts\":[\"Prefers short answers\",\"Works in Istanbul\"]}\n```"
        let rig = try Rig(script: ["LOOM_FAKE_REMORA_ANSWER": answer])
        let remora = rig.model.remora
        #expect(rig.model.askRemora("What moved?"))
        await remora.settle()
        #expect(remora.proposedFacts == ["Prefers short answers", "Works in Istanbul"])
        rig.model.dismissRemoraFact("Works in Istanbul")
        rig.model.confirmRemoraFact("Prefers short answers")
        await remora.settle()
        #expect(remora.proposedFacts.isEmpty && remora.lastRemembered == "Prefers short answers" && remora.lastUndo != nil)
        let note = try String(contentsOf: rig.remora.appendingPathComponent("Remora.md"), encoding: .utf8)
        #expect(note.contains("Prefers short answers") && !note.contains("Istanbul"))
        await rig.finish()
    }

    // MARK: The automatic brief

    @Test func theAutomaticBriefStartsOnlyWhenOnlineAndDueAndTheModelShowsItsPhaseOnlyThen() async throws {
        let rig = try Rig()
        let remora = rig.model.remora
        // Offline (L3b's one check says so): nothing starts and nothing is recorded.
        #expect(!rig.model.briefRemoraIfDue(homeShown: true, isOnline: false))
        #expect(remora.phase == .idle && !rig.ranAProcess)
        #expect(!FileManager.default.fileExists(atPath: rig.remora.appendingPathComponent("last-brief.json").path))
        // When I ask: the schedule never runs it.
        rig.model.setRemoraBriefMode(.whenIAsk)
        await remora.settle()
        #expect(rig.model.briefRemoraIfDue(homeShown: true))
        #expect(remora.phase == .idle, "a decision that runs nothing showed a phase")
        await remora.settle()
        #expect(!rig.ranAProcess && remora.lastAnswer == nil)
        // Automatic, Home shown: the brief runs and records its day.
        rig.model.setRemoraBriefMode(.automatic)
        await remora.settle()
        #expect(rig.model.briefRemoraIfDue(homeShown: true))
        await remora.settle()
        #expect(remora.lastAnswer?.kind == .brief && remora.phase == .idle)
        #expect(FileManager.default.fileExists(atPath: rig.remora.appendingPathComponent("last-brief.json").path))
        await rig.finish()
    }

    @Test func theFiveHourShareComesFromTheLimitsAndAnUnknownWindowIsNil() {
        let now = Date()
        let low = PlanLimits(fiveHour: PlanLimitWindow(usedPercent: 95, resetsAt: now.addingTimeInterval(3_600)), weekly: nil, fetchedAt: now)
        #expect(CatalogModel.remainingFiveHourShare(of: low, now: now) == 0.05)
        let over = PlanLimits(fiveHour: PlanLimitWindow(usedPercent: 95, resetsAt: now.addingTimeInterval(-60)), weekly: nil, fetchedAt: now)
        #expect(CatalogModel.remainingFiveHourShare(of: over, now: now) == nil)
        #expect(CatalogModel.remainingFiveHourShare(of: PlanLimits(fiveHour: nil, weekly: nil, fetchedAt: now), now: now) == nil)
        #expect(CatalogModel.remainingFiveHourShare(of: nil, now: now) == nil)
    }

    // MARK: Settings

    @Test func theSettingsRoundTripThroughThePreferencesFileAndAnOldFileStillDecodes() async throws {
        let rig = try Rig(withHost: false)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = rig.model
        #expect(model.remora.preferences == RemoraPreferences())
        let project = UUID()
        let note = rig.root.appendingPathComponent("vault/Remora.md")
        model.setRemoraOn(false)
        model.setRemoraModel("haiku")
        model.setRemoraEffort("high")
        model.setRemoraBriefMode(.whenIAsk)
        model.setRemoraProposals(false)
        model.setRemoraWindowThreshold(0.3)
        model.setRemoraExcluded(project, true)
        model.setRemoraNoteFile(note)
        let expected = RemoraPreferences(isOn: false, model: "haiku", effort: "high", briefMode: .whenIAsk, excludedProjects: [project],
                                         proposals: false, windowThreshold: 0.3, noteFilePath: note.path)
        #expect(model.remora.preferences == expected)
        #expect(UIPreferencesStore(url: rig.preferencesURL).current.remora == expected)
        let again = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: rig.preferencesURL))
        #expect(again.remora.preferences == expected)
        model.setRemoraExcluded(project, false)
        #expect(UIPreferencesStore(url: rig.preferencesURL).current.remora.excludedProjects.isEmpty)

        // A file from before Remora, and one whose Remora value is unusable, read as the defaults.
        let old = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"viewMode":"projects","sidebarWidth":340}"#.utf8))
        #expect(old.remora == RemoraPreferences() && old.sidebarWidth == 340)
        let broken = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"remora":{"isOn":"yes","model":3},"viewMode":"projects"}"#.utf8))
        #expect(broken.remora == RemoraPreferences() && broken.viewMode == .projects)
        let notAnObject = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"remora":"on"}"#.utf8))
        #expect(notAnObject.remora == RemoraPreferences())
    }

    @Test func withoutAHostNothingRunsAndEveryMethodRefusesQuietly() async throws {
        let rig = try Rig(withHost: false)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let model = rig.model
        #expect(!model.hasRemora)
        #expect(!model.askRemora("What moved?") && !model.askRemora("Remember that x") && !model.briefRemora())
        #expect(!model.briefRemoraIfDue(homeShown: true))
        model.stopRemora()
        model.confirmRemoraFact("a fact")
        model.editRemoraNote(project: UUID(), text: "x")
        model.removeRemoraNote(project: UUID())
        model.clearRemoraWorkingMemory()
        model.refreshRemoraUsage()
        #expect(await model.remoraNotes().isEmpty)
        #expect(await model.remoraJournalDays().isEmpty)
        await model.remora.settle()
        #expect(model.remora.phase == .idle && model.remora.lastAnswer == nil && model.remora.usage == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.remora.path))
    }

    @Test func offRefusesAsksAndExcludingAProjectDeletesItsNote() async throws {
        let rig = try Rig()
        let remora = rig.model.remora
        let host = try #require(rig.host)
        let kept = UUID()
        let seed = try RemoraMemory(directory: rig.remora)
        let item = RemoraNoteItem(text: "Waits on review", sessions: [rig.session])
        try await seed.replaceNote(project: rig.project, items: [item])
        try await seed.replaceNote(project: kept, items: [item])
        rig.model.setRemoraExcluded(rig.project, true)
        await remora.settle()
        #expect(host.settings.excludedProjects == [rig.project])
        #expect(await rig.model.remoraNotes().map(\.project) == [kept])
        rig.model.setRemoraOn(false)
        await remora.settle()
        #expect(!rig.model.askRemora("What moved?") && !rig.ranAProcess)
        await rig.finish()
    }

    @Test func aNewNoteFileIsWhatARememberOrderWritesTo() async throws {
        let rig = try Rig()
        let remora = rig.model.remora
        let elsewhere = rig.root.appendingPathComponent("chosen/Remora.md")
        rig.model.setRemoraNoteFile(elsewhere)
        await remora.settle()
        #expect(rig.model.askRemora("Remember that the vault is mine"))
        await remora.settle()
        #expect(try String(contentsOf: elsewhere, encoding: .utf8).contains("the vault is mine"))
        #expect(!FileManager.default.fileExists(atPath: rig.remora.appendingPathComponent("Remora.md").path))
        await rig.finish()
    }

    // MARK: L3a2: the decision, the stop, the reading, the kept brief and the language

    /// Short and slow: the fake's two 400 ms pauses are the window a test has to stop it.
    private static let slow = ["LOOM_FAKE_REMORA": "slow", "LOOM_FAKE_REMORA_ANSWER": "Hello there"]

    @Test func theLastScheduleDecisionIsKeptWithItsReasonAndAStartedBriefClearsIt() async throws {
        let rig = try Rig()
        let remora = rig.model.remora
        #expect(remora.lastBriefDecision == nil)
        rig.model.setRemoraBriefMode(.whenIAsk)
        await remora.settle()
        #expect(rig.model.briefRemoraIfDue(homeShown: true))
        await remora.settle()
        #expect(remora.lastBriefDecision == .skip(.whenIAsk) && remora.phase == .idle && !rig.ranAProcess)
        // A wait carries its reason (the host's `.notDue(.wait)` goes through the same `finish`).
        remora.finish(.notDue(.wait(.windowLow(remaining: 0.05))))
        #expect(remora.lastBriefDecision == .wait(.windowLow(remaining: 0.05)))
        // The newest decision replaces it.
        rig.model.setRemoraBriefMode(.automatic)
        await remora.settle()
        #expect(rig.model.briefRemoraIfDue(homeShown: false))
        await remora.settle()
        #expect(remora.lastBriefDecision == .skip(.homeNotShown))
        // A brief that starts clears it, the automatic one and the asked one alike.
        #expect(rig.model.briefRemoraIfDue(homeShown: true))
        await remora.settle()
        #expect(remora.lastAnswer?.kind == .brief && remora.lastBriefDecision == nil)
        remora.finish(.notDue(.skip(.alreadyBriefedToday)))
        #expect(remora.lastBriefDecision == .skip(.alreadyBriefedToday))
        #expect(rig.model.briefRemora())
        #expect(remora.lastBriefDecision == nil)
        await remora.settle()
        await rig.finish()
    }

    @Test func aStoppedCallLeavesItsKindAndTheNextCallClearsIt() async throws {
        let rig = try Rig(script: Self.slow)
        let remora = rig.model.remora
        #expect(remora.stopped == nil)
        #expect(rig.model.askRemora("What moved?"))
        _ = try #require(await rig.pid())
        rig.model.stopRemora()
        await remora.settle()
        #expect(remora.stopped == .question && remora.lastFailure == nil && remora.phase == .idle)
        try? FileManager.default.removeItem(at: rig.pids)
        #expect(rig.model.briefRemora())
        #expect(remora.stopped == nil, "the next call started with the old stop")
        _ = try #require(await rig.pid())
        rig.model.stopRemora()
        await remora.settle()
        #expect(remora.stopped == .brief)
        // A call that ends well leaves no stop.
        #expect(rig.model.askRemora("Once more?"))
        await remora.settle()
        #expect(remora.stopped == nil && remora.lastAnswer?.answer.text == "Hello there")
        await rig.finish()
    }

    @Test func turningRemoraOffOrExcludingAProjectDuringACallIsAStopToo() async throws {
        let off = try Rig(script: Self.slow)
        #expect(off.model.briefRemora())
        _ = try #require(await off.pid())
        off.model.setRemoraOn(false)
        await off.model.remora.settle()
        #expect(off.model.remora.stopped == .brief && off.model.remora.phase == .idle)
        await off.finish()

        let excluded = try Rig(script: Self.slow)
        #expect(excluded.model.askRemora("What moved?"))
        _ = try #require(await excluded.pid())
        excluded.model.setRemoraExcluded(excluded.project, true)
        await excluded.model.remora.settle()
        #expect(excluded.model.remora.stopped == .question)
        await excluded.finish()
    }

    @Test func theReadingCountsAreSetBeforeTheCallStartsAndClearAtItsEnd() async throws {
        let rig = try Rig(script: Self.slow)
        let remora = rig.model.remora
        let seed = try RemoraMemory(directory: rig.remora)
        try await seed.replaceNote(project: rig.project, items: [RemoraNoteItem(text: "Waits on review", sessions: [rig.session])])
        #expect(remora.reading == nil)
        #expect(rig.model.askRemora("What moved?"))
        _ = try #require(await rig.pid())
        #expect(remora.phase == .asking, "the call was over before the counts were looked at")
        #expect(remora.reading == RemoraReading(sessions: 0, projectNotes: 1, project: nil))
        await remora.settle()
        #expect(remora.reading == nil && remora.phase == .idle)

        // A scoped question carries its project's id and name.
        try? FileManager.default.removeItem(at: rig.pids)
        #expect(rig.model.askRemora("What moved here?", scope: .project(rig.project)))
        _ = try #require(await rig.pid())
        #expect(remora.reading == RemoraReading(sessions: 0, projectNotes: 1, project: .init(id: rig.project, name: "loom")))
        await remora.settle()
        #expect(remora.reading == nil)

        // A "Remember …" makes no pack: nothing was reported.
        #expect(rig.model.askRemora("Remember that I prefer tabs"))
        #expect(remora.reading == nil)
        await remora.settle()
        #expect(remora.reading == nil)
        await rig.finish()
    }

    @Test func theDaysBriefIsReadOnFirstUseAfterARelaunchAndGoesWithClearOrAnExclusion() async throws {
        let first = try Rig(script: ["LOOM_FAKE_REMORA_ANSWER": "Billing waits.\n\n```remora\n{\"cited\":[],\"chips\":[],\"facts\":[]}\n```"])
        #expect(first.model.remora.keptBrief == nil)
        await first.model.loadRemoraKeptBrief()
        #expect(first.model.remora.keptBrief == nil, "there was nothing to read")
        #expect(first.model.briefRemora())
        await first.model.remora.settle()
        let kept = try #require(first.model.remora.keptBrief, "a brief that answered is the day's")
        #expect(kept.text == "Billing waits." && kept.footer.hasPrefix("read 0 sessions and 0 project notes"))
        let mode = try #require(try FileManager.default.attributesOfItem(
            atPath: first.remora.appendingPathComponent("day-brief.json").path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)

        // The relaunch: a new model and host over the same folder. Nothing is read until the model is asked to.
        let second = try Rig(root: first.root)
        #expect(second.model.remora.keptBrief == nil)
        await second.model.loadRemoraKeptBrief()
        #expect(second.model.remora.keptBrief == kept)

        // Clear removes it, from disk and from the model's copy.
        second.model.clearRemoraWorkingMemory()
        await second.model.remora.settle()
        #expect(second.model.remora.keptBrief == nil)
        #expect(!FileManager.default.fileExists(atPath: second.remora.appendingPathComponent("day-brief.json").path))
        await second.finish()
        await first.finish()
    }

    @Test func aNewExclusionOfTheBriefsProjectReloadsTheModelsCopyAsEmpty() async throws {
        let rig = try Rig(script: ["LOOM_FAKE_REMORA_ANSWER": "Billing waits."])
        #expect(rig.model.briefRemora())
        await rig.model.remora.settle()
        // The one session the brief read is none (no transcript); name the rig's session so the brief belongs to its project.
        let file = rig.remora.appendingPathComponent("day-brief.json")
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var named = stored
        named["sessions"] = [rig.session.uuidString]
        try JSONSerialization.data(withJSONObject: named).write(to: file)
        await rig.model.loadRemoraKeptBrief()
        #expect(rig.model.remora.keptBrief?.readSessionIDs == [rig.session])
        rig.model.setRemoraExcluded(UUID(), true)
        await rig.model.remora.settle()
        #expect(rig.model.remora.keptBrief != nil, "a project the brief never read removed it")
        rig.model.setRemoraExcluded(rig.project, true)
        await rig.model.remora.settle()
        #expect(rig.model.remora.keptBrief == nil && !FileManager.default.fileExists(atPath: file.path))
        await rig.finish()
    }

    @Test func theBriefLanguageIsASettingThatRoundTripsAndReachesTheHost() async throws {
        let rig = try Rig()
        let model = rig.model
        #expect(model.remora.preferences.language == nil)
        model.setRemoraLanguage("tr")
        await model.remora.settle()
        #expect(model.remora.preferences.language == "tr" && rig.host?.settings.language == "tr")
        #expect(UIPreferencesStore(url: rig.preferencesURL).current.remora.language == "tr")
        let again = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: rig.preferencesURL))
        #expect(again.remora.preferences.language == "tr")
        // Another setting keeps it, and a value that is no language tag is none.
        model.setRemoraProposals(false)
        #expect(model.remora.preferences.language == "tr")
        model.setRemoraLanguage("not a language")
        #expect(model.remora.preferences.language == nil)
        model.setRemoraLanguage("tr")
        model.setRemoraLanguage(nil)
        await model.remora.settle()
        #expect(model.remora.preferences.language == nil && rig.host?.settings.language == nil)
        await rig.finish()
    }

    // MARK: The development hold (a plain evidence launch holds Remora Off)

    /// A data root whose preferences file says Remora is on, as a seeded or earlier run left it.
    private static func rootWithRemoraOn() throws -> (root: URL, bytes: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-hold-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data(#"{"remora":{"isOn":true},"sidebarWidth":300}"#.utf8)
        try bytes.write(to: root.appendingPathComponent("ui-preferences.json"))
        return (root, bytes)
    }

    @Test func theHoldStopsEveryCallAndLeavesThePreferencesFileAsItWas() async throws {
        let seeded = try Self.rootWithRemoraOn()
        let rig = try Rig(root: seeded.root)
        let remora = rig.model.remora
        #expect(remora.preferences.isOn)
        rig.model.holdRemoraOff()
        await remora.settle()
        #expect(!remora.preferences.isOn && rig.host?.settings.isOn == false)
        // The same setup as the automatic brief's test: Home shown, online, due.
        #expect(!rig.model.briefRemoraIfDue(homeShown: true))
        #expect(!rig.model.askRemora("What moved?"))
        #expect(!rig.model.briefRemora())
        await remora.settle()
        #expect(!rig.ranAProcess && remora.lastAnswer == nil && remora.phase == .idle)
        #expect(try Data(contentsOf: rig.preferencesURL) == seeded.bytes, "the hold reached the preferences file")
        await rig.finish()
    }

    @Test func theHeldOffNeverReachesTheFileAndTurningRemoraOnLiftsIt() async throws {
        let seeded = try Self.rootWithRemoraOn()
        let rig = try Rig(root: seeded.root)
        let remora = rig.model.remora
        rig.model.holdRemoraOff()
        await remora.settle()
        // A write of the whole preferences value (the sidebar width) keeps the file's Remora on.
        rig.model.setSidebarWidth(360)
        let written = try JSONDecoder().decode(UIPreferences.self, from: Data(contentsOf: rig.preferencesURL))
        #expect(written.sidebarWidth == 360, "the write did not happen")
        #expect(try Data(contentsOf: rig.preferencesURL) != seeded.bytes)
        #expect(written.remora.isOn, "the held Off was written to the file")
        #expect(!remora.preferences.isOn)
        // Settings turns it on: kept as usual, and a brief starts again.
        rig.model.setRemoraOn(true)
        await remora.settle()
        #expect(remora.preferences.isOn && rig.host?.settings.isOn == true)
        #expect(UIPreferencesStore(url: rig.preferencesURL).current.remora.isOn)
        #expect(rig.model.briefRemoraIfDue(homeShown: true))
        await remora.settle()
        #expect(remora.lastAnswer?.kind == .brief && rig.ranAProcess)
        await rig.finish()
    }

    // MARK: L3a3: the folded weeks, the two times and the removal's own Undo

    /// `YYYY-MM-DD` of a date in the current time zone (Remora's calendar in the rig).
    private static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A question's journal line on `date`, written by a store of its own whose clock is that day (it folds nothing), before
    /// the rig's host opens the memory (which folds then).
    private static func seedJournal(at directory: URL, on date: Date, sessions: [UUID]) async throws {
        let seed = try RemoraMemory(directory: directory, clock: { date })
        try await seed.appendJournal(RemoraJournalEntry.make(
            kind: .question, question: "What moved?", answerText: "Billing waits.", sessions: sessions, model: nil, tokens: 10,
            summary: nil, date: date))
    }

    @Test func theFoldedWeeksAreReadWithTheirFirstDayAndLinesAndALineIdOrADeletionRemovesOne() async throws {
        let rig = try Rig()
        let removed = Date().addingTimeInterval(-20 * 86_400)
        let forgotten = Date().addingTimeInterval(-22 * 86_400)
        let deleted = UUID()
        try await Self.seedJournal(at: rig.remora, on: removed, sessions: [rig.session])
        try await Self.seedJournal(at: rig.remora, on: forgotten, sessions: [deleted])
        let weeks = await rig.model.remoraJournalWeeks()
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = .current
        let starts = Set([removed, forgotten].compactMap { iso.dateInterval(of: .weekOfYear, for: $0)?.start })
        #expect(Set(weeks.map(\.start)) == starts, "each week starts on its Monday at local midnight")
        let lines = weeks.flatMap(\.lines)
        #expect(Set(lines.map(\.id)) == [Self.dayString(removed), Self.dayString(forgotten)])
        #expect(lines.allSatisfy { $0.text == "1 question" })
        #expect(await rig.model.remoraJournalDays().isEmpty, "the days older than 14 were not folded")
        // A line's id removes it through the journal's ×.
        rig.model.removeRemoraJournalLine(id: Self.dayString(removed))
        await rig.model.remora.settle()
        #expect(await rig.model.remoraJournalWeeks().flatMap(\.lines).map(\.id) == [Self.dayString(forgotten)])
        // A session deleted through the forgetter takes its folded line out of the weeks read.
        let host = try #require(rig.host)
        try await host.forgetter.forget(sessionID: deleted, providerIDs: [])
        #expect(await rig.model.remoraJournalWeeks().flatMap(\.lines).isEmpty)
        await rig.finish()

        let none = try Rig(withHost: false)
        defer { try? FileManager.default.removeItem(at: none.root) }
        #expect(await none.model.remoraJournalWeeks().isEmpty)
        #expect(await none.model.remoraWorkingMemoryUpdatedAt() == nil)
    }

    @Test func theWeeksReadTreatsAnExcludedProjectAsTheDaysReadDoes() async throws {
        let rig = try Rig()
        let now = Date()
        try await Self.seedJournal(at: rig.remora, on: now.addingTimeInterval(-20 * 86_400), sessions: [rig.session])
        try await Self.seedJournal(at: rig.remora, on: now, sessions: [rig.session])
        rig.model.setRemoraExcluded(rig.project, true)
        await rig.model.remora.settle()
        // Both reads return what is on disk: the excluded project's lines stay there (kept out of the share only).
        let days = await rig.model.remoraJournal(on: now)
        let folded = await rig.model.remoraJournalWeeks().flatMap(\.lines)
        #expect(days.map(\.sessions) == [[rig.session]])
        #expect(folded.count == 1, "the weeks read and the days read disagree on an excluded project")
        await rig.finish()
    }

    @Test func theWorkingMemorysUpdatedTimeIsNilWhenEmptyFollowsAWriteAndSurvivesARelaunch() async throws {
        let first = try Rig()
        #expect(await first.model.remoraWorkingMemoryUpdatedAt() == nil)
        let before = Date().addingTimeInterval(-1)
        first.model.editRemoraNote(project: first.project, text: "Waits on review")
        await first.model.remora.settle()
        let written = try #require(await first.model.remoraWorkingMemoryUpdatedAt(), "a note write left no time")
        #expect(written >= before)
        // A journal line moves it too.
        let projects = first.remora.appendingPathComponent(RemoraMemory.projectsName)
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        for path in [projects.path, projects.appendingPathComponent(first.project.uuidString + ".md").path,
                     first.remora.appendingPathComponent(RemoraMemory.journalName).path] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)
        }
        #expect(await first.model.remoraWorkingMemoryUpdatedAt() == past)
        #expect(first.model.askRemora("What moved?"))
        await first.model.remora.settle()
        let journaled = try #require(await first.model.remoraWorkingMemoryUpdatedAt())
        #expect(journaled >= before)
        // A fresh host on the same folder reads the same time.
        let second = try Rig(root: first.root)
        #expect(await second.model.remoraWorkingMemoryUpdatedAt() == journaled)
        // Clear empties it.
        second.model.clearRemoraWorkingMemory()
        await second.model.remora.settle()
        #expect(await second.model.remoraWorkingMemoryUpdatedAt() == nil)
        await second.finish()
        await first.finish()
    }

    @Test func aNotesRewrittenTimeFollowsItsFileAndAnUndoKeepsTheTimeBeforeTheRemoval() async throws {
        let rig = try Rig()
        let seed = try RemoraMemory(directory: rig.remora)
        try await seed.replaceNote(project: rig.project, items: [RemoraNoteItem(text: "Waits on review", sessions: [rig.session])])
        let file = rig.remora.appendingPathComponent(RemoraMemory.projectsName).appendingPathComponent(rig.project.uuidString + ".md")
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        #expect(await rig.model.remoraNotes().map(\.rewrittenAt) == [past])
        let token = try #require(await rig.model.removeRemoraNoteWithUndo(project: rig.project))
        #expect(await rig.model.remoraNotes().isEmpty)
        rig.model.undoRemora(token)
        await rig.model.remora.settle()
        #expect(await rig.model.remoraNotes().map(\.rewrittenAt) == [past], "the undo read as a fresh rewrite")
        // An edit rewrites it: the time moves.
        let before = Date().addingTimeInterval(-1)
        rig.model.editRemoraNote(project: rig.project, text: "Waits on a second review")
        await rig.model.remora.settle()
        let edited = try #require(await rig.model.remoraNotes().first?.rewrittenAt)
        #expect(edited >= before)
        await rig.finish()
    }

    @Test func twoRemovalsInFlightEachReturnTheUndoOfTheirOwnNote() async throws {
        let rig = try Rig()
        let model = rig.model
        let seed = try RemoraMemory(directory: rig.remora)
        // The memory is open, as after the sheet's first load: the two removals are not serialized by its opening.
        #expect(await model.remoraNotes().isEmpty)
        for round in 0..<5 {
            let first = UUID()
            let second = UUID()
            try await seed.replaceNote(project: first, items: [RemoraNoteItem(text: "First waits \(round)")])
            try await seed.replaceNote(project: second, items: [RemoraNoteItem(text: "Second waits \(round)")])
            // Both start before either finishes.
            let one = Task { await model.removeRemoraNoteWithUndo(project: first) }
            let two = Task { await model.removeRemoraNoteWithUndo(project: second) }
            let firstToken = try #require(await one.value)
            let secondToken = try #require(await two.value)
            #expect(firstToken != secondToken, "round \(round): both removals returned one token")
            #expect(await model.remoraNotes().isEmpty)
            #expect(model.remora.lastUndo == firstToken || model.remora.lastUndo == secondToken)
            model.undoRemora(firstToken)
            await model.remora.settle()
            #expect(await model.remoraNotes().map(\.project) == [first], "round \(round): the first removal's Undo restored another note")
            model.undoRemora(secondToken)
            await model.remora.settle()
            #expect(Set(await model.remoraNotes().map(\.project)) == [first, second])
            try await seed.replaceNote(project: first, items: [])
            try await seed.replaceNote(project: second, items: [])
        }
        await rig.finish()
    }

    @Test func aRemovalInFlightWithAConfirmedFactStillReturnsItsOwnUndo() async throws {
        let rig = try Rig()
        let model = rig.model
        let other = UUID()
        let seed = try RemoraMemory(directory: rig.remora)
        try await seed.replaceNote(project: rig.project, items: [RemoraNoteItem(text: "Waits on review")])
        try await seed.replaceNote(project: other, items: [RemoraNoteItem(text: "Ships Friday")])
        let removal = Task { await model.removeRemoraNoteWithUndo(project: rig.project) }
        model.confirmRemoraFact("I prefer tabs")
        let token = try #require(await removal.value)
        await model.remora.settle()
        #expect(model.remora.lastRemembered == "I prefer tabs" || model.remora.lastUndo == token)
        model.undoRemora(token)
        await model.remora.settle()
        #expect(Set(await model.remoraNotes().map(\.project)) == [rig.project, other], "the removal's own token did not restore its note")
        // The fact is still remembered: the removal's Undo was not the fact's.
        let note = try String(contentsOf: rig.remora.appendingPathComponent("Remora.md"), encoding: .utf8)
        #expect(note.contains("I prefer tabs"))
        // `lastUndo` holds the newest token, as before.
        let newest = try #require(await model.removeRemoraNoteWithUndo(project: other))
        #expect(model.remora.lastUndo == newest)
        await rig.finish()
    }

    // MARK: L3c: Draft Brief

    @Test func draftBriefIsRefusedWithoutAHostWhenOffForAnExcludedProjectOrOneWithNoSessionAndWhileACallRuns() async throws {
        let none = try Rig(withHost: false)
        defer { try? FileManager.default.removeItem(at: none.root) }
        #expect(!(await none.model.draftRemoraBrief(project: UUID())))

        let rig = try Rig(script: Self.slow)
        let model = rig.model
        #expect(!(await model.draftRemoraBrief(project: UUID())), "a project with no session")
        model.setRemoraOn(false)
        await model.remora.settle()
        #expect(!(await model.draftRemoraBrief(project: rig.project)), "Remora is off")
        model.setRemoraOn(true)
        model.setRemoraExcluded(rig.project, true)
        await model.remora.settle()
        #expect(!(await model.draftRemoraBrief(project: rig.project)), "an excluded project")
        #expect(!rig.ranAProcess && model.remora.draft == .idle)
        model.setRemoraExcluded(rig.project, false)
        await model.remora.settle()
        // A question runs: no draft starts; a draft runs: no question or brief starts.
        #expect(model.askRemora("What moved?"))
        #expect(!(await model.draftRemoraBrief(project: rig.project)))
        model.stopRemora()
        await model.remora.settle()
        #expect(await model.draftRemoraBrief(project: rig.project))
        #expect(!model.askRemora("And now?") && !model.briefRemora() && !model.briefRemoraIfDue(homeShown: true))
        #expect(!(await model.draftRemoraBrief(project: rig.project)), "a second draft while one runs")
        model.stopRemora()
        await model.remora.settle()
        await rig.finish()
    }

    @Test func aDraftReadsThenLandsWithItsTextCitedIdsAndCountsAndLeavesHomesAnswerAlone() async throws {
        // The fake's script file: the answer's text, its closing block built with the pack's own session ids.
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-draft-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data(#"{"answer":"The goal is a clean importer.","mode":"slow","chips":[],"drafts":[]}"#.utf8)
            .write(to: fixture.appendingPathComponent("remora-fixture.json"))
        let rig = try Rig(script: ["CLAUDE_CONFIG_DIR": fixture.path])
        let state = rig.model.remora
        #expect(await rig.model.draftRemoraBrief(project: rig.project))
        #expect(state.draft.isReading && state.phase == .idle)
        _ = try #require(await rig.pid())
        #expect(state.draft == .reading(project: rig.project,
                                        reading: RemoraReading(sessions: 0, projectNotes: 0, project: .init(id: rig.project, name: "loom"))))
        await state.settle()
        guard case let .drafted(drafted) = state.draft else { Issue.record("not drafted: \(state.draft)"); await rig.finish(); return }
        #expect(drafted.project == rig.project && drafted.text == "The goal is a clean importer.")
        #expect(drafted.citedSessionIDs == [rig.session] && drafted.sessionsRead == 0)
        #expect(abs(drafted.draftedAt.timeIntervalSinceNow) < 60)
        #expect(state.lastAnswer == nil && state.streamedText.isEmpty, "the draft took Home's answer")
        #expect(state.usage?.today.drafts == 1 && state.usage?.today.questions == 0)
        let line = try #require(await rig.model.remoraJournal(on: Date()).last)
        #expect(line.isDraft && line.kind == .question && line.sessions == [rig.session])
        await rig.finish()
    }

    @Test func aDraftsFailureCarriesItsSentenceAndStopLeavesItStoppedAndDraftingAgainIsTheSameEntry() async throws {
        let login = try Rig(script: ["LOOM_FAKE_REMORA": "login"])
        #expect(await login.model.draftRemoraBrief(project: login.project))
        await login.model.remora.settle()
        #expect(login.model.remora.draft == .failed(project: login.project, failure: .notLoggedIn,
                                                    sentence: "Remora uses your Claude Code login. Log in with claude in a terminal."))
        #expect(login.model.remora.lastFailure == nil, "the draft's failure is not Home's")
        await login.finish()

        let error = try Rig(script: ["LOOM_FAKE_REMORA": "error"])
        #expect(await error.model.draftRemoraBrief(project: error.project))
        await error.model.remora.settle()
        #expect(error.model.remora.draft == .failed(project: error.project, failure: .apiError,
                                                    sentence: "Remora could not get an answer from Claude."))
        await error.finish()

        let slow = try Rig(script: Self.slow)
        #expect(await slow.model.draftRemoraBrief(project: slow.project))
        _ = try #require(await slow.pid())
        slow.model.stopRemora()
        await slow.model.remora.settle()
        #expect(slow.model.remora.draft == .stopped(project: slow.project) && slow.model.remora.stopped == nil)
        try? FileManager.default.removeItem(at: slow.pids)
        #expect(await slow.model.draftRemoraBrief(project: slow.project))
        #expect(slow.model.remora.draft.isReading)
        await slow.model.remora.settle()
        if case .drafted = slow.model.remora.draft {} else { Issue.record("drafting again did not draft: \(slow.model.remora.draft)") }
        await slow.finish()
    }
}
