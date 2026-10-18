import Foundation
import LoomCore
import Observation

/// The state of the Home screen (V05) that the model does not already hold: what the catalog was asked when
/// Home opened, and the project the start box is on. Everything else Home shows (the sessions that need the
/// user, the plan limits, the clock) is read from the model when it draws; nothing here polls.
@MainActor @Observable
public final class HomeState {
    /// Sessions whose latest run Quit (or a crash) ended and that were not resumed since, newest first.
    public internal(set) var quitRuns: [CatalogQuitRun] = []
    /// How many sessions were used since the start of the day; nil until the first read.
    public internal(set) var sessionsToday: Int?
    /// The project of the most recently used session: where the start box begins.
    public internal(set) var lastUsedProjectID: UUID?
    /// A project picked in the start box, for this window run only.
    public internal(set) var chosenProjectID: UUID?
    /// The catalog was read at least once, so an empty Continue is "none", not "not read yet".
    public internal(set) var hasRead = false
    /// How many times the catalog was read for Home (a test counts it).
    @ObservationIgnored public internal(set) var reads = 0

    public init() {}
}

/// What development evidence reads of Home (see `CatalogModel.homeSummary()`).
public struct HomeSummary: Equatable, Sendable {
    public let needsYou: [UUID]
    public let finished: [UUID]
    public let continueSessions: [UUID]
    public let sessionsToday: Int?
    public let startProjectID: UUID?
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
    let endedAt: Date
}

/// What a read of the catalog for Home depends on: it runs when Home appears, once the model is ready, when the
/// day turns, when the number of sessions changes, when the runtime has closed the runs an earlier Loom left
/// open, and when the usage refresh ends (a turn in a session that already exists moves "sessions today"
/// without changing any count; the refresh is already debounced and reads no timer).
struct HomeReadKey: Equatable {
    let ready: Bool
    let day: Date
    let counts: [UUID?: Int]
    let runsRecovered: Int
    let usageRefreshed: Date?
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
        HomeReadKey(ready: isReady, day: today, counts: sessionCounts, runsRecovered: runsRecovered,
                    usageRefreshed: usage?.updatedAt)
    }

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
                tone: projectTone(forProject: record.projectID), indicator: candidate.indicator,
                reason: SessionReasonLine(liveStates[id]?.reason), lastActivityAt: candidate.lastActivityAt)
            if HomeBoard.isFinished(candidate.indicator) { board.finished.append(entry) } else { board.needsYou.append(entry) }
        }
        return board
    }

    // MARK: Evidence

    /// Home in numbers and ids, for development evidence: no title, project name or line (those are content).
    public func homeSummary() -> HomeSummary {
        let board = homeBoard()
        return HomeSummary(
            needsYou: board.needsYou.map(\.id), finished: board.finished.map(\.id),
            continueSessions: homeContinueEntries().map(\.id), sessionsToday: home.sessionsToday,
            startProjectID: homeStartProjectID, emptyCatalog: homeCatalogIsEmpty, claudeMissing: homeClaudeCLIMissing,
            paces: homePaces().count, reads: home.reads)
    }

    /// Development evidence: Resume on a Continue card, and another project in the start box.
    public func resumeHomeForEvidence(_ id: UUID) { resumeFromHome(id) }
    public func chooseHomeProjectForEvidence(_ id: UUID) { chooseHomeStartProject(id) }

    // MARK: Plan limits

    /// The pace of each plan window at the model's clock. Reading `now` here is what lets the minute tick
    /// redraw the pace line, and only while a view that reads this is on screen; a window that has ended
    /// drops out by itself. Pure arithmetic over the last answer: nothing is asked.
    func homePaces() -> [PlanPace] { usage?.paces(at: now) ?? [] }

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
                tone: projectTone(forProject: record.projectID), endedAt: run.endedAt)
        }
    }

    /// Whether Resume applies to a session the catalog lists: the rule of `canResume(_:)` without needing a row.
    func canResumeFromHome(_ record: CatalogSession) -> Bool {
        let id = record.session.id
        let provider = record.session.provider
        return actionsAvailable && provider != .synthetic && startableProviders.contains(provider)
            && liveStates[id]?.runID == nil && busy[id] == nil && !isDeleting(id)
    }

    /// Resume on a Continue card: the existing resume path, which selects the session once its run is up. The
    /// card is dropped from the list Home holds, so stopping the session again does not bring it back; the next
    /// read finds a later run and leaves it out too.
    func resumeFromHome(_ id: UUID) {
        guard let held = home.quitRuns.first(where: { $0.session.session.id == id }), canResumeFromHome(held.session) else { return }
        resumeConversation(id)
        home.quitRuns.removeAll { $0.session.session.id == id }
    }

    // MARK: The start box

    /// The project the start box is on: the one picked there, else the project of the most recently used
    /// session, else the first project. Nil when there is no project (the draft then has none).
    var homeStartProjectID: UUID? {
        let known = Set(projects.map(\.id))
        if let chosen = home.chosenProjectID, known.contains(chosen) { return chosen }
        if let last = home.lastUsedProjectID, known.contains(last) { return last }
        return projects.first?.id
    }

    /// The start box is on another project; its draft slot starts empty or as it was left.
    func chooseHomeStartProject(_ id: UUID) {
        guard home.chosenProjectID != id else { return }
        home.chosenProjectID = id
        prepareHomeStart()
    }

    /// Opens the draft slot behind the start box, as the draft screen does: a slot with text comes back as
    /// it was, an empty one lives in memory only.
    func prepareHomeStart() {
        let projectID = homeStartProjectID
        prepareNewSession()
        newSession.open(projectID: projectID)
        loadDraftBranch(projectID: projectID)
        refreshTicket(projectID: projectID)
    }

    // MARK: First run and the empty catalog

    /// Nothing in the catalog: no project and no session. Home says so itself, with the way to add a project.
    var homeCatalogIsEmpty: Bool {
        isReady && projects.isEmpty && list(for: .activity).rows.isEmpty && !isSearching
    }

    /// Loom could not find a Claude CLI to start sessions with. Read from the plan-limits ask Loom already
    /// makes on launch (its failure `noToolchain`: no Claude CLI could be resolved), so Home starts no
    /// process to find out. False until that ask has failed that way, and again after one succeeds.
    var homeClaudeCLIMissing: Bool {
        usage?.limitsFailure?.category == .noToolchain
    }

    /// "Check Again" on the missing-CLI notice: asks for the plan limits again, which resolves the Claude CLI
    /// again. The user's own action; nothing runs by itself.
    func recheckClaude() { usage?.refresh(reason: .manual) }

    // MARK: Reading the catalog

    /// Reads what only the catalog knows, once per Home opening (and again when `HomeReadKey` changes): the
    /// sessions Quit cut short, the sessions used today and the last-used project. Three small queries; no
    /// process, no timer.
    func refreshHome() async {
        guard let catalog, isReady else { return }
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
}
