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

    public internal(set) var phase: Phase = .idle
    /// The visible answer so far; reset when a call starts.
    public internal(set) var streamedText = ""
    /// The last call's answer (a question's or a brief's); kept until the next one ends well.
    public internal(set) var lastAnswer: RemoraHostAnswer?
    /// The last call's failure kind; nil after a call that ended well, and while one runs.
    public internal(set) var lastFailure: RemoraFailure.Kind?
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

    @ObservationIgnored var host: RemoraHost?
    @ObservationIgnored var persist: (@MainActor (RemoraPreferences) -> Void)?
    @ObservationIgnored var task: Task<Void, Never>?
    /// An automatic brief is being decided (no phase yet).
    @ObservationIgnored var deciding = false
    @ObservationIgnored var pending: [Task<Void, Never>] = []

    public init() {}

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
        pending.removeAll()
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

    /// Whether Remora has a host (the Home views show nothing of Remora without one).
    public var hasRemora: Bool { remora.host != nil }

    // MARK: Calls

    /// A question. "Remember …" saves a fact and makes no call. Refused (false) without a host, while a call runs or with
    /// Remora off. `followUp` carries the last answer's exchange.
    @discardableResult
    public func askRemora(_ question: String, scope: RemoraScope = .allProjects, followUp: Bool = false) -> Bool {
        let previous = followUp ? remora.lastAnswer?.exchange : nil
        return startRemora(.asking) { host, state, _ in
            await host.ask(question, scope: scope, previous: previous, onText: { state.streamedText += $0 })
        }
    }

    /// The brief the user asked for: runs whatever the schedule says.
    @discardableResult
    public func briefRemora() -> Bool {
        startRemora(.briefing) { host, state, _ in await host.brief(onText: { state.streamedText += $0 }) }
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
        return startRemora(nil) { host, state, started in
            await host.briefIfDue(homeShown: homeShown, windowRemainingShare: share, onStart: started,
                                  onText: { state.streamedText += $0 })
        }
    }

    /// The plan's five-hour window share that is left, 0...1; nil when the limits are not known or the window is over.
    func remainingFiveHourShare(now: Date = Date()) -> Double? { Self.remainingFiveHourShare(of: usage?.limits, now: now) }

    nonisolated static func remainingFiveHourShare(of limits: PlanLimits?, now: Date) -> Double? {
        guard let window = limits?.fiveHour, window.isCurrent(at: now) else { return nil }
        return Double(window.remainingPercent) / 100
    }

    /// Stops the running call (its child ends); no-op when none runs.
    public func stopRemora() { remora.host?.stop() }

    /// Starts a call as the model's one: `phase` shows at once, or (nil, the automatic brief) when the host says the brief
    /// started. `started` is what the host calls then.
    private func startRemora(
        _ phase: RemoraModelState.Phase?,
        _ body: @escaping @MainActor (RemoraHost, RemoraModelState, _ started: @escaping @MainActor () -> Void) async -> RemoraOutcome
    ) -> Bool {
        let state = remora
        guard let host = state.host, state.phase == .idle, !state.deciding, state.preferences.isOn else { return false }
        let kind = phase ?? .briefing
        let begin: @MainActor () -> Void = {
            state.deciding = false
            state.phase = kind
            state.streamedText = ""
            state.lastFailure = nil
            state.notSavedReason = nil
        }
        if phase != nil { begin() } else { state.deciding = true }
        state.task = Task {
            let outcome = await body(host, state, begin)
            state.finish(outcome)
            if outcome.changesUsage { state.usage = await host.usage() ?? state.usage }
            state.deciding = false
            state.phase = .idle
        }
        return true
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

    /// The notes Remora keeps per project (reads the memory on first use).
    public func remoraNotes() async -> [RemoraHostNote] { await remora.host?.notes() ?? [] }

    public func remoraJournalDays() async -> [Date] { await remora.host?.journalDays() ?? [] }

    public func remoraJournal(on date: Date) async -> [RemoraJournalEntry] { await remora.host?.journal(on: date) ?? [] }

    /// Edit: `text` is the note as the user left it.
    public func editRemoraNote(project: UUID, text: String) {
        guard let host = remora.host else { return }
        track { state in
            _ = await host.editNote(project: project, text: text)
            state.usage = await host.usage() ?? state.usage
        }
    }

    /// Deletes a project's note; `remora.lastUndo` restores it.
    public func removeRemoraNote(project: UUID) {
        guard let host = remora.host else { return }
        track { state in
            if let token = await host.removeNote(project: project) {
                state.lastUndo = token
                state.lastRemembered = nil
            }
            state.usage = await host.usage() ?? state.usage
        }
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
        }
    }

    /// Reads the use again (Settings opens, a call ended elsewhere).
    public func refreshRemoraUsage() {
        guard let host = remora.host else { return }
        track { state in state.usage = await host.usage() ?? state.usage }
    }

    private func track(_ body: @escaping @MainActor (RemoraModelState) async -> Void) {
        let state = remora
        state.pending.append(Task { await body(state) })
    }

    // MARK: Preferences

    /// Changes Remora's settings in one step: kept in the preferences file and told to the host (a project that became
    /// excluded loses its note, a new `Remora.md` path is used from then on).
    public func updateRemoraPreferences(_ change: (inout RemoraPreferences) -> Void) {
        var next = remora.preferences
        change(&next)
        next = RemoraPreferences(
            isOn: next.isOn, model: next.model, effort: next.effort, briefMode: next.briefMode,
            excludedProjects: next.excludedProjects, proposals: next.proposals, windowThreshold: next.windowThreshold,
            noteFilePath: next.noteFilePath)
        guard next != remora.preferences else { return }
        remora.preferences = next
        remora.persist?(next)
        guard let host = remora.host else { return }
        track { state in
            await host.update(settings: next)
            state.usage = await host.usage() ?? state.usage
        }
    }

    public func setRemoraOn(_ on: Bool) { updateRemoraPreferences { $0.isOn = on } }
    public func setRemoraModel(_ model: String) { updateRemoraPreferences { $0.model = model } }
    public func setRemoraEffort(_ effort: String) { updateRemoraPreferences { $0.effort = effort } }
    public func setRemoraBriefMode(_ mode: RemoraBriefMode) { updateRemoraPreferences { $0.briefMode = mode } }
    public func setRemoraProposals(_ on: Bool) { updateRemoraPreferences { $0.proposals = on } }
    public func setRemoraWindowThreshold(_ share: Double) { updateRemoraPreferences { $0.windowThreshold = share } }

    /// A project leaves or joins Remora's reach; excluding it deletes its note.
    public func setRemoraExcluded(_ project: UUID, _ excluded: Bool) {
        updateRemoraPreferences { if excluded { $0.excludedProjects.insert(project) } else { $0.excludedProjects.remove(project) } }
    }

    /// The file `Remora.md` lives in: an absolute path the user chose, or nil for `<data root>/remora/Remora.md`.
    public func setRemoraNoteFile(_ url: URL?) { updateRemoraPreferences { $0.noteFilePath = url?.path } }
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
        case .cancelled, .busy, .off, .notDue:
            break
        }
    }
}
