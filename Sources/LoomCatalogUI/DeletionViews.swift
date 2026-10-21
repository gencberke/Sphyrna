import LoomCore
import SwiftUI

/// The confirm sheet (CP4-D). It shows what the runtime's dry run found and removes nothing itself.
struct DeleteConversationSheet: View {
    let model: CatalogModel
    let confirmation: DeletionConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sheetSpacing) {
            Text("Delete this session?").font(LoomTheme.Typography.title)
            Text(confirmation.title).font(LoomTheme.Typography.bodyStrong)
                .foregroundStyle(LoomTheme.Text.primary).lineLimit(2).truncationMode(.tail)
            switch confirmation.phase {
            case .loading:
                HStack(spacing: LoomTheme.Space.headerSpacing) {
                    ProgressView().controlSize(.small)
                    Text("Checking what Claude has kept for this session…")
                        .foregroundStyle(LoomTheme.Text.secondary)
                }
                .font(LoomTheme.Typography.small)
            case let .ready(preview):
                Text(DeletionCopy.confirmBody(preview))
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !preview.unreachable.isEmpty {
                    Text(DeletionCopy.unreachableNote(preview.unreachable))
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.failure)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            case let .unavailable(message):
                Text(message).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.failure)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if confirmation.offersRemoveFromLoomOnly {
                    Button("Remove from Loom Only") { model.requestRemoveFromLoomOnly(confirmation.id) }
                        .help("Removes the session from Loom. Claude's files are not touched.")
                }
                Spacer()
                Button("Cancel") { model.cancelDeletion() }.keyboardShortcut(.cancelAction)
                Button("Delete Permanently") { Task { await model.confirmDeletion() } }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(!confirmation.canConfirm)
            }
        }
        .removeFromLoomAlert(model: model, id: confirmation.id)
        .padding(LoomTheme.Space.sheetPadding)
        .frame(width: LoomTheme.Layout.sheetWidth)
        .tint(LoomTheme.Accent.base)
        .accessibilityIdentifier("delete-confirm-sheet")
    }
}

/// Deletions that did not finish, or are finishing after a launch (one row each). Shown in every build:
/// a deletion the runtime recovered must stay visible and retryable.
struct DeletionBanner: View {
    let model: CatalogModel

    var body: some View {
        let records = model.deletions.pending.values.sorted { ($0.requestedAt, $0.id.uuidString) < ($1.requestedAt, $1.id.uuidString) }
        let recovery = model.deletions.recoveryFailure
        if !records.isEmpty || recovery != nil {
            VStack(spacing: LoomTheme.Space.bannerSpacing) {
                if let recovery {
                    Text(recovery).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.failure)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .accessibilityIdentifier("deletion-recovery-failure")
                }
                ForEach(records) { record in
                    DeletionBannerRow(model: model, record: record)
                }
            }
            .padding(.horizontal, LoomTheme.Space.detailInset)
            .padding(.bottom, LoomTheme.Space.bannerBottom)
        }
    }
}

struct DeletionBannerRow: View {
    let model: CatalogModel
    let record: PendingConversationDeletion

    var body: some View {
        let title = model.deletions.titles[record.id].flatMap { $0.isEmpty ? nil : $0 }
        HStack(alignment: .top, spacing: LoomTheme.Space.bannerRowSpacing) {
            if model.isDeleting(record.id) {
                Text(title.map { "Deleting \($0)…" } ?? "Deleting a session…")
                    .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: LoomTheme.Space.noticeLineSpacing) {
                    Text(DeletionCopy.bannerText(lastFailure: record.lastFailure))
                        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.failure)
                        .textSelection(.enabled)
                    if let title {
                        Text(title).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Try Again") { Task { await model.retryDeletion(record.id) } }
                    .buttonStyle(AccentButtonStyle(kind: .tinted))
                    .disabled(!model.canRetryDeletion(record.id))
                if model.canRemoveFromLoomOnly(record.id) {
                    Button("Remove from Loom Only") { model.requestRemoveFromLoomOnly(record.id) }
                        .buttonStyle(AccentButtonStyle(kind: .tinted))
                        .help("Removes the session from Loom. Claude's files are not touched.")
                }
            }
        }
        .removeFromLoomAlert(model: model, id: record.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deletion-banner-\(record.id.uuidString.lowercased())")
    }
}

extension View {
    /// The one alert "Remove from Loom Only" goes through, on the confirm sheet and on the banner.
    func removeFromLoomAlert(model: CatalogModel, id: UUID) -> some View {
        alert(DeletionCopy.removeTitle, isPresented: Binding(
            get: { model.deletions.removalRequest == id }, set: { if !$0 { model.cancelRemoveFromLoomOnly() } }
        )) {
            Button(DeletionCopy.removeButton, role: .destructive) { model.removeFromLoomOnly(id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DeletionCopy.removeMessage)
        }
    }
}

/// "Delete Permanently…" and "Retry Deleting" for the card menu and the actions menu, in every build;
/// a disabled entry is followed by the reason.
struct DeletionMenuItems: View {
    static let deleteTitle = "Delete Permanently…"

    let model: CatalogModel
    let row: SessionRowModel

    var body: some View {
        Divider()
        if model.canRetryDeletion(row.id) {
            Button("Retry Deleting") { Task { await model.retryDeletion(row.id) } }
        }
        let reason = model.deletionDisabledReason(for: row)
        Button(Self.deleteTitle) { model.requestDeletion(row.id) }
            .disabled(reason != nil)
        if let reason { Text(reason) }
    }
}

/// A destructive button of the control family: the failure text, with the failure wash under the pointer.
struct DestructiveButtonStyle: ButtonStyle {
    var size: LoomTheme.Control.Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        ControlButtonStyle(kind: .destructive, size: size).makeBody(configuration: configuration)
    }
}
