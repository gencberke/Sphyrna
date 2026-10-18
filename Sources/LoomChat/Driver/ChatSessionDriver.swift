import Foundation
import LoomCore

public enum ChatDriverError: Error, Equatable, Sendable {
    /// A Stop, Quit or face switch is under way (or cancelled the start).
    case stopping
    /// The child could not be started, or ended before it was ready (the card's issue says why).
    case couldNotStart(String)
    /// No request waits under this id (answered, withdrawn, or the process ended).
    case noSuchRequest(String)
    /// The message is not one Loom sent in this session, or it was read already.
    case notPending(String)
    /// No item of the queue has this id.
    case noSuchQueueItem(String)
    /// The child's input queue is full (it stopped reading): the message was not sent.
    case inputFull
    /// The queue holds `ChatQueue.maximumItems` items or `ChatQueue.maximumBytes` bytes: the message was not queued.
    case queueFull
}

/// The engine of a Chat-face session (V16): the user's own `claude` speaking stream-json over pipes, inside the
/// session's run scope (`SessionRuntime.startChatConversation` / `resumeChatConversation`).
///
/// It owns the run's stdin and stdout: it writes every message and control request, reads every line into its
/// `TurnModel`, and publishes the run's work state to the event hub. It never answers a request by itself, in any mode.
///
/// - **Ready** is the `initialize` answer (`system/init` comes only with the first turn); the starting mode is read
///   from it.
/// - **Delivery** follows `command_lifecycle` and the `isReplay` echo, for Loom's own uuids only.
/// - **Stop** (and Quit, and a face switch) interrupts a running turn or a waiting request, waits for the turn's
///   `result`, then the supervisor closes stdin and waits for the exit (S1 §D6). The `leave` stop hook does the first
///   two steps, bounded by the supervisor's input-close grace; nothing here sends a signal. A Stop while the child
///   starts cancels the start the same way.
/// - **The card follows the run.** `/clear` (a new conversation in the same process) moves the run to a new card
///   (`ProcessSupervisor.adoptConversation`); the driver moves with it (`sessionID`), with its queue, and its stream
///   starts over with a "cleared" marker.
///
/// An actor, not the main actor: Quit can wait in a nested run loop where main-actor work does not run, and the stop
/// hook must still be able to interrupt and read the `result`. Views pull `snapshot()` when `updates()` fires.
public actor ChatSessionDriver {
    /// After this long without a stdout line during a turn, the turn reads "No activity for 40s" (S1 §D13).
    public static let quietAfter: TimeInterval = 40
    /// Capabilities the driver relies on (`system/init`); one that is missing is a drift notice.
    public static let requiredCapabilities = ["msg_lifecycle_v1"]

    /// The card the run is on: the session Loom started or resumed, and after a `/clear` the card the run moved to.
    public private(set) var sessionID: UUID

    private let runtime: SessionRuntime
    private let queueStore: ChatQueueStore?
    private let journal: DiagnosticJournal?
    private let clock: @Sendable () -> Date
    private let readyTimeout: Duration
    private let onChoicesChanged: @Sendable (ClaudeLaunchChoices) -> Void
    private let onContextWindow: @Sendable (_ model: String, _ window: Int) -> Void
    private let onMoved: @Sendable (_ from: UUID, _ to: UUID) -> Void

    private struct Run {
        let runID: UUID
        let pipe: PipeEndpoint
        let channel: ControlChannel
        let sink: ChatPipeSink
        let isResume: Bool
        var writer: Task<Void, Never>?
        var reader: Task<Void, Never>?
    }

    private var run: Run?
    private var phase: ChatDriverPhase = .stopped
    private var model = TurnModel(source: .live)
    /// The session's mode, model and effort as the catalog holds them (the runtime passes them on every spawn).
    private var choices = ClaudeLaunchChoices()
    private var permissionMode: String?
    private var requests: [ChatPendingRequest] = []
    private var queue: ChatQueue
    private var queueIssue: ChatQueueIssue?
    private var returnedDrafts: [ChatReturnedDraft] = []
    private var drift: [ChatDrift] = []
    private var driftKeys: Set<String> = []
    private var policySignal: ChatPolicySignal?
    private var lastActivity: Date?
    private var contextWindows: [String: Int] = [:]
    /// Loom's own sends of this session, by row id: their text (a returned draft, "Read now").
    private var sent: [String: String] = [:]
    private var turnRunning = false
    /// Loom asked this run to end (Stop, Quit, face switch, an idle stop): its exit is not a failure. Set by `stop()`
    /// and by the `leave` hook of a stop Loom made, never for an exit of the child's own.
    private var stopRequested = false
    /// A Stop came while the child was still spawning: the start ends as soon as the spawn returns.
    private var startCancelled = false
    /// The newest `assistant.error` category of the running turn: the category of an `api_error` result.
    private var lastErrorCategory: String?
    private var conversationID: String?
    /// The trigger of the newest `conversation_reset`, for the marker of the card the run moves to.
    private var resetTrigger: String?
    private var background = ChatBackgroundTasks()
    /// The work state last published, republished when the background count changes.
    private var publishedActivity: AgentActivity?
    private var turnEndWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var modelSubscribers: [UUID: AsyncStream<ModelChange>.Continuation] = [:]
    private var updateSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Rows changed since the last flush to `modelChanges` subscribers, and what else changed.
    private var streamDelta = ModelDelta()
    private var streamActivityChanged = false
    private var streamReplaced = false
    /// The number of the newest change handed to `modelChanges` readers, and the model's counts when it was made: the
    /// next growth is made against them.
    private var changeSequence = 0
    private var flushedEntries = 0
    private var flushedTurns = 0
    /// The model's counts when the newest run began (`ChatLiveState.runStart`).
    private var runStart = LiveHistoryJoin.RunStart()
    /// Frames of one stdout read are being applied: the subscribers hear of them once, at the end.
    private var ingesting = false
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Waiting for `outputEnded` to finish with a run whose output already ended.
    private var runEndWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - queueStore: where the "After this turn" queue is kept; nil keeps it in memory (tests).
    ///   - onChoicesChanged: a change the user made live (mode, model, effort, a plan approval's mode). The runtime
    ///     already recorded it in the catalog; this only tells the UI.
    ///   - onContextWindow: each `result`'s `modelUsage.<model>.contextWindow` (the model name as the context ring keys
    ///     it, `[1m]` included for the extended variant).
    ///   - onMoved: the run moved to another card (`/clear`) and the driver with it: its owner re-keys it.
    ///
    /// The callbacks are synchronous and must not wait for the main actor: a `result` read during Quit (the stop
    /// hook) calls them while the main thread may wait in a nested run loop. Hop with a task of your own.
    public init(sessionID: UUID, runtime: SessionRuntime, queueStore: ChatQueueStore? = nil, journal: DiagnosticJournal? = nil,
                readyTimeout: Duration = .seconds(30),
                clock: @escaping @Sendable () -> Date = { Date() },
                onChoicesChanged: @escaping @Sendable (ClaudeLaunchChoices) -> Void = { _ in },
                onContextWindow: @escaping @Sendable (_ model: String, _ window: Int) -> Void = { _, _ in },
                onMoved: @escaping @Sendable (_ from: UUID, _ to: UUID) -> Void = { _, _ in }) {
        self.sessionID = sessionID
        self.runtime = runtime
        self.queueStore = queueStore
        self.journal = journal
        self.readyTimeout = readyTimeout
        self.clock = clock
        self.onChoicesChanged = onChoicesChanged
        self.onContextWindow = onContextWindow
        self.onMoved = onMoved
        var queue = ChatQueue()
        do {
            queue = try queueStore?.load(sessionID: sessionID) ?? ChatQueue()
        } catch let ChatQueueStoreError.unreadable(keptAs) {
            queueIssue = .unreadable(keptAs: keptAs)
        } catch {
            queueIssue = .unreadable(keptAs: nil)
        }
        // Items still queued when Loom starts again wait for the user.
        if !queue.isEmpty, queue.paused == nil { queue.paused = .relaunch }
        self.queue = queue
    }

    deinit {
        for continuation in updateSubscribers.values { continuation.finish() }
        for continuation in modelSubscribers.values { continuation.finish() }
    }

    // MARK: Reading

    /// Everything a view needs now. Reading it changes nothing.
    public func snapshot() -> ChatDriverSnapshot {
        ChatDriverSnapshot(
            sessionID: sessionID, phase: phase, model: model, runID: run?.runID, processID: run?.pipe.pid,
            permissionMode: permissionMode,
            choices: choices, requests: requests, queue: queue, queueIssue: queueIssue,
            backgroundTaskCount: background.count, returnedDrafts: returnedDrafts, drift: drift,
            policySignal: policySignal, lastActivity: lastActivity, contextWindows: contextWindows,
            turnRunning: turnRunning
        )
    }

    public var currentPhase: ChatDriverPhase { phase }

    /// Fires (coalesced, newest only) whenever the snapshot changed, and once at once. Any number of readers, each
    /// with its own stream.
    public func updates() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        updateSubscribers[id] = continuation
        continuation.yield()
        continuation.onTermination = { [weak self] _ in Task { await self?.dropUpdateSubscriber(id) } }
        return stream
    }

    private func dropUpdateSubscriber(_ id: UUID) {
        updateSubscribers[id] = nil
    }

    /// The live model's changes, for a presentation model (`ModelChangeSource`, the source the incremental chat rows
    /// read): first the model as it is, as a `.replaced` change carrying the number of the newest change, then one change
    /// per stdout read or local edit with the next number: `.growth` with what it touched, `.replaced` when the model
    /// started over (`/clear`). Every reader shares the numbers. A reader that falls far behind loses the oldest changes
    /// it had not taken; the next one it takes is not the next number, and it asks for `snapshotChange()`.
    public func modelChanges() -> ChatModelChanges {
        let (stream, continuation) = AsyncStream.makeStream(of: ModelChange.self,
                                                            bufferingPolicy: .bufferingNewest(Self.changeBuffer))
        let id = UUID()
        modelSubscribers[id] = continuation
        flushModelChanges()
        continuation.yield(model.snapshot(sequence: changeSequence, hasOlder: false))
        continuation.onTermination = { [weak self] _ in Task { await self?.dropModelSubscriber(id) } }
        return ChatModelChanges(changes: stream)
    }

    /// Changes a reader may leave untaken before the oldest are dropped (it then asks for a snapshot).
    static let changeBuffer = 256

    /// The model as it is, as a `.replaced` change with the number of the newest change: what a reader that missed a
    /// change asks for. Anything not yet handed out is handed out first, so the next change continues from this one.
    public func snapshotChange() -> ModelChange {
        flushModelChanges()
        return model.snapshot(sequence: changeSequence, hasOlder: false)
    }

    /// The parts of the snapshot a live stream view follows, without the model (copying it out would make the driver copy
    /// its buffers on the next change).
    public func liveState() -> ChatLiveState {
        ChatLiveState(sessionID: sessionID, conversationID: conversationID, phase: phase, turnRunning: turnRunning,
                      lastActivity: lastActivity, drift: drift, policySignal: policySignal, runStart: runStart)
    }

    private func dropModelSubscriber(_ id: UUID) {
        modelSubscribers[id] = nil
    }

    private func flushModelChanges() {
        guard !streamDelta.isEmpty || streamActivityChanged || streamReplaced else { return }
        changeSequence += 1
        let change = streamReplaced
            ? model.snapshot(sequence: changeSequence, hasOlder: false)
            : model.growth(sequence: changeSequence, entriesBefore: flushedEntries, turnsBefore: flushedTurns,
                           delta: streamDelta, hasOlder: false, activityChanged: streamActivityChanged)
        flushedEntries = model.entries.count
        flushedTurns = model.turns.count
        streamDelta = ModelDelta()
        streamActivityChanged = false
        streamReplaced = false
        // A full buffer drops the reader's oldest change: the gap tells it to ask for a snapshot.
        for continuation in modelSubscribers.values { continuation.yield(change) }
    }

    /// Marks a face switch in the stream ("Continued in Terminal", "Back in Chat").
    public func noteFace(_ face: Marker.Face) {
        note(model.appendMarker(.face(face), at: clock()))
    }

    /// Drafts an interrupt gave back, handed over once: the composer takes them.
    public func takeReturnedDrafts() -> [ChatReturnedDraft] {
        defer { returnedDrafts.removeAll() }
        if !returnedDrafts.isEmpty { changed() }
        return returnedDrafts
    }

    // MARK: Start, resume, stop

    /// Starts this (new) session in the Chat face with the draft's title, ticket, workspace and choices. Ready when
    /// it returns: the CLI answered `initialize`; the draft's first message (if any) was then sent over stdin.
    @discardableResult
    public func startNew(projectID: UUID?, draft: NewSessionLaunch? = nil) async throws -> ChatSendReceipt? {
        let id = sessionID
        try await launch(isResume: false) { sink in
            try await self.runtime.startChatConversation(
                projectID: projectID, sessionID: id, draft: draft, outputSink: sink
            )
        }
        guard let message = draft?.firstMessage, !message.isEmpty else { return nil }
        return try await send(message)
    }

    /// Resumes the stopped session in the Chat face (`--resume`, with the mode, model and effort the catalog holds).
    public func resume() async throws {
        let id = sessionID
        try await launch(isResume: true) { sink in
            try await self.runtime.resumeChatConversation(sessionID: id, outputSink: sink)
        }
    }

    /// Stops the run in the verified order (interrupt, `result`, stdin, exit). Returns the supervisor's report. A
    /// Stop while the child starts cancels the start: the spawn is let finish, then the child is stopped in the same
    /// order, and the start ends with `ChatDriverError.stopping` (never as a failure).
    @discardableResult
    public func stop() async throws -> SessionStopReport {
        if phase == .starting {
            startCancelled = true
            setPhase(.stopping)
            if run == nil { _ = await waitForStart() }
        }
        stopRequested = true
        await followRun()
        do {
            return try await runtime.stopConversation(sessionID: sessionID)
        } catch {
            // Nothing of this run was stopped (it had ended, or nothing runs): no stop is under way.
            if run == nil {
                stopRequested = false
                if phase == .stopping { setPhase(.stopped) }
            } else if phase.isLive {
                stopRequested = false
            }
            throw error
        }
    }

    private func launch(
        isResume: Bool, _ start: @escaping @Sendable (ChatPipeSink) async throws -> RuntimePipeLaunch
    ) async throws {
        if phase == .stopping { throw ChatDriverError.stopping }
        if phase == .starting {
            guard await waitForStart() else { throw ChatDriverError.couldNotStart("the start failed") }
            return
        }
        guard !phase.isLive else { return }
        runStart = LiveHistoryJoin.RunStart(entries: model.entries.count, turns: model.turns.count,
                                            unknownRecords: model.unknownRecordCount)
        setPhase(.starting)
        stopRequested = false
        startCancelled = false
        let sink = ChatPipeSink(clock: clock)
        let launched: RuntimePipeLaunch
        do {
            launched = try await start(sink)
        } catch {
            finishStartWaiters(false)
            if startCancelled {
                startCancelled = false
                setPhase(.stopped)
                throw ChatDriverError.stopping
            }
            setPhase(.failed(.couldNotStart(LoomLog.category(of: error))))
            throw error
        }
        let channel = ControlChannel()
        var current = Run(runID: launched.runID, pipe: launched.pipe, channel: channel, sink: sink, isResume: isResume)
        current.writer = Task {
            for await line in channel.outgoing {
                do { try await launched.pipe.write(line) } catch { break }
            }
        }
        current.reader = Task { [weak self] in
            for await input in sink.inputs {
                guard let self else {
                    sink.close()
                    return
                }
                await self.receive(input, from: sink)
            }
        }
        let drain = channel.events
        Task { for await _ in drain {} }
        run = current
        let runID = launched.runID
        if let stored = try? await runtime.catalog.launchChoices(sessionID: sessionID) { choices = stored }
        try? await runtime.supervisor.registerStopHooks(runID: runID, hooks: ManagedRunStopHooks(
            prepare: {}, completed: {},
            leave: { [weak self] request in await self?.leave(request) },
            moved: { [weak self] card in await self?.followMove(to: card) }
        ))
        if startCancelled {
            // The waiting Stop goes on now and stops the child in the verified order.
            finishStartWaiters(false)
            throw ChatDriverError.stopping
        }
        do {
            let reply = try await channel.request(.initialize, timeout: readyTimeout)
            guard run?.runID == runID, phase == .starting else { throw ChatDriverError.stopping }
            let response = reply.initializeResponse
            permissionMode = response.currentPermissionMode ?? permissionMode
            note(model.apply(ready: response, at: clock()))
            setPhase(.ready)
            await publish(.atPrompt)
            finishStartWaiters(true)
        } catch {
            finishStartWaiters(false)
            // A Stop during Starting: the start is cancelled, not failed.
            if stopRequested || startCancelled || phase == .stopping { throw ChatDriverError.stopping }
            guard run?.runID == runID else {
                // The child ended before it was ready; `outputEnded` says why (it may still be reading stderr).
                if phase == .starting { await waitForRunEnd() }
                if case let .failed(.couldNotStart(reason)) = phase { throw ChatDriverError.couldNotStart(reason) }
                throw ChatDriverError.couldNotStart(LoomLog.category(of: error))
            }
            // The child lives but never answered: stop it, and say so.
            setPhase(.failed(.notReady))
            await runtime.supervisor.events.publish(
                sessionID: sessionID, change: .issue("Claude did not answer in the Chat face.")
            )
            journal?.record("chat.not_ready", ["error": .string(LoomLog.category(of: error))])
            Task { try? await self.stopAfterFailure() }
            throw ChatDriverError.couldNotStart("no answer to initialize")
        }
    }

    private func stopAfterFailure() async throws {
        stopRequested = true
        _ = try await runtime.stopConversation(sessionID: sessionID)
        // The phase stays failed: the run never became ready.
        if phase == .stopped { setPhase(.failed(.notReady)) }
    }

    private func waitForStart() async -> Bool {
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func finishStartWaiters(_ ready: Bool) {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ready) }
    }

    /// The supervisor's stop hook (Stop, an idle stop, Quit, a face switch), before stdin closes: interrupt a running
    /// turn or a waiting request and wait for the turn's `result`, all within the grace. Only a stop Loom made comes
    /// here (the supervisor does not call it when the leader already exited); its exit is then not a failure.
    func leave(_ request: ManagedRunLeave) async {
        guard let current = run, request.reason != .processExited else { return }
        stopRequested = true
        setPhase(.stopping)
        // Nothing queued goes out during the Stop.
        if !queue.isEmpty, queue.paused == nil { pauseQueue(.interrupted) }
        guard turnRunning || !requests.isEmpty else { return }
        let started = clock()
        await sendInterrupt(on: current.channel, timeout: request.graceSeconds)
        let left = request.graceSeconds - clock().timeIntervalSince(started)
        if left > 0 { await waitForTurnEnd(seconds: left) }
    }

    // MARK: Sending

    /// Sends a message. `.next` goes to the CLI now (read after the running tool); `.afterTurn` waits in Loom's queue
    /// while a turn runs, a request waits, or the queue already holds (or pauses) items. A stopped session is resumed
    /// first.
    @discardableResult
    public func send(_ text: String, timing: ChatSendTiming = .next) async throws -> ChatSendReceipt {
        if timing == .afterTurn, turnRunning || !requests.isEmpty || !queue.isEmpty || queue.paused != nil {
            return .queued(try enqueue(text))
        }
        try await ensureLive()
        return .sent(try await write(text, priority: .next))
    }

    /// "Read now": a sent message still waiting is taken back (`cancel_async_message`) and sent again with priority
    /// `now`, which cuts the running step. Its row keeps its place and its id; the CLI knows it by a new uuid from now
    /// on (`TurnModel.sentUUID(ofRow:)`). False when the CLI had already taken it into the turn.
    @discardableResult
    public func readNow(messageID: String) async throws -> Bool {
        guard let current = run, let text = sent[messageID],
              model.pendingUserMessageIDs.contains(messageID) else { throw ChatDriverError.notPending(messageID) }
        let reply = try await current.channel.request(.cancelAsyncMessage(messageUUID: model.sentUUID(ofRow: messageID)))
        guard reply.wasCancelled != false else { return false }
        let uuid = UUID().uuidString.lowercased()
        note(model.rekeyPendingUser(from: messageID, to: uuid))
        sent[messageID] = text
        try await deliver(OutgoingUserMessage(uuid: uuid, text: text, priority: .now), row: messageID, on: current.channel)
        changed()
        return true
    }

    /// Esc: stops the running turn. Messages the CLI held unread come back as drafts; the queue pauses.
    public func interrupt() async {
        guard let current = run, phase != .stopping, turnRunning || !requests.isEmpty else { return }
        await sendInterrupt(on: current.channel, timeout: 10)
    }

    private func ensureLive() async throws {
        switch phase {
        case .stopping: throw ChatDriverError.stopping
        case .starting, .stopped, .failed: try await resume()
        case .ready, .working, .needsYou: break
        }
    }

    private func write(_ text: String, priority: OutgoingUserMessage.Priority) async throws -> String {
        guard let current = run else { throw ChatDriverError.stopping }
        let uuid = UUID().uuidString.lowercased()
        sent[uuid] = text
        note(model.appendPendingUser(uuid: uuid, text: text, at: clock()))
        try await deliver(OutgoingUserMessage(uuid: uuid, text: text, priority: priority), row: uuid, on: current.channel)
        await beginTurn()
        return uuid
    }

    /// Queues a message on the channel. One that cannot go out shows "Not delivered" and the error says why.
    private func deliver(_ message: OutgoingUserMessage, row: String, on channel: ControlChannel) async throws {
        do {
            try await channel.write(message.line())
        } catch {
            note(model.markNotDelivered([row]))
            throw (error as? ControlError) == .outputFull ? ChatDriverError.inputFull : ChatDriverError.stopping
        }
    }

    private func sendInterrupt(on channel: ControlChannel, timeout seconds: Double) async {
        model.noteInterruptSent()
        // Paused before the reply is awaited: the interrupted turn's `result` can come first and must not release it.
        if !queue.isEmpty, queue.paused == nil { pauseQueue(.interrupted) }
        let receipt: InterruptReceipt?
        do {
            receipt = try await channel.request(.interrupt(cancelQueued: true), timeout: .seconds(seconds))
                .interruptReceipt
        } catch ControlError.unsupported {
            receipt = try? await channel.request(.interrupt(cancelQueued: false), timeout: .seconds(seconds))
                .interruptReceipt
        } catch {
            receipt = nil
        }
        for id in receipt?.cancelled ?? [] {
            let row = model.rowID(forSent: id)
            guard let text = sent[row] else { continue }
            returnedDrafts.append(ChatReturnedDraft(messageID: row, text: text))
            if let lifecycle = CommandLifecycle(json: ["command_uuid": .string(id), "state": "cancelled"]) {
                note(model.apply(.commandLifecycle(lifecycle), at: clock()))
            }
        }
        changed()
    }

    // MARK: Requests (cards)

    /// Answers a waiting request. A denial with `interrupt` stops the turn ("Deny and stop"). `record` is the one line
    /// the stream keeps of the card.
    public func respond(to requestID: String, with decision: PermissionDecision,
                        record: RequestRecord? = nil) async throws {
        guard let current = run, requests.contains(where: { $0.requestID == requestID }) else {
            throw ChatDriverError.noSuchRequest(requestID)
        }
        let stops: Bool
        if case .deny(_, true) = decision { stops = true } else { stops = false }
        if stops { model.noteInterruptSent() }
        guard await current.channel.respond(to: requestID, with: decision) else {
            if stops { model.clearInterruptSent() }
            // Still waiting: the answer could not be queued (the input is full); the card stays answerable.
            if await current.channel.pendingRequests.contains(where: { $0.requestID == requestID }) {
                throw ChatDriverError.inputFull
            }
            await retire(requestID: requestID)
            throw ChatDriverError.noSuchRequest(requestID)
        }
        if let record { note(model.recordRequest(record, at: clock())) }
        await retire(requestID: requestID)
        await afterRequestsChanged()
    }

    /// Approves a plan and leaves plan mode for `mode` (sent every time, also when it is the mode Claude would pick).
    public func approvePlan(requestID: String, mode: String, record: RequestRecord? = nil) async throws {
        guard let request = requests.first(where: { $0.requestID == requestID }) else {
            throw ChatDriverError.noSuchRequest(requestID)
        }
        try await respond(to: requestID, with: .allow(
            updatedInput: request.request.input,
            updatedPermissions: [.setMode(PermissionMode(rawValue: mode))],
            toolUseID: request.request.toolUseID
        ), record: record)
        permissionMode = mode
        await recordChoices(ClaudeLaunchChoices(permissionMode: mode))
    }

    /// Keeps planning: the plan is denied with the user's feedback, and Claude plans on in the same turn.
    public func keepPlanning(requestID: String, feedback: String, record: RequestRecord? = nil) async throws {
        try await respond(to: requestID, with: .deny(message: feedback, interrupt: false), record: record)
    }

    private func retire(requestID: String) async {
        requests.removeAll { $0.requestID == requestID }
        changed()
        await publishRequests()
    }

    /// The run's pending requests, provider-independent, for Home, the sidebar and the Dock (and V18's cards).
    private func publishRequests() async {
        await followRun()
        await runtime.supervisor.events.publish(
            sessionID: sessionID, change: .pendingRequests(requests.map(\.summary))
        )
    }

    private func afterRequestsChanged() async {
        guard phase == .needsYou || phase == .working else { return }
        if requests.isEmpty, turnRunning {
            setPhase(.working)
            await publish(.working)
        } else if requests.isEmpty {
            setPhase(.ready)
        }
    }

    // MARK: Mode, model, effort

    /// Changes the mode now (and on every later spawn).
    public func setPermissionMode(_ mode: String) async throws {
        if let current = run, phase.isLive {
            _ = try await current.channel.request(.setPermissionMode(PermissionMode(rawValue: mode)))
            permissionMode = mode
        }
        await recordChoices(ClaudeLaunchChoices(permissionMode: mode))
    }

    public func setModel(_ name: String) async throws {
        if let current = run, phase.isLive {
            _ = try await current.channel.request(.setModel(name))
        }
        await recordChoices(ClaudeLaunchChoices(model: name))
    }

    public func setEffort(_ level: String) async throws {
        if let current = run, phase.isLive {
            _ = try await current.channel.request(.applyFlagSettings(.effortLevel(level)))
        }
        await recordChoices(ClaudeLaunchChoices(effort: level))
    }

    private func recordChoices(_ newer: ClaudeLaunchChoices) async {
        choices = choices.merging(newer)
        await followRun()
        await runtime.recordLaunchChoices(newer, sessionID: sessionID)
        changed()
        onChoicesChanged(choices)
    }

    // MARK: Queue

    /// Adds a message to the end of the queue. Refused (`queueFull`) past `ChatQueue.maximumItems` items or
    /// `ChatQueue.maximumBytes` bytes.
    @discardableResult
    public func enqueue(_ text: String) throws -> String {
        guard queue.admits(text) else { throw ChatDriverError.queueFull }
        let item = ChatQueue.Item(text: text, queuedAt: clock())
        queue.items.append(item)
        saveQueue()
        return item.id
    }

    public func editQueued(id: String, text: String) throws {
        guard let i = queue.items.firstIndex(where: { $0.id == id }) else { throw ChatDriverError.noSuchQueueItem(id) }
        guard queue.admits(text, replacing: id) else { throw ChatDriverError.queueFull }
        queue.items[i].text = text
        saveQueue()
    }

    public func moveQueued(id: String, to position: Int) throws {
        guard let i = queue.items.firstIndex(where: { $0.id == id }) else { throw ChatDriverError.noSuchQueueItem(id) }
        let item = queue.items.remove(at: i)
        queue.items.insert(item, at: min(max(0, position), queue.items.count))
        saveQueue()
    }

    @discardableResult
    public func removeQueued(id: String) throws -> ChatQueue.Item {
        guard let i = queue.items.firstIndex(where: { $0.id == id }) else { throw ChatDriverError.noSuchQueueItem(id) }
        let item = queue.items.remove(at: i)
        if queue.isEmpty { queue.paused = nil }
        saveQueue()
        return item
    }

    /// Sends a queued item at once: with priority `now` into a running turn, as a new turn otherwise. The item leaves
    /// the queue only once it is written; if it cannot be (the resume failed, a Stop began, the input is full), it
    /// stays where it was and the error says why.
    @discardableResult
    public func sendQueuedNow(id: String) async throws -> String {
        guard queue.items.contains(where: { $0.id == id }) else { throw ChatDriverError.noSuchQueueItem(id) }
        try await ensureLive()
        guard let i = queue.items.firstIndex(where: { $0.id == id }) else { throw ChatDriverError.noSuchQueueItem(id) }
        let item = queue.items.remove(at: i)
        do {
            let uuid = try await write(item.text, priority: turnRunning ? .now : .next)
            if queue.isEmpty { queue.paused = nil }
            saveQueue()
            return uuid
        } catch {
            queue.items.insert(item, at: min(i, queue.items.count))
            saveQueue()
            throw error
        }
    }

    /// Lifts a pause; the first item goes out when no turn runs and no request waits.
    public func resumeQueue() async throws {
        queue.paused = nil
        saveQueue()
        try await releaseQueue()
    }

    @discardableResult
    public func clearQueue() -> [ChatQueue.Item] {
        let items = queue.items
        queue = ChatQueue()
        saveQueue()
        return items
    }

    private func pauseQueue(_ reason: ChatQueue.PauseReason) {
        queue.paused = reason
        saveQueue()
    }

    private func saveQueue() {
        do {
            try queueStore?.save(queue, sessionID: sessionID)
            if case .notSaved = queueIssue { queueIssue = nil }
        } catch {
            queueIssue = .notSaved(LoomLog.category(of: error))
            LoomLog.error(.lifecycle, "The Chat queue could not be saved (\(LoomLog.category(of: error)))")
        }
        changed()
    }

    /// Sends the first item when nothing runs, nothing waits and the queue is not paused. The item leaves the queue
    /// only once it is written; one that cannot be goes back to the head and the error is thrown.
    private func releaseQueue() async throws {
        guard queue.paused == nil, phase != .stopping, !turnRunning, requests.isEmpty,
              let first = queue.items.first else { return }
        try await ensureLive()
        guard queue.paused == nil, phase != .stopping, !turnRunning, requests.isEmpty,
              queue.items.first?.id == first.id else { return }
        queue.items.removeFirst()
        do {
            _ = try await write(first.text, priority: .next)
            if case .notSent = queueIssue { queueIssue = nil }
            saveQueue()
        } catch {
            queue.items.insert(first, at: 0)
            saveQueue()
            throw error
        }
    }

    // MARK: Ingestion

    private func receive(_ input: ChatPipeSink.Input, from sink: ChatPipeSink) async {
        switch input {
        case let .frames(frames, at, bytes):
            lastActivity = at
            ingesting = true
            let activityBefore = model.activity
            for frame in frames {
                guard case let .message(message) = frame else {
                    note(model.apply(frame, at: at))
                    continue
                }
                await ingest(message, at: at)
            }
            if model.activity != activityBefore { streamActivityChanged = true }
            ingesting = false
            flushModelChanges()
            sink.taken(bytes)
            changed()
        case .ended:
            await outputEnded()
        }
    }

    private func ingest(_ message: StreamMessage, at now: Date) async {
        guard let current = run else { return }
        await current.channel.receive(message)
        switch message {
        case let .commandLifecycle(lifecycle):
            // Only Loom's own sends: a task notification has a uuid of its own and lifecycle records too.
            guard sent[model.rowID(forSent: lifecycle.commandUUID)] != nil else { return }
            note(model.apply(message, at: now))
        case let .result(result):
            await ingestResult(result, at: now)
        case let .controlRequest(request):
            guard case let .canUseTool(tool) = request.kind else { return }
            requests.append(ChatPendingRequest(requestID: request.requestID, request: tool, arrivedAt: now))
            if tool.toolName == "ExitPlanMode", let id = tool.toolUseID, let plan = tool.input["plan"]?.string {
                note(model.updatePlan(toolUseID: id, markdown: plan, filePath: tool.input["planFilePath"]?.string))
            }
            // A request that comes while Loom stops the run is withdrawn by the Stop's interrupt: it is not shown.
            guard phase != .stopping else { return }
            await publishRequests()
            await beginTurn()
            setPhase(.needsYou)
            await publish(.waitingForApproval)
        case let .controlCancel(requestID):
            guard requests.contains(where: { $0.requestID == requestID }) else { return }
            await retire(requestID: requestID)
            await afterRequestsChanged()
        case let .conversationReset(reset):
            // The run goes to a new card, whose stream starts with the marker (`followMove`).
            resetTrigger = reset.trigger
            if let id = reset.newConversationID { await adopt(id, transition: .new) }
        default:
            let unknownBefore = model.unknownRecordCount
            note(model.apply(message, at: now))
            await observe(message, unknownBefore: unknownBefore)
        }
    }

    private func observe(_ message: StreamMessage, unknownBefore: Int) async {
        if background.apply(message) {
            if let activity = publishedActivity { await publish(activity) }
            changed()
        }
        switch message {
        case let .systemInit(info):
            permissionMode = info.permissionMode ?? permissionMode
            let listed = Set(info.capabilities ?? [])
            for capability in Self.requiredCapabilities where !listed.contains(capability) {
                noteDrift(.missingCapability(capability))
            }
            if let id = info.sessionID { await adopt(id, transition: .automatic) }
            if !turnRunning {
                // A turn the CLI started itself (a finished background task, a queued turn).
                await beginTurn()
            }
        case let .status(status):
            permissionMode = status.permissionMode ?? permissionMode
        case let .user(user):
            let finished = Set(user.content.compactMap { block -> String? in
                if case let .toolResult(result) = block { result.toolUseID } else { nil }
            })
            guard !finished.isEmpty else { return }
            let before = requests.count
            requests.removeAll { $0.request.toolUseID.map(finished.contains) == true }
            guard requests.count != before else { return }
            await publishRequests()
            await afterRequestsChanged()
        case let .assistant(assistant):
            guard let category = assistant.error else { return }
            lastErrorCategory = category
            if ChatPolicySignal.categories.contains(category) {
                policySignal = ChatPolicySignal(category: category, source: .assistantError)
            } else if assistant.stopReason != "refusal" {
                noteDrift(.apiError(category: category, status: nil))
            }
        case let .apiRetry(retry):
            if let category = retry.error, ChatPolicySignal.categories.contains(category) {
                policySignal = ChatPolicySignal(category: category, source: .apiRetry)
            }
        case let .unknown(unknown):
            if model.unknownRecordCount > unknownBefore {
                noteDrift(.unknownRecord(type: unknown.type, subtype: unknown.subtype))
            }
        default:
            break
        }
    }

    private func ingestResult(_ result: TurnResult, at now: Date) async {
        let stoppedByLoom = model.interruptSent
        note(model.apply(.result(result), at: now))
        for (name, window) in result.contextWindows {
            let key = windowKey(name)
            contextWindows[key] = window
            onContextWindow(key, window)
        }
        // An interrupt's own result (`error_during_execution`, `is_error`, no text) is not a failed turn, nor is a
        // turn a `now` send cut.
        let failed = result.isError && !result.wasInterrupted
        if result.terminalReason == "api_error" {
            noteDrift(.apiError(category: lastErrorCategory, status: result.apiErrorStatus))
        }
        lastErrorCategory = nil
        // A `now` send cut the turn, or the CLI holds more turns: the next turn follows at once.
        let continues = !stoppedByLoom && (
            (result.queuedTurnCount ?? 0) > 0
                || model.pendingUserMessageIDs.contains { sent[$0] != nil }
        )
        guard !continues else { return }
        turnRunning = false
        wakeTurnEndWaiters()
        if phase == .working || phase == .needsYou { setPhase(requests.isEmpty ? .ready : .needsYou) }
        if failed, !queue.isEmpty { pauseQueue(.failedTurn) }
        guard phase != .stopping else { return }
        let category = result.terminalReason ?? result.subtype.rawValue
        await publish(failed ? .failed(category) : .turnComplete)
        if let runID = run?.runID { try? await runtime.supervisor.markProviderActivity(runID: runID, at: now) }
        do {
            try await releaseQueue()
        } catch {
            queueIssue = .notSent(LoomLog.category(of: error))
            changed()
        }
    }

    private func outputEnded() async {
        guard let current = run else { return }
        // The run is gone for every other call from here on, whatever the awaits below let in.
        run = nil
        let endedStarting = phase == .starting
        current.sink.close()
        await current.channel.close()
        current.writer?.cancel()
        requests.removeAll()
        background.removeAll()
        let unread = model.pendingUserMessageIDs.filter { sent[$0] != nil }
        note(model.markNotDelivered(unread))
        if turnRunning { note(model.endRunningTurn(at: clock())) }
        turnRunning = false
        wakeTurnEndWaiters()
        finishStartWaiters(false)
        // Whatever the scope does next, the hub must not stay at Working or Needs you.
        publishedActivity = nil
        try? await runtime.supervisor.updateProviderWorkState(runID: current.runID,
                                                              state: ProviderWorkState(activity: .sessionEnded(nil)))
        await runtime.supervisor.events.publish(sessionID: sessionID, change: .pendingRequests([]))
        if stopRequested {
            setPhase(.stopped)
        } else if endedStarting {
            // An exit at once (a bad flag, a resume of a conversation the CLI cannot find): its first stderr line.
            let line = await firstErrorLine(of: current.sink)
            setPhase(.failed(.couldNotStart(line ?? "ended before it was ready")))
            journal?.record("chat.ended_at_start", ["resume": .bool(current.isResume)])
            let issue = startFailureIssue(line: line, sink: current.sink, isResume: current.isResume)
            await runtime.supervisor.events.publish(sessionID: sessionID, change: .issue(issue))
        } else {
            setPhase(.failed(.ended))
            if !queue.isEmpty { pauseQueue(.processEnded) }
            journal?.record("chat.ended", [:])
            await runtime.supervisor.events.publish(
                sessionID: sessionID, change: .issue("Claude ended unexpectedly. Send a message to resume the session.")
            )
        }
        stopRequested = false
        changed()
        let waiters = runEndWaiters
        runEndWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForRunEnd() async {
        await withCheckedContinuation { runEndWaiters.append($0) }
    }

    /// Stderr can trail stdout's end by a moment.
    private func firstErrorLine(of sink: ChatPipeSink) async -> String? {
        if let line = sink.standardErrorFirstLine { return line }
        try? await Task.sleep(for: .milliseconds(100))
        return sink.standardErrorFirstLine
    }

    private func startFailureIssue(line: String?, sink: ChatPipeSink, isResume: Bool) -> String {
        if isResume, let error = ProviderResumeDiagnostics.error(
            provider: .claude, conversationID: conversationID ?? sessionID.uuidString.lowercased(),
            output: sink.standardErrorHead, exitStatus: 1
        ), case LoomError.providerHistoryUnavailable = error {
            return String(describing: error)
        }
        return "Claude ended before it was ready" + (line.map { ": \($0)" } ?? ".")
    }

    // MARK: Following the run's card

    /// The card the run is on now, as the supervisor has it (a `/clear` the hooks reported first moved it).
    private func followRun() async {
        guard let runID = run?.runID, let card = await runtime.supervisor.activeSessionID(runID: runID) else { return }
        await followMove(to: card)
    }

    /// The run moved to another card (`/clear`; the supervisor moved it, with its choices and face): the driver goes
    /// with it. Its owner re-keys it, the queue goes to the new card, and the stream starts over with the marker
    /// (the old card keeps the old conversation's transcript).
    func followMove(to card: UUID) async {
        guard card != sessionID, run != nil else { return }
        let old = sessionID
        sessionID = card
        if let queueStore {
            do {
                try queueStore.save(queue, sessionID: card)
                try queueStore.remove(sessionID: old)
            } catch {
                queueIssue = .notSaved(LoomLog.category(of: error))
            }
        }
        var fresh = TurnModel(source: .live)
        fresh.ready = model.ready
        fresh.latestInit = model.latestInit
        fresh.rateLimit = model.rateLimit
        fresh.startMarkerPlaced = true
        model = fresh
        runStart = LiveHistoryJoin.RunStart()
        streamReplaced = true
        note(model.appendMarker(.reset(trigger: resetTrigger ?? "clear"), at: clock()))
        resetTrigger = nil
        if !ingesting { flushModelChanges() }
        onMoved(old, card)
        journal?.record("chat.moved", [:])
        conversationID = await runtime.supervisor.session(id: card)?.providerConversationID ?? conversationID
        // The new card's hub entry: the run's requests and work state (the move's `runStarted` cleared them).
        await runtime.supervisor.events.publish(sessionID: card, change: .pendingRequests(requests.map(\.summary)))
        if let activity = publishedActivity { await publish(activity) }
        changed()
    }

    // MARK: Helpers

    private func beginTurn() async {
        guard !turnRunning else { return }
        turnRunning = true
        guard phase == .ready || phase == .starting else { return }
        setPhase(.working)
        await publish(.working)
    }

    private func adopt(_ id: String, transition: ConversationTransition) async {
        guard id != conversationID, let runID = run?.runID else { return }
        conversationID = id
        do {
            let card = try await runtime.supervisor.adoptConversation(runID: runID, conversationID: id, transition: transition)
            await followMove(to: card)
        } catch {
            LoomLog.error(.lifecycle, "A Chat session's identity was not recorded (\(LoomLog.category(of: error)))")
        }
    }

    private func publish(_ activity: AgentActivity) async {
        publishedActivity = activity
        guard let runID = run?.runID else { return }
        try? await runtime.supervisor.updateProviderWorkState(runID: runID, state: ProviderWorkState(
            activity: activity, pendingProviderWorkCount: background.count))
    }

    private func noteDrift(_ signal: ChatDrift) {
        let key: String
        let fields: [String: JournalValue]
        switch signal {
        case let .unknownRecord(type, subtype):
            // One notice per session, whatever the type.
            key = "unknown"
            fields = ["kind": "unknown_record", "type": .string(type ?? "-"), "subtype": .string(subtype ?? "-")]
        case let .missingCapability(name):
            key = "capability:\(name)"
            fields = ["kind": "missing_capability", "capability": .string(name)]
        case let .apiError(category, status):
            key = "api:\(category ?? "-")"
            fields = ["kind": "api_error", "category": .string(category ?? "-"), "status": .int(status ?? 0)]
        }
        guard driftKeys.insert(key).inserted else { return }
        drift.append(signal)
        journal?.record("chat.drift", fields)
        changed()
    }

    /// The context ring's key for a `modelUsage` name: the extended variant keeps `[1m]`, also when the CLI names the
    /// model without it but the session runs the extended one.
    private func windowKey(_ name: String) -> String {
        let suffix = "[1m]"
        guard !name.lowercased().contains(suffix), let chosen = choices.model?.lowercased(), chosen.contains(suffix),
              UsagePricing.canonicalModelID(chosen) == UsagePricing.canonicalModelID(name) else { return name }
        return name + suffix
    }

    private func waitForTurnEnd(seconds: Double) async {
        guard turnRunning else { return }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            turnEndWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await self?.resumeTurnEndWaiter(id)
            }
        }
    }

    private func resumeTurnEndWaiter(_ id: UUID) {
        turnEndWaiters.removeValue(forKey: id)?.resume()
    }

    private func wakeTurnEndWaiters() {
        let waiters = turnEndWaiters.values
        turnEndWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func setPhase(_ next: ChatDriverPhase) {
        guard phase != next else { return }
        phase = next
        changed()
    }

    private func note(_ delta: ModelDelta) {
        guard !delta.isEmpty else { return }
        streamDelta.merge(delta)
        if !ingesting { flushModelChanges() }
        changed()
    }

    private func changed() {
        for continuation in updateSubscribers.values { continuation.yield() }
    }
}

extension ChatDriverSnapshot {
    /// A turn runs, nothing waits for the user, and no stdout line came for `ChatSessionDriver.quietAfter`.
    public func isQuiet(at now: Date) -> Bool {
        guard turnRunning, requests.isEmpty, let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= ChatSessionDriver.quietAfter
    }
}
