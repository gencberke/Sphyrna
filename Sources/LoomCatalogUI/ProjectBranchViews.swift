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

    /// Said in place of the list for a folder outside Git, and while the branches are read.
    static let notRepository = "This folder is not in a Git repository, or its branches could not be read."
    static let reading = "Reading branches\u{2026}"

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
                        .projectType(LoomTheme.ProjectPage.cutNote).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        .padding(.top, LoomTheme.ProjectPage.cutNoteTop)
                }
            } else if page.branchesLoad == .loading {
                ProjectPageNote(text: Self.reading, identifier: "project-branches-note")
            } else {
                ProjectPageNote(text: Self.notRepository, identifier: "project-branches-note")
            }
        }
        .frame(maxWidth: LoomTheme.ProjectPage.instructionsMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Branches")
        .accessibilityIdentifier("project-branches")
    }
}

/// A line in place of a list: 12.5 secondary on 1.5, 10 above and below, 12 in.
private struct ProjectPageNote: View {
    let text: String
    let identifier: String

    var body: some View {
        Text(text).projectType(LoomTheme.ProjectPage.note).foregroundStyle(LoomTheme.Text.secondaryStyle)
            .lineSpacing(LoomTheme.ProjectPage.noteSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LoomTheme.ProjectPage.notePaddingH).padding(.vertical, LoomTheme.ProjectPage.notePaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}

/// A branch: its glyph, its name (primary and with an accent "current" for the project's own checkout), the folder of another
/// worktree that has it, then how many listed sessions work on it and when its ref last changed.
private struct ProjectBranchRow: View {
    let branch: ProjectBranch
    let sessions: Int
    let now: Date

    var body: some View {
        HStack(spacing: LoomTheme.ProjectPage.branchGap) {
            InkIcon(.branch, size: LoomTheme.Icon.body)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .frame(width: LoomTheme.ProjectPage.branchGlyphBox)
            Text(branch.name).projectType(LoomTheme.ProjectPage.branchName)
                .foregroundStyle(branch.isCurrent ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                .lineLimit(1).truncationMode(.middle)
            if branch.isCurrent {
                Text("current").projectType(LoomTheme.ProjectPage.branchCurrent).foregroundStyle(LoomTheme.Accent.high)
                    .fixedSize()
            } else if let worktree = branch.worktree {
                let words = Text("worktree ").font(LoomTheme.ProjectPage.branchWorktree.font)
                let folder = Text((worktree as NSString).abbreviatingWithTildeInPath)
                    .font(LoomTheme.ProjectPage.branchWorktreeFolder.font)
                Text("\(words)\(folder)")
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            if sessions > 0 {
                Text(sessions == 1 ? "1 session" : "\(sessions) sessions")
                    .projectType(LoomTheme.ProjectPage.branchSessions).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize()
            }
            if let updated = branch.updated {
                Text(RelativeTime.string(from: updated, to: now)).projectType(LoomTheme.ProjectPage.branchTime)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .frame(width: LoomTheme.ProjectPage.branchTimeWidth, alignment: .trailing)
            }
        }
        .frame(height: LoomTheme.ProjectPage.branchRowHeight)
        .padding(.horizontal, LoomTheme.ProjectPage.rowPaddingH)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([branch.name, branch.isCurrent ? "current" : nil, branch.worktree.map { _ in "in a worktree" },
                             sessions > 0 ? "\(sessions) sessions" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("project-branch-row")
    }
}

/// The words of the Instructions line: "13 lines · 2d" (the size when the file was cut), and the age as the rows write it.
enum ProjectInstructionsText {
    static func meta(_ instructions: ProjectInstructions, now: Date) -> String {
        var parts: [String] = []
        if let lines = instructions.lineCount { parts.append(lines == 1 ? "1 line" : "\(lines) lines") }
        else { parts.append(size(instructions.byteCount)) }
        if let modified = instructions.modified { parts.append(RelativeTime.string(from: modified, to: now)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1_024 ? "\((bytes + 512) / 1_024) KB" : "\(bytes) bytes"
    }

    static let none = "This project has no CLAUDE.md. Claude reads one from the project folder when it starts a session there."
    static let reading = "Reading CLAUDE.md\u{2026}"
}

/// The Instructions tab: the project's CLAUDE.md, read-only, with Open in Editor beside its name.
struct ProjectInstructionsTab: View {
    let page: ProjectPageState
    let project: CatalogProject
    let now: Date
    @State private var flags: Set<String> = []
    @State private var context = ChatRowContext()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let instructions = page.instructions {
                HStack(spacing: LoomTheme.ProjectPage.instructionsGap) {
                    InkIcon(.book, size: LoomTheme.Icon.body)
                        .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    Text(instructions.name).projectType(LoomTheme.ProjectPage.instructionsName).foregroundStyle(LoomTheme.Text.primary)
                    Text(ProjectInstructionsText.meta(instructions, now: now))
                        .projectType(LoomTheme.ProjectPage.instructionsMeta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                    ChatLinkButton(title: "Open in Editor", symbol: "arrow.up.right.square", identified: false) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: (project.path as NSString).appendingPathComponent(instructions.name)))
                    }
                    .accessibilityIdentifier("project-open-claude-md")
                }
                .frame(height: LoomTheme.ProjectPage.instructionsLineHeight)
                let shape = RoundedRectangle(cornerRadius: LoomTheme.ProjectPage.cardRadius)
                ChatMarkdownView(blocks: instructions.blocks, flags: flags, rowID: "project-instructions", context: context)
                    .padding(.horizontal, LoomTheme.ProjectPage.instructionsPaddingH)
                    .padding(.top, LoomTheme.ProjectPage.instructionsPaddingTop).padding(.bottom, LoomTheme.ProjectPage.instructionsPaddingBottom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(shape.fill(LoomTheme.Surface.card))
                    .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
                    .depth(LoomTheme.Elevation.card)
                    .padding(.top, LoomTheme.ProjectPage.instructionsCardTop)
                    .accessibilityIdentifier("project-claude-md")
                if instructions.truncated {
                    Text("Showing the first \(ProjectInstructionsText.size(ProjectInstructionsReader.maxBytes)) of "
                         + "\(ProjectInstructionsText.size(instructions.byteCount)). Open the file to read the rest.")
                        .projectType(LoomTheme.ProjectPage.cutNote).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        .padding(.top, LoomTheme.ProjectPage.cutNoteTop)
                        .accessibilityIdentifier("project-claude-md-truncated")
                }
            } else if page.instructionsLoad == .loading {
                ProjectPageNote(text: ProjectInstructionsText.reading, identifier: "project-instructions-note")
            } else {
                ProjectPageNote(text: ProjectInstructionsText.none, identifier: "project-instructions-note")
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
}
