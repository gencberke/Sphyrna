import LoomCore
import SwiftUI

/// The confirm sheet (CP4-D). It shows what the runtime's dry run found and removes nothing itself.
struct DeleteConversationSheet: View {
    let model: CatalogModel
    let confirmation: DeletionConfirmation

    var body: some View {
        InkSheet(
            title: "Delete this session?", subject: confirmation.title, listsFiles: true,
            cancel: { model.cancelDeletion() },
            leading: confirmation.offersRemoveFromLoomOnly
                ? SheetAction(id: "remove-from-loom", title: "Remove from Loom Only",
                              perform: { model.requestRemoveFromLoomOnly(confirmation.id) })
                : nil,
            actions: [SheetAction(id: "delete-permanently", title: "Delete Permanently", tint: .failure,
                                  isEnabled: confirmation.canConfirm,
                                  perform: { Task { await model.confirmDeletion() } })]
        ) {
            facts
        }
        .removeFromLoomAlert(model: model, id: confirmation.id)
        .accessibilityIdentifier("delete-confirm-sheet")
    }

    @ViewBuilder private var facts: some View {
        switch confirmation.phase {
        case .loading:
            HStack(spacing: LoomTheme.Space.headerSpacing) {
                ProgressView().controlSize(.small)
                Text("Checking what Claude has kept for this session…")
                    .projectType(LoomTheme.Sheet.text).foregroundStyle(LoomTheme.Text.secondary)
            }
            .padding(.top, LoomTheme.Sheet.textTop)
        case let .ready(preview):
            SheetText(text: DeletionCopy.confirmBody(preview))
            if !preview.unreachable.isEmpty {
                Text(DeletionCopy.unreachableNote(preview.unreachable))
                    .projectType(LoomTheme.Sheet.text).foregroundStyle(LoomTheme.Status.failure)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LoomTheme.Sheet.factGap)
            }
        case let .unavailable(message):
            Text(message)
                .projectType(LoomTheme.Sheet.text).foregroundStyle(LoomTheme.Status.failure)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(.top, LoomTheme.Sheet.textTop)
        }
    }
}

// The deletions that did not finish, or are finishing after a launch, are boxes in the top stack (`Banners`, `BannerItems`):
// shown in every build, because a deletion the runtime recovered must stay visible and retryable.

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
