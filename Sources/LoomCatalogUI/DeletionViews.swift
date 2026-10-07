import LoomCore
import SwiftUI

/// The confirm sheet (CP4-D). It shows what the runtime's dry run found and removes nothing itself.
struct DeleteConversationSheet: View {
    let model: CatalogModel
    let confirmation: DeletionConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.sheetSpacing) {
            Text("Delete this conversation?").font(LoomTheme.Typography.title)
            Text(confirmation.title).font(LoomTheme.Typography.bodyStrong)
                .foregroundStyle(LoomTheme.Text.primary).lineLimit(2).truncationMode(.tail)
            switch confirmation.phase {
            case .loading:
                HStack(spacing: LoomTheme.Space.headerSpacing) {
                    ProgressView().controlSize(.small)
                    Text("Checking what Claude has kept for this conversation…")
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
                Spacer()
                Button("Cancel") { model.cancelDeletion() }.keyboardShortcut(.cancelAction)
                Button("Delete Permanently") { Task { await model.confirmDeletion() } }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(!confirmation.canConfirm)
            }
        }
        .padding(LoomTheme.Space.sheetPadding)
        .frame(width: LoomTheme.Layout.sheetWidth)
        .preferredColorScheme(.dark)
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
                Text(title.map { "Deleting \($0)…" } ?? "Deleting a conversation…")
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
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deletion-banner-\(record.id.uuidString.lowercased())")
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

/// A destructive button: the failure color as a fill with the same dark text the accent fill uses.
struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(LoomTheme.Typography.body)
                .foregroundStyle(LoomTheme.Accent.onAccent)
                .padding(.horizontal, LoomTheme.Space.buttonH).padding(.vertical, LoomTheme.Space.buttonV)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
                    .fill(LoomTheme.Status.failure.opacity(configuration.isPressed ? LoomTheme.Opacity.accentPressed : 1)))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
        }
    }
}
