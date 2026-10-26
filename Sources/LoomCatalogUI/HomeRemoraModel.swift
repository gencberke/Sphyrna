import Foundation
import LoomCore
import LoomRemora

// What Home draws of Remora, as plain values (DESIGN §9 and §20). The views read these; a test reads them without a view. Nothing
// here keeps Remora's data: every value is built again from the model each time Home draws, and a session that is gone from the
// catalog is left out.

// MARK: A session as Home names it

/// A session Remora names, as the catalog and the live state say it now.
struct HomeRemoraSession: Equatable, Identifiable {
    let id: UUID
    let projectID: UUID?
    let projectName: String?
    let tone: ProjectTone?
    let provider: ManagedSession.Provider
    let title: String
    let lastActivityAt: Date
    let indicator: SessionIndicator
}

/// A project Home may name in a quiet line.
struct HomeRemoraProject: Equatable {
    let id: UUID
    let name: String
    let tone: ProjectTone?
}

// MARK: The brief

/// The day's brief as Home shows it: the model's last answer when that was a brief, or the one Remora kept for the day.
struct HomeRemoraBrief: Equatable {
    var text: String
    var chips: [RemoraChip]
    var drafts: [RemoraDraft]
    var readSessionIDs: [UUID]
    var footer: String
    var startedAt: Date?
    var duration: TimeInterval?
    var tokens: Int?

    /// The kept brief is the day's, read back from disk after every brief and every deletion; the answer of this run stands only
    /// until it is written. Nil before either exists.
    static func current(kept: RemoraKeptBrief?, lastAnswer: RemoraHostAnswer?) -> HomeRemoraBrief? {
        let own = lastAnswer.flatMap { $0.kind == .brief ? $0 : nil }
        if let kept {
            // The numbers belong to the answer only while it is the same brief.
            let same = own.map { $0.answer.text == kept.text } ?? false
            return HomeRemoraBrief(
                text: kept.text, chips: kept.chips, drafts: kept.drafts, readSessionIDs: kept.readSessionIDs, footer: kept.footer,
                startedAt: kept.startedAt, duration: same ? own.map { HomeRemoraText.seconds($0.answer.duration) } : nil,
                tokens: same ? own.map { $0.answer.usage.total } : nil)
        }
        guard let own else { return nil }
        return HomeRemoraBrief(
            text: own.answer.text, chips: own.answer.chips, drafts: own.answer.drafts, readSessionIDs: own.readSessionIDs,
            footer: own.footer, startedAt: nil, duration: HomeRemoraText.seconds(own.answer.duration), tokens: own.answer.usage.total)
    }
}

// MARK: The state

/// Why Remora cannot write the brief, in Sphyrna's words (`HomeRemoraText`).
enum HomeRemoraCannotAnswer: Equatable {
    case login
    /// The 5-hour limit is low: the morning brief waits, questions still run, and Catch Me Up Anyway asks.
    case wait
    /// Any other failure; Try Again.
    case generic(RemoraFailure.Kind)
}

/// Which Home Remora gives, chosen from the preferences and the state of the last calls.
enum HomeRemoraState: Equatable {
    /// Remora is off (or has no host): Home is the band and Needs you.
    case off
    /// No session yet: the band, one line about what Remora will do, and Needs you.
    case beforeAnySession
    /// A brief is being written.
    case reading
    case cannotAnswer(HomeRemoraCannotAnswer)
    /// A brief was stopped.
    case stoppedBrief
    /// The brief, with its tiles.
    case brief
    /// The brief, folded: one of its entries was picked up.
    case folded
    /// No brief to show and none running (When I ask, or nothing moved): the catalog's tiles with Catch Me Up.
    case whenIAsk

    struct Inputs: Equatable {
        var hasHost = true
        var isOn = true
        var hasSessions = true
        var phase: RemoraModelState.Phase = .idle
        /// The failure of the last brief; nil when the last call that failed was a question (the answer shows that one).
        var briefFailure: RemoraFailure.Kind?
        var decision: RemoraBriefDecision?
        var stopped: RemoraModelState.StoppedCall?
        var hasBrief = false
        /// How many of the brief's entries were picked up, and whether the user brought the whole brief back.
        var pickedUp = 0
        var expanded = false
    }

    /// The order matters: off, no session, a brief being written, a failure, a wait, a stopped brief, the brief, nothing.
    static func choose(_ input: Inputs) -> HomeRemoraState {
        guard input.hasHost, input.isOn else { return .off }
        guard input.hasSessions else { return .beforeAnySession }
        if input.phase == .briefing { return .reading }
        if let failure = input.briefFailure { return .cannotAnswer(failure == .notLoggedIn ? .login : .generic(failure)) }
        if !input.hasBrief, case .wait? = input.decision { return .cannotAnswer(.wait) }
        if input.stopped == .brief { return .stoppedBrief }
        if input.hasBrief { return input.pickedUp > 0 && !input.expanded ? .folded : .brief }
        return .whenIAsk
    }

    /// Whether Home puts Remora's section in the band's place.
    var replacesBand: Bool {
        switch self {
        case .off, .beforeAnySession: false
        default: true
        }
    }
}

// MARK: Tiles

struct HomeRemoraTile: Equatable, Identifiable {
    var id: UUID { session.id }
    let session: HomeRemoraSession
    /// The chip's "where to pick up" line; nil for a catalog tile and for a chip Remora wrote none for.
    let next: String?
    /// The line Put in Draft leaves; nil for a catalog tile and for a session Remora wrote no line for.
    let draft: String?
    /// A catalog tile has Open only.
    let isCatalog: Bool
}

/// A project beyond the three tiles that moved: one line.
struct HomeRemoraFurther: Equatable, Identifiable {
    var id: UUID { session.id }
    let session: HomeRemoraSession
    let why: String
}

struct HomeRemoraQuiet: Equatable, Identifiable {
    var id: UUID { project.id }
    let project: HomeRemoraProject
    let since: Date
}

struct HomeRemoraTilePlan: Equatable {
    var tiles: [HomeRemoraTile] = []
    var further: [HomeRemoraFurther] = []
    var quiet: [HomeRemoraQuiet] = []
}

/// Builds the tiles from Remora's chips and drafts and the catalog (the map's 2.3, decided 21 Oct). Pure.
enum HomeRemoraTiles {
    static let maxTiles = 3

    /// - `sessions`: the sessions that exist now, by id. A chip whose session is not there is hidden (it was deleted).
    /// - `excluded`: projects Settings keeps Remora out of; none is ever named.
    /// - `latest`: each project's newest activity, for the quiet lines; `before`: the brief's start, after which a project is not quiet.
    static func brief(chips: [RemoraChip], drafts: [RemoraDraft], sessions: [UUID: HomeRemoraSession],
                      excluded: Set<UUID>, projects: [HomeRemoraProject] = [], latest: [UUID: Date] = [:],
                      before: Date? = nil) -> HomeRemoraTilePlan {
        var plan = HomeRemoraTilePlan()
        var seen = Set<UUID>()
        var named = Set<UUID>()
        for chip in chips {
            guard let id = UUID(uuidString: chip.sessionID), let session = sessions[id] else { continue }
            if let project = session.projectID, excluded.contains(project) { continue }
            // One entry for each project that moved: the first chip of the project is its tile.
            guard seen.insert(session.projectID ?? session.id).inserted else { continue }
            if let project = session.projectID { named.insert(project) }
            if plan.tiles.count < maxTiles {
                let next = chip.next.isEmpty ? nil : chip.next
                let draft = drafts.first { $0.sessionID == chip.sessionID }?.text
                plan.tiles.append(HomeRemoraTile(session: session, next: next, draft: draft, isCatalog: false))
            } else {
                plan.further.append(HomeRemoraFurther(session: session, why: chip.why))
            }
        }
        plan.quiet = quiet(projects: projects, latest: latest, named: named, excluded: excluded, before: before)
        return plan
    }

    /// When Remora cannot answer and when the user asks: the newest sessions, one for each project, with Open only.
    static func catalog(recent: [HomeRemoraSession], excluded: Set<UUID>) -> [HomeRemoraTile] {
        var seen = Set<UUID>()
        var tiles: [HomeRemoraTile] = []
        for session in recent.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }) {
            if let project = session.projectID, excluded.contains(project) { continue }
            guard seen.insert(session.projectID ?? session.id).inserted else { continue }
            tiles.append(HomeRemoraTile(session: session, next: nil, draft: nil, isCatalog: true))
            if tiles.count == maxTiles { break }
        }
        return tiles
    }

    /// Projects that did not move since the brief and that it did not name, newest first.
    static func quiet(projects: [HomeRemoraProject], latest: [UUID: Date], named: Set<UUID>, excluded: Set<UUID>,
                      before: Date?) -> [HomeRemoraQuiet] {
        projects.compactMap { project -> HomeRemoraQuiet? in
            guard !named.contains(project.id), !excluded.contains(project.id), let date = latest[project.id] else { return nil }
            if let before, date > before { return nil }
            return HomeRemoraQuiet(project: project, since: date)
        }
        .sorted { $0.since > $1.since }
    }

    /// How many entries were picked up: their session ran after the brief began.
    static func pickedUp(_ tiles: [HomeRemoraTile], since start: Date?) -> Int {
        guard let start else { return 0 }
        return tiles.filter { $0.session.lastActivityAt > start }.count
    }

    /// The tile's state line in the catalog's words: "Working", "Finished 25m ago, not read", "Failed", "Last active 3h ago".
    static func stateText(_ indicator: SessionIndicator, lastActivityAt: Date, now: Date) -> String {
        let age = HomeAgeText.ago(from: lastActivityAt, to: now)
        switch indicator {
        case .unviewedCompletion: return "Finished \(age), not read"
        case .failed(let message): return message.map { "Failed \u{00B7} \($0)" } ?? "Failed"
        case .problem(let text), .stopUnverified(let text): return text
        case .working, .waitingForApproval, .waitingForInput, .unknown, .identityUnclear, .ready, .idle, .stale:
            return indicator.label ?? "Last active \(age)"
        case .ended: return "Last active \(age)"
        }
    }
}

// MARK: The field's keys

/// The field takes ↵, Esc and ↑ only while it is focused (its own key handling, no default or cancel action). Pure.
enum HomeRemoraFieldKeys {
    enum Key: Equatable { case `return`, escape, up }

    enum Action: Equatable {
        case ask(String)
        case stop
        /// ↑ in the empty field brings the last question back.
        case recall(String)
        case nothing
    }

    struct Outcome: Equatable {
        let action: Action
        /// The key was used; an unused key goes on to the field (↑ moves the caret in text).
        let handled: Bool
    }

    static func resolve(_ key: Key, text: String, busy: Bool, lastQuestion: String?) -> Outcome {
        switch key {
        case .return:
            let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A call runs: the key is used and asks nothing (the model refuses a second call).
            if busy || question.isEmpty { return Outcome(action: .nothing, handled: true) }
            return Outcome(action: .ask(question), handled: true)
        case .escape:
            return busy ? Outcome(action: .stop, handled: true) : Outcome(action: .nothing, handled: false)
        case .up:
            guard text.isEmpty, let lastQuestion, !lastQuestion.isEmpty else { return Outcome(action: .nothing, handled: false) }
            return Outcome(action: .recall(lastQuestion), handled: true)
        }
    }
}

// MARK: Showing Home

/// What the main window looks like to the morning brief.
struct HomeWindowFacts: Equatable {
    var hasWindow = false
    var isMiniaturized = false
    var occlusionVisible = false

    static let none = HomeWindowFacts()
}

/// The automatic brief's rule and its one call, made when Home shows (DESIGN §20 Cost: the first Home of the day, D-64).
enum HomeRemoraShow {
    /// Home is shown for the brief when its route is up and the main window is on screen: not miniaturized, and with `.visible` in its
    /// occlusion state.
    static func homeShown(routeIsHome: Bool, window: HomeWindowFacts) -> Bool {
        routeIsHome && window.hasWindow && !window.isMiniaturized && window.occlusionVisible
    }

    /// Whether the automatic brief is asked at all: Remora on, with a host, set to Automatic.
    static func asksForBrief(isOn: Bool, hasHost: Bool, mode: RemoraBriefMode) -> Bool { isOn && hasHost && mode == .automatic }
}
