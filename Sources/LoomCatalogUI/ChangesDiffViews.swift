import AppKit
import LoomCore
import SwiftUI

/// The lines of one file's diff as the card draws them: a header for each hunk, then its rows. Each row knows the anchor a
/// comment on it would have, and whether the comments of that anchor are drawn under it (the first row with that anchor
/// only: two edits of one file can show the same line twice).
enum ChangesDiffLayout {
    struct Item: Equatable {
        enum Kind: Equatable {
            case hunkHeader(String)
            case row(DiffRow)
        }

        var kind: Kind
        /// Nil for a header and for a note line.
        var anchor: ChangeAnchor?
        var showsComments: Bool
    }

    /// The items of `hunks` for the file `fileID`.
    static func items(of hunks: [DiffHunk], fileID: String) -> [Item] {
        var items: [Item] = []
        var seen = Set<ChangeAnchor>()
        for hunk in hunks {
            if hunk.isNumbered { items.append(Item(kind: .hunkHeader(hunk.header), anchor: nil, showsComments: false)) }
            for row in hunk.rows {
                var row = row
                row.text = ChatDiff.clipped(row.text)
                guard row.kind != .note else {
                    items.append(Item(kind: .row(row), anchor: nil, showsComments: false))
                    continue
                }
                let removed = row.kind == .removed
                let anchor = ChangeAnchor(fileID: fileID, line: removed ? row.oldNumber : row.newNumber, removed: removed, text: row.text)
                items.append(Item(kind: .row(row), anchor: anchor, showsComments: seen.insert(anchor).inserted))
            }
        }
        return items
    }

    /// Comments whose line is not in the diff any more (the file changed since): they stay in the draft and are drawn
    /// after the lines.
    static func orphans(_ comments: [ChangeComment], in items: [Item]) -> [ChangeComment] {
        let anchors = Set(items.compactMap(\.anchor))
        return comments.filter { !anchors.contains($0.anchor) }
    }
}

/// The open file's diff in a code card: its path and "Open in editor", then the unified diff with a gutter of old and new
/// line numbers and a band on each changed line, or the reason there is no diff to draw.
struct ChangesDiffCard: View {
    enum Content: Equatable {
        case loading
        case hunks([DiffHunk])
        case binary
        case tooLarge
        case timedOut
        case failed(String)
    }

    let model: CatalogModel
    let sessionID: UUID
    let file: ChangesFile
    let content: Content
    let comments: [ChangeComment]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
            bodyView
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Changes.cardRadius).fill(LoomTheme.Changes.cardFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Changes.cardRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Changes.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("changes-diff")
    }

    private var header: some View {
        HStack(spacing: LoomTheme.Changes.fileRowGap) {
            Image(systemName: "doc.text").font(LoomTheme.Changes.fileGlyph).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .accessibilityHidden(true)
            Text(verbatim: file.displayPath).font(LoomTheme.Changes.fileName).foregroundStyle(LoomTheme.Text.primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: LoomTheme.Changes.fileRowGap)
            ChangesOpenInEditor(path: file.absolutePath)
        }
        .padding(.horizontal, LoomTheme.Changes.cardHeaderInset)
        .frame(height: LoomTheme.Changes.cardHeaderHeight)
        // The header drags the file's `@path` out, as its row in the list does.
        .contentShape(Rectangle())
        .modifier(ChangesFileDragSource(model: model, sessionID: sessionID, file: file))
    }

    @ViewBuilder private var bodyView: some View {
        switch content {
        case .loading:
            ChangesNote(text: "Reading the diff", busy: true)
        case .binary:
            ChangesNote(text: "Binary file")
        case .tooLarge:
            ChangesNote(text: "Too large to show here", openPath: file.absolutePath)
        case .timedOut:
            ChangesNote(text: "Git did not answer", retry: { model.retryChangesFile(file.id, in: sessionID) })
        case let .failed(message):
            ChangesNote(text: "The diff could not be read. \(message)", retry: { model.retryChangesFile(file.id, in: sessionID) })
        case let .hunks(hunks):
            if hunks.isEmpty {
                ChangesNote(text: "No line changes")
            } else {
                let items = ChangesDiffLayout.items(of: hunks, fileID: file.id)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        ChangesDiffItemView(model: model, sessionID: sessionID, item: item, comments: comments)
                    }
                    ForEach(ChangesDiffLayout.orphans(comments, in: items)) { comment in
                        ChangesCommentBox(model: model, sessionID: sessionID, anchor: comment.anchor, saved: comment,
                                          label: "Line changed since")
                    }
                }
                .padding(.vertical, LoomTheme.Changes.textInset)
            }
        }
    }
}

/// A hunk header or a line of the diff, with the comment under it.
private struct ChangesDiffItemView: View {
    let model: CatalogModel
    let sessionID: UUID
    let item: ChangesDiffLayout.Item
    let comments: [ChangeComment]

    var body: some View {
        switch item.kind {
        case let .hunkHeader(text):
            Text(verbatim: text).font(LoomTheme.Changes.hunkHeaderFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .frame(maxWidth: .infinity, minHeight: LoomTheme.Changes.hunkHeaderHeight, alignment: .leading)
                .padding(.leading, LoomTheme.Changes.numberWidth * 2 + LoomTheme.Changes.signWidth)
                .accessibilityLabel("Hunk \(text)")
        case let .row(row):
            VStack(alignment: .leading, spacing: 0) {
                ChangesDiffRowView(row: row, anchor: item.anchor) {
                    if let anchor = item.anchor { model.beginChangeComment(at: anchor, in: sessionID) }
                }
                if item.showsComments, let anchor = item.anchor {
                    let session = model.changes.session(for: sessionID)
                    let saved = comments.first { $0.anchor == anchor }
                    if session.composing == anchor || saved != nil {
                        ChangesCommentBox(model: model, sessionID: sessionID, anchor: anchor, saved: saved, label: nil)
                    }
                }
            }
        }
    }
}

/// One line: old and new number, sign, text, on a band when the line changed. A click on it, or the "+" that shows in its
/// gutter under the pointer, opens the comment box.
private struct ChangesDiffRowView: View {
    let row: DiffRow
    let anchor: ChangeAnchor?
    let comment: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(row.oldNumber)
            gutter(row.newNumber)
            Text(verbatim: sign).font(LoomTheme.Changes.diffFont).foregroundStyle(signStyle)
                .frame(width: LoomTheme.Changes.signWidth, alignment: .center)
                .accessibilityHidden(true)
            Text(verbatim: row.text.isEmpty ? " " : row.text).font(LoomTheme.Changes.diffFont)
                .foregroundStyle(row.kind == .note ? AnyShapeStyle(LoomTheme.Text.secondaryStyle) : AnyShapeStyle(LoomTheme.Text.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, LoomTheme.Changes.textInset)
        }
        .frame(minHeight: LoomTheme.Changes.rowMinHeight, alignment: .top)
        .background(band)
        .overlay(alignment: .leading) {
            if hovering, anchor != nil {
                Image(systemName: "plus").font(LoomTheme.Changes.addGlyph).foregroundStyle(LoomTheme.Accent.onAccent)
                    .frame(width: LoomTheme.Changes.addButtonSize, height: LoomTheme.Changes.addButtonSize)
                    .background(RoundedRectangle(cornerRadius: LoomTheme.Changes.addButtonRadius).fill(LoomTheme.Accent.base))
                    .padding(.leading, LoomTheme.Changes.textInset)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if anchor != nil { comment() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(anchor == nil ? [] : .isButton)
        .accessibilityAction(named: "Add comment") { if anchor != nil { comment() } }
    }

    private func gutter(_ number: Int?) -> some View {
        Text(verbatim: number.map(String.init) ?? "").font(LoomTheme.Changes.gutterFont)
            .foregroundStyle(LoomTheme.Text.tertiaryStyle).monospacedDigit()
            .frame(width: LoomTheme.Changes.numberWidth, alignment: .trailing)
            .padding(.trailing, LoomTheme.Changes.textInset)
            .accessibilityHidden(true)
    }

    private var sign: String {
        switch row.kind {
        case .added: "+"
        case .removed: "\u{2212}"
        case .context, .note: ""
        }
    }

    private var signStyle: Color { row.kind == .added ? LoomTheme.Changes.addedSign : LoomTheme.Changes.removedSign }

    @ViewBuilder private var band: some View {
        switch row.kind {
        case .added: LoomTheme.Changes.addedBand
        case .removed: LoomTheme.Changes.removedBand
        case .context, .note: Color.clear
        }
    }

    private var accessibilityLabel: String {
        let kind = switch row.kind {
        case .added: "Added"
        case .removed: "Removed"
        case .context: "Unchanged"
        case .note: "Note"
        }
        let line = (anchor?.line).map { ", line \($0)" } ?? ""
        return "\(kind)\(line): \(row.text)"
    }
}

/// The inline box under a line: the draft being written ("Your comment · line N"), or the saved comment with Edit and Remove.
struct ChangesCommentBox: View {
    let model: CatalogModel
    let sessionID: UUID
    let anchor: ChangeAnchor
    let saved: ChangeComment?
    /// Replaces "Your comment · line N" for a comment whose line left the diff.
    let label: String?
    @FocusState private var focused: Bool

    var body: some View {
        let session = model.changes.session(for: sessionID)
        let editing = session.composing == anchor
        VStack(alignment: .leading, spacing: LoomTheme.Changes.commentGap) {
            HStack(spacing: LoomTheme.Changes.commentGap) {
                Image(systemName: "text.bubble").font(LoomTheme.Changes.commentGlyph).accessibilityHidden(true)
                Text(verbatim: title).font(LoomTheme.Typography.caption)
                Spacer(minLength: 0)
                if !editing, let saved {
                    Button("Edit") { model.beginChangeComment(at: anchor, in: sessionID) }
                        .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                    Button("Remove") { model.removeChangeComment(at: anchor, in: sessionID) }
                        .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                        .accessibilityLabel("Remove comment on \(saved.displayPath)")
                }
            }
            .foregroundStyle(LoomTheme.Text.secondaryStyle)
            if editing {
                TextField("Comment for Claude", text: Binding(get: { session.composingText }, set: { session.composingText = $0 }),
                          axis: .vertical)
                    .textFieldStyle(.plain).font(LoomTheme.Typography.small)
                    .lineLimit(1...LoomTheme.Changes.commentLines)
                    .focused($focused)
                    .onSubmit { model.saveChangeComment(in: sessionID) }
                    .accessibilityLabel("Comment on \(title)")
                HStack(spacing: LoomTheme.Changes.commentGap) {
                    Spacer(minLength: 0)
                    Button("Cancel") { model.cancelChangeComment(in: sessionID) }.buttonStyle(ControlButtonStyle(kind: .ghost))
                    Button("Add comment") { model.saveChangeComment(in: sessionID) }.buttonStyle(ControlButtonStyle(kind: .default))
                        .disabled(session.composingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if let saved {
                Text(verbatim: saved.text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
        .padding(LoomTheme.Changes.commentInset)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Changes.commentRadius).fill(LoomTheme.Changes.commentFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Changes.commentRadius).strokeBorder(LoomTheme.Changes.commentStroke))
        .padding(.leading, LoomTheme.Changes.numberWidth * 2 + LoomTheme.Changes.signWidth)
        .padding(.trailing, LoomTheme.Changes.commentInset)
        .padding(.vertical, LoomTheme.Changes.commentOuterV)
        .onAppear { if editing { focused = true } }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if let label { return label }
        return anchor.line.map { "Your comment \u{00B7} line \($0)" } ?? "Your comment"
    }
}

/// "Open in editor": the file in the app macOS opens it with. Nothing opens many files at once.
struct ChangesOpenInEditor: View {
    let path: String

    var body: some View {
        Button("Open in editor") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            .buttonStyle(ControlButtonStyle(kind: .link, size: .small))
            .disabled(!FileManager.default.fileExists(atPath: path))
            .accessibilityLabel("Open \((path as NSString).lastPathComponent) in editor")
    }
}

/// One quiet line in the card: a state, with the actions that fit it.
struct ChangesNote: View {
    let text: String
    var busy = false
    var openPath: String?
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: LoomTheme.Changes.stateGap) {
            if busy { ProgressView().controlSize(.small) }
            Text(verbatim: text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
            if let retry { Button("Try Again", action: retry).buttonStyle(ControlButtonStyle(kind: .link, size: .small)) }
            if let openPath { ChangesOpenInEditor(path: openPath) }
            Spacer(minLength: 0)
        }
        .padding(LoomTheme.Changes.cardHeaderInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
