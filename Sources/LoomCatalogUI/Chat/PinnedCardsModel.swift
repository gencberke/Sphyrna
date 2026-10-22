import Foundation
import LoomChat
import LoomCore
import Observation

/// What the composer offers the cards: its text is the card's text (CHAT-SPEC → Requests). The cards set it only to clear it
/// (a pick, an answer that went out) or to hand the keyboard back.
@MainActor
protocol PinnedNoteLink: AnyObject {
    /// The cards changed the note (cleared by a pick or an answer): the composer shows it.
    func cardSetNote(_ text: String)
    /// The keyboard goes back to the composer (Tab on a card).
    func focusComposer()
}

/// The text a card takes as "your note" (CHAT-SPEC → Requests): a denial's message, a plan's feedback, a question's
/// "Other". It is the composer's own text: the composer mirrors every change here (`mirror`), and a change the cards make
/// (`set`, `clear`) goes back to it. The cards read it only when the user clicks a button that uses it, and clear it only
/// after such an answer went out. Without a composer (a test, the ended screen) it is a plain value.
@MainActor
@Observable
final class PinnedNote {
    private(set) var text = ""
    /// When the user last edited the text, on the monotonic clock (system uptime, never the wall clock, so a clock change
    /// cannot hold or release a card). A change the cards or the composer make themselves is not an edit. The typing guard
    /// reads it.
    var lastEditedAt: TimeInterval?
    /// Whether the composer's field has the keyboard focus.
    var hasFocus = false
    @ObservationIgnored weak var link: (any PinnedNoteLink)?

    func edited(at time: TimeInterval) { lastEditedAt = time }

    /// The composer's text changed (the user typed, or the composer set it itself). Nothing goes back.
    func mirror(_ value: String) {
        if text != value { text = value }
    }

    /// The cards set the text (a test, evidence, a pick): the composer takes it.
    func set(_ value: String) {
        guard text != value else { return }
        text = value
        link?.cardSetNote(value)
    }

    func clear() {
        set("")
        lastEditedAt = nil
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A question card's progress: the question shown, and the picks or the user's own words for each.
struct PinnedQuestionDraft: Equatable {
    var step = 0
    var picks: [[String]]
    var other: [String?]

    init(questionCount: Int) {
        picks = Array(repeating: [], count: questionCount)
        other = Array(repeating: nil, count: questionCount)
    }

    func isAnswered(_ index: Int) -> Bool {
        guard picks.indices.contains(index) else { return false }
        return !picks[index].isEmpty || !(other[index]?.isEmpty ?? true)
    }
}

/// The pinned cards of one live chat (V18): approvals, questions and plans that wait for the user, one at a time with a
/// counter, the line an answered card folds to, and the card a dead process cut off. It follows the driver's state and
/// answers only through explicit calls; there is no path from a key (Return, Esc) or a timer to an answer.
///
/// - **The typing guard** (T3): a stack that would appear while the composer was typed in within `typingHold` waits as a
///   one-line "1 request waiting" until the user pauses, leaves the composer, sends, or opens it. It never takes the
///   composer's text or focus: the cards read `note` only when a button uses it.
/// - **A card retires on the driver's say only**: its own request id answered, withdrawn, or its `tool_use_id` finished,
///   or the process ending. The model never drops a request itself.
@MainActor
@Observable
final class PinnedCardsModel {
    struct Folded: Equatable {
        var id: String
        var kind: RequestRecord.Kind
        var summary: String
        var outcome: ChatSettledRequest.Outcome
    }

    // MARK: What the driver says

    private(set) var requests: [ChatPendingRequest] = []
    /// Cards a process that ended on its own cut off: disabled, with Resume, until the next run. Only what the card shows
    /// is kept of them, never the request's input.
    private(set) var cutOff: [ChatSettledRequest] = []
    /// The texts of messages that never reached Claude (the ended view offers them with Copy).
    private(set) var undelivered: [String] = []
    private(set) var folded: Folded?
    private(set) var phase: ChatDriverPhase = .stopped

    // MARK: What the user is doing

    /// The card shown (one of `requests`).
    private(set) var currentID: String?
    private(set) var isHeld = false
    private(set) var answering: Set<String> = []
    private(set) var failures: [String: String] = [:]
    private(set) var questionDrafts: [String: PinnedQuestionDraft] = [:]
    private(set) var planModes: [String: String] = [:]
    private(set) var expandedPlans: Set<String> = []
    /// Moves the keyboard focus to the card (the composer's Tab calls `focus()`).
    private(set) var focusRequest = 0
    /// "Show the request" (the Agents tab's notice, V23): the request whose card was brought into view, and how many times
    /// a card was. The stack scrolls to `revealedRequestID` when the count moves; a test reads both.
    private(set) var revealedRequestID: String?
    private(set) var revealCount = 0
    /// The button the ring is on while the card has the keyboard (← and → choose it). Kept here, not in a view, so a card
    /// the stack draws again (its failure line appeared, the window changed size) keeps its ring.
    var focusedIndex: Int?
    let note = PinnedNote()
    /// For the markdown of a question or a plan; the cards open nothing through it.
    @ObservationIgnored let context = ChatRowContext()

    @ObservationIgnored private let source: any ChatLiveSource
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let typingClock: () -> TimeInterval
    /// What an approval card shows, built once per request.
    @ObservationIgnored private var contents: [String: PinnedApprovalContent] = [:]
    @ObservationIgnored private let typingHold: TimeInterval
    @ObservationIgnored private let foldedLinger: TimeInterval
    @ObservationIgnored private let questionAdvance: TimeInterval
    @ObservationIgnored private var lastFoldedID: String?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var foldTask: Task<Void, Never>?
    @ObservationIgnored private var advanceTasks: [String: Task<Void, Never>] = [:]

    init(source: any ChatLiveSource, clock: @escaping () -> Date = { Date() },
         typingClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         typingHold: TimeInterval = LoomTheme.Pinned.typingHold, foldedLinger: TimeInterval = LoomTheme.Pinned.foldedLinger,
         questionAdvance: TimeInterval = LoomTheme.Pinned.questionAdvance) {
        self.source = source
        self.clock = clock
        self.typingClock = typingClock
        self.typingHold = typingHold
        self.foldedLinger = foldedLinger
        self.questionAdvance = questionAdvance
    }

    isolated deinit {
        holdTask?.cancel()
        foldTask?.cancel()
        for task in advanceTasks.values { task.cancel() }
    }

    // MARK: Reading

    var current: ChatPendingRequest? {
        requests.first { $0.requestID == currentID } ?? requests.first
    }

    /// 1-based position of the card shown among the waiting ones, and how many wait.
    var position: Int { (requests.firstIndex { $0.requestID == current?.requestID } ?? 0) + 1 }
    var count: Int { requests.count }

    /// "1 of 3", for more than one card.
    var counter: String? { requests.count > 1 ? "\(position) of \(requests.count)" : nil }

    var isEmpty: Bool { requests.isEmpty && cutOff.isEmpty && folded == nil }

    /// "1 request waiting" while the typing guard holds the stack.
    var heldText: String { requests.count == 1 ? "1 request waiting" : "\(requests.count) requests waiting" }

    func draft(for request: ChatPendingRequest) -> PinnedQuestionDraft {
        questionDrafts[request.requestID] ?? PinnedQuestionDraft(questionCount: request.questions.count)
    }

    /// What the approval card shows of a request: built once per request id, never per body evaluation.
    func content(for request: ChatPendingRequest) -> PinnedApprovalContent {
        if let known = contents[request.requestID] { return known }
        let made = PinnedApprovalContent.make(request)
        contents[request.requestID] = made
        return made
    }

    /// Nothing can be answered while the session stops: the buttons are off.
    var isStopping: Bool { phase == .stopping }

    /// Ask is the session's mode: a plan is approved in Ask, so its card offers no other mode (the driver sees to it too).
    private(set) var askIsOn = false

    /// The approval card offers "Allow for this session". A side chat's cards never do (V22 part 3): its driver refuses the
    /// answer, because a rule that outlives one request would let the fork write for good.
    @ObservationIgnored var offersSessionGrants = true

    func planMode(for request: ChatPendingRequest) -> String { planModes[request.requestID] ?? "default" }

    /// The modes a plan can continue in, in the order the card offers them (CHAT-SPEC → Plans).
    static let planModeChoices = ["default", "acceptEdits", "auto"]

    // MARK: Following the driver

    func apply(_ state: ChatLiveState) {
        if phase != state.phase { phase = state.phase }
        if askIsOn != state.isAsk { askIsOn = state.isAsk }
        if undelivered != state.undelivered { undelivered = state.undelivered }
        let incoming = state.requests
        let now = typingClock()
        let wall = clock()
        if incoming != requests {
            let appeared = requests.isEmpty && !incoming.isEmpty
            requests = incoming
            if incoming.isEmpty {
                setHeld(false)
            } else if appeared, composerIsBusy(at: now) {
                setHeld(true)
            }
            let ids = Set(incoming.map(\.requestID))
            if currentID == nil || !ids.contains(currentID!) {
                // The card shown left: the one that took its place (or the first).
                currentID = incoming.first?.requestID
                focusedIndex = nil
            }
            questionDrafts = questionDrafts.filter { ids.contains($0.key) }
            planModes = planModes.filter { ids.contains($0.key) }
            expandedPlans = expandedPlans.filter { ids.contains($0) }
            failures = failures.filter { ids.contains($0.key) }
            contents = contents.filter { ids.contains($0.key) }
            for (id, task) in advanceTasks where !ids.contains(id) {
                task.cancel()
                advanceTasks[id] = nil
            }
        }
        let ended = state.settled.filter { $0.outcome == .processEnded }
        if ended != cutOff { cutOff = ended }
        foldLatest(of: state.settled, now: wall)
    }

    private func foldLatest(of settled: [ChatSettledRequest], now: Date) {
        guard let latest = settled.last(where: { $0.outcome != .processEnded }), latest.id != lastFoldedID,
              now.timeIntervalSince(latest.settledAt) < foldedLinger else { return }
        lastFoldedID = latest.id
        folded = Folded(id: latest.id, kind: latest.recordKind, summary: latest.summary, outcome: latest.outcome)
        foldTask?.cancel()
        let id = latest.id
        let linger = foldedLinger
        foldTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(linger))
            guard !Task.isCancelled else { return }
            self?.expireFolded(id: id)
        }
    }

    func expireFolded(id: String? = nil) {
        guard id == nil || folded?.id == id else { return }
        folded = nil
    }

    // MARK: Moving between cards

    func step(_ delta: Int) {
        guard requests.count > 1, let index = requests.firstIndex(where: { $0.requestID == current?.requestID }) else { return }
        let next = (index + delta + requests.count) % requests.count
        currentID = requests[next].requestID
        focusedIndex = nil
    }

    /// Brings the card of the request a subagent asked into view (V23): it becomes the card shown, a stack the typing guard
    /// holds opens, and the stack scrolls to it. Nothing is answered and nothing in the stream scrolls. False when no waiting
    /// request names the subagent (a main-thread request names none).
    @discardableResult
    func reveal(agentID: String) -> Bool {
        guard let request = requests.first(where: { $0.agent?.id == agentID }) else { return false }
        if currentID != request.requestID {
            currentID = request.requestID
            focusedIndex = nil
        }
        setHeld(false)
        revealedRequestID = request.requestID
        revealCount += 1
        return true
    }

    /// The keyboard goes to the card (the composer's Tab). Nothing is answered.
    func focus() { focusRequest += 1 }

    /// The keyboard goes back to the composer (Tab on the card). Nothing is answered.
    func returnToComposer() { note.link?.focusComposer() }

    // MARK: The composer

    /// A card is on screen and takes the composer's text with its answer: the composer then neither sends the text as a
    /// message nor answers the card on Return. A stack the typing guard holds is not shown, so the composer sends as usual.
    var isShowingCard: Bool { current != nil && !isHeld }

    /// The kind of the card shown, for the words the composer wears.
    var shownKind: ChatPendingRequest.Kind? { isShowingCard ? current?.kind : nil }

    /// The composer is this model's note (its text, its focus). The text it holds now is the note.
    func attach(_ composer: some PinnedNoteLink, text: String, hasFocus: Bool) {
        note.link = composer
        note.mirror(text)
        note.hasFocus = hasFocus
    }

    /// The user changed the composer's text.
    func composerTextChanged(_ text: String) {
        note.mirror(text)
        noteEdited()
    }

    /// The composer set its own text (a recall, a returned draft, a restore): not an edit by the user.
    func composerTextSet(_ text: String) { note.mirror(text) }

    /// The composer's field gained or lost the keyboard. Leaving it lets a held stack show.
    func composerFocusChanged(_ focused: Bool) {
        note.hasFocus = focused
        if !focused { releaseHoldIfIdle() }
    }

    /// The composer sent a message (a send while the stack was held goes out as a message): the guard is over.
    func composerSent() {
        note.mirror("")
        note.lastEditedAt = nil
        releaseHoldIfIdle()
    }

    // MARK: The typing guard

    func composerIsBusy(at now: TimeInterval) -> Bool {
        guard note.hasFocus, let edited = note.lastEditedAt else { return false }
        return now - edited < typingHold
    }

    /// The composer lost the focus, sent, or the user paused: the held stack shows.
    func releaseHoldIfIdle(at now: TimeInterval? = nil) {
        guard isHeld, !composerIsBusy(at: now ?? typingClock()) else { return }
        setHeld(false)
    }

    /// The user opened the one-line notice.
    func openHeld() { setHeld(false) }

    private func setHeld(_ value: Bool) {
        guard isHeld != value else { return }
        isHeld = value
        holdTask?.cancel()
        holdTask = nil
        guard value else { return }
        holdTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LoomTheme.Pinned.holdPoll))
                guard let self, !Task.isCancelled else { return }
                releaseHoldIfIdle()
            }
        }
    }

    // MARK: Questions

    /// The user edited the note: on a question card, typing clears the picks of the question shown (CHAT-SPEC → Questions).
    func noteEdited() {
        note.edited(at: typingClock())
        guard let request = current, request.kind == .question, !note.trimmed.isEmpty else { return }
        var draft = draft(for: request)
        guard draft.picks.indices.contains(draft.step) else { return }
        advanceTasks[request.requestID]?.cancel()
        draft.picks[draft.step] = []
        draft.other[draft.step] = nil
        questionDrafts[request.requestID] = draft
    }

    /// Picks an option (a click, or its digit). A single-select pick moves to the next question after 200 ms, unless the
    /// question changes or another pick comes first; a multi-select pick toggles. Picking clears the note.
    func pick(option index: Int, in request: ChatPendingRequest) {
        var draft = draft(for: request)
        let questions = request.questions
        guard questions.indices.contains(draft.step), questions[draft.step].options.indices.contains(index) else { return }
        let step = draft.step
        let label = questions[step].options[index].label
        advanceTasks[request.requestID]?.cancel()
        advanceTasks[request.requestID] = nil
        if questions[step].multiSelect {
            if let at = draft.picks[step].firstIndex(of: label) { draft.picks[step].remove(at: at) } else { draft.picks[step].append(label) }
        } else {
            draft.picks[step] = [label]
        }
        draft.other[step] = nil
        questionDrafts[request.requestID] = draft
        note.clear()
        guard !questions[step].multiSelect, step < questions.count - 1 else { return }
        let id = request.requestID
        advanceTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.questionAdvance ?? 0))
            guard !Task.isCancelled else { return }
            self?.advance(id: id, from: step)
        }
    }

    private func advance(id: String, from step: Int) {
        advanceTasks[id] = nil
        guard var draft = questionDrafts[id], draft.step == step, step < draft.picks.count - 1 else { return }
        draft.step += 1
        questionDrafts[id] = draft
    }

    /// Next question: the note, if any, is this question's own answer.
    func next(in request: ChatPendingRequest) {
        var draft = draft(for: request)
        commitNote(into: &draft)
        guard draft.isAnswered(draft.step), draft.step < draft.picks.count - 1 else { return }
        advanceTasks[request.requestID]?.cancel()
        draft.step += 1
        questionDrafts[request.requestID] = draft
    }

    func back(in request: ChatPendingRequest) {
        var draft = draft(for: request)
        guard draft.step > 0 else { return }
        advanceTasks[request.requestID]?.cancel()
        draft.step -= 1
        questionDrafts[request.requestID] = draft
    }

    private func commitNote(into draft: inout PinnedQuestionDraft) {
        let text = note.trimmed
        guard !text.isEmpty, draft.picks.indices.contains(draft.step) else { return }
        draft.picks[draft.step] = []
        draft.other[draft.step] = text
        note.clear()
    }

    /// Whether Submit applies: every question has an answer (picks, or the note for the question shown).
    func canSubmit(_ request: ChatPendingRequest) -> Bool {
        var draft = draft(for: request)
        if !note.trimmed.isEmpty, draft.picks.indices.contains(draft.step), draft.other[draft.step] == nil {
            draft.picks[draft.step] = []
            draft.other[draft.step] = note.trimmed
        }
        return !draft.picks.isEmpty && draft.picks.indices.allSatisfy { draft.isAnswered($0) }
    }

    // MARK: Plans

    func setPlanMode(_ mode: String, for request: ChatPendingRequest) {
        guard Self.planModeChoices.contains(mode) else { return }
        planModes[request.requestID] = mode
    }

    func togglePlanExpanded(_ request: ChatPendingRequest) {
        if expandedPlans.contains(request.requestID) { expandedPlans.remove(request.requestID) } else { expandedPlans.insert(request.requestID) }
    }

    // MARK: Answering (every one an explicit user action)

    func allowOnce(_ request: ChatPendingRequest) async { await send(request, .allowOnce) }
    func allowForSession(_ request: ChatPendingRequest) async { await send(request, .allowForSession) }

    func deny(_ request: ChatPendingRequest) async {
        let text = note.trimmed
        if await send(request, .deny(note: text.isEmpty ? nil : text)) { note.clear() }
    }

    func denyAndStop(_ request: ChatPendingRequest) async {
        let text = note.trimmed
        if await send(request, .denyAndStop(note: text.isEmpty ? nil : text)) { note.clear() }
    }

    func approvePlan(_ request: ChatPendingRequest) async {
        await send(request, .approvePlan(mode: askIsOn ? ClaudePermissionMode.ask.rawValue : planMode(for: request)))
    }

    func keepPlanning(_ request: ChatPendingRequest) async {
        let text = note.trimmed
        if await send(request, .keepPlanning(feedback: text.isEmpty ? nil : text)) { note.clear() }
    }

    func submit(_ request: ChatPendingRequest) async {
        var draft = draft(for: request)
        commitNote(into: &draft)
        let questions = request.questions
        guard draft.picks.count == questions.count, draft.picks.indices.allSatisfy({ draft.isAnswered($0) }) else { return }
        let answers = questions.indices.map {
            ChatQuestionAnswer(question: questions[$0].question, picks: draft.picks[$0], other: draft.other[$0])
        }
        questionDrafts[request.requestID] = draft
        await send(request, .answers(answers))
    }

    /// Resume on the card a dead process cut off.
    func resume() async {
        do { try await source.resume() } catch {
            for request in cutOff { failures[request.id] = "Sphyrna could not resume the session (\(LoomLog.category(of: error)))." }
        }
    }

    @discardableResult
    private func send(_ request: ChatPendingRequest, _ answer: ChatRequestAnswer) async -> Bool {
        let id = request.requestID
        guard !answering.contains(id), requests.contains(where: { $0.requestID == id }) else { return false }
        answering.insert(id)
        failures[id] = nil
        defer { answering.remove(id) }
        do {
            try await source.answer(requestID: id, answer)
            return true
        } catch {
            failures[id] = Self.failureText(error)
            return false
        }
    }

    static func failureText(_ error: Error) -> String {
        switch error as? ChatDriverError {
        case .inputFull?: "Claude is not reading input right now. Try again in a moment."
        case .noSuchRequest?: "This request is no longer waiting."
        case .answerInProgress?: "This request is already being answered."
        case .stopping?: "The session is stopping."
        case .incompleteAnswer?: "Answer every question first."
        case .notOffered?: "The CLI does not offer that answer for this request."
        default: "Sphyrna could not send the answer (\(LoomLog.category(of: error)))."
        }
    }

    // MARK: Tests and evidence

    /// A summary in numbers and kinds, without any request text.
    var summary: [String: Any] {
        [
            "waiting": requests.count, "position": requests.isEmpty ? 0 : position, "held": isHeld,
            "folded": folded.map { String(describing: $0.outcome) } ?? "none", "cutOff": cutOff.count,
            "kind": current.map { String(describing: $0.kind) } ?? "none", "counter": counter ?? "",
            "failures": failures.count,
            "shown": isShowingCard, "noteLength": note.text.utf16.count, "noteHasFocus": note.hasFocus,
            "cardFocusRequests": focusRequest, "focusedIndex": focusedIndex ?? -1, "undelivered": undelivered.count,
        ]
    }
}
