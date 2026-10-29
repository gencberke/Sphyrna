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

/// "Side chat", what it saw, and "New side chat": the title in 13 semibold, the note in 11.5 tertiary and a "+" icon button.
struct SideHeader: View {
    let model: CatalogModel
    let parent: UUID
    let item: SideChatItem

    var body: some View {
        HStack(alignment: .top, spacing: LoomTheme.Side.headerGap) {
            VStack(alignment: .leading, spacing: LoomTheme.Side.headerNoteGap) {
                Text(SideText.headerTitle).font(LoomTheme.Side.headerTitle).foregroundStyle(LoomTheme.Text.primary)
                Text(SideText.headerNote(forkedAt: item.forkedAt)).font(LoomTheme.Side.headerNote)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("side-header-note")
            }
            Spacer(minLength: LoomTheme.Side.headerButtonGap)
            Button { model.startNewSideChat(in: parent) } label: { InkIcon(.plus) }
                .buttonStyle(ChromeButtonStyle())
                .help(SideText.newSideChat)
                .accessibilityLabel(SideText.newSideChat)
                .accessibilityIdentifier("side-new")
        }
        .padding(.horizontal, LoomTheme.Side.headerInsetH).padding(.top, LoomTheme.Side.headerInsetV)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The session's other side chats, newest first: a clock, "Earlier side chats · N" and a chevron, in 12 secondary.
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
                HStack(spacing: LoomTheme.Side.earlierGap) {
                    InkIcon(.clock, size: LoomTheme.Icon.body)
                    Text("\(SideText.earlier) \u{00B7} \(items.count)").font(LoomTheme.Side.earlierFont)
                    InkIcon(.chevronDown, size: LoomTheme.Icon.tiny)
                }
                .foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("\(SideText.earlier), \(items.count)")
            .accessibilityIdentifier("side-earlier")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Side.headerInsetH)
        .padding(.top, LoomTheme.Side.earlierTop)
        .frame(minHeight: LoomTheme.Side.earlierHeight)
    }
}

/// The empty Side tab: the line.
struct SideEmptyState: View {
    var body: some View {
        VStack(spacing: 0) {
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
    @Environment(\.indicatorsAnimate) private var animates

    var body: some View {
        HStack(spacing: LoomTheme.Side.headerButtonGap) {
            if busy { BrailleSpinner(animating: animates).frame(width: LoomTheme.Layout.indicatorSlot.width).accessibilityHidden(true) }
            Text(text).font(LoomTheme.Side.statusFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Side.statusInsetH).padding(.vertical, LoomTheme.Side.headerInsetV)
        .accessibilityIdentifier("side-status")
    }
}

/// A discard that did not finish: why, and "Try Again" (the deletion's own retry).
private struct SideDiscardFailure: View {
    let model: CatalogModel
    let parent: UUID
    let id: UUID
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Side.headerButtonGap) {
            Text(text).font(LoomTheme.Side.statusFont).foregroundStyle(LoomTheme.Status.failureLight)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { Task { await model.retryDiscardSideChat(id, in: parent) } }
                .buttonStyle(ControlButtonStyle(kind: .outline))
        }
        .padding(.horizontal, LoomTheme.Side.statusInsetH).padding(.vertical, LoomTheme.Side.headerInsetV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("side-discard-failure")
    }
}

/// "Discard this side chat?" (DESIGN §6 Sheets): a sheet that removes has no default button. Cancel has the focus and Esc,
/// Discard is tinted in the failure tone, and Return does nothing.
struct SideDiscardSheet: View {
    let model: CatalogModel
    let parent: UUID
    let request: SideDiscardRequest

    var body: some View {
        InkSheet(
            title: SideText.discardTitle, subject: request.title,
            cancelTitle: SideText.discardCancel, cancel: { model.cancelDiscardSideChat(in: parent) },
            actions: [SheetAction(id: "discard", title: SideText.discardConfirm, tint: .failure,
                                  perform: { Task { await model.confirmDiscardSideChat(in: parent) } })]
        ) {
            SheetText(text: SideText.discardMessage)
        }
        .accessibilityIdentifier("side-discard-sheet")
    }
}

/// Copy and "Send to Main as a Note" under a finished side answer, secondary small buttons. After the note went, "Sent to the
/// main session" takes the note button's place. Off, with the reason, where the parent is not a Chat session.
struct SideAnswerActions: View {
    let entryID: String
    let text: String
    let notes: SideAnswerNotes
    let context: ChatRowContext

    var body: some View {
        let status = notes.status(for: entryID)
        let availability = notes.availability()
        HStack(spacing: LoomTheme.Side.actionGap) {
            AsideCopyButton(text: text, context: context)
            switch status {
            case .sent:
                HStack(spacing: LoomTheme.Side.actionGlyphGap) {
                    InkIcon(.check, size: LoomTheme.Icon.compact)
                    Text(SideText.noteSent)
                }
                .font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .accessibilityElement(children: .combine).accessibilityIdentifier("side-note-sent")
            case .idle, .sending, .failed:
                let reason: String? = { if case let .off(why) = availability { why } else { nil } }()
                Button(SideText.sendNote) { notes.send(entryID) }
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                    .disabled(reason != nil || status == .sending)
                    .help(reason ?? SideText.sendNote)
                    .accessibilityLabel(SideText.sendNote).accessibilityHint(reason ?? "")
                    .accessibilityIdentifier("side-note-send")
            }
            if case let .failed(message) = status {
                Text(message).font(LoomTheme.Chat.meta).foregroundStyle(LoomTheme.Status.failureLight).lineLimit(1)
                    .truncationMode(.tail).help(message)
            }
        }
    }
}

/// Copy on an aside's answer: a secondary small button with the copy glyph, "Copied" for 1.2 s (the quick question and the Side
/// tab; the stream's link-style Copy is the main chat's).
struct AsideCopyButton: View {
    let text: String
    let context: ChatRowContext
    @State private var copied = false

    var body: some View {
        Button {
            context.copy(text)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(LoomTheme.Chat.copiedDuration))
                copied = false
            }
        } label: {
            HStack(spacing: LoomTheme.Side.actionGlyphGap) {
                InkIcon(copied ? .check : .copy, size: LoomTheme.Icon.body)
                Text(copied ? "Copied" : "Copy")
            }
        }
        .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
        .help("Copy")
        .accessibilityLabel("Copy")
    }
}
