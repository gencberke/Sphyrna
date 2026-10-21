import AppKit
import LoomChat
import LoomCore
import SwiftUI

/// The composer of a live Chat session (V17, D-58; Ink, DESIGN §11): the card on raised 2 with its ring and shadow, the queue
/// strip tucked behind its top edge, the attachments, the text, notices and the bar. The menus open above it.
/// `ChatComposerDock` puts it at the bottom of the live view.
struct ChatComposerView: View {
    let model: ChatComposerModel
    @State private var height = LoomTheme.Composer.minimumTextHeight

    var body: some View {
        // While a card waits above, the composer is one line and a bar, so the card's buttons stay on screen in a short window.
        let compact = model.cardShown
        VStack(spacing: 0) {
            if let hint = model.cardNoteHint {
                // The text field below is the card's note: said once, above the card (CHAT-SPEC → Requests).
                HStack(spacing: LoomTheme.Composer.cardNoteGap) {
                    Image(systemName: "arrow.turn.up.left").font(LoomTheme.Composer.cardNoteIcon).accessibilityHidden(true)
                    Text(hint).lineLimit(compact ? 1 : 2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(LoomTheme.Composer.cardNoteFont).foregroundStyle(LoomTheme.Composer.cardNoteColor)
                .padding(.leading, LoomTheme.Composer.hintInset).padding(.bottom, LoomTheme.Composer.cardNoteBottom)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("composer-card-note")
            }
            // The strip draws first and the card over it, so the strip's foot is behind the card.
            ComposerQueueStrip(model: model)
            card(compact: compact)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-card")
        .task { model.start() }
    }

    private func card(compact: Bool) -> some View {
        VStack(spacing: 0) {
            ComposerAttachmentsRow(model: model)
            ZStack(alignment: .topLeading) {
                if model.textIsEmpty {
                    Text(Self.placeholder(model))
                        .font(LoomTheme.TypeScale.reading).foregroundStyle(LoomTheme.Text.faint)
                        .padding(.top, ComposerTextEditor.inset.height).allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerTextEditor(host: model, height: $height,
                                   minimumHeight: compact ? LoomTheme.Composer.compactTextHeight : LoomTheme.Composer.minimumTextHeight,
                                   maximumHeight: compact ? LoomTheme.Composer.compactMaximumTextHeight : LoomTheme.Composer.maximumTextHeight,
                                   accessibilityIdentifier: "composer-text", accessibilityLabel: "Message for Claude")
                    .frame(height: height)
            }
            .padding(.horizontal, LoomTheme.Composer.textInsetH)
            .padding(.top, model.attachments.isEmpty && model.preparing == 0
                     ? (compact ? LoomTheme.Composer.compactTextTop : LoomTheme.Composer.textTop) : LoomTheme.Composer.attachmentBottom)
            if let moving = model.handoverPending {
                Text(moving).font(LoomTheme.Composer.noticeFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .padding(.horizontal, LoomTheme.Composer.noticeInset).padding(.bottom, LoomTheme.Space.headerSpacing)
                    .accessibilityIdentifier("composer-handover")
            }
            if let notice = model.notice {
                Text(notice.text).font(LoomTheme.Composer.noticeFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LoomTheme.Composer.noticeInset).padding(.bottom, LoomTheme.Space.headerSpacing)
                    .accessibilityIdentifier("composer-notice")
            }
            LiveComposerBar(model: model)
        }
        .composerCard()
        .overlay(alignment: .top) {
            // A zero-height strip on the card's top edge; the panel's bottom sits on it, so the panel opens upwards.
            if let menu = model.menu {
                Color.clear.frame(height: 0)
                    .overlay(alignment: .bottomLeading) {
                        ComposerMenuPanel(model: model, menu: menu).offset(y: -LoomTheme.Composer.menuGap)
                    }
            }
        }
        .zIndex(1)
    }

    static func placeholder(_ model: ChatComposerModel) -> String {
        if let card = model.cardPlaceholder { return card }
        if model.editing != nil { return "Edit the queued message" }
        if model.state.turnRunning { return "Message Claude; it reads it after the current step" }
        return "Message Claude, or / for commands, @ for files"
    }
}

/// The dock at the bottom of the live view: the composer in the reading column, and under it the keys that apply now.
struct ChatComposerDock: View {
    let model: ChatComposerModel

    var body: some View {
        let compact = model.cardShown
        VStack(spacing: LoomTheme.Composer.hintTop) {
            ChatComposerView(model: model)
            // The keys are on the card then (its own hint line), so the dock's line goes with the room it takes.
            if !compact { ComposerHints(model: model) }
        }
        .frame(maxWidth: LoomTheme.Composer.column)
        .padding(.horizontal, LoomTheme.Composer.dockSideInset)
        .padding(.top, compact ? LoomTheme.Composer.compactDockTopInset : LoomTheme.Composer.dockTopInset)
        .padding(.bottom, compact ? LoomTheme.Composer.compactDockBottomInset : LoomTheme.Composer.dockBottomInset)
        .frame(maxWidth: .infinity)
    }
}

/// The keys under the card: what each key does in the state the composer is in. Mono, tertiary, the key in secondary, 16
/// apart and 16 in from the card's edge; a narrow window keeps the first three.
struct ComposerHints: View {
    let model: ChatComposerModel

    var body: some View {
        let hints = ComposerBarText.hints(model.state, editing: model.editing != nil, cardShown: model.cardShown)
        ViewThatFits(in: .horizontal) {
            line(hints)
            line(Array(hints.prefix(3)))
        }
        .accessibilityHidden(true)
    }

    private func line(_ hints: [String]) -> some View {
        HStack(spacing: LoomTheme.Composer.hintGap) {
            ForEach(hints, id: \.self) { hint in
                let (key, words) = Self.split(hint)
                HStack(spacing: LoomTheme.Composer.hintKeyGap) {
                    Text(key).foregroundStyle(LoomTheme.Text.secondaryStyle).fontWeight(.medium)
                    if !words.isEmpty { Text(words) }
                }
            }
            Spacer(minLength: 0)
        }
        .font(LoomTheme.Composer.hintFont).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1).fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, LoomTheme.Composer.hintInset)
    }

    /// A hint is its key and then its words: "\u{21B5} send" is `↵` and `send`.
    static func split(_ hint: String) -> (key: String, words: String) {
        guard let space = hint.firstIndex(of: " ") else { return (hint, "") }
        return (String(hint[..<space]), String(hint[hint.index(after: space)...]))
    }
}

extension ComposerBarText {
    /// The keys that apply now, shortest first (the narrow view keeps the first three).
    static func hints(_ state: ChatComposerState, editing: Bool, cardShown: Bool = false) -> [String] {
        // A card is shown: ↵ and esc do not answer it; tab goes to it.
        if cardShown { return ["tab to the request", "\u{21B5} and esc do not answer it", "your text goes with the answer"] }
        if editing { return ["\u{21B5} update", "esc cancel the edit", "\u{21E7}\u{21B5} new line"] }
        if state.turnRunning {
            // A request waiting: Esc does nothing then, so the hint does not offer it.
            let escape = state.requestCount > 0 ? [] : ["esc interrupt"]
            return ["\u{21B5} send now", "\u{2318}\u{21B5} after this turn"] + escape + ["@ files and sessions",
                    "/ commands and skills"]
        }
        return ["\u{21B5} send", "\u{21E7}\u{21B5} new line", "@ files and sessions", "/ commands and skills",
                "\u{2191} earlier messages"]
    }
}

// MARK: Attachments

/// Thumbnails and chips above the text (56 × 42 thumbnails with a × badge, 42 high file chips), 16 in from the card's edge.
struct ComposerAttachmentsRow: View {
    let model: ChatComposerModel

    var body: some View {
        if !model.attachments.isEmpty || model.preparing > 0 {
            FlowLayout(spacing: LoomTheme.Composer.attachmentSpacing, centered: false) {
                ForEach(model.attachments) { attachment in chip(attachment) }
                if model.preparing > 0 {
                    ProgressView().controlSize(.small).frame(width: LoomTheme.Composer.attachmentHeight,
                                                              height: LoomTheme.Composer.attachmentHeight)
                }
            }
            .padding(.horizontal, LoomTheme.Composer.textInsetH).padding(.top, LoomTheme.Composer.textTop)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer-attachments")
        }
    }

    @ViewBuilder private func chip(_ attachment: ComposerAttachment) -> some View {
        if let picture = attachment.thumbnail {
            thumbnail(attachment, picture: picture)
        } else {
            fileChip(attachment)
        }
    }

    private func thumbnail(_ attachment: ComposerAttachment, picture: NSImage) -> some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Composer.attachmentRadius)
        return Image(nsImage: picture).resizable().scaledToFill()
            .frame(width: LoomTheme.Composer.thumbnail.width, height: LoomTheme.Composer.thumbnail.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
            .overlay(alignment: .topTrailing) {
                Button { model.removeAttachment(attachment.id) } label: {
                    Image(systemName: "xmark").font(LoomTheme.Composer.badgeGlyph).foregroundStyle(LoomTheme.Composer.badgeGlyphColor)
                        .frame(width: LoomTheme.Composer.badgeSide, height: LoomTheme.Composer.badgeSide)
                        .background(Circle().fill(LoomTheme.Composer.badgeFill))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).padding(LoomTheme.Composer.badgeInset)
                .accessibilityLabel("Remove \(attachment.label)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(attachment.label)
            .accessibilityIdentifier("composer-attachment")
    }

    private func fileChip(_ attachment: ComposerAttachment) -> some View {
        HStack(spacing: LoomTheme.Composer.attachmentSpacing) {
            Image(systemName: attachment.isImage ? "photo" : "doc.plaintext").font(LoomTheme.Composer.attachmentIcon)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle)
            Text(attachment.title).font(LoomTheme.Composer.attachmentFont).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: LoomTheme.Composer.attachmentMaxLabelWidth, alignment: .leading)
            if let detail = attachment.detail {
                Text(detail).font(LoomTheme.Composer.attachmentSizeFont).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
            Button { model.removeAttachment(attachment.id) } label: {
                Image(systemName: "xmark").font(LoomTheme.Typography.chevron).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(width: LoomTheme.Composer.queueIcon, height: LoomTheme.Composer.queueIcon).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Remove \(attachment.label)")
        }
        .foregroundStyle(LoomTheme.Text.primary)
        .padding(.leading, LoomTheme.Composer.attachmentPaddingLeading).padding(.trailing, LoomTheme.Composer.attachmentPaddingTrailing)
        .frame(height: LoomTheme.Composer.attachmentHeight)
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Composer.attachmentRadius)
            .strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer-attachment")
    }
}

// MARK: Bar

/// The live composer's bar: +, the mode, then the ring, the one model chip and Send (the pickers are `ComposerPickers` and
/// `ComposerModelPopover`).
struct LiveComposerBar: View {
    let model: ChatComposerModel
    @State private var commandHeld = false
    @State private var plusOpen = false

    var body: some View {
        let state = model.state
        ComposerBarFrame {
            plusChip
            modeChip(state)
        } trailing: {
            ComposerRing(usage: ComposerBarText.contextUsage(state, fallback: model.environment.contextFallback()),
                         canCompact: state.phase == .ready && !state.turnRunning && state.requestCount == 0,
                         onCompact: { model.compactNow() }, showsPopover: Bindable(model).ringPopoverOpen)
            modelChip(state)
            sendButton
        }
        .background(shortcuts)
        .onModifierKeysChanged(mask: .command, initial: true) { _, new in commandHeld = new.contains(.command) }
    }

    private var plusChip: some View {
        ComposerPlusChip(isOpen: $plusOpen) { choose($0) }
    }

    private func choose(_ item: ComposerPlusItem) {
        switch item {
        case .attach: model.pickFiles(in: NSApp.keyWindow)
        case .mention: model.openMenu(.mention)
        case .commands: model.openMenu(.commands)
        }
    }

    /// ⇧⌘A, ⇧⌘M and ⇧⌘K work wherever the focus is in this window, as they did from the + menu's items.
    private var shortcuts: some View {
        Group {
            Button("Add images and files") { choose(.attach) }.keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Mention a file or session") { choose(.mention) }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Commands and skills") { choose(.commands) }.keyboardShortcut("k", modifiers: [.command, .shift])
        }
        .focusable(false).opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    private func modeChip(_ state: ChatComposerState) -> some View {
        ComposerModeChip(
            selected: ComposerBarText.selectedMode(permissionMode: state.permissionMode, choices: state.choices),
            title: ComposerBarText.modeTitle(permissionMode: state.permissionMode, choices: state.choices),
            help: "Permission mode of this session. It changes at once.", identifier: "composer-mode", reset: nil,
            isOpen: Bindable(model).modePopoverOpen) { mode in model.setMode(mode.rawValue) }
    }

    private func modelChip(_ state: ChatComposerState) -> some View {
        ComposerModelChip(
            picker: model.modelPicker, identifier: "composer-model",
            help: "Model and effort of this session. They change at once.",
            isOpen: Bindable(model).modelPopoverOpen,
            onPickModel: { model.setModel($0 ?? ComposerModelChip.defaultID) }, onPickEffort: { model.setEffort($0) },
            onResetEffort: { model.resetEffort() })
    }

    private var sendButton: some View {
        let kind = model.sendKind(commandHeld: commandHeld)
        let help: String = switch kind {
        case .sendDisabled: model.handoverPending != nil ? "Moving to the terminal. Your text stays here"
            : model.cardShown ? "Answer the request above first. Your text goes with the answer"
            : "Nothing to send yet"
        case .send: "Send (\u{21B5})"
        case .sendNow: "Send now (\u{21B5}): Claude reads it after the current step. \u{2318}\u{21B5} sends it after this turn"
        case .afterTurn: "Send after this turn (\u{2318}\u{21B5})"
        case .update: "Update the queued message (\u{21B5})"
        case .interrupt: model.state.requestCount > 0 ? "Interrupt Claude. Your text stays here" : "Interrupt Claude (esc). Your text stays here"
        case .resume: "Send the next queued message"
        }
        return ComposerSendButton(look: kind.look, label: kind.label, help: help, identifier: "composer-send") { held in
            model.performSendButton(commandHeld: held)
        }
    }
}
