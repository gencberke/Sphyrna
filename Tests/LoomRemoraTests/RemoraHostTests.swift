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
        let broken = blocked.makeHost(failToStart: RemoraFailure(kind: .couldNotStart, detail: "Claude could not be found", usage: nil))
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
}
