import Foundation
import LoomChat
import Observation

/// The quick question (V22) on the model: ⌘; opens a small panel over a live Chat session, and one question at a time goes to
/// the driver's `sideQuestion`. The driver owns the rule and the wire; this file owns what the panel holds: whether it is
/// open, the field's text, the last question and its answer, and the task that waits. Nothing is kept: the answer lives in
/// memory until the panel closes, and the session never sees either.
@MainActor @Observable
final class QuickQuestionPanel {
    typealias Ask = @Sendable (_ question: String) async throws -> String

    private(set) var isOpen = false
    /// The field's text.
    var text = ""
    /// The question being answered, or the last one that was.
    private(set) var question: String?
    private(set) var answer: String?
    /// One quiet line: why the last question got no answer.
    private(set) var failure: String?
    /// When the question that waits was sent; nil while none waits.
    private(set) var waitingSince: Date?
    /// Moves when the panel asks for the keyboard (a second ⌘; while it is open).
    private(set) var focusRequests = 0

    @ObservationIgnored let ask: Ask
    @ObservationIgnored let clock: @Sendable () -> Date
    /// The driver this panel asks through; a panel made for another one is replaced.
    @ObservationIgnored let driverID: ObjectIdentifier?
    /// What the Markdown renderer of the answer needs (the stream's own views take a context).
    @ObservationIgnored let context = ChatRowContext()
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Counts the questions and the closings: an answer belongs to the question that was sent, and only while the panel stays open.
    @ObservationIgnored private var generation = 0

    init(driverID: ObjectIdentifier? = nil, clock: @escaping @Sendable () -> Date = { Date() }, ask: @escaping Ask) {
        self.driverID = driverID
        self.clock = clock
        self.ask = ask
    }

    var isWaiting: Bool { waitingSince != nil }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Return does something: the panel is open, no question waits, and the field holds one.
    var canSend: Bool { isOpen && !isWaiting && !trimmedText.isEmpty }

    func open() {
        if isOpen { focusRequests += 1 } else { isOpen = true }
    }

    /// Esc, the session leaving, or the model closing it: the question and its answer are dropped, a question still under way
    /// is told to stop, and an answer that comes back anyway is discarded.
    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        task?.cancel()
        task = nil
        text = ""
        question = nil
        answer = nil
        failure = nil
        waitingSince = nil
    }

    /// The session can no longer take a question (it stopped, left the Chat face, a handover began): the panel closes.
    func reconcile(_ availability: SideQuestionAvailability) {
        if availability != .available { close() }
    }

    /// Return. Does nothing while a question waits or the field is empty (one question at a time).
    func submit() {
        guard canSend else { return }
        let asked = trimmedText
        generation += 1
        let mine = generation
        question = asked
        answer = nil
        failure = nil
        text = ""
        waitingSince = clock()
        let ask = ask
        task = Task { [weak self] in
            let outcome: Result<String, Error>
            do { outcome = .success(try await ask(asked)) } catch { outcome = .failure(error) }
            // A closed panel, or a newer question, has no use for this answer.
            guard let self, isOpen, generation == mine else { return }
            finish(outcome, asked: asked)
        }
    }

    private func finish(_ outcome: Result<String, Error>, asked: String) {
        task = nil
        waitingSince = nil
        switch outcome {
        case let .success(reply):
            answer = reply
        case let .failure(error):
            if error is CancellationError { return }
            failure = (error as? SideQuestionError)?.text ?? "Claude could not answer"
            // The field is kept: the question comes back to it to ask again, unless the user typed something meanwhile.
            if text.isEmpty { text = asked }
        }
    }
}

/// The panels of the open window, one per session, made on first use.
@MainActor @Observable
final class QuickQuestionState {
    @ObservationIgnored private var panels: [UUID: QuickQuestionPanel] = [:]

    func panel(for sessionID: UUID) -> QuickQuestionPanel? { panels[sessionID] }

    /// The session's panel for this driver; one made for another driver (the session was stopped and its driver replaced) is
    /// closed and replaced.
    func panel(for sessionID: UUID, driver: ChatSessionDriver) -> QuickQuestionPanel {
        let id = ObjectIdentifier(driver)
        if let existing = panels[sessionID], existing.driverID == id { return existing }
        panels[sessionID]?.close()
        let made = QuickQuestionPanel(driverID: id) { question in try await driver.sideQuestion(question) }
        panels[sessionID] = made
        return made
    }

    /// The session was deleted: its panel is closed and dropped (the driver it asks through goes with it).
    func forget(_ sessionID: UUID) {
        panels.removeValue(forKey: sessionID)?.close()
    }
}

extension ChatComposerModel {
    /// Whether a quick question can be asked of this session now: the driver's phase and whether a handover holds it.
    var sideQuestionAvailability: SideQuestionAvailability {
        SideQuestionAvailability.of(phase: state.phase, handoverHolds: handoverPending != nil)
    }
}

extension CatalogModel {
    /// Whether the session can take a quick question. Only a live Chat session can: a terminal-face session has its own `/btw`
    /// that Loom cannot reach, and a stopped session is never resumed for one.
    func quickQuestionAvailability(for sessionID: UUID) -> SideQuestionAvailability {
        composer(of: sessionID)?.sideQuestionAvailability ?? .stopped
    }

    /// The selected session can take a quick question (the menu item, the palette action).
    public var canAskQuickQuestion: Bool {
        selectedSessionID.map { quickQuestionAvailability(for: $0) == .available } ?? false
    }

    /// Why "Ask a Quick Question…" is off for the selected session; nil when it is on.
    public var quickQuestionUnavailableReason: String? {
        guard let id = selectedSessionID else { return SideQuestionAvailability.stopped.reason }
        return quickQuestionAvailability(for: id).reason
    }

    /// ⌘;: opens the selected session's panel (or gives the open one the keyboard).
    public func askQuickQuestion() {
        guard let id = selectedSessionID, quickQuestionAvailability(for: id) == .available,
              let driver = chatSessions?.existingDriver(for: id) else { return }
        quick.panel(for: id, driver: driver).open()
    }
}
