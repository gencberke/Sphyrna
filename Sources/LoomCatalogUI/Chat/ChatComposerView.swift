import AppKit
import LoomChat
import LoomCore
import SwiftUI

/// The composer of a live Chat session (V17, D-58): the card with its queue strip, attachments, text, notices and the bar.
/// The menus open above it. `ChatComposerDock` puts it at the bottom of the live view.
struct ChatComposerView: View {
    let model: ChatComposerModel
    @State private var height = LoomTheme.Composer.minimumTextHeight

    var body: some View {
        VStack(spacing: 0) {
            ComposerQueueStrip(model: model)
            ComposerAttachmentsRow(model: model)
            if let hint = model.cardNoteHint {
                // The text field below is the card's note: said once, above the field (CHAT-SPEC → Requests).
                HStack(spacing: LoomTheme.Space.headerSpacing) {
                    Image(systemName: "arrow.turn.up.left").font(LoomTheme.Composer.cardNoteIcon)
                        .accessibilityHidden(true)
                    Text(hint).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(LoomTheme.Composer.cardNoteFont).foregroundStyle(LoomTheme.Composer.cardNoteColor)
                .padding(.horizontal, LoomTheme.Composer.textInsetH).padding(.top, LoomTheme.Composer.cardNoteTop)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("composer-card-note")
            }
            ZStack(alignment: .topLeading) {
                if model.textIsEmpty {
                    Text(Self.placeholder(model))
                        .font(LoomTheme.TypeScale.reading).foregroundStyle(LoomTheme.Text.tertiary)
                        .padding(.top, ComposerTextEditor.inset.height).allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerTextEditor(host: model, height: $height, accessibilityIdentifier: "composer-text",
                                   accessibilityLabel: "Message for Claude")
                    .frame(height: height)
            }
            .padding(.horizontal, LoomTheme.Composer.textInsetH).padding(.top, LoomTheme.Composer.textTop)
            if let notice = model.notice {
                Text(notice.text).font(LoomTheme.Composer.noticeFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LoomTheme.Composer.noticeInset).padding(.bottom, LoomTheme.Space.headerSpacing)
                    .accessibilityIdentifier("composer-notice")
            }
            LiveComposerBar(model: model)
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Composer.radius).fill(LoomTheme.Composer.fill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Composer.radius)
            .strokeBorder(LoomTheme.Composer.stroke, lineWidth: LoomTheme.Line.hairline))
        .overlay(alignment: .top) {
            // A zero-height strip on the card's top edge; the panel's bottom sits on it, so the panel opens upwards.
            if let menu = model.menu {
                Color.clear.frame(height: 0)
                    .overlay(alignment: .bottom) {
                        ComposerMenuPanel(model: model, menu: menu).offset(y: -LoomTheme.Composer.menuGap)
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-card")
        .task { model.start() }
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
        VStack(spacing: LoomTheme.Space.headerSpacing + 2) {
            ChatComposerView(model: model)
            ComposerHints(model: model)
        }
        .frame(maxWidth: LoomTheme.Composer.column)
        .padding(.horizontal, LoomTheme.Composer.dockSideInset)
        .padding(.top, LoomTheme.Composer.dockTopInset).padding(.bottom, LoomTheme.Composer.dockBottomInset)
        .frame(maxWidth: .infinity)
    }
}

/// "↵ send now · ⌘↵ after this turn · …": what the keys do in the state the composer is in.
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
        HStack(spacing: LoomTheme.Space.requestPadding + 2) {
            ForEach(hints, id: \.self) { Text($0) }
            Spacer(minLength: 0)
        }
        .font(LoomTheme.Composer.hintFont).foregroundStyle(LoomTheme.Text.tertiary).lineLimit(1).fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, LoomTheme.Space.headerSpacing)
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

/// Thumbnails and chips above the text, each with a remove button.
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
            .padding(.horizontal, LoomTheme.Space.requestPadding + 2).padding(.top, LoomTheme.Space.requestPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("composer-attachments")
        }
    }

    private func chip(_ attachment: ComposerAttachment) -> some View {
        HStack(spacing: LoomTheme.Composer.attachmentSpacing) {
            if let picture = attachment.thumbnail {
                Image(nsImage: picture).resizable().scaledToFill()
                    .frame(width: LoomTheme.Composer.thumbnail.width, height: LoomTheme.Composer.thumbnail.height)
                    .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm - 2))
            } else {
                Image(systemName: attachment.isImage ? "photo" : "doc.plaintext").font(LoomTheme.Typography.small)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            Text(attachment.label).font(LoomTheme.Composer.attachmentFont).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: LoomTheme.Composer.attachmentMaxLabelWidth, alignment: .leading)
            Button { model.removeAttachment(attachment.id) } label: {
                Image(systemName: "xmark").font(LoomTheme.Typography.chevron).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(width: LoomTheme.Composer.queueIcon, height: LoomTheme.Composer.queueIcon).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Remove \(attachment.label)")
        }
        .foregroundStyle(LoomTheme.Text.primary)
        .padding(.leading, LoomTheme.Space.headerSpacing).padding(.trailing, LoomTheme.Space.headerSpacing)
        .frame(height: LoomTheme.Composer.attachmentHeight)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Composer.attachmentRadius).fill(LoomTheme.Composer.attachmentFill))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer-attachment")
    }
}

// MARK: Bar

/// The live composer's bar: +, the mode, then the ring, the model with its effort, and Send.
struct LiveComposerBar: View {
    let model: ChatComposerModel
    @State private var commandHeld = false

    var body: some View {
        let state = model.state
        ComposerBarFrame {
            plusMenu
            modeMenu(state)
        } trailing: {
            ComposerRing(usage: ComposerBarText.contextUsage(state, fallback: model.environment.contextFallback()),
                         canCompact: state.phase == .ready && !state.turnRunning && state.requestCount == 0,
                         onCompact: { model.compactNow() }, showsPopover: Bindable(model).ringPopoverOpen)
            modelMenu(state)
            sendButton
        }
        .onModifierKeysChanged(mask: .command, initial: true) { _, new in commandHeld = new.contains(.command) }
    }

    private var plusMenu: some View {
        Menu {
            Button { model.pickFiles(in: NSApp.keyWindow) } label: { Label("Add images and files\u{2026}", systemImage: "paperclip") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button { model.openMenu(.mention) } label: { Label("Mention a file or session (@)", systemImage: "at") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button { model.openMenu(.commands) } label: { Label("Commands and skills (/)", systemImage: "slash.circle") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        } label: {
            Image(systemName: "plus").font(LoomTheme.Composer.plusIcon).foregroundStyle(LoomTheme.Text.primary)
                .frame(width: LoomTheme.Composer.controlSide, height: LoomTheme.Composer.controlSide).contentShape(Rectangle())
        }
        .composerMenuStyle()
        .help("Add images and files, mention a file or session, or run a command")
        .accessibilityLabel("Add")
        .accessibilityIdentifier("composer-plus")
    }

    private func modeMenu(_ state: ChatComposerState) -> some View {
        let current = ComposerBarText.selectedMode(permissionMode: state.permissionMode, choices: state.choices)
        let title = ComposerBarText.modeTitle(permissionMode: state.permissionMode, choices: state.choices)
        return Menu {
            ForEach(ClaudePermissionMode.allCases, id: \.self) { mode in
                Button { model.setMode(mode.rawValue) } label: {
                    if current == mode.rawValue { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                }
            }
        } label: {
            // Every mode looks the same: no warning colour or mark, Full access included (D-58).
            ComposerChipLabel(symbol: "shield", title: title)
        }
        .composerMenuStyle()
        .help("Permission mode of this session. It changes at once.")
        .accessibilityLabel("Permission mode, \(title)")
        .accessibilityIdentifier("composer-mode")
    }

    private func modelMenu(_ state: ChatComposerState) -> some View {
        let title = ComposerBarText.modelTitle(state)
        let effort = ComposerBarText.effortTitle(state)
        let chosenModel = state.choices.model
        let chosenEffort = state.choices.effort ?? state.reportedEffort
        return Menu {
            Section("Model") {
                ForEach(ComposerBarText.modelChoices(state), id: \.value) { choice in
                    Button { model.setModel(choice.value) } label: {
                        if chosenModel == choice.value { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                    }
                }
            }
            Section("Effort") {
                ForEach(ComposerBarText.effortLevels(state), id: \.self) { level in
                    Button { model.setEffort(level) } label: {
                        let name = ComposerBarText.effortLabel(level)
                        if chosenEffort == level { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
        } label: {
            ComposerChipLabel(symbol: nil, title: title, lighter: effort, titleColor: LoomTheme.Composer.modelColor)
        }
        .composerMenuStyle()
        .help("Model and effort of this session. They change at once.")
        .accessibilityLabel("Model, \(title)" + (effort.map { ", effort \($0)" } ?? ""))
        .accessibilityIdentifier("composer-model")
    }

    private var sendButton: some View {
        let kind = model.sendKind(commandHeld: commandHeld)
        let (look, label, help): (ComposerSendLook, String, String) = switch kind {
        case .sendDisabled: (.disabled, "Send", model.cardShown ? "Answer the request above first. Your text goes with the answer"
            : "Nothing to send yet")
        case .send: (.send, "Send", "Send (\u{21B5})")
        case .sendNow: (.send, "Send now", "Send now (\u{21B5}): Claude reads it after the current step. \u{2318}\u{21B5} sends it after this turn")
        case .afterTurn: (.afterTurn, "After this turn", "Send after this turn (\u{2318}\u{21B5})")
        case .update: (.update, "Update", "Update the queued message (\u{21B5})")
        case .interrupt: (.stop, "Interrupt", model.state.requestCount > 0 ? "Interrupt Claude. Your text stays here"
            : "Interrupt Claude (esc). Your text stays here")
        case .resume: (.resume, "Resume the queue", "Send the next queued message")
        }
        return ComposerSendButton(look: look, label: label, help: help, identifier: "composer-send") { held in
            model.performSendButton(commandHeld: held)
        }
    }
}
