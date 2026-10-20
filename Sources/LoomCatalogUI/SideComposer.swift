import AppKit
import SwiftUI

/// The Side tab's field as the text view's host (`ComposerEditorHost`): ↵ asks, ⇧↵ makes a new line, Esc does nothing (the
/// session's composer is elsewhere, and an Esc here must not close or interrupt anything). The text lives in the session's
/// holder (`SideSession.composerText`), so the field follows it: cleared after a question, given back after a refusal.
@MainActor
final class SideComposerEditorHost: ComposerEditorHost {
    private let model: CatalogModel
    private let parent: UUID
    private weak var bridge: (any ComposerEditorBridge)?

    init(model: CatalogModel, parent: UUID) {
        self.model = model
        self.parent = parent
    }

    var keyMode: ComposerKeys.Mode { .quick }
    var syncsByRevision: Bool { false }
    var textRevision: Int { 0 }
    var modelText: String { model.side.existing(for: parent)?.composerText ?? "" }

    func keyState(isRepeat: Bool, hasMarkedText: Bool, bridge: any ComposerEditorBridge) -> ComposerKeys.State {
        var state = ComposerKeys.State()
        state.mode = .quick
        state.hasMarkedText = hasMarkedText
        state.isRepeat = isRepeat
        return state
    }

    func perform(_ action: ComposerKeys.Action, bridge: any ComposerEditorBridge, in window: NSWindow?) -> Bool {
        switch action {
        case .send, .sendSecondary: submit()
        case .pastePlain:
            guard let text = NSPasteboard.general.string(forType: .string) else { return true }
            bridge.insertAtCaret(text)
        case .closePanel, .ignore: break
        default: return false
        }
        return true
    }

    func submit() {
        Task { [model, parent] in await model.submitSideQuestion(in: parent) }
    }

    func textChanged(_ text: String) {
        guard let session = model.side.existing(for: parent), session.composerText != text else { return }
        session.composerText = text
        if session.notice != nil { session.notice = nil }
    }

    func editorEndedEditing() {}
    func paste(_ pasteboard: NSPasteboard, plain: Bool) -> Bool { false }
    func drop(_ pasteboard: NSPasteboard) -> Bool { false }
    func editorAttached(_ bridge: (any ComposerEditorBridge)?) { self.bridge = bridge }
}

/// The compact composer: the field ("Ask on the side"), one quiet line for what went wrong, and a bar with Close, the
/// session's model (read only), "Allow edits", "…" and Send. There are no slash commands and no `@` menu here.
struct SideComposerView: View {
    let model: CatalogModel
    let row: SessionRowModel
    let session: SideSession
    @State private var host: SideComposerEditorHost
    @State private var height = LoomTheme.Side.composerMinimumTextHeight

    init(model: CatalogModel, row: SessionRowModel, session: SideSession) {
        self.model = model
        self.row = row
        self.session = session
        _host = State(initialValue: SideComposerEditorHost(model: model, parent: row.id))
    }

    /// Why the field takes no question, or nil.
    private var offReason: String? {
        if session.forkUnsupported { return SideText.forkUnsupported }
        if model.chatSessions == nil { return SideText.unavailable }
        return nil
    }

    private var isDiscarding: Bool { session.openID.map { session.discarding.contains($0) } ?? false }

    var body: some View {
        let off = offReason
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if session.composerText.isEmpty {
                    Text(SideText.placeholder).font(LoomTheme.TypeScale.reading).foregroundStyle(LoomTheme.Text.faint)
                        .padding(.top, ComposerTextEditor.inset.height).allowsHitTesting(false).accessibilityHidden(true)
                }
                ComposerTextEditor(host: host, height: $height, isEditable: off == nil && !isDiscarding,
                                   minimumHeight: LoomTheme.Side.composerMinimumTextHeight,
                                   maximumHeight: LoomTheme.Side.composerMaximumTextHeight,
                                   accessibilityIdentifier: "side-composer-text", accessibilityLabel: SideText.placeholder,
                                   takesFocus: false)
                    .frame(height: height)
            }
            .padding(.horizontal, LoomTheme.Side.composerTextInset).padding(.top, LoomTheme.Side.composerTextTop)
            if let line = off ?? session.notice {
                Text(line).font(LoomTheme.Side.noticeFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LoomTheme.Side.composerTextInset).padding(.bottom, LoomTheme.Side.noticeInsetBottom)
                    .accessibilityIdentifier("side-composer-notice")
            }
            SideComposerBar(model: model, row: row, session: session, sendOff: off != nil || isDiscarding) { host.submit() }
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Side.composerRadius).fill(LoomTheme.Composer.fill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Side.composerRadius)
            .strokeBorder(LoomTheme.Composer.stroke, lineWidth: LoomTheme.Line.hairline))
        .padding(LoomTheme.Side.composerInset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("side-composer")
    }
}

private struct SideComposerBar: View {
    let model: CatalogModel
    let row: SessionRowModel
    let session: SideSession
    let sendOff: Bool
    let send: () -> Void

    var body: some View {
        let open = session.openItem
        let live = session.live(for: open?.id)
        let canSend = !sendOff && !session.isBusy && !session.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: LoomTheme.Side.barGap) {
            if let open {
                Button(SideText.close) { Task { await model.closeSideChat(open.id, in: row.id) } }
                    .buttonStyle(.plain).font(LoomTheme.Side.barFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .disabled(live?.isRunning != true)
                    .opacity(live?.isRunning == true ? 1 : LoomTheme.Opacity.disabled)
                    .help("Stops the side chat. Its thread stays, and your next question resumes it.")
                    .accessibilityIdentifier("side-close")
            }
            Text(model.modelContent(of: row.record)?.name ?? "Model").font(LoomTheme.Side.barFont)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                .help(SideText.modelHelp).accessibilityLabel("Model, \(SideText.modelHelp)")
                .accessibilityIdentifier("side-model")
            if let open {
                Toggle(SideText.allowEdits, isOn: Binding(
                    get: { live?.allowsEdits ?? false },
                    set: { value in Task { await model.setSideAllowsEdits(value, chat: open.id, in: row.id) } }
                ))
                .toggleStyle(.checkbox).controlSize(.small).font(LoomTheme.Side.barFont)
                .foregroundStyle(LoomTheme.Text.secondaryStyle)
                // The permission is the running process's: a closed side chat starts again with edits off.
                .disabled(live?.isRunning != true)
                .help(SideText.allowEditsHelp).accessibilityHint(SideText.allowEditsHelp)
                .accessibilityIdentifier("side-allow-edits")
                Menu {
                    Button(SideText.discard, role: .destructive) { model.requestDiscardSideChat(open.id, in: row.id) }
                } label: {
                    Image(systemName: "ellipsis").font(LoomTheme.Side.barGlyph)
                        .frame(width: LoomTheme.Side.controlSide, height: LoomTheme.Side.controlSide)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More").accessibilityIdentifier("side-more")
            }
            Spacer(minLength: 0)
            ComposerSendButton(look: canSend ? .send : .disabled, label: "Ask on the side", help: "Ask on the side (↵)",
                               identifier: "side-send") { _ in send() }
        }
        .padding(.horizontal, LoomTheme.Side.barInset)
        .frame(height: LoomTheme.Side.barHeight)
    }
}
