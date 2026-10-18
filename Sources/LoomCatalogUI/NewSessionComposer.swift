import AppKit
import LoomCore
import SwiftUI

/// The draft's composer in the look of D-58 (design/v2-new-session-preview.html, N1): a card with the ticket
/// line when the text holds a key, the text, and a bar with the permission mode as plain text with a shield, the
/// model, and a round Send. Mode and model come from `NewSessionDefaults` and a pick overrides them. Small
/// and replaceable: V17 builds the session's own composer, and this one is its draft-time stand-in.
struct NewSessionComposer: View {
    let model: CatalogModel
    let projectID: UUID?
    @State private var height = NewSessionTextView.minimumHeight

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
                        .padding(.top, NewSessionTextView.inset.height).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                NewSessionTextView(
                    text: Binding(get: { draft.text }, set: { model.setDraftText($0, projectID: projectID) }),
                    height: $height, isEditable: !sending,
                    onSend: { model.sendDraft(projectID: projectID) },
                    onSendAndOpenFresh: { model.sendDraft(projectID: projectID, startsFreshDraft: true) },
                    onBlur: { model.newSession.flush() })
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
    static let barHeight: CGFloat = 34
    static let sendSize: CGFloat = 30
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

/// Mode and model chips and Send.
private struct ComposerBar: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        let resolved = model.resolvedStart(for: projectID)
        HStack(spacing: LoomTheme.Space.headerSpacing) {
            modeMenu(resolved)
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            modelMenu(resolved)
            SendButton(model: model, projectID: projectID)
        }
        .padding(.horizontal, LoomTheme.Space.detailSpacing).padding(.bottom, LoomTheme.Space.detailSpacing)
        .frame(minHeight: NewSessionLayout.barHeight)
    }

    private func modeMenu(_ resolved: ResolvedStart) -> some View {
        let draft = model.newSession.draft(for: projectID)
        // Full access that was not picked on this screen says where it comes from, in the chip's own style.
        let kept = model.draftKeepsFullAccess(projectID: projectID)
        let title = kept ? "\(resolved.modeTitle), kept from earlier" : resolved.modeTitle
        return Menu {
            ForEach(ClaudePermissionMode.allCases, id: \.self) { mode in
                Button { model.setDraftMode(.value(mode.rawValue), projectID: projectID) } label: {
                    if resolved.mode.value == mode.rawValue { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                }
            }
            Divider()
            Button { model.setDraftMode(.claudeDefault, projectID: projectID) } label: {
                if resolved.mode.value == nil { Label(NewSessionDefaults.claudeDefaultTitle, systemImage: "checkmark") }
                else { Text(NewSessionDefaults.claudeDefaultTitle) }
            }
            if let draft, draft.modePick != .inherit {
                Button("Use the default for this project") { model.setDraftMode(.inherit, projectID: projectID) }
            }
        } label: {
            // Every mode looks the same: no warning colour or mark, Full access included (D-58).
            HStack(spacing: LoomTheme.Space.hintSpacing) {
                Image(systemName: "shield").font(LoomTheme.Typography.small)
                Text(title).font(LoomTheme.Typography.smallMedium)
                Image(systemName: "chevron.down").font(LoomTheme.Typography.chevron).foregroundStyle(LoomTheme.Text.tertiary)
            }
            .foregroundStyle(LoomTheme.Text.secondaryStyle)
            .padding(.horizontal, LoomTheme.Space.cardH).frame(minHeight: NewSessionLayout.barHeight - LoomTheme.Space.headerSpacing)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Permission mode of the new session")
        .accessibilityLabel("Permission mode, \(title)")
        .accessibilityIdentifier("draft-mode")
    }

    private func modelMenu(_ resolved: ResolvedStart) -> some View {
        let draft = model.newSession.draft(for: projectID)
        return Menu {
            ForEach(NewSessionModels.all, id: \.alias) { entry in
                Button { model.setDraftModel(.value(entry.alias), projectID: projectID) } label: {
                    if resolved.model.value == entry.alias { Label(entry.title, systemImage: "checkmark") } else { Text(entry.title) }
                }
            }
            Divider()
            Button { model.setDraftModel(.claudeDefault, projectID: projectID) } label: {
                if resolved.model.value == nil { Label(NewSessionDefaults.claudeDefaultTitle, systemImage: "checkmark") }
                else { Text(NewSessionDefaults.claudeDefaultTitle) }
            }
            if let draft, draft.modelPick != .inherit {
                Button("Use the default for this project") { model.setDraftModel(.inherit, projectID: projectID) }
            }
        } label: {
            HStack(spacing: LoomTheme.Space.hintSpacing) {
                Text(resolved.modelTitle).font(LoomTheme.Typography.smallMedium)
                Image(systemName: "chevron.down").font(LoomTheme.Typography.chevron).foregroundStyle(LoomTheme.Text.tertiary)
            }
            .foregroundStyle(LoomTheme.Text.primary)
            .padding(.horizontal, LoomTheme.Space.cardH).frame(minHeight: NewSessionLayout.barHeight - LoomTheme.Space.headerSpacing)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Model of the new session")
        .accessibilityLabel("Model, \(resolved.modelTitle)")
        .accessibilityIdentifier("draft-model")
    }
}

/// The round Send button: light when the draft can start, dim when there is nothing to send.
private struct SendButton: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        let enabled = model.canSendDraft(projectID: projectID)
        Button { model.sendDraft(projectID: projectID) } label: {
            Image(systemName: "arrow.up").font(LoomTheme.Typography.bodyStrong)
                .foregroundStyle(enabled ? LoomTheme.Accent.onAccent : LoomTheme.Text.tertiary)
                .frame(width: NewSessionLayout.sendSize, height: NewSessionLayout.sendSize)
                .background(Circle().fill(enabled ? LoomTheme.Text.primary : LoomTheme.Surface.controlPressed))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .help(enabled ? "Start the session (↵). ⌘↵ starts it and opens a fresh draft" : "Nothing to start yet")
        .accessibilityLabel("Start session")
        .accessibilityIdentifier("draft-send")
    }
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
