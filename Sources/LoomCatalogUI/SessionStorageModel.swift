import Foundation
import LoomCore
import Observation

/// Settings → Sessions → Storage (RESCUE C1): what each of Sphyrna's sessions keeps on disk, largest first, by project, and
/// Claude's own retention. The sizes are the deletion allowlist's dry run (`CleanupReviewing.storage`), measured off the main
/// actor and only when the section shows, then kept until a deletion or Refresh. Deleting goes through the coordinator's
/// verified deletion, one session at a time, as the review's Delete does.
@MainActor @Observable
public final class SessionStorageModel {
    public enum Phase: Equatable {
        case idle
        case loading
        case ready
        case deleting
        case failed(String)
    }

    /// Which sessions the list shows.
    public enum ProjectFilter: Hashable, Sendable {
        case all
        case project(UUID)
        case noProject
    }

    /// One project's sessions in the list, with their total.
    public struct Group: Equatable, Identifiable {
        public let id: UUID?
        public let title: String
        public let totalBytes: Int64
        public let rows: [SessionStorageRow]
    }

    public private(set) var phase: Phase = .idle
    public private(set) var report: SessionStorageReport?
    public var filter: ProjectFilter = .all
    public private(set) var selection: Set<UUID> = []
    public private(set) var results: [UUID: CleanupRowResult] = [:]
    public private(set) var retention: ClaudeRetention?
    public private(set) var retentionError: String?

    @ObservationIgnored private let reviewing: any CleanupReviewing
    @ObservationIgnored var currentDate: @Sendable () -> Date = { Date() }

    public init(reviewing: any CleanupReviewing) { self.reviewing = reviewing }

    public var isBusy: Bool { phase == .loading || phase == .deleting }
    public var canDelete: Bool { phase == .ready && !selectedRows.isEmpty }

    /// The section shows: measures once, then keeps the numbers until a deletion or `refresh`.
    public func open() async {
        if retention == nil { await loadRetention() }
        guard report == nil, !isBusy else { return }
        await load()
    }

    /// "Refresh": measures again.
    public func refresh() async {
        guard !isBusy else { return }
        await loadRetention()
        await load()
    }

    private func load() async {
        phase = .loading
        do {
            report = try await reviewing.storage(now: currentDate())
            selection = selection.filter { id in report?.rows.contains { $0.id == id && !$0.isRunning } == true }
            phase = .ready
        } catch {
            phase = .failed("The sizes could not be read: \(error)")
        }
    }

    // MARK: The list

    /// The rows the filter keeps, grouped by project (largest project first, "No project" last), each group largest first.
    public func groups(projectName: (UUID) -> String?) -> [Group] {
        guard let report else { return [] }
        let kept = report.rows.filter { row in
            switch filter {
            case .all: true
            case let .project(id): row.record.projectID == id
            case .noProject: row.record.projectID == nil
            }
        }
        var order: [UUID?] = []
        var byProject: [UUID?: [SessionStorageRow]] = [:]
        for row in kept {
            let key = row.record.projectID
            if byProject[key] == nil { order.append(key) }
            byProject[key, default: []].append(row)
        }
        let groups = order.map { key -> Group in
            let rows = byProject[key] ?? []
            return Group(id: key, title: key.flatMap(projectName) ?? "No project",
                         totalBytes: rows.reduce(0) { $0 + ($1.byteCount ?? 0) }, rows: rows)
        }
        return groups.sorted { lhs, rhs in
            if (lhs.id == nil) != (rhs.id == nil) { return rhs.id == nil }
            return lhs.totalBytes > rhs.totalBytes
        }
    }

    /// The projects the filter offers: those with a session in the report.
    public var projectIDs: [UUID] {
        var seen = Set<UUID>()
        return (report?.rows ?? []).compactMap(\.record.projectID).filter { seen.insert($0).inserted }
    }

    public var hasSessionsWithoutProject: Bool { report?.rows.contains { $0.record.projectID == nil } ?? false }

    // MARK: Selection

    /// Why a row cannot be checked; nil when it can.
    public func refusal(_ row: SessionStorageRow) -> String? {
        if row.isRunning { return "Running" }
        if results[row.id] == .deleted { return "Deleted" }
        return nil
    }

    public func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    public func setSelected(_ id: UUID, _ selected: Bool) {
        guard phase == .ready, let row = report?.rows.first(where: { $0.id == id }), refusal(row) == nil else { return }
        if selected { selection.insert(id) } else { selection.remove(id) }
    }

    public func clearSelection() { selection = [] }

    /// The checked rows, largest first.
    public var selectedRows: [SessionStorageRow] {
        (report?.rows ?? []).filter { selection.contains($0.id) && refusal($0) == nil }
    }

    // MARK: Deleting

    /// The Delete sheet's button: each checked session through the verified deletion, then the sizes are measured again.
    public func confirmDeletion() async {
        guard canDelete else { return }
        let ids = selectedRows.map(\.id)
        phase = .deleting
        results = [:]
        let outcome = await reviewing.deleteFromStorage(ids: ids) { [weak self] id, result in
            await self?.record(id, result)
        }
        results = outcome
        selection = []
        report = nil
        await load()
    }

    private func record(_ id: UUID, _ result: CleanupRowResult) { results[id] = result }

    // MARK: Claude's retention

    public func loadRetention() async {
        retention = await reviewing.retention()
    }

    /// The days Claude keeps transcripts, when known.
    public var retentionDays: Int? {
        if case let .days(days, _) = retention { return days }
        return nil
    }

    /// The confirmation's button: writes `cleanupPeriodDays` only.
    public func setRetention(days: Int) async {
        do {
            try await reviewing.setRetention(days: days)
            retentionError = nil
        } catch {
            retentionError = "Claude's retention was not changed: \(error)"
        }
        await loadRetention()
    }
}

/// The words of the Storage section.
enum StorageText {
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// "Claude keeps 4.6 GB of transcripts in total, including sessions started outside Sphyrna."
    static func projectsFolder(_ bytes: Int64) -> String {
        "Claude keeps \(size(bytes)) of transcripts in total, including sessions started outside Sphyrna."
    }

    static func retention(_ retention: ClaudeRetention?) -> String {
        switch retention {
        case let .days(days, stated)?:
            "Claude deletes transcripts older than \(CleanupNumberUnit.days(days))" + (stated ? "." : " (its default).")
        case let .unreadable(reason)?: "Claude's retention could not be read: \(reason)."
        case nil: "Reading Claude's retention."
        }
    }

    static let retentionTitle = "Change Claude's retention?"
    static func retentionBody(days: Int, file: String) -> String {
        "Claude Code deletes its transcripts older than \(CleanupNumberUnit.days(days)) when it starts, also those of sessions "
            + "started outside Sphyrna. Sphyrna writes only cleanupPeriodDays in \(file) and keeps everything else in it."
    }
}
