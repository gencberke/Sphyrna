import AppKit
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// V05, the parts that need no window: the two lists and their numbers against the sidebar's and the Dock
/// badge's, Continue and its Resume, the start box's project, the first-run and empty states, and the plan
/// pace on the model's tick. What the views evaluate is in `HomeRenderTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct HomeTests {
    /// Records the resumes and starts Home asks for.
    @MainActor
    final class HomeIntents: ConversationIntents {
        var resumed: [UUID] = []
        var starts: [(provider: ManagedSession.Provider, projectID: UUID?)] = []
        func start(provider: ManagedSession.Provider, projectID: UUID?) { starts.append((provider, projectID)) }
        func resume(sessionID: UUID) { resumed.append(sessionID) }
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { nil }
    }

    private final class HomeClock: Sendable {
        private let value: Mutex<Date>
        init(_ start: Date) { value = Mutex(start) }
        var now: Date { value.withLock { $0 } }
        func set(_ date: Date) { value.withLock { $0 = date } }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-home-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let noon = Date(timeIntervalSince1970: 1_791_374_400)

    // MARK: Needs you and Finished against the sidebar and the Dock badge

    private func approval() -> StatusReason {
        StatusReason(.approval(tool: "Bash"), detail: "git push origin fix/webhook-sig", note: "Push the branch")
    }

    /// A project with seven sessions in every state Home tells apart. Returns the ids by role.
    private struct States {
        let approval, input, question, finished, failed, working, idle: UUID
    }

    private func drive(_ rig: ListRig) async throws -> States {
        let ids = try #require(rig.ids[rig.projects[0].id])
        let states = States(approval: ids[0], input: ids[1], question: ids[2], finished: ids[3], failed: ids[4],
                            working: ids[5], idle: ids[6])
        for id in ids.prefix(6) { try await rig.feed(.runStarted(UUID()), for: id) }
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: states.approval)
        try await rig.feed(.reason(approval()), for: states.approval)
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForInput)), for: states.input)
        try await rig.feed(.reason(StatusReason(.input)), for: states.input)
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: states.question)
        try await rig.feed(.reason(StatusReason(.question, detail: "PDF library")), for: states.question)
        try await rig.feed(.reason(StatusReason(.turnDone, detail: "12 tests added, all pass")), for: states.finished)
        try await rig.feed(.status(ProviderWorkState(activity: .turnComplete)), for: states.finished)
        try await rig.feed(.reason(StatusReason(.failure(category: "rate_limit"), detail: "Too many requests")), for: states.failed)
        try await rig.feed(.status(ProviderWorkState(activity: .failed("rate_limit"))), for: states.failed)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: states.working)
        return states
    }

    @Test func aFailedTurnTheUserHasReadLeavesHomeAndTheBadgeLikeTheSidebarsActiveSection() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 2, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let id = try #require(rig.ids[rig.projects[0].id]?.first)
        try await rig.feed(.runStarted(UUID()), for: id)
        // A failure with no turn seen under way before it is still news: unread, so on Home and in Active.
        try await rig.feed(.status(ProviderWorkState(activity: .failed("rate_limit"))), for: id)
        #expect(model.homeBoard().finished.map(\.id) == [id] && model.attentionCount == 1)
        #expect(model.activeIDs.contains(id))
        // Read (viewed or marked read): out of Active, and out of Home and the badge with it. The card keeps its red dot.
        try await rig.feed(.markedRead, for: id)
        #expect(!model.activeIDs.contains(id))
        #expect(model.homeBoard().count == 0 && model.attentionCount == 0)
        #expect(model.rowModels[id]?.indicator == .failed("rate_limit"))
    }

    @Test func theTwoListsAreTheSidebarsAndTheDockBadgesCountSplitInTwo() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 7, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        var badge = 0
        model.onAttentionCountChange = { badge = $0 }
        let states = try await drive(rig)

        let board = model.homeBoard()
        #expect(Set(board.needsYou.map(\.id)) == [states.approval, states.input, states.question])
        #expect(board.finished.map(\.id) == [states.failed, states.finished], "a failure comes before a finish nobody read")
        // The sidebar's Home row, the Dock badge and the lists are one number.
        #expect(board.count == 5 && model.attentionCount == 5 && badge == 5)
        #expect(DockBadge.label(count: badge) == "5")
        #expect(HomeRow.accessibilityLabel(count: model.attentionCount) == "Home, 5 sessions need you")
        // The same sessions the keyboard jump walks, none twice and none missing.
        let ordered = model.sessionsNeedingAttention()
        #expect(Set(ordered) == Set(board.needsYou.map(\.id) + board.finished.map(\.id)))
        #expect(ordered.count == board.count)
        // Working and idle sessions are in neither list.
        #expect(!ordered.contains(states.working) && !ordered.contains(states.idle))

        // Reading the finished turn takes it off Home and off both counts at once.
        model.markRead(states.finished)
        await model.settle()
        try await rig.applyNextFrame()
        let after = model.homeBoard()
        #expect(after.finished.map(\.id) == [states.failed])
        #expect(after.count == 4 && model.attentionCount == 4 && badge == 4)

        // Nothing waits: both lists are empty and so are the badge and the row's count.
        model.markRead(states.finished)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: states.approval)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: states.input)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: states.question)
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: states.failed)
        #expect(model.homeBoard().count == 0 && model.attentionCount == 0 && badge == 0)
        #expect(DockBadge.label(count: badge) == nil)
    }

    @Test func aCardSaysWhatTheSessionWaitsForOrDidLast() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 7, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let states = try await drive(rig)
        let board = rig.model.homeBoard()
        func line(_ id: UUID) -> String? { (board.needsYou + board.finished).first { $0.id == id }?.line }
        #expect(line(states.approval) == "Asks to run: git push origin fix/webhook-sig")
        #expect(line(states.input) == "Waiting for your input")
        #expect(line(states.question) == "Asks: PDF library")
        // The last turn's words stay after the run, so a finished card keeps its line.
        #expect(line(states.finished) == "12 tests added, all pass")
        #expect(line(states.failed) == "Failed: Too many requests")
        let entry = try #require(board.needsYou.first { $0.id == states.approval })
        #expect(entry.projectName == rig.projects[0].name && entry.indicator == .waitingForApproval)
        #expect(entry.provider == .claude, "the row draws the harness's mark")
    }

    @Test func aStateWithoutAReasonFallsBackToWhatTheStateSays() {
        func entry(_ indicator: SessionIndicator, reason: StatusReason? = nil) -> HomeEntry {
            HomeEntry(id: UUID(), title: "t", projectName: nil, tone: nil, provider: .claude, indicator: indicator,
                      reason: SessionReasonLine(reason), lastActivityAt: Date())
        }
        #expect(entry(.waitingForApproval).line == "Needs approval")
        #expect(entry(.unviewedCompletion).line == "Finished")
        #expect(entry(.problem("Claude could not be resumed")).line == "Claude could not be resumed")
        #expect(entry(.waitingForApproval, reason: approval()).line.hasPrefix("Asks"))
        #expect(entry(.unviewedCompletion).canMarkRead && !entry(.failed(nil)).canMarkRead)
        // Where each need goes: a finished turn and a failed one are Finished; every other need is Needs you.
        #expect(HomeBoard.isFinished(.unviewedCompletion) && HomeBoard.isFinished(.failed("x")))
        for indicator: SessionIndicator in [.waitingForApproval, .waitingForInput, .identityUnclear,
                                            .stopUnverified("x"), .problem("x")] {
            #expect(!HomeBoard.isFinished(indicator) && AttentionOrder.rank(of: indicator) != nil)
        }
    }

    @Test func theBoardIsObservedSoTheListsFollowTheSessions() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 3, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let ids = try #require(rig.ids[rig.projects[0].id])
        let seen = ObservedWrite { _ = model.homeBoard() }
        try await rig.feed(.runStarted(UUID()), for: ids[0])
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: ids[0])
        #expect(seen.wrote)
        #expect(model.homeBoard().needsYou.map(\.id) == [ids[0]])
    }

    /// The band's "Two sessions are working." needs a count that follows the sessions: `menuBarSummary` is not observed, so the
    /// count is derived the way the summary is, after `liveRevision`, and a working session that stops redraws the band.
    @Test func theBandsWorkingCountIsObservedAndIsTheMenuBarsCount() async throws {
        let rig = try await ListRig.make(projects: 1, perProject: 4, unassigned: 0, mode: .activity)
        defer { rig.cleanup() }
        let model = rig.model
        let ids = try #require(rig.ids[rig.projects[0].id])
        #expect(model.homeWorkingCount() == 0)
        try await rig.feed(.runStarted(UUID()), for: ids[0])
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: ids[0])
        try await rig.feed(.runStarted(UUID()), for: ids[1])
        try await rig.feed(.status(ProviderWorkState(activity: .working)), for: ids[1])
        try await rig.feed(.runStarted(UUID()), for: ids[2])
        try await rig.feed(.status(ProviderWorkState(activity: .waitingForApproval)), for: ids[2])
        #expect(model.homeWorkingCount() == 2, "a session that waits for the user is not working")
        #expect(model.homeWorkingCount() == model.menuBarSummary.working)
        #expect(model.homeBoard().count == model.menuBarSummary.needsYou, "the sentence's two numbers are the menu bar's")
        let seen = ObservedWrite { _ = model.homeWorkingCount() }
        try await rig.feed(.status(ProviderWorkState(activity: .turnComplete)), for: ids[1])
        #expect(seen.wrote, "the band redraws when a session stops working")
        #expect(model.homeWorkingCount() == 1)
    }

    // MARK: Continue

    private struct CatalogRig {
        let root: URL
        let catalog: SessionCatalog
        let model: CatalogModel
        let intents: HomeIntents
        let projects: [CatalogProject]
        /// Quit three hours before noon, resumable.
        var quit = UUID()
        /// Stopped by the user.
        var stopped = UUID()
        /// Quit, but a Codex session and this build starts Claude only.
        var codex = UUID()
        /// Quit eight days before noon: past the window.
        var old = UUID()
    }

    private func catalogRig(projectNames: [String] = ["api", "billing"],
                            startable: Set<ManagedSession.Provider> = [.claude]) async throws -> CatalogRig {
        let root = try temporaryRoot()
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var projects: [CatalogProject] = []
        for name in projectNames {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projects.append(try await catalog.addProject(path: folder.path).project)
        }
        let leader = ProcessIdentity(pid: 7, startSeconds: 1, startMicroseconds: 2)
        func insert(_ provider: ManagedSession.Provider, _ title: String, project: CatalogProject?, ended: Date,
                    reason: ManagedRunEndReason) async throws -> UUID {
            let session = ManagedSession(provider: provider, providerConversationID: title,
                                         workingDirectory: project.map(\.path) ?? root.path)
            try await catalog.insertSession(session, title: title, createdAt: ended.addingTimeInterval(-3_600),
                                            lastUsedAt: ended, lifecycle: .idle, projectID: project?.id,
                                            lastActivityAt: ended)
            let run = ManagedRun(id: UUID(), leader: leader, startedAt: ended.addingTimeInterval(-600),
                                 state: .running, exitStatus: nil, descendants: [leader])
            try await catalog.startRun(run, sessionID: session.id)
            try await catalog.finishRun(run.id, endedAt: ended, reason: reason, exitStatus: nil)
            return session.id
        }
        let hour: TimeInterval = 3_600
        var rig = CatalogRig(
            root: root, catalog: catalog,
            model: CatalogModel(catalog: catalog, events: SessionEventHub(),
                                preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")),
                                startableProviders: startable),
            intents: HomeIntents(), projects: projects)
        rig.quit = try await insert(.claude, "Backfill script", project: projects.last, ended: noon.addingTimeInterval(-3 * hour),
                                    reason: .applicationQuit)
        rig.stopped = try await insert(.claude, "Stopped by hand", project: projects.first, ended: noon.addingTimeInterval(-hour),
                                       reason: .requested)
        rig.codex = try await insert(.codex, "A Codex session", project: projects.first, ended: noon.addingTimeInterval(-2 * hour),
                                     reason: .applicationQuit)
        rig.old = try await insert(.claude, "Last week", project: projects.first, ended: noon.addingTimeInterval(-8 * 24 * hour),
                                   reason: .applicationQuit)
        rig.model.currentDate = { [noon] in noon }
        rig.model.intents = rig.intents
        await rig.model.start()
        await rig.model.stopAndWait()
        await rig.model.settle()
        return rig
    }

    private func cleanup(_ rig: CatalogRig) {
        rig.model.stop()
        try? FileManager.default.removeItem(at: rig.root)
    }

    @Test func continueListsTheSessionsQuitEndedAndResumeUsesTheResumePath() async throws {
        let rig = try await catalogRig()
        defer { cleanup(rig) }
        let model = rig.model
        #expect(model.homeContinueEntries().isEmpty, "nothing is read before Home asks")
        #expect(!model.home.hasRead)

        await model.refreshHome()
        #expect(model.home.hasRead)
        // The stopped session, the Codex one (not startable here) and the one past the window are not offered.
        let entries = model.homeContinueEntries()
        #expect(entries.map(\.id) == [rig.quit])
        let entry = try #require(entries.first)
        #expect(entry.title == "Backfill script" && entry.projectName == "billing")
        #expect(entry.endedAt == noon.addingTimeInterval(-3 * 3_600))
        #expect(entry.provider == .claude)

        model.resumeFromHome(rig.quit)
        #expect(rig.intents.resumed == [rig.quit], "Resume goes through the existing resume path")
        #expect(model.homeContinueEntries().isEmpty, "the card is gone at once")

        // The session runs, then stops again while Home stays up: the card does not come back from the held list.
        model.liveStates[rig.quit] = SessionViewState(runID: UUID())
        #expect(model.homeContinueEntries().isEmpty)
        model.liveStates[rig.quit] = nil
        #expect(model.homeContinueEntries().isEmpty, "a stopped session is not a Quit one")
        model.setBusy(rig.quit, .resuming)
        #expect(model.homeContinueEntries().isEmpty)
    }

    /// DESIGN §9 Row: a Continue row carries its harness's mark, so each entry names the harness its session runs on.
    @Test func continueEntriesNameTheHarnessOfTheirSession() async throws {
        let rig = try await catalogRig(startable: [.claude, .codex])
        defer { cleanup(rig) }
        await rig.model.refreshHome()
        let providers = Dictionary(uniqueKeysWithValues: rig.model.homeContinueEntries().map { ($0.id, $0.provider) })
        #expect(providers[rig.quit] == .claude && providers[rig.codex] == .codex, "\(providers)")
    }

    @Test func aResumeThatCannotApplyLeavesTheCardAlone() async throws {
        let rig = try await catalogRig()
        defer { cleanup(rig) }
        let model = rig.model
        await model.refreshHome()
        // A resume is already under way: the card is not offered, and pressing it again does nothing more.
        model.setBusy(rig.quit, .resuming)
        model.resumeFromHome(rig.quit)
        #expect(rig.intents.resumed.isEmpty)
        model.setBusy(rig.quit, nil)
        #expect(model.homeContinueEntries().map(\.id) == [rig.quit])
    }

    @Test func aResumeThatStartedAfterTheReadTakesTheSessionOffTheNextRead() async throws {
        let rig = try await catalogRig()
        defer { cleanup(rig) }
        await rig.model.refreshHome()
        #expect(rig.model.homeContinueEntries().map(\.id) == [rig.quit])
        let leader = ProcessIdentity(pid: 8, startSeconds: 1, startMicroseconds: 2)
        try await rig.catalog.startRun(
            ManagedRun(id: UUID(), leader: leader, startedAt: noon, state: .running, exitStatus: nil, descendants: [leader]),
            sessionID: rig.quit)
        await rig.model.refreshHome()
        #expect(rig.model.homeContinueEntries().isEmpty)
    }

    @Test func homeReadsTheCatalogOnlyWhenAskedAndTheCountsAreTheCatalogs() async throws {
        let rig = try await catalogRig()
        defer { cleanup(rig) }
        let model = rig.model
        #expect(model.home.reads == 0 && model.home.sessionsToday == nil)
        await model.refreshHome()
        #expect(model.home.reads == 1)
        // Four sessions were used before today's start (noon is the clock); none today.
        let startOfDay = Calendar.current.startOfDay(for: noon)
        let expected = try await rig.catalog.sessionCount(activeSince: startOfDay)
        #expect(model.home.sessionsToday == expected)
        // A read that finds the same answer writes nothing.
        let write = ObservedWrite { _ = model.home.quitRuns; _ = model.home.sessionsToday; _ = model.home.lastUsedProjectID }
        await model.refreshHome()
        #expect(model.home.reads == 2 && !write.wrote)
    }

    // MARK: When Home reads

    @Test func homeReadsAgainWhenTheRuntimeHasClosedTheRunsACrashLeft() async throws {
        let rig = try await catalogRig()
        defer { cleanup(rig) }
        let model = rig.model
        // A run the last Loom left open, with a leader that is gone.
        let crashedSession = ManagedSession(provider: .claude, providerConversationID: "crashed", workingDirectory: rig.projects[0].path)
        try await rig.catalog.insertSession(crashedSession, title: "Crashed run", createdAt: noon.addingTimeInterval(-7_200),
                                            lastUsedAt: noon.addingTimeInterval(-1_800), lifecycle: .idle,
                                            projectID: rig.projects[0].id, lastActivityAt: noon.addingTimeInterval(-1_800))
        let gone = ProcessIdentity(pid: 2_999_999, startSeconds: 1, startMicroseconds: 2)
        try await rig.catalog.startRun(
            ManagedRun(id: UUID(), leader: gone, startedAt: noon.addingTimeInterval(-3_600), state: .running, exitStatus: nil,
                       descendants: [gone]), sessionID: crashedSession.id)

        // Home's first read runs while the run is still open: the crashed session is not there yet.
        let first = model.homeReadKey
        await model.refreshHome()
        #expect(!model.homeContinueEntries().map(\.id).contains(crashedSession.id))

        // The runtime closes the run. Nothing in the model moved, so Home would not read again...
        #expect(try await rig.catalog.closeAbandonedRuns(at: noon, isLive: { @Sendable _ in false }) == 1)
        #expect(model.homeReadKey == first)
        // ... until the runtime says the open runs are closed. Then the key moves and the read finds the session,
        // dated by its last use rather than by the relaunch.
        model.runsWereRecovered()
        #expect(model.homeReadKey != first)
        await model.refreshHome()
        let entry = try #require(model.homeContinueEntries().first { $0.id == crashedSession.id })
        #expect(entry.endedAt == noon.addingTimeInterval(-1_800))
    }

    @Test func aUsageRefreshReadsOnlyTodaysCountAndNotTheWholeHomeAgain() async throws {
        let rig = try await catalogRig()
        defer { cleanup(rig) }
        let model = rig.model
        let index = KindsUsageIndex(output: 1_000)
        let usage = UsageModel(index: index, clock: { Date() }, timeZone: TimeZone(identifier: "UTC")!)
        model.usage = usage
        await model.refreshHome()
        let before = model.homeReadKey
        let stamp = model.homeTodayKey
        #expect(stamp == nil && model.home.reads == 1 && model.home.todayReads == 0)

        // A turn in a session that already exists (last week's, here) changes no count of sessions...
        let today = try #require(model.home.sessionsToday)
        try await rig.catalog.markActivity(sessionID: rig.old, at: noon)
        #expect(model.homeReadKey == before, "no count moved")
        #expect(model.home.sessionsToday == today, "Home still shows the old number")
        // ... the usage refresh that follows the turn does not move the key of the full read (the Continue
        // query scans the runs, and every finished turn ends in a refresh) ...
        await usage.refreshNow(reason: .turnComplete)
        #expect(model.homeReadKey == before, "the full read does not run again")
        #expect(model.homeTodayKey != stamp, "the refresh is what the second task waits on")
        // ... it re-reads one count, and Home finds one more session today.
        await model.refreshHomeToday()
        #expect(model.home.sessionsToday == today + 1)
        #expect(model.home.reads == 1 && model.home.todayReads == 1, "one count, not the whole read")
        // The same refresh is not read twice (the task runs again when Home reappears).
        await model.refreshHomeToday()
        #expect(model.home.todayReads == 1)
    }

    @Test func theCountAfterARefreshWaitsForTheFirstFullRead() async throws {
        let rig = try await catalogRig()
        defer { cleanup(rig) }
        let model = rig.model
        let usage = UsageModel(index: KindsUsageIndex(output: 1_000), clock: { Date() }, timeZone: TimeZone(identifier: "UTC")!)
        model.usage = usage
        await usage.refreshNow(reason: .turnComplete)
        await model.refreshHomeToday()
        #expect(model.home.todayReads == 0 && model.home.sessionsToday == nil, "the full read comes first, and it brings the count")
        await model.refreshHome()
        await model.refreshHomeToday()
        #expect(model.home.reads == 1 && model.home.todayReads == 0, "the full read already went with this refresh")
    }

    // MARK: New session (V19: the start box went; the sidebar's row opens the draft)

    @Test func newSessionOpensTheDraftInTheMostRecentlyUsedProject() async throws {
        let rig = try await catalogRig()
        defer { cleanup(rig) }
        let model = rig.model
        let api = rig.projects[0]
        // The most recent activity in the catalog is the stopped session of api, an hour before noon.
        model.beginNewSessionInRecentProject()
        #expect(await waitFor { model.destination == .draft(projectID: api.id) })
        // The draft's own project picker still changes it.
        let billing = rig.projects[1]
        model.chooseDraftProject(billing.id, from: api.id)
        #expect(model.destination == .draft(projectID: billing.id))
    }

    @Test func newSessionFallsBackToTheFirstProjectAndToNoneWithoutProjects() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: try SessionCatalog(url: root.appendingPathComponent("c.sqlite3")),
                                 events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait()
        #expect(model.mostRecentProjectID == nil)
        model.beginNewSessionInRecentProject()
        #expect(await waitFor { model.destination == .draft(projectID: nil) })
        model.stop()
    }

    /// M6: the row's project is the catalog's, read when it is used: it holds when the window has not read Home yet (a
    /// relaunch), in the Projects view and with a search typed, and an unrelated start does not disable the row.
    @Test func theNewSessionRowUsesThePersistedProjectWhateverTheWindowShows() async throws {
        let rig = try await catalogRig()
        defer { cleanup(rig) }
        let model = rig.model
        // The newest session is in "billing", the second project: the last-used project is not the first of the list.
        let billing = rig.projects[1]
        let newest = ManagedSession(provider: .claude, providerConversationID: "newest", workingDirectory: billing.path)
        try await rig.catalog.insertSession(newest, title: "newest", createdAt: noon.addingTimeInterval(-600), lastUsedAt: noon,
                                            lifecycle: .idle, projectID: billing.id, lastActivityAt: noon)
                // As after a relaunch: the window has not kept anything from a Home read.
        model.home.lastUsedProjectID = nil
        model.select(nil)
        model.setViewMode(.projects)
        model.setSearchText("api")
        let persisted = try await rig.catalog.lastUsedProjectID()
        #expect(persisted == billing.id)
        #expect(model.mostRecentProjectID == rig.projects[0].id, "what the window alone knows is the first project")
        #expect(await model.recentProjectForNewSession() == billing.id, "not the first project of a filtered or other list")
        model.beginNewSessionInRecentProject()
        #expect(await waitFor { model.destination == .draft(projectID: billing.id) })
        // The row depends on Claude being startable, not on any start elsewhere.
        #expect(model.newSessionRowAvailable == (model.actionsAvailable && model.startableProviders.contains(.claude)))
    }

    /// M6: ⌘N and the menu item on Home open the same draft as the sidebar's row.
    @Test func commandNOnHomeOpensTheSameDraftAsTheRow() async throws {
        let rig = try await catalogRig()
        defer { cleanup(rig) }
        let model = rig.model
        let api = rig.projects[0]
        model.showHome()
        model.beginNewSessionFromCommand()
        #expect(await waitFor { model.destination == .draft(projectID: api.id) })
    }

    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    // MARK: First run and empty states

    @Test func anEmptyCatalogOpensOnHomeWithItsOwnStateWithoutAnyDestination() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: try SessionCatalog(url: root.appendingPathComponent("c.sqlite3")),
                                 events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        #expect(!model.homeCatalogIsEmpty, "not before the catalog is read")
        await model.start()
        await model.stopAndWait()
        await model.settle()
        #expect(model.homeCatalogIsEmpty)
        // First run: no saved destination, and the empty catalog still opens on Home (not the old start screen).
        #expect(model.destination == nil && model.detailRoute == .home)
        model.showHome()
        #expect(model.detailRoute == .home && model.homeCatalogIsEmpty)
        #expect(model.homeBoard().count == 0 && model.homeContinueEntries().isEmpty)
        model.stop()
    }

    @Test func aCatalogWithAProjectOrASessionIsNotEmpty() async throws {
        let rig = try await catalogRig(projectNames: ["api"])
        defer { cleanup(rig) }
        rig.model.showHome()
        #expect(!rig.model.homeCatalogIsEmpty)
        #expect(rig.model.detailRoute == .home)
    }

    @Test func theFirstRunWordsSayWhatHappenedAndWhatToDo() {
        let copies: [HomeEmptyCopy] = [.noProjects, .connect]
        for copy in copies {
            let words = copy.title + " " + copy.text
            #expect(!words.contains("!") && !words.lowercased().contains("oops"), "no exclamation marks, no Oops")
            #expect(!words.contains("onversation"), "text the user reads says session")
            #expect(copy.title.first?.isUppercase == true && !copy.title.hasSuffix("."))
            #expect(copy.text.hasSuffix("."))
        }
        #expect(HomeEmptyCopy.noProjects.text.contains("Add the folder"))
        // Over sessions the compact card does not offer to add a project; they stay readable.
        #expect(HomeConnect.noticeSuffix.contains("stay readable"))
        #expect(!HomeConnect.noticeSuffix.contains("project"))
    }

    private func usageModel(_ limits: FakeLimits, clock: TestClock) -> UsageModel {
        UsageModel(index: FakeUsageIndex(), limits: limits, clock: { clock.now },
                   timeZone: TimeZone(identifier: "UTC")!, debounce: .milliseconds(40), activationCooldown: .zero)
    }

    // Home's "Connect your agents" (the health of each harness replaced the plan-limits proxy for a missing Claude) is tested
    // in ConnectionsTests.

    // MARK: Today

    @Test func todayShowsTheChipsTokensAndTheCatalogsSessions() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        #expect(model.homeTodayFigures() == nil, "nothing to say before anything was read")
        model.home.sessionsToday = 4
        #expect(model.homeTodayFigures() == HomeTodayFigures(tokens: nil, sessions: 4, note: nil))

        let index = FakeUsageIndex()
        index.setTokens(1_200_000)
        let usage = UsageModel(index: index, clock: { Date() }, timeZone: TimeZone(identifier: "UTC")!)
        model.usage = usage
        usage.refresh(reason: .launch)
        await usage.settle()
        let figures = try #require(model.homeTodayFigures())
        #expect(figures.tokens == usage.chip?.figure && figures.tokens == "1.2M", "the footer chip's own number")
        #expect(figures.sessions == 4)
    }

    @Test func todayAddsTheCacheShareAndTheKindsOfTodaysTokens() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let index = KindsUsageIndex(input: 90, output: 50, cacheWrite: 10, cacheRead: 400)
        let usage = UsageModel(index: index, clock: { Date() }, timeZone: TimeZone(identifier: "UTC")!)
        model.usage = usage
        usage.refresh(reason: .launch)
        await usage.settle()
        let figures = try #require(model.homeTodayFigures())
        let kinds = try #require(figures.kinds)
        #expect(kinds.input == 90 && kinds.output == 50 && kinds.cacheWrite == 10 && kinds.cacheRead == 400)
        #expect(figures.cacheShare == "80%", "400 cache reads of 500 prompt tokens")

        // Nothing sent as prompt: no share, and a day without tokens has no bars.
        index.set(input: 0, output: 0, cacheWrite: 0, cacheRead: 0)
        await usage.refreshNow(reason: .manual)
        let empty = model.homeTodayFigures()
        #expect(empty?.kinds == nil && empty?.cacheShare == nil)
        index.set(input: 0, output: 70, cacheWrite: 0, cacheRead: 0)
        await usage.refreshNow(reason: .manual)
        #expect(model.homeTodayFigures()?.kinds?.total == 70 && model.homeTodayFigures()?.cacheShare == nil)
    }

    @Test func todayIsOneCompactLineOfTokensSessionsAndTheCacheShareWithTheKindsAsATooltip() {
        let figures = HomeTodayFigures(tokens: "1.2M", sessions: 6, note: nil,
                                       kinds: UsageToday(UsageTokens(input: 90_000, output: 50_000, cacheWrite5m: 10_000, cacheRead: 400_000)))
        #expect(figures.stats.map { "\($0.figure) \($0.label)" } == ["1.2M tokens", "6 sessions", "80% from cache"])
        #expect(figures.spoken == "Today, 1.2M tokens, 6 sessions, 80% from cache")
        #expect(figures.kindsTooltip == "Today by kind: input 90K, output 50K, cache read 400K, cache write 10K.")
        // Nothing but the catalog's count (no usage index yet), and one session in the singular.
        let alone = HomeTodayFigures(tokens: nil, sessions: 1, note: nil)
        #expect(alone.stats.map { "\($0.figure) \($0.label)" } == ["1 session"] && alone.kindsTooltip == nil)
        #expect(HomeTodayFigures(tokens: nil, sessions: nil, note: "Reading").stats.isEmpty)
    }

    // MARK: The pace line and the tick

    @Test func thePlanPaceFollowsTheModelsTickAndDropsAWindowThatEnded() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let clock = HomeClock(noon)
        model.currentDate = { clock.now }
        // The tick's sleep never ends in this test: only the model's own catch-up on becoming visible runs.
        model.sleepUntil = { _ in try await Task.sleep(for: .seconds(3_600)) }
        let testClock = TestClock(noon)
        let limits = FakeLimits()
        limits.setAnswer(PlanLimits(
            fiveHour: PlanLimitWindow(usedPercent: 38, resetsAt: noon.addingTimeInterval(120)),
            weekly: PlanLimitWindow(usedPercent: 41, resetsAt: noon.addingTimeInterval(4 * 86_400)), fetchedAt: noon))
        let usage = usageModel(limits, clock: testClock)
        model.usage = usage
        model.setWindowVisible(true)
        usage.refresh(reason: .launch)
        await usage.settle()

        #expect(model.homePaces().map(\.kind) == [.fiveHour, .weekly])
        let seen = ObservedWrite { _ = model.homePaces() }
        model.setWindowVisible(false)
        clock.set(noon.addingTimeInterval(180))
        model.setWindowVisible(true) // the catch-up the tick makes
        #expect(seen.wrote, "the pace line reads the model's clock")
        #expect(model.homePaces().map(\.kind) == [.weekly], "a window that ended drops out without a new ask")
        model.setWindowVisible(false)
        model.stop()
    }

    @Test func noPlanLimitsMeansNoPaceLines() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        #expect(model.homePaces().isEmpty, "no usage model")
        model.usage = usageModel(FakeLimits(), clock: TestClock())
        #expect(model.homePaces().isEmpty, "no answer yet")
    }

    // MARK: The plan-limits card

    /// Rows of the picture (top to bottom, in pixels) where a run of at least `minRun` opaque pixels of one colour, other than
    /// the card's own fill, crosses `columns`: the track or the fill of a meter. Text, the hairline and the tick are not.
    private func meterBands(_ bitmap: NSBitmapImageRep, columns: Range<Int>, minRun: Int, minRows: Int) -> [Range<Int>] {
        guard let data = bitmap.bitmapData, bitmap.samplesPerPixel == 4, bitmap.bitsPerSample == 8 else { return [] }
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let offset = y * bitmap.bytesPerRow + x * 4
            return (0..<4).map { Int(data[offset + $0]) }
        }
        var counts: [[Int]: Int] = [:]
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: columns.lowerBound, to: columns.upperBound, by: 3) {
                let color = pixel(x, y)
                if color[3] == 255 { counts[color, default: 0] += 1 }
            }
        }
        guard let card = counts.max(by: { $0.value < $1.value })?.key else { return [] }
        func near(_ a: [Int], _ b: [Int]) -> Bool { (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= 3 } }
        var inked: [Bool] = []
        for y in 0..<bitmap.pixelsHigh {
            var run = 0, best = 0
            var previous: [Int]?
            for x in columns {
                let color = pixel(x, y)
                if color[3] == 255, !near(color, card), let before = previous, near(color, before) { run += 1 } else { run = 0 }
                previous = color
                best = max(best, run)
            }
            inked.append(best >= minRun)
        }
        var bands: [Range<Int>] = []
        var start: Int?
        for (y, on) in Array(inked.enumerated()) + [(inked.count, false)] {
            if on { start = start ?? y } else if let from = start {
                if y - from >= minRows { bands.append(from..<y) }
                start = nil
            }
        }
        return bands
    }

    /// V25 swapped the preview's plan-limits card for a one-line button with a popover; the previews (and D-65's Home) show the
    /// meters on Home itself. The card draws both windows' meters inline: a 6 pt track and fill for each, nothing to click.
    @Test func homeDrawsBothPlanLimitWindowsAsMetersInTheCardItself() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let now = Date()
        let limits = FakeLimits()
        limits.setAnswer(PlanLimits(
            fiveHour: PlanLimitWindow(usedPercent: 38, resetsAt: now.addingTimeInterval(3 * 3_600)),
            weekly: PlanLimitWindow(usedPercent: 59, resetsAt: now.addingTimeInterval(4 * 86_400)), fetchedAt: now))
        let usage = UsageModel(index: FakeUsageIndex(), limits: limits, timeZone: TimeZone(identifier: "UTC")!,
                               debounce: .milliseconds(40), activationCooldown: .zero)
        model.usage = usage
        usage.refresh(reason: .launch)
        await usage.settle()
        #expect(model.homePaces().count == 2)

        let width: CGFloat = 340 // the side column
        let renderer = ImageRenderer(content: HomeUsage(model: model)
            .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        if let directory = ProcessInfo.processInfo.environment["LOOM_REVIEW_RENDER_DIR"], !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("home-plan-limits-card.png"))
        }
        let inset = Int(LoomTheme.Home.sideCardPadding * 2)
        let bands = meterBands(bitmap, columns: inset..<(Int(width * 2) - inset), minRun: 120, minRows: 8)
        #expect(bands.count == 2, "one meter per window in the card, found \(bands.count)")
        #expect(bands.allSatisfy { $0.count <= Int(LoomTheme.PlanPaceLine.meterHeight * 2) + 4 }, // pixels at 2x, with the antialiased edge rows
                "each meter is \(LoomTheme.PlanPaceLine.meterHeight) pt tall (the tick is taller, and made the meter 10 pt): \(bands)")
    }
}
