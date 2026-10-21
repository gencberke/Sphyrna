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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-model-\(UUID().uuidString.prefix(8))")
        let supervisor: ProcessSupervisor
        let model: CatalogModel
        private(set) var host: RemoraHost?
        let project = UUID()
        let session = UUID()
        var remora: URL { root.appendingPathComponent("remora") }
        var preferencesURL: URL { root.appendingPathComponent("ui-preferences.json") }
        var pids: URL { root.appendingPathComponent("fake-pid") }
        var log: URL { root.appendingPathComponent("fake-log.json") }

        init(script: [String: String] = [:], withHost: Bool = true) throws {
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
}
