import SwiftUI

/// The strip under the keys line (DESIGN §8 Branch strip): a centred segmented control (§6) for where the session's files are,
/// "Stay on <branch>", "New branch" or "New worktree". Either new choice asks for its name in a small popover from its segment,
/// which then shows the name; a click on it opens the popover again. Git runs only at the first send.
struct BranchStrip: View {
    let model: CatalogModel
    let projectID: UUID?
    private let openState = InkOpenState.shared

    private var draft: SessionDraft { model.newSession.draft(for: projectID) ?? SessionDraft(projectID: projectID) }

    var body: some View {
        let segments = DraftWords.segments(
            hasProject: projectID != nil, branch: model.newSession.branch(for: projectID), chosen: draft.branchKind,
            name: model.draftBranchName(draft))
        let spot = InkOpeners.placement(.branchName, onDraft: true) ?? InkOpeners.Spot(side: .below, alignment: .leading)
        HStack(spacing: LoomTheme.Draft.segmentGap) {
            ForEach(segments, id: \.kind) { segment in
                StripSegment(segment: segment) { choose(segment.kind) }
                    .inkPopover(isPresented: open(segment.kind), id: "draft-branch-name", label: branchPopoverLabel(segment.kind),
                                side: spot.side, alignment: spot.alignment) {
                        BranchNamePopover(model: model, projectID: projectID, kind: segment.kind) { openState.draft = nil }
                    }
            }
        }
        .padding(LoomTheme.Draft.segmentPadding)
        .background(RoundedRectangle(cornerRadius: LoomTheme.InkRadius.group).fill(LoomTheme.Surface.control))
        .frame(height: LoomTheme.InkHeight.control)
        .fixedSize()
        .disabled(projectID == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branch, \(segments.first(where: \.isChosen)?.accessibilityLabel ?? "")")
        .accessibilityIdentifier("draft-branch")
        // A popover does not outlive its page: coming back to it finds it shut.
        .onDisappear { if openState.draft?.projectID == projectID { openState.draft = nil } }
    }

    private func choose(_ kind: BranchKind) {
        let next = DraftWords.afterClick(kind)
        if draft.branchKind != next.chosen { model.setDraftBranch(next.chosen, projectID: projectID) }
        openState.draft = next.popover.map { .init(projectID: projectID, popover: .branchName($0)) }
    }

    private func open(_ kind: BranchKind) -> Binding<Bool> {
        openState.draftBinding(.branchName(kind), projectID: projectID)
    }

    private func branchPopoverLabel(_ kind: BranchKind) -> String { kind == .newWorktree ? "Worktree name" : "Branch name" }
}

/// One segment: 22 high inside the group's 2, radius 5. The chosen one is raised (Segment on, a strong hairline and a 1 pt drop).
private struct StripSegment: View {
    let segment: DraftWords.Segment
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused

    private typealias D = LoomTheme.Draft

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.InkRadius.groupInner)
        let on = enabled && segment.isEnabled
        Button(action: action) {
            HStack(spacing: D.segmentGlyphGap) {
                if segment.showsGlyph { Image(systemName: "arrow.triangle.branch").font(D.segmentGlyph) }
                Text(segment.title).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: segment.showsGlyph ? D.segmentStayMaxWidth : nil)
                if let name = segment.name {
                    Text(name).draftType(D.segmentName).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: D.segmentNameMaxWidth)
                        .foregroundStyle(segment.reason == nil ? AnyShapeStyle(LoomTheme.Text.secondaryStyle)
                                         : AnyShapeStyle(LoomTheme.Status.failureLight))
                        .padding(.leading, D.segmentNameGap - D.segmentGlyphGap)
                }
            }
            .draftType(D.segment)
            .foregroundStyle(segment.isChosen || (hovering && on) ? AnyShapeStyle(LoomTheme.Text.primary)
                             : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
            .padding(.horizontal, D.segmentPaddingH)
            .frame(height: LoomTheme.InkHeight.control - 2 * D.segmentPadding)
            .background {
                if segment.isChosen {
                    shape.fill(LoomTheme.Surface.segmentOn)
                        .depth(LoomTheme.Elevation.lift)
                        .overlay(shape.strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
                }
            }
            .controlFocusRing(
                visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                radius: LoomTheme.InkRadius.groupInner)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!segment.isEnabled)
        .opacity(on ? 1 : LoomTheme.Opacity.disabled)
        .onHover { hovering = $0 }
        .help(segment.reason ?? segment.help)
        .accessibilityLabel(segment.accessibilityLabel)
        .accessibilityValue(segment.reason ?? "")
        .accessibilityAddTraits(segment.isChosen ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var identifier: String {
        switch segment.kind {
        case .stay: "draft-branch-stay"
        case .newBranch: "draft-branch-new-branch"
        case .newWorktree: "draft-branch-new-worktree"
        }
    }
}

/// The name of the branch or worktree a new choice creates, in a small popover from its segment. A name Git would refuse says
/// why and keeps Send off (`canSendDraft`); closing the popover keeps the name, and the segment shows it.
private struct BranchNamePopover: View {
    let model: CatalogModel
    let projectID: UUID?
    let kind: BranchKind
    let close: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    private var draft: SessionDraft { model.newSession.draft(for: projectID) ?? SessionDraft(projectID: projectID) }
    private var suggestion: String { NewSessionBranchNames.suggest(text: draft.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Draft.popoverGap) {
            InkField(focused: focused, hasError: DraftWords.nameReason(model.draftBranchName(draft)) != nil) {
                TextField(kind == .newWorktree ? "Worktree name" : "Branch name", text: $name, prompt: Text(suggestion))
                    .font(LoomTheme.TypeScale.mono)
                    .focused($focused)
                    .onSubmit { commit(); close() }
                    .onChange(of: name) { _, value in commit(value) }
                    .accessibilityIdentifier("draft-branch-name")
            }
            if let reason = DraftWords.nameReason(model.draftBranchName(draft)) {
                Text(reason).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.OnPopover.failure)
            }
            Text(DraftWords.createsAtStart)
                .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.OnPopover.placeholder)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LoomTheme.Draft.popoverPadding)
        .frame(width: NewSessionLayout.popoverWidth)
        .onAppear {
            name = draft.branchName ?? ""
            focused = true
        }
    }

    private func commit() { commit(name) }

    private func commit(_ value: String) { model.setDraftBranch(draft.branchKind, name: value, projectID: projectID) }
}
