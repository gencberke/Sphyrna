import AppKit
import SwiftUI

/// The inspector's Changes tab (V20): a scope control, the files of the scope, the open file's diff, and the footer that
/// sends line comments where the session supports them. Last turn and Whole session show recorded file edits;
/// Branch shows the working tree against the merge base with the base branch (read from git). It reads only
/// while it is on screen (`CatalogModel.changesTrigger`).
struct ChangesTab: View {
    let model: CatalogModel
    let row: SessionRowModel

    var body: some View {
        let session = model.changes.session(for: row.id)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: LoomTheme.Changes.sectionGap) {
                    ChangesScopeBar(model: model, sessionID: row.id, selected: session.scope)
                    ChangesBody(model: model, sessionID: row.id, session: session)
                }
                .padding(LoomTheme.Changes.bodyInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ChangesFooter(model: model, sessionID: row.id, session: session)
        }
        // A turn that ends while the tab shows reads again (`noteChangesIndicator`); a card that waits is not its end.
        .onChange(of: row.indicator, initial: true) { _, indicator in
            model.noteChangesIndicator(indicator, for: row.id)
        }
        // Whether this run takes the comments (F11): asked again for a new run, a native session or a status change.
        .task(id: ChangesReceiverKey(run: row.live?.runID, conversation: row.live?.conversationID, indicator: row.indicator)) {
            await model.refreshChangesReceiver(for: row.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector-changes")
    }
}

private struct ChangesReceiverKey: Equatable {
    var run: UUID?
    var conversation: String?
    var indicator: SessionIndicator
}

/// Last turn | Whole session | Branch.
struct ChangesScopeBar: View {
    let model: CatalogModel
    let sessionID: UUID
    let selected: ChangesScope

    var body: some View {
        HStack(spacing: LoomTheme.Changes.segmentSpacing) {
            InkSegmented(values: ChangesScope.allCases, title: \.title, selection: selected,
                         key: { "changes-scope:\($0.rawValue)" },
                         onSelect: { model.setChangesScope($0, for: sessionID) })
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes scope")
    }
}

/// Everything under the scope control: the quiet line, then the file list and the open file, or the state of the read.
private struct ChangesBody: View {
    let model: CatalogModel
    let sessionID: UUID
    let session: SessionChanges

    var body: some View {
        let scope = session.scope
        let state = session.currentState
        VStack(alignment: .leading, spacing: LoomTheme.Changes.sectionGap) {
            if let note = ChangesBodyWords.note(scope: scope, state: state, harnessName: harnessName) {
                Text(verbatim: note).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            switch state {
            case .idle, .loading:
                // Git can take its time: the branch says what it runs and for how long. The turn scopes read Claude's
                // transcript, usually in a blink.
                if scope == .branch {
                    ChangesBranchReading()
                } else {
                    ChangesNote(text: ChangesBodyWords.readingEdits, busy: true)
                }
            case let .off(reason):
                ChangesNote(text: reason)
            case .timedOut:
                ChangesNote(text: "Git did not answer", retry: { model.retryChanges(for: sessionID) })
            case let .failed(message):
                ChangesNote(text: "The changes could not be read. \(message)", retry: { model.retryChanges(for: sessionID) })
            case let .ready(data):
                if data.files.isEmpty {
                    InspectorEmptyState(text: ChangesBodyWords.emptyText(scope: scope, data: data, harnessName: harnessName))
                } else {
                    ChangesFileList(model: model, sessionID: sessionID, session: session, data: data)
                    if let file = session.selected[scope].flatMap({ id in data.files.first { $0.id == id } }) {
                        ChangesDiffCard(model: model, sessionID: sessionID, file: file,
                                        content: Self.content(of: file, scope: scope, data: data, session: session),
                                        comments: session.comments(in: scope).filter { $0.anchor.fileID == file.id })
                    }
                }
            }
        }
    }

    private var harnessName: String {
        let row = model.selectedRow?.id == sessionID ? model.selectedRow : model.rowModels[sessionID]
        return row.map { model.capabilities(of: $0.record.session.provider).displayName } ?? "Session"
    }

    static func content(of file: ChangesFile, scope: ChangesScope, data: ChangesScopeData,
                        session: SessionChanges) -> ChangesDiffCard.Content {
        if file.isBinary { return .binary }
        if file.isTooLarge { return .tooLarge }
        if scope != .branch { return .hunks(data.hunks[file.id] ?? []) }
        switch session.gitDiffs[file.id] {
        case nil, .loading?: return .loading
        case let .hunks(hunks)?: return .hunks(hunks)
        case .binary?: return .binary
        case .tooLarge?: return .tooLarge
        case .timedOut?: return .timedOut
        case let .failed(message)?: return .failed(message)
        }
    }
}

/// What the tab says in words.
enum ChangesBodyWords {
    /// The one quiet line of the scope: what it leaves out, what was not read, or where the branch stands.
    static func note(scope: ChangesScope, state: ChangesScopeState, harnessName: String = "Claude") -> String? {
        switch scope {
        case .lastTurn, .wholeSession:
            guard case .off = state else {
                let base = "\(harnessName)'s file edits. Shell commands and subagents show under Branch."
                if state.data?.partial == true { return base + " Some edits could not be read." }
                return state.data?.truncated == true ? base + " Older edits were not read." : base
            }
            return nil
        case .branch:
            guard let data = state.data, let base = data.baseName else { return nil }
            return data.onBase ? "You are on \(base). Showing the uncommitted changes." : "Your working tree against \(base)."
        }
    }

    static let readingEdits = "Reading the changes"
    static let readingBranch = "Reading the branch…"
    /// The command the branch's list comes from (`GitChanges`): the merge base it compares to is known only once the read is done.
    static let branchCommand = "git diff --numstat -M"

    /// The line under "Reading the branch…": the command and how long it has run, counted from 1 in its first second.
    static func readingLine(elapsed: TimeInterval) -> String {
        "\(branchCommand) \u{00B7} \(Int(max(0, elapsed)) + 1) s"
    }

    static func emptyText(scope: ChangesScope, data: ChangesScopeData, harnessName: String = "Claude") -> String {
        switch scope {
        case .lastTurn: "\(harnessName) has not edited files in the last turn."
        case .wholeSession: "\(harnessName) has not edited files in this session."
        case .branch: data.onBase ? "No uncommitted changes." : "No changes against \(data.baseName ?? "the base branch")."
        }
    }
}

/// While git reads the branch: the command and elapsed time. Only an active window keeps the one-second clock.
struct ChangesBranchReading: View {
    @State private var start = Date()
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate

    var body: some View {
        Group {
            if indicatorsAnimate {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    reading(at: context.date)
                }
            } else {
                reading(at: Date())
            }
        }
        .accessibilityIdentifier("changes-reading-branch")
    }

    private func reading(at date: Date) -> some View {
        VStack(spacing: 0) {
            BrailleSpinner(animating: indicatorsAnimate)
                .frame(width: LoomTheme.Layout.indicatorSlot.width, height: LoomTheme.Layout.indicatorSlot.height)
                .accessibilityHidden(true)
            InspectorEmptyState(text: ChangesBodyWords.readingBranch,
                                detail: ChangesBodyWords.readingLine(elapsed: date.timeIntervalSince(start)))
        }
    }
}

/// What the list's row says for a file: a rename reads "old → new", the old path tertiary and the name primary.
enum ChangesFileText {
    static func name(_ name: String, oldPath: String?) -> AttributedString {
        guard let oldPath else { return AttributedString(name) }
        var old = AttributedString("\(oldPath) \u{2192} ")
        old.foregroundColor = LoomTheme.Text.tertiary
        var new = AttributedString(name)
        new.foregroundColor = LoomTheme.Text.primary
        return old + new
    }
}

/// The scope's files: folders first as the changed-files card draws them, with the +/− counts and the comment count.
private struct ChangesFileList: View {
    let model: CatalogModel
    let sessionID: UUID
    let session: SessionChanges
    let data: ChangesScopeData

    var body: some View {
        let lines = ChangesTree.lines(of: data.files)
        let comments = session.comments(in: session.scope)
        let height = min(CGFloat(lines.count) * LoomTheme.Changes.fileRowHeight, LoomTheme.Changes.fileListMaxHeight)
        VStack(alignment: .leading, spacing: LoomTheme.Changes.noteGap) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        if let file = line.file {
                            fileRow(line, file: file, comments: comments.filter { $0.anchor.fileID == file.id }.count)
                        } else {
                            folderRow(line)
                        }
                    }
                }
            }
            .frame(height: height)
            if data.omittedFiles > 0 {
                Text("\(data.omittedFiles) more files are not listed.").font(LoomTheme.Typography.caption)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }

    private func folderRow(_ line: ChangesTree.Line) -> some View {
        HStack(spacing: LoomTheme.Changes.fileRowGap) {
            InkIcon(.folder, size: LoomTheme.Icon.body).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .frame(width: LoomTheme.Changes.fileGlyphWidth).accessibilityHidden(true)
            Text(verbatim: line.name).font(LoomTheme.Changes.fileName).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(line.depth) * LoomTheme.Changes.fileIndent + LoomTheme.Changes.fileRowInset)
        .frame(height: LoomTheme.Changes.fileRowHeight)
    }

    private func fileRow(_ line: ChangesTree.Line, file: ChangesFile, comments: Int) -> some View {
        ChangesFileRow(model: model, sessionID: sessionID, line: line, file: file, comments: comments,
                       selected: session.selected[session.scope] == file.id)
    }

    static func accessibilityLabel(file: ChangesFile, comments: Int) -> String {
        var parts = [file.displayPath]
        if let oldPath = file.oldPath { parts.append("renamed from \(oldPath)") }
        parts += [file.status.word, "\(file.added) added", "\(file.removed) removed"]
        if comments > 0 { parts.append("\(comments) comment\(comments == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

/// One file of the list: a button that opens its diff (and drags its `@path` out, `ChangesFileDrag`), and the "Open in editor"
/// button in its own slot at the end.
private struct ChangesFileRow: View {
    let model: CatalogModel
    let sessionID: UUID
    let line: ChangesTree.Line
    let file: ChangesFile
    let comments: Int
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button { model.selectChangesFile(file.id, in: sessionID) } label: {
                HStack(spacing: LoomTheme.Changes.fileRowGap) {
                    Text(verbatim: file.status.letter).font(LoomTheme.Changes.statusFont)
                        .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        .frame(width: LoomTheme.Changes.statusWidth).accessibilityHidden(true)
                    Text(ChangesFileText.name(line.name, oldPath: file.oldPath))
                        .font(LoomTheme.Changes.fileName).foregroundStyle(LoomTheme.Text.primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: LoomTheme.Changes.fileRowGap)
                    ChatChangeCounts(added: line.added, removed: line.removed)
                    if comments > 0 {
                        Text("\u{00B7} \(comments) comment\(comments == 1 ? "" : "s")").font(LoomTheme.Typography.caption)
                            .foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                }
                .padding(.leading, CGFloat(line.depth) * LoomTheme.Changes.fileIndent + LoomTheme.Changes.fileRowInset)
                .padding(.trailing, LoomTheme.Changes.fileRowInset)
                .frame(height: LoomTheme.Changes.fileRowHeight)
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Highlight.radiusControl))
            }
            .buttonStyle(RowButtonStyle(selected: selected, radius: LoomTheme.Highlight.radiusControl, key: "changes-file"))
            .focusEffectDisabled()
            .accessibilityLabel(ChangesFileList.accessibilityLabel(file: file, comments: comments))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .modifier(ChangesFileDragSource(model: model, sessionID: sessionID, file: file))
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: file.absolutePath)) } label: {
                InkIcon(.open, size: LoomTheme.Icon.body)
                    .frame(width: LoomTheme.Changes.openSlot, height: LoomTheme.Changes.fileRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .opacity(hovering || selected ? 1 : 0)
            .disabled(!FileManager.default.fileExists(atPath: file.absolutePath))
            .help("Open in editor")
            .accessibilityLabel("Open \(file.displayPath) in editor")
        }
        .onHover { hovering = $0 }
    }
}

/// "2 comments in 2 files", Discard and "Send to <harness>"; shown while the scope has comments. Send is there while
/// something takes the comments: a Chat session, or a live terminal run with the session channel.
private struct ChangesFooter: View {
    let model: CatalogModel
    let sessionID: UUID
    let session: SessionChanges

    var body: some View {
        let comments = session.comments(in: session.scope)
        if !comments.isEmpty {
            let files = Set(comments.map(\.anchor.fileID)).count
            let sendTitle = model.changesSendTitle(for: sessionID)
            let sending = session.sendStatus == .sending
            VStack(alignment: .leading, spacing: LoomTheme.Changes.noteGap) {
                HStack(spacing: LoomTheme.Changes.controlGap) {
                    InkIcon(.bubble, size: LoomTheme.Icon.body).foregroundStyle(LoomTheme.Accent.high)
                        .accessibilityHidden(true)
                    Text(verbatim: ChangesFooterText.summary(comments: comments.count, files: files))
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary)
                    Spacer(minLength: LoomTheme.Changes.controlGap)
                    Button("Discard") { model.discardChangeComments(in: sessionID) }
                        .buttonStyle(ControlButtonStyle(kind: .secondary)).disabled(sending)
                    if let sendTitle {
                        Button(sendTitle) { Task { await model.sendChangeComments(for: sessionID) } }
                            .buttonStyle(ControlButtonStyle(kind: .default))
                            .disabled(session.sendStatus.holdsSend)
                    }
                }
                if case let .failed(message) = session.sendStatus {
                    Text(verbatim: message).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Status.failureLight)
                } else if let line = session.sendStatus.line {
                    Text(verbatim: line).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
                } else if let note = model.changesSendNote(for: sessionID) {
                    Text(verbatim: note).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
            }
            .padding(LoomTheme.Changes.footerInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Changes.footerRadius).fill(LoomTheme.Surface.card))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Changes.footerRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
            .padding(.horizontal, LoomTheme.Changes.bodyInset)
            .padding(.bottom, LoomTheme.Changes.bodyInset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("changes-footer")
        }
    }
}
