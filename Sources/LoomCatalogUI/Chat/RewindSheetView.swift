import LoomChat
import SwiftUI

/// "Rewind files to before this message?" (V21): the dry run is the confirmation. Paths relative to the working folder with
/// the totals, a warning on each file Claude did not leave as it is, the honest label, and Cancel and "Rewind files". Cancel
/// is the default (Esc); Return never confirms.
struct RewindSheetView: View {
    let model: CatalogModel
    let sheet: RewindSheetState
    @FocusState private var focus: Field?

    private enum Field { case cancel }

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sheetSpacing) {
            Text(RewindCopy.title).font(LoomTheme.Typography.title)
            if !sheet.title.isEmpty {
                Text("\u{201C}\(sheet.title)\u{201D}").font(LoomTheme.Typography.bodyStrong)
                    .foregroundStyle(LoomTheme.Text.primary).lineLimit(2).truncationMode(.tail)
            }
            phase
            HStack {
                Spacer()
                Button("Cancel") { model.cancelRewind() }
                    .keyboardShortcut(.cancelAction)
                    .focused($focus, equals: .cancel)
                    .disabled(!sheet.canCancel)
                    .accessibilityIdentifier("rewind-cancel")
                Button("Rewind files") { Task { await model.confirmRewind() } }
                    .buttonStyle(AccentButtonStyle(kind: .tinted))
                    .disabled(!sheet.canConfirm)
                    .accessibilityIdentifier("rewind-confirm")
            }
        }
        .padding(LoomTheme.Space.sheetPadding)
        .frame(width: LoomTheme.Rewind.sheetWidth)
        .tint(LoomTheme.Accent.base)
        .defaultFocus($focus, .cancel)
        .onKeyPress(phases: .down) { press in
            switch RewindSheetKeys.reaction(to: press.key) {
            case .cancel:
                guard sheet.canCancel else { return .handled }
                model.cancelRewind()
                return .handled
            case .swallow: return .handled
            case .ignore: return .ignored
            }
        }
        .accessibilityIdentifier("rewind-sheet")
    }

    @ViewBuilder private var phase: some View {
        switch sheet.phase {
        case .loading:
            HStack(spacing: LoomTheme.Space.headerSpacing) {
                ProgressView().controlSize(.small)
                Text("Checking what would change\u{2026}").foregroundStyle(LoomTheme.Text.secondary)
            }
            .font(LoomTheme.Typography.small)
        case .rewinding:
            HStack(spacing: LoomTheme.Space.headerSpacing) {
                ProgressView().controlSize(.small)
                Text("Rewinding\u{2026}").foregroundStyle(LoomTheme.Text.secondary)
            }
            .font(LoomTheme.Typography.small)
        case let .ready(content):
            ready(content)
        case let .cannot(text), let .failed(text):
            Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.failure)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ready(_ content: RewindSheetContent) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.Rewind.noteGap) {
            if content.files.isEmpty {
                note(RewindCopy.nothingToChange, color: LoomTheme.Text.secondary)
            } else {
                HStack {
                    Text(content.files.count == 1 ? "1 file" : "\(content.files.count) files")
                        .font(LoomTheme.Typography.smallMedium)
                    Spacer()
                    Text(content.totals).font(LoomTheme.Typography.mono).foregroundStyle(LoomTheme.Text.secondary)
                }
                files(content)
            }
            if let problem = RewindCopy.copyProblem(content.copy) { note(problem, color: LoomTheme.Status.failure) }
            note(RewindCopy.honestLabel, color: LoomTheme.Text.secondary)
            if content.newestTurn { note(RewindCopy.newestTurnNote, color: LoomTheme.Status.attention) }
        }
    }

    private func files(_ content: RewindSheetContent) -> some View {
        // A long list scrolls inside its box; a short one is as tall as it is.
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(content.files) { file in
                HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Rewind.fileRowGap) {
                    Text(file.displayPath).font(LoomTheme.Typography.mono).foregroundStyle(LoomTheme.Text.primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let mark = file.mark {
                        Text(mark.text).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Status.attention)
                            .lineLimit(1).layoutPriority(1)
                    }
                }
                .padding(.vertical, LoomTheme.Rewind.fileRowPadding)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(LoomTheme.Rewind.listInset)
        return Group {
            if content.files.count > LoomTheme.Rewind.scrollAbove {
                ScrollView { rows }.frame(height: LoomTheme.Rewind.fileListMaxHeight)
            } else {
                rows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Rewind.listRadius).fill(LoomTheme.Surface.control))
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text).font(LoomTheme.Typography.small).foregroundStyle(color)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
