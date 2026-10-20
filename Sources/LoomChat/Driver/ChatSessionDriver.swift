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
    /// A queued message carries text only: a message with attachments is sent, not queued.
    case queueTextOnly
    /// Nothing to send: no text and no attachment.
    case emptyMessage
    /// The answer is not one the request takes (for example "for this session" where it is not offered).
    case notOffered
    /// A question was left without an answer.
    case incompleteAnswer
    /// A request is already being answered (the first answer is on its way): a second one is refused.
    case answerInProgress
    /// The queue holds `ChatQueue.maximumItems` items or `ChatQueue.maximumBytes` bytes: the message was not queued.
    case queueFull
    /// The session is moving to the terminal (V19): a message that would start a turn waits for the other face. One
    /// "After this turn" is still queued.
    case handingOver
    /// A request (approval, question or plan) waits for the user: a handover is refused until it is answered, and a
    /// message is never sent with priority `now` into it (the queue's "Send now", V24).
    case requestWaiting
    /// Background tasks still run under the finished turn: a handover would end them, so it is refused.
    case backgroundWork
    /// The session is starting, stopping or already being handed over.
    case busy
    /// A `/clear` moved the run to a new card while the handover waited: the handover ended, nothing moved.
    case clearedDuringHandover
    /// A mode change failed and nothing changed: the session keeps its mode (`staysInAsk`: and Ask's rules are back on).
    case modeNotChanged(staysInAsk: Bool)
    /// Ask cannot be turned on: the CLI did not find Loom's output style (its plugin folder could not be written).
    case askUnavailable
    /// A message that begins with "/" was sent to a side chat: "Commands don't run in a side chat".
    case commandsRefused
    /// The action does not exist in a side chat (a mode, model or effort change, a handover to the terminal).
    case notInSideChat
    /// A side chat's first launch was asked of a driver that is not a side chat's.
    case notASideChat
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
    /// How many settled requests the driver keeps: the cards fold the newest, and a card cut off by the process ending
    /// stays until the next run.
    public static let settledLimit = 16
    /// Capabilities the driver relies on (`system/init`); one that is missing is a drift notice.
    public static let requiredCapabilities = ["msg_lifecycle_v1"]

    // MARK: State
    //
    // Swift keeps stored properties out of extensions, so all of them live here, grouped by the file that works on them.

    // Identity and collaborators (set once by `init`)

    /// The card the run is on: the session Loom started or resumed, and after a `/clear` the card the run moved to.
    public internal(set) var sessionID: UUID

    let runtime: SessionRuntime
    let queueStore: ChatQueueStore?
    /// Where the composer's drafts are kept: messages Claude never read are written here when a run ends.
    let draftStore: ChatDraftStore?
    /// Where the copies a files rewind keeps for Undo are written (nil: the session cannot rewind files).
    let rewindStore: ChatRewindStore?
    let journal: DiagnosticJournal?
    /// Decides tool requests before they become cards (`receiveToolRequest`); nil for a main session, whose every request is a
    /// card. A side chat's is `SideChatPolicy`.
    let requestPolicy: (any ChatRequestPolicy)?
    /// The session this driver's session was forked from: set for a side chat's driver only (V22,
    /// ChatSessionDriver+SideChat.swift). A side chat has no title generation, no slash commands, no mode, model or effort
    /// change, no handover and no files rewind.
    let sideChatParent: UUID?
    let clock: @Sendable () -> Date
    let readyTimeout: Duration
    let onChoicesChanged: @Sendable (ClaudeLaunchChoices) -> Void
    let onContextWindow: @Sendable (_ model: String, _ window: Int) -> Void
    let onMoved: @Sendable (_ from: UUID, _ to: UUID) -> Void
    let onTitle: @Sendable (_ card: UUID, _ title: String) -> Void

    // The run and its start and stop (ChatSessionDriver+Lifecycle.swift)

    struct Run {
        let runID: UUID
        let pipe: PipeEndpoint
        let channel: ControlChannel
        let sink: ChatPipeSink
        let isResume: Bool
        var writer: Task<Void, Never>?
        var reader: Task<Void, Never>?
    }

    var run: Run?
    var phase: ChatDriverPhase = .stopped
    /// Loom asked this run to end (Stop, Quit, face switch, an idle stop): its exit is not a failure. Set by `stop()`
    /// and by the `leave` hook of a stop Loom made, never for an exit of the child's own.
    var stopRequested = false
    /// A Stop came while the child was still spawning: the start ends as soon as the spawn returns.
    var startCancelled = false
    var startWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Waiting for `outputEnded` to finish with a run whose output already ended.
    var runEndWaiters: [CheckedContinuation<Void, Never>] = []

    // The stream, the turn and what the run reports (the helpers below; ChatSessionDriver+Ingestion.swift)

    var model = TurnModel(source: .live)
    var turnRunning = false
    /// Turns that ended (a `result`, or the run's end): a send that waited across one begins no turn of its own (`write`).
    var turnsEnded = 0
    private var drift: [ChatDrift] = []
    private var driftKeys: Set<String> = []
    var policySignal: ChatPolicySignal?
    var lastActivity: Date?
    var contextWindows: [String: Int] = [:]
    /// The newest `assistant.error` category of the running turn: the category of an `api_error` result.
    var lastErrorCategory: String?
    var conversationID: String?
    /// The trigger of the newest `conversation_reset`, for the marker of the card the run moves to.
    var resetTrigger: String?
    var background = ChatBackgroundTasks()
    /// The work state last published, republished when the background count changes.
    var publishedActivity: AgentActivity?
    private var turnEndWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The model's counts when the newest run began (`ChatLiveState.runStart`).
    var runStart = LiveHistoryJoin.RunStart()
    /// Frames of one stdout read are being applied: the subscribers hear of them once, at the end.
    var ingesting = false

    // What the readers follow (Reading, below)

    private var modelSubscribers: [UUID: AsyncStream<ModelChange>.Continuation] = [:]
    private var updateSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Rows changed since the last flush to `modelChanges` subscribers, and what else changed.
    private var streamDelta = ModelDelta()
    var streamActivityChanged = false
    var streamReplaced = false
    /// The number of the newest change handed to `modelChanges` readers, and the model's counts when it was made: the
    /// next growth is made against them.
    private var changeSequence = 0
    private var flushedEntries = 0
    private var flushedTurns = 0
    /// Whether the stored choices (the catalog's launch row) have been read into `choices`. A driver made for a session
    /// that has some shows them before any launch (`loadStoredChoices`).
    var choicesLoaded = false

    // Mode, model and effort (ChatSessionDriver+Mode.swift)

    /// The session's mode, model and effort as the catalog holds them (the runtime passes them on every spawn).
    var choices = ClaudeLaunchChoices()
    var permissionMode: String?
    /// The mode (Loom's word) the session had when Ask was turned on in this process: Ask's way back. Not kept across a
    /// relaunch; without it, leaving Ask goes to Ask before edits (Loom never picks Full access by itself).
    var modeBeforeAsk: String?
    /// The effort was cleared (to the CLI's own) and no `system/init` has said what that is: nothing is reported meanwhile.
    var effortCleared = false
    /// The chain every mode transition runs in (the picker, Ask's two directions, the launch's Ask layer, the mode a plan
    /// approval sets): one at a time, in the order asked. The actor is reentrant at every `await` of a control request,
    /// so without it two transitions interleave and the CLI ends in a mix of their states.
    var modeBusy = false
    var modeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Ask's layer is being put on again after a reset and no transition holds the mode chain yet: a message waits for it.
    var askLayerPending = false
    var askLayerWaiters: [CheckedContinuation<Void, Never>] = []
    /// The model the user chose live: the chip and the ring show it until a newer `system/init` names the model.
    var liveModel: String?

    // Requests (ChatSessionDriver+Requests.swift)

    var requests: [ChatPendingRequest] = []
    /// The newest requests that left the list, oldest first (`settledLimit`).
    var settled: [ChatSettledRequest] = []
    /// Requests whose answer is on its way: one answer per request.
    var answering: Set<String> = []

    // The queue (ChatSessionDriver+Queue.swift)

    var queue: ChatQueue
    var queueIssue: ChatQueueIssue?

    // Sending, drafts and the title (ChatSessionDriver+Sending.swift)

    var returnedDrafts: [ChatReturnedDraft] = []
    /// Messages that came back as drafts and were then sent again (Retry): a composer that took them takes them out again.
    var withdrawnDrafts: [ChatReturnedDraft] = []
    /// The texts of Loom's own messages that never reached the CLI in the newest run (the ended view offers them).
    var undelivered: [String] = []
    /// Rows of Loom's own messages whose payload (images, pasted texts) the driver still holds: the unread ones, in the
    /// order they were written (which is their order in the model's entries). A read message drops its payload. The unread
    /// rows come from here, so reading them costs the unread messages, not the stream (`unreadRows`).
    var heldPayloads: [String] = []
    /// Loom's own sends of this session, by row id: what went out (a returned draft, "Read now", "Retry").
    var sent: [String: ChatSentMessage] = [:]
    var titleState = TitleState.needed
    /// Title requests for the card the run is on that failed or held no title (`titleAttemptLimit`).
    var titleFailures = 0
    /// Tests park a send here, its row in the model: before it goes to the CLI (`false`) and once it went (`true`), each time
    /// before the turn begins here.
    var sendParked: (@Sendable (_ delivered: Bool) async -> Void)?

    // The handover to the terminal (ChatSessionDriver+Handover.swift)

    /// Where the handover is (V19). While it holds the session nothing starts a turn here (no send, no queue release), so
    /// the run never gets a second turn it would have to cut.
    var handover = HandoverState.none
    /// Mode, model and effort picked while a handover holds the session: the child is going away, so it is not told. They are
    /// the session's choice (`choices`, the catalog), the target face's launch applies them, and a handover that ends with the
    /// run still here (Cancel, `/clear`, a refusal) tells the child afterwards (`replayHeldPicks`).
    var heldPicks = HeldPicks()
    /// Tests park a handover here, once its wait for the turn is over and before it decides (the turn's end and the queue's
    /// release come while it stays parked: the order a slow mode change gives it).
    var handoverParked: (@Sendable () async -> Void)?

    // Rewind files (ChatSessionDriver+Rewind.swift)

    /// A rewind or an Undo is under way: nothing else starts a turn or another rewind meanwhile.
    var rewindBusy = false
    /// The session's newest rewind: its marker, and whether Undo is still offered (until the next message is sent).
    var newestRewind: RewindRecord?

    // The quick question (ChatSessionDriver+Side.swift)

    /// How long a quick question waits for its answer (S6: 2 to 5 s when idle).
    public static let sideQuestionTimeout: Duration = .seconds(120)
    /// The wait in use; tests shorten it.
    var sideQuestionWait = ChatSessionDriver.sideQuestionTimeout

    // The side chat (ChatSessionDriver+SideChat.swift, and the policy intake in ChatSessionDriver+Requests.swift)

    /// Requests the policy answered: those it refused (each left a line in the stream) and those it allowed (a read-only command).
    var policyRefusals = 0
    var policyAllowed = 0
    /// The side chat's first message was sent (its uuid is the card's `side_first_uuid`, written once).
    var sideFirstSent = false

    /// - Parameters:
    ///   - queueStore: where the "After this turn" queue is kept; nil keeps it in memory (tests).
    ///   - rewindStore: where a files rewind keeps its copies; nil turns the action off.
    ///   - requestPolicy: answers tool requests before they become cards; nil (a main session) lists every one.
    ///   - sideChatParent: this driver is a side chat's, forked from that session (V22).
    ///   - onChoicesChanged: a change the user made live (mode, model, effort, a plan approval's mode). The runtime
    ///     already recorded it in the catalog; this only tells the UI.
    ///   - onContextWindow: each `result`'s `modelUsage.<model>.contextWindow` (the model name as the context ring keys
    ///     it, `[1m]` included for the extended variant).
    ///   - onMoved: the run moved to another card (`/clear`) and the driver with it: its owner re-keys it.
    ///   - onTitle: Claude named the untitled session (`generate_session_title`); the owner records it as a title that is
    ///     not custom, so a rename always wins.
    ///
    /// The callbacks are synchronous and must not wait for the main actor: a `result` read during Quit (the stop
    /// hook) calls them while the main thread may wait in a nested run loop. Hop with a task of your own.
    public init(sessionID: UUID, runtime: SessionRuntime, queueStore: ChatQueueStore? = nil, draftStore: ChatDraftStore? = nil,
                rewindStore: ChatRewindStore? = nil, journal: DiagnosticJournal? = nil,
                requestPolicy: (any ChatRequestPolicy)? = nil, sideChatParent: UUID? = nil,
                readyTimeout: Duration = .seconds(30),
                clock: @escaping @Sendable () -> Date = { Date() },
                onChoicesChanged: @escaping @Sendable (ClaudeLaunchChoices) -> Void = { _ in },
                onContextWindow: @escaping @Sendable (_ model: String, _ window: Int) -> Void = { _, _ in },
                onMoved: @escaping @Sendable (_ from: UUID, _ to: UUID) -> Void = { _, _ in },
                onTitle: @escaping @Sendable (_ card: UUID, _ title: String) -> Void = { _, _ in }) {
        self.sessionID = sessionID
        self.runtime = runtime
        self.queueStore = queueStore
        self.draftStore = draftStore
        self.rewindStore = rewindStore
        self.journal = journal
        self.requestPolicy = requestPolicy
        self.sideChatParent = sideChatParent
        self.readyTimeout = readyTimeout
        self.clock = clock
        self.onChoicesChanged = onChoicesChanged
        self.onContextWindow = onContextWindow
        self.onMoved = onMoved
        self.onTitle = onTitle
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
        // Messages a run of an earlier Loom wrote and never confirmed read (a crash, a force quit) come back as the draft.
        if let draftStore {
            do { try draftStore.recoverHeld(sessionID: sessionID) } catch {
                LoomLog.error(.lifecycle, "Messages Claude may not have read could not be restored to the draft (\(LoomLog.category(of: error)))")
            }
        }
        Task { [weak self] in await self?.loadStoredChoices() }
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
            choices: choices, requests: requests, settled: settled, queue: queue, queueIssue: queueIssue,
            backgroundTaskCount: background.count, returnedDrafts: returnedDrafts, drift: drift,
            policySignal: policySignal, lastActivity: lastActivity, contextWindows: contextWindows,
            turnRunning: turnRunning
        )
    }

    public var currentPhase: ChatDriverPhase { phase }

    /// What the composer draws (`ChatComposerState`): the parts of the snapshot it follows, without the model.
    public func composerState() -> ChatComposerState {
        let initialized = model.latestInit
        // After a live change the chosen model's own name (its resolved id when the CLI listed it) until `system/init`.
        let resolved = liveModel.map { chosen in
            model.ready?.models.first { $0.value == chosen }?.resolvedModel ?? chosen
        } ?? initialized?.model
        let window = (resolved ?? choices.model).flatMap { name in
            contextWindows[windowKey(name)] ?? contextWindows.first {
                UsagePricing.canonicalModelID($0.key) == UsagePricing.canonicalModelID(name)
            }?.value
        }
        return ChatComposerState(
            sessionID: sessionID, phase: phase, turnRunning: turnRunning, requestCount: requests.count, queue: queue,
            queueIssue: queueIssue, choices: choices, permissionMode: permissionMode, resolvedModel: resolved,
            reportedEffort: effortCleared ? nil : initialized?.effort,
            models: model.ready?.models ?? [], commands: model.ready?.commands ?? [],
            slashCommands: initialized?.slashCommands ?? [], skills: initialized?.skills ?? [],
            terminalOnlyCommands: initialized?.terminalSlashCommands ?? [], backgroundTaskCount: background.count,
            unreadMessageIDs: unreadRows,
            hasReturnedDrafts: !returnedDrafts.isEmpty, hasWithdrawnDrafts: !withdrawnDrafts.isEmpty,
            contextTokens: model.contextUsage.map(\.contextTokens), contextWindow: window, contextModel: resolved,
            rewind: rewindAvailability()
        )
    }

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
                      lastActivity: lastActivity, drift: drift, policySignal: policySignal, runStart: runStart,
                      requests: requests, settled: settled, undelivered: undelivered, isAsk: isAsk)
    }

    private func dropModelSubscriber(_ id: UUID) {
        modelSubscribers[id] = nil
    }

    func flushModelChanges() {
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

    /// Marks a face switch in the stream ("Continued in Terminal").
    public func noteFace(_ face: Marker.Face) {
        note(model.appendMarker(.face(face), at: clock()))
    }

    /// Drafts an interrupt gave back, handed over once: the composer takes them.
    public func takeReturnedDrafts() -> [ChatReturnedDraft] {
        defer { returnedDrafts.removeAll() }
        if !returnedDrafts.isEmpty { changed() }
        return returnedDrafts
    }

    /// Drafts that were sent again after they came back, handed over once: the composer takes them out of its text.
    public func takeWithdrawnDrafts() -> [ChatReturnedDraft] {
        defer { withdrawnDrafts.removeAll() }
        if !withdrawnDrafts.isEmpty { changed() }
        return withdrawnDrafts
    }

    /// Reads the session's stored mode, model and effort, once, so a stopped session opened after Loom started again shows
    /// them (the composer's bar) before any launch. A launch reads them again; a live change made first wins, since it
    /// is merged into the catalog's row as well.
    func loadStoredChoices() async {
        guard !choicesLoaded else { return }
        let stored = try? await runtime.catalog.launchChoices(sessionID: sessionID)
        guard !choicesLoaded else { return }
        choicesLoaded = true
        guard let stored else { return }
        let merged = stored.merging(choices)
        guard merged != choices else { return }
        choices = merged
        changed()
    }

    // MARK: Helpers

    func beginTurn() async {
        guard !turnRunning else { return }
        turnRunning = true
        guard phase == .ready || phase == .starting else { return }
        setPhase(.working)
        await publish(.working)
    }

    func adopt(_ id: String, transition: ConversationTransition) async {
        guard id != conversationID, let runID = run?.runID else { return }
        conversationID = id
        do {
            let card = try await runtime.supervisor.adoptConversation(runID: runID, conversationID: id, transition: transition)
            await followMove(to: card)
        } catch {
            LoomLog.error(.lifecycle, "A Chat session's identity was not recorded (\(LoomLog.category(of: error)))")
        }
    }

    func publish(_ activity: AgentActivity) async {
        publishedActivity = activity
        guard let runID = run?.runID else { return }
        try? await runtime.supervisor.updateProviderWorkState(runID: runID, state: ProviderWorkState(
            activity: activity, pendingProviderWorkCount: background.count))
    }

    func noteDrift(_ signal: ChatDrift) {
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
    func windowKey(_ name: String) -> String {
        let suffix = "[1m]"
        guard !name.lowercased().contains(suffix), let chosen = choices.model?.lowercased(), chosen.contains(suffix),
              UsagePricing.canonicalModelID(chosen) == UsagePricing.canonicalModelID(name) else { return name }
        return name + suffix
    }

    func waitForTurnEnd(seconds: Double) async {
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

    func wakeTurnEndWaiters() {
        let waiters = turnEndWaiters.values
        turnEndWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func setPhase(_ next: ChatDriverPhase) {
        guard phase != next else { return }
        phase = next
        changed()
    }

    func note(_ delta: ModelDelta) {
        guard !delta.isEmpty else { return }
        streamDelta.merge(delta)
        if !ingesting { flushModelChanges() }
        changed()
    }

    func changed() {
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
