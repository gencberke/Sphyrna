import Darwin
import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora

/// L3a: the host over the fake provider. Each test names a rule a host that skipped it would fail. No real Claude, no real
/// profile, no vault: a temporary data root and the fake provider's Remora mode.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct RemoraHostTests {
    private static let factAnswer = """
    Two sessions moved since you looked, and billing waits for your review.

    ```remora
    {"cited":[],"facts":["Prefers short answers"]}
    ```
    """

    // MARK: Asking

    @Test func anAskStreamsFinishesAppliesTheAnswerAndCountsItsUse() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA_ANSWER": Self.factAnswer])
        let pieces = HostPieces()
        let outcome = await host.ask("Where did I leave off?", onText: { pieces.items.append($0) })
        guard case let .answered(answer) = outcome else {
            Issue.record("expected an answer, got \(outcome)")
            await rig.finish()
            return
        }
        #expect(pieces.items.count > 1, "the text did not stream in pieces")
        #expect(pieces.items.joined() == answer.answer.text)
        #expect(answer.answer.text == "Two sessions moved since you looked, and billing waits for your review.")
        #expect(answer.answer.usage == RemoraTokenUsage(input: 2, cacheCreation: 1_200, cacheRead: 0, output: 64))
        #expect(answer.question == "Where did I leave off?" && answer.kind == .question)
        #expect(answer.exchange?.answer == "Two sessions moved since you looked, and billing waits for your review.")
        #expect(answer.proposedFacts == ["Prefers short answers"])
        #expect(answer.journaled)
        // The memory applied it: one journal line for the call.
        let lines = await host.journal(on: rig.clock.now)
        #expect(lines.count == 1 && lines.first?.kind == .question && lines.first?.question == "Where did I leave off?")
        // The use is counted and readable, with the drift count.
        let use = try #require(await host.usage())
        #expect(use.today.questions == 1 && use.today.briefs == 0)
        #expect(use.today.tokens.total == 1_266)
        #expect(use.today.costUSD == 0.0123)
        #expect(use.cacheDriftCalls == 0 && use.days.count == 1)
        #expect(!host.isRunning && host.activeKind == nil)
        await rig.finish()
    }

    @Test func theCallCarriesTheSettingsModelAndEffort() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(settings: RemoraPreferences(model: "haiku", effort: "medium"))
        guard case .answered = await host.ask("What moved?") else { Issue.record("no answer"); await rig.finish(); return }
        let record = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: rig.log)) as? [String: Any])
        let arguments = try #require(record["arguments"] as? [String])
        #expect(arguments[arguments.firstIndex(of: "--model")! + 1] == "haiku")
        #expect(arguments[arguments.firstIndex(of: "--effort")! + 1] == "medium")
        await rig.finish()
    }

    @Test func proposalsOffOffersNoFact() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA_ANSWER": Self.factAnswer], settings: RemoraPreferences(proposals: false))
        guard case let .answered(answer) = await host.ask("What moved?") else { Issue.record("no answer"); await rig.finish(); return }
        #expect(answer.proposedFacts.isEmpty)
        await rig.finish()
    }

    @Test func rememberMakesNoProcessAndSavesWithAnUndo() async throws {
        for (question, fact) in [("Remember that I prefer tabs", "I prefer tabs"), ("Hatırla: ben sekme severim", "ben sekme severim")] {
            let rig = try RemoraHostRig()
            let host = rig.makeHost()
            guard case let .remembered(saved, undo) = await host.ask(question) else {
                Issue.record("\(question) was not taken as an order to remember"); await rig.finish(); return
            }
            #expect(saved == fact)
            #expect(!rig.ranAProcess, "a remember order started a process")
            #expect(try String(contentsOf: rig.noteFile, encoding: .utf8).contains(" \u{00B7} " + fact))
            #expect(await host.undo(undo))
            #expect(!(try String(contentsOf: rig.noteFile, encoding: .utf8).contains(fact)))
            let use = try #require(await host.usage())
            #expect(use.today.calls == 0)
            await rig.finish()
        }
    }

    @Test func aFactTheNoteCannotTakeComesBackAsNotSavedAndStartsNothing() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost()
        let outcome = await host.ask("Remember " + String(repeating: "x", count: RemoraDurableNote.maxFactCharacters + 1))
        guard case let .notSaved(reason) = outcome else { Issue.record("got \(outcome)"); await rig.finish(); return }
        #expect(!reason.isEmpty && !rig.ranAProcess)
        await rig.finish()
    }

    @Test func offAsksNothingAndMakesNoProcess() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(settings: RemoraPreferences(isOn: false))
        #expect(await host.ask("What moved?") == .off)
        #expect(await host.brief() == .off)
        #expect(await host.briefIfDue(homeShown: true, windowRemainingShare: 1) == .notDue(.skip(.remoraOff)))
        #expect(!rig.ranAProcess && !FileManager.default.fileExists(atPath: rig.lastBrief.path))
        await rig.finish()
    }

    // MARK: Stop and one at a time

    @Test func stopEndsTheChildAndTheAskReturnsCancelled() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA": "slow"])
        let running = Task { await host.ask("What moved?") }
        let pid = try #require(await rig.pid())
        try await Task.sleep(for: .milliseconds(700))
        #expect(host.isRunning && host.activeKind == .question)
        host.stop()
        #expect(await running.value == .cancelled)
        #expect(await rig.gone(pid), "the child outlived stop")
        #expect(!host.isRunning && host.activeKind == nil)
        // Nothing was applied for a call nobody finished.
        #expect(await host.journal(on: rig.clock.now).isEmpty)
        await rig.finish()
    }

    @Test func aSecondCallWhileOneRunsIsRefusedAndTheFirstIsUntouched() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA": "slow"])
        let first = Task { await host.ask("What moved?") }
        let pid = try #require(await rig.pid())
        try await Task.sleep(for: .milliseconds(300))
        #expect(await host.ask("And now?") == .busy)
        #expect(await host.brief() == .busy)
        #expect(await host.briefIfDue(homeShown: true, windowRemainingShare: 1) == .busy)
        #expect(host.isRunning && kill(pid, 0) == 0, "the refusal disturbed the running call")
        // The refused brief recorded no slot.
        #expect(try rig.lastBriefRecorded() == nil)
        host.stop()
        #expect(await first.value == .cancelled)
        #expect(await rig.gone(pid))
        await rig.finish()
    }

    // MARK: Off or a new exclusion stops the call in flight

    /// A brief's answer that writes the rig project's note (the fake streams it in 7-character pieces, 400 ms apart in `slow`).
    private func noteAnswer(_ rig: RemoraHostRig) -> String {
        """
        Moved.

        ```remora
        {"notes":[{"project":"\(rig.project.uuidString)","items":[{"text":"Review","sessions":["\(rig.session.uuidString)"]}]}]}
        ```
        """
    }

    private func slowBrief(_ rig: RemoraHostRig, settings: RemoraPreferences = RemoraPreferences()) -> RemoraHost {
        rig.makeHost(script: ["LOOM_FAKE_REMORA": "slow", "LOOM_FAKE_REMORA_ANSWER": noteAnswer(rig)], settings: settings,
                     withTranscript: true)
    }

    @Test func excludingTheProjectWhileABriefRunsStopsTheCallAndLeavesNoNote() async throws {
        let rig = try RemoraHostRig()
        let host = slowBrief(rig)
        let running = Task { await host.brief() }
        let pid = try #require(await rig.pid())
        try await Task.sleep(for: .milliseconds(700))
        #expect(host.isRunning && host.activeKind == .brief)
        await host.excludeProject(rig.project)
        #expect(!host.isRunning, "the exclusion returned while the call still ran")
        #expect(await running.value == .cancelled)
        #expect(await rig.gone(pid), "the child outlived the exclusion")
        #expect(await host.notes().isEmpty, "an excluded project was remembered")
        #expect(await host.journal(on: rig.clock.now).isEmpty, "the stopped call applied its answer")
        #expect(host.settings.excludedProjects == [rig.project])
        await rig.finish()
    }

    @Test func turningRemoraOffWhileABriefRunsStopsTheCallAndAppliesNothing() async throws {
        let rig = try RemoraHostRig()
        let host = slowBrief(rig)
        let running = Task { await host.brief() }
        let pid = try #require(await rig.pid())
        try await Task.sleep(for: .milliseconds(700))
        #expect(host.isRunning)
        var off = host.settings
        off.isOn = false
        await host.update(settings: off)
        #expect(!host.isRunning && !host.settings.isOn)
        #expect(await running.value == .cancelled)
        #expect(await rig.gone(pid), "the child outlived Off")
        #expect(await host.notes().isEmpty && host.settings.excludedProjects.isEmpty)
        #expect(await host.journal(on: rig.clock.now).isEmpty, "the stopped call applied its answer")
        await rig.finish()
    }

    @Test func aSettingsChangeThatIsNeitherOffNorAGrowingExclusionLetsTheCallFinish() async throws {
        let rig = try RemoraHostRig()
        let other = UUID(), third = UUID()
        let host = slowBrief(rig, settings: RemoraPreferences(excludedProjects: [other, third]))
        let running = Task { await host.brief() }
        _ = try #require(await rig.pid())
        try await Task.sleep(for: .milliseconds(700))
        var changed = host.settings
        changed.model = "haiku"
        changed.proposals = false
        await host.update(settings: changed)
        #expect(host.isRunning, "a model change stopped the call")
        changed.excludedProjects = [other]
        await host.update(settings: changed)
        #expect(host.isRunning, "a shrinking exclusion set stopped the call")
        guard case .answered = await running.value else { Issue.record("the call did not finish"); await rig.finish(); return }
        #expect(await host.notes().map(\.project) == [rig.project], "the control's answer writes the note the other tests keep out")
        await rig.finish()
    }

    // MARK: The brief's day

    @Test func anAutomaticBriefRunsOncePerDayAndARelaunchedHostDoesNotRunItAgain() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost()
        let counter = HostPieces()
        let outcome = await host.briefIfDue(homeShown: true, windowRemainingShare: 0.8, onStart: { counter.starts += 1 })
        guard case let .answered(answer) = outcome else { Issue.record("got \(outcome)"); await rig.finish(); return }
        #expect(answer.kind == .brief && answer.question == nil && counter.starts == 1)
        #expect(try rig.lastBriefRecorded() == rig.clock.now.timeIntervalSince1970)
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: rig.lastBrief.path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        let use = try #require(await host.usage())
        #expect(use.today.briefs == 1)

        // The same host, and a relaunched one (nothing shared but the folder): no second brief, no process.
        rig.forgetProcesses()
        #expect(await host.briefIfDue(homeShown: true, windowRemainingShare: 0.8) == .notDue(.skip(.alreadyBriefedToday)))
        let relaunched = rig.makeHost()
        #expect(await relaunched.briefIfDue(homeShown: true, windowRemainingShare: 0.8) == .notDue(.skip(.alreadyBriefedToday)))
        #expect(!rig.ranAProcess, "a second brief started a process")
        // A brief the user asks for runs anyway.
        guard case .answered = await relaunched.brief() else { Issue.record("the asked brief did not run"); await rig.finish(); return }
        await rig.finish()
    }

    @Test func theCheapRulesAnswerBeforeTheCatalogIsRead() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost()
        guard case .answered = await host.briefIfDue(homeShown: true, windowRemainingShare: 1) else {
            Issue.record("the day's brief did not run"); await rig.finish(); return
        }
        let reads = rig.maps.readCount
        #expect(reads > 0, "the brief read the maps itself")
        // Every Home view after the day's brief, in the same host and in a relaunched one: no read.
        #expect(await host.briefIfDue(homeShown: true, windowRemainingShare: 1) == .notDue(.skip(.alreadyBriefedToday)))
        #expect(await rig.makeHost().briefIfDue(homeShown: true, windowRemainingShare: 1) == .notDue(.skip(.alreadyBriefedToday)))
        // Off and When I ask answer the same without it.
        #expect(await rig.makeHost(settings: RemoraPreferences(isOn: false)).briefIfDue(homeShown: true, windowRemainingShare: 1) == .notDue(.skip(.remoraOff)))
        #expect(await rig.makeHost(settings: RemoraPreferences(briefMode: .whenIAsk)).briefIfDue(homeShown: true, windowRemainingShare: 1) == .notDue(.skip(.whenIAsk)))
        #expect(rig.maps.readCount == reads, "a cheap rule still read the catalog")
        // The next day's first view does read it (the rule is the day, not the file).
        rig.clock.now = rig.clock.now.addingTimeInterval(24 * 3_600)
        _ = await rig.makeHost().briefIfDue(homeShown: false, windowRemainingShare: 1)
        #expect(rig.maps.readCount == reads + 1)
        await rig.finish()
    }

    @Test func aWaitRecordsNothingAndTheBriefRunsWhenThePlanRecovers() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost()
        let outcome = await host.briefIfDue(homeShown: true, windowRemainingShare: 0.05)
        #expect(outcome == .notDue(.wait(.windowLow(remaining: 0.05))))
        #expect(try rig.lastBriefRecorded() == nil, "a wait recorded the day's slot")
        #expect(host.loadLastBrief() == nil && !rig.ranAProcess)
        guard case .answered = await host.briefIfDue(homeShown: true, windowRemainingShare: 0.5) else {
            Issue.record("the brief did not run after the wait"); await rig.finish(); return
        }
        await rig.finish()
    }

    @Test func aBriefThatNeverReachedTheModelGivesTheDaysSlotBack() async throws {
        // Not logged in: the call is made, Claude says so.
        let login = try RemoraHostRig()
        let loggedOut = login.makeHost(script: ["LOOM_FAKE_REMORA": "login"])
        guard case let .failed(failure) = await loggedOut.briefIfDue(homeShown: true, windowRemainingShare: 1) else {
            Issue.record("expected a failure"); await login.finish(); return
        }
        #expect(failure.kind == .notLoggedIn)
        #expect(try login.lastBriefRecorded() == nil, "notLoggedIn kept the slot")
        guard case .answered = await login.makeHost().briefIfDue(homeShown: true, windowRemainingShare: 1) else {
            Issue.record("the day's brief could not run after notLoggedIn"); await login.finish(); return
        }
        await login.finish()

        // The child could not be started: the same.
        let blocked = try RemoraHostRig()
        let broken = blocked.makeHost(failToStart: RemoraFailure(kind: .couldNotStart, detail: "Claude could not be found",
                                                                beforeSpawn: true))
        guard case let .failed(second) = await broken.briefIfDue(homeShown: true, windowRemainingShare: 1) else {
            Issue.record("expected a failure"); await blocked.finish(); return
        }
        #expect(second.kind == .couldNotStart)
        #expect(try blocked.lastBriefRecorded() == nil, "couldNotStart kept the slot")
        await blocked.finish()
    }

    @Test func aFailureThatReachedTheModelKeepsTheSlotSoTheBriefIsNotRetriedToday() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA": "error"])
        guard case let .failed(failure) = await host.briefIfDue(homeShown: true, windowRemainingShare: 1) else {
            Issue.record("expected a failure"); await rig.finish(); return
        }
        #expect(failure.kind == .apiError)
        #expect(try rig.lastBriefRecorded() == rig.clock.now.timeIntervalSince1970)
        rig.forgetProcesses()
        #expect(await rig.makeHost().briefIfDue(homeShown: true, windowRemainingShare: 1) == .notDue(.skip(.alreadyBriefedToday)))
        #expect(!rig.ranAProcess)
        await rig.finish()
    }

    @Test func aSlotGivenBackIsTheEarlierDaysNotNone() async throws {
        let rig = try RemoraHostRig()
        let yesterday = rig.clock.now.addingTimeInterval(-26 * 3_600)
        try FileManager.default.createDirectory(at: rig.remora, withIntermediateDirectories: true)
        try RemoraLastBrief(directory: rig.remora).write(yesterday)
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA": "login"])
        guard case .failed = await host.brief() else { Issue.record("expected a failure"); await rig.finish(); return }
        #expect(try rig.lastBriefRecorded() == yesterday.timeIntervalSince1970)
        await rig.finish()
    }

    // MARK: Launch

    @Test func makingTheHostRemovesStalePromptFilesAndReadsNoMemoryFile() async throws {
        let rig = try RemoraHostRig()
        try FileManager.default.createDirectory(at: rig.remora, withIntermediateDirectories: true)
        for name in ["system-aaa.txt", "system-bbb.txt", "keep.txt"] { try Data("x".utf8).write(to: rig.remora.appendingPathComponent(name)) }
        // The day's brief of an earlier day: a read would remove it (the day's end), so a file that is still there was not read.
        try RemoraKeptBriefFile(directory: rig.remora).write(RemoraKeptBrief(
            startedAt: rig.clock.now.addingTimeInterval(-3 * 86_400), text: "Old brief."))
        let host = rig.makeHost()
        let forgetters = ConversationForgetters()
        host.registerForgetter(in: forgetters)
        #expect(forgetters.registered.count == 1)
        #expect(!FileManager.default.fileExists(atPath: rig.remora.appendingPathComponent("system-aaa.txt").path))
        #expect(!FileManager.default.fileExists(atPath: rig.remora.appendingPathComponent("system-bbb.txt").path))
        #expect(FileManager.default.fileExists(atPath: rig.remora.appendingPathComponent("keep.txt").path))
        // The memory opens its folders, folds the journal and reads the use when it is made: none of that happened.
        #expect(!host.memoryIsOpen)
        for name in [RemoraMemory.journalName, RemoraMemory.projectsName, RemoraMemory.usageName] {
            #expect(!FileManager.default.fileExists(atPath: rig.remora.appendingPathComponent(name).path), "\(name) was touched")
        }
        #expect(!FileManager.default.fileExists(atPath: rig.noteFile.path))
        #expect(FileManager.default.fileExists(atPath: rig.keptBrief.path), "making the host read the day's brief")
        #expect(!rig.ranAProcess)
        await rig.finish()
    }

    @Test func aDeletionBeforeAnyUseOfRemoraMakesNoFolder() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost()
        try await host.forgetter.forget(sessionID: UUID(), providerIDs: [])
        #expect(!FileManager.default.fileExists(atPath: rig.remora.path))
        await rig.finish()
    }

    // MARK: Projects and notes

    @Test func anExcludedProjectsNoteIsDeletedAndOthersStay() async throws {
        let rig = try RemoraHostRig()
        let other = UUID()
        let seed = try RemoraMemory(directory: rig.remora, timeZone: rig.zone, clock: { [clock = rig.clock] in clock.now })
        let item = RemoraNoteItem(text: "Waits on review", sessions: [rig.session])
        try await seed.replaceNote(project: rig.project, items: [item])
        try await seed.replaceNote(project: other, items: [item])
        let host = rig.makeHost()
        await host.excludeProject(rig.project)
        let kept = await host.notes().map(\.project)
        #expect(kept == [other])
        #expect(host.settings.excludedProjects == [rig.project])
        await rig.finish()
    }

    @Test func aNewNoteFileIsUsedFromNowOnAndTheMemoryStaysTheSame() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost()
        let elsewhere = rig.root.appendingPathComponent("elsewhere/My Note.md")
        guard case .remembered = await host.remember("First fact") else { Issue.record("not saved"); await rig.finish(); return }
        #expect(await host.journalDays().isEmpty)
        var settings = host.settings
        settings.noteFilePath = elsewhere.path
        await host.update(settings: settings)
        guard case .remembered = await host.remember("Second fact") else { Issue.record("not saved"); await rig.finish(); return }
        #expect(try String(contentsOf: elsewhere, encoding: .utf8).contains("Second fact"))
        #expect(try !String(contentsOf: rig.noteFile, encoding: .utf8).contains("Second fact"))
        // The memory read the new note for its share, and the call ran.
        guard case .answered = await host.ask("What do you remember?") else { Issue.record("no answer"); await rig.finish(); return }
        await rig.finish()
    }

    @Test func theMapsCoverEverySessionBeyondTheFirstHundredRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-maps-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let folder = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await catalog.addProject(path: folder.path).project
        var ids: [UUID] = []
        for index in 0..<130 {
            let session = ManagedSession(provider: .claude, workingDirectory: folder.path)
            ids.append(session.id)
            try await catalog.insertSession(session, title: "Row \(index)", createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                                            lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle,
                                            projectID: project.id, lastActivityAt: Date(timeIntervalSince1970: 10_000 + Double(index)))
        }
        let maps = try await RemoraCatalogMaps.read(from: catalog)
        #expect(maps.sessionProjects.count == 130, "the map stopped at \(maps.sessionProjects.count)")
        #expect(ids.allSatisfy { maps.sessionProjects[$0] == project.id })
        #expect(maps.projectNames[project.id] == project.name)
        #expect(maps.newestActivity(excluding: []) == Date(timeIntervalSince1970: 10_129))
        #expect(maps.newestActivity(excluding: [project.id]) == nil, "an excluded project's sessions moved the brief")
        #expect(maps.namedProjects(excluding: [project.id]).isEmpty)
        #expect(maps.namedProjects(excluding: []) == [project.id: project.name])
    }

    // MARK: The closing review (1.6.0)

    @Test func aQuitAfterTheBriefsChildSpawnedKeepsTheDaysSlot() async throws {
        // SPEC §10.2: once a brief's call reached the model, the day's slot is spent even if Sphyrna quits under it.
        let rig = try RemoraHostRig()
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA": "slow"])
        let running = Task { await host.briefIfDue(homeShown: true, windowRemainingShare: 1) }
        _ = try #require(await rig.pid(), "the brief's child did not start")
        try await Task.sleep(for: .milliseconds(500))
        let report = await rig.supervisor.shutdown()
        #expect(report.succeeded, "\(report.errors)")
        guard case let .failed(failure) = await running.value else { Issue.record("expected a failure"); await rig.finish(); return }
        #expect(!failure.beforeSpawn, "a Quit after the spawn was taken as never started")
        #expect(try rig.lastBriefRecorded() == rig.clock.now.timeIntervalSince1970, "Quit gave the day's slot back")
        rig.forgetProcesses()
        #expect(await rig.makeHost().briefIfDue(homeShown: true, windowRemainingShare: 1) == .notDue(.skip(.alreadyBriefedToday)),
                "a relaunch the same day would start a second call")
        #expect(!rig.ranAProcess)
        try? FileManager.default.removeItem(at: rig.root)
    }

    @Test func aChildThatCannotBeSpawnedGivesTheSlotBackAndCountsNoCall() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(executable: rig.root.appendingPathComponent("no-such-claude").path)
        guard case let .failed(failure) = await host.briefIfDue(homeShown: true, windowRemainingShare: 1) else {
            Issue.record("expected a failure"); await rig.finish(); return
        }
        #expect(failure.kind == .couldNotStart && failure.beforeSpawn)
        #expect(try rig.lastBriefRecorded() == nil, "a brief that never spawned kept the slot")
        #expect(await host.usage()?.today.briefs == 0, "a call that never spawned was counted")
        await rig.finish()
    }

    @Test func afterNotLoggedInTheAutomaticBriefWaitsForTheUserOrASettingsChange() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(script: ["LOOM_FAKE_REMORA": "login"])
        guard case let .failed(failure) = await host.briefIfDue(homeShown: true, windowRemainingShare: 1) else {
            Issue.record("expected a failure"); await rig.finish(); return
        }
        #expect(failure.kind == .notLoggedIn)
        #expect(try rig.lastBriefRecorded() == nil, "the slot is still given back")
        rig.forgetProcesses()
        // Two more Home shows: no call, no process.
        #expect(await host.briefIfDue(homeShown: true, windowRemainingShare: 1) == .notDue(.skip(.notLoggedIn)))
        #expect(await host.briefIfDue(homeShown: true, windowRemainingShare: 1) == .notDue(.skip(.notLoggedIn)))
        #expect(!rig.ranAProcess, "a Home show after notLoggedIn started a call")
        let briefs = await host.usage()?.today.briefs
        #expect(briefs == 1, "the Use line counts \(briefs ?? -1) briefs")
        // Catch Me Up still runs.
        guard case .failed = await host.brief() else { Issue.record("Catch Me Up did not run"); await rig.finish(); return }
        #expect(rig.ranAProcess, "Catch Me Up was held back")
        // It failed the same way: the wait holds again until a setting changes.
        rig.forgetProcesses()
        #expect(await host.briefIfDue(homeShown: true, windowRemainingShare: 1) == .notDue(.skip(.notLoggedIn)))
        var changed = host.settings
        changed.windowThreshold = 0.2
        await host.update(settings: changed)
        _ = await host.briefIfDue(homeShown: true, windowRemainingShare: 1)
        #expect(rig.ranAProcess, "a settings change did not let the automatic brief try again")
        await rig.finish()
    }

    @Test func theNotesAreNamedByTheCallerAndReadNoCatalogMaps() async throws {
        let rig = try RemoraHostRig()
        let seed = try RemoraMemory(directory: rig.remora, timeZone: rig.zone, clock: { [clock = rig.clock] in clock.now })
        try await seed.replaceNote(project: rig.project, items: [RemoraNoteItem(text: "Waits on review", sessions: [rig.session])])
        let host = rig.makeHost()
        let notes = await host.notes(names: [rig.project: "loom (model)"])
        #expect(notes.map(\.project) == [rig.project])
        #expect(notes.first?.name == "loom (model)")
        #expect(rig.maps.readCount == 0, "notes() read the catalog's maps (up to 10,000 rows) only to name projects")
        await rig.finish()
    }

    @Test func theNewestListedActivityIsOneNarrowReadThatSkipsExcludedProjectsAndSideChats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-newest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var projects: [UUID] = []
        for name in ["a", "b"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projects.append(try await catalog.addProject(path: folder.path).project.id)
        }
        #expect(try await catalog.newestListedActivity(excludingProjects: []) == nil)
        for (index, project) in projects.enumerated() {
            let session = ManagedSession(provider: .claude, workingDirectory: root.path)
            let when = Date(timeIntervalSince1970: 10_000 + Double(index) * 100)
            try await catalog.insertSession(session, title: "S\(index)", createdAt: when, lastUsedAt: when, lifecycle: .idle,
                                            projectID: project, lastActivityAt: when)
        }
        #expect(try await catalog.newestListedActivity(excludingProjects: []) == Date(timeIntervalSince1970: 10_100))
        #expect(try await catalog.newestListedActivity(excludingProjects: [projects[1]]) == Date(timeIntervalSince1970: 10_000))
        #expect(try await catalog.newestListedActivity(excludingProjects: Set(projects)) == nil)
        let maps = try await RemoraCatalogMaps.read(from: catalog)
        for excluded in [Set<UUID>(), [projects[0]], [projects[1]], Set(projects)] {
            #expect(try await catalog.newestListedActivity(excludingProjects: excluded) == maps.newestActivity(excluding: excluded))
        }
    }
}
