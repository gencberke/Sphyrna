import Foundation
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// CP4-G at the presentation boundary: pin writes the catalog and the card, and the review model
/// only ever asks for rows that are checked, shows each row's result, and never deletes by itself.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CleanupReviewTests {
    private let now = Date(timeIntervalSince1970: 200 * 86_400)

    private func record(_ title: String) -> CatalogSession {
        CatalogSession(
            session: ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: title,
            createdAt: now.addingTimeInterval(-90 * 86_400), lastUsedAt: now.addingTimeInterval(-60 * 86_400),
            lifecycle: .stale, pinned: false, staleSince: now.addingTimeInterval(-45 * 86_400))
    }

    private func review(due: Bool = true, eligible: [CatalogSession], excluded: [CleanupExcludedRow] = []) -> CleanupReview {
        CleanupReview(
            generatedAt: now, due: due ? .due : .notDue(until: now.addingTimeInterval(86_400)),
            mode: .reviewRequired(.automaticDisabled),
            eligible: eligible.map {
                CleanupEligibleRow(record: $0, eligibleSince: now.addingTimeInterval(-30 * 86_400),
                                   byteCount: 2_048, fileCount: 2)
            },
            excluded: excluded)
    }

    final class FakeBackend: CleanupReviewing, @unchecked Sendable {
        private let lock = NSLock()
        var snapshot: CleanupReview
        var results: [UUID: CleanupRowResult] = [:]
        private(set) var confirmed: [[UUID]] = []
        private(set) var dismissals = 0
        private(set) var reviews = 0

        init(snapshot: CleanupReview) { self.snapshot = snapshot }

        func review(now: Date) async throws -> CleanupReview {
            lock.withLock { reviews += 1; return snapshot }
        }

        func confirm(ids: [UUID], now: Date,
                     progress: @escaping @Sendable (UUID, CleanupRowResult) async -> Void) async throws -> CleanupConfirmation {
            let outcome = lock.withLock { () -> [UUID: CleanupRowResult] in
                confirmed.append(ids)
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, results[$0] ?? .deleted) })
            }
            for id in ids { await progress(id, outcome[id]!) }
            return CleanupConfirmation(results: outcome, review: snapshot)
        }

        func dismiss(now: Date) async throws { lock.withLock { dismissals += 1 } }
    }

    @Test func nothingIsCheckedByDefaultAndOnlyCheckedRowsAreConfirmed() async throws {
        let rows = [record("a"), record("b"), record("c")]
        let backend = FakeBackend(snapshot: review(eligible: rows))
        let model = CleanupReviewModel(reviewing: backend)
        await model.open()
        #expect(model.phase == .ready)
        #expect(model.selection.isEmpty)
        #expect(!model.canDelete)
        // A tap on the button with nothing checked asks for nothing.
        await model.confirmDeletion()
        #expect(backend.confirmed.isEmpty)

        model.setSelected(rows[2].session.id, true)
        model.setSelected(rows[0].session.id, true)
        model.setSelected(UUID(), true)   // not on the list: ignored
        #expect(model.selectedCount == 2)
        await model.confirmDeletion()
        #expect(backend.confirmed == [[rows[0].session.id, rows[2].session.id]])
        #expect(model.results[rows[0].session.id] == .deleted)
        #expect(model.results[rows[1].session.id] == nil)
        #expect(model.selection.isEmpty)
        #expect(!model.canDelete)
    }

    @Test func aFailedRowShowsItsResultAndTheRunStillFinishes() async throws {
        let rows = [record("a"), record("b")]
        let backend = FakeBackend(snapshot: review(eligible: rows))
        backend.results[rows[0].session.id] = .failed("shared provider data")
        let model = CleanupReviewModel(reviewing: backend)
        await model.open()
        model.selectAll()
        await model.confirmDeletion()
        #expect(model.results[rows[0].session.id] == .failed("shared provider data"))
        #expect(model.results[rows[1].session.id] == .deleted)
        #expect(CleanupText.result(model.results[rows[0].session.id]!) == "Failed: shared provider data")
        // A finished run cannot be repeated from the old snapshot; reviewing again starts clean.
        model.setSelected(rows[1].session.id, true)
        #expect(model.selection.isEmpty)
        await model.open()
        #expect(model.results.isEmpty)
        #expect(backend.reviews == 2)
    }

    @Test func aDueReviewShowsAQuietLineAndDismissIsRecordedOnce() async throws {
        let backend = FakeBackend(snapshot: review(eligible: [record("a")]))
        let model = CleanupReviewModel(reviewing: backend)
        await model.open()
        #expect(model.showsDueNotice)
        await model.dismissDueReview()
        #expect(!model.showsDueNotice)
        await model.dismissDueReview()
        #expect(backend.dismissals == 1)

        let quiet = CleanupReviewModel(reviewing: FakeBackend(snapshot: review(due: false, eligible: [record("a")])))
        await quiet.open()
        #expect(!quiet.showsDueNotice)
        await quiet.dismissDueReview()
    }

    @Test func theReviewIsOfferedOnlyWhereTheAppInstallsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-cp4g-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(
            catalog: try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3")),
            events: SessionEventHub(), preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        #expect(model.cleanupReview == nil)
        model.installCleanupReview(FakeBackend(snapshot: review(eligible: [])))
        #expect(model.cleanupReview != nil)
        #expect(SettingsSection.available(cleanupReview: true).contains(.conversations))
        #expect(!SettingsSection.available(cleanupReview: false).contains(.conversations))
    }

    @Test func pinWritesTheCatalogAndTheCard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-cp4g-pin-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        let catalog = try SessionCatalog(url: url)
        let session = ManagedSession(provider: .claude, workingDirectory: "/tmp")
        try await catalog.insertSession(session, title: "card", lifecycle: .idle)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        defer { model.stop() }
        let row = try #require(model.list(for: .activity).rows.first { $0.id == session.id })
        #expect(!row.record.pinned)

        await model.setPinned(session.id, true)
        #expect(row.record.pinned)
        #expect(try await SessionCatalog(url: url).session(id: session.id)?.pinned == true)
        await model.setPinned(session.id, false)
        #expect(!row.record.pinned)
        #expect(try await SessionCatalog(url: url).session(id: session.id)?.pinned == false)
        // An unknown conversation is reported, not silently ignored.
        await model.setPinned(UUID(), true)
        #expect(model.errorMessage != nil)
    }
}
