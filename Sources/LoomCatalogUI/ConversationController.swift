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
public final class ConversationController: ConversationIntents {
    struct Entry {
        let runID: UUID
        let surface: TerminalSurface
        let container: TerminalContainerView
        var owner: UUID
    }

    private let runtime: SessionRuntime
    private weak var model: CatalogModel?
    private(set) var entries: [UUID: Entry] = [:]
    private var observer: Task<Void, Never>?

    public init(runtime: SessionRuntime, model: CatalogModel) {
        self.runtime = runtime
        self.model = model
        model.intents = self
    }

    deinit { observer?.cancel() }

    /// Follows run ownership and run ends from the event hub. Frames coalesce,
    /// so every frame is answered by asking the runtime for the current truth.
    public func begin() async {
        guard observer == nil else { return }
        let stream = await runtime.supervisor.events.subscribe()
        observer = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { break }
                await self?.reconcile()
            }
        }
    }

    public func stopObserving() {
        observer?.cancel()
        observer = nil
    }

    public func setTerminalFontSize(_ size: Double) {
        for entry in entries.values { entry.surface.setFontSize(size) }
    }

    public var terminalCount: Int { entries.count }

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
        model?.quitting = true
        model?.flushPreferences()
    }

    // MARK: ConversationIntents

    public func start(provider: ManagedSession.Provider, projectID: UUID?) {
        guard let model, model.actionsAvailable, model.startableProviders.contains(provider) else { return }
        let key = StartKey(provider: provider, projectID: projectID)
        guard model.beginStart(key) else { return }
        let surface = TerminalSurface(fontSize: model.terminalFontSize)
        let size = surface.gridSize
        Task {
            var pendingSessionID: UUID?
            defer {
                model.endStart(key)
                if let pendingSessionID { model.setBusy(pendingSessionID, nil) }
            }
            do {
                let launch = try await runtime.startConversation(
                    provider: provider, projectID: projectID, rows: size.rows,
                    columns: size.columns, outputSink: surface.outputSink,
                    onTerminalReady: { launch in
                        pendingSessionID = launch.sessionID
                        model.cardCreated(for: key)
                        self.adopt(launch, surface: surface)
                        model.setBusy(launch.sessionID, .starting)
                        model.showStarted(launch.sessionID)
                    }
                )
                if pendingSessionID == nil {
                    adopt(launch, surface: surface)
                    model.showStarted(launch.sessionID)
                }
            } catch {
                surface.runEnded()
                await reconcile()
                report(error, "\(ProviderName.title(provider)) could not be started")
            }
        }
    }

    public func resume(sessionID: UUID) {
        guard let model, model.actionsAvailable, model.busy[sessionID] == nil else { return }
        model.setBusy(sessionID, .resuming)
        let surface = TerminalSurface(fontSize: model.terminalFontSize)
        let size = surface.gridSize
        Task {
            defer { model.setBusy(sessionID, nil) }
            do {
                let launch = try await runtime.resumeConversation(
                    sessionID: sessionID, rows: size.rows, columns: size.columns,
                    outputSink: surface.outputSink
                )
                adopt(launch, surface: surface)
                model.showStarted(launch.sessionID)
            } catch {
                surface.runEnded()
                report(error, "The conversation could not be resumed")
            }
        }
    }

    public func stop(sessionID: UUID) {
        guard let model, model.actionsAvailable, model.busy[sessionID] != .stopping else { return }
        model.setBusy(sessionID, .stopping)
        Task {
            defer { model.setBusy(sessionID, nil) }
            do {
                let report = try await runtime.stopConversation(sessionID: sessionID)
                if !report.succeeded {
                    // The card also carries the unverified stop; this makes it hard to miss.
                    let providerFailure = report.providerStages?.first { $0.outcome == "failed" }?.failureDescription
                    let detail = providerFailure ?? report.errors.first ?? "Process cleanup was not verified"
                    let count = report.remainingCountVerified == false ? "unavailable" : "\(report.remaining.count) remaining"
                    model.reportFailure("\(detail). Last process check: \(count). Stop it again to retry.")
                }
            } catch {
                report(error, "The conversation could not be stopped")
            }
        }
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

    public func viewed(sessionID: UUID) {
        Task {
            try? await runtime.markViewed(sessionID: sessionID)
            await model?.viewRecorded(sessionID)
        }
    }

    public func terminalView(sessionID: UUID) -> NSView? {
        entries.values.first { $0.owner == sessionID }?.container
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

    func reconcile() async {
        var changed = false
        for entry in Array(entries.values) {
            let owner = await runtime.supervisor.activeSessionID(runID: entry.runID)
            guard let owner else {
                entry.surface.runEnded()
                entries[entry.runID] = nil
                changed = true
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

    private func report(_ error: any Error, _ context: String) {
        if error is CancellationError { return }
        if let runtimeError = error as? SessionRuntimeError, case .alreadyStarting = runtimeError { return }
        model?.reportFailure(CatalogModel.userMessage(for: error, context: context))
    }
}
