import AppKit
import LoomCore
import SwiftUI

/// A project's new-session draft (V07, D-59, design/v2-new-session-preview.html N1): an empty page with one
/// question, "What should we work on in [project]?", whose project is the picker, the session's composer, and
/// under it one strip for the branch. Nothing runs until the first send; `DetailContent` draws it for `.draft`.
struct DraftSessionView: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: LoomTheme.Space.detailSectionSpacing) {
                Headline(model: model, projectID: projectID)
                VStack(spacing: LoomTheme.Space.requestListSpacing + LoomTheme.Space.headerSpacing) {
                    NewSessionComposer(model: model, projectID: projectID)
                    BranchStrip(model: model, projectID: projectID)
                    PresetRow(model: model, projectID: projectID)
                }
            }
            .frame(maxWidth: NewSessionLayout.column)
            .padding(.horizontal, NewSessionLayout.sideInset)
            Spacer(minLength: 0)
        }
        .padding(.bottom, NewSessionLayout.bottomLift)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One page per project: a draft of another project starts from a fresh field, strip and focus.
        .id(projectID?.uuidString ?? "none")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("draft-session")
        .onAppear {
            model.prepareNewSession()
            model.newSession.open(projectID: projectID)
            model.loadDraftBranch(projectID: projectID)
        }
    }
}

/// "What should we work on in [project ▾]?" The project name is a picker; its tone is the stripe of the chip.
struct Headline: View {
    let model: CatalogModel
    let projectID: UUID?

    private var project: CatalogProject? { model.draftProject(projectID) }

    var body: some View {
        VStack(spacing: LoomTheme.Space.headerSpacing * 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: LoomTheme.Space.hintSpacing) { lead; picker; questionMark }
                // Too narrow for one line: the question mark stays with the picker, never alone on a line.
                VStack(spacing: LoomTheme.Space.hintSpacing) {
                    lead
                    HStack(spacing: LoomTheme.Space.hintSpacing) { picker; questionMark }
                }
            }
            Text(folderLine).font(LoomTheme.Typography.body).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .contain)
    }

    private var lead: some View {
        Text("What should we work on in").font(LoomTheme.TypeScale.display).foregroundStyle(LoomTheme.Text.primary)
            .fixedSize()
    }

    private var questionMark: some View {
        Text("?").font(LoomTheme.TypeScale.display).foregroundStyle(LoomTheme.Text.primary)
    }

    private var folderLine: String {
        if let project { return "Claude starts in " + Self.abbreviated(project.path) }
        return "Claude starts in your home folder"
    }

    static func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

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
            HStack(spacing: LoomTheme.Space.chipInset) {
                if let tone {
                    RoundedRectangle(cornerRadius: LoomTheme.ProjectColor.stripeRadius)
                        .fill(LoomTheme.ProjectColor.stripe(tone))
                        .frame(width: NewSessionLayout.toneStripe.width, height: NewSessionLayout.toneStripe.height)
                        .accessibilityHidden(true)
                }
                Text(project?.name ?? "no project").font(LoomTheme.TypeScale.display).lineLimit(1)
                Image(systemName: "chevron.down").font(LoomTheme.Typography.chevron)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            .foregroundStyle(LoomTheme.Text.primary)
            .padding(.horizontal, LoomTheme.Space.requestPadding).frame(minHeight: NewSessionLayout.headlinePickHeight)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.lg).fill(LoomTheme.Surface.control))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.lg)
                .strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.lg))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Project, \(project?.name ?? "none")")
        .accessibilityIdentifier("draft-project")
    }
}

/// The strip under the composer: where the session's files are (stay on the branch, a new branch, a new
/// worktree), what the mode and model came from, and Save as preset once there is text.
private struct BranchStrip: View {
    let model: CatalogModel
    let projectID: UUID?
    @State private var showsChoices = false

    private var draft: SessionDraft { model.newSession.draft(for: projectID) ?? SessionDraft(projectID: projectID) }
    private var branch: GitBranch? { model.newSession.branch(for: projectID) }
    /// A folder with no Git branch has nothing to branch from.
    private var canBranch: Bool { projectID != nil && (branch.map { $0 != .unavailable } ?? false) }

    var body: some View {
        HStack(spacing: NewSessionLayout.chipSpacing) {
            Button { showsChoices.toggle() } label: {
                HStack(spacing: NewSessionLayout.chipSpacing) {
                    Image(systemName: "arrow.triangle.branch").font(LoomTheme.Typography.small)
                    // Cut at the end: the start of a worktree or branch name is what identifies it.
                    Text(chipText).font(LoomTheme.Typography.smallMedium).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(LoomTheme.Typography.chevron)
                        .foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
            }
            .buttonStyle(ChipButtonStyle(emphasized: showsChoices || draft.branchKind != .stay))
            .disabled(projectID == nil)
            .popover(isPresented: $showsChoices, arrowEdge: .bottom) {
                BranchChoices(model: model, projectID: projectID, canBranch: canBranch)
            }
            .help(draft.branchKind == .stay ? "Where the session starts: this branch, a new branch or a new worktree"
                  : chipText)
            .accessibilityLabel("Branch, \(chipText)")
            .accessibilityIdentifier("draft-branch")
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            if let note = sourceNote {
                Text(note).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.tertiary).lineLimit(1)
            }
            if draft.isVisible {
                Button { model.savePreset(projectID: projectID) } label: {
                    Label("Save as preset", systemImage: "plus")
                }
                .buttonStyle(ChipButtonStyle()).accessibilityIdentifier("draft-save-preset")
            }
        }
        .padding(.horizontal, LoomTheme.Space.headerSpacing)
    }

    private var chipText: String {
        switch draft.branchKind {
        case .stay:
            switch branch {
            case .named(let name)?: name
            case .detached?: GitBranch.detached.label
            case .unavailable?: projectID == nil ? "No project folder" : "Not a Git folder"
            case nil: "Branch"
            }
        case .newBranch: "New branch " + model.draftBranchName(draft)
        case .newWorktree: "New worktree " + model.draftBranchName(draft)
        }
    }

    /// Where mode and model come from, when it is not the draft's own pick (the defaults of CHAT-SPEC).
    private var sourceNote: String? {
        let resolved = model.resolvedStart(for: projectID)
        let name = model.draftProject(projectID)?.name
        if resolved.mode.source == .lastUsed || resolved.model.source == .lastUsed {
            return "Mode and model as last used" + (name.map { " in \($0)" } ?? "")
        }
        if resolved.mode.source == .settings || resolved.model.source == .settings { return "Mode and model from Settings" }
        return nil
    }
}

/// The popover of the strip: three choices and the name of the branch the new ones create.
private struct BranchChoices: View {
    let model: CatalogModel
    let projectID: UUID?
    let canBranch: Bool
    @State private var name = ""

    private var draft: SessionDraft { model.newSession.draft(for: projectID) ?? SessionDraft(projectID: projectID) }
    private var current: String {
        switch model.newSession.branch(for: projectID) {
        case .named(let value)?: value
        default: "the current branch"
        }
    }
    private var suggestion: String { NewSessionBranchNames.suggest(text: draft.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.headerSpacing) {
            row(.stay, title: "Stay on \(current)", detail: nil, enabled: true)
            row(.newBranch, title: "New branch", detail: "in this folder", enabled: canBranch)
            row(.newWorktree, title: "New worktree", detail: "its own folder", enabled: canBranch)
            if draft.branchKind != .stay {
                TextField("Branch name", text: $name, prompt: Text(suggestion))
                    .textFieldStyle(.roundedBorder).font(LoomTheme.TypeScale.mono)
                    .onSubmit(commitName)
                    .onChange(of: name) { _, value in model.setDraftBranch(draft.branchKind, name: value, projectID: projectID) }
                    .accessibilityIdentifier("draft-branch-name")
                if !NewSessionBranchNames.isPlausible(model.draftBranchName(draft)) {
                    Text("That is not a valid branch name.").font(LoomTheme.Typography.caption)
                        .foregroundStyle(LoomTheme.OnPopover.failure)
                }
            }
            Text(canBranch ? "Loom creates it when the session starts, never before."
                 : "This folder is not a Git repository, so there is nothing to branch from.")
                .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.OnPopover.placeholder)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LoomTheme.Space.requestPadding + LoomTheme.Space.headerSpacing)
        .frame(width: NewSessionLayout.popoverWidth)
        .background(LoomTheme.Surface.popover)
        .onAppear { name = draft.branchName ?? "" }
    }

    private func commitName() { model.setDraftBranch(draft.branchKind, name: name, projectID: projectID) }

    private func row(_ kind: BranchKind, title: String, detail: String?, enabled: Bool) -> some View {
        Button {
            model.setDraftBranch(kind, projectID: projectID)
        } label: {
            HStack(spacing: LoomTheme.Space.chipInset) {
                Image(systemName: "checkmark").font(LoomTheme.Typography.small)
                    .opacity(draft.branchKind == kind ? 1 : 0).frame(width: LoomTheme.Layout.indicatorSlot.width)
                Text(title).font(LoomTheme.Typography.body).foregroundStyle(LoomTheme.Text.primary)
                if let detail {
                    Text("· " + detail).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.OnPopover.placeholder)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: LoomTheme.Layout.minimumHitTarget.height).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
        .accessibilityAddTraits(draft.branchKind == kind ? .isSelected : [])
    }
}

/// Saved first messages of the project, one click each: the message goes into the composer; nothing starts.
private struct PresetRow: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        let presets = model.presets(for: projectID)
        if !presets.isEmpty {
            FlowLayout(spacing: NewSessionLayout.chipSpacing) {
                ForEach(presets) { preset in
                    Button { model.applyPreset(preset, projectID: projectID) } label: {
                        Label(preset.name, systemImage: preset.permissionMode == ClaudePermissionMode.plan.rawValue ? "list.bullet.rectangle" : "play")
                            .lineLimit(1)
                    }
                    .buttonStyle(ChipButtonStyle())
                    .contextMenu { Button("Remove Preset") { model.removePreset(preset) } }
                    .help(preset.message)
                    .accessibilityIdentifier("draft-preset")
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Presets")
        }
    }
}
