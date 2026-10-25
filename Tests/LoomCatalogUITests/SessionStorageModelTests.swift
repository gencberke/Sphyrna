import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// Settings → Sessions → Storage at the presentation boundary (RESCUE C1): measured once while shown and kept until a deletion
/// or Refresh, grouped by project with totals, a running session never checked, and Claude's retention through the coordinator.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SessionStorageModelTests {
    private let now = Date(timeIntervalSince1970: 200 * 86_400)

    private func record(_ title: String, project: UUID?) -> CatalogSession {
        CatalogSession(
            session: ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: title,
            createdAt: now.addingTimeInterval(-9 * 86_400), lastUsedAt: now.addingTimeInterval(-86_400),
            lifecycle: .active, pinned: false, projectID: project)
    }

    final class Backend: CleanupReviewing, @unchecked Sendable {
        private let lock = NSLock()
        var rows: [SessionStorageRow]
        private(set) var storageReads = 0
        private(set) var deleted: [[UUID]] = []
        private(set) var retentionDays = 30
        init(rows: [SessionStorageRow]) { self.rows = rows }

        func review(now: Date) async throws -> CleanupReview {
            CleanupReview(generatedAt: now, due: .notDue(until: now), mode: .reviewRequired(.automaticDisabled), eligible: [],
                          excluded: [])
        }
        func confirm(ids: [UUID], now: Date,
                     progress: @escaping @Sendable (UUID, CleanupRowResult) async -> Void) async throws -> CleanupConfirmation {
            CleanupConfirmation(results: [:], review: try await review(now: now))
        }
        func dismiss(now: Date) async throws {}
        func settings() async throws -> CleanupSettings { .standard }
        func setSettings(_ settings: CleanupSettings) async throws {}
        func resetSettings() async throws -> CleanupSettings { .standard }

        func storage(now: Date) async throws -> SessionStorageReport {
            lock.withLock {
                storageReads += 1
                return SessionStorageReport(generatedAt: now, rows: rows, configDirectory: "/tmp/profile",
                                            projectsFolderBytes: 4_600_000_000)
            }
        }
        func deleteFromStorage(ids: [UUID], progress: @escaping @Sendable (UUID, CleanupRowResult) async -> Void) async
            -> [UUID: CleanupRowResult] {
            lock.withLock {
                deleted.append(ids)
                rows.removeAll { ids.contains($0.id) }
            }
            for id in ids { await progress(id, .deleted) }
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, .deleted) })
        }
        func retention() async -> ClaudeRetention { lock.withLock { .days(retentionDays, stated: retentionDays != 30) } }
        func setRetention(days: Int) async throws { lock.withLock { retentionDays = days } }
    }

    @Test func theListIsGroupedByProjectLargestFirstAndARunningSessionCannotBeChecked() async throws {
        let api = UUID(), web = UUID()
        let small = SessionStorageRow(record: record("small", project: api), byteCount: 2_000, fileCount: 1, isRunning: false)
        let big = SessionStorageRow(record: record("big", project: web), byteCount: 7_300_000, fileCount: 9, isRunning: false)
        let live = SessionStorageRow(record: record("live", project: api), byteCount: 9_000_000, fileCount: 4, isRunning: true)
        let loose = SessionStorageRow(record: record("loose", project: nil), byteCount: 99_000_000, fileCount: 1, isRunning: false)
        let backend = Backend(rows: [small, big, live, loose])
        let storage = SessionStorageModel(reviewing: backend)

        await storage.open()
        await storage.open()
        #expect(backend.storageReads == 1, "measured once while shown, then kept")
        let total: Int64 = 2_000 + 7_300_000 + 9_000_000 + 99_000_000
        #expect(storage.report?.totalBytes == total, "\(String(describing: storage.report?.rows.map(\.byteCount)))")
        let names: [UUID: String] = [api: "api", web: "web"]
        let groups = storage.groups(projectName: { names[$0] })
        #expect(groups.map(\.title) == ["api", "web", "No project"], "largest project first, the loose sessions last")
        #expect(groups[0].rows.compactMap(\.record.title) == ["live", "small"] && groups[0].totalBytes == 9_002_000)
        storage.filter = .project(web)
        #expect(storage.groups(projectName: { names[$0] }).map(\.title) == ["web"])
        storage.filter = .all

        storage.setSelected(live.id, true)
        #expect(!storage.isSelected(live.id) && storage.refusal(live) == "Running")
        storage.setSelected(big.id, true)
        storage.setSelected(small.id, true)
        #expect(storage.canDelete && storage.selectedRows.map(\.id) == [big.id, small.id])

        await storage.confirmDeletion()
        #expect(backend.deleted == [[big.id, small.id]], "only the checked ones, through the coordinator")
        #expect(backend.storageReads == 2, "a deletion measures again")
        #expect(storage.report?.rows.map(\.id) == [loose.id, live.id] && storage.selection.isEmpty)

        await storage.refresh()
        #expect(backend.storageReads == 3)
    }

    @Test func claudesRetentionIsReadAndChangedThroughTheCoordinator() async throws {
        let backend = Backend(rows: [])
        let storage = SessionStorageModel(reviewing: backend)
        await storage.open()
        #expect(storage.retention == .days(30, stated: false))
        #expect(StorageText.retention(storage.retention) == "Claude deletes transcripts older than 30 days (its default).")
        await storage.setRetention(days: 90)
        #expect(storage.retentionDays == 90 && storage.retentionError == nil)
        #expect(StorageText.projectsFolder(4_600_000_000)
            == "Claude keeps \(StorageText.size(4_600_000_000)) of transcripts in total, including sessions started outside Sphyrna.")
    }

    @Test func theOverviewsUsageBlockSplitsMainAndSubagents() {
        let usage = SessionUsage(
            main: SessionUsage.Part(tokens: UsageTokens(input: 1_000, output: 200, cacheWrite5m: 50, cacheRead: 30_000),
                                    estimatedCostUSD: 0.5, messageCount: 3),
            subagents: SessionUsage.Part(tokens: UsageTokens(input: 9_000, output: 900), estimatedCostUSD: 1.5, messageCount: 4))
        let text = OverviewUsageText(usage)
        #expect(text.columns.map(\.title) == ["Main", "Subagents", "Total"])
        #expect(text.columns[2].input == UsageFormat.tokens(10_000) && text.columns[2].cost == UsageFormat.cost(2.0))
        let unknown = SessionUsage(main: usage.main, subagents: SessionUsage.Part(estimatedCostUSD: nil, messageCount: 1))
        #expect(OverviewUsageText(unknown).columns[2].cost == "\u{2014}", "a total with an unpriced part is not a guess")
    }
}
