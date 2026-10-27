import LoomCore
import LoomRemora
import SwiftUI

/// Settings → Remora (DESIGN §20 Settings; the reference's `settings/body.html` Remora pane). The first row is the switch; Off dims
/// the rest and answers nothing in it. Every control calls its setter at once (`CatalogModel+Remora.swift`), and the use is read again
/// when the tab opens.
struct RemoraSettingsView: View {
    let model: CatalogModel
    let navigation: SettingsNavigation
    /// What the working memory holds, read when the tab opens and again when a sheet closes.
    @State private var counts: (days: Int, notes: Int, updated: Date?) = (0, 0, nil)

    private typealias S = LoomTheme.Settings
    private typealias R = LoomTheme.RemoraTab
    private typealias Text_ = RemoraSettingsText

    private var controls: RemoraSettingsControls { RemoraSettingsControls(model: model) }

    /// What Remora may run behind: every Claude model the catalog knows (the model's own catalogue, C2B).
    private var catalog: ModelCatalog { model.modelCatalog }

    var body: some View {
        let preferences = model.remora.preferences
        let dimmed = RemoraSettingsRule.dimsTheRest(isOn: preferences.isOn)
        SettingsPage {
            VStack(alignment: .leading, spacing: S.groupGap) {
                SettingsCard {
                    SettingsRow(title: Text_.switchTitle, detail: Text_.switchDetail) {
                        SettingsSwitch(title: Text_.switchTitle, isOn: Binding(get: { preferences.isOn }, set: { controls.setOn($0) }))
                    }
                    Group {
                        SettingsRowDivider()
                        modelRow(preferences)
                        if !RemoraChoices.efforts(for: preferences.model, from: catalog, including: preferences.effort).isEmpty {
                            SettingsRowDivider()
                            effortRow(preferences)
                        }
                        SettingsRowDivider()
                        briefRow(preferences)
                        SettingsRowDivider()
                        languageRow(preferences)
                    }
                    .settingsDimmed(dimmed)
                }
                SettingsGroup(label: Text_.readsLabel) { projectsRow(preferences) }
                    .settingsDimmed(dimmed)
                SettingsGroup(label: Text_.memoryLabel) {
                    memoryRow
                    SettingsRowDivider()
                    noteRow
                    SettingsRowDivider()
                    SettingsRow(title: Text_.proposalsTitle, detail: Text_.proposalsDetail) {
                        SettingsSwitch(title: Text_.proposalsTitle,
                                       isOn: Binding(get: { preferences.proposals }, set: { controls.setProposals($0) }))
                    }
                }
                .settingsDimmed(dimmed)
                SettingsGroup(label: Text_.useLabel) {
                    SettingsRow(title: Text_.todayTitle, detail: RemoraSettingsLine.today(model.remora.usage?.today),
                                detailStyle: R.fact) {}
                    SettingsRowDivider()
                    thresholdRow(preferences)
                }
                .settingsDimmed(dimmed)
                Text(Text_.lastLine(isOn: preferences.isOn))
                    .projectType(R.note).lineHeight(.exact(points: R.noteLine))
                    .offset(y: R.noteDrop).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .frame(maxWidth: R.noteMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, R.noteTop - S.groupGap).padding(.horizontal, R.noteInset)
            }
        }
        .task { model.refreshRemoraUsage() }
        // Edits and Clear in the memory sheet change what the memory holds, and so does a deletion that ends.
        .task(id: CountsKey(sheet: navigation.openSheet, deletions: model.openDeletions)) { await readCounts() }
    }

    private struct CountsKey: Equatable {
        let sheet: SettingsSheet?
        let deletions: Set<UUID>
    }

    private func readCounts() async {
        await model.remoraMemoryChanged()
        counts = (await model.remoraJournalDays().count, await model.remoraNotes().count, await model.remoraWorkingMemoryUpdatedAt())
    }

    // MARK: Rows

    private func modelRow(_ preferences: RemoraPreferences) -> some View {
        let options = RemoraChoices.models(from: catalog.claudeModels, including: preferences.model)
        return SettingsRow(title: RemoraSettingsText.modelTitle, detail: RemoraSettingsText.modelDetail) {
            SettingsPopup(title: RemoraSettingsText.modelTitle,
                          selection: Binding(get: { preferences.model }, set: { controls.setModel($0) }),
                          valueText: RemoraChoices.title(of: preferences.model, in: options)) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
        }
    }

    private func effortRow(_ preferences: RemoraPreferences) -> some View {
        let options = RemoraChoices.efforts(for: preferences.model, from: catalog, including: preferences.effort)
        return SettingsRow(title: RemoraSettingsText.effortTitle) {
            SettingsPopup(title: RemoraSettingsText.effortTitle,
                          selection: Binding(get: { preferences.effort }, set: { controls.setEffort($0) }),
                          valueText: RemoraChoices.title(of: preferences.effort, in: options)) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
        }
    }

    private func briefRow(_ preferences: RemoraPreferences) -> some View {
        SettingsRow(title: RemoraSettingsText.briefTitle, detail: RemoraSettingsText.briefDetail) {
            InkSegmented(values: [RemoraBriefMode.automatic, .whenIAsk], title: \.settingsTitle, selection: preferences.briefMode,
                         onSelect: { controls.setBriefMode($0) })
                .accessibilityLabel(RemoraSettingsText.briefTitle)
        }
    }

    private func languageRow(_ preferences: RemoraPreferences) -> some View {
        let options = RemoraChoices.languages(including: preferences.language)
        let tag = RemoraChoices.tag(forLanguage: preferences.language)
        return SettingsRow(title: RemoraSettingsText.languageTitle) {
            SettingsPopup(title: RemoraSettingsText.languageTitle,
                          selection: Binding(get: { tag }, set: { controls.setLanguage(tag: $0) }),
                          valueText: RemoraChoices.title(of: tag, in: options)) {
                Text(options[0].title).tag(options[0].value)
                Divider()
                ForEach(options.dropFirst(), id: \.value) { Text($0.title).tag($0.value) }
            }
        }
    }

    /// One check for each project: the mark and the name beside it. A check that is off puts the project out of Remora's reach.
    private func projectsRow(_ preferences: RemoraPreferences) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRowText(title: RemoraSettingsText.projectsTitle, detail: RemoraSettingsText.projectsDetail)
            if model.projects.isEmpty {
                Text(RemoraSettingsText.noProjects).projectType(LoomTheme.InkType.small)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle).padding(.top, R.projectsTop)
            } else {
                RemoraFlow(spacing: R.projectGap) {
                    ForEach(model.projects) { project in
                        RemoraProjectCheck(
                            name: project.name, tone: model.projectTone(forProject: project.id),
                            isOn: Binding(get: { !preferences.excludedProjects.contains(project.id) },
                                          set: { controls.setProject(project.id, reads: $0) }))
                    }
                }
                .padding(.top, R.projectsTop)
            }
        }
        .padding(.vertical, S.rowPaddingV).padding(.horizontal, S.rowPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: S.rowMinHeight)
    }

    private var memoryRow: some View {
        SettingsRow(title: RemoraSettingsText.workingTitle,
                    detail: RemoraSettingsLine.workingMemory(days: counts.days, notes: counts.notes, updated: counts.updated), detailStyle: R.fact) {
            Button(RemoraSettingsText.show) { navigation.sheets.present(.remoraMemory) }
                .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                .disabled(!model.hasRemora)
            Button(RemoraSettingsText.clear) { navigation.askToClearRemoraMemory(fromMemorySheet: false) }
                .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                .disabled(!model.hasRemora)
        }
    }

    private var noteRow: some View {
        let url = model.remoraNoteURL
        return SettingsRow(title: RemoraSettingsText.noteTitle, detail: url.map(SettingsPaths.display) ?? "Not set up yet",
                           detailStyle: S.path, detailWidth: S.pathMaxWidth) {
            Button(RemoraSettingsText.choose) {
                if let chosen = navigation.noteActions.choose() { controls.setNoteFile(chosen) }
            }
            .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
            Button(RemoraSettingsText.open) { if let url { navigation.noteActions.open(url) } }
                .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                .disabled(url == nil)
        }
    }

    private func thresholdRow(_ preferences: RemoraPreferences) -> some View {
        let percent = RemoraThreshold.percent(of: preferences.windowThreshold)
        return SettingsRow(title: RemoraSettingsText.thresholdTitle, detail: RemoraSettingsText.thresholdDetail) {
            InkStepper(title: RemoraSettingsText.thresholdTitle, value: percent, range: R.thresholdRange,
                       valueText: RemoraSettingsLine.threshold(percent), decreaseHelp: "Lower", increaseHelp: "Higher",
                       onChange: { controls.setThreshold(percent: $0) })
        }
    }
}

/// What each control of the tab does to the model: one setter each (`CatalogModel+Remora.swift`), with the conversions the popups
/// and the stepper need. The views call these and nothing else, so a test can press every control.
@MainActor
struct RemoraSettingsControls {
    let model: CatalogModel
    /// The catalog the model list and each model's efforts come from; nil is the model's own (`CatalogModel.modelCatalog`), and a
    /// test may hand its own.
    var catalog: ModelCatalog?

    private var models: ModelCatalog { catalog ?? model.modelCatalog }

    func setOn(_ on: Bool) { model.setRemoraOn(on) }
    func setModel(_ value: String) {
        model.setRemoraModel(value)
        // A model with fewer levels keeps the nearest one below the stored level; one with none keeps the stored level for
        // the next model that takes it (its row is hidden until then).
        if let kept = RemoraChoices.keptEffort(model.remora.preferences.effort, for: value, from: models), kept != model.remora.preferences.effort {
            model.setRemoraEffort(kept)
        }
    }
    func setEffort(_ value: String) { model.setRemoraEffort(value) }
    func setBriefMode(_ mode: RemoraBriefMode) { model.setRemoraBriefMode(mode) }
    /// The language popup's tag; "" is the first item, "Same as my last question".
    func setLanguage(tag: String) { model.setRemoraLanguage(RemoraChoices.language(forTag: tag)) }
    /// A project's check: on means Remora reads it.
    func setProject(_ project: UUID, reads: Bool) { model.setRemoraExcluded(project, !reads) }
    func setProposals(_ on: Bool) { model.setRemoraProposals(on) }
    func setThreshold(percent: Int) { model.setRemoraWindowThreshold(RemoraThreshold.share(ofPercent: percent)) }
    func setNoteFile(_ url: URL) { model.setRemoraNoteFile(url) }
}

extension RemoraBriefMode {
    /// The segment's word.
    var settingsTitle: String {
        switch self {
        case .automatic: "Automatic"
        case .whenIAsk: "When I ask"
        }
    }
}

// MARK: A project's check

/// A project in the list Remora reads: the checkbox, the project's mark and its name in a 26 high chip with a strong-hairline edge. A
/// project that is left out is drawn in the tertiary tone with its mark dimmed.
struct RemoraProjectCheck: View {
    let name: String
    let tone: ProjectTone?
    @Binding var isOn: Bool
    @State private var hovering = false
    @Environment(\.settingsDimmed) private var dimmed

    private typealias R = LoomTheme.RemoraTab

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: R.projectRadius)
        HStack(spacing: R.projectGap) {
            Toggle(name, isOn: $isOn).labelsHidden().toggleStyle(InkCheckboxStyle())
            HStack(spacing: R.projectGap) {
                ProjectMarkView(name: name, tone: tone, size: .chip).grayscale(isOn ? 0 : 1).opacity(isOn ? 1 : R.projectOffMark)
                Text(name).projectType(R.projectFont).lineLimit(1)
                    .foregroundStyle(isOn ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.tertiaryStyle))
            }
            .opacity(dimmed ? R.dimmed : 1)
        }
        .padding(.leading, R.projectPaddingLeading).padding(.trailing, R.projectPaddingTrailing)
        .frame(height: R.projectHeight)
        .background(shape.fill(hovering ? LoomTheme.Surface.hover : Color.clear))
        .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
        .contentShape(shape)
        .onTapGesture { isOn.toggle() }
        .onHover { hovering = $0 }
        // One checkbox for assistive technologies, named by the project.
        .accessibilityRepresentation { Toggle(name, isOn: $isOn).toggleStyle(.checkbox) }
    }
}

// MARK: Wrapping

/// Chips in a row that wraps at the width it is given, each row starting at the leading edge.
struct RemoraFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in placed.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}
