import LoomCore
import SwiftUI

/// Delete's facts for one session (DESIGN §6 Sheets, D-78): one lead sentence that ends "This can't be undone.", then what goes
/// under "Removed" with the count, size and folder in mono, and what stays under "Kept". Every word comes from the runtime's dry run
/// (`ConversationDeletionPreview`), as the paragraph it replaces did (`DeletionCopy.confirmBody`); Settings' cleanup Delete reads the
/// same lists (`DeleteSheetText`).
struct DeleteSessionFacts: Equatable {
    static let removedTitle = "Removed"
    static let keptTitle = "Kept"
    /// One session's transcript; with side chats there is one per session, as the cleanup's Delete says.
    static let removedItems = ["The transcript and the subagent transcripts", "File snapshots and session folders"]

    let lead: String
    let removed: [String]
    /// "3 files · 10 bytes · in ~/.claude".
    let totals: String
    let kept: [String]

    init(_ preview: ConversationDeletionPreview) {
        let sideChats = preview.sideChatCount
        let who = sideChats > 0 ? "it and its \(sideChats) side chat\(sideChats == 1 ? "" : "s")" : "it"
        let theirs = sideChats > 0 ? "them" : "it"
        let action = "removes \(who) from Sphyrna and deletes Claude's local files for \(theirs)"
        lead = (preview.isRunning ? "It is running now, so Sphyrna stops it first, then \(action)" : "Sphyrna \(action)")
            + ". This can't be undone."
        removed = sideChats > 0 ? DeleteSheetText.removedItems : Self.removedItems
        let files = preview.fileCount == 1 ? "1 file" : "\(preview.fileCount) files"
        let size = preview.byteCount == 0 ? "0 bytes" : DeleteSheetText.size(preview.byteCount)
        let folder = (preview.configDirectory as NSString).abbreviatingWithTildeInPath
        totals = "\(files) \u{00B7} \(size) \u{00B7} in \(folder)"
        kept = DeleteSheetText.keptItems
    }
}

/// The confirm sheet (CP4-D). It shows what the runtime's dry run found and removes nothing itself.
struct DeleteConversationSheet: View {
    let model: CatalogModel
    let confirmation: DeletionConfirmation

    /// The sheet's buttons (D-78, "Filled means Return"): a delete has no filled button, so Return does nothing, Esc cancels and the
    /// focus starts on Cancel; Delete Permanently is tinted in the failure tone. Remove from Loom Only, where a folder blocks the
    /// delete, is the way out at the leading edge.
    static func buttons(for confirmation: DeletionConfirmation, removeOnly: @escaping () -> Void,
                        delete: @escaping () -> Void) -> (leading: SheetAction?, actions: [SheetAction]) {
        let leading = confirmation.offersRemoveFromLoomOnly
            ? SheetAction(id: "remove-from-loom", title: "Remove from Sphyrna Only", perform: removeOnly)
            : nil
        return (leading, [SheetAction(id: "delete-permanently", title: "Delete Permanently", tint: .failure,
                                      isEnabled: confirmation.canConfirm, perform: delete)])
    }

    var body: some View {
        let buttons = Self.buttons(
            for: confirmation, removeOnly: { model.requestRemoveFromLoomOnly(confirmation.id) },
            delete: { Task { await model.confirmDeletion() } })
        InkSheet(
            title: "Delete this session?", subject: confirmation.title, listsFiles: true,
            cancel: { model.cancelDeletion() }, leading: buttons.leading, actions: buttons.actions
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
            let facts = DeleteSessionFacts(preview)
            SheetText(text: facts.lead)
            SheetList(label: DeleteSessionFacts.removedTitle, items: facts.removed, meta: facts.totals)
            SheetList(label: DeleteSessionFacts.keptTitle, items: facts.kept)
            if !preview.unreachable.isEmpty {
                Text(DeletionCopy.unreachableNote(preview.unreachable))
                    .projectType(LoomTheme.Sheet.text).foregroundStyle(LoomTheme.Status.failureLight)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LoomTheme.Sheet.listTop)
            }
        case let .unavailable(message):
            Text(message)
                .projectType(LoomTheme.Sheet.text).foregroundStyle(LoomTheme.Status.failureLight)
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
