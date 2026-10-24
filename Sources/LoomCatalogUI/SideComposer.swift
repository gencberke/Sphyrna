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

    /// Files and folders as `@path` and `@folder/`, relative to the parent session's folder. A side question is text only, so
    /// an image file is a path too.
    func drop(_ pasteboard: NSPasteboard) -> Bool {
        let record = model.rowModels[parent]?.record ?? model.liveRecords[parent]
        return ComposerPasteboard.dropMentions(from: pasteboard, relativeTo: record?.session.workingDirectory, into: bridge,
                                               text: modelText) { textChanged($0) }
    }
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
        .background(RoundedRectangle(cornerRadius: LoomTheme.Side.composerRadius).fill(LoomTheme.Side.composerFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Side.composerRadius)
            .strokeBorder(LoomTheme.Side.composerEdge, lineWidth: LoomTheme.Line.hairline))
        .padding(.horizontal, LoomTheme.Side.composerInsetH).padding(.bottom, LoomTheme.Side.composerInsetBottom)
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
                    .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                    .disabled(live?.isRunning != true)
                    .help("Stops the side chat. Its thread stays, and your next question resumes it.")
                    .accessibilityIdentifier("side-close")
            }
            HStack(spacing: LoomTheme.Side.switchGap) {
                ProviderIcon(provider: row.record.session.provider, size: LoomTheme.Side.barMarkSize)
                Text(model.modelContent(of: row.record)?.name ?? "Model").lineLimit(1)
            }
            .font(LoomTheme.Side.barFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .padding(.horizontal, LoomTheme.Side.barLabelPadding)
            .help(SideText.modelHelp).accessibilityElement(children: .combine)
            .accessibilityLabel("Model, \(SideText.modelHelp)")
            .accessibilityIdentifier("side-model")
            Spacer(minLength: 0)
            if let open {
                Toggle(SideText.allowEdits, isOn: Binding(
                    get: { live?.allowsEdits ?? false },
                    set: { value in Task { await model.setSideAllowsEdits(value, chat: open.id, in: row.id) } }
                ))
                .toggleStyle(ControlSwitchStyle())
                // The permission is the running process's: a closed side chat starts again with edits off.
                .disabled(live?.isRunning != true)
                .help(SideText.allowEditsHelp).accessibilityHint(SideText.allowEditsHelp)
                .accessibilityIdentifier("side-allow-edits")
                PinnedMoreMenu(busy: false, label: "More", side: LoomTheme.Side.controlSide) {
                    Button(SideText.discard, systemImage: "trash", role: .destructive) {
                        model.requestDiscardSideChat(open.id, in: row.id)
                    }
                }
                .accessibilityIdentifier("side-more")
            }
            ComposerSendButton(look: canSend ? .send : .disabled, label: "Ask on the side", help: "Ask on the side (↵)",
                               identifier: "side-send") { _ in send() }
        }
        .padding(.horizontal, LoomTheme.Side.barInset)
        .frame(height: LoomTheme.Side.barHeight)
    }
}

/// The control family's switch (DESIGN §6 Controls): 28 × 16, the stronger hairline as the track and the accent when on, a white
/// 12 pt knob. The label comes first, 6 before the track. Keyboard: Space, as for any button.
struct ControlSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: LoomTheme.Side.switchGap) {
                    configuration.label.font(LoomTheme.Side.barFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    track
                }
                .padding(.horizontal, LoomTheme.Side.barLabelPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
            .accessibilityValue(configuration.isOn ? "on" : "off")
            .accessibilityAddTraits(.isToggle)
        }

        private var track: some View {
            Capsule().fill(configuration.isOn ? LoomTheme.Side.switchOnFill : LoomTheme.Side.switchOffFill)
                .frame(width: LoomTheme.Side.switchWidth, height: LoomTheme.Side.switchHeight)
                .overlay(alignment: .leading) {
                    Circle().fill(LoomTheme.Side.switchKnobFill)
                        .shadow(color: LoomTheme.Side.switchKnobShadow, radius: 1, x: 0, y: 1)
                        .frame(width: LoomTheme.Side.switchKnob, height: LoomTheme.Side.switchKnob)
                        .offset(x: LoomTheme.Side.switchInset
                            + (configuration.isOn ? LoomTheme.Side.switchWidth - LoomTheme.Side.switchKnob - 2 * LoomTheme.Side.switchInset : 0))
                }
                .animation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Highlight.fadeDuration), value: configuration.isOn)
                .accessibilityHidden(true)
        }
    }
}
