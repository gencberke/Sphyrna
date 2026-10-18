import AppKit
import SwiftUI

/// What the text view needs from the composer that owns it: the key state, what to do for a key, where its text goes.
/// The live composer (`ChatComposerModel`) and the new-session draft's composer (`DraftComposerHost`) both adopt it, so one
/// text view serves both (D-59).
@MainActor
protocol ComposerEditorHost: AnyObject {
    var keyMode: ComposerKeys.Mode { get }
    /// True: the field reads `modelText` only when `textRevision` changed (the model sets the text itself now and then).
    /// False: the field compares `modelText` with what it holds on every update (the draft keeps its text elsewhere).
    var syncsByRevision: Bool { get }
    var textRevision: Int { get }
    var modelText: String { get }
    func keyState(isRepeat: Bool, hasMarkedText: Bool, bridge: any ComposerEditorBridge) -> ComposerKeys.State
    /// Obeys a key's meaning; false when the text view should handle the key itself.
    func perform(_ action: ComposerKeys.Action, bridge: any ComposerEditorBridge, in window: NSWindow?) -> Bool
    func textChanged(_ text: String)
    func editorEndedEditing()
    /// The text view gained or lost the keyboard.
    func editorFocusChanged(_ focused: Bool)
    func paste(_ pasteboard: NSPasteboard, plain: Bool) -> Bool
    func drop(_ pasteboard: NSPasteboard) -> Bool
    /// The text view came or went (the model drives it through the bridge while it is there).
    func editorAttached(_ bridge: (any ComposerEditorBridge)?)
    /// This text view went. Only the editor the host holds is let go: a newer one that took its place stays.
    func editorDetached(_ bridge: any ComposerEditorBridge)
}

extension ComposerEditorHost {
    func editorDetached(_ bridge: any ComposerEditorBridge) { editorAttached(nil) }

    /// Only the live composer cares (its cards' typing guard); the draft's does not.
    func editorFocusChanged(_ focused: Bool) {}
}

/// The text field of a composer: plain text that grows with its lines, with the composer's keys (CHAT-SPEC → Composer →
/// Keys). Keys are matched by key code (`ComposerKeys`), so none depends on the keyboard layout; a key never sends while an
/// input method composes (`hasMarkedText`), and a held key never sends twice.
struct ComposerTextEditor: NSViewRepresentable {
    let host: any ComposerEditorHost
    @Binding var height: CGFloat
    var isEditable = true
    var minimumHeight: CGFloat = LoomTheme.Composer.minimumTextHeight
    var maximumHeight: CGFloat = LoomTheme.Composer.maximumTextHeight
    var accessibilityIdentifier = "composer-text"
    var accessibilityLabel = "Message"
    /// Takes the caret when the field first appears.
    var takesFocus = true

    static let inset = NSSize(width: 0, height: 4)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: LoomTheme.TypeScale.readingSize)
        textView.textColor = LoomTheme.Text.primaryPair.nsColor
        textView.insertionPointColor = LoomTheme.Text.primaryPair.nsColor
        textView.textContainerInset = Self.inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.takesFocusOnAppearing = takesFocus
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        let initial = host.modelText
        textView.string = initial
        context.coordinator.synced = initial
        context.coordinator.revision = host.textRevision
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.textView = textView
        DispatchQueue.main.async {
            context.coordinator.measure()
            context.coordinator.parent.host.editorAttached(textView)
        }
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let textView = coordinator.textView { coordinator.parent.host.editorDetached(textView) }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerTextView else { return }
        textView.isEditable = isEditable
        // A new size range (the composer went compact for a card, or back) is measured at once.
        let range = [minimumHeight, maximumHeight]
        if coordinator.measuredRange != range {
            coordinator.measuredRange = range
            coordinator.measure()
        }
        // A change that came from the field is in the field already; only an outside change (a recall, a returned draft, a
        // preset, a restored draft) is written, so the caret never jumps while typing.
        guard !textView.hasMarkedText() else { return }
        if host.syncsByRevision {
            let revision = host.textRevision
            guard revision != coordinator.revision else { return }
            coordinator.revision = revision
            let value = host.modelText
            coordinator.synced = value
            if textView.string != value { textView.setPlainText(value) }
            coordinator.measure()
        } else {
            let value = host.modelText
            guard value != coordinator.synced else { return }
            coordinator.synced = value
            if textView.string != value { textView.setPlainText(value) }
            coordinator.measure()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        weak var textView: ComposerTextView?
        /// The text the field and the composer last agreed on.
        var synced = ""
        var revision = 0
        /// The minimum and maximum height the field was last measured for.
        var measuredRange: [CGFloat] = []

        init(_ parent: ComposerTextEditor) { self.parent = parent }

        var host: any ComposerEditorHost { parent.host }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // The field's text is read once.
            let value = textView.string
            synced = value
            parent.host.textChanged(value)
            measure()
        }

        func textDidEndEditing(_ notification: Notification) { parent.host.editorEndedEditing() }

        /// The field's height follows its lines between the minimum and the maximum.
        func measure() {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + ComposerTextEditor.inset.height * 2
            let height = min(max(used, parent.minimumHeight), parent.maximumHeight)
            if abs(parent.height - height) > 0.5 { DispatchQueue.main.async { self.parent.height = height } }
        }
    }

    final class ComposerTextView: NSTextView, ComposerEditorBridge {
        weak var coordinator: Coordinator?
        var takesFocusOnAppearing = true

        override var acceptsFirstResponder: Bool { isEditable }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { coordinator?.host.editorFocusChanged(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { coordinator?.host.editorFocusChanged(false) }
            return resigned
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, isEditable, takesFocusOnAppearing else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.firstResponder !== self else { return }
                // Not over another field the user is in.
                if let responder = window.firstResponder as? NSTextView, responder !== self, responder.isEditable { return }
                window.makeFirstResponder(self)
            }
        }

        // MARK: Keys

        override func keyDown(with event: NSEvent) {
            guard !handle(event) else { return }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(ComposerKeys.relevantModifiers)
            // ⌘⇧ shortcuts and ⌘↵ come here first; every other key equivalent is the menu's.
            guard modifiers.contains(.command), window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            let shortcut: Set<UInt16> = [ComposerKeys.letterV, ComposerKeys.letterA, ComposerKeys.letterM, ComposerKeys.letterK]
            guard modifiers == [.command, .shift], shortcut.contains(event.keyCode) else {
                return super.performKeyEquivalent(with: event)
            }
            return handle(event) || super.performKeyEquivalent(with: event)
        }

        /// Asks the composer what the key means and does it; false when the field handles the key.
        private func handle(_ event: NSEvent) -> Bool {
            guard let host = coordinator?.host, event.type == .keyDown else { return false }
            let state = host.keyState(isRepeat: event.isARepeat, hasMarkedText: hasMarkedText(), bridge: self)
            let action = ComposerKeys.resolve(keyCode: event.keyCode, modifiers: event.modifierFlags, state: state)
            switch action {
            case .passThrough: return false
            case .newline:
                insertNewlineIgnoringFieldEditor(nil)
                return true
            default:
                return host.perform(action, bridge: self, in: window)
            }
        }

        /// Tab leaves the field like it does in any other text field.
        override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
        override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

        // MARK: Paste and drop

        override func paste(_ sender: Any?) {
            if coordinator?.host.paste(.general, plain: false) == true { return }
            pasteAsPlainText(sender)
        }

        private func carriesAttachments(_ pasteboard: NSPasteboard) -> Bool {
            ComposerPasteboard.items(from: pasteboard).contains {
                if case .text = $0 { false } else { true }
            }
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            carriesAttachments(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            carriesAttachments(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            if carriesAttachments(sender.draggingPasteboard), coordinator?.host.drop(sender.draggingPasteboard) == true {
                return true
            }
            return super.performDragOperation(sender)
        }

        // MARK: ComposerEditorBridge

        var caretLocation: Int { selectedRange().location }
        var hasSelection: Bool { selectedRange().length > 0 }
        var utf16Length: Int { textStorage?.length ?? 0 }

        func currentText() -> String { string }

        func replaceAll(with text: String) {
            // Text the model sets (a recall, a returned draft) never lands in the middle of an input method's composition.
            if hasMarkedText() { unmarkText() }
            setPlainText(text)
            setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator?.synced = text
            coordinator?.measure()
        }

        func setPlainText(_ text: String) {
            string = text
            // Earlier undo steps point into text that is gone.
            undoManager?.removeAllActions()
        }

        func substring(_ range: NSRange) -> String {
            guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return "" }
            return storage.mutableString.substring(with: range)
        }

        func replace(_ range: NSRange, with text: String) {
            guard NSMaxRange(range) <= utf16Length, shouldChangeText(in: range, replacementString: text) else { return }
            // The text carries the typing attributes (a plain string would take the storage's default: small and black).
            textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
            setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
            didChangeText()
        }

        func insertAtCaret(_ text: String) {
            replace(selectedRange(), with: text)
        }

        func caretLines() -> (first: Bool, last: Bool) {
            guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else {
                return (true, true)
            }
            let caret = min(selectedRange().location, storage.length)
            layout.ensureLayout(for: container)
            let glyphCount = layout.numberOfGlyphs
            guard glyphCount > 0 else { return (true, true) }
            func top(ofGlyph glyph: Int) -> CGFloat { layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY }
            let endsWithNewline = storage.mutableString.character(at: storage.length - 1) == 0x0A
            if caret == storage.length, endsWithNewline { return (false, true) }
            let glyph = layout.glyphIndexForCharacter(at: min(caret, storage.length - 1))
            let line = top(ofGlyph: glyph)
            // A trailing newline leaves one more (empty) line below the last glyph's.
            return (line == top(ofGlyph: 0), line == top(ofGlyph: glyphCount - 1) && !endsWithNewline)
        }

        func focus() {
            window?.makeFirstResponder(self)
        }

        func typeIn(_ event: NSEvent) {
            focus()
            keyDown(with: event)
        }
    }
}
