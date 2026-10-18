import AppKit
import SwiftUI

/// The text field of the draft's composer: plain text that grows with its lines, with the composer's keys
/// (CHAT-SPEC → Composer → Keys). ↵ sends, ⌘↵ sends and opens a fresh draft, ⇧↵ and ⌥↵ start a new line. A
/// key never sends while an input method composes (`hasMarkedText`) and a held key never sends twice. Return
/// is matched by key code, so it does not depend on the keyboard layout. Small and replaceable: V17's
/// composer takes its place.
struct NewSessionTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var isEditable: Bool
    var onSend: () -> Void
    var onSendAndOpenFresh: () -> Void
    var onBlur: () -> Void

    static let minimumHeight: CGFloat = 60
    static let maximumHeight: CGFloat = 220
    static let inset = NSSize(width: 0, height: 4)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: LoomTheme.TypeScale.readingSize)
        textView.textColor = NSColor(LoomTheme.Text.primary)
        textView.insertionPointColor = NSColor(LoomTheme.Text.primary)
        textView.textContainerInset = Self.inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setAccessibilityIdentifier("draft-composer")
        textView.setAccessibilityLabel("Message for the new session")
        textView.string = text
        context.coordinator.synced = text
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.measure() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        textView.isEditable = isEditable
        // A change that came from the view is already in the field; only an outside change (a preset, a
        // restored draft) is written, so the caret never jumps while typing. The coordinator remembers the text
        // the field and the model last agreed on: while the model still holds it, there is nothing to compare
        // with the field, which would read the whole text again on every redraw.
        let coordinator = context.coordinator
        if text != coordinator.synced, !textView.hasMarkedText() {
            coordinator.synced = text
            if textView.string != text {
                textView.string = text
                coordinator.measure()
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NewSessionTextView
        weak var textView: ComposerTextView?
        /// The text the field and the model last agreed on.
        var synced = ""

        init(_ parent: NewSessionTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // The field's text is read once; the model ignores a value it already holds.
            let value = textView.string
            synced = value
            parent.text = value
            measure()
        }

        func textDidEndEditing(_ notification: Notification) { parent.onBlur() }

        /// The field's height follows its lines between the minimum and the maximum.
        func measure() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + NewSessionTextView.inset.height * 2
            let height = min(max(used, NewSessionTextView.minimumHeight), NewSessionTextView.maximumHeight)
            if abs(parent.height - height) > 0.5 { DispatchQueue.main.async { self.parent.height = height } }
        }
    }

    final class ComposerTextView: NSTextView {
        weak var coordinator: Coordinator?
        private static let returnKeys: Set<UInt16> = [36, 76]

        override var acceptsFirstResponder: Bool { isEditable }

        /// The draft opens with the caret in the text: the question is answered by typing.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, isEditable else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.firstResponder !== self else { return }
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            guard Self.returnKeys.contains(event.keyCode), !hasMarkedText() else { return super.keyDown(with: event) }
            let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
            switch modifiers {
            case []:
                if !event.isARepeat { coordinator?.parent.onSend() }
            case [.command]:
                if !event.isARepeat { coordinator?.parent.onSendAndOpenFresh() }
            case [.shift], [.option]:
                insertNewlineIgnoringFieldEditor(nil)
            default:
                super.keyDown(with: event)
            }
        }

        /// Tab leaves the field like it does in any other text field.
        override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
        override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    }
}
