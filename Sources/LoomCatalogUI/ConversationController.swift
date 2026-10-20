import AppKit
import Foundation
import LoomChat
import LoomCore
import LoomTerminal

/// Hosts one terminal view; focus goes to the terminal when it enters a window.
@MainActor
final class TerminalContainerView: NSView {
    let terminal: NSView

    init(terminal: NSView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: LoomTheme.Space.terminalInset),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -LoomTheme.Space.terminalInset),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: LoomTheme.Space.terminalInset),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -LoomTheme.Space.terminalInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Gives the keyboard back to the terminal (leaving the search field with Esc).
    func focusTerminal() { window?.makeFirstResponder(terminal) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let terminal = terminal
        DispatchQueue.main.async { window.makeFirstResponder(terminal) }
    }
}

/// An action that runs once, on the main actor (the card of a Chat start exists: told once, from either of two places).
@MainActor
final class OneShot {
    private(set) var fired = false
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) { self.body = body }

    func fire() {
        guard !fired else { return }
        fired = true
        body()
    }
}

/// Connects the catalog model's intents to the runtime and to the live
/// terminals. It keeps one terminal per live run; a card sees a terminal only
/// while it owns that run, so after `/clear` or `/new` the same terminal
/// belongs to the new card and callbacks bound to the old card do nothing.
@MainActor
public final class ConversationController: NewSessionIntents, HandoverIntents {
    struct Entry {
        let runID: UUID
        let surface: TerminalSurface
        let container: TerminalContainerView
        var owner: UUID
    }

    let runtime: SessionRuntime
    weak var model: CatalogModel?
    private(set) var entries: [UUID: Entry] = [:]
    /// The last screens of ended runs, by session (FB4-3): static snapshots, no surface is kept.
    private(set) var endedScreens = EndedScreenStore()
    /// What the user saw when they pressed Stop, by run, until that run's end uses it.
    private var stopCaptures: [UUID: TerminalScreenSnapshot] = [:]
    /// Who owns a run right now, asked of the supervisor. Only an entry the latest event frame does
    /// not confirm is asked about; tests count these calls.
    var ownerLookup: (UUID) async -> UUID?
    private var observer: Task<Void, Never>?
    private var openRequestObserver: Task<Void, Never>?
    /// Approvals in flight: a second click on "Open Session" must not ask the runtime twice.
    private var approvingOpen: Set<UUID> = []
    /// Handovers between the faces that wait or run (V19), by session.
    var handoverTasks: [UUID: Task<Void, Never>] = [:]
    /// How long a terminal session must rest at its prompt before it moves to Chat (the first idle frame between two
    /// hooks is not the end of a turn). Tests make it short.
    var handoverSettle: Duration = .milliseconds(1500)
    /// Held at a handover's point of no return, with its target (tests act at that phase; nil in the app).
    var handoverGate: (@MainActor (UUID, SessionFace) async -> Void)?
    /// Held after a Stop returned from the runtime, before the tab decision (tests navigate at that phase; nil in the app).
    var stopGate: (@MainActor (UUID) async -> Void)?
    /// How often a handover looked at the terminal session's standing in the hub (tests: a wait is on events, not on a timer).
    var standingReads = 0

    public init(runtime: SessionRuntime, model: CatalogModel) {
        self.runtime = runtime
        self.model = model
        ownerLookup = { runID in await runtime.supervisor.activeSessionID(runID: runID) }
        model.intents = self
    }

    deinit {
        observer?.cancel()
        openRequestObserver?.cancel()
    }

    /// What builds before V16 kept in the new-session file (`launched`: the choices of each session Loom started, `lastUsed`: each
    /// project's) moves into the catalog once, and the catalog says so (`app_state`): the file's lists are not read again, so
    /// a launch costs nothing for them. Only sessions with none stored take choices, and only projects the catalog remembers
    /// nothing for take theirs.
    func importLegacyLaunchRecords() async {
        guard let model else { return }
        // The file is opened here if the model has not yet: marking the import done without having read it would lose it.
        model.prepareNewSession()
        guard model.newSession.store != nil else { return }
        let catalog = await runtime.catalog
        do {
            guard try await catalog.appState(Self.launchImportKey) == nil else { return }
            let records = model.newSession.legacyLaunchRecords()
            try await catalog.importLaunchChoices(records.launched)
            try await catalog.importLastUsedLaunchChoices(records.lastUsed)
            try await catalog.setAppState(Self.launchImportKey, to: "1")
            model.refreshLastUsedChoices()
        } catch {
            LoomLog.error(.catalog, "Launch choices could not be copied to the catalog (\(LoomLog.category(of: error)))")
        }
    }

    static let launchImportKey = "launch.legacy-import-done"

    /// Follows run ownership and run ends from the event hub. Every frame carries the full session
    /// states, so frames may coalesce: each one is compared with the entries locally and only what it
    /// does not confirm is asked of the supervisor (see `reconcile(_:)`).
    public func begin() async {
        guard observer == nil else { return }
        await importLegacyLaunchRecords()
        let stream = await runtime.supervisor.events.subscribe()
        observer = Task { [weak self] in
            for await frame in stream {
                guard !Task.isCancelled else { break }
                await self?.reconcile(frame)
            }
        }
        // The agents' requests to open a session (D-40): the model shows the runtime's whole list.
        let requests = await runtime.openRequestUpdates()
        openRequestObserver = Task { [weak self] in
            for await list in requests {
                guard !Task.isCancelled else { break }
                self?.model?.setOpenRequests(list)
            }
        }
    }

    public func stopObserving() {
        observer?.cancel()
        observer = nil
        openRequestObserver?.cancel()
        openRequestObserver = nil
    }

    /// The main pane's tone changed (Settings → Theme): every live terminal takes the new background.
    public func applyTerminalTheme() {
        for entry in entries.values { entry.surface.applyTheme() }
    }

    public func setTerminalFontSize(_ size: Double) {
        for entry in entries.values { entry.surface.setFontSize(size) }
    }

    /// Live terminals (one per run that has an owner).
    public var terminalCount: Int { entries.count }
    /// Kept screens of runs that ended.
    public var endedScreenCount: Int { endedScreens.count }

    /// What acceptance tooling records about a live terminal.
    public struct TerminalEvidence: Sendable {
        public let runID: UUID
        public let owner: UUID
        /// Nil when the evidence is redacted (real providers): the screen is
        /// never written; only whether expected tokens appeared.
        public let screenTail: String?
        public let tokenPresence: [String: Bool]
        public let outputBytes: Int
        public let pendingInputBytes: Int
        public let inputErrors: [String]
    }

    public func terminalEvidence(redacted: Bool = false, tokens: [String] = []) -> [TerminalEvidence] {
        entries.values.map {
            let statistics = $0.surface.statistics
            let screen = $0.surface.screenText()
            return TerminalEvidence(
                runID: $0.runID, owner: $0.owner,
                screenTail: redacted ? nil : String(screen.suffix(600)),
                tokenPresence: Dictionary(uniqueKeysWithValues: tokens.map { ($0, screen.contains($0)) }),
                outputBytes: statistics.outputBytes,
                pendingInputBytes: statistics.pendingInputBytes,
                inputErrors: statistics.inputErrors
            )
        }.sorted { $0.runID.uuidString < $1.runID.uuidString }
    }

    /// Types into the terminal a conversation owns, through the same delegate
    /// path keystrokes use (acceptance only; not a native key event).
    @discardableResult
    public func typeForEvidence(_ text: String, intoSession id: UUID) -> Bool {
        guard let surface = entries.values.first(where: { $0.owner == id })?.surface else { return false }
        surface.send(source: surface.view, data: ArraySlice(Array((text + "\r").utf8)))
        return true
    }

    public func runtimeEvidence() async -> [String: Any] { await Self.runtimeEvidence(of: runtime) }

    /// The one runtime diagnostics dictionary (snapshots and quit summaries).
    nonisolated public static func runtimeEvidence(of runtime: SessionRuntime) async -> [String: Any] {
        let codex = await runtime.codexServerState()
        let routing = try? JSONEncoder().encode(await runtime.codexRoutingDiagnostics())
        let stops = try? JSONEncoder().encode(await runtime.supervisor.stopDiagnostics())
        return [
            "codexRouting": routing.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:],
            "stopDiagnostics": stops.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [],
            "liveRuns": await runtime.liveRunCount(),
            "runningSessions": await runtime.supervisor.runningSessionIDs().map(\.uuidString).sorted(),
            "codexLeases": codex.servers,
            "codexServerRunning": codex.internalSessionID != nil,
            "environmentWarnings": await runtime.environmentWarnings(),
        ]
    }

    /// Quit has started: no new work, buttons off.
    public func quitStarted() {
        releaseAllEndedScreens()
        model?.quitting = true
        model?.flushPreferences()
        model?.newSession.flush()
        model?.flushChatComposers()
    }

    // MARK: ConversationIntents

    public func startSession(projectID: UUID?, launch: NewSessionLaunch, focus: NewSessionFocus,
                             outcome: @escaping @MainActor (NewSessionOutcome) -> Void) {
        // Settings → "Sessions run in" (V19, D-69): Chat by default. Without the app's Chat host (a test, a runtime-less
        // window) there is no Chat face to start in, and the terminal start stands.
        if model?.newSessionFace == .chat, model?.chatSessions != nil {
            startInChat(projectID: projectID, launch: launch, focus: focus, outcome: outcome)
        } else {
            start(provider: .claude, projectID: projectID, draft: launch, focus: focus, outcome: outcome)
        }
    }

    /// A new Claude session in the Chat face from a draft's first send. "Started" is told once Claude answered
    /// `initialize` (Ready, normally well under a second): the draft is told then, and a fresh draft or the session
    /// itself is shown. A start that fails before that is `.failed` and the draft page gives the text back; a first
    /// message that fails after it goes to the session's own draft. The two outcomes exclude each other and come in
    /// the order they happen (`onReady` is awaited, so `.started` is told before the first message is sent).
    private func startInChat(projectID: UUID?, launch: NewSessionLaunch, focus: NewSessionFocus,
                             outcome: @escaping @MainActor (NewSessionOutcome) -> Void) {
        guard let model, model.actionsAvailable, model.startableProviders.contains(.claude),
              let host = model.chatSessions else {
            outcome(.failed)
            return
        }
        let key = StartKey(provider: .claude, projectID: projectID)
        guard model.beginStart(key) else {
            outcome(.failed)
            return
        }
        let sessionID = UUID()
        // The project's start is over once the draft was told, or when the start failed: whatever the first message
        // does after Ready belongs to the session's own draft, and the next draft of the project may start meanwhile.
        let release = OneShot { [weak model] in model?.endStart(key) }
        let shot = OneShot { [weak model] in
            guard let model else { return }
            model.cardCreated(for: key)
            outcome(.started(sessionID))
            if focus == .session { model.showStarted(sessionID) }
            release.fire()
        }
        Task {
            defer { release.fire() }
            do {
                try await host.startNewSession(projectID: projectID, sessionID: sessionID, draft: launch,
                                               onReady: { await MainActor.run { shot.fire() } })
                shot.fire()
            } catch {
                // Cancelled by a Stop while starting: not a failure to report.
                let stopped = (error as? ChatDriverError) == .stopping
                // A start that failed before Ready keeps no driver (its card stays, as after a terminal start that
                // failed): nothing shows a live Chat for a session that never answered.
                if !shot.fired, !stopped { host.forget(sessionID: sessionID) }
                if !stopped { report(error, "Claude could not be started") }
                if !shot.fired { outcome(.failed) }
            }
        }
    }

    public func start(provider: ManagedSession.Provider, projectID: UUID?) {
        start(provider: provider, projectID: projectID, draft: nil, focus: .session, outcome: nil)
    }

    /// The one start path. `draft` is a new-session draft's first send (V07): the runtime starts Claude with
    /// that message, mode, model and branch choice. `focus` says whether the new session is shown (↵) or the
    /// window moves on to a fresh draft (⌘↵); `outcome` is told once whether the card exists.
    private func start(provider: ManagedSession.Provider, projectID: UUID?, draft: NewSessionLaunch?,
                       focus: NewSessionFocus, outcome: (@MainActor (NewSessionOutcome) -> Void)?) {
        guard let model, model.actionsAvailable, model.startableProviders.contains(provider) else {
            outcome?(.failed)
            return
        }
        let key = StartKey(provider: provider, projectID: projectID)
        guard model.beginStart(key) else {
            outcome?(.failed)
            return
        }
        let surface = TerminalSurface(fontSize: model.terminalFontSize)
        let size = surface.gridSize
        Task {
            var pendingSessionID: UUID?
            var reported = false
            defer {
                model.endStart(key)
                if let pendingSessionID { model.setBusy(pendingSessionID, nil) }
            }
            /// The card exists: the draft is told, then the session is shown unless a fresh draft is.
            @MainActor func cardReady(_ launch: RuntimeLaunch) {
                guard !reported else { return }
                reported = true
                outcome?(.started(launch.sessionID))
                if focus == .session { model.showStarted(launch.sessionID) }
            }
            do {
                let launch = try await runtime.startConversation(
                    provider: provider, projectID: projectID, rows: size.rows,
                    columns: size.columns, outputSink: surface.outputSink, draft: draft,
                    onTerminalReady: { launch in
                        pendingSessionID = launch.sessionID
                        model.cardCreated(for: key)
                        self.adopt(launch, surface: surface)
                        model.setBusy(launch.sessionID, .starting)
                        cardReady(launch)
                    }
                )
                if pendingSessionID == nil {
                    model.cardCreated(for: key)
                    adopt(launch, surface: surface)
                    cardReady(launch)
                }
            } catch {
                surface.runEnded()
                await reconcile()
                report(error, "\(ProviderName.title(provider)) could not be started")
                if !reported { outcome?(.failed) }
            }
        }
    }

    public func resume(sessionID: UUID) {
        guard let model, model.actionsAvailable, model.busy[sessionID] == nil, model.handovers[sessionID] == nil else { return }
        let known = model.knownProvider(of: sessionID)
        if let known, !model.startableProviders.contains(known) { return }
        model.setBusy(sessionID, .resuming)
        Task {
            defer { model.setBusy(sessionID, nil) }
            do {
                // A session resumes in the face the app-wide switch names (D-69), not in the endpoint of its last run:
                // that only says how the run was driven. Codex stays in the terminal.
                var provider = known
                if provider == nil, let catalog = model.catalog {
                    provider = try await catalog.session(id: sessionID)?.session.provider
                    // The model has no row for this id (a direct call): the catalog decides, same rule.
                    if let provider, !model.startableProviders.contains(provider) { return }
                }
                if model.newSessionFace == .chat, provider == .claude, let host = model.chatSessions {
                    try await host.driver(for: sessionID).resume()
                    model.showStarted(sessionID)
                } else {
                    // S2: the CLI restores neither mode nor model nor effort; the runtime passes the session's own,
                    // from the catalog (V16).
                    try await resumeInTerminal(sessionID)
                }
            } catch {
                report(error, "The session could not be resumed")
            }
        }
    }

    /// Resumes the session in a terminal and shows it.
    func resumeInTerminal(_ sessionID: UUID) async throws {
        guard let model else { return }
        let surface = TerminalSurface(fontSize: model.terminalFontSize)
        let size = surface.gridSize
        do {
            let launch = try await runtime.resumeConversation(
                sessionID: sessionID, rows: size.rows, columns: size.columns, outputSink: surface.outputSink
            )
            adopt(launch, surface: surface)
            model.showStarted(launch.sessionID)
        } catch {
            surface.runEnded()
            throw error
        }
    }

    public func stop(sessionID: UUID) {
        guard let model, model.actionsAvailable, model.busy[sessionID] != .stopping else { return }
        // A Stop ends a handover: the user chose to end the session, not to move it. Before the point of no return the
        // wait ends; after it the other face does not start.
        stopHandover(sessionID: sessionID)
        model.setBusy(sessionID, .stopping)
        let stopped = entries.values.first { $0.owner == sessionID }
        let stoppedRun = stopped?.runID ?? model.liveStates[sessionID]?.runID
        let navigationAtStop = model.navigationCount
        // What the user sees now is what stays: taken before any signal, so whatever the program draws
        // while it exits cannot replace it.
        if let stopped, let seen = stopped.surface.captureVisibleScreen() { stopCaptures[stopped.runID] = seen }
        Task {
            defer { model.setBusy(sessionID, nil) }
            do {
                let report = try await runtime.stopConversation(sessionID: sessionID)
                if let stoppedRun {
                    // The run's end takes the capture; one that was not taken (a stop that failed) is let go.
                    if report.succeeded { await reconcile() }
                    stopCaptures[stoppedRun] = nil
                }
                await stopGate?(sessionID)
                // A verified stop closes the session's tab like its close button. A stop that is not
                // verified keeps it, and so does a session that has a new run meanwhile. If the user moved the
                // window while the stop verified (opened the session again), the tab is only unpinned: closing
                // it would take them away from where they came back to.
                if report.succeeded, !hasNewRun(sessionID, since: stoppedRun) {
                    if model.navigationCount == navigationAtStop { model.closeTab(sessionID) } else { model.unpinTab(sessionID) }
                }
                if !report.succeeded {
                    // The card also carries the unverified stop; this makes it hard to miss.
                    let providerFailure = report.providerStages?.first { $0.outcome == "failed" }?.failureDescription
                    let detail = providerFailure ?? report.errors.first ?? "Process cleanup was not verified"
                    let count = report.remainingCountVerified == false ? "unavailable" : "\(report.remaining.count) remaining"
                    model.reportFailure("\(detail). Last process check: \(count). Stop it again to retry.")
                }
            } catch {
                if let stoppedRun { stopCaptures[stoppedRun] = nil }
                report(error, "The session could not be stopped")
            }
        }
    }

    /// True when the session owns a run other than `stoppedRun`: a resume or a start got in after the stop.
    private func hasNewRun(_ sessionID: UUID, since stoppedRun: UUID?) -> Bool {
        if entries.values.contains(where: { $0.owner == sessionID && $0.runID != stoppedRun }) { return true }
        guard let live = model?.liveStates[sessionID]?.runID else { return false }
        return live != stoppedRun
    }

    public func answer(sessionID: UUID, requestID: String, accept: Bool) {
        Task {
            do {
                try await runtime.respond(
                    sessionID: sessionID, requestID: requestID, decision: accept ? .accept : .decline
                )
            } catch {
                // The failed answer stays on the request itself; nothing is assumed answered.
                report(error, "The answer was not delivered")
            }
        }
    }

    /// "Open Session" on an agent's request (D-40). The runtime starts the session through the normal
    /// start path; the terminal is adopted exactly as a start adopts it. The selection does not move.
    /// A failed start is shown in the request's box (the runtime keeps it as failed) and never retried.
    public func approveOpen(requestID: UUID) {
        guard let model, model.actionsAvailable, approvingOpen.insert(requestID).inserted else { return }
        let surface = TerminalSurface(fontSize: model.terminalFontSize)
        let size = surface.gridSize
        Task {
            defer { approvingOpen.remove(requestID) }
            do {
                let launch = try await runtime.approveOpenRequest(
                    requestID, rows: size.rows, columns: size.columns, outputSink: surface.outputSink
                )
                adopt(launch, surface: surface)
            } catch {
                surface.runEnded()
                // A start that failed is on the request's box; only an answer that could not be given is a banner.
                if error is OpenSessionError { report(error, "The request could not be answered") }
            }
        }
    }

    public func denyOpen(requestID: UUID) {
        Task {
            do { try await runtime.denyOpenRequest(requestID) }
            catch { report(error, "The request could not be denied") }
        }
    }

    public func dismissOpen(requestID: UUID) {
        Task {
            do { try await runtime.dismissOpenRequest(requestID) }
            catch { report(error, "The request could not be dismissed") }
        }
    }

    public func viewed(sessionID: UUID) {
        Task {
            try? await runtime.markViewed(sessionID: sessionID)
            await model?.viewRecorded(sessionID)
        }
    }

    public func terminalView(sessionID: UUID) -> NSView? {
        entries.values.first { $0.owner == sessionID }?.container
    }

    public func endedScreen(sessionID: UUID) -> TerminalScreenSnapshot? { endedScreens.use(sessionID) }

    public func closeEndedScreen(sessionID: UUID) { releaseEndedScreen(sessionID) }

    /// The panel reads a subagent's transcript only from the profile's `projects` folder, the one this
    /// runtime launches Claude with.
    public func subagentTranscript(path: String, agentID: String) async -> SubagentTranscriptFile? {
        SubagentTranscriptLocation.resolve(
            path: path, agentID: agentID, projectsDirectory: await runtime.claudeProjectsDirectory())
    }

    // Permanent deletion: the runtime owns every step; these only forward.

    public func deletionPreview(sessionID: UUID) async throws -> ConversationDeletionPreview {
        try await runtime.deletionPreview(id: sessionID)
    }

    public func deleteConversation(sessionID: UUID) async throws -> ConversationDeletionOutcome {
        try await runtime.deleteConversation(id: sessionID)
    }

    public func retryDeletion(sessionID: UUID) async throws -> ConversationDeletionOutcome {
        try await runtime.retryDeletion(id: sessionID)
    }

    public func pendingDeletions() async throws -> [PendingConversationDeletion] {
        try await runtime.pendingDeletions()
    }

    public func removeFromLoomOnly(sessionID: UUID) async throws {
        try await runtime.removeFromLoomOnly(id: sessionID)
    }

    public func deletionRecoveryFailure() async -> String? {
        await runtime.deletionRecoveryFailure()
    }

    public func deleteSideChats(inProject projectID: UUID) async throws {
        try await runtime.deleteSideChats(inProject: projectID)
    }

    // MARK: Terminals

    private func adopt(_ launch: RuntimeLaunch, surface: TerminalSurface) {
        let runID = launch.runID
        // A new run of a session lets go of the screen its earlier run left behind.
        releaseEndedScreen(launch.sessionID)
        surface.setFontSize(model?.terminalFontSize ?? 14)
        surface.attach(runID: runID, endpoint: launch.terminal, inputGate: runtime.inputGate)
        // Callbacks resolve the owner when they fire, never a card captured now.
        surface.onTitle = { [weak self] title in self?.titleChanged(run: runID, title: title) }
        surface.onInputError = { [weak self] error in
            self?.model?.reportFailure(error.description)
        }
        entries[runID] = Entry(
            runID: runID, surface: surface,
            container: TerminalContainerView(terminal: surface.view), owner: launch.sessionID
        )
        model?.terminalsChanged()
        Task {
            await reconcile()
            // Warnings from the user's shell startup are shown once, not hidden.
            let warnings = await runtime.environmentWarnings()
            if !warnings.isEmpty, model?.infoMessage == nil {
                model?.showInfo("Shell startup warning: " + warnings.joined(separator: " "))
            }
        }
    }

    private func titleChanged(run runID: UUID, title: String) {
        guard let owner = entries[runID]?.owner, let model else { return }
        Task { await model.terminalTitleChanged(sessionID: owner, title: title) }
    }

    /// Reconciles with the hub's current states (a new terminal, a failed start).
    func reconcile() async {
        await reconcile(await runtime.supervisor.events.snapshot())
    }

    /// An entry whose owner's state in `frame` still carries its run needs no question: the hub
    /// publishes every run start, move (`runDetached` then `runStarted`) and end, and the supervisor
    /// changes the owner before it publishes. Only an entry the frame does not show (the run ended,
    /// moved, or started after the frame) is confirmed with the supervisor.
    func reconcile(_ frame: SessionEventFrame) async {
        var changed = false
        for listed in Array(entries.values) {
            guard let entry = entries[listed.runID] else { continue }
            if frame.sessions[entry.owner]?.runID == entry.runID { continue }
            let owner = await ownerLookup(entry.runID)
            guard let owner else {
                entries[entry.runID] = nil
                changed = true
                keepEndedScreen(entry)
                continue
            }
            if owner != entry.owner, entries[entry.runID] != nil {
                entries[entry.runID]?.owner = owner
                changed = true
                // The user is looking at this terminal: it stays in front, now
                // as the new conversation. Someone who already moved to another
                // card keeps that choice.
                model?.tabOwnerMoved(from: entry.owner, to: owner)
                if model?.selectedSessionID == entry.owner { model?.select(owner) }
            }
        }
        if changed { model?.terminalsChanged() }
    }

    /// What the run left on screen (a failed resume, an expired login, /exit, a Stop) is kept as a snapshot
    /// and the surface goes with the entry: nothing of the terminal stays alive for an ended session.
    private func keepEndedScreen(_ entry: Entry) {
        let screen = stopCaptures.removeValue(forKey: entry.runID) ?? entry.surface.captureEndedScreen()
        entry.surface.runEnded()
        guard let screen else { return }
        endedScreens.put(screen, for: entry.owner)
    }

    func releaseEndedScreen(_ id: UUID) {
        if endedScreens.remove(id) { model?.terminalsChanged() }
    }

    private func releaseAllEndedScreens() {
        guard endedScreens.count > 0 else { return }
        endedScreens.removeAll()
        model?.terminalsChanged()
    }

    func report(_ error: any Error, _ context: String) {
        if error is CancellationError { return }
        if let runtimeError = error as? SessionRuntimeError, case .alreadyStarting = runtimeError { return }
        model?.reportFailure(CatalogModel.userMessage(for: error, context: context))
    }
}
