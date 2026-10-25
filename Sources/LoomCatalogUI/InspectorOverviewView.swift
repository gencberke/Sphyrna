import LoomChat
import LoomCore
import SwiftUI

/// The Overview tab (the reference's session window A): five sections of what is true about the session. Session (its state,
/// start, Claude Code version, model and effort, permission mode), Context (the ring), Worktree (project, branch and its base,
/// folder), Changes of the last turn and Agents. It reads what the app already holds; the last turn's files are read while the
/// tab is open as the Changes tab reads them (`CatalogModel.changesTrigger`).
struct InspectorOverview: View {
    let model: CatalogModel
    let row: SessionRowModel
    @Environment(\.inspectorOverlays) private var overlays
    /// The base branch read for one folder and branch (a file read, off the main actor); used only while it is still the
    /// selected session's.
    @State private var baseRead: BaseRead?

    private struct BaseKey: Equatable {
        let directory: String
        let branch: String
    }

    private struct BaseRead {
        let key: BaseKey
        let name: String?
    }

    /// The branch the session is on, when it is a named one: a detached HEAD has no base to point at.
    private var namedBranch: String? {
        if case let .named(name)? = model.branches[row.record.session.workingDirectory] { name } else { nil }
    }

    private var baseKey: BaseKey? {
        namedBranch.map { BaseKey(directory: row.record.session.workingDirectory, branch: $0) }
    }

    private var content: InspectorOverviewContent {
        let record = row.record
        let directory = record.session.workingDirectory
        let launched = model.launchModels
        let words = OverviewRunWords.pick(
            composer: model.composer(of: row.id)?.state, live: row.live, launchedVersion: launched.claudeVersion,
            launchedMode: launched.permissionMode(of: row.id), launchedEffort: launched.effort(of: row.id))
        let chip = model.headerChip(of: record)
        let provider = record.session.provider
        let readsEdits = model.capabilities(of: provider).readsEdits
        let edits = readsEdits ? model.changes.session(for: row.id).state(.lastTurn).data?.files : nil
        let base = baseKey.flatMap { key in baseRead.flatMap { $0.key == key ? $0.name : nil } }
        return InspectorOverviewContent(
            status: row.indicator.label ?? (record.lifecycle == .active ? "Not running" : "\u{2014}"),
            createdAt: record.createdAt, now: model.now, provider: provider,
            claudeVersion: words.version, model: model.modelContent(of: record)?.name,
            reportedMode: words.reportedMode, launchedMode: words.launchedMode,
            reportedEffort: words.reportedEffort, launchedEffort: words.launchedEffort,
            project: model.projectName(for: record), branch: chip?.branch, base: base, directory: directory,
            edits: edits, readsEdits: readsEdits, subagents: model.agentRecords(for: row),
            waiting: SubagentWaiting.ids(in: row.live))
    }

    var body: some View {
        let content = content
        ScrollView {
            VStack(alignment: .leading, spacing: LoomTheme.Inspector.sectionGap) {
                sessionSection(content)
                OverviewSection(title: "Context") { context }
                if let conversationID = usageConversationID {
                    OverviewSection(title: "Usage") { usageBlock(conversationID) }
                }
                worktreeSection(content)
                if let lastTurn = content.lastTurn { changesSection(lastTurn) }
                if let agents = content.agents { agentsSection(agents) }
            }
            .padding(LoomTheme.Inspector.bodyInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .loadsLaunchModel(model, row: row)
        // The session's use is read when the tab shows and again each time a turn ends (the indicator leaves Working).
        .task(id: UsageReadKey(conversationID: usageConversationID, working: row.indicator == .working)) {
            guard let id = usageConversationID, row.indicator != .working else { return }
            await model.usage?.loadSessionUsage(conversationID: id)
        }
        // The runtime's toolchain probe is read again when a run begins: a start is what resolves it.
        .task(id: row.live?.runID) { await model.launchModels.loadClaudeVersion(from: model.intents) }
        .task(id: baseKey) {
            guard let key = baseKey else { return }
            let name = await Task.detached(priority: .utility) { GitBaseBranch.read(directory: key.directory) }.value
            baseRead = BaseRead(key: key, name: name)
        }
        // A turn that ends while the tab shows reads the last turn again (`noteChangesIndicator`).
        .onChange(of: row.indicator, initial: true) { _, indicator in
            model.noteChangesIndicator(indicator, for: row.id)
        }
        .accessibilityIdentifier("inspector-overview")
    }

    // MARK: Session

    private func sessionSection(_ content: InspectorOverviewContent) -> some View {
        OverviewSection(title: "Session") {
            VStack(alignment: .leading, spacing: LoomTheme.Overview.rowGap) {
                OverviewFact("State") {
                    HStack(spacing: LoomTheme.Overview.valueGap) {
                        IndicatorView(indicator: row.indicator)
                        OverviewText(content.status)
                    }
                }
                OverviewFact("Started") { OverviewText(content.started, mono: true) }
                if let claude = content.claudeCode {
                    OverviewFact(model.capabilities(of: row.record.session.provider).displayName) {
                        HStack(spacing: LoomTheme.Overview.valueGap) {
                            ProviderIcon(provider: row.record.session.provider, size: LoomTheme.Overview.harnessMark)
                            OverviewText(claude, mono: true)
                        }
                    }
                }
                if let name = content.model {
                    OverviewFact("Model") {
                        HStack(spacing: LoomTheme.Overview.valueGap) {
                            OverviewText(name)
                            if let effort = content.effort {
                                Text("\u{00B7} \(effort)").inspectorType(LoomTheme.Overview.effort)
                                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
                            }
                        }
                    }
                } else if let effort = content.effort {
                    OverviewFact("Effort") { OverviewText(effort, mono: true) }
                }
                if let mode = content.mode {
                    OverviewFact("Mode") {
                        HStack(spacing: LoomTheme.Overview.valueGap) {
                            Image(systemName: ComposerModeLook.symbol(forRaw: mode.key)).font(LoomTheme.Overview.glyph)
                                .accessibilityHidden(true)
                            Text(verbatim: mode.title).inspectorType(LoomTheme.Overview.value)
                        }
                        .foregroundStyle(ComposerModeLook.color(forRaw: mode.key))
                    }
                }
            }
        }
    }

    // MARK: Context

    @ViewBuilder private var context: some View {
        if !model.capabilities(of: row.record.session.provider).readsContext {
            note("The context is read for Claude sessions.")
        } else if let id = row.record.session.providerConversationID, let usage = model.usage?.contexts[id] {
            OverviewContext(usage: usage)
        } else {
            note("No reading yet. It appears after the session's first reply.")
        }
    }

    // MARK: Usage

    private struct UsageReadKey: Equatable {
        let conversationID: String?
        let working: Bool
    }

    /// A Claude session with an id has a Usage block.
    private var usageConversationID: String? {
        guard model.capabilities(of: row.record.session.provider).readsContext, model.usage != nil,
              let id = row.record.session.providerConversationID, !id.isEmpty else { return nil }
        return id
    }

    @ViewBuilder private func usageBlock(_ conversationID: String) -> some View {
        if let usage = model.usage?.sessionUsages[conversationID], !usage.isEmpty {
            OverviewUsageTable(text: OverviewUsageText(usage))
        } else if model.usage?.sessionUsageFailures.contains(conversationID) == true {
            note(OverviewUsageText.failed)
        } else {
            note(OverviewUsageText.none)
        }
    }

    // MARK: Worktree

    private func worktreeSection(_ content: InspectorOverviewContent) -> some View {
        OverviewSection(title: "Worktree") {
            VStack(alignment: .leading, spacing: LoomTheme.Overview.rowGap) {
                OverviewFact("Project") {
                    if let chip = SessionHeaderChip(project: model.headerProjectMark(of: row.record), branch: nil) {
                        ProjectBranchChip(chip: chip)
                    } else {
                        OverviewText(content.project ?? "No project")
                    }
                }
                if let branch = content.branch {
                    OverviewFact("Branch") {
                        OverviewText(content.base.map { "\(branch) \u{2192} \($0)" } ?? branch, mono: true)
                            .lineLimit(1).truncationMode(.middle).help("Git branch")
                    }
                }
                OverviewFact("Folder") {
                    HStack(spacing: LoomTheme.Overview.valueGap) {
                        OverviewText(content.folder, mono: true).lineLimit(1).truncationMode(.middle)
                            .help(content.folderPath)
                        Spacer(minLength: 0)
                        OverviewCopyButton(text: content.folderPath)
                    }
                }
            }
        }
    }

    // MARK: Changes and agents

    private func changesSection(_ lastTurn: InspectorOverviewContent.LastTurn) -> some View {
        OverviewSection(title: "Changes \u{00B7} last turn", link: ("Open changes", {
            model.openChanges(.lastTurn, for: row.id)
        })) {
            VStack(alignment: .leading, spacing: 0) {
                if lastTurn.isEmpty {
                    note("Claude has not edited files in the last turn.")
                }
                ForEach(lastTurn.files) { file in OverviewFileRow(file: file) }
                if lastTurn.more > 0 {
                    Text("\(lastTurn.more) more").inspectorType(LoomTheme.Overview.caption)
                        .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
                        .frame(height: LoomTheme.Overview.fileHeight, alignment: .leading)
                }
            }
            .accessibilityIdentifier("overview-changes")
        }
    }

    private func agentsSection(_ agents: InspectorOverviewContent.Agents) -> some View {
        OverviewSection(title: agents.title, link: ("Open agents", { model.selectInspectorTab(.agents) })) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(agents.rows) { agent in OverviewAgentRow(agent: agent) }
                if agents.more > 0 {
                    Text("\(agents.more) more").inspectorType(LoomTheme.Overview.caption)
                        .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
                        .frame(height: LoomTheme.Overview.agentHeight, alignment: .leading)
                }
            }
            .accessibilityIdentifier("overview-agents")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).inspectorType(LoomTheme.Inspector.factValue).foregroundStyle(LoomTheme.Text.secondaryStyle)
    }
}

// MARK: - Parts

/// A section of the Overview: its label in Ink's label type, an optional "Open ›" at the end of the head, then the content.
private struct OverviewSection<Content: View>: View {
    let title: String
    var link: (label: String, action: () -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.inspectorOverlays) private var overlays

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Inspector.sectionTitleGap) {
            HStack(spacing: LoomTheme.Space.detailSpacing) {
                Text(title).inspectorType(LoomTheme.Inspector.sectionLabel)
                    .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                if let link { OverviewLink(label: link.label, action: link.action) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Open ›": secondary, primary under the pointer. The hit area is 24 high; the head keeps the label's height.
private struct OverviewLink: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: LoomTheme.Overview.linkGap) {
                Text("Open").inspectorType(LoomTheme.Overview.link)
                Image(systemName: "chevron.right").font(LoomTheme.Overview.linkGlyph).accessibilityHidden(true)
            }
            .foregroundStyle(hovering ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
            .frame(minHeight: LoomTheme.Layout.minimumHitTarget.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -(LoomTheme.Layout.minimumHitTarget.height - LoomTheme.Overview.linkLine) / 2)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

/// One fact: its label in the quiet voice on a fixed column, its value beside it.
private struct OverviewFact<Value: View>: View {
    let name: String
    @ViewBuilder let value: () -> Value
    @Environment(\.inspectorOverlays) private var overlays

    init(_ name: String, @ViewBuilder value: @escaping () -> Value) {
        self.name = name
        self.value = value
    }

    var body: some View {
        HStack(alignment: .center, spacing: LoomTheme.Overview.columnGap) {
            Text(name).inspectorType(LoomTheme.Inspector.factLabel)
                .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
                .frame(width: LoomTheme.Overview.labelWidth, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A value in primary, in the sans face, or in mono where it is what the machine says.
private struct OverviewText: View {
    let text: String
    var mono = false

    init(_ text: String, mono: Bool = false) {
        self.text = text
        self.mono = mono
    }

    var body: some View {
        Text(verbatim: text).inspectorType(mono ? LoomTheme.Overview.machine : LoomTheme.Overview.value)
            .foregroundStyle(mono ? AnyShapeStyle(LoomTheme.Text.secondaryStyle) : AnyShapeStyle(LoomTheme.Text.primary))
            .textSelection(.enabled)
    }
}

/// The folder's copy button: the full path goes to the pasteboard; the glyph says so for a moment.
private struct OverviewCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            SessionLocationActions.copy(text)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(LoomTheme.Chat.copiedDuration))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(LoomTheme.Overview.copyGlyph)
        }
        .buttonStyle(ChromeButtonStyle(size: CGSize(width: LoomTheme.Overview.copySide, height: LoomTheme.Overview.copySide),
                                       key: "overview-copy-folder"))
        .focusEffectDisabled()
        .help("Copy the folder's path")
        .accessibilityLabel("Copy the folder's path")
        .accessibilityIdentifier("overview-copy-folder")
    }
}

/// The Usage block: a row per kind of token and the API equivalent, a column each for Main, Subagents and Total.
private struct OverviewUsageTable: View {
    let text: OverviewUsageText
    @Environment(\.inspectorOverlays) private var overlays

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: LoomTheme.Overview.columnGap, verticalSpacing: LoomTheme.Overview.rowGap) {
            GridRow {
                Text(verbatim: "").gridColumnAlignment(.leading)
                ForEach(text.columns, id: \.title) { column in label(column.title) }
            }
            line("Input", \.input)
            line("Cache write", \.cacheWrite)
            line("Cache read", \.cacheRead)
            line("Output", \.output)
            line(OverviewUsageText.costLabel, \.cost)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityIdentifier("overview-usage")
    }

    private func line(_ name: String, _ value: KeyPath<OverviewUsageText.Column, String>) -> some View {
        GridRow {
            label(name).gridColumnAlignment(.leading)
            ForEach(text.columns, id: \.title) { column in
                Text(verbatim: column[keyPath: value]).inspectorType(LoomTheme.Overview.machine)
                    .foregroundStyle(column.title == "Total" ? AnyShapeStyle(LoomTheme.Text.primary)
                                     : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).inspectorType(LoomTheme.Inspector.factLabel)
            .foregroundStyle(LoomTheme.Inspector.quiet(overlays: overlays))
    }
}

/// The context block: a ring with the share over the tokens against the window.
private struct OverviewContext: View {
    let usage: ContextUsage

    var body: some View {
        HStack(spacing: LoomTheme.Overview.ringGap) {
            ring
            VStack(alignment: .leading, spacing: LoomTheme.Overview.captionGap) {
                Text(OverviewContextText.headline(usage)).inspectorType(LoomTheme.Overview.headline)
                    .foregroundStyle(LoomTheme.Text.primary)
                Text(OverviewContextText.detail(usage)).inspectorType(LoomTheme.Overview.caption)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(ContextRingText.detail(usage))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ContextRingText.spoken(usage))
    }

    /// With a known window the arc shows the share; without one the track alone is drawn, since a share would be a guess.
    private var ring: some View {
        let fraction = usage.fraction
        return ZStack {
            Circle().stroke(LoomTheme.ContextRing.track, lineWidth: LoomTheme.Overview.ringLine)
            if let fraction, fraction > 0 {
                Circle().trim(from: 0, to: fraction)
                    .stroke(fraction >= LoomTheme.ContextRing.nearlyFull ? LoomTheme.ContextRing.arcFull : LoomTheme.ContextRing.arc,
                            style: StrokeStyle(lineWidth: LoomTheme.Overview.ringLine, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: LoomTheme.Overview.ringDiameter, height: LoomTheme.Overview.ringDiameter)
        .frame(width: LoomTheme.Overview.ringBox, height: LoomTheme.Overview.ringBox)
        .accessibilityHidden(true)
    }
}

/// A changed file of the last turn: its name in mono, the added and removed lines at the end. Not a link.
private struct OverviewFileRow: View {
    let file: InspectorOverviewContent.FileRow

    var body: some View {
        HStack(spacing: LoomTheme.Overview.fileGap) {
            Text(verbatim: file.name).inspectorType(LoomTheme.Overview.fileName).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            ChatChangeCounts(added: file.added, removed: file.removed)
        }
        .frame(height: LoomTheme.Overview.fileHeight)
        .help(file.path)
        .accessibilityElement(children: .combine)
    }
}

/// A subagent: the status column (the spinner while it works, the attention dot while it waits, a check once finished), its
/// type, its description and the time. Not a link: the Agents tab opens its transcript.
private struct OverviewAgentRow: View {
    let agent: InspectorAgentsContent.Row

    var body: some View {
        HStack(spacing: LoomTheme.Overview.agentGap) {
            mark.frame(width: LoomTheme.Layout.indicatorSlot.width)
            Text(verbatim: agent.title).inspectorType(LoomTheme.Overview.agentType).foregroundStyle(LoomTheme.Text.primary)
                .lineLimit(1).fixedSize()
            Text(verbatim: agent.detail ?? agent.note ?? "").inspectorType(LoomTheme.Inspector.factValue)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(agent.time).inspectorType(LoomTheme.Overview.agentTime).foregroundStyle(LoomTheme.Text.tertiaryStyle)
        }
        .frame(height: LoomTheme.Overview.agentHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.accessibilityLabel)
    }

    @ViewBuilder private var mark: some View {
        if agent.isWaiting {
            IndicatorView(indicator: .waitingForApproval)
        } else if agent.isRunning && agent.note == nil {
            IndicatorView(indicator: .working)
        } else if agent.note == nil {
            Image(systemName: "checkmark").font(LoomTheme.Overview.agentCheck).foregroundStyle(LoomTheme.Text.faint)
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}
