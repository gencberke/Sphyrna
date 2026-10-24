import Foundation
import LoomCore
import LoomRemora

// Remora's brief on the new-session page (DESIGN §8 "Remora's brief", §20 "A new session's brief", D-80): the row under the
// presets, the line above the composer and Put in Draft's rule for the draft's composer. Plain values, so a test reads the words
// and the states without a view. The one call is the row's (`DraftRemoraViews.swift`); nothing here calls Remora, and nothing
// here sends: a brief goes to the draft's text or to the pasteboard (D-64).

/// Where a draft's brief came from: kept while the draft's text is Remora's (`NewSessionState.remoraOrigins`, by draft id).
struct DraftRemoraOrigin: Equatable {
    var project: UUID
    var draftedAt: Date
    var sessionsRead: Int
    var citedSessionIDs: [UUID]
    /// `.placed` (the brief is the composer's text) or `.copiedHasDraft` (the composer kept its text).
    var result: RemoraDraftResult
    /// The text put in the composer, so Draft Again can tell Remora's untouched brief from the user's own text. Memory only.
    var placedText: String?
    /// How long the call took, from the click; nil when it did not start from the row.
    var duration: TimeInterval?
}

/// What the row and the line above the composer say (Sphyrna's plain voice; the brief itself is the model's).
enum DraftRemoraText {
    static let draftBrief = "Draft Brief"
    static let draftAgain = "Draft Again"
    static let stop = "Stop"
    static let sources = "Sources"
    static let clear = "Clear"
    static let originTitle = "Remora's draft"
    static let drafted = "Remora drafted the brief above. Nothing is sent until you press \u{21B5}."
    /// Put in Draft's rule when the composer has text (proposed: DESIGN names the rule, not the row's words).
    static let copied = "Remora drafted the brief. The composer has text, so it was copied instead."
    /// While another Remora call runs (proposed: DESIGN is silent).
    static let busy = "Remora is busy with another call. Draft Brief waits until it ends."
    /// After Stop, in the words of Home's stopped brief ("Stopped. Catch Me Up writes the whole brief.").
    static let stopped = "Stopped. Draft Brief writes the whole brief."

    static func offer(projectName: String) -> String { "Remora can write this session's brief from \(projectName)'s recent work." }

    /// "Reading 3 sessions in loom and its note…", Home's reading line for the project; before the pack is built, "Reading the
    /// sessions in loom…".
    static func reading(_ reading: RemoraReading?, projectName: String, project: UUID) -> String {
        guard var reading else { return "Reading the sessions in \(projectName)\u{2026}" }
        if reading.project?.name == nil { reading.project = RemoraReading.Project(id: project, name: projectName) }
        return HomeRemoraText.readingLine(reading)
    }

    /// "from 3 sessions in loom · not sent".
    static func originDetail(sessionsRead: Int, projectName: String) -> String {
        "from \(HomeRemoraText.plural(sessionsRead, "session")) in \(projectName) \u{00B7} not sent"
    }

    /// The Sources popover's foot: "3 sessions · 6.2 s".
    static func sourcesFoot(sessionsRead: Int, duration: TimeInterval?) -> String {
        let sessions = HomeRemoraText.plural(sessionsRead, "session")
        guard let duration else { return sessions }
        return sessions + " \u{00B7} " + HomeRemoraText.seconds(duration)
    }

    /// The row's time: how long the call took ("6.2 s"), or, when that is not known, when it answered ("11:20").
    static func time(_ origin: DraftRemoraOrigin, zone: TimeZone? = nil, locale: Locale = .current,
                     calendar: Calendar = .current) -> String {
        if let duration = origin.duration { return HomeRemoraText.seconds(duration) }
        return LoomDateFormat.time24(origin.draftedAt, zone: zone, locale: locale, calendar: calendar)
    }
}

/// The row under the presets, as a value: nil is no row.
struct DraftRemoraRow: Equatable {
    enum Phase: Equatable {
        case offer
        case busy
        case reading
        case drafted
        case copied
        case failed
        case stopped
    }

    enum Action: Equatable {
        case draft
        case stop
        case draftAgain
    }

    /// What the row is made from.
    struct Facts {
        var hasHost: Bool
        var isOn: Bool
        var excluded: Bool
        var sessionCount: Int
        var projectID: UUID?
        var projectName: String
        var draft: RemoraModelState.DraftState
        /// Home's call (or ⌘K's) runs.
        var remoraBusy: Bool
        var origin: DraftRemoraOrigin?
        var slotHasText: Bool
        var zone: TimeZone? = nil
    }

    var phase: Phase
    var text: String
    /// The time after the words (drafted and copied).
    var time: String?
    var action: Action
    var actionEnabled: Bool
    var showsSpinner: Bool { phase == .reading }
    /// Sources sits in the row only when the brief was copied: a placed brief has it on the line above the composer.
    var showsSources: Bool { phase == .copied }
    var actionTitle: String {
        switch action {
        case .draft: DraftRemoraText.draftBrief
        case .stop: DraftRemoraText.stop
        case .draftAgain: DraftRemoraText.draftAgain
        }
    }

    /// With Remora on (and a host), for a project that is not excluded and has a session; the states of a draft for another
    /// project are not this page's, they only make it busy.
    static func make(_ facts: Facts) -> DraftRemoraRow? {
        guard facts.hasHost, facts.isOn, let project = facts.projectID, !facts.excluded, facts.sessionCount > 0 else { return nil }
        let name = facts.projectName
        var otherDraftRuns = false
        switch facts.draft {
        case let .reading(running, reading):
            if running == project {
                return DraftRemoraRow(phase: .reading, text: DraftRemoraText.reading(reading, projectName: name, project: project),
                                      time: nil, action: .stop, actionEnabled: true)
            }
            otherDraftRuns = true
        case let .failed(failed, _, sentence) where failed == project:
            return DraftRemoraRow(phase: .failed, text: sentence, time: nil, action: .draft, actionEnabled: !facts.remoraBusy)
        case let .stopped(stopped) where stopped == project:
            return DraftRemoraRow(phase: .stopped, text: DraftRemoraText.stopped, time: nil, action: .draft, actionEnabled: !facts.remoraBusy)
        default:
            break
        }
        let free = !facts.remoraBusy && !otherDraftRuns
        if let origin = facts.origin, origin.project == project {
            let time = DraftRemoraText.time(origin, zone: facts.zone)
            if origin.result == .placed, facts.slotHasText {
                return DraftRemoraRow(phase: .drafted, text: DraftRemoraText.drafted, time: time, action: .draftAgain, actionEnabled: free)
            }
            if origin.result != .placed {
                return DraftRemoraRow(phase: .copied, text: DraftRemoraText.copied, time: time, action: .draftAgain, actionEnabled: free)
            }
        }
        if !free { return DraftRemoraRow(phase: .busy, text: DraftRemoraText.busy, time: nil, action: .draft, actionEnabled: false) }
        return DraftRemoraRow(phase: .offer, text: DraftRemoraText.offer(projectName: name), time: nil, action: .draft, actionEnabled: true)
    }
}

/// The line above the composer, as a value: shown while the slot's text is the brief Remora placed.
struct DraftRemoraOriginLine: Equatable {
    var title: String
    var detail: String
    var citedSessionIDs: [UUID]
    var sessionsRead: Int
    var duration: TimeInterval?

    static func make(origin: DraftRemoraOrigin?, project: UUID?, projectName: String, slotHasText: Bool) -> DraftRemoraOriginLine? {
        guard let origin, origin.project == project, origin.result == .placed, slotHasText else { return nil }
        return DraftRemoraOriginLine(title: DraftRemoraText.originTitle,
                                     detail: DraftRemoraText.originDetail(sessionsRead: origin.sessionsRead, projectName: projectName),
                                     citedSessionIDs: origin.citedSessionIDs, sessionsRead: origin.sessionsRead, duration: origin.duration)
    }
}

extension CatalogModel {
    private func remoraSlot(_ projectID: UUID?) -> (origin: DraftRemoraOrigin?, hasText: Bool) {
        (newSession.remoraOrigin(for: projectID), newSession.draft(for: projectID)?.hasText ?? false)
    }

    /// The row this page shows now; nil is no row.
    func draftRemoraRow(projectID: UUID?) -> DraftRemoraRow? {
        let slot = remoraSlot(projectID)
        let preferences = remora.preferences
        return DraftRemoraRow.make(DraftRemoraRow.Facts(
            hasHost: hasRemora, isOn: preferences.isOn,
            excluded: projectID.map { preferences.excludedProjects.contains($0) } ?? false,
            sessionCount: projectID.flatMap { sessionCounts[$0] } ?? 0, projectID: projectID,
            projectName: draftProject(projectID)?.name ?? "this project", draft: remora.draft, remoraBusy: remora.isBusy,
            origin: slot.origin, slotHasText: slot.hasText))
    }

    /// The line above the composer; nil when the composer's text is not Remora's brief, or the row is not there.
    func draftRemoraOriginLine(projectID: UUID?) -> DraftRemoraOriginLine? {
        guard draftRemoraRow(projectID: projectID) != nil else { return nil }
        let slot = remoraSlot(projectID)
        return DraftRemoraOriginLine.make(origin: slot.origin, project: projectID,
                                          projectName: draftProject(projectID)?.name ?? "this project", slotHasText: slot.hasText)
    }

    /// The row's click, before its call: the time it started, for the row's time.
    func noteRemoraDraftClick(projectID: UUID, at date: Date = Date()) {
        newSession.open(projectID: projectID)
        if let id = newSession.currentID(for: projectID) { newSession.remoraStartedAt[id] = date }
    }

    /// The call was refused: no time to keep.
    func forgetRemoraDraftClick(projectID: UUID) {
        if let id = newSession.currentID(for: projectID) { newSession.remoraStartedAt[id] = nil }
    }

    /// Puts a drafted brief in its project's draft by Put in Draft's rule, once: an empty composer takes it; a composer with text
    /// keeps it and the brief is copied. A composer that still holds Remora's last brief, untouched, counts as empty (Draft Again
    /// replaces it). Returns what it did, or nil when there is no new brief. Never sends.
    @discardableResult
    func landRemoraDraft(copy: (String) -> Void = RemoraPutInDraft.copyToPasteboard) -> RemoraDraftResult? {
        guard case let .drafted(brief) = remora.draft, newSession.remoraLanded != brief.draftedAt else { return nil }
        newSession.remoraLanded = brief.draftedAt
        let project = brief.project
        let state = newSession
        state.open(projectID: project)
        guard let id = state.currentID(for: project) else { return nil }
        let previous = state.remoraOrigins[id]
        let target = RemoraDraftTarget.newSessionComposer(
            project: project,
            hasText: {
                guard let draft = state.draft(for: project), draft.hasText else { return false }
                return previous?.placedText.map { $0 != draft.text } ?? true
            },
            setText: { [weak self] text in self?.setDraftText(text, projectID: project) })
        let result = RemoraPutInDraft.perform(target, line: brief.text, copy: copy)
        let started = state.remoraStartedAt.removeValue(forKey: id)
        state.remoraOrigins[id] = DraftRemoraOrigin(
            project: project, draftedAt: brief.draftedAt, sessionsRead: brief.sessionsRead, citedSessionIDs: brief.citedSessionIDs,
            result: result, placedText: result == .placed ? brief.text : nil,
            duration: started.map { max(0, brief.draftedAt.timeIntervalSince($0)) })
        return result
    }

    /// Clear on the line above the composer: the brief leaves the composer, and the row offers Draft Brief again.
    func clearRemoraDraft(projectID: UUID) {
        if let id = newSession.currentID(for: projectID) { newSession.remoraOrigins[id] = nil }
        setDraftText("", projectID: projectID)
    }

    /// Draft Brief's state in numbers and ids for the evidence snapshot: never the brief's text.
    public var draftRemoraEvidence: [String: Any] {
        var result: [String: Any] = [:]
        switch remora.draft {
        case .idle:
            result["phase"] = "idle"
        case let .reading(project, reading):
            result["phase"] = "reading"
            result["project"] = project.uuidString
            result["sessionsRead"] = reading?.sessions ?? NSNull()
        case let .drafted(brief):
            result["phase"] = "drafted"
            result["project"] = brief.project.uuidString
            result["sessionsRead"] = brief.sessionsRead
            result["cited"] = brief.citedSessionIDs.count
            if let origin = newSession.remoraOrigin(for: brief.project), origin.draftedAt == brief.draftedAt {
                result["landed"] = origin.result == .placed ? "placed" : "copied"
            } else {
                result["landed"] = NSNull()
            }
        case let .failed(project, failure, _):
            result["phase"] = "failed"
            result["project"] = project.uuidString
            result["failure"] = failure.rawValue
        case let .stopped(project):
            result["phase"] = "stopped"
            result["project"] = project.uuidString
        }
        return result
    }
}
