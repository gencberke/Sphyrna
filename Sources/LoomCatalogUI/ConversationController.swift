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
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: LoomTheme.Space.terminalLeadingInset),
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

/// Connects the catalog model's intents to the session service and keeps the live terminals. The service owns the
/// lifecycle (start, resume, stop, the handover, the answers, deletion) and its state; this class forwards the intents, does what the
/// UI must do at the moments the service tells (show a session, close its tab, word a failure), and is the service's
/// terminal sinks. It keeps one terminal per live run; a card sees a terminal only while it owns that run, so after
/// `/clear` or `/new` the same terminal belongs to the new card and callbacks bound to the old card do nothing.
@MainActor
public final class ConversationController: NewSessionIntents, HandoverIntents, TerminalFaceSinks {
    struct Entry {
        let runID: UUID
        let surface: TerminalSurface
        let container: TerminalContainerView
        var owner: UUID
    }

    let runtime: SessionRuntime
    let service: SessionService
    weak var model: CatalogModel?
    private(set) var entries: [UUID: Entry] = [:]
    /// The frame of the last terminal this controller laid out: a new terminal starts at it (FB6-9).
    private(set) var lastTerminalFrame: CGSize?
    /// The last screens of ended runs, by session (FB4-3): static snapshots, no surface is kept.
    private(set) var endedScreens = EndedScreenStore()
    /// What the user saw when they pressed Stop, by run, until that run's end uses it.
    private var stopCaptures: [UUID: TerminalScreenSnapshot] = [:]
    /// Who owns a run right now, asked of the supervisor. Only an entry the latest event frame does
    /// not confirm is asked about; tests count these calls.
    var ownerLookup: (UUID) async -> UUID?
    private var observer: Task<Void, Never>?
    private var openRequestObserver: Task<Void, Never>?
    /// Held at a handover's point of no return, with its target (tests act at that phase; nil in the app). The service holds
    /// the hold; this is its seam in the UI's own type.
    var handoverGate: (@MainActor (UUID, SessionFace) async -> Void)? {
        didSet {
            guard let gate = handoverGate else {
                service.handoverGate = nil
                return
            }
            service.handoverGate = { (id: UUID, face: SessionLiveFace) async in
                let target: SessionFace = face == .chat ? .chat : .terminal
                await gate(id, target)
            }
        }
    }
    /// Held after a Stop returned from the runtime, before the tab decision (tests navigate at that phase; nil in the app).
    var stopGate: (@MainActor (UUID) async -> Void)?

    public init(service: SessionService, model: CatalogModel) {
        runtime = service.runtime
        self.service = service
        self.model = model
        let runtime = service.runtime
        ownerLookup = { runID in await runtime.supervisor.activeSessionID(runID: runID) }
        service.terminal = self
        service.failureHandler = { [weak self] failure in self?.report(failure) }
        model.attach(sessions: service)
        model.intents = self
    }

    /// A controller with a service of its own, built from the model's build identity (the app builds the service itself).
    public convenience init(runtime: SessionRuntime, model: CatalogModel) {
        self.init(service: SessionService(runtime: runtime, startableProviders: model.startableProviders), model: model)
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
        guard let model, model.actionsAvailable else {
            outcome(.failed)
            return
        }
        // Settings → "Sessions run in" (V19, D-69) decides the face; the service starts the session in it.
        let completesOnIdentity = launch.choices.claudeChoices == nil
        var startedID: UUID?
        service.startSession(
            projectID: projectID, launch: launch,
            cardCreated: { [weak model] id in
                startedID = id
                if !completesOnIdentity { outcome(.started(id)) }
                if focus == .session { model?.showStarted(id) }
            },
            notStarted: { if !completesOnIdentity { outcome(.failed) } },
            startResolved: { started in
                guard completesOnIdentity else { return }
                if started, let id = startedID { outcome(.started(id)) } else { outcome(.failed) }
            }
        )
    }

    public func start(provider: ManagedSession.Provider, projectID: UUID?) {
        guard let model, model.actionsAvailable else { return }
        service.start(provider: provider, projectID: projectID, cardCreated: { [weak model] id in model?.showStarted(id) })
    }

    public func resume(sessionID: UUID) {
        guard let model, model.actionsAvailable else { return }
        service.resume(sessionID: sessionID, knownProvider: model.knownProvider(of: sessionID),
                       shown: { [weak model] id in model?.showStarted(id) })
    }

    /// Resumes the session in a terminal and shows it.
    func resumeInTerminal(_ sessionID: UUID) async throws {
        guard let model else { return }
        try await service.resumeInTerminal(sessionID, shown: { model.showStarted($0) })
    }

    public func stop(sessionID: UUID) {
        guard let model, model.actionsAvailable else { return }
        let navigationAtStop = model.navigationCount
        service.stop(
            sessionID: sessionID, liveRunID: model.liveStates[sessionID]?.runID,
            settled: { [weak self] outcome in await self?.stopSettled(sessionID, outcome, navigationAtStop: navigationAtStop) }
        )
    }

    /// The runtime answered the Stop (busy is still held): the tab decision and the unverified stop's banner.
    private func stopSettled(_ sessionID: UUID, _ outcome: SessionStopOutcome, navigationAtStop: Int) async {
        guard let model else { return }
        let report = outcome.report
        await stopGate?(sessionID)
        // A verified stop closes the session's tab like its close button. A stop that is not
        // verified keeps it, and so does a session that has a new run meanwhile. If the user moved the
        // window while the stop verified (opened the session again), the tab is only unpinned: closing
        // it would take them away from where they came back to.
        if report.succeeded, !hasNewRun(sessionID, since: outcome.run) {
            if model.navigationCount == navigationAtStop { model.closeTab(sessionID) } else { model.unpinTab(sessionID) }
        }
        if !report.succeeded {
            // The card also carries the unverified stop; this makes it hard to miss.
            let providerFailure = report.providerStages?.first { $0.outcome == "failed" }?.failureDescription
            let detail = providerFailure ?? report.errors.first ?? "Process cleanup was not verified"
            let count = report.remainingCountVerified == false ? "unavailable" : "\(report.remaining.count) remaining"
            model.reportFailure("\(detail). Last process check: \(count). Stop it again to retry.")
        }
    }

    /// True when the session owns a run other than `stoppedRun`: a resume or a start got in after the stop.
    private func hasNewRun(_ sessionID: UUID, since stoppedRun: UUID?) -> Bool {
        if entries.values.contains(where: { $0.owner == sessionID && $0.runID != stoppedRun }) { return true }
        guard let live = model?.liveStates[sessionID]?.runID else { return false }
        return live != stoppedRun
    }

    public func answer(sessionID: UUID, requestID: String, accept: Bool) {
        service.answer(sessionID: sessionID, requestID: requestID, accept: accept)
    }

    /// "Open Session" on an agent's request (D-40). The selection does not move.
    public func approveOpen(requestID: UUID) {
        guard let model, model.actionsAvailable,
              let request = model.openRequests.first(where: { $0.id == requestID }),
              let provider = request.choices.harness.provider else { return }
        guard model.capabilities(of: provider).startable else {
            report(LoomError.message(model.blockedHarnessReason(provider) ?? "The harness cannot be started"),
                   "The session could not be started")
            return
        }
        service.approveOpen(requestID: requestID, provider: provider)
    }

    public func denyOpen(requestID: UUID) { service.denyOpen(requestID: requestID) }

    public func dismissOpen(requestID: UUID) { service.dismissOpen(requestID: requestID) }

    public func viewed(sessionID: UUID) {
        Task {
            await service.markViewed(sessionID: sessionID)
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

    public func toolchainVersion(provider: ManagedSession.Provider) async -> String? {
        await runtime.toolchainVersion(for: provider)
    }

    // Permanent deletion: the service forwards to the runtime, which owns every step.

    public func deletionPreview(sessionID: UUID) async throws -> ConversationDeletionPreview {
        try await service.deletionPreview(sessionID: sessionID)
    }

    public func deleteConversation(sessionID: UUID) async throws -> ConversationDeletionOutcome {
        try await service.deleteConversation(sessionID: sessionID)
    }

    public func retryDeletion(sessionID: UUID) async throws -> ConversationDeletionOutcome {
        try await service.retryDeletion(sessionID: sessionID)
    }

    public func pendingDeletions() async throws -> [PendingConversationDeletion] {
        try await service.pendingDeletions()
    }

    public func removeFromLoomOnly(sessionID: UUID) async throws {
        try await service.removeFromLoomOnly(sessionID: sessionID)
    }

    public func deletionRecoveryFailure() async -> String? {
        await service.deletionRecoveryFailure()
    }

    public func deleteSideChats(inProject projectID: UUID) async throws {
        try await service.deleteSideChats(inProject: projectID)
    }

    // MARK: Terminals (the service's sinks)

    public func newRunSink() -> TerminalRunSink? {
        guard let model else { return nil }
        let surface = TerminalSurface(fontSize: model.terminalFontSize,
                                      launchFrame: lastTerminalFrame ?? TerminalSurfaceLimits.fallbackFrame)
        let size = surface.gridSize
        return TerminalRunSink(rows: size.rows, columns: size.columns, output: surface.outputSink, handle: surface)
    }

    public func adopt(_ launch: RuntimeLaunch, into sink: TerminalRunSink) {
        guard let surface = sink.handle as? TerminalSurface else { return }
        adopt(launch, surface: surface)
    }

    public func runFailedToStart(_ sink: TerminalRunSink) {
        (sink.handle as? TerminalSurface)?.runEnded()
    }

    public func captureForStop(sessionID: UUID) -> UUID? {
        guard let stopped = entries.values.first(where: { $0.owner == sessionID }) else { return nil }
        // What the user sees now is what stays: the service asks before any signal, so whatever the program draws
        // while it exits cannot replace it.
        if let seen = stopped.surface.captureVisibleScreen() { stopCaptures[stopped.runID] = seen }
        return stopped.runID
    }

    public func releaseStopCapture(run: UUID) { stopCaptures[run] = nil }

    /// A session dropped on a run's terminal pastes its transcript path. The owner is asked when the drag moves (a terminal
    /// refuses its own session, also after `/clear`); the lookup stays in the one folder Claude names after the working
    /// directory, off the main actor.
    private func sessionDrop(run runID: UUID) -> TerminalSessionDrop {
        TerminalSessionDrop(
            pasteboardType: SessionDrag.pasteboardType,
            sessionID: { SessionDrag.sessionID(from: $0) },
            accepts: { [weak self] id in
                guard let self, self.entries[runID]?.owner != id else { return false }
                return self.model?.composerMentionTarget(for: id) != nil
            },
            transcriptPath: { [weak self] id in
                guard let model = self?.model, let directory = model.claudeConfigDirectory,
                      let record = model.rowModels[id]?.record ?? model.liveRecords[id],
                      let conversation = record.session.providerConversationID else { return nil }
                let folder = record.session.workingDirectory
                return await Task.detached(priority: .userInitiated) {
                    ClaudeTranscriptLocator.locate(sessionID: conversation, configDirectory: directory, onlyIn: folder)?.path
                }.value
            })
    }

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
        surface.onLaidOut = { [weak self] frame in self?.lastTerminalFrame = frame }
        surface.view.sessionDrop = sessionDrop(run: runID)
        surface.view.dropWash = .init(fill: LoomTheme.Drag.washNS, edge: LoomTheme.Drag.edgeNS,
                                      edgeWidth: LoomTheme.Drag.edgeWidth, radius: LoomTheme.Drag.washRadius)
        surface.view.onDropHover = { over in
            if over { DragActivity.shared.enter(DragActivity.terminal) } else { DragActivity.shared.leave(DragActivity.terminal) }
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
    public func reconcile() async {
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

    /// The words of a failure the service reports.
    private func report(_ failure: SessionFailure) {
        let context = switch failure.kind {
        case let .startFailed(provider): "\(ProviderName.title(provider)) could not be started"
        case .resumeFailed: "The session could not be resumed"
        case .stopFailed: "The session could not be stopped"
        case .handoverFailed: "The session could not be moved"
        case .answerNotDelivered: "The answer was not delivered"
        case .openRequestNotAnswered: "The request could not be answered"
        case .openRequestNotDenied: "The request could not be denied"
        case .openRequestNotDismissed: "The request could not be dismissed"
        }
        report(failure.error, context)
    }

    func report(_ error: any Error, _ context: String) {
        if error is CancellationError { return }
        if let runtimeError = error as? SessionRuntimeError, case .alreadyStarting = runtimeError { return }
        model?.reportFailure(CatalogModel.userMessage(for: error, context: context))
    }
}
