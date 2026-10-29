import SwiftUI

/// Remora's memory (DESIGN §20 Memory; the reference's `remora/sections.html` "03 Memory"): one sheet of §6's family, 560 wide, over the
/// Settings window. The title and the line, three tabs (Journal, Project notes, Remora.md) as a segment, a pane that scrolls past 404,
/// Clear Working Memory… at the leading edge (it asks first) and Done, which closes the sheet as Esc does and is not filled: every
/// change is written at once, so nothing waits for a save.
struct RemoraMemorySheet: View {
    let catalog: CatalogModel
    let navigation: SettingsNavigation
    @State private var memory: RemoraMemoryModel

    private typealias M = LoomTheme.MemorySheet

    init(catalog: CatalogModel, navigation: SettingsNavigation) {
        self.catalog = catalog
        self.navigation = navigation
        _memory = State(initialValue: RemoraMemoryModel(catalog: catalog))
    }

    /// The sheet's shape: 560 wide, Done as the way out (it closes as Esc does), Clear Working Memory… at the leading edge, and no
    /// filled button, so Return does nothing.
    static func chrome<Content: View>(catalog: CatalogModel, navigation: SettingsNavigation,
                                      @ViewBuilder content: () -> Content) -> InkSheet<Content> {
        InkSheet(
            title: RemoraMemoryText.title, width: .memory, cancelTitle: RemoraMemoryText.done, cancel: navigation.sheets.dismiss,
            leading: SheetAction(
                id: "clear-working-memory", title: RemoraMemoryText.clear, isEnabled: catalog.hasRemora,
                perform: { navigation.askToClearRemoraMemory(fromMemorySheet: true) }),
            actions: [], content: content)
    }

    var body: some View {
        Self.chrome(catalog: catalog, navigation: navigation) {
            Text(RemoraMemoryText.line).projectType(LoomTheme.Sheet.text).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.lineTop)
            InkSegmented(values: RemoraMemoryTab.allCases, title: \.title, selection: navigation.memoryTab,
                         onSelect: { navigation.memoryTab = $0 })
                .accessibilityLabel("Memory")
                .padding(.top, M.tabsTop)
            RemoraMemoryPane(memory: memory, navigation: navigation)
                .padding(.top, M.paneTop)
        }
        .accessibilityIdentifier("settings-sheet-remora-memory")
        // Read again when a deletion ends: Remora has forgotten the session by then.
        .task(id: catalog.openDeletions) { await memory.load() }
        .onDisappear { memory.commitEditing() }
    }
}

/// A pane: its content scrolls when it is taller than 404 (or than the room the window leaves), and is as tall as itself when it is
/// shorter.
struct RemoraMemoryScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: contentHeight > 0 ? min(contentHeight, maxHeight) : maxHeight)
    }
}

struct RemoraMemoryPane: View {
    let memory: RemoraMemoryModel
    let navigation: SettingsNavigation

    var body: some View {
        RemoraMemoryScroll(maxHeight: LoomTheme.MemorySheet.paneMaxHeight) {
            switch navigation.memoryTab {
            case .journal: JournalPane(memory: memory)
            case .notes: NotesPane(memory: memory)
            case .noteFile: NoteFilePane(catalog: memory.catalog, navigation: navigation)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct EmptyPane: View {
    let text: String

    var body: some View {
        Text(text).projectType(LoomTheme.MemorySheet.emptyText).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, LoomTheme.MemorySheet.emptyTop)
    }
}

// MARK: Journal

private struct JournalPane: View {
    let memory: RemoraMemoryModel

    private typealias M = LoomTheme.MemorySheet

    var body: some View {
        if memory.loaded && memory.groups.isEmpty {
            EmptyPane(text: RemoraMemoryText.emptyJournal)
        } else {
            VStack(alignment: .leading, spacing: M.dayGap) {
                ForEach(memory.groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsLabel(text: group.label).padding(.bottom, M.dayLabelBottom)
                        ForEach(group.lines) { line in JournalLine(line: line) { memory.removeLine(line.id) } }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }
}

/// A journal line: the time, the text and a × that shows under the pointer.
private struct JournalLine: View {
    let line: RemoraJournalGroup.Line
    let remove: () -> Void
    @State private var hovering = false

    private typealias M = LoomTheme.MemorySheet

    var body: some View {
        let lit = hovering || LookEvidence.forcesHover("journal-line:\(line.id)")
        HStack(alignment: .top, spacing: M.lineGap) {
            Text(line.time).projectType(M.lineTime).lineHeight(.exact(points: M.lineTimeHeight))
                .offset(y: M.lineTimeDrop).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .frame(width: M.lineTimeWidth, alignment: .leading)
            Text(line.text).projectType(M.lineText).lineHeight(.exact(points: M.lineTextHeight))
                .offset(y: M.lineTextDrop).foregroundStyle(LoomTheme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: remove) {
                InkIcon(.close, size: LoomTheme.Icon.small).frame(width: M.removeSide, height: M.removeSide)
            }
            .buttonStyle(ChromeButtonStyle(size: CGSize(width: M.removeSide, height: M.removeSide)))
            .focusEffectDisabled()
            .opacity(lit ? 1 : 0)
            .frame(width: M.lineRemoveColumn, alignment: .leading)
            .accessibilityLabel("Remove this line")
        }
        .padding(.vertical, M.linePaddingV)
        .padding(.leading, M.linePaddingLeading).padding(.trailing, M.linePaddingTrailing)
        .background(RoundedRectangle(cornerRadius: M.lineRadius).fill(lit ? LoomTheme.Surface.hover : Color.clear))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Project notes

private struct NotesPane: View {
    let memory: RemoraMemoryModel

    var body: some View {
        if memory.loaded && memory.noteRows.isEmpty {
            EmptyPane(text: RemoraMemoryText.emptyNotes)
        } else {
            VStack(alignment: .leading, spacing: LoomTheme.MemorySheet.noteGap) {
                ForEach(memory.noteRows) { row in
                    switch row {
                    case let .card(card): NoteCardView(memory: memory, card: card)
                    case let .removed(removed): RemovedNote(memory: memory, removed: removed)
                    }
                }
            }
        }
    }
}

private struct NoteCardView: View {
    let memory: RemoraMemoryModel
    let card: RemoraMemoryModel.NoteCard
    @FocusState private var editorFocused: Bool

    private typealias M = LoomTheme.MemorySheet

    var body: some View {
        let editing = memory.isEditing(card)
        let shape = RoundedRectangle(cornerRadius: M.noteRadius)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: M.noteHeadGap) {
                ProjectMarkView(name: card.name, tone: card.tone, size: .chip)
                Text(card.name).projectType(M.noteHead).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                Spacer(minLength: 0)
                Text(memory.meta(of: card)).projectType(M.noteMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
            body(editing: editing).padding(.top, M.noteBodyTop)
            HStack(spacing: M.noteButtonsGap) {
                Button(editing ? RemoraMemoryText.doneEditing : RemoraMemoryText.edit) { memory.toggleEditing(card) }
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                    .accessibilityLabel((editing ? RemoraMemoryText.doneEditing : RemoraMemoryText.edit) + " the note of " + card.name)
                Button(RemoraMemoryText.remove) { memory.removeNote(card) }
                    .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                    .accessibilityLabel("Remove the note of " + card.name)
            }
            .padding(.top, M.noteButtonsTop)
        }
        .padding(.top, M.notePaddingTop).padding(.horizontal, M.notePaddingH).padding(.bottom, M.notePaddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(LoomTheme.Surface.raised1))
        .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
        .accessibilityElement(children: .contain)
    }

    /// The note's text, or the editor over it: on the canvas with an accent edge and a wash. The body is 8 wider than the card's text
    /// on each side, so its text stays in line with the head.
    @ViewBuilder
    private func body(editing: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: M.noteBodyRadius)
        Group {
            if editing {
                TextEditor(text: Binding(get: { memory.draft }, set: { memory.draft = $0 }))
                    .scrollContentBackground(.hidden)
                    .projectType(M.noteBody).lineSpacing(M.noteBodySpacing)
                    .foregroundStyle(LoomTheme.Text.primary)
                    .focused($editorFocused)
                    .frame(minHeight: M.noteBodyHeight * 3)
                    .padding(.horizontal, -M.editorInset)
                    .onAppear { editorFocused = true }
                    .accessibilityLabel("Note of " + card.name)
            } else {
                Text(card.text).projectType(M.noteBody).lineHeight(.exact(points: M.noteBodyHeight))
                    .offset(y: M.noteBodyDrop).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, M.noteBodyPaddingV).padding(.horizontal, M.noteBodyPaddingH)
        .background(shape.fill(editing ? LoomTheme.Surface.canvas : Color.clear))
        .overlay { if editing { shape.strokeBorder(LoomTheme.Accent.base, lineWidth: M.noteEditEdge) } }
        .background {
            if editing { shape.stroke(LoomTheme.Accent.wash, lineWidth: M.noteEditWash).padding(-M.noteEditWash / 2) }
        }
        .padding(.horizontal, -M.noteBodyPaddingH)
    }
}

/// What a removed note leaves: one line, with Undo.
private struct RemovedNote: View {
    let memory: RemoraMemoryModel
    let removed: RemoraMemoryModel.RemovedCard

    private typealias M = LoomTheme.MemorySheet

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: M.noteRadius)
        HStack(spacing: M.noteHeadGap) {
            Text(RemoraMemoryText.removed).projectType(M.removedText).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(RemoraMemoryText.undo) { memory.undoRemoval(removed.card.id) }
                .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                .disabled(removed.token == nil)
                .accessibilityLabel("Undo the removal of the note of " + removed.card.name)
        }
        .padding(.top, M.notePaddingTop).padding(.horizontal, M.notePaddingH).padding(.bottom, M.notePaddingTop)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(LoomTheme.Surface.raised1))
        .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Remora.md

/// The vault note: what it holds, where it is with Open (in Obsidian when it sits in a vault), and the honest line about who writes there. Its text is not shown:
/// it opens in the user's own editor.
private struct NoteFilePane: View {
    let catalog: CatalogModel
    let navigation: SettingsNavigation

    private typealias M = LoomTheme.MemorySheet

    var body: some View {
        let url = catalog.remoraNoteURL
        let shape = RoundedRectangle(cornerRadius: M.noteRadius)
        VStack(alignment: .leading, spacing: 0) {
            Text(RemoraMemoryText.noteFileHolds).projectType(M.noteBody).lineHeight(.exact(points: M.noteBodyHeight))
                .offset(y: M.noteBodyDrop).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.noteFilePaddingTop).padding(.horizontal, M.noteFilePaddingH).padding(.bottom, M.noteFilePaddingBottom)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(LoomTheme.Surface.raised1))
                .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
            HStack(spacing: M.pathGap) {
                Text(url.map(SettingsPaths.display) ?? RemoraMemoryText.noNoteFile)
                    .projectType(M.pathText).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
                Button(RemoraMemoryText.openTitle(note: url)) { if let url { navigation.noteActions.open(url) } }
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                    .disabled(url == nil)
            }
            .padding(.top, M.pathTop)
            Text(RemoraMemoryText.honesty).projectType(M.honestyText).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.honestyTop)
        }
    }
}
