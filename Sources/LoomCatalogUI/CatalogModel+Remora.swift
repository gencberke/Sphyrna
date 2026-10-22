import Foundation
import LoomCore
import LoomRemora
import Observation

/// What the UI observes of Remora (L3a): one value the model holds. The host (`RemoraHost`) does the work; this holds the
/// state of the call in progress and of the last one, and the preferences. Nothing here draws or starts anything.
@MainActor @Observable
public final class RemoraModelState {
    public enum Phase: Equatable, Sendable {
        case idle
        case asking
        case briefing
    }

    /// Which kind of call was stopped (by Stop, by turning Remora off or by excluding a project): Home says "Stopped. Ask
    /// again…" for a question and the like for a brief.
    public enum StoppedCall: Equatable, Sendable {
        case question
        case brief
    }

    /// Where a call was asked from. Draft Brief keeps its own state (`draft`) and never sets `phase`, `streamedText`,
    /// `lastFailure` or `call`, so it is not one of these.
    public enum Door: Equatable, Sendable {
        /// Home: its field, Catch Me Up (and Try Again), and the automatic brief.
        case home
        /// ⌘K's Ask Remora (and the evidence command that asks as it does).
        case palette
    }

    /// The call `phase`, `streamedText`, `lastFailure` and `stopped` belong to: what it is and which door asked it.
    public struct Call: Equatable, Sendable {
        public var kind: RemoraKind
        public var door: Door
    }

    public internal(set) var phase: Phase = .idle
    /// The visible answer so far; reset when a call starts.
    public internal(set) var streamedText = ""
    /// The last call's answer (a question's or a brief's); kept until the next one ends well.
    public internal(set) var lastAnswer: RemoraHostAnswer?
    /// The last call's failure kind; nil after a call that ended well, and while one runs.
    public internal(set) var lastFailure: RemoraFailure.Kind?
    /// The call that runs, or the last one that started (set when it starts, kept after it ends): whose `phase`, stream,
    /// failure and stop these are. Home shows only its own question's, and only a brief's failure in the brief's place.
    public internal(set) var call: Call?
    /// Facts the last answer proposes, for "Remember this?"; a confirmed or dismissed one leaves the list.
    public internal(set) var proposedFacts: [String] = []
    /// What the calls used, with the drift count; refreshed after every call and every memory change.
    public internal(set) var usage: RemoraUsageSnapshot?
    /// The undo of the last "Remember …", fact confirmation or note removal.
    public internal(set) var lastUndo: RemoraUndoToken?
    /// The fact the last "Remember …" or confirmation saved; nil when it saved none.
    public internal(set) var lastRemembered: String?
    /// Why the last "Remember …" was not saved (`Remora.md` is full, unreadable, …).
    public internal(set) var notSavedReason: String?
    /// Remora's settings as the app holds them (persisted in `UIPreferences.remora`).
    public internal(set) var preferences = RemoraPreferences()
    /// What the last `briefRemoraIfDue` decided when it started no brief (a wait carries its reason: "…left until 13:40, so the
    /// morning brief waits"); nil before any, and cleared when a brief starts. The UI reads the limits' reset itself.
    public internal(set) var lastBriefDecision: RemoraBriefDecision?
    /// The kind of call that was stopped; set when a call ends `.cancelled`, cleared when the next call starts.
    public internal(set) var stopped: StoppedCall?
    /// What the running call reads ("Reading 6 sessions and 3 project notes…"): set once the pack is built and before the
    /// call starts, cleared when the call ends. A "Remember …" makes no pack and sets nothing.
    public internal(set) var reading: RemoraReading?
    /// The day's brief as Remora kept it, so Home can show it after a relaunch the same day. Nothing fills it at launch:
    /// `loadRemoraKeptBrief()` reads it on first use, and a brief that answers replaces it. A copy that a deletion or an
    /// exclusion removed from disk stays until the next load (`loadRemoraKeptBrief()` again), or Clear or an exclusion made
    /// here, which reload it.
    public internal(set) var keptBrief: RemoraKeptBrief?

    /// Draft Brief's row on the new-session page (D-80): its own state, apart from Home's call. Idle until a draft starts.
    public internal(set) var draft: DraftState = .idle

    @ObservationIgnored var host: RemoraHost? {
        didSet { hasHost = host != nil }
    }
    /// Whether the host is installed: the one observed sign of it, so Home asks again when the host arrives after Home showed
    /// (the window is shown before the runtime installs the host).
    public private(set) var hasHost = false
    /// A draft's checks are being made (the catalog read before it starts): nothing else starts meanwhile.
    @ObservationIgnored var draftChecking = false
    @ObservationIgnored var persist: (@MainActor (RemoraPreferences) -> Void)?
    @ObservationIgnored var task: Task<Void, Never>?
    /// An automatic brief is being decided (no phase yet).
    @ObservationIgnored var deciding = false
    /// The memory and settings changes under way; each leaves the list when it ends.
    @ObservationIgnored private var tracked: [UUID: Task<Void, Never>] = [:]
    var pending: [Task<Void, Never>] { Array(tracked.values) }

    public init() {}

    /// What Draft Brief's row shows.
    public enum DraftState: Equatable, Sendable {
        case idle
        /// The call runs. `reading` is what it reads ("Reading 3 sessions in loom and its note…"), set once its pack is
        /// built; nil before that.
        case reading(project: UUID, reading: RemoraReading?)
        case drafted(RemoraDraftedBrief)
        /// The call ended without a draft: the failure's kind and its sentence, worded as a question's failure on Home.
        case failed(project: UUID, failure: RemoraFailure.Kind, sentence: String)
        /// Stop (or Remora turned off, or the project excluded) ended it.
        case stopped(project: UUID)

        /// The draft's call is running.
        public var isReading: Bool {
            if case .reading = self { return true }
            return false
        }
    }

    /// Whether a call runs (the UI offers Stop).
    public var isBusy: Bool { phase != .idle }

    func install(preferences: RemoraPreferences, persist: @escaping @MainActor (RemoraPreferences) -> Void) {
        self.preferences = preferences
        self.persist = persist
    }

    /// Waits for the call and the memory changes started so far (tests).
    func settle() async {
        await task?.value
        for item in pending { await item.value }
    }

    /// Runs `body` as a tracked change; it leaves `pending` when it ends.
    func track(_ body: @escaping @MainActor (RemoraModelState) async -> Void) {
        let id = UUID()
        // The task runs on the main actor after this returns, so it is in the list before it can remove itself.
        tracked[id] = Task { @MainActor in
            await body(self)
            self.tracked[id] = nil
        }
    }
}

/// Remora's model API (L3a): forwards to the host, keeps `remora`'s state. Nothing in the app calls it until L3b's views, and
/// nothing here runs by itself. Without a host (a test, a window with no runtime) every method refuses quietly.
extension CatalogModel {
    // MARK: Install

    /// The app's one install, before `SessionRuntime.start()`: makes the host with the runtime, registers its forgetter (a
    /// deletion that `start()` recovers reaches it) and holds it. Starts nothing and reads nothing but a folder listing.
    public func installRemora(runtime: SessionRuntime, dataRoot: URL,
                              toolchain: @escaping @Sendable () async throws -> ProviderToolchain,
                              profile: ClaudeProfileLayout) async {
        let host = RemoraHost(dataRoot: dataRoot, supervisor: await runtime.supervisor, catalog: await runtime.catalog,
                              sessions: runtime.directory, toolchain: toolchain, profile: profile, settings: remora.preferences)
        host.registerForgetter(in: runtime.conversationForgetters)
        installRemora(host: host)
    }

    func installRemora(host: RemoraHost) { remora.host = host }

    /// Whether Remora has a host (the Home views show nothing of Remora without one). Observed: it turns true when the host is
    /// installed.
    public var hasRemora: Bool { remora.hasHost }

    // MARK: Calls

    /// A question. "Remember …" saves a fact and makes no call. Refused (false) without a host, while a call runs or with
    /// Remora off. `followUp` carries the last answer's exchange; `door` is where it was asked (⌘K's unless Home says so).
    @discardableResult
    public func askRemora(_ question: String, scope: RemoraScope = .allProjects, followUp: Bool = false,
                          door: RemoraModelState.Door = .palette) -> Bool {
        let previous = followUp ? remora.lastAnswer?.exchange : nil
        return startRemora(.asking, door: door) { host, state, _ in
            await host.ask(question, scope: scope, previous: previous, onReading: { state.reading = $0 },
                           onText: { state.streamedText += $0 })
        }
    }

    /// The brief the user asked for: runs whatever the schedule says.
    @discardableResult
    public func briefRemora() -> Bool {
        startRemora(.briefing, door: .home) { host, state, _ in
            await host.brief(onReading: { state.reading = $0 }, onText: { state.streamedText += $0 })
        }
    }

    /// The morning brief, when the schedule says so (`RemoraSchedule`): Remora on and automatic, not briefed today, a session
    /// moved, Home shown, the plan's five-hour window with at least the threshold left (read from the usage model's limits
    /// when known; an unknown window never holds it back). `isOnline` is the one reachability check L3b makes at its call
    /// site (a single read of the path's state, no watcher): offline starts nothing and records nothing, so the next call
    /// tries again. The phase becomes `briefing` only when a brief really starts. Nothing calls this in L3a.
    @discardableResult
    public func briefRemoraIfDue(homeShown: Bool, isOnline: Bool = true) -> Bool {
        guard isOnline else { return false }
        let share = remainingFiveHourShare()
        return startRemora(nil, door: .home) { host, state, started in
            await host.briefIfDue(homeShown: homeShown, windowRemainingShare: share, onStart: started,
                                  onReading: { state.reading = $0 }, onText: { state.streamedText += $0 })
        }
    }

    /// The plan's five-hour window share that is left, 0...1; nil when the limits are not known or the window is over.
    func remainingFiveHourShare(now: Date = Date()) -> Double? { Self.remainingFiveHourShare(of: usage?.limits, now: now) }

    nonisolated static func remainingFiveHourShare(of limits: PlanLimits?, now: Date) -> Double? {
        guard let window = limits?.fiveHour, window.isCurrent(at: now) else { return nil }
        return Double(window.remainingPercent) / 100
    }

    // MARK: Draft Brief

    /// Draft Brief (the new-session page's row, D-80): one call, on the click, that writes an unsent brief for `project`'s next
    /// session into `remora.draft` (reading, then drafted, failed or stopped). Nothing is sent: placing the text in the composer
    /// is the UI's (Put in Draft's rule). Returns once the call has started (true); false, with no child started, without a
    /// host, while Remora is off, while another Remora call runs, for an excluded project and for one with no session (the
    /// last is the catalog's answer, read here once). `stopRemora()` stops it; drafting again is this same entry.
    @discardableResult
    public func draftRemoraBrief(project: UUID) async -> Bool {
        let state = remora
        func free() -> Bool {
            state.phase == .idle && !state.deciding && !state.draftChecking && !state.draft.isReading && state.preferences.isOn
                && !state.preferences.excludedProjects.contains(project)
        }
        guard let host = state.host, free() else { return false }
        state.draftChecking = true
        let allowed = await host.canDraft(project: project)
        state.draftChecking = false
        guard allowed, free() else { return false }
        state.draft = .reading(project: project, reading: nil)
        state.task = Task {
            let outcome = await host.draft(project: project, onReading: { reading in
                if case .reading(project, _) = state.draft { state.draft = .reading(project: project, reading: reading) }
            })
            state.finishDraft(outcome, project: project)
            if outcome.changesUsage { state.usage = await host.usage() ?? state.usage }
        }
        return true
    }

    /// Stops the running call (its child ends); no-op when none runs.
    public func stopRemora() { remora.host?.stop() }

    /// Starts a call as the model's one: `phase` shows at once, or (nil, the automatic brief) when the host says the brief
    /// started. `started` is what the host calls then.
    private func startRemora(
        _ phase: RemoraModelState.Phase?, door: RemoraModelState.Door,
        _ body: @escaping @MainActor (RemoraHost, RemoraModelState, _ started: @escaping @MainActor () -> Void) async -> RemoraOutcome
    ) -> Bool {
        let state = remora
        guard let host = state.host, state.phase == .idle, !state.deciding, !state.draftChecking, !state.draft.isReading,
              state.preferences.isOn else { return false }
        let kind = phase ?? .briefing
        let begin: @MainActor () -> Void = {
            state.deciding = false
            state.phase = kind
            state.call = RemoraModelState.Call(kind: kind == .asking ? .question : .brief, door: door)
            state.streamedText = ""
            state.lastFailure = nil
            state.notSavedReason = nil
            state.stopped = nil
            state.reading = nil
            if kind == .briefing { state.lastBriefDecision = nil }
        }
        if phase != nil { begin() } else { state.deciding = true }
        state.task = Task {
            let outcome = await body(host, state, begin)
            state.finish(outcome)
            state.reading = nil
            if outcome.changesUsage { state.usage = await host.usage() ?? state.usage }
            // The brief that just answered is the day's: read back what the host kept (nil when it could not be written).
            if case let .answered(answer) = outcome, answer.kind == .brief { state.keptBrief = await host.keptBrief() }
            state.deciding = false
            state.phase = .idle
        }
        return true
    }

    // MARK: The day's brief

    /// Reads the day's brief that Remora kept (the file is read when this runs, never at launch) into `remora.keptBrief`: the
    /// brief of an earlier day is removed and leaves nil. Home calls it when it is first shown (and may call it again). With
    /// Remora off, or before the host is installed, nothing is read.
    public func loadRemoraKeptBrief() async {
        guard let host = remora.host, remora.preferences.isOn else { return }
        remora.keptBrief = await host.keptBrief()
    }

    // MARK: Facts and undo

    /// "Remember this?" confirmed: the fact goes to `Remora.md` (Undo with `remora.lastUndo`).
    public func confirmRemoraFact(_ fact: String) {
        guard let host = remora.host else { return }
        remora.proposedFacts.removeAll { $0 == fact }
        track { state in
            state.finish(await host.remember(fact))
            state.usage = await host.usage() ?? state.usage
        }
    }

    /// "Remember this?" declined.
    public func dismissRemoraFact(_ fact: String) { remora.proposedFacts.removeAll { $0 == fact } }

    /// Undo of a remembered fact or a removed note.
    public func undoRemora(_ token: RemoraUndoToken) {
        guard let host = remora.host else { return }
        track { state in
            _ = await host.undo(token)
            if state.lastUndo == token { state.lastUndo = nil }
            state.usage = await host.usage() ?? state.usage
        }
    }

    // MARK: Memory

    /// The notes Remora keeps per project (reads the memory on first use), named from the model's projects.
    public func remoraNotes() async -> [RemoraHostNote] {
        guard let host = remora.host else { return [] }
        return await host.notes(names: Dictionary(projects.map { ($0.id, $0.name) }) { first, _ in first })
    }

    public func remoraJournalDays() async -> [Date] { await remora.host?.journalDays() ?? [] }

    public func remoraJournal(on date: Date) async -> [RemoraJournalEntry] { await remora.host?.journal(on: date) ?? [] }

    /// The weeks the journal folds its days older than 14 into, oldest first; empty without a host.
    public func remoraJournalWeeks() async -> [RemoraWeekSummary] { await remora.host?.journalWeeks() ?? [] }

    /// Settings' Working memory line: when the journal or a project note was last written; nil when it is empty or there is
    /// no host. Read from the files on each call (never at launch).
    public func remoraWorkingMemoryUpdatedAt() async -> Date? { await remora.host?.workingMemoryUpdatedAt() }

    /// Edit: `text` is the note as the user left it.
    public func editRemoraNote(project: UUID, text: String) {
        guard let host = remora.host else { return }
        track { state in
            _ = await host.editNote(project: project, text: text)
            state.usage = await host.usage() ?? state.usage
        }
    }

    /// Deletes a project's note and returns this removal's own Undo token (nil when there was no note, or no host). A tracked
    /// change like the others (`remoraMemoryChanged()` waits for it), and it sets `remora.lastUndo` (and clears `lastRemembered`),
    /// so Home's single Undo still holds the newest token.
    public func removeRemoraNoteWithUndo(project: UUID) async -> RemoraUndoToken? {
        guard let host = remora.host else { return nil }
        let state = remora
        let removal = Task { () -> RemoraUndoToken? in
            let token = await host.removeNote(project: project)
            if let token {
                state.lastUndo = token
                state.lastRemembered = nil
            }
            state.usage = await host.usage() ?? state.usage
            return token
        }
        track { _ in _ = await removal.value }
        return await removal.value
    }

    /// The × on a journal line.
    public func removeRemoraJournalLine(id: String) {
        guard let host = remora.host else { return }
        track { _ in _ = await host.removeJournalLine(id: id) }
    }

    /// Settings' Clear: the journal and the notes go.
    public func clearRemoraWorkingMemory() {
        guard let host = remora.host else { return }
        track { state in
            await host.clearWorkingMemory()
            state.usage = await host.usage() ?? state.usage
            if state.keptBrief != nil { state.keptBrief = await host.keptBrief() }
        }
    }

    /// Reads the use again (Settings opens, a call ended elsewhere).
    public func refreshRemoraUsage() {
        guard let host = remora.host else { return }
        track { state in state.usage = await host.usage() ?? state.usage }
    }

    private func track(_ body: @escaping @MainActor (RemoraModelState) async -> Void) { remora.track(body) }

    // MARK: Preferences

    /// Changes Remora's settings in one step: kept in the preferences file and told to the host (a project that became
    /// excluded loses its note, a new `Remora.md` path is used from then on).
    public func updateRemoraPreferences(_ change: (inout RemoraPreferences) -> Void) {
        var next = remora.preferences
        change(&next)
        next = RemoraPreferences(
            isOn: next.isOn, model: next.model, effort: next.effort, briefMode: next.briefMode,
            excludedProjects: next.excludedProjects, proposals: next.proposals, windowThreshold: next.windowThreshold,
            noteFilePath: next.noteFilePath, language: next.language)
        guard next != remora.preferences else { return }
        remora.preferences = next
        remora.persist?(next)
        guard let host = remora.host else { return }
        track { state in
            await host.update(settings: next)
            state.usage = await host.usage() ?? state.usage
            // A new exclusion may have removed the day's brief.
            if state.keptBrief != nil { state.keptBrief = await host.keptBrief() }
        }
    }

    /// Holds Remora Off for this launch only, for a launch that must not reach a real CLI (a development evidence run
    /// without fake providers or an isolated profile). Memory only: the preferences file stays as it was, and a later
    /// write of the other preferences keeps the file's own Remora value. A change to a Remora setting during the run
    /// writes Remora's settings as they then stand, Off included; turning Remora on in Settings persists as usual and
    /// lifts the hold. A host that already exists is told, as `updateRemoraPreferences` does.
    public func holdRemoraOff() {
        guard remora.preferences.isOn else { return }
        var next = remora.preferences
        next.isOn = false
        remora.preferences = next
        guard let host = remora.host else { return }
        track { _ in await host.update(settings: next) }
    }

    public func setRemoraOn(_ on: Bool) { updateRemoraPreferences { $0.isOn = on } }
    public func setRemoraModel(_ model: String) { updateRemoraPreferences { $0.model = model } }
    public func setRemoraEffort(_ effort: String) { updateRemoraPreferences { $0.effort = effort } }
    public func setRemoraBriefMode(_ mode: RemoraBriefMode) { updateRemoraPreferences { $0.briefMode = mode } }
    public func setRemoraProposals(_ on: Bool) { updateRemoraPreferences { $0.proposals = on } }
    public func setRemoraWindowThreshold(_ share: Double) { updateRemoraPreferences { $0.windowThreshold = share } }

    /// The brief's language, a BCP-47 code such as `tr`; nil is "the language of your last question".
    public func setRemoraLanguage(_ code: String?) { updateRemoraPreferences { $0.language = code } }

    /// A project leaves or joins Remora's reach; excluding it deletes its note.
    public func setRemoraExcluded(_ project: UUID, _ excluded: Bool) {
        updateRemoraPreferences { if excluded { $0.excludedProjects.insert(project) } else { $0.excludedProjects.remove(project) } }
    }

    /// The file `Remora.md` lives in: an absolute path the user chose, or nil for `<data root>/remora/Remora.md`.
    public func setRemoraNoteFile(_ url: URL?) { updateRemoraPreferences { $0.noteFilePath = url?.path } }
}

/// A Draft Brief that answered: the text the UI places in the composer (or copies), with what it rests on.
public struct RemoraDraftedBrief: Equatable, Sendable {
    public var project: UUID
    /// The brief, plain paragraphs, without the closing block.
    public var text: String
    /// The sessions the brief cites (only ids its pack named).
    public var citedSessionIDs: [UUID]
    /// How many sessions its pack read ("from 3 sessions in loom").
    public var sessionsRead: Int
    public var draftedAt: Date
}

extension RemoraModelState {
    /// A failed draft's sentence, worded as Home words a question's failure (design/DESIGN.md §20, States).
    static func draftFailureSentence(_ kind: RemoraFailure.Kind) -> String {
        kind == .notLoggedIn ? "Remora uses your Claude Code login. Log in with claude in a terminal."
            : "Remora could not get an answer from Claude."
    }

    /// What a draft's outcome leaves in `draft`.
    func finishDraft(_ outcome: RemoraOutcome, project: UUID) {
        switch outcome {
        case let .answered(answer):
            draft = .drafted(RemoraDraftedBrief(
                project: project, text: answer.answer.text, citedSessionIDs: answer.answer.cited.compactMap(UUID.init(uuidString:)),
                sessionsRead: answer.readSessionIDs.count, draftedAt: Date()))
        case let .failed(failure):
            draft = .failed(project: project, failure: failure.kind, sentence: Self.draftFailureSentence(failure.kind))
        case .cancelled:
            draft = .stopped(project: project)
        case .remembered, .notSaved, .busy, .off, .notDue:
            draft = .idle
        }
    }
}

extension RemoraOutcome {
    /// Whether the call or save touched the memory or the counters: the use is read again after it.
    var changesUsage: Bool {
        switch self {
        case .answered, .failed, .cancelled, .remembered: true
        case .notSaved, .busy, .off, .notDue: false
        }
    }
}

extension RemoraModelState {
    /// What an outcome changes in the state (the phase and the usage are the caller's).
    func finish(_ outcome: RemoraOutcome) {
        switch outcome {
        case let .answered(answer):
            lastAnswer = answer
            proposedFacts = answer.proposedFacts
            lastFailure = nil
        case let .failed(failure):
            lastFailure = failure.kind
        case let .remembered(fact, undo):
            lastRemembered = fact
            lastUndo = undo
            notSavedReason = nil
        case let .notSaved(reason):
            notSavedReason = reason
        case .cancelled:
            switch phase {
            case .asking: stopped = .question
            case .briefing: stopped = .brief
            case .idle: break
            }
        case let .notDue(decision):
            lastBriefDecision = decision
        case .busy, .off:
            break
        }
    }
}
