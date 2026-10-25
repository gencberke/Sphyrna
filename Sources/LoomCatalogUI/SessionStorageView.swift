import LoomCore
import SwiftUI

/// Settings → Sessions → Storage (RESCUE C1): Claude's retention, the profile's whole transcript folder for context, then
/// Sphyrna's sessions by project with what each keeps on disk, largest first. Checked sessions go through the Delete sheet and
/// the verified deletion; a running one cannot be checked. Measured when the section shows (`SessionStorageModel.open`).
struct StorageSection: View {
    let storage: SessionStorageModel
    let catalog: CatalogModel
    let sheets: SheetPresenter<SettingsSheet>

    private typealias S = LoomTheme.Settings

    var body: some View {
        VStack(alignment: .leading, spacing: S.groupGap) {
            retentionGroup
            sessionsGroup
        }
        .task { await storage.open() }
        .accessibilityIdentifier("settings-storage")
    }

    // MARK: Retention

    private var retentionGroup: some View {
        SettingsGroup(label: "Storage") {
            SettingsRow(title: "Claude's retention", detail: StorageText.retention(storage.retention)) {
                Button("Change\u{2026}") { sheets.present(.retention) }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                    .disabled(storage.retentionDays == nil)
                    .accessibilityLabel("Change Claude's retention")
            }
            if let bytes = storage.report?.projectsFolderBytes {
                SettingsRowDivider()
                Text(StorageText.projectsFolder(bytes))
                    .projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, S.sessionPaddingV).padding(.horizontal, S.rowPaddingH)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings-storage-projects")
            }
            if let error = storage.retentionError {
                SettingsRowDivider()
                Text(error).projectType(S.changedNote).foregroundStyle(LoomTheme.Status.failureLight)
                    .textSelection(.enabled)
                    .padding(.vertical, S.sessionPaddingV).padding(.horizontal, S.rowPaddingH)
            }
        }
    }

    // MARK: Sessions

    @ViewBuilder private var sessionsGroup: some View {
        if let report = storage.report {
            let groups = storage.groups(projectName: { id in catalog.projects.first { $0.id == id }?.name })
            SettingsGroup(
                label: "Sessions \u{00B7} \(StorageText.size(report.totalBytes))",
                trailing: { trailing },
                content: {
                    if groups.isEmpty {
                        Text("No sessions to show.").projectType(LoomTheme.InkType.small)
                            .foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .padding(.vertical, S.sessionPaddingV).padding(.horizontal, S.rowPaddingH)
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { SettingsRowDivider() }
                        projectHead(group)
                        ForEach(group.rows) { row in
                            SettingsRowDivider()
                            sessionRow(row)
                        }
                    }
                })
            footer
        } else if case let .failed(message) = storage.phase {
            SettingsNote(title: "The sizes could not be read", text: message, retry: { Task { await storage.refresh() } })
        } else {
            Text("Measuring what each session keeps on disk.").projectType(LoomTheme.InkType.small)
                .foregroundStyle(LoomTheme.Text.secondaryStyle)
        }
    }

    private var trailing: some View {
        HStack(spacing: S.labelGap) {
            SettingsPopup(title: "Project", selection: Binding(get: { storage.filter }, set: { storage.filter = $0 }),
                          valueText: filterTitle) {
                Text("All projects").tag(SessionStorageModel.ProjectFilter.all)
                ForEach(storage.projectIDs, id: \.self) { id in
                    Text(projectName(id) ?? "Project").tag(SessionStorageModel.ProjectFilter.project(id))
                }
                if storage.hasSessionsWithoutProject {
                    Text("No project").tag(SessionStorageModel.ProjectFilter.noProject)
                }
            }
            SettingsRefreshButton(label: "Measure again", disabled: storage.isBusy) { Task { await storage.refresh() } }
        }
    }

    private var filterTitle: String {
        switch storage.filter {
        case .all: "All projects"
        case let .project(id): projectName(id) ?? "Project"
        case .noProject: "No project"
        }
    }

    private func projectName(_ id: UUID) -> String? { catalog.projects.first { $0.id == id }?.name }

    private func projectHead(_ group: SessionStorageModel.Group) -> some View {
        HStack {
            Text(group.title).projectType(S.sessionTitle).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
            Spacer(minLength: 0)
            Text(StorageText.size(group.totalBytes)).projectType(S.sessionWhy).foregroundStyle(LoomTheme.Text.secondaryStyle)
        }
        .padding(.vertical, S.sessionPaddingV).padding(.horizontal, S.rowPaddingH)
        .accessibilityElement(children: .combine)
    }

    private func sessionRow(_ row: SessionStorageRow) -> some View {
        let title = row.record.displayTitle(projectName: catalog.projectName(for: row.record))
        let refusal = storage.refusal(row)
        return HStack(spacing: S.sessionGap) {
            Toggle(title, isOn: Binding(get: { storage.isSelected(row.id) }, set: { storage.setSelected(row.id, $0) }))
                .labelsHidden().toggleStyle(InkCheckboxStyle()).disabled(storage.isBusy || refusal != nil)
                .accessibilityLabel("Delete \(title)")
            VStack(alignment: .leading, spacing: 0) {
                Text(title).projectType(S.sessionTitle).foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(1).truncationMode(.tail).frame(minHeight: S.sessionTitleLine, alignment: .leading)
                Text("Last used \(LoomDateFormat.date(row.record.lastUsedAt))").projectType(S.sessionSub)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
                    .frame(minHeight: S.sessionSubLine, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let refusal {
                Text(refusal).projectType(S.sessionWhy).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            Text(row.byteCount.map(StorageText.size) ?? "\u{2014}").projectType(S.sessionWhy)
                .foregroundStyle(LoomTheme.Text.primary)
        }
        .padding(.vertical, S.sessionPaddingV).padding(.horizontal, S.rowPaddingH)
        .frame(minHeight: S.sessionMinHeight)
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: S.labelGap) {
            Text(footerText).projectType(S.changedNote).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            Spacer(minLength: 0)
            Button("Delete Sessions") { sheets.present(.deleteStored) }
                .buttonStyle(ControlButtonStyle(kind: .destructive, size: .small))
                .disabled(!storage.canDelete)
                .accessibilityIdentifier("settings-storage-delete")
        }
    }

    private var footerText: String {
        if storage.phase == .deleting { return "Deleting \(storage.results.count) of \(storage.selectedRows.count)" }
        if !storage.results.isEmpty {
            let deleted = storage.results.values.filter { $0 == .deleted }.count
            let skipped = storage.results.count - deleted
            return "\(deleted) deleted" + (skipped > 0 ? ", \(skipped) not deleted" : "")
        }
        let count = storage.selectedRows.count
        guard count > 0 else { return "Check sessions to delete them and free their space." }
        return "\(count) checked \u{00B7} \(StorageText.size(storage.selectedRows.reduce(0) { $0 + ($1.byteCount ?? 0) }))"
    }
}

/// "Delete N sessions?" for the Storage part's checked sessions: the same words, list and totals as the review's sheet.
struct DeleteStoredSessionsSheet: View {
    let storage: SessionStorageModel
    let catalog: CatalogModel
    let profile: URL?
    let presenter: SheetPresenter<SettingsSheet>

    var body: some View {
        let rows = storage.selectedRows.map {
            DeleteSheetText.Row(title: $0.record.displayTitle(projectName: catalog.projectName(for: $0.record)),
                                fileCount: $0.fileCount, byteCount: $0.byteCount)
        }
        let text = DeleteSheetText.make(rows: rows, folder: profile.map(SettingsPaths.display))
        InkSheet(
            title: text.title, subject: text.names, listsFiles: true, cancel: presenter.dismiss,
            actions: [SheetAction(
                id: "delete-permanently", title: SettingsSheetText.deleteConfirm, tint: .failure, isEnabled: storage.canDelete,
                perform: {
                    presenter.dismiss()
                    Task { await storage.confirmDeletion() }
                })]
        ) {
            SheetText(text: text.lead)
            SheetList(label: "Removed", items: text.removed, meta: text.totals)
            SheetList(label: "Kept", items: text.kept)
        }
        .accessibilityIdentifier("settings-sheet-delete-stored")
    }
}

/// "Change Claude's retention?": the days, then the button that writes them. Cancel has the focus.
struct RetentionSheet: View {
    let storage: SessionStorageModel
    let profile: URL?
    let presenter: SheetPresenter<SettingsSheet>
    @State private var days: Int?

    var body: some View {
        let shown = days ?? storage.retentionDays ?? ClaudeRetention.defaultDays
        let file = profile.map { SettingsPaths.display($0.appendingPathComponent("settings.json")) } ?? "settings.json"
        InkSheet(
            title: StorageText.retentionTitle, cancel: presenter.dismiss,
            actions: [SheetAction(
                id: "change-retention", title: "Keep \(CleanupNumberUnit.days(shown))", tint: .accent,
                isEnabled: storage.retentionDays != nil && shown != storage.retentionDays,
                perform: {
                    presenter.dismiss()
                    Task { await storage.setRetention(days: shown) }
                })]
        ) {
            SheetText(text: StorageText.retentionBody(days: shown, file: file))
            InkStepper(title: "Days", value: shown, range: ClaudeRetention.allowedDays, valueText: CleanupNumberUnit.days(shown),
                       decreaseHelp: "Fewer days", increaseHelp: "More days") { days = $0 }
        }
        .accessibilityIdentifier("settings-sheet-retention")
    }
}
