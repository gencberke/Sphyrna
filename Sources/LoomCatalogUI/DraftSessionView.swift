import AppKit
import LoomCore
import SwiftUI

/// A project's new-session draft (V07, D-59; DESIGN §8): an empty page with one question, "What should we work on in
/// [project]?", whose project is the picker, the folder line, the session's composer, the keys line, the branch strip and the
/// presets with Remora's brief row (D-80), on the faint radial grid. Nothing runs until the first send; `DetailContent` draws it
/// for `.draft`.
struct DraftSessionView: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        let origin = model.draftRemoraOriginLine(projectID: projectID)
        ZStack {
            CanvasGrid(mask: .radial)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Headline(model: model, projectID: projectID)
                    // Where the composer's text came from, while it is Remora's brief (DESIGN §8 Remora's brief).
                    if let origin {
                        DraftRemoraOriginView(model: model, projectID: projectID, line: origin)
                            .frame(maxWidth: NewSessionLayout.composerWidth)
                            .padding(.top, LoomTheme.Draft.originTop)
                    }
                    NewSessionComposer(model: model, projectID: projectID)
                        .frame(maxWidth: NewSessionLayout.composerWidth)
                        .padding(.top, origin == nil ? NewSessionLayout.composerTop : LoomTheme.Draft.originComposerGap)
                    DraftKeysLine()
                        .padding(.top, NewSessionLayout.keysTop)
                    BranchStrip(model: model, projectID: projectID)
                        .padding(.top, NewSessionLayout.stripTop)
                    PresetRow(model: model, projectID: projectID)
                    DraftSourceNote(model: model, projectID: projectID)
                    // Remora's brief row (DESIGN §8, D-80), 18 under the presets' line.
                    DraftRemoraRowView(model: model, projectID: projectID)
                }
                .frame(maxWidth: NewSessionLayout.column)
                .padding(.horizontal, NewSessionLayout.sideInset)
                Spacer(minLength: 0)
            }
            .padding(.bottom, NewSessionLayout.bottomLift)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One page per project: a draft of another project starts from a fresh field, strip and focus.
        .id(projectID?.uuidString ?? "none")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draft-session")
        .onAppear {
            model.prepareNewSession()
            model.newSession.open(projectID: projectID)
            model.loadDraftBranch(projectID: projectID)
            model.landRemoraDraft()
        }
        // A brief that answered lands in its project's draft once, by Put in Draft's rule; nothing is sent.
        .onChange(of: model.remora.draft) { _, _ in model.landRemoraDraft() }
    }
}

/// "What should we work on in [project ▾]?" in display type, and under it the folder line. The project's name is the picker,
/// underlined in its tone.
struct Headline: View {
    let model: CatalogModel
    let projectID: UUID?
    @State private var hoversPick = false

    private typealias D = LoomTheme.Draft

    private var project: CatalogProject? { model.draftProject(projectID) }

    var body: some View {
        VStack(spacing: NewSessionLayout.folderTop) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    lead.fixedSize()
                    picker.padding(.leading, D.questionWordGap)
                    questionMark
                }
                // Too narrow for one line: the question mark stays with the picker, never alone on a line.
                twoRows(shrinksLead: false)
                // Narrower than the first line of the two rows: it shrinks rather than wrapping into a third row.
                twoRows(shrinksLead: true)
            }
            folderLine
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .contain)
    }

    private func twoRows(shrinksLead: Bool) -> some View {
        VStack(spacing: D.questionRowGap) {
            if shrinksLead {
                lead.lineLimit(1).minimumScaleFactor(D.questionShrink)
            } else {
                lead.fixedSize()
            }
            HStack(spacing: 0) { picker; questionMark }
        }
    }

    private var lead: some View {
        Text("What should we work on in").draftType(D.question).foregroundStyle(LoomTheme.Text.primary)
    }

    private var questionMark: some View {
        Text("?").draftType(D.question).foregroundStyle(LoomTheme.Text.primary)
    }

    private var folderLine: some View {
        let folder = DraftWords.folder(
            projectPath: project?.path, branch: project.flatMap { model.newSession.branch(for: $0.id) })
        return HStack(spacing: D.folderGap) {
            Text(folder.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if let branch = folder.branch {
                Text("\u{00B7}")
                Text(branch).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            }
        }
        .draftType(D.folder).foregroundStyle(LoomTheme.Text.tertiaryStyle)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("draft-folder")
    }

    private var picker: some View {
        let tone = model.projectTone(forProject: projectID)
        return Menu {
            ForEach(model.projects) { entry in
                Button {
                    model.chooseDraftProject(entry.id, from: projectID)
                } label: {
                    if entry.id == projectID { Label(entry.name, systemImage: "checkmark") } else { Text(entry.name) }
                }
            }
            Divider()
            Button {
                model.chooseDraftProject(nil, from: projectID)
            } label: {
                if projectID == nil { Label("No project", systemImage: "checkmark") } else { Text("No project") }
            }
        } label: {
            HStack(spacing: D.chevronGap) {
                Text(project?.name ?? "no project").draftType(D.question).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: D.pickMaxWidth)
                Image(systemName: "chevron.down").font(D.chevronFont)
                    .foregroundStyle(hoversPick ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.tertiaryStyle))
                    .frame(width: D.chevronBox, height: D.chevronBox)
                    .offset(y: D.chevronDrop)
            }
            .foregroundStyle(LoomTheme.Text.primary)
            .padding(.bottom, D.underlineGap)
            .overlay(alignment: .bottom) {
                Rectangle().fill(D.underline(tone)).frame(height: D.underlineThickness).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hoversPick = $0 }
        .accessibilityLabel("Project, \(project?.name ?? "none")")
        .accessibilityIdentifier("draft-project")
    }
}

/// The keys under the composer (DESIGN §8 Keys): mono 11 tertiary, the key in secondary 500, 18 apart, centred.
struct DraftKeysLine: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(spacing: LoomTheme.Draft.keysGap, vertical: false)
            line(spacing: LoomTheme.Composer.hintRowGap, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DraftWords.keys.joined(separator: ", "))
        .accessibilityIdentifier("draft-keys")
    }

    private func line(spacing: CGFloat, vertical: Bool) -> some View {
        let keys = ForEach(DraftWords.keys, id: \.self) { hint in
            let (key, words) = ComposerHints.split(hint)
            HStack(spacing: LoomTheme.Draft.keyWordsGap) {
                Text(key).foregroundStyle(LoomTheme.Text.secondaryStyle).fontWeight(.medium)
                Text(words)
            }
        }
        return Group {
            if vertical { VStack(spacing: spacing) { keys } } else { HStack(spacing: spacing) { keys } }
        }
        .draftType(LoomTheme.Draft.keys).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1).fixedSize()
        .frame(maxWidth: .infinity)
    }
}
