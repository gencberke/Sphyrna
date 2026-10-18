import AppKit
import LoomCore
import SwiftUI

/// The draft's composer in the look of D-58 (design/v2-new-session-preview.html, N1): a card with the ticket
/// line when the text holds a key, the text, and a bar with the permission mode as plain text with a shield, the
/// model, and a round Send. Mode and model come from `NewSessionDefaults` and a pick overrides them.
///
/// It is the session's own composer at draft time (D-59): the text field, the keys and the bar's pieces are the
/// ones the live composer uses (`ComposerTextEditor`, `ComposerKeys`, `ComposerBar`); what differs is what the keys
/// do (↵ starts the session) and what the draft keeps (ticket line, presets, branch strip, its save).
struct NewSessionComposer: View {
    let model: CatalogModel
    let projectID: UUID?
    @State private var height = NewSessionLayout.textMinimumHeight
    @State private var host: DraftComposerHost

    init(model: CatalogModel, projectID: UUID?) {
        self.model = model
        self.projectID = projectID
        _host = State(initialValue: DraftComposerHost(model: model, projectID: projectID))
    }

    private var draft: SessionDraft { model.newSession.draft(for: projectID) ?? SessionDraft(projectID: projectID) }
    private var sending: Bool { model.newSession.isSending(projectID) }

    var body: some View {
        let status = model.newSession.ticketStatus(for: projectID)
        VStack(alignment: .leading, spacing: 0) {
            if status != .none { TicketLine(model: model, projectID: projectID, status: status, draft: draft) }
            ZStack(alignment: .topLeading) {
                if draft.text.isEmpty {
                    Text("Describe the work, paste a ticket key, or add a skill with /")
                        .font(LoomTheme.TypeScale.reading).foregroundStyle(LoomTheme.Text.tertiary)
                        .padding(.top, ComposerTextEditor.inset.height).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                ComposerTextEditor(host: host, height: $height, isEditable: !sending,
                                   minimumHeight: NewSessionLayout.textMinimumHeight,
                                   maximumHeight: NewSessionLayout.textMaximumHeight,
                                   accessibilityIdentifier: "draft-composer", accessibilityLabel: "Message for the new session")
                    .frame(height: height)
            }
            .padding(.horizontal, NewSessionLayout.textInset).padding(.top, NewSessionLayout.textTop)
            .opacity(sending ? LoomTheme.Opacity.disabled : 1)
            if let block = model.draftSendBlock(projectID: projectID) {
                Text(block).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NewSessionLayout.textInset).padding(.bottom, LoomTheme.Space.requestPadding)
                    .accessibilityIdentifier("draft-send-block")
            }
            if let notice = model.newSession.storeNotice {
                Text(notice).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NewSessionLayout.textInset).padding(.bottom, LoomTheme.Space.requestPadding)
                    .accessibilityIdentifier("draft-store-notice")
            }
            ComposerBar(model: model, projectID: projectID)
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.xxl).fill(LoomTheme.Surface.card))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.xxl)
            .strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draft-composer-card")
    }
}

/// Shared sizes of the draft screen.
enum NewSessionLayout {
    static let column: CGFloat = 720
    static let sideInset: CGFloat = 40
    /// The question sits above the middle of the page (the preview's 70 pt of bottom padding).
    static let bottomLift: CGFloat = 70
    static let popoverWidth: CGFloat = 320
    static let textInset: CGFloat = 18
    static let textTop: CGFloat = 10
    static let textMinimumHeight: CGFloat = 60
    static let textMaximumHeight: CGFloat = 220
    static let chipHeight: CGFloat = 26
    static let chipSpacing: CGFloat = 6
    static let headlinePickHeight: CGFloat = 36
    static let toneStripe = CGSize(width: 4, height: 17)
    static let glyph: CGFloat = 12
}

/// The line inside the composer for a ticket key (CHAT-SPEC, D-40): the key and whether the project already
/// has a session for it. A ticket that has one offers Open instead of a copy, and Start anyway for a second.
private struct TicketLine: View {
    let model: CatalogModel
    let projectID: UUID?
    let status: TicketStatus
    let draft: SessionDraft

    var body: some View {
        HStack(spacing: LoomTheme.Space.bannerRowSpacing) {
            Image(systemName: "ticket").font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .accessibilityHidden(true)
            switch status {
            case .none:
                EmptyView()
            case .free(let key):
                Text(key).font(LoomTheme.Typography.smallMedium).foregroundStyle(LoomTheme.Text.primary)
                if projectID != nil {
                    Text("· no session for it yet").font(LoomTheme.Typography.small)
                        .foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                Spacer(minLength: 0)
            case .exists(let key, _, let title):
                Text(key).font(LoomTheme.Typography.smallMedium).foregroundStyle(LoomTheme.Text.primary)
                Text(draft.allowDuplicateTicket ? "already has a session; this will be a second one"
                     : "already has a session\(title.map { ": \($0)" } ?? "")")
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                Button("Open") { model.openExistingTicketSession(projectID: projectID) }
                    .buttonStyle(AccentButtonStyle(kind: .tinted)).accessibilityIdentifier("draft-ticket-open")
                if !draft.allowDuplicateTicket {
                    Button("Start anyway") { model.allowDuplicateTicket(projectID: projectID) }
                        .buttonStyle(ChipButtonStyle()).accessibilityIdentifier("draft-ticket-anyway")
                }
            }
        }
        .padding(.horizontal, NewSessionLayout.textInset).padding(.top, LoomTheme.Space.requestPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draft-ticket-line")
    }
}

/// Mode and model chips and Send: the bar of D-58 without a ring (no session yet) and without +, whose menus need a
/// session's commands. The chips and their popovers are the live composer's (`ComposerPickers`, D-63).
private struct ComposerBar: View {
    let model: CatalogModel
    let projectID: UUID?
    @State private var modeOpen = false
    @State private var modelOpen = false
    @State private var effortOpen = false

    var body: some View {
        let resolved = model.resolvedStart(for: projectID)
        ComposerBarFrame {
            modeChip(resolved)
        } trailing: {
            modelChip(resolved)
            SendButton(model: model, projectID: projectID)
        }
    }

    private func modeChip(_ resolved: ResolvedStart) -> some View {
        let draft = model.newSession.draft(for: projectID)
        // Full access that was not picked on this screen says where it comes from, in the chip's own style.
        let kept = model.draftKeepsFullAccess(projectID: projectID)
        let title = kept ? "\(resolved.modeTitle), kept from earlier" : resolved.modeTitle
        let picked = draft.map { $0.modePick != .inherit && $0.modePick != .claudeDefault } ?? false
        return ComposerModeChip(
            selected: resolved.mode.value, title: title, help: "Permission mode of the new session", identifier: "draft-mode",
            reset: picked ? { model.setDraftMode(.inherit, projectID: projectID) } : nil,
            askAllowed: model.newSessionAllowsAsk, isOpen: $modeOpen) { mode in
            model.setDraftMode(.value(mode.rawValue), projectID: projectID)
        }
    }

    private func modelChip(_ resolved: ResolvedStart) -> some View {
        let draft = model.newSession.draft(for: projectID)
        let picker = ComposerModelPicker(
            modelTitle: resolved.modelTitle, effortTitle: resolved.effortTitle,
            rows: NewSessionModels.all.map { ComposerBarText.ModelRow(value: $0.alias, title: $0.title) },
            chosenModel: resolved.model.value, levels: NewSessionModels.effortLevels, chosenLevel: resolved.effort.value,
            canResetEffort: (draft?.effortPick ?? .inherit) != .inherit,
            resetHelp: "Back to the effort this project starts with")
        return ComposerModelChip(
            picker: picker, identifier: "draft-model", help: "Model of the new session",
            modelOpen: $modelOpen, effortOpen: $effortOpen,
            onPickModel: { value in model.setDraftModel(value.map { .value($0) } ?? .claudeDefault, projectID: projectID) },
            onPickEffort: { model.setDraftEffort(.value($0), projectID: projectID) },
            onResetEffort: { model.setDraftEffort(.inherit, projectID: projectID) })
    }
}

/// The round Send button: light when the draft can start, dim when there is nothing to send.
private struct SendButton: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        let enabled = model.canSendDraft(projectID: projectID)
        ComposerSendButton(
            look: enabled ? .send : .disabled, label: "Start session",
            help: enabled ? "Start the session (\u{21B5}). \u{2318}\u{21B5} starts it and opens a fresh draft" : "Nothing to start yet",
            identifier: "draft-send") { _ in model.sendDraft(projectID: projectID) }
    }
}

/// The draft's composer as the text view's host: ↵ starts the session, ⌘↵ starts it and opens a fresh draft [T3], and the
/// text goes to the project's draft slot (saved 300 ms after the last change, on blur and on Quit).
@MainActor
final class DraftComposerHost: ComposerEditorHost {
    private let model: CatalogModel
    private let projectID: UUID?

    init(model: CatalogModel, projectID: UUID?) {
        self.model = model
        self.projectID = projectID
    }

    var keyMode: ComposerKeys.Mode { .draft }
    var syncsByRevision: Bool { false }
    var textRevision: Int { 0 }
    var modelText: String { model.newSession.draft(for: projectID)?.text ?? "" }

    func keyState(isRepeat: Bool, hasMarkedText: Bool, bridge: any ComposerEditorBridge) -> ComposerKeys.State {
        var state = ComposerKeys.State()
        state.mode = .draft
        state.hasMarkedText = hasMarkedText
        state.isRepeat = isRepeat
        return state
    }

    func perform(_ action: ComposerKeys.Action, bridge: any ComposerEditorBridge, in window: NSWindow?) -> Bool {
        switch action {
        case .send: model.sendDraft(projectID: projectID)
        case .sendSecondary: model.sendDraft(projectID: projectID, startsFreshDraft: true)
        case .pastePlain:
            guard let text = NSPasteboard.general.string(forType: .string) else { return true }
            bridge.insertAtCaret(text)
        case .ignore: break
        default: return false
        }
        return true
    }

    func textChanged(_ text: String) { model.setDraftText(text, projectID: projectID) }
    func editorEndedEditing() { model.newSession.flush() }
    func paste(_ pasteboard: NSPasteboard, plain: Bool) -> Bool { false }
    func drop(_ pasteboard: NSPasteboard) -> Bool { false }
    func editorAttached(_ bridge: (any ComposerEditorBridge)?) {}
}

/// A quiet chip: the control fill, hairline, small text; used for presets and the strip.
struct ChipButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, emphasized: emphasized)
    }

    private struct Chip: View {
        let configuration: ButtonStyle.Configuration
        let emphasized: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(LoomTheme.Typography.small)
                .foregroundStyle(hovering || emphasized ? LoomTheme.Text.primary : LoomTheme.Text.secondary)
                .padding(.horizontal, LoomTheme.Space.cardV + 1).frame(minHeight: NewSessionLayout.chipHeight)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).fill(
                    configuration.isPressed ? LoomTheme.Surface.controlPressed
                        : (hovering ? LoomTheme.Surface.controlHover : LoomTheme.Surface.control)))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).strokeBorder(
                    LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.sm))
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }
    }
}
