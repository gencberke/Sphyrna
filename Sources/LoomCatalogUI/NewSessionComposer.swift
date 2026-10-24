import AppKit
import LoomCore
import SwiftUI

/// The draft's composer in the look of D-58 (design/v2-new-session-preview.html, N1): a card with the text
/// and a bar with the permission mode as plain text with a shield, the
/// model, and a round Send. Mode and model come from `NewSessionDefaults` and a pick overrides them.
///
/// It is the session's own composer at draft time (D-59): the text field, the keys and the bar's pieces are the
/// ones the live composer uses (`ComposerTextEditor`, `ComposerKeys`, `ComposerBar`); what differs is what the keys
/// do (↵ starts the session) and what the draft keeps (presets, branch strip, its save).
struct NewSessionComposer: View {
    let model: CatalogModel
    let projectID: UUID?
    /// Moves when a drop elsewhere on the page landed in the draft: the field takes the keyboard.
    var focusRequest = 0
    @State private var height = NewSessionLayout.textMinimumHeight
    @State private var host: DraftComposerHost

    init(model: CatalogModel, projectID: UUID?, focusRequest: Int = 0) {
        self.model = model
        self.projectID = projectID
        self.focusRequest = focusRequest
        _host = State(initialValue: DraftComposerHost(model: model, projectID: projectID))
    }

    private var draft: SessionDraft { model.newSession.draft(for: projectID) ?? SessionDraft(projectID: projectID) }
    private var sending: Bool { model.newSession.isSending(projectID) }

    var body: some View {
        VStack(spacing: LoomTheme.Edges.stackGap) {
            // The page's two notes are banners above the composer (DESIGN §19 Banners), each gone with its cause.
            ForEach(DraftNotes.make(sendBlock: model.draftSendBlock(projectID: projectID), storeNotice: model.newSession.storeNotice)) { note in
                BannerBox(tone: note.tone, text: note.text, selectable: true, textInsetV: LoomTheme.Edges.textInsetV,
                          identifier: note.identifier)
                    .fadesIn()
            }
            card
        }
        .onChange(of: focusRequest) { host.focusEditor() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if draft.text.isEmpty {
                    Text("Describe the work, or add a skill with /")
                        .font(LoomTheme.TypeScale.reading).foregroundStyle(LoomTheme.Text.faint)
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
            ComposerBar(model: model, projectID: projectID, restoreFocus: { host.focusEditor() })
        }
        .composerCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draft-composer-card")
    }
}

/// The draft page's two notes (DESIGN §19 Banners): a message too long to start a session with is a note, and a draft that could
/// not be saved limits what the page promises, so it is an attention banner. The heavier one comes first. Each goes with its
/// cause.
struct DraftNote: Equatable, Identifiable {
    let tone: ChatBannerTone
    let text: String
    let identifier: String

    var id: String { identifier }
}

enum DraftNotes {
    static func make(sendBlock: String?, storeNotice: String?) -> [DraftNote] {
        var notes: [DraftNote] = []
        if let storeNotice { notes.append(DraftNote(tone: .attention, text: storeNotice, identifier: "draft-store-notice")) }
        if let sendBlock { notes.append(DraftNote(tone: .note, text: sendBlock, identifier: "draft-send-block")) }
        return notes
    }
}

/// Shared sizes of the draft screen (DESIGN §8; the reference's `.draftpage`). The page's rhythm, top to bottom: the folder line
/// 16 under the question, the composer 30 under it, the keys line 14, the strip 26 and the presets 14. Type, colours and the
/// optical values are `LoomTheme.Draft`.
enum NewSessionLayout {
    static let column: CGFloat = 720
    static let sideInset: CGFloat = 40
    /// The composer is 680 wide, centred in the column.
    static let composerWidth: CGFloat = 680
    /// The question sits above the middle of the page (the preview's 70 pt of bottom padding).
    static let bottomLift: CGFloat = 70
    static let folderTop: CGFloat = 16
    static let composerTop: CGFloat = 30
    static let keysTop: CGFloat = 14
    static let stripTop: CGFloat = 26
    static let presetsTop: CGFloat = 14
    static let presetGap: CGFloat = 8
    /// The name popover of a new branch or worktree.
    static let popoverWidth: CGFloat = 280
    /// The draft's composer is the live one (D-58, D-59, V17): its text inset, top and chip spacing are the live composer's
    /// tokens, so the two cards look the same. `FixRoundLookTests` ties them.
    static let textInset: CGFloat = LoomTheme.Composer.textInsetH
    static let textTop: CGFloat = LoomTheme.Composer.textTop
    static let textMinimumHeight: CGFloat = 60
    static let textMaximumHeight: CGFloat = 220
    static let chipSpacing: CGFloat = LoomTheme.Composer.chipGap
}

/// Mode and model chips and Send: the bar of D-58 without a ring (no session yet) and without +, whose menus need a
/// session's commands. The chips and their popovers are the live composer's (`ComposerPickers`, D-63; the one model chip, D-75),
/// opening below their chips in the window's host (`InkOpeners`). Which one is open is `InkOpenState`'s, so the evidence can
/// open it.
private struct ComposerBar: View {
    let model: CatalogModel
    let projectID: UUID?
    /// Gives the keyboard back to the draft's text when a popover closes.
    let restoreFocus: () -> Void
    private let openState = InkOpenState.shared

    var body: some View {
        let resolved = model.resolvedStart(for: projectID)
        ComposerBarFrame {
            modeChip(resolved)
        } trailing: {
            modelChip(resolved)
            SendButton(model: model, projectID: projectID)
        }
        // A popover does not outlive its page: coming back to it finds it shut.
        .onDisappear { if openState.draft?.projectID == projectID { openState.draft = nil } }
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
            askAllowed: model.newSessionAllowsAsk, onDraft: true, restoreFocus: restoreFocus,
            isOpen: openState.draftBinding(.mode, projectID: projectID)) { mode in
            model.setDraftMode(.value(mode.rawValue), projectID: projectID)
        }
    }

    private func modelChip(_ resolved: ResolvedStart) -> some View {
        let draft = model.newSession.draft(for: projectID)
        let picker = ComposerModelPicker(
            modelTitle: resolved.modelTitle, effortTitle: resolved.effortTitle,
            rows: ModelCatalog.claude.map { ComposerBarText.ModelRow(value: $0.id, title: $0.title) },
            chosenModel: resolved.model.value, levels: NewSessionModels.effortLevels, chosenLevel: resolved.effort.value,
            canResetEffort: (draft?.effortPick ?? .inherit) != .inherit,
            resetHelp: "Back to the effort this project starts with",
            // A build that cannot start Codex shows its group off, with the build's own words (DESIGN §8).
            codexNote: model.newSessionUnavailableReason(.codex) ?? ComposerModelNotes.inNewSession)
        return ComposerModelChip(
            picker: picker, identifier: "draft-model", help: "Model and effort of the new session",
            onDraft: true, restoreFocus: restoreFocus, isOpen: openState.draftBinding(.model, projectID: projectID),
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
            help: DraftWords.sendHelp(enabled: enabled),
            identifier: "draft-send") { _ in model.sendDraft(projectID: projectID) }
    }
}

/// The draft's composer as the text view's host: ↵ starts the session, ⌘↵ starts it and opens a fresh draft [T3], and the
/// text goes to the project's draft slot (saved 300 ms after the last change, on blur and on Quit).
@MainActor
final class DraftComposerHost: ComposerEditorHost {
    private let model: CatalogModel
    private let projectID: UUID?
    private weak var editor: (any ComposerEditorBridge)?

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

    /// Files and folders as `@path` and `@folder/`, relative to the draft's project folder. The new session's first message
    /// is text only, so an image file is a path too. Refused while the draft is being sent.
    func drop(_ pasteboard: NSPasteboard) -> Bool {
        guard !model.newSession.isSending(projectID) else { return false }
        return ComposerPasteboard.dropMentions(from: pasteboard, relativeTo: model.draftProject(projectID)?.path, into: editor,
                                        text: modelText) { model.setDraftText($0, projectID: projectID) }
    }

    /// A drop anywhere on the draft page (`ComposerPaneDrop`): the files go after the draft's text. The page then gives the
    /// field the keyboard (`NewSessionComposer.focusRequest`). Refused while the draft is being sent: the started session
    /// discards the draft, and what landed with it.
    static func dropOnPage(_ pasteboard: NSPasteboard, model: CatalogModel, projectID: UUID?) -> Bool {
        guard !model.newSession.isSending(projectID) else { return false }
        return ComposerPasteboard.dropMentions(from: pasteboard, relativeTo: model.draftProject(projectID)?.path, into: nil,
                                        text: model.newSession.draft(for: projectID)?.text ?? "") {
            model.setDraftText($0, projectID: projectID)
        }
    }

    func editorAttached(_ bridge: (any ComposerEditorBridge)?) { editor = bridge }

    /// The draft's text takes the keyboard back (a popover closed).
    func focusEditor() { editor?.focus() }
}
