import Foundation
import LoomCore

/// The one owner of Remora in a running app (L3a; LOMBOT §4). It owns Remora's memory (`<data root>/remora/`, opened on first
/// use), `Remora.md`, the pack builder over the catalog, the call, the day's brief record and the one call in flight. The UI
/// never talks to those; the model API (`CatalogModel+Remora`) forwards to this.
///
/// - Nothing runs by itself: no timer, watcher or launch-time read beyond removing the stale system-prompt files (a folder
///   listing). `ask`, `brief` and `briefIfDue` are called by the app; idle means no process.
/// - One call at a time: a second `ask` or `brief` while one runs gets `.busy`. `stop()` ends the call and its child.
/// - Failures are values (`RemoraOutcome.failed` with a `RemoraFailure.Kind`); nothing throws past the host.
/// - The forgetter (`registerForgetter`) does not need the main actor: a deletion that `SessionRuntime.start()` recovers can
///   reach it before any UI exists, so it goes through the thread-safe memory box.
@MainActor
public final class RemoraHost {
    /// `<data root>/remora/`.
    public nonisolated let directory: URL
    public private(set) var settings: RemoraPreferences
    /// What the running call is for; nil when none runs.
    public private(set) var activeKind: RemoraKind?
    public var isRunning: Bool { running != nil }

    private nonisolated let box: RemoraMemoryBox
    private var note: RemoraDurableNote
    private let lastBriefFile: RemoraLastBrief
    private var lastBriefLoaded = false
    private var lastBriefValue: Date?
    private let builder: RemoraPackBuilder
    private let readMaps: @Sendable () async throws -> RemoraCatalogMaps
    private let makeCall: @Sendable (RemoraUsage) async throws -> RemoraCall
    private let timeZone: TimeZone
    private let clock: @Sendable () -> Date
    private var running: Task<RemoraOutcome, Never>?

    /// The app's host. `toolchain` resolves the Claude CLI when a call needs it (the app's toolchain slot, which waits for
    /// the runtime's resolver); `profile` is the Claude profile usage reads, and its folder is where transcripts are found.
    /// Making the host reads only the listing of `<data root>/remora/` (it removes stale system-prompt files).
    public convenience init(dataRoot: URL, supervisor: ProcessSupervisor, catalog: SessionCatalog, sessions: SessionDirectory,
                            toolchain: @escaping @Sendable () async throws -> ProviderToolchain,
                            profile: ClaudeProfileLayout, settings: RemoraPreferences = RemoraPreferences()) {
        let workingDirectory = dataRoot.appendingPathComponent("remora/run", isDirectory: true)
        self.init(
            dataRoot: dataRoot, settings: settings,
            sessions: { try await sessions.summaries($0) },
            transcript: RemoraPackBuilder.catalogTranscripts(catalog, configDirectory: profile.configDirectory),
            maps: { try await RemoraCatalogMaps.read(from: catalog) },
            makeCall: { usage in
                let resolved: ProviderToolchain
                do { resolved = try await toolchain() } catch {
                    throw RemoraFailure(kind: .couldNotStart, detail: "Claude could not be found", usage: nil)
                }
                return RemoraCall(supervisor: supervisor, toolchain: resolved, profile: profile,
                                  workingDirectory: workingDirectory, usage: usage)
            },
            timeZone: .current, clock: { Date() })
    }

    init(dataRoot: URL, settings: RemoraPreferences, sessions: @escaping RemoraPackBuilder.Sessions,
         transcript: @escaping RemoraPackBuilder.Transcript, maps: @escaping @Sendable () async throws -> RemoraCatalogMaps,
         makeCall: @escaping @Sendable (RemoraUsage) async throws -> RemoraCall,
         timeZone: TimeZone = .current, clock: @escaping @Sendable () -> Date = { Date() }) {
        let directory = dataRoot.appendingPathComponent("remora", isDirectory: true)
        self.directory = directory
        self.settings = settings
        let note = RemoraDurableNote(url: settings.noteURL(defaultIn: directory), timeZone: timeZone, clock: clock)
        self.note = note
        box = RemoraMemoryBox(directory: directory, note: note, timeZone: timeZone, clock: clock)
        lastBriefFile = RemoraLastBrief(directory: directory)
        builder = RemoraPackBuilder(sessions: sessions, transcript: transcript)
        readMaps = maps
        self.makeCall = makeCall
        self.timeZone = timeZone
        self.clock = clock
        // A call that was cut short (a crash, a kill) leaves its system-prompt file; nothing else is read at launch.
        RemoraCall.removeStaleSystemPrompts(in: directory)
    }

    // MARK: Forgetting

    /// What the app registers on `ConversationForgetters` before `SessionRuntime.start()`: it forwards to the host's memory,
    /// opened on demand, and holds nothing of the main actor.
    public nonisolated var forgetter: any ConversationForgetting { RemoraHostForgetter(box: box) }

    /// The one registration the app makes, before `start()` (a deletion that start recovers reaches it).
    public nonisolated func registerForgetter(in forgetters: ConversationForgetters) {
        forgetters.register(forgetter)
    }

    /// Whether the memory has been opened (tests: launch reads none of its files).
    var memoryIsOpen: Bool { box.isOpen }

    // MARK: Questions and briefs

    /// A question. "Remember …" / "Hatırla …" saves a fact to `Remora.md` and makes no call. Otherwise: the share, the pack
    /// (the settings' exclusions, model and effort), the call; `onText` gets the visible answer as it streams; on the end,
    /// the memory applies the answer.
    public func ask(_ question: String, scope: RemoraScope = .allProjects, previous: RemoraExchange? = nil,
                    onText: @escaping @MainActor (String) -> Void = { _ in }) async -> RemoraOutcome {
        guard settings.isOn else { return .off }
        if let fact = RemoraRemember.fact(in: question) { return await remember(fact) }
        return await run(.question(question, scope: scope, previous: previous), onText: onText)
    }

    /// The brief the user asked for: it runs whatever the schedule says.
    public func brief(onText: @escaping @MainActor (String) -> Void = { _ in }) async -> RemoraOutcome {
        guard settings.isOn else { return .off }
        return await runBrief(onText: onText)
    }

    /// The automatic brief: `RemoraSchedule.decide` over the settings, the day's record and the catalog's newest activity;
    /// it starts a brief only on `.run`. A `.wait` or `.skip` records nothing. Nothing calls this in L3a.
    /// - Parameters:
    ///   - homeShown: Home is on screen.
    ///   - windowRemainingShare: what is left of the plan's five-hour window, 0...1; nil when unknown.
    ///   - onStart: called when a brief really starts (not for a `.wait`, a `.skip` or a refusal).
    public func briefIfDue(homeShown: Bool, windowRemainingShare: Double?, onStart: @escaping @MainActor () -> Void = {},
                           onText: @escaping @MainActor (String) -> Void = { _ in }) async -> RemoraOutcome {
        guard settings.isOn else { return .notDue(.skip(.remoraOff)) }
        guard running == nil else { return .busy }
        let newest = (try? await readMaps())?.newestActivity(excluding: settings.excludedProjects)
        let decision = RemoraSchedule.decide(RemoraScheduleInput(
            remoraOn: settings.isOn, briefMode: settings.briefMode, now: clock(), timeZone: timeZone,
            lastBrief: loadLastBrief(), newestActivity: newest, homeShown: homeShown,
            windowRemainingShare: windowRemainingShare, windowThreshold: settings.windowThreshold))
        guard decision == .run else { return .notDue(decision) }
        return await runBrief(onStart: onStart, onText: onText)
    }

    /// Ends the running call: its child gets SIGTERM, then SIGKILL; the call's `ask` or `brief` returns `.cancelled`.
    public func stop() { running?.cancel() }

    /// A brief records the day's slot when it starts (a failed or stopped one is not retried the same day), and gives it back
    /// when it never reached the model (`notLoggedIn`, `couldNotStart`).
    private func runBrief(onStart: @escaping @MainActor () -> Void = {}, onText: @escaping @MainActor (String) -> Void) async -> RemoraOutcome {
        guard running == nil else { return .busy }
        let now = clock()
        let previous = loadLastBrief()
        storeLastBrief(now)
        let since = RemoraSchedule.briefSince(now: now, lastBrief: previous, timeZone: timeZone)
        let outcome = await run(.brief(since: since), onStart: onStart, onText: onText)
        if case let .failed(failure) = outcome, failure.kind == .notLoggedIn || failure.kind == .couldNotStart {
            storeLastBrief(previous)
        }
        return outcome
    }

    private func run(_ request: RemoraPackRequest, onStart: @escaping @MainActor () -> Void = {},
                     onText: @escaping @MainActor (String) -> Void) async -> RemoraOutcome {
        guard running == nil else { return .busy }
        activeKind = request.kind
        onStart()
        let task = Task { await self.execute(request, onText: onText) }
        running = task
        let outcome = await task.value
        running = nil
        activeKind = nil
        return outcome
    }

    private func execute(_ request: RemoraPackRequest, onText: @escaping @MainActor (String) -> Void) async -> RemoraOutcome {
        let settings = settings
        do {
            let memory = try await box.open()
            let maps = try await readMaps()
            let excluded = settings.excludedProjects
            let scope: RemoraScope
            if case let .question(_, asked, _) = request { scope = asked } else { scope = .allProjects }
            let share = await memory.share(
                for: scope, excludedProjects: excluded, sessionProjects: maps.sessionProjects,
                projectNames: maps.namedProjects(excluding: excluded))
            let pack = try await builder.build(
                request, settings: RemoraPackSettings(excludedProjects: excluded, model: settings.model, effort: settings.effort),
                memory: share, today: memory.usage.today, now: clock(), timeZone: timeZone)
            try Task.checkCancellation()
            let call = try await makeCall(memory.usage)
            var finished: RemoraAnswer?
            for try await event in call.run(pack.request(model: settings.model, effort: settings.effort)) {
                switch event {
                case let .text(piece): onText(piece)
                case let .finished(answer): finished = answer
                }
            }
            guard let answer = finished else {
                if Task.isCancelled { return .cancelled }
                return .failed(RemoraFailure(kind: .endedWithoutAnswer, detail: "The call ended without a result", usage: nil))
            }
            var facts: [String]
            var journaled = true
            do {
                facts = try await memory.apply(answer: answer, request: request, pack: pack,
                                               sessionProjects: maps.sessionProjects, excludedProjects: excluded)
            } catch {
                facts = answer.proposedFacts
                journaled = false
            }
            if !settings.proposals { facts = [] }
            var question: String?
            if case let .question(text, _, _) = request { question = text }
            return .answered(RemoraHostAnswer(
                kind: request.kind, question: question, answer: answer, proposedFacts: facts,
                readSessionIDs: pack.readSessionIDs, footer: pack.facts.text, journaled: journaled))
        } catch let failure as RemoraFailure {
            return Task.isCancelled ? .cancelled : .failed(failure)
        } catch {
            if Task.isCancelled || error is CancellationError { return .cancelled }
            return .failed(RemoraFailure(kind: .couldNotStart, detail: "Remora's memory or the session list could not be read", usage: nil))
        }
    }

    // MARK: The day's brief

    /// When the last brief started (read from `last-brief.json` on first use); nil when none did.
    func loadLastBrief() -> Date? {
        if !lastBriefLoaded {
            lastBriefValue = lastBriefFile.read()
            lastBriefLoaded = true
        }
        return lastBriefValue
    }

    private func storeLastBrief(_ date: Date?) {
        lastBriefValue = date
        lastBriefLoaded = true
        try? lastBriefFile.write(date)
    }

    // MARK: Remora.md

    /// Saves a fact under `## Remembered` (Undo with the token). A fact the file cannot take comes back as `.notSaved`.
    public func remember(_ fact: String) async -> RemoraOutcome {
        do {
            let token = try await note.remember(fact)
            return .remembered(fact: fact, undo: token)
        } catch let refusal as RemoraDurableNote.Refusal {
            return .notSaved(refusal.reason)
        } catch {
            return .notSaved("Remora.md could not be saved.")
        }
    }

    // MARK: Memory

    /// Every project's note with its name, in project order of the memory's folder.
    public func notes() async -> [RemoraHostNote] {
        guard let memory = try? await box.open() else { return [] }
        let names = (try? await readMaps())?.projectNames ?? [:]
        var result: [RemoraHostNote] = []
        for project in await memory.noteProjects() {
            if let note = await memory.note(for: project) { result.append(RemoraHostNote(project: project, name: names[project], note: note)) }
        }
        return result
    }

    /// Edit: `text` is the note as the user left it. False when it could not be saved.
    public func editNote(project: UUID, text: String) async -> Bool {
        guard let memory = try? await box.open() else { return false }
        do { try await memory.editNote(project: project, text: text); return true } catch { return false }
    }

    /// Deletes the note; the token restores it. Nil when there was none or it could not be removed.
    public func removeNote(project: UUID) async -> RemoraUndoToken? {
        guard let memory = try? await box.open() else { return nil }
        return try? await memory.removeNote(project: project)
    }

    /// Undo of a removed note or of a remembered fact. False when the token is spent or unknown.
    public func undo(_ token: RemoraUndoToken) async -> Bool {
        if (try? await note.undo(token)) == true { return true }
        guard let memory = box.openMemory else { return false }
        return (try? await memory.undo(token)) ?? false
    }

    /// The days that have a journal file, oldest first.
    public func journalDays() async -> [Date] {
        guard let memory = try? await box.open() else { return [] }
        return await memory.journalDays()
    }

    public func journal(on date: Date) async -> [RemoraJournalEntry] {
        guard let memory = try? await box.open() else { return [] }
        return await memory.journal(on: date)
    }

    /// The × on Home: one journal line by its id. False when none has the id.
    public func removeJournalLine(id: String) async -> Bool {
        guard let memory = try? await box.open() else { return false }
        return (try? await memory.removeJournalLine(id: id)) ?? false
    }

    /// Settings' Clear: the journal and the notes go (use counters and `Remora.md` stay).
    public func clearWorkingMemory() async {
        guard let memory = try? await box.open() else { return }
        await memory.clearWorkingMemory()
    }

    /// Today's and the last days' use, with the drift count; nil when the memory cannot be opened.
    public func usage() async -> RemoraUsageSnapshot? {
        guard let memory = try? await box.open() else { return nil }
        return RemoraUsageSnapshot(today: memory.usage.today, days: memory.usage.days)
    }

    // MARK: Settings

    /// The settings changed (the app persists them). A project that became excluded loses its note now; a new `Remora.md` path
    /// makes the host use that file from now on (the memory stays, so its counters and the forgetter's reach are unchanged).
    public func update(settings updated: RemoraPreferences) async {
        let old = settings
        settings = updated
        if updated.noteFilePath != old.noteFilePath {
            let fresh = RemoraDurableNote(url: updated.noteURL(defaultIn: directory), timeZone: timeZone, clock: clock)
            note = fresh
            if let memory = box.use(note: fresh) { await memory.setDurableNote(fresh) }
        }
        let added = updated.excludedProjects.subtracting(old.excludedProjects)
        if !added.isEmpty, let memory = try? await box.open() {
            for project in added { await memory.excludeProject(project) }
        }
    }

    /// A project became excluded: it is added to the settings and its note is deleted.
    public func excludeProject(_ project: UUID) async {
        var updated = settings
        updated.excludedProjects.insert(project)
        await update(settings: updated)
    }
}
