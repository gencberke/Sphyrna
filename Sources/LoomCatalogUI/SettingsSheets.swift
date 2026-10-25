import Foundation
import LoomCore
import SwiftUI

/// The questions Settings asks before it changes something (DESIGN §6 Sheets, D-83) and Remora's memory: sheets of the family
/// (`SheetFamily.swift`) over the Settings window.
public enum SettingsSheet: Hashable, Sendable {
    /// "Start new sessions in Full access?": picking Full access as the default mode.
    case fullAccess
    /// "Delete N sessions?": the checked sessions of the cleanup review.
    case delete
    /// "Delete N sessions?": the checked sessions of the Storage part.
    case deleteStored
    /// "Change Claude's retention?" with the days to write.
    case retention
    /// Remora's memory, 560 wide (DESIGN §20).
    case remoraMemory
    /// "Clear Remora's working memory?" from Settings' Clear… or the memory sheet's button; from the sheet, Cancel and the answer
    /// bring the memory sheet back.
    case remoraClear(returnsToMemory: Bool)
}

/// The words of the two sheets, as plain values so tests pin them.
enum SettingsSheetText {
    static let fullAccessTitle = "Start new sessions in Full access?"
    static let fullAccessBody = "Claude runs every tool without asking. Every new session starts in it until you change this. You can still pick another mode in a draft."
    static let fullAccessConfirm = "Use Full Access"
    static let deleteConfirm = "Delete Permanently"
}

/// Delete's facts for the checked sessions: the question, their names, the lead sentence, what is removed and what is kept.
struct DeleteSheetText: Equatable {
    /// One checked session, as the review lists it.
    struct Row: Equatable {
        let title: String
        let fileCount: Int?
        let byteCount: Int64?
    }

    let title: String
    let names: String
    let lead: String
    let removed: [String]
    /// "203 files · 17.2 MB · in ~/.claude"; nil when no dry run could count anything. "At least" leads it when some could not.
    let totals: String?
    let kept: [String]

    static let removedItems = ["The transcripts and the subagent transcripts", "File snapshots and session folders"]
    static let keptItems = [
        "Your prompts in Claude's shared prompt history", "Project files and worktrees", "Anything already sent to Anthropic",
    ]

    /// `folder` is the Claude profile as the user reads it ("~/.claude"); nil leaves it out of the totals.
    static func make(rows: [Row], folder: String?, size: (Int64) -> String = Self.size) -> DeleteSheetText {
        let count = rows.count
        let one = count == 1
        return DeleteSheetText(
            title: "Delete \(count) \(one ? "session" : "sessions")?",
            names: rows.map(\.title).joined(separator: ", "),
            lead: "Sphyrna removes \(one ? "it" : "them") from Sphyrna, and deletes Claude's local files for \(one ? "it" : "them"). This can't be undone.",
            removed: removedItems,
            totals: totals(rows, folder: folder, size: size),
            kept: keptItems)
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private static func totals(_ rows: [Row], folder: String?, size: (Int64) -> String) -> String? {
        let counted = rows.compactMap(\.fileCount)
        let sized = rows.compactMap(\.byteCount)
        guard !counted.isEmpty || !sized.isEmpty else { return nil }
        let complete = counted.count == rows.count && sized.count == rows.count
        var parts: [String] = []
        if !counted.isEmpty {
            let files = counted.reduce(0, +)
            parts.append((complete ? "" : "At least ") + "\(files) \(files == 1 ? "file" : "files")")
        }
        if !sized.isEmpty { parts.append(((complete || !counted.isEmpty) ? "" : "At least ") + size(sized.reduce(0, +))) }
        if let folder { parts.append("in \(folder)") }
        return parts.joined(separator: " · ")
    }
}

enum SettingsSheets {
    /// The sheet that fits a request, over the Settings window.
    @MainActor @ViewBuilder
    static func view(for sheet: SettingsSheet, model: CatalogModel, profile: URL?, navigation: SettingsNavigation) -> some View {
        let presenter = navigation.sheets
        switch sheet {
        case .fullAccess:
            FullAccessSheet(model: model, presenter: presenter)
        case .delete:
            if let review = model.cleanupReview {
                DeleteSessionsSheet(review: review, catalog: model, profile: profile, presenter: presenter)
            }
        case .deleteStored:
            if let review = model.cleanupReview {
                DeleteStoredSessionsSheet(storage: review.storage, catalog: model, profile: profile, presenter: presenter)
            }
        case .retention:
            if let review = model.cleanupReview {
                RetentionSheet(storage: review.storage, profile: profile, presenter: presenter)
            }
        case .remoraMemory:
            RemoraMemorySheet(catalog: model, navigation: navigation)
                .padding(.bottom, LoomTheme.MemorySheet.windowBottom)
        case let .remoraClear(returnsToMemory):
            RemoraClearSheet(model: model, presenter: presenter, returnsToMemory: returnsToMemory)
        }
    }
}

/// "Start new sessions in Full access?": Cancel has the focus; "Use Full Access" is tinted in the Full access mode's tone; Return does
/// nothing and Esc cancels.
struct FullAccessSheet: View {
    let model: CatalogModel
    let presenter: SheetPresenter<SettingsSheet>

    var body: some View {
        InkSheet(
            title: SettingsSheetText.fullAccessTitle, cancel: presenter.dismiss,
            actions: [SheetAction(
                id: "use-full-access", title: SettingsSheetText.fullAccessConfirm,
                tint: .tone(LoomTheme.Composer.ModeTone.fullAccessPair),
                perform: {
                    model.setDefaultStartMode(ClaudePermissionMode.fullAccess.rawValue, confirmedFullAccess: true)
                    presenter.dismiss()
                })]
        ) {
            SheetText(text: SettingsSheetText.fullAccessBody)
        }
        .accessibilityIdentifier("settings-sheet-full-access")
    }
}

/// "Clear Remora's working memory?": Cancel has the focus; "Clear Working Memory" is in the failure wash; Return does nothing and Esc
/// cancels. `Remora.md` is kept. Opened from the memory sheet, either answer brings the memory sheet back.
struct RemoraClearSheet: View {
    let model: CatalogModel
    let presenter: SheetPresenter<SettingsSheet>
    let returnsToMemory: Bool

    var body: some View {
        InkSheet(
            title: RemoraSettingsText.clearTitle, cancel: leave,
            actions: [SheetAction(id: "clear-memory", title: RemoraSettingsText.clearConfirm, tint: .failure,
                                  perform: { Self.confirm(model: model, presenter: presenter, returnsToMemory: returnsToMemory) })]
        ) {
            SheetText(text: RemoraSettingsText.clearBody)
        }
        .accessibilityIdentifier("settings-sheet-remora-clear")
    }

    private func leave() { Self.leave(presenter: presenter, returnsToMemory: returnsToMemory) }

    /// The one place the working memory is cleared (`Remora.md` stays): the question's own button.
    static func confirm(model: CatalogModel, presenter: SheetPresenter<SettingsSheet>, returnsToMemory: Bool) {
        model.clearRemoraWorkingMemory()
        leave(presenter: presenter, returnsToMemory: returnsToMemory)
    }

    static func leave(presenter: SheetPresenter<SettingsSheet>, returnsToMemory: Bool) {
        if returnsToMemory { presenter.present(.remoraMemory) } else { presenter.dismiss() }
    }
}

/// "Delete N sessions?" for every checked session of the review at once. 480 wide, since it lists what goes.
struct DeleteSessionsSheet: View {
    let review: CleanupReviewModel
    let catalog: CatalogModel
    let profile: URL?
    let presenter: SheetPresenter<SettingsSheet>

    var body: some View {
        let text = DeleteSheetText.make(rows: rows, folder: profile.map(SettingsPaths.display))
        InkSheet(
            title: text.title, subject: text.names, listsFiles: true, cancel: presenter.dismiss,
            actions: [SheetAction(
                id: "delete-permanently", title: SettingsSheetText.deleteConfirm, tint: .failure, isEnabled: review.canDelete,
                perform: {
                    presenter.dismiss()
                    Task { await review.confirmDeletion() }
                })]
        ) {
            SheetText(text: text.lead)
            SheetList(label: "Removed", items: text.removed, meta: text.totals)
            SheetList(label: "Kept", items: text.kept)
        }
        .accessibilityIdentifier("settings-sheet-delete")
    }

    /// The checked rows, in the review's order.
    private var rows: [DeleteSheetText.Row] {
        (review.review?.eligible ?? []).filter { review.isSelected($0.id) }.map {
            DeleteSheetText.Row(title: $0.record.displayTitle(projectName: catalog.projectName(for: $0.record)),
                                fileCount: $0.fileCount, byteCount: $0.byteCount)
        }
    }
}
