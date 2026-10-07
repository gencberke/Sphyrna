import LoomCore
import SwiftUI

/// Settings → Conversations (CP4-G): stale conversations the cleanup rules allow deleting, with
/// the kept ones and why. Nothing is checked by default and nothing is deleted without the button.
struct CleanupReviewView: View {
    let review: CleanupReviewModel
    let catalog: CatalogModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        .task { await review.open() }
        .alert("Delete \(review.selectedCount) \(review.selectedCount == 1 ? "session" : "sessions") permanently?",
               isPresented: $confirming) {
            Button("Delete", role: .destructive) { Task { await review.confirmDeletion() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their Claude data and Loom records are removed and cannot be restored.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch review.phase {
        case .idle, .loading where review.review == nil:
            CleanupNotice(title: "Reviewing sessions", text: "Checking which stale sessions can be deleted.")
        case .failed(let message) where review.review == nil:
            CleanupNotice(title: "The review could not be made", text: message, retry: { Task { await review.open() } })
        default:
            if let snapshot = review.review { list(snapshot) } else { Spacer(minLength: 0) }
        }
    }

    private func list(_ snapshot: CleanupReview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoomTheme.Space.settingsSectionGap) {
                if review.showsDueNotice { dueCleanupNotice(snapshot) }
                if snapshot.eligible.isEmpty && snapshot.excluded.isEmpty {
                    Text("No stale sessions. Sessions unused for 15 days become stale.")
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                }
                if !snapshot.eligible.isEmpty { eligibleSection(snapshot) }
                if !snapshot.excluded.isEmpty { keptSection(snapshot) }
                if case .failed(let message) = review.phase {
                    Text(message).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.failure)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, LoomTheme.Space.settingsInset)
            .padding(.top, LoomTheme.Space.settingsSegmentH)
            .padding(.bottom, LoomTheme.Space.settingsSectionGap)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func dueCleanupNotice(_ snapshot: CleanupReview) -> some View {
        HStack(spacing: LoomTheme.Space.settingsRowInset) {
            Text(dueText(snapshot.mode))
                .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
            Spacer(minLength: 0)
            Button("Dismiss") { Task { await review.dismissDueReview() } }
                .buttonStyle(SettingsButtonStyle())
                .accessibilityLabel("Dismiss the review")
        }
    }

    private func dueText(_ mode: CleanupMode) -> String {
        switch mode {
        case .reviewRequired(.longAbsence): "It has been a while. A review is due; nothing is deleted unless you confirm it here."
        case .reviewRequired(.bulk): "A review is due and many sessions qualify. Nothing is deleted unless you confirm it here."
        default: "A review is due. Nothing is deleted unless you confirm it here."
        }
    }

    private func eligibleSection(_ snapshot: CleanupReview) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.headerSpacing) {
            HStack {
                SectionHeading(review.hasResults ? "Deletion results (\(snapshot.eligible.count))" : "Can be deleted (\(snapshot.eligible.count))")
                Spacer(minLength: 0)
                if !review.hasResults {
                    Button(review.selectedCount == snapshot.eligible.count ? "Clear" : "Select all") {
                        if review.selectedCount == snapshot.eligible.count { review.clearSelection() } else { review.selectAll() }
                    }
                    .buttonStyle(SettingsButtonStyle()).disabled(review.isBusy)
                }
            }
            SettingsCard {
                ForEach(Array(snapshot.eligible.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { SettingsRowDivider() }
                    eligibleRow(row)
                }
            }
        }
    }

    private func eligibleRow(_ row: CleanupEligibleRow) -> some View {
        let title = row.record.displayTitle(projectName: catalog.projectName(for: row.record))
        return HStack(spacing: LoomTheme.Space.settingsRowInset) {
            if review.hasResults {
                Color.clear.frame(width: 0)
            } else {
                Toggle(isOn: Binding(get: { review.isSelected(row.id) }, set: { review.setSelected(row.id, $0) })) {
                    Text(title)
                }
                .toggleStyle(.checkbox).labelsHidden().disabled(review.isBusy)
                .accessibilityLabel("Delete \(title)")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(LoomTheme.Typography.smallMedium).lineLimit(1).truncationMode(.tail)
                Text(details(row)).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: LoomTheme.Space.settingsRowInset)
            if let result = review.results[row.id] {
                ResultText(result: result)
            } else if review.phase == .deleting && review.isSelected(row.id) {
                Text("Waiting").font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            }
        }
        .padding(.vertical, LoomTheme.Space.settingsRowV)
        .frame(minHeight: LoomTheme.Layout.settingsRowMinHeight)
        .accessibilityElement(children: .contain)
    }

    private func details(_ row: CleanupEligibleRow) -> String {
        var parts: [String] = []
        if let project = catalog.projectName(for: row.record) { parts.append(project) }
        let since = row.record.staleSince ?? row.eligibleSince
        parts.append("Stale since \(since.formatted(date: .abbreviated, time: .omitted))")
        if let size = CleanupText.size(row) { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    private func keptSection(_ snapshot: CleanupReview) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.headerSpacing) {
            SectionHeading("Kept (\(snapshot.excluded.count))")
            SettingsCard {
                ForEach(Array(snapshot.excluded.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { SettingsRowDivider() }
                    let title = row.record.displayTitle(projectName: catalog.projectName(for: row.record))
                    HStack(spacing: LoomTheme.Space.settingsRowInset) {
                        Text(title).font(LoomTheme.Typography.smallMedium).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: LoomTheme.Space.settingsRowInset)
                        Text(CleanupText.reason(row.reason))
                            .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.vertical, LoomTheme.Space.settingsRowV)
                    .frame(minHeight: LoomTheme.Layout.settingsRowMinHeight)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: LoomTheme.Space.footerSpacing) {
            Text(footerText).lineLimit(1)
            Spacer(minLength: 0)
            Button { Task { await review.open() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(ChromeButtonStyle())
                .disabled(review.isBusy)
                .help("Review again")
                .accessibilityLabel("Review again")
            if !review.hasResults {
                Button(review.selectedCount == 0 ? "Delete Sessions" : "Delete \(review.selectedCount) \(review.selectedCount == 1 ? "Session" : "Sessions")") {
                    confirming = true
                }
                .buttonStyle(AccentButtonStyle(kind: .tinted))
                .disabled(!review.canDelete)
            }
        }
        .font(LoomTheme.Typography.caption).monospacedDigit()
        .foregroundStyle(LoomTheme.Text.secondary)
        .padding(.leading, LoomTheme.Space.settingsInset).padding(.trailing, LoomTheme.Space.settingsFooterInset)
        .frame(height: LoomTheme.Layout.settingsFooterHeight)
        .overlay(alignment: .top) { SettingsRowDivider() }
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
        return review.review.map { "Reviewed \($0.generatedAt.formatted(date: .omitted, time: .shortened))" } ?? ""
    }
}

private struct SectionHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(LoomTheme.Typography.statusLabel).foregroundStyle(LoomTheme.Text.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ResultText: View {
    let result: CleanupRowResult

    var body: some View {
        Text(CleanupText.result(result))
            .font(LoomTheme.Typography.caption)
            .foregroundStyle(failed ? LoomTheme.Status.failure : LoomTheme.Text.secondary)
            .lineLimit(2).multilineTextAlignment(.trailing)
            .frame(maxWidth: LoomTheme.Layout.cleanupResultMaxWidth, alignment: .trailing)
    }

    private var failed: Bool {
        switch result {
        case .failed, .incomplete: true
        default: false
        }
    }
}

private struct CleanupNotice: View {
    let title: String
    let text: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: LoomTheme.Space.hintSpacing) {
            Text(title).font(LoomTheme.Typography.heading)
            Text(text).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: LoomTheme.Layout.messageMaxWidth)
            if let retry { Button("Try again", action: retry).buttonStyle(AccentButtonStyle(kind: .tinted)) }
        }
        .padding(.horizontal, LoomTheme.Space.settingsInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
