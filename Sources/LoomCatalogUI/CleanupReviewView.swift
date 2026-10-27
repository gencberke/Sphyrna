import LoomCore
import SwiftUI

/// Settings → Sessions (CP4-G): stale sessions the cleanup rules allow deleting, with the kept ones
/// and why, and the Cleanup part with the rules' two numbers (D-69). Nothing is checked by default
/// and nothing is deleted without the button and the Delete sheet (D-83).
struct CleanupReviewView: View {
    let review: CleanupReviewModel
    let catalog: CatalogModel
    /// "Delete Sessions" opens the Delete sheet here.
    let sheets: SheetPresenter<SettingsSheet>

    private typealias S = LoomTheme.Settings

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        .task { await review.open() }
    }

    @ViewBuilder
    private var content: some View {
        switch review.phase {
        case .idle, .loading where review.review == nil:
            SettingsNote(title: "Reviewing sessions", text: "Checking which stale sessions can be deleted.")
        case .failed(let message) where review.review == nil:
            SettingsNote(title: "The review could not be made", text: message, retry: { Task { await review.open() } })
        default:
            if let snapshot = review.review { list(snapshot) } else { Spacer(minLength: 0) }
        }
    }

    private func list(_ snapshot: CleanupReview) -> some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: S.groupGap) {
                if review.showsDueNotice {
                    dueCleanupNotice(snapshot).padding(.bottom, S.dueBottom - S.groupGap)
                }
                if snapshot.eligible.isEmpty && snapshot.excluded.isEmpty {
                    Text("No stale sessions. Sessions unused for 15 days become stale.")
                        .projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                if !snapshot.eligible.isEmpty { eligibleSection(snapshot) }
                if !snapshot.excluded.isEmpty { keptSection(snapshot) }
                CleanupSettingsSection(review: review)
                StorageSection(storage: review.storage, catalog: catalog, sheets: sheets)
                if case .failed(let message) = review.phase {
                    Text(message).projectType(LoomTheme.InkType.small).foregroundStyle(LoomTheme.Status.failureLight)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// A review is due: a card line with the info glyph, the words and Dismiss.
    private func dueCleanupNotice(_ snapshot: CleanupReview) -> some View {
        let shape = RoundedRectangle(cornerRadius: S.dueRadius)
        return HStack(spacing: S.dueGap) {
            Image(systemName: "info.circle").font(S.dueGlyph).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .accessibilityHidden(true)
            Text(dueText(snapshot.mode)).projectType(S.dueText).foregroundStyle(LoomTheme.Text.secondaryStyle)
            Spacer(minLength: 0)
            Button("Dismiss") { Task { await review.dismissDueReview() } }
                .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                .accessibilityLabel("Dismiss the review")
        }
        .padding(.vertical, S.duePaddingV).padding(.leading, S.duePaddingLeading).padding(.trailing, S.duePaddingTrailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(LoomTheme.Surface.raised1))
        .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
        .accessibilityElement(children: .contain)
    }

    private func dueText(_ mode: CleanupMode) -> String {
        switch mode {
        case .reviewRequired(.longAbsence): "It has been a while. A review is due; nothing is deleted unless you confirm it here."
        case .reviewRequired(.bulk): "A review is due and many sessions qualify. Nothing is deleted unless you confirm it here."
        default: "A review is due. Nothing is deleted unless you confirm it here."
        }
    }

    private func eligibleSection(_ snapshot: CleanupReview) -> some View {
        let all = review.selectedCount == snapshot.eligible.count
        return SettingsGroup(
            label: review.hasResults ? "Deletion results (\(snapshot.eligible.count))" : "Can be deleted (\(snapshot.eligible.count))",
            trailing: {
                if !review.hasResults {
                    Button(all ? "Clear" : "Select All") {
                        if all { review.clearSelection() } else { review.selectAll() }
                    }
                    .buttonStyle(ControlButtonStyle(kind: .link, key: "settings-select-all")).disabled(review.isBusy)
                }
            },
            content: {
                ForEach(Array(snapshot.eligible.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { SettingsRowDivider() }
                    eligibleRow(row)
                }
            })
    }

    private func eligibleRow(_ row: CleanupEligibleRow) -> some View {
        let title = row.record.displayTitle(projectName: catalog.projectName(for: row.record))
        let result = review.results[row.id]
        return HStack(spacing: S.sessionGap) {
            if !review.hasResults {
                Toggle(title, isOn: Binding(get: { review.isSelected(row.id) }, set: { review.setSelected(row.id, $0) }))
                    .labelsHidden().toggleStyle(InkCheckboxStyle()).disabled(review.isBusy)
                    .accessibilityLabel("Delete \(title)")
            }
            SessionRowText(title: title, detail: details(row), dimmed: result == .deleted)
            if let result {
                ResultText(result: result)
            } else if review.phase == .deleting && review.isSelected(row.id) {
                Text("Waiting").projectType(S.sessionWhy).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        }
        .padding(.vertical, S.sessionPaddingV).padding(.horizontal, S.rowPaddingH)
        .frame(minHeight: S.sessionMinHeight)
        .accessibilityElement(children: .contain)
    }

    private func details(_ row: CleanupEligibleRow) -> String {
        var parts: [String] = []
        if let project = catalog.projectName(for: row.record) { parts.append(project) }
        let since = row.record.staleSince ?? row.eligibleSince
        parts.append("Stale since \(LoomDateFormat.date(since))")
        if let size = CleanupText.size(row) { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    private func keptSection(_ snapshot: CleanupReview) -> some View {
        SettingsGroup(label: "Kept (\(snapshot.excluded.count))") {
            ForEach(Array(snapshot.excluded.enumerated()), id: \.element.id) { index, row in
                if index > 0 { SettingsRowDivider() }
                let title = row.record.displayTitle(projectName: catalog.projectName(for: row.record))
                HStack(spacing: S.sessionGap) {
                    SessionRowText(title: title, detail: catalog.projectName(for: row.record))
                    Text(CleanupText.reason(row.reason))
                        .projectType(S.sessionWhy).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(.vertical, S.sessionPaddingV).padding(.horizontal, S.rowPaddingH)
                .frame(minHeight: S.sessionMinHeight)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var footer: some View {
        SettingsFooter {
            Text(footerText)
        } trailing: {
            SettingsRefreshButton(label: "Review again", disabled: review.isBusy) { Task { await review.open() } }
            if !review.hasResults {
                Button("Delete Sessions") { sheets.present(.delete) }
                    .buttonStyle(ControlButtonStyle(kind: .destructive, size: .small))
                    .disabled(!review.canDelete)
            }
        }
    }

    private var footerText: String {
        switch review.phase {
        case .loading: return "Reviewing"
        case .deleting: return "Deleting \(review.results.count) of \(review.selectedCount)"
        default: break
        }
        if review.hasResults {
            let deleted = review.results.values.filter { $0 == .deleted }.count
            return "\(deleted) deleted, \(review.results.count - deleted) not deleted"
        }
        return review.review.map { "Reviewed \(LoomDateFormat.time($0.generatedAt))" } ?? ""
    }
}

/// A session row's text: the title in 13 on 18 (secondary once deleted), one line, and under it a mono line in tertiary.
private struct SessionRowText: View {
    let title: String
    var detail: String?
    var dimmed = false

    private typealias S = LoomTheme.Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).projectType(S.sessionTitle)
                .foregroundStyle(dimmed ? AnyShapeStyle(LoomTheme.Text.secondaryStyle) : AnyShapeStyle(LoomTheme.Text.primary))
                .lineLimit(1).truncationMode(.tail).frame(minHeight: S.sessionTitleLine, alignment: .leading)
            if let detail {
                Text(detail).projectType(S.sessionSub).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .lineLimit(1).truncationMode(.tail).frame(minHeight: S.sessionSubLine, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }
}

private struct ResultText: View {
    let result: CleanupRowResult

    private typealias S = LoomTheme.Settings

    var body: some View {
        Text(CleanupText.result(result))
            .projectType(S.sessionWhy)
            .foregroundStyle(color)
            .lineLimit(2).multilineTextAlignment(.trailing)
            .frame(maxWidth: S.sessionResultMaxWidth, alignment: .trailing)
    }

    private var color: AnyShapeStyle {
        switch result {
        case .failed, .incomplete: AnyShapeStyle(LoomTheme.Status.failureLight)
        case .deleted: AnyShapeStyle(LoomTheme.Text.primary)
        default: AnyShapeStyle(LoomTheme.Text.secondaryStyle)
        }
    }
}

/// The Cleanup part: the two numbers of the rules, each with its range and default, and a reset.
private struct CleanupSettingsSection: View {
    let review: CleanupReviewModel

    private typealias S = LoomTheme.Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(
                label: "Cleanup",
                trailing: {
                    Button("Reset to Defaults") { review.resetSettings() }
                        .buttonStyle(ControlButtonStyle(kind: .link, key: "settings-reset-defaults"))
                        .disabled(review.settings.isStandard || review.isBusy)
                },
                content: {
                    numberRow(CleanupText.reviewIntervalTitle, detail: CleanupText.reviewIntervalDetail,
                              range: CleanupSettings.reviewIntervalDaysRange,
                              standard: CleanupSettings.standard.reviewIntervalDays, value: \.reviewIntervalDays)
                    SettingsRowDivider()
                    numberRow(CleanupText.deletionWaitTitle, detail: CleanupText.deletionWaitDetail,
                              range: CleanupSettings.deletionWaitDaysRange,
                              standard: CleanupSettings.standard.deletionWaitDays, value: \.deletionWaitDays)
                })
            if let error = review.settingsError {
                Text(error).projectType(S.changedNote).foregroundStyle(LoomTheme.Status.failureLight)
                    .textSelection(.enabled).padding(.top, S.changedNoteTop)
            } else if review.settingsChangedSinceReview {
                Text("A change applies from the next review. Review again to see it.")
                    .projectType(S.changedNote).foregroundStyle(LoomTheme.Text.tertiaryStyle).padding(.top, S.changedNoteTop)
            }
        }
    }

    private func numberRow(
        _ title: String, detail: String, range: ClosedRange<Int>, standard: Int,
        value: WritableKeyPath<CleanupSettings, Int>
    ) -> some View {
        let current = review.settings[keyPath: value]
        return SettingsRow(title: title, detail: "\(detail) Default \(CleanupNumberUnit.days(standard)).") {
            InkStepper(title: title, value: current, range: range, valueText: CleanupNumberUnit.days(current),
                       decreaseHelp: "Fewer days", increaseHelp: "More days") { number in
                review.updateSettings { $0[keyPath: value] = number }
            }
        }
    }
}

/// How a cleanup number reads next to its row.
enum CleanupNumberUnit {
    static func days(_ number: Int) -> String { number == 1 ? "1 day" : "\(number) days" }
}
