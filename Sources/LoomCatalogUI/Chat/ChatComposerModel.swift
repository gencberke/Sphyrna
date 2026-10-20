import AppKit
import Foundation
import LoomChat
import LoomCore
import Observation
import Synchronization

/// What the composer needs from the app around it, as closures: the session's folder, the earlier messages, the other
/// sessions, the fallback context figure. The app fills them from the catalog; tests fill what they use.
struct ComposerEnvironment {
    var workingDirectory: () -> String? = { nil }
    /// The session's earlier messages, oldest first (for ↑).
    var historyTexts: () -> [String] = { [] }
    /// The context the usage index holds, when the driver has no figure yet.
    var contextFallback: () -> ContextUsage? = { nil }
    var sessionCandidates: () -> [ComposerSessionCandidate] = { [] }
    /// The text that mentions a session: its transcript and last answer.
    var sessionMention: (UUID) -> String? = { _ in nil }
    /// ⌃O in the field: cycles the stream's view (V19).
    var cycleView: (() -> Void)?
    /// What the composer says while the session is being moved to the other face; nil when it is not. Sending waits.
    var handoverNotice: () -> String? = { nil }
    /// The file scan for `@` (a test replaces it).
    var scanFiles: @Sendable (URL, ComposerCancel) -> [ComposerFileEntry] = { root, cancel in
        ComposerFileIndex.scan(root: root, isCancelled: { cancel.isCancelled })
    }
    /// How long typing must pause before the `@` list is ranked again [T3].
    var mentionDebounce: Duration = .milliseconds(120)
    /// How long a draft waits after the last change before it is written [T3].
    var draftDelay: Duration = .milliseconds(300)
}

struct ComposerSessionCandidate: Equatable {
    var id: UUID
    var title: String
    var project: String?
    var lastActivity: Date
}

/// A flag a detached piece of work reads to stop early (the task that started it cancels it).
final class ComposerCancel: Sendable {
    private let flag = Mutex(false)
    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

/// The text view as the model sees it.
@MainActor
protocol ComposerEditorBridge: AnyObject {
    func hasMarkedText() -> Bool
    var caretLocation: Int { get }
    var hasSelection: Bool { get }
    var utf16Length: Int { get }
    /// The text, read once.
    func currentText() -> String
    func replaceAll(with text: String)
    func substring(_ range: NSRange) -> String
    func replace(_ range: NSRange, with text: String)
    func insertAtCaret(_ text: String)
    /// Whether the caret is on the first / last line of the text.
    func caretLines() -> (first: Bool, last: Bool)
    func focus()
    /// A key typed while the stream had the keyboard: the field takes the focus and then the event itself, so the input
    /// method (Option characters, dead keys, composition) sees the first key as it sees every other.
    func typeIn(_ event: NSEvent)
}

extension ComposerEditorBridge {
    func typeIn(_ event: NSEvent) { focus() }
}

struct ComposerNotice: Equatable {
    var text: String
    var id = UUID()
}

struct ComposerMenuState: Equatable {
    enum Kind: Equatable {
        case commands
        case mention
    }

    var kind: Kind
    var trigger: ComposerTrigger
    var items: [ComposerMenuItem]
    var selection = 0
    /// The file list is still being read.
    var loading = false
}

/// A message taken out of the field for a send the driver has not accepted yet.
struct ComposerInFlight {
    let id = UUID()
    var text: String
    var attachments: [ComposerAttachment]
}

/// A queued message being edited in the composer (CHAT-SPEC → Queue → Edit).
struct ComposerQueueEdit: Equatable {
    var itemID: String
    /// What the composer held before: it comes back when the edit ends.
    var savedText: String
    var savedAttachments: [ComposerAttachment]
    /// The item's text when the edit began: the edit is a change only if the composer reads differently.
    var originalText = ""
}

/// What the Send button is (CHAT-SPEC → Send button).
enum ComposerSendKind: Equatable {
    case sendDisabled
    case send
    case interrupt
    /// Claude works and there is text: sent with ↵'s meaning. ⌘ held turns it into `afterTurn`.
    case sendNow
    case afterTurn
    case update
    case resume
}

/// The composer of one live Chat session (V17): its text, attachments, menus, history, queue editing and the sends,
/// kept per session for as long as the app keeps the session's driver, so a view that goes and comes back finds
/// everything where it was. The text view is the typing surface and reports each change; the model keeps the rest.
///
/// Typing costs the same at any length: a keystroke stores the field's text once (no scan), looks at the few characters
/// before the caret for a menu trigger, and schedules the draft's save (a timer, not a write).
@MainActor
@Observable
final class ChatComposerModel {
    // MARK: What the views draw

    /// The driver's part: phase, queue, choices, models, commands, context. Replaced only when it differs.
    private(set) var state: ChatComposerState
    private(set) var attachments: [ComposerAttachment] = []
    private(set) var preparing = 0
    private(set) var menu: ComposerMenuState?
    private(set) var editing: ComposerQueueEdit?
    private(set) var notice: ComposerNotice?
    /// The context ring's popover is open (a model property so evidence can open it).
    var ringPopoverOpen = false
    /// The session is being moved to the terminal: sending waits, and the text stays where it is (V19).
    var handoverPending: String? { environment.handoverNotice() }
    /// The bar's mode list, model list and effort slider are open (model properties so evidence can open them).
    var modePopoverOpen = false
    var modelPopoverOpen = false
    var effortPopoverOpen = false
    /// The effort this session had when its composer first knew one: what the slider's reset goes back to (the CLI has no
    /// "no effort"; an unset level cannot be told to it live).
    private(set) var effortBaseline: String?
    /// The user set an effort from this bar: what the driver holds from now on is theirs, not the baseline.
    var effortChanged = false
    /// True when there is text (not only spaces) or an attachment: what Send needs.
    private(set) var hasContent = false
    /// No characters at all (the placeholder shows).
    private(set) var textIsEmpty = true
    /// Changes when the model itself sets the text (a recall, a returned draft, a restore): the field then reads it.
    private(set) var textRevision = 0
    /// Unread messages (their rows offer Read now), and the ones that arrived since the last look.
    var unreadMessageIDs: [String] { state.unreadMessageIDs }

    // MARK: Plumbing

    @ObservationIgnored let driver: ChatSessionDriver
    @ObservationIgnored var environment: ComposerEnvironment
    @ObservationIgnored let drafts: ChatDraftStore?
    /// Rewind files (V21), set by the app: "Rewind files" on a user message opens the sheet, Undo on the rewind's marker runs.
    /// The rows reach them through the composer as they reach Read now and Retry.
    @ObservationIgnored var onRewindFiles: ((_ rowID: String) -> Void)?
    @ObservationIgnored var onUndoRewind: ((_ rewindID: String) -> Void)?
    /// The text as the field last reported it (not observed: a keystroke must not redraw anything).
    @ObservationIgnored private(set) var text = ""
    @ObservationIgnored weak var editor: (any ComposerEditorBridge)?
    @ObservationIgnored var history = ComposerHistory()
    /// The card the draft is kept under (follows the driver's run on `/clear`).
    @ObservationIgnored var card: UUID
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var sendTail: Task<Void, Never>?
    @ObservationIgnored var mentionTask: Task<Void, Never>?
    @ObservationIgnored var mentionCancel: ComposerCancel?
    @ObservationIgnored var fileEntries: [ComposerFileEntry] = []
    @ObservationIgnored var fileEntriesRoot: String?
    @ObservationIgnored var fileEntriesAt: Date?
    @ObservationIgnored var fileScan: Task<[ComposerFileEntry], Never>?
    @ObservationIgnored var fileScanCancel: ComposerCancel?
    /// The `@` menu's session rows, built when it opened at that `@` (offset in the text) and dropped when it closes.
    @ObservationIgnored var mentionSessions: (location: Int, items: [ComposerMenuItem])?
    /// The trigger the user dismissed with Esc: ignored until a different one.
    @ObservationIgnored var dismissedTrigger: (kind: ComposerMenuState.Kind, location: Int)?
    /// Messages cleared from the field for a send that has not been accepted yet; they stay in the saved draft, so a crash
    /// in that window loses nothing.
    @ObservationIgnored var inFlight: [ComposerInFlight] = []
    /// V18's pinned cards (above the composer): the composer's text is the card's text, and its keys and focus serve them.
    @ObservationIgnored weak var cards: PinnedCardsModel?
    /// Whether the text view has the keyboard (the cards' typing guard reads it).
    @ObservationIgnored var hasEditorFocus = false
    /// How often the composer read or scanned the whole text (tests: typing must not).
    @ObservationIgnored private(set) var fullTextReads = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored var lastSavedDraft: ChatDraft?
    /// The saved draft has been read (off the main thread): no save is written before, so it cannot be overwritten.
    @ObservationIgnored var draftLoaded = false
    @ObservationIgnored var restoreTask: Task<Void, Never>?
    @ObservationIgnored var fileWrites: Task<Void, Never>?
    /// Attachment files asked for and not yet on disk; a flush (Quit, blur) writes these itself rather than leave a draft that lists a missing file.
    @ObservationIgnored var unwrittenFiles: [String: ComposerAttachment.Content] = [:]
    /// When the draft was read from its file (nil when there was none).
    @ObservationIgnored var restoredAt: Date?
    /// The host forgot the session (it was deleted): nothing is written for it any more.
    @ObservationIgnored var forgotten = false

    init(driver: ChatSessionDriver, card: UUID, drafts: ChatDraftStore?, environment: ComposerEnvironment = ComposerEnvironment(),
         initial: ChatComposerState? = nil) {
        self.driver = driver
        self.card = card
        self.drafts = drafts
        self.environment = environment
        state = initial ?? .idle(sessionID: card)
        restoreDraft()
    }

    isolated deinit {
        for task in tasks { task.cancel() }
        saveTask?.cancel()
        mentionTask?.cancel()
        mentionCancel?.cancel()
    }

    // MARK: Following the driver

    /// Follows the driver for as long as the composer lives. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        let driver = driver
        tasks.append(Task { [weak self] in
            for await _ in await driver.updates() {
                guard let self, !Task.isCancelled else { return }
                await refresh()
            }
        })
    }

    /// Reads the driver's state now (and takes what an interrupt gave back).
    func refresh() async {
        let next = await driver.composerState()
        if next != state { state = next }
        // The baseline is what the session had at open: the stored choice, else the effort the CLI reports (its `system/init`
        // comes with the first turn). Never one the user set from this bar.
        if effortBaseline == nil, !effortChanged, let level = next.choices.effort ?? next.reportedEffort { effortBaseline = level }
        if next.sessionID != card { moveDraft(to: next.sessionID) }
        if next.hasReturnedDrafts || next.hasWithdrawnDrafts {
            // The saved draft first: what the driver wrote into it is not taken twice (`restoredAlready`).
            await restoreTask?.value
            if next.hasReturnedDrafts { await takeReturnedDrafts(await driver.takeReturnedDrafts()) }
            if next.hasWithdrawnDrafts { takeWithdrawnDrafts(await driver.takeWithdrawnDrafts()) }
        }
        endEditIfItemLeft()
    }

    // MARK: Text

    /// The field reports its text after the user changed it. Nothing here scans the text.
    func textChanged(_ value: String) {
        text = value
        let content = hasContentNow
        if hasContent != content { hasContent = content }
        if textIsEmpty != value.isEmpty { textIsEmpty = value.isEmpty }
        history.noteEdit()
        scheduleSave()
        if notice != nil { clearNotice() }
        cards?.composerTextChanged(value)
        updateMenu()
    }

    /// The model sets the text (a recall, a returned draft, a restore). The field takes it, caret at the end.
    func setText(_ value: String) {
        text = value
        if let editor { editor.replaceAll(with: value) }
        textRevision += 1
        let content = hasContentNow
        if hasContent != content { hasContent = content }
        if textIsEmpty != value.isEmpty { textIsEmpty = value.isEmpty }
        scheduleSave()
        cards?.composerTextSet(value)
        updateMenu()
    }

    private var hasContentNow: Bool {
        !attachments.isEmpty || text.contains { !$0.isWhitespace }
    }

    /// The field's text, read from the field (once) when it is attached.
    func currentText() -> String {
        if let editor { text = editor.currentText(); fullTextReads += 1 }
        return text
    }

    // MARK: The pinned cards (V18)

    /// A card is on screen above the composer: the composer's text goes with its answer, and ↵ sends nothing.
    var cardShown: Bool { cards?.isShowingCard ?? false }

    /// Joins the cards of the session's live chat: they read this composer's text and focus, and it serves their keys.
    func attach(cards: PinnedCardsModel) {
        guard self.cards !== cards else { return }
        self.cards = cards
        cards.attach(self, text: text, hasFocus: hasEditorFocus)
    }

    /// What the text does to the card shown, in the composer's own words (CHAT-SPEC → Send button): shown above the field.
    var cardNoteHint: String? { Self.cardNoteHint(for: cards?.shownKind) }

    /// The hint for a card of `kind`. The composer is one line and a bar while a card waits, so each hint fits one line of
    /// the narrowest composer (a 780 pt window with the sidebar open) and is never cut (`ReleaseBReviewTests`).
    static func cardNoteHint(for kind: ChatPendingRequest.Kind?) -> String? {
        switch kind {
        case .approval?: "If you deny, Claude gets this as your note."
        case .question?: "Claude gets this as your own answer."
        case .plan?: "If you keep planning, Claude gets this as feedback."
        case nil: nil
        }
    }

    /// The field's placeholder while a card is shown.
    var cardPlaceholder: String? {
        switch cards?.shownKind {
        case .approval?: "Note for Claude, sent if you deny"
        case .question?: "Or write your own answer"
        case .plan?: "Or say what to change in the plan"
        case nil: nil
        }
    }

    // MARK: Notices

    func show(_ message: String) {
        notice = ComposerNotice(text: message)
        noticeTask?.cancel()
        let id = notice?.id
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, notice?.id == id else { return }
            notice = nil
        }
    }

    func clearNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    // MARK: Attachments (state only; the work is in +Attach)

    func setAttachments(_ value: [ComposerAttachment]) {
        attachments = value
        let content = hasContentNow
        if hasContent != content { hasContent = content }
    }

    func beginPreparing() { preparing += 1 }
    func endPreparing() { preparing = max(0, preparing - 1) }

    // MARK: Menu state

    func setMenu(_ value: ComposerMenuState?) {
        if menu != value { menu = value }
    }

    func setEditing(_ value: ComposerQueueEdit?) {
        if editing != value { editing = value }
    }

    // MARK: Tests and evidence

    /// A short description of the composer for evidence files: kinds and counts, never the text.
    var summary: [String: Any] {
        let state = state
        return [
            "mode": state.permissionMode ?? "none", "model": state.resolvedModel ?? "none", "effort": state.reportedEffort ?? "none",
            "contextTokens": state.contextTokens ?? -1, "contextWindow": state.contextWindow ?? -1, "ringOpen": ringPopoverOpen,
            "modeOpen": modePopoverOpen, "modelOpen": modelPopoverOpen, "effortOpen": effortPopoverOpen,
            "modeTitle": ComposerBarText.modeTitle(permissionMode: state.permissionMode, choices: state.choices),
            "modelTitle": ComposerBarText.modelTitle(state), "effortTitle": ComposerBarText.effortTitle(state) ?? "none",
            "effortLevels": ComposerBarText.effortLevels(state), "noticeText": notice?.text ?? "", "choicesMode": state.choices.permissionMode ?? "none",
            "textLength": text.utf16.count, "attachments": attachments.map { $0.isImage ? "image" : "pastedText" },
            "menu": menu.map { String(describing: $0.kind) } ?? "none", "menuItems": menu?.items.count ?? 0,
            "editing": editing != nil, "queue": state.queue.items.count, "queuePaused": state.queue.paused?.rawValue ?? "none",
            "phase": String(describing: state.phase), "turnRunning": state.turnRunning, "sendKind": String(describing: sendKind(commandHeld: false)),
            "recalling": history.isRecalling, "notice": notice != nil, "unread": state.unreadMessageIDs.count,
            "cardShown": cardShown, "hasFocus": hasEditorFocus,
        ]
    }
}

extension ChatComposerModel: PinnedNoteLink {
    /// The cards cleared the note (a pick, an answer that went out).
    func cardSetNote(_ value: String) {
        guard value != text else { return }
        setText(value)
    }

    func focusComposer() { editor?.focus() }
}

extension ChatComposerModel: ChatHostedAttachment {
    func hostForgot() {
        forgotten = true
        saveTask?.cancel()
        saveTask = nil
        fileWrites?.cancel()
        restoreTask?.cancel()
    }
}
