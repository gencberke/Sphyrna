import SwiftUI

/// The inspector's Side tab (V22 part 3): the session's side chats. A side chat is a copy of the session that answers on the
/// side; its answers are in the main chat's own style, and the main session never sees it unless "Send to main as a note" is
/// clicked. The tab holds a header (with "New side chat"), the "Earlier side chats" menu, the thread or the empty state, and a
/// compact composer. Nothing is read while the inspector is closed, and nothing starts before the first question; a side chat
/// that runs goes on running when the tab, the inspector or the session leaves the screen.
struct SideTab: View {
    let model: CatalogModel
    let row: SessionRowModel

    var body: some View {
        // The holder is made by the inspector's side read (`CatalogModel.sideTrigger`) or by the first action.
        if let session = model.side.existing(for: row.id) {
            SideTabContent(model: model, row: row, session: session)
        } else {
            Spacer(minLength: 0)
        }
    }
}

private struct SideTabContent: View {
    let model: CatalogModel
    let row: SessionRowModel
    let session: SideSession

    var body: some View {
        let open = session.openItem
        VStack(spacing: 0) {
            if let open {
                SideHeader(model: model, parent: row.id, item: open)
            }
            let others = session.items.filter { $0.id != open?.id }
            if !others.isEmpty {
                SideEarlierMenu(model: model, parent: row.id, items: others)
            }
            thread(open)
            SideComposerView(model: model, row: row, session: session).id(row.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: Binding(get: { session.discard }, set: { if $0 == nil { model.cancelDiscardSideChat(in: row.id) } })) { request in
            SideDiscardSheet(model: model, parent: row.id, request: request)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector-side")
    }

    @ViewBuilder private func thread(_ open: SideChatItem?) -> some View {
        if let open {
            if session.discarding.contains(open.id) {
                SideStatusLine(text: SideText.discarding, busy: true)
                Spacer(minLength: 0)
            } else if let failure = session.discardFailures[open.id] {
                SideDiscardFailure(model: model, parent: row.id, id: open.id, text: failure)
                Spacer(minLength: 0)
            } else if let feed = model.sideFeed(for: open, in: row.id) {
                SideThread(model: model, parent: row.id, item: open, feed: feed)
            } else {
                Spacer(minLength: 0)
            }
        } else {
            SideEmptyState()
        }
    }
}

/// "Side chat", what it saw, and "New side chat".
struct SideHeader: View {
    let model: CatalogModel
    let parent: UUID
    let item: SideChatItem

    var body: some View {
        HStack(alignment: .top, spacing: LoomTheme.Side.headerGap) {
            Image(systemName: "arrow.triangle.branch").font(LoomTheme.Side.headerGlyph)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).padding(.top, LoomTheme.Side.headerNoteGap).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LoomTheme.Side.headerNoteGap) {
                Text(SideText.headerTitle).font(LoomTheme.Side.headerTitle).foregroundStyle(LoomTheme.Text.primary)
                Text(SideText.headerNote(forkedAt: item.forkedAt)).font(LoomTheme.Side.headerNote)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("side-header-note")
            }
            Spacer(minLength: LoomTheme.Side.headerButtonGap)
            Button { model.startNewSideChat(in: parent) } label: {
                Image(systemName: "plus").font(LoomTheme.Side.headerButtonGlyph)
                    .frame(width: LoomTheme.Side.controlSide, height: LoomTheme.Side.controlSide).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .help(SideText.newSideChat)
            .accessibilityLabel(SideText.newSideChat)
            .accessibilityIdentifier("side-new")
        }
        .padding(.horizontal, LoomTheme.Side.headerInsetH).padding(.vertical, LoomTheme.Side.headerInsetV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
        }
    }
}

/// The session's other side chats, newest first.
struct SideEarlierMenu: View {
    let model: CatalogModel
    let parent: UUID
    let items: [SideChatItem]

    var body: some View {
        HStack(spacing: LoomTheme.Side.headerButtonGap) {
            Menu {
                ForEach(items) { item in
                    Button(SideText.earlierEntry(item)) { model.openSideChat(item.id, in: parent) }
                }
            } label: {
                Text("\(SideText.earlier) \u{00B7} \(items.count)").font(LoomTheme.Side.earlierFont)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .accessibilityIdentifier("side-earlier")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Side.headerInsetH)
        .frame(height: LoomTheme.Side.earlierHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
        }
    }
}

struct SideEmptyState: View {
    var body: some View {
        VStack {
            Text(SideText.emptyState).font(LoomTheme.Side.emptyFont).lineSpacing(LoomTheme.Side.emptyLineSpacing)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .padding(LoomTheme.Side.emptyInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("side-empty")
            Spacer(minLength: 0)
        }
    }
}

/// One quiet line in the column, with a spinner while something is under way.
struct SideStatusLine: View {
    let text: String
    var busy = false

    var body: some View {
        HStack(spacing: LoomTheme.Side.headerButtonGap) {
            if busy { ProgressView().controlSize(.small) }
            Text(text).font(LoomTheme.Side.statusFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Side.statusInsetH).padding(.vertical, LoomTheme.Side.headerInsetV)
        .accessibilityIdentifier("side-status")
    }
}

/// A discard that did not finish: why, and "Try again" (the deletion's own retry).
private struct SideDiscardFailure: View {
    let model: CatalogModel
    let parent: UUID
    let id: UUID
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Side.headerButtonGap) {
            Text(text).font(LoomTheme.Side.statusFont).foregroundStyle(LoomTheme.Status.failureLight)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await model.retryDiscardSideChat(id, in: parent) } }
                .buttonStyle(SettingsButtonStyle())
        }
        .padding(.horizontal, LoomTheme.Side.statusInsetH).padding(.vertical, LoomTheme.Side.headerInsetV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("side-discard-failure")
    }
}

/// "Discard this side chat?": Cancel is the default button (and Esc), so Return never discards.
struct SideDiscardSheet: View {
    let model: CatalogModel
    let parent: UUID
    let request: SideDiscardRequest

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sheetSpacing) {
            Text(SideText.discardTitle).font(LoomTheme.Typography.title)
            Text(request.title).font(LoomTheme.Typography.bodyStrong).foregroundStyle(LoomTheme.Text.primary)
                .lineLimit(2).truncationMode(.tail)
            Text(SideText.discardMessage).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(SideText.discardCancel) { model.cancelDiscardSideChat(in: parent) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AccentButtonStyle(kind: .filled))
                    .accessibilityIdentifier("side-discard-cancel")
                Button(SideText.discardConfirm) { Task { await model.confirmDiscardSideChat(in: parent) } }
                    .buttonStyle(DestructiveButtonStyle())
                    .accessibilityIdentifier("side-discard-confirm")
            }
        }
        .padding(LoomTheme.Space.sheetPadding)
        .frame(width: LoomTheme.Layout.sheetWidth)
        .tint(LoomTheme.Accent.base)
        .accessibilityIdentifier("side-discard-sheet")
    }
}

/// "Send to main as a note" and "Copy" under a finished side answer. After the note went, "Sent to the main session" takes the
/// button's place. Off, with the reason, where the parent is not a Chat session.
struct SideAnswerActions: View {
    let entryID: String
    let text: String
    let notes: SideAnswerNotes
    let context: ChatRowContext

    var body: some View {
        let status = notes.status(for: entryID)
        let availability = notes.availability()
        HStack(spacing: LoomTheme.Side.actionGap) {
            switch status {
            case .sent:
                HStack(spacing: LoomTheme.Side.actionGlyphGap) {
                    Image(systemName: "checkmark").font(LoomTheme.Side.sentGlyph)
                    Text(SideText.noteSent)
                }
                .font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .accessibilityElement(children: .combine).accessibilityIdentifier("side-note-sent")
            case .idle, .sending, .failed:
                let reason: String? = { if case let .off(why) = availability { why } else { nil } }()
                Button { notes.send(entryID) } label: {
                    HStack(spacing: LoomTheme.Side.actionGlyphGap) {
                        Image(systemName: "arrow.up").font(LoomTheme.Side.actionGlyph)
                        Text(SideText.sendNote)
                    }
                }
                .buttonStyle(.plain).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .disabled(reason != nil || status == .sending)
                .opacity(reason == nil ? 1 : LoomTheme.Opacity.disabled)
                .help(reason ?? SideText.sendNote)
                .accessibilityLabel(SideText.sendNote).accessibilityHint(reason ?? "")
                .accessibilityIdentifier("side-note-send")
            }
            ChatCopyButton(text: text, context: context)
            if case let .failed(message) = status {
                Text(message).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Status.failureLight).lineLimit(1)
                    .truncationMode(.tail).help(message)
            }
        }
    }
}
