import LoomCore
import SwiftUI

// MARK: What the stack can say

/// The banners above a session, as plain values (DESIGN §19 Banners). The model keeps four slots (`ownershipNotice`,
/// `statusMessage`, `errorMessage`, `infoMessage`), the deletion records and the selected session's live issue; `BannerItems`
/// reads them as they are and decides the weight, the order, the symbol and whether × closes the box.
enum BannerKind: Hashable {
    /// A failure the app reported (a start that did not work, a refused action).
    case error
    /// The selected session's live issue ("Sphyrna is not receiving events from Claude…").
    case sessionIssue
    /// Launch recovery could not read a deletion record.
    case deletionRecovery
    /// A deletion that did not finish.
    case deletionFailure(UUID)
    /// What limits the app while its cause holds (the missing helper).
    case ownership
    /// A note ("“x” is already in Sphyrna.").
    case info
    /// Quit or terminal progress.
    case progress
    /// A deletion under way.
    case deleting(UUID)
}

struct BannerItem: Equatable, Identifiable {
    let kind: BannerKind
    let tone: ChatBannerTone
    let text: String
    /// The mono line under the text (a deletion's session title).
    var detail: String?
    /// A row that reports progress shows the spinner in the symbol slot.
    var leading: BannerLeading = .tone
    /// The deletion a row's buttons act on.
    var deletion: UUID?
    var canRetry = false
    var canRemove = false

    var id: BannerKind { kind }

    /// × closes a banner at once and for the session; a notice that holds while its cause holds has none: the missing helper,
    /// the live issue, progress, and a deletion that is pending or failed (it stays visible and retryable).
    var isDismissible: Bool {
        switch kind {
        case .error, .info: true
        case .sessionIssue, .deletionRecovery, .deletionFailure, .ownership, .progress, .deleting: false
        }
    }

    var identifier: String {
        switch kind {
        case .error: "error-message"
        case .sessionIssue: "session-issue-notice"
        case .deletionRecovery: "deletion-recovery-failure"
        case .deletionFailure(let id), .deleting(let id): "deletion-banner-\(id.uuidString.lowercased())"
        case .ownership: "ownership-notice"
        case .info: "info-message"
        case .progress: "status-message"
        }
    }
}

/// A deletion record as the stack reads it.
struct BannerDeletion: Equatable {
    let id: UUID
    /// The session's title kept for the banner; nil or empty when unknown.
    var title: String?
    /// A step is executing now (here or in launch recovery).
    var isDeleting: Bool
    var lastFailure: String?
    var canRetry: Bool
    var canRemove: Bool
}

/// Everything the stack reads, in plain values.
struct BannerSources: Equatable {
    var error: String?
    var sessionIssue: String?
    var recoveryFailure: String?
    var deletions: [BannerDeletion] = []
    var ownership: String?
    var info: String?
    var status: String?
}

enum BannerItems {
    /// By weight: what did not happen first (the failure tone with the triangle), then what limits the app (attention), then notes.
    /// Inside a tone the order is fixed: error, the live issue, the recovery failure, the failed deletions; the ownership notice;
    /// info, progress, the deletions under way.
    static func make(_ sources: BannerSources) -> [BannerItem] {
        var items: [BannerItem] = []
        if let text = sources.error { items.append(BannerItem(kind: .error, tone: .failure, text: text)) }
        if let text = sources.sessionIssue { items.append(BannerItem(kind: .sessionIssue, tone: .failure, text: text)) }
        if let text = sources.recoveryFailure { items.append(BannerItem(kind: .deletionRecovery, tone: .failure, text: text)) }
        for deletion in sources.deletions where !deletion.isDeleting {
            items.append(BannerItem(
                kind: .deletionFailure(deletion.id), tone: .failure, text: DeletionCopy.bannerText(lastFailure: deletion.lastFailure),
                detail: deletion.title.flatMap { $0.isEmpty ? nil : $0 }, deletion: deletion.id,
                canRetry: deletion.canRetry, canRemove: deletion.canRemove))
        }
        if let text = sources.ownership { items.append(BannerItem(kind: .ownership, tone: .attention, text: text)) }
        if let text = sources.info { items.append(BannerItem(kind: .info, tone: .note, text: text)) }
        if let text = sources.status { items.append(BannerItem(kind: .progress, tone: .note, text: text, leading: .spinner)) }
        for deletion in sources.deletions where deletion.isDeleting {
            let title = deletion.title.flatMap { $0.isEmpty ? nil : $0 }
            items.append(BannerItem(
                kind: .deleting(deletion.id), tone: .note, text: title.map { "Deleting \($0)…" } ?? "Deleting a session…",
                leading: .spinner, deletion: deletion.id))
        }
        return ChatBanners.orderedByTone(items)
    }

    /// The boxes drawn now: the first, or all of them while the peek is open.
    static func visible(_ items: [BannerItem], open: Bool) -> [BannerItem] {
        guard let first = items.first else { return [] }
        return open && items.count > 1 ? items : [first]
    }
}

extension ChatBanners {
    /// `ordered` for any item that carries a tone: by weight, and in the order given within a tone.
    static func orderedByTone(_ items: [BannerItem]) -> [BannerItem] {
        items.enumerated().sorted { ($0.element.tone, $0.offset) < ($1.element.tone, $1.offset) }.map(\.element)
    }
}

// MARK: The stack's state

/// What the stack remembers while the window lives: whether "+N" has opened the others. × clears the model's own slot
/// (`dismissError`, `dismissInfo`), so a banner closed at once stays closed until the same thing happens again, which is a new
/// banner; the peek closes by itself when fewer than two boxes are left.
@MainActor @Observable
final class BannerStackState {
    var open = false

    /// The window's stack, for the evidence run's seam only (`CatalogModel+EvidenceBanners`); nothing else reads it.
    static weak var current: BannerStackState?

    func closeIfAlone(_ count: Int) { if count < 2 { open = false } }
}

extension EnvironmentValues {
    /// Whether the top stack shows a box above the pane's own line (the ended line gets 8 above it and a hairline).
    @Entry var bannerStackShown = false
}

// MARK: The model's side

extension Banners {
    /// The stack's sources, read from the model: the four slots, the deletion records and, on a route that shows the session
    /// live (the terminal or the chat), the selected session's live issue.
    @MainActor static func sources(for model: CatalogModel) -> BannerSources {
        let records = model.deletions.pending.values.sorted { ($0.requestedAt, $0.id.uuidString) < ($1.requestedAt, $1.id.uuidString) }
        let issue: String?
        switch model.detailRoute {
        case .terminal, .chat: issue = SessionIssueNotice.message(for: model.selectedRow?.live)
        default: issue = nil
        }
        return BannerSources(
            error: model.errorMessage, sessionIssue: issue, recoveryFailure: model.deletions.recoveryFailure,
            deletions: records.map { record in
                BannerDeletion(id: record.id, title: model.deletions.titles[record.id], isDeleting: model.isDeleting(record.id),
                               lastFailure: record.lastFailure, canRetry: model.canRetryDeletion(record.id),
                               canRemove: model.canRemoveFromLoomOnly(record.id))
            },
            ownership: model.ownershipNotice, info: model.infoMessage, status: model.statusMessage)
    }

    @MainActor static func items(for model: CatalogModel) -> [BannerItem] { BannerItems.make(sources(for: model)) }

    /// Whether the stack takes no layout space at all. The "Preparing…" notice is not part of it: a row here would resize the
    /// terminal below (a PTY resize); it lives in the fixed-height header row.
    @MainActor static func isEmpty(for model: CatalogModel) -> Bool { items(for: model).isEmpty }
}

// MARK: The view

/// The top stack (DESIGN §19 Banners): under the tab row and above the pane's own line, 12 from the edges. One box shows; the
/// rest wait behind "+N", which opens them in place and closes them again. It comes in by opacity only (a height animation
/// would resize the terminal below), and the stack pushes the screen down once.
struct Banners: View {
    let model: CatalogModel
    let items: [BannerItem]
    let state: BannerStackState

    var body: some View {
        if !items.isEmpty {
            let open = state.open && items.count > 1
            VStack(spacing: LoomTheme.Edges.stackGap) {
                ForEach(Array(BannerItems.visible(items, open: state.open).enumerated()), id: \.element.id) { index, item in
                    box(item, peek: index == 0 && items.count > 1, open: open)
                        .fadesIn()
                }
            }
            .padding(.horizontal, LoomTheme.Edges.stackPaddingH).padding(.top, LoomTheme.Edges.stackPaddingTop)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("banner-stack")
        }
    }

    @ViewBuilder private func box(_ item: BannerItem, peek: Bool, open: Bool) -> some View {
        let shown = BannerBox(
            tone: item.tone, leading: item.leading, text: item.text, detail: item.detail, selectable: true,
            textInsetV: LoomTheme.Edges.textInsetV, actions: actions(for: item),
            peek: peek ? BannerPeek(hidden: items.count - 1, open: open, identifier: "banner-stack-peek",
                                    toggle: { state.open.toggle() }) : nil,
            dismiss: item.isDismissible ? BannerDismiss(label: "Dismiss message", perform: { dismiss(item) }) : nil,
            identifier: item.identifier)
        if let id = item.deletion {
            shown.removeFromLoomAlert(model: model, id: id)
        } else {
            shown
        }
    }

    private func dismiss(_ item: BannerItem) {
        switch item.kind {
        case .error: model.dismissError()
        case .info: model.dismissInfo()
        default: break
        }
    }

    /// A failed deletion offers Try Again (the accent tint) and, where the record allows it, Remove from Loom Only (the failure
    /// tint, D-78).
    private func actions(for item: BannerItem) -> [BannerAction] {
        guard case .deletionFailure(let id) = item.kind else { return [] }
        let suffix = id.uuidString.lowercased()
        var actions = [BannerAction(id: "deletion-retry-\(suffix)", title: "Try Again", style: .accent, enabled: item.canRetry,
                                    perform: { Task { await model.retryDeletion(id) } })]
        if item.canRemove {
            actions.append(BannerAction(id: "deletion-remove-\(suffix)", title: "Remove from Loom Only", style: .failure,
                                        help: "Removes the session from Loom. Claude's files are not touched.",
                                        perform: { model.requestRemoveFromLoomOnly(id) }))
        }
        return actions
    }
}
