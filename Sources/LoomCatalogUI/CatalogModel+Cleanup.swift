import Foundation
import LoomCore
import Observation

// CP4-G: pin (a retention exception, not a pinned tab) and the Settings → Sessions review state.

extension CatalogModel {
    /// Writes `sessions.pinned` and refreshes the card. A pinned conversation is never listed
    /// for cleanup (DP-CP4-5).
    public func setPinned(_ id: UUID, _ pinned: Bool) async {
        guard let catalog else { return }
        do {
            try await catalog.setPinned(pinned, for: id)
        } catch {
            report(error, pinned ? "The session could not be pinned" : "The session could not be unpinned")
            return
        }
        await refreshRow(id)
    }

    /// Offers the cleanup review in Settings (every build, D-69). It deletes only what the user
    /// checks and confirms there.
    public func installCleanupReview(_ reviewing: any CleanupReviewing) {
        cleanupReview = CleanupReviewModel(reviewing: reviewing)
    }
}

/// State of Settings → Sessions. Every list is a snapshot from the coordinator; deleting
/// re-plans in the coordinator and only rows that are checked and still eligible are removed.
@MainActor @Observable
public final class CleanupReviewModel {
    public enum Phase: Equatable {
        case idle
        case loading
        case ready
        case deleting
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var review: CleanupReview?
    public private(set) var selection: Set<UUID> = []
    /// Per-row outcome of the last deletion run, shown on the rows.
    public private(set) var results: [UUID: CleanupRowResult] = [:]
    /// A dismissed due review stops showing the info line until the next one is due.
    public private(set) var dismissed = false
    /// The two cleanup numbers in force (the Cleanup part of the page).
    public private(set) var settings: CleanupSettings = .standard
    /// The numbers changed after the list on screen was made; the next review uses them.
    public private(set) var settingsChangedSinceReview = false
    public private(set) var settingsError: String?
    @ObservationIgnored private var settingsSave: Task<Void, Never>?

    @ObservationIgnored private let reviewing: any CleanupReviewing
    @ObservationIgnored var currentDate: @Sendable () -> Date = { Date() }

    public init(reviewing: any CleanupReviewing) { self.reviewing = reviewing }

    public var isBusy: Bool { phase == .loading || phase == .deleting }
    public var hasResults: Bool { !results.isEmpty }
    public var selectedCount: Int { selection.count }
    public var canDelete: Bool { phase == .ready && !selection.isEmpty && !hasResults }
    /// The quiet info line: a review is due and the user has not dismissed it.
    public var showsDueNotice: Bool { (review?.isDue ?? false) && !dismissed && !hasResults }

    /// Takes a fresh snapshot (Settings opened, or "Review again"). Nothing is checked by default.
    public func open() async {
        guard !isBusy else { return }
        phase = .loading
        do {
            if let stored = try? await reviewing.settings() { settings = stored }
            review = try await reviewing.review(now: currentDate())
            settingsChangedSinceReview = false
            selection = []
            results = [:]
            dismissed = false
            phase = .ready
        } catch {
            phase = .failed("The review could not be made: \(error)")
        }
    }

    public func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    public func setSelected(_ id: UUID, _ selected: Bool) {
        guard phase == .ready, !hasResults, review?.eligible.contains(where: { $0.id == id }) == true else { return }
        if selected { selection.insert(id) } else { selection.remove(id) }
    }

    public func selectAll() {
        guard phase == .ready, !hasResults, let review else { return }
        selection = Set(review.eligible.map(\.id))
    }

    public func clearSelection() { selection = [] }

    /// Deletes the checked conversations one by one through the normal deletion path. The
    /// coordinator re-plans first; a row that is no longer eligible is skipped, never deleted.
    public func confirmDeletion() async {
        guard canDelete, let review else { return }
        let ids = review.eligible.map(\.id).filter(selection.contains)
        phase = .deleting
        results = [:]
        do {
            let confirmation = try await reviewing.confirm(ids: ids, now: currentDate()) { [weak self] id, result in
                await self?.record(id, result)
            }
            results = confirmation.results
            selection = []
            phase = .ready
        } catch {
            phase = .failed("Deleting stopped: \(error)")
        }
    }

    /// Changes the cleanup numbers (held inside their ranges) and keeps them. They apply from the next
    /// review on; a list already on screen is not re-planned by a change.
    public func updateSettings(_ change: (inout CleanupSettings) -> Void) {
        var edited = settings
        change(&edited)
        let updated = CleanupSettings(
            reviewIntervalDays: edited.reviewIntervalDays, deletionWaitDays: edited.deletionWaitDays)
        guard updated != settings else { return }
        settings = updated
        settingsChangedSinceReview = true
        persistSettings { [reviewing] in try await reviewing.setSettings(updated) }
    }

    /// Back to the defaults ("Reset to defaults").
    public func resetSettings() {
        guard !settings.isStandard else { return }
        settings = .standard
        settingsChangedSinceReview = true
        persistSettings { [reviewing] in _ = try await reviewing.resetSettings() }
    }

    /// Waits for the numbers to be kept (tests).
    public func settingsSaved() async { await settingsSave?.value }

    /// Saves one after another, so the last change is the one that stays.
    private func persistSettings(_ save: @escaping @Sendable () async throws -> Void) {
        let previous = settingsSave
        settingsSave = Task { [weak self] in
            await previous?.value
            do {
                try await save()
                self?.settingsError = nil
            } catch {
                self?.settingsError = "The cleanup numbers could not be kept: \(error)"
                if let stored = try? await self?.reviewing.settings() { self?.settings = stored }
            }
        }
    }

    /// Leaves a due review without deleting; it still counts as the cleanup run.
    public func dismissDueReview() async {
        guard showsDueNotice else { return }
        do {
            try await reviewing.dismiss(now: currentDate())
            dismissed = true
        } catch {
            phase = .failed("The review could not be dismissed: \(error)")
        }
    }

    private func record(_ id: UUID, _ result: CleanupRowResult) { results[id] = result }
}

/// The words Settings uses for the planner's reasons and the Cleanup part's two numbers.
enum CleanupText {
    static let reviewIntervalTitle = "Review again after"
    static let reviewIntervalDetail = "A new review is due this long after the last one."
    static let deletionWaitTitle = "Wait before deleting"
    static let deletionWaitDetail = "A stale session can be deleted this long after it went stale or after you last opened it."


    static func reason(_ reason: CleanupExclusionReason) -> String {
        switch reason {
        case .pinned: "Pinned"
        case .running: "Running"
        case .deleting: "Being deleted"
        case .notStale: "Not stale"
        case .waitUntil(let date): "Waits until \(LoomDateFormat.date(date))"
        case .worktree(let detail): detail
        case .task: "Linked to an unfinished task"
        }
    }

    static func result(_ result: CleanupRowResult) -> String {
        switch result {
        case .deleted: "Deleted"
        // The recorded failure is "category: file"; the row shows the category, the file stays in the record.
        case .incomplete(let detail): "Not finished: \(detail.components(separatedBy: ": ").first ?? detail)"
        case .failed(let detail): "Failed: \(detail)"
        case .skipped(let why): "Skipped: \(reason(why))"
        }
    }

    static func size(_ row: CleanupEligibleRow) -> String? {
        row.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}
