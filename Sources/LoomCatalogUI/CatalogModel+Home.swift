import Foundation
import LoomCore
import Observation

/// The state of the Home screen (V05) that the model does not already hold: what the catalog was asked when
/// Home opened. Everything else Home shows (the sessions that need the
/// user, the plan limits, the clock) is read from the model when it draws; nothing here polls.
@MainActor @Observable
public final class HomeState {
    /// Sessions whose latest run Quit (or a crash) ended and that were not resumed since, newest first.
    public internal(set) var quitRuns: [CatalogQuitRun] = []
    /// How many sessions were used since the start of the day; nil until the first read.
    public internal(set) var sessionsToday: Int?
    /// The project of the most recently used session, as the catalog says (the sidebar's New session falls back to it).
    public internal(set) var lastUsedProjectID: UUID?
    /// The catalog was read at least once, so an empty Continue is "none", not "not read yet".
    public internal(set) var hasRead = false
    /// How many times the catalog was read for Home in full (a test counts it).
    @ObservationIgnored public internal(set) var reads = 0
    /// How many times only "sessions today" was read again, after a usage refresh (a test counts it).
    @ObservationIgnored public internal(set) var todayReads = 0
    /// The usage refresh time the last read of "sessions today" went with.
    @ObservationIgnored var todayStamp: Date?

    public init() {}
}

/// What development evidence reads of Home (see `CatalogModel.homeSummary()`).
public struct HomeSummary: Equatable, Sendable {
    public let needsYou: [UUID]
    public let finished: [UUID]
    public let continueSessions: [UUID]
    public let sessionsToday: Int?
    public let newSessionProjectID: UUID?
    public let emptyCatalog: Bool
    public let claudeMissing: Bool
    public let paces: Int
    public let reads: Int
}

/// One session on Home, as a card shows it. Plain values: the views compare them, and a test reads them.
struct HomeEntry: Identifiable, Equatable {
    let id: UUID
    let title: String
    let projectName: String?
    let tone: ProjectTone?
    /// The harness the session runs on: a row draws its mark (DESIGN §9 Row).
    let provider: ManagedSession.Provider
    let indicator: SessionIndicator
    /// What it waits for or did last (V03), one bounded line.
    let reason: SessionReasonLine?
    let lastActivityAt: Date

    /// The card's line: the reason when the hub has one, else what the state itself says.
    var line: String {
        if let reason { return reason.text }
        switch indicator {
        case .problem(let text): return text
        default: return indicator.label ?? ""
        }
    }

    var canMarkRead: Bool { indicator.canMarkRead }
}

/// The two lists that make the Dock badge's number: sessions that need the user, and sessions that finished
/// or failed and have not been read. Their sizes add up to `CatalogModel.attentionCount` (they split
/// `AttentionOrder`'s set, and nothing else).
struct HomeBoard: Equatable {
    var needsYou: [HomeEntry] = []
    var finished: [HomeEntry] = []

    var count: Int { needsYou.count + finished.count }

    /// Where an indicator of `AttentionOrder`'s set goes: a finished turn nobody read, and a turn that failed
    /// (it ended and says why), are Finished; every other need (an approval, a question, a plan, a stop that
    /// could not be verified, a problem, an unclear identity) is Needs you.
    static func isFinished(_ indicator: SessionIndicator) -> Bool {
        switch indicator {
        case .unviewedCompletion, .failed: true
        default: false
        }
    }
}

/// A session Continue offers to resume.
struct HomeContinueEntry: Identifiable, Equatable {
    let id: UUID
    let title: String
    let projectName: String?
    let tone: ProjectTone?
    let provider: ManagedSession.Provider
    let endedAt: Date
}

/// What a full read of the catalog for Home depends on: it runs when Home appears, once the model is ready, when
/// the day turns, when the number of sessions changes, and when the runtime has closed the runs an earlier Loom
/// left open. The usage refresh is not part of it: a turn in a session that already exists moves "sessions
/// today" and nothing else, and every finished turn ends in a refresh, so the refresh re-reads only that number
/// (`CatalogModel.refreshHomeToday`, keyed on `CatalogModel.homeTodayKey`).
struct HomeReadKey: Equatable {
    let ready: Bool
    let day: Date
    let counts: [UUID?: Int]
    let runsRecovered: Int
}

/// How far back Continue looks and how many sessions one read returns.
enum HomeLimits {
    static let continueDays = 7
    static let continueRead = 30
}

extension CatalogModel {
    /// "Home": shows the Home screen. Deselects the current session (its run keeps going); nothing is stopped or started.
    public func showHome() { navigate(to: .home) }

    /// The key Home's read task runs on (`HomeView`).
    var homeReadKey: HomeReadKey {
        HomeReadKey(ready: isReady, day: today, counts: sessionCounts, runsRecovered: runsRecovered)
    }

    /// The key of Home's second read task: the time the usage refresh last ended.
    var homeTodayKey: Date? { usage?.updatedAt }

    // MARK: Needs you, Finished

    /// The sessions behind the Dock badge, split into the two lists Home draws. Reads the live states the
    /// badge reads and the records the sidebar holds, so its numbers are theirs; nothing is queried.
    func homeBoard() -> HomeBoard {
        _ = liveRevision
        let candidates = attentionCandidates()
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var board = HomeBoard()
        for id in AttentionOrder.ordered(candidates) {
            guard let candidate = byID[id], let record = rowModels[id]?.record ?? liveRecords[id] else { continue }
            let name = projectName(for: record)
            let entry = HomeEntry(
                id: id, title: record.displayTitle(projectName: name), projectName: name,
                tone: projectTone(forProject: record.projectID), provider: record.session.provider, indicator: candidate.indicator,
                reason: SessionReasonLine(liveStates[id]?.displayReason), lastActivityAt: candidate.lastActivityAt)
            if HomeBoard.isFinished(candidate.indicator) { board.finished.append(entry) } else { board.needsYou.append(entry) }
        }
        return board
    }

    /// How many sessions are working and need nobody: the band's "Two sessions are working.". Read like `homeBoard` (after
    /// `liveRevision`, so a live change redraws it) from the derivation the menu bar's summary comes from;
    /// `menuBarSummary` itself is not observed, so a view must not read it.
    func homeWorkingCount() -> Int {
        _ = liveRevision
        return MenuBarSummary.derive(attentionCandidates()).working
    }

    // MARK: Evidence

    /// Home in numbers and ids, for development evidence: no title, project name or line (those are content).
    public func homeSummary() -> HomeSummary {
        let board = homeBoard()
        return HomeSummary(
            needsYou: board.needsYou.map(\.id), finished: board.finished.map(\.id),
            continueSessions: homeContinueEntries().map(\.id), sessionsToday: home.sessionsToday,
            newSessionProjectID: mostRecentProjectID, emptyCatalog: homeCatalogIsEmpty, claudeMissing: homeClaudeCLIMissing,
            paces: homePaces().count, reads: home.reads)
    }

    // MARK: Plan limits

    /// The pace of each plan window at the model's clock. Reading `now` here is what lets the minute tick
    /// redraw the pace line, and only while a view that reads this is on screen; a window that has ended
    /// drops out by itself. Pure arithmetic over the last answer: nothing is asked.
    func homePaces() -> [PlanPace] { usage?.paces(at: now) ?? [] }

    /// Codex's limit windows for the Plan limits card, at the model's clock: empty unless Codex is connected and has been
    /// read (by the Usage page or Connections; Home asks nothing itself). A window that has ended drops out by itself.
    func homeCodexLimits() -> [PlanPaceLine.Content] {
        guard let usage, usage.isConnected(.codex), let reading = usage.readings[.codex] else { return [] }
        let current = now
        return reading.currentWindows(at: current).map {
            PlanPaceLine.Content(window: $0, measuredAt: reading.readAt, now: current, timeZone: usage.timeZone)
        }
    }

    // MARK: Continue

    /// The sessions Quit cut short that can be resumed now, newest first. A session whose run is live again
    /// (resumed since the read) drops out at once; a provider this build cannot start is not offered.
    func homeContinueEntries() -> [HomeContinueEntry] {
        home.quitRuns.compactMap { run in
            let record = run.session
            let id = record.session.id
            guard canResumeFromHome(record) else { return nil }
            let name = projectName(for: record)
            return HomeContinueEntry(
                id: id, title: record.displayTitle(projectName: name), projectName: name,
                tone: projectTone(forProject: record.projectID), provider: record.session.provider, endedAt: run.endedAt)
        }
    }

    /// Whether Resume applies to a session the catalog lists: the rule of `canResume(_:)` without needing a row.
    func canResumeFromHome(_ record: CatalogSession) -> Bool {
        let id = record.session.id
        let provider = record.session.provider
        return actionsAvailable && capabilities(of: provider).startable
            && liveStates[id]?.runID == nil && busy[id] == nil && !isDeleting(id)
    }

    /// Resume on a Continue card: the existing resume path, which selects the session once its run is up. The
    /// card is dropped from the list Home holds, so stopping the session again does not bring it back; the next
    /// read finds a later run and leaves it out too.
    public func resumeFromHome(_ id: UUID) {
        guard let held = home.quitRuns.first(where: { $0.session.session.id == id }), canResumeFromHome(held.session) else { return }
        resumeConversation(id)
        home.quitRuns.removeAll { $0.session.session.id == id }
    }

    // MARK: New session

    /// The project the sidebar's "New session" opens its draft in, as far as the window knows it: the catalog's last-used
    /// project (kept by the last read), else the first project. Nil when there is no project. `beginNewSessionInRecentProject`
    /// asks the catalog itself, so the view, a search or a relaunch change nothing.
    var mostRecentProjectID: UUID? {
        let known = Set(projects.map(\.id))
        if let last = home.lastUsedProjectID, known.contains(last) { return last }
        return projects.first?.id
    }

    /// Whether the sidebar's "New session" row works: only whether Claude can start at all. A start somewhere else does not
    /// matter, since the row opens a draft and starts nothing.
    var newSessionRowAvailable: Bool { actionsAvailable && capabilities(of: .newSessionDefault).startable }

    /// The most recently used project, read from the catalog now (the project of the newest session that has one); the
    /// last known one or the first project when the read fails or finds none.
    func recentProjectForNewSession() async -> UUID? {
        let known = Set(projects.map(\.id))
        if let catalog, let last = try? await catalog.lastUsedProjectID(), known.contains(last) {
            if home.lastUsedProjectID != last { home.lastUsedProjectID = last }
            return last
        }
        return mostRecentProjectID
    }

    /// The sidebar's "New session" row (and ⌘N on Home): the draft page in the most recently used project. The project
    /// is the persisted one, read when the row is clicked, so it holds in the Projects view, with a search and after a
    /// relaunch. The draft's own project picker still changes it.
    public func beginNewSessionInRecentProject() {
        Task { [weak self] in
            guard let self else { return }
            beginNewSession(projectID: await recentProjectForNewSession())
        }
    }

    /// ⌘N and the menu's "New Claude Session": on Home the same draft as the sidebar's row; elsewhere the draft of the
    /// project on screen.
    public func beginNewSessionFromCommand() {
        if destination == .home { beginNewSessionInRecentProject() } else { beginNewSession(projectID: contextProjectID) }
    }

    // MARK: First run and the empty catalog

    /// Nothing in the catalog: no project and no session. Home says so itself, with the way to add a project.
    var homeCatalogIsEmpty: Bool {
        isReady && projects.isEmpty && list(for: .activity).rows.isEmpty && !isSearching
    }

    /// Sphyrna could not find the Claude CLI to start sessions with: the harness health says "Not found" for Claude (D-98), read
    /// from the check Connections makes, so Home starts no process to find out. False until a check has said so, and again
    /// once one finds it.
    var homeClaudeCLIMissing: Bool {
        harnessHealth?.health(of: .claude).state == .install
    }

    // MARK: Reading the catalog

    /// Reads what only the catalog knows, once per Home opening (and again when `HomeReadKey` changes): the
    /// sessions Quit cut short, the sessions used today and the last-used project. Three small queries; no
    /// process, no timer.
    func refreshHome() async {
        guard let catalog, isReady else { return }
        home.todayStamp = usage?.updatedAt
        let read = currentDate()
        let since = read.addingTimeInterval(-TimeInterval(HomeLimits.continueDays) * 86_400)
        let startOfDay = Calendar.current.startOfDay(for: read)
        do {
            let quit = try await catalog.sessionsEndedByQuit(since: since, limit: HomeLimits.continueRead)
            let today = try await catalog.sessionCount(activeSince: startOfDay)
            let last = try await catalog.lastUsedProjectID()
            if home.quitRuns != quit { home.quitRuns = quit }
            if home.sessionsToday != today { home.sessionsToday = today }
            if home.lastUsedProjectID != last { home.lastUsedProjectID = last }
            home.hasRead = true
            home.reads += 1
        } catch {
            report(error, "Home could not read the session list")
        }
    }

    /// The usage refresh ended (a turn finished): reads "sessions today" again and nothing else, one count
    /// instead of the full read's scan of the runs. The Continue list and the start box's project wait for the
    /// next full read. Skipped before the first full read, and when the full read that just ran went with this
    /// refresh.
    func refreshHomeToday() async {
        guard let catalog, isReady, home.hasRead, home.todayStamp != usage?.updatedAt else { return }
        let stamp = usage?.updatedAt
        home.todayStamp = stamp
        do {
            let today = try await catalog.sessionCount(activeSince: Calendar.current.startOfDay(for: currentDate()))
            if home.sessionsToday != today { home.sessionsToday = today }
            home.todayReads += 1
        } catch {
            report(error, "Home could not read the session list")
        }
    }
}
