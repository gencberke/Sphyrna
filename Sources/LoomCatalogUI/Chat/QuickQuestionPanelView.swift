import AppKit
import LoomChat
import SwiftUI

/// The quick question's field as the text view's host (`ComposerEditorHost`): ↵ asks, ⇧↵ makes a new line, Esc closes the
/// panel. The text lives in the panel, so the field follows it (a cleared field after a question, a question back after an
/// error).
@MainActor
final class QuickQuestionEditorHost: ComposerEditorHost {
    private let panel: QuickQuestionPanel
    private weak var bridge: (any ComposerEditorBridge)?

    init(panel: QuickQuestionPanel) { self.panel = panel }

    var keyMode: ComposerKeys.Mode { .quick }
    var syncsByRevision: Bool { false }
    var textRevision: Int { 0 }
    var modelText: String { panel.text }

    func keyState(isRepeat: Bool, hasMarkedText: Bool, bridge: any ComposerEditorBridge) -> ComposerKeys.State {
        var state = ComposerKeys.State()
        state.mode = .quick
        state.hasMarkedText = hasMarkedText
        state.isRepeat = isRepeat
        return state
    }

    func perform(_ action: ComposerKeys.Action, bridge: any ComposerEditorBridge, in window: NSWindow?) -> Bool {
        switch action {
        case .send, .sendSecondary: panel.submit()
        case .closePanel: panel.close()
        case .pastePlain:
            guard let text = NSPasteboard.general.string(forType: .string) else { return true }
            bridge.insertAtCaret(text)
        case .ignore: break
        default: return false
        }
        return true
    }

    func textChanged(_ text: String) { panel.text = text }
    func editorEndedEditing() {}
    func paste(_ pasteboard: NSPasteboard, plain: Bool) -> Bool { false }
    func drop(_ pasteboard: NSPasteboard) -> Bool { false }
    func editorAttached(_ bridge: (any ComposerEditorBridge)?) {
        self.bridge = bridge
        // The panel is there because the user asked for it (⌘;, the palette): its field takes the keyboard, also from the main
        // composer, which the editor's own focus on appearing leaves alone. Else Return would send the question to the session.
        bridge?.focus()
    }

    func focus() { bridge?.focus() }
}

/// What the panel says in words.
enum QuickQuestionText {
    static let placeholder = "Ask a quick question"
    static let hint = "Claude answers from this session's context. The session never sees the question."

    /// "Thinking · 3 s": Loom's own timer, since the CLI reports only that the question started.
    static func waiting(seconds: Int) -> String { "Thinking \u{00B7} \(max(0, seconds)) s" }
}

/// The floating card: the last question with its answer, the field, and one quiet line about what the session sees. Over the
/// bottom of the chat column, at the composer's width; the stream behind it stays live.
struct QuickQuestionPanelView: View {
    let panel: QuickQuestionPanel
    @State private var host: QuickQuestionEditorHost
    @State private var fieldHeight = LoomTheme.QuickQuestion.fieldMinimumHeight

    init(panel: QuickQuestionPanel) {
        self.panel = panel
        _host = State(initialValue: QuickQuestionEditorHost(panel: panel))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.QuickQuestion.rowGap) {
            if let question = panel.question, panel.isWaiting || panel.answer != nil { thread(question) }
            if let failure = panel.failure {
                Text(failure).font(LoomTheme.QuickQuestion.statusFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quick-question-failure")
            }
            field
            Text(QuickQuestionText.hint).font(LoomTheme.QuickQuestion.hintFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("quick-question-hint")
        }
        .padding(.horizontal, LoomTheme.QuickQuestion.insetH)
        .padding(.top, LoomTheme.QuickQuestion.insetTop).padding(.bottom, LoomTheme.QuickQuestion.insetBottom)
        .background(RoundedRectangle(cornerRadius: LoomTheme.QuickQuestion.radius).fill(LoomTheme.QuickQuestion.fill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.QuickQuestion.radius)
            .strokeBorder(LoomTheme.QuickQuestion.stroke, lineWidth: LoomTheme.Line.hairline))
        .depth(LoomTheme.Elevation.popover)
        .overlay(alignment: .topTrailing) { closeButton }
        .frame(maxWidth: LoomTheme.QuickQuestion.column)
        .padding(.horizontal, LoomTheme.QuickQuestion.sideInset)
        .padding(.bottom, LoomTheme.QuickQuestion.bottomGap)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick question")
        .accessibilityIdentifier("quick-question")
        .onChange(of: panel.focusRequests) { host.focus() }
    }

    private var field: some View {
        ZStack(alignment: .topLeading) {
            if panel.text.isEmpty {
                Text(QuickQuestionText.placeholder)
                    .font(LoomTheme.TypeScale.reading).foregroundStyle(LoomTheme.OnPopover.placeholder)
                    .padding(.top, ComposerTextEditor.inset.height).allowsHitTesting(false).accessibilityHidden(true)
            }
            ComposerTextEditor(host: host, height: $fieldHeight, minimumHeight: LoomTheme.QuickQuestion.fieldMinimumHeight,
                               maximumHeight: LoomTheme.QuickQuestion.fieldMaximumHeight,
                               accessibilityIdentifier: "quick-question-text", accessibilityLabel: QuickQuestionText.placeholder)
                .frame(height: fieldHeight)
        }
    }

    private func thread(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.QuickQuestion.rowGap) {
            Text(question).font(LoomTheme.QuickQuestion.questionFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, LoomTheme.QuickQuestion.closeSide)
                .accessibilityIdentifier("quick-question-asked")
            if let since = panel.waitingSince {
                // One timer, alive only while the question waits: it ends with the answer, the error or the panel.
                TimelineView(.periodic(from: since, by: 1)) { timeline in
                    Text(QuickQuestionText.waiting(seconds: Int(timeline.date.timeIntervalSince(since))))
                        .font(LoomTheme.QuickQuestion.statusFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                .accessibilityIdentifier("quick-question-waiting")
            } else if let answer = panel.answer {
                ScrollView {
                    ChatMarkdownView(blocks: ChatContent.blocks(id: "quick-question", text: answer, isStreaming: false, in: panel.context),
                                     flags: [], rowID: "quick-question", context: panel.context)
                }
                .frame(maxHeight: LoomTheme.QuickQuestion.answerMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("quick-question-answer")
                HStack { ChatCopyButton(text: answer, context: panel.context); Spacer(minLength: 0) }
            }
        }
    }

    private var closeButton: some View {
        Button { panel.close() } label: {
            Image(systemName: "xmark").font(LoomTheme.QuickQuestion.closeGlyph).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .frame(width: LoomTheme.QuickQuestion.closeSide, height: LoomTheme.QuickQuestion.closeSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, LoomTheme.QuickQuestion.insetTop - 4).padding(.trailing, LoomTheme.QuickQuestion.insetH - 8)
        .accessibilityLabel("Close")
        .help("Close (esc)")
    }
}
