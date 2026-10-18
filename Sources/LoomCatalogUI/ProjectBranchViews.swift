import Foundation
import LoomCore
import SwiftUI

/// How many of the listed sessions work on each branch, by the branch their folder has checked out now.
enum ProjectBranchUse {
    static func counts(records: [CatalogSession], branches: [String: GitBranch]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in records {
            if case .named(let name) = branches[record.session.workingDirectory] { counts[name, default: 0] += 1 }
        }
        return counts
    }
}

/// The Branches tab: the repository's local branches, read from its `.git` files when the page opened.
struct ProjectBranchesTab: View {
    let model: CatalogModel

    var body: some View {
        let page = model.projectPage
        VStack(alignment: .leading, spacing: 0) {
            if let branches = page.branches {
                let counts = ProjectBranchUse.counts(records: page.records, branches: model.branches)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(branches.branches.enumerated()), id: \.element.id) { index, branch in
                        if index > 0 {
                            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                        }
                        ProjectBranchRow(branch: branch, sessions: counts[branch.name] ?? 0, now: model.now)
                    }
                }
                if branches.truncated {
                    Text("Only the first \(branches.branches.count) branches are listed.")
                        .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .padding(.top, LoomTheme.ProjectPage.cardGap)
                }
            } else if page.branchesLoad == .loading {
                note("Reading branches\u{2026}")
            } else {
                note("This folder is not in a Git repository, or its branches could not be read.")
            }
        }
        .frame(maxWidth: LoomTheme.ProjectPage.instructionsMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branches")
        .accessibilityIdentifier("project-branches")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .padding(LoomTheme.ProjectPage.noticePadding)
            .accessibilityIdentifier("project-branches-note")
    }
}

private struct ProjectBranchRow: View {
    let branch: ProjectBranch
    let sessions: Int
    let now: Date

    var body: some View {
        HStack(spacing: LoomTheme.ProjectPage.rowColumnGap) {
            Image(systemName: "arrow.triangle.branch").font(LoomTheme.ProjectPage.cardRowGlyph)
                .foregroundStyle(LoomTheme.Text.secondaryStyle)
                .frame(width: LoomTheme.Layout.indicatorSlot.width)
            Text(branch.name).font(LoomTheme.ProjectPage.branchNameFont)
                .foregroundStyle(branch.isCurrent ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                .lineLimit(1).truncationMode(.middle)
            if branch.isCurrent {
                Text("current").font(LoomTheme.Typography.statusLabel).foregroundStyle(LoomTheme.Accent.high)
            } else if let worktree = branch.worktree {
                Text("worktree " + (worktree as NSString).abbreviatingWithTildeInPath)
                    .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            if sessions > 0 {
                Text(sessions == 1 ? "1 session" : "\(sessions) sessions")
                    .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            if let updated = branch.updated {
                Text(RelativeTime.string(from: updated, to: now)).font(LoomTheme.ProjectPage.rowTime)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(width: LoomTheme.ProjectPage.rowTimeWidth, alignment: .trailing)
            }
        }
        .frame(minHeight: LoomTheme.ProjectPage.branchRowHeight)
        .padding(.horizontal, LoomTheme.ProjectPage.rowPaddingH)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([branch.name, branch.isCurrent ? "current" : nil, branch.worktree.map { _ in "in a worktree" },
                             sessions > 0 ? "\(sessions) sessions" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("project-branch-row")
    }
}

/// The Instructions tab: the project's CLAUDE.md, read-only.
struct ProjectInstructionsTab: View {
    let page: ProjectPageState
    @State private var flags: Set<String> = []
    @State private var context = ChatRowContext()

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.ProjectPage.cardGap) {
            if let instructions = page.instructions {
                HStack(spacing: LoomTheme.Space.chipInset) {
                    Image(systemName: "book").font(LoomTheme.ProjectPage.cardRowGlyph)
                    Text(instructions.name).font(LoomTheme.ProjectPage.branchNameFont)
                    Text(meta(instructions)).font(LoomTheme.Typography.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(LoomTheme.Text.secondaryStyle)
                .accessibilityElement(children: .combine)
                ChatMarkdownView(blocks: instructions.blocks, flags: flags, rowID: "project-instructions", context: context)
                    .padding(LoomTheme.ProjectPage.instructionsPadding)
                    .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.card).fill(LoomTheme.Surface.card))
                    .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.card)
                        .strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
                    .accessibilityIdentifier("project-claude-md")
                if instructions.truncated {
                    Text("Showing the first \(Self.size(ProjectInstructionsReader.maxBytes)) of \(Self.size(instructions.byteCount)). "
                         + "Open the file to read the rest.")
                        .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .accessibilityIdentifier("project-claude-md-truncated")
                }
            } else if page.instructionsLoad == .loading {
                note("Reading CLAUDE.md\u{2026}")
            } else {
                note("This project has no CLAUDE.md. Claude reads one from the project folder when it starts a session there.")
            }
        }
        .frame(maxWidth: LoomTheme.ProjectPage.instructionsMaxWidth, alignment: .leading)
        .onAppear { context.toggleFlag = { _, flag in
            if flags.contains(flag) { flags.remove(flag) } else { flags.insert(flag) }
        } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Instructions")
        .accessibilityIdentifier("project-instructions")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .padding(LoomTheme.ProjectPage.noticePadding)
            .accessibilityIdentifier("project-instructions-note")
    }

    private func meta(_ instructions: ProjectInstructions) -> String {
        var parts: [String] = []
        if let lines = instructions.lineCount { parts.append(lines == 1 ? "1 line" : "\(lines) lines") }
        else { parts.append(Self.size(instructions.byteCount)) }
        if let modified = instructions.modified {
            let age = RelativeTime.string(from: modified, to: Date())
            parts.append(age == "now" ? "changed just now" : "changed \(age) ago")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_024 ? "\((bytes + 512) / 1_024) KB" : "\(bytes) bytes"
    }
}
