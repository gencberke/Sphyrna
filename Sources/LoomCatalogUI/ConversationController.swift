import AppKit
import Foundation
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

/// Connects the catalog model's intents to the runtime and to the live
/// terminals. It keeps one terminal per live run; a card sees a terminal only
/// while it owns that run, so after `/clear` or `/new` the same terminal
/// belongs to the new card and callbacks bound to the old card do nothing.
@MainActor
public final class ConversationController: NewSessionIntents {
    struct Entry {
        let runID: UUID
        let surface: TerminalSurface
        let container: TerminalContainerView
        var owner: UUID
    }

    private let runtime: SessionRuntime
    private weak var model: CatalogModel?
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

    /// Follows run ownership and run ends from the event hub. Every frame carries the full session
    /// states, so frames may coalesce: each one is compared with the entries locally and only what it
    /// does not confirm is asked of the supervisor (see `reconcile(_:)`).
    public func begin() async {
        guard observer == nil else { return }
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
    }

    // MARK: ConversationIntents

    public func startSession(projectID: UUID?, launch: NewSessionLaunch, focus: NewSessionFocus,
                             outcome: @escaping @MainActor (NewSessionOutcome) -> Void) {
        start(provider: .claude, projectID: projectID, draft: launch, focus: focus, outcome: outcome)
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
        guard let model, model.actionsAvailable, model.busy[sessionID] == nil else { return }
        let known = model.knownProvider(of: sessionID)
        if let known, !model.startableProviders.contains(known) { return }
        model.setBusy(sessionID, .resuming)
        let surface = TerminalSurface(fontSize: model.terminalFontSize)
        let size = surface.gridSize
        Task {
            defer { model.setBusy(sessionID, nil) }
            do {
                // The model has no row for this id (a direct call): the catalog decides, same rule.
                if known == nil, let catalog = model.catalog,
                   let provider = try await catalog.session(id: sessionID)?.session.provider,
                   !model.startableProviders.contains(provider) {
                    return
                }
                // S2: the CLI restores neither mode nor model, so a session Loom started from a draft resumes
                // with the ones it was started with.
                let launch = try await runtime.resumeConversation(
                    sessionID: sessionID, rows: size.rows, columns: size.columns,
                    outputSink: surface.outputSink,
                    choices: model.newSession.launchChoices(for: sessionID) ?? ClaudeLaunchChoices()
                )
                adopt(launch, surface: surface)
                model.showStarted(launch.sessionID)
            } catch {
                surface.runEnded()
                report(error, "The session could not be resumed")
            }
        }
    }

    public func stop(sessionID: UUID) {
        guard let model, model.actionsAvailable, model.busy[sessionID] != .stopping else { return }
        model.setBusy(sessionID, .stopping)
        let stopped = entries.values.first { $0.owner == sessionID }
        let stoppedRun = stopped?.runID ?? model.liveStates[sessionID]?.runID
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
                // A verified stop closes the session's tab like its close button. A stop that is not
                // verified keeps it, and so does a session that has a new run meanwhile.
                if report.succeeded, !hasNewRun(sessionID, since: stoppedRun) { model.closeTab(sessionID) }
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
                guard let launch = try await runtime.approveOpenRequest(
                    requestID, rows: size.rows, columns: size.columns, outputSink: surface.outputSink
                ) else {
                    // The ticket got a session meanwhile: the request is a notice now, nothing started.
                    surface.runEnded()
                    return
                }
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

    public func deletionRecoveryFailure() async -> String? {
        await runtime.deletionRecoveryFailure()
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

    private func releaseEndedScreen(_ id: UUID) {
        if endedScreens.remove(id) { model?.terminalsChanged() }
    }

    private func releaseAllEndedScreens() {
        guard endedScreens.count > 0 else { return }
        endedScreens.removeAll()
        model?.terminalsChanged()
    }

    private func report(_ error: any Error, _ context: String) {
        if error is CancellationError { return }
        if let runtimeError = error as? SessionRuntimeError, case .alreadyStarting = runtimeError { return }
        model?.reportFailure(CatalogModel.userMessage(for: error, context: context))
    }
}
