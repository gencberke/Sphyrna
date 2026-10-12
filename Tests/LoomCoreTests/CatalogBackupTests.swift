import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore

/// H1-B item 8: the catalog backup (daily, three kept, never holding a deleted session) and the
/// restore / start-fresh actions of the launch prompt.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CatalogBackupTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loom-backup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func catalog(_ root: URL, titles: [String]) async throws -> (SessionCatalog, [UUID]) {
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var ids: [UUID] = []
        for title in titles {
            let session = ManagedSession(provider: .claude, workingDirectory: "/tmp")
            try await catalog.insertSession(session, title: title)
            ids.append(session.id)
        }
        return (catalog, ids)
    }

    /// The titles a catalog file holds, read from a copy so the file itself is never touched.
    private func titles(in file: URL) async throws -> Set<String> {
        let copyRoot = try root()
        defer { try? FileManager.default.removeItem(at: copyRoot) }
        let copy = copyRoot.appendingPathComponent("catalog.sqlite3")
        try FileManager.default.copyItem(at: file, to: copy)
        let reopened = try SessionCatalog(url: copy)
        return Set(try await reopened.sessions().compactMap(\.title))
    }

    private func allBytes(under folder: URL) throws -> Data {
        var data = Data()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            data.append(try Data(contentsOf: folder.appendingPathComponent(name)))
        }
        return data
    }

    private func damage(_ root: URL) throws {
        let url = root.appendingPathComponent("catalog.sqlite3")
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        try Data(repeating: 0x41, count: 8_192).write(to: url)
    }

    // MARK: Taking

    @Test func aBackupHoldsTheLiveRowsAndAnotherIsOnlyDueAfterADay() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (catalog, _) = try await catalog(root, titles: ["one", "two"])
        let store = catalog.backupStore
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        guard case let .created(info) = await store.backUpIfDue(now: now) else { Issue.record("no backup"); return }
        #expect(info.url.deletingLastPathComponent().lastPathComponent == "backups")
        #expect(info.url.lastPathComponent.hasPrefix("catalog-") && info.url.pathExtension == "sqlite3")
        #expect(try await titles(in: info.url) == ["one", "two"])
        #expect(await store.backUpIfDue(now: now.addingTimeInterval(23 * 3_600)) == .notDue)
        guard case .created = await store.backUpIfDue(now: now.addingTimeInterval(25 * 3_600)) else {
            Issue.record("a day later a backup is due"); return
        }
        #expect(store.list().count == 2)
        // No partial copy is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).allSatisfy { !$0.hasSuffix(".partial") })
    }

    @Test func onlyTheThreeNewestBackupsAreKept() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (catalog, _) = try await catalog(root, titles: ["a"])
        let store = catalog.backupStore
        let start = Date(timeIntervalSince1970: 1_791_374_400)
        for day in 0..<5 { _ = await store.backUp(now: start.addingTimeInterval(Double(day) * 86_400)) }
        let kept = store.list()
        #expect(kept.count == 3)
        #expect(kept.map(\.createdAt) == [4, 3, 2].map { start.addingTimeInterval(Double($0) * 86_400) })
    }

    @Test func aBackupWithAClockAheadOfNowDoesNotBlockTheNextOne() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (catalog, _) = try await catalog(root, titles: ["a"])
        let store = catalog.backupStore
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        _ = await store.backUp(now: now.addingTimeInterval(10 * 86_400))
        guard case .created = await store.backUpIfDue(now: now) else { Issue.record("blocked by a future stamp"); return }
    }

    // MARK: The deletion contract

    @Test func deletingASessionRemovesEveryBackupAndTheNextOneDoesNotHoldIt() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (catalog, ids) = try await catalog(root, titles: ["MARKER-DELETED-TITLE", "kept title"])
        let store = catalog.backupStore
        for day in 0..<3 { _ = await store.backUp(now: Date(timeIntervalSince1970: 1_791_374_400 + Double(day) * 86_400)) }
        #expect(store.list().count == 3)
        #expect(try allBytes(under: store.directory).range(of: Data("MARKER-DELETED-TITLE".utf8)) != nil)

        #expect(try await catalog.deleteSessionRows(sessionID: ids[0]))
        #expect(store.list().isEmpty)
        #expect(try allBytes(under: store.directory).isEmpty)

        guard case let .created(fresh) = await store.backUp() else { Issue.record("no fresh backup"); return }
        #expect(try await titles(in: fresh.url) == ["kept title"])
        #expect(try allBytes(under: store.directory).range(of: Data("MARKER-DELETED-TITLE".utf8)) == nil)
    }

    @Test func aCopyBeingWrittenWhenADeletionFinishesIsDiscarded() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (catalog, ids) = try await catalog(root, titles: ["gone soon", "stays"])
        let store = catalog.backupStore
        // A deletion lands after the copy was made and checked, before it is accepted.
        store.setAfterCopyHookForTesting { [store] in store.invalidateInFlightForTesting() }
        #expect(await store.backUp() == .superseded)
        #expect(store.list().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
        store.setAfterCopyHookForTesting(nil)
        // And a purge that removes the files while the copy is still being written ends the same way.
        store.setAfterCopyHookForTesting { [store] in store.purgeAll() }
        #expect(await store.backUp() == .superseded)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
        store.setAfterCopyHookForTesting(nil)
        _ = ids
    }

    @Test func finishingADeletionRecordAlsoRemovesTheBackups() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (catalog, _) = try await catalog(root, titles: ["a"])
        _ = await catalog.backupStore.backUp()
        #expect(catalog.backupStore.list().count == 1)
        try await catalog.finishDeletion(sessionID: UUID())   // absent is not an error; the purge still happens
        #expect(catalog.backupStore.list().isEmpty)
    }

    // MARK: Restore

    @Test func aDamagedCatalogIsDetectedAndRestoredFromABackupWithTheDamagedFilesKept() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        do {
            let (catalog, _) = try await catalog(root, titles: ["first", "second"])
            _ = await catalog.backupStore.backUp()
        }
        try damage(root)
        try Data("wal bytes".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        do { _ = try SessionCatalog(url: url); Issue.record("opened a damaged catalog") }
        catch let error as SessionCatalogError { #expect(error.isDamaged) }

        let backup = try #require(CatalogRecovery.backups(forCatalogAt: url).first)
        let aside = try #require(try CatalogRecovery.restore(backup, intoCatalogAt: url))
        #expect(aside.lastPathComponent.hasPrefix("catalog.damaged-") && aside.pathExtension == "sqlite3")
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(FileManager.default.fileExists(atPath: aside.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: url.path + ".restoring"))

        let reopened = try SessionCatalog(url: url)
        #expect(Set(try await reopened.sessions().compactMap(\.title)) == ["first", "second"])
        // The backup itself is untouched and still listed.
        #expect(CatalogRecovery.backups(forCatalogAt: url).count == 1)
        #expect(DiagnosticJournal.forDataRoot(root).lines().contains { $0.contains("\"restored\"") })
    }

    @Test func aBrokenButOpenableFileIsAlsoDamage() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        do { let (catalog, _) = try await catalog(root, titles: ["row"]); _ = catalog }
        // Keep the 100-byte header (so the file still opens as SQLite) and ruin the schema page after it.
        var bytes = try Data(contentsOf: url)
        bytes.replaceSubrange(100..<600, with: Data(repeating: 0xFF, count: 500))
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        try bytes.write(to: url)
        do { _ = try SessionCatalog(url: url); Issue.record("opened a catalog with a broken schema page") }
        catch let error as SessionCatalogError { #expect(error.isDamaged, "\(error)") }
    }

    @Test func startFreshMovesTheCatalogAsideAndTheNextOpenIsEmpty() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        _ = try await catalog(root, titles: ["x"])
        try damage(root)
        let aside = try #require(try CatalogRecovery.startFresh(catalogAt: url))
        #expect(aside.lastPathComponent.hasPrefix("catalog.damaged-"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let fresh = try SessionCatalog(url: url)
        #expect(try await fresh.sessions().isEmpty)
    }

    @Test func aBackupThatDoesNotOpenIsRefusedAndNothingChanges() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        _ = try await catalog(root, titles: ["x"])
        try damage(root)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let bad = backups.appendingPathComponent("catalog-20261001-120000-000.sqlite3")
        try Data(repeating: 0x42, count: 5_000).write(to: bad)
        let info = try #require(CatalogRecovery.backups(forCatalogAt: url).first)
        do { _ = try CatalogRecovery.restore(info, intoCatalogAt: url); Issue.record("restored a broken backup") }
        catch let error as CatalogRecoveryError { guard case .backupUnreadable = error else { Issue.record("\(error)"); return } }
        #expect(FileManager.default.fileExists(atPath: url.path))                      // the catalog was not moved
        #expect(!FileManager.default.fileExists(atPath: url.path + ".restoring"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains("damaged") })
    }

    @Test func onlyAFileInTheBackupFolderWithABackupNameCanBeRestored() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        _ = try await catalog(root, titles: ["x"])
        let elsewhere = CatalogBackupInfo(url: root.appendingPathComponent("catalog-20261001-120000-000.sqlite3"),
                                          createdAt: Date(), byteCount: 0)
        #expect(throws: CatalogRecoveryError.notABackup) { try CatalogRecovery.restore(elsewhere, intoCatalogAt: url) }
        let renamed = CatalogBackupInfo(url: root.appendingPathComponent("backups/notes.txt"), createdAt: Date(), byteCount: 0)
        #expect(throws: CatalogRecoveryError.notABackup) { try CatalogRecovery.restore(renamed, intoCatalogAt: url) }
    }

    @Test func aRestoreInterruptedAfterTheCatalogWentAsideIsCompletedByTheNextOpen() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        do { let (catalog, _) = try await catalog(root, titles: ["kept"]); _ = await catalog.backupStore.backUp() }
        try damage(root)
        try Data("w".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        let backup = try #require(CatalogRecovery.backups(forCatalogAt: url).first)
        struct Crash: Error {}
        #expect(throws: Crash.self) {
            try CatalogRecovery.restore(backup, intoCatalogAt: url, now: Date()) { step in
                if step == .movedAside { throw Crash() }
            }
        }
        // The state a crash at that point leaves: no catalog, a verified staging copy, the old files aside.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: url.path + ".restoring"))
        // A stray log of the old file must not be replayed into the restored one.
        try Data("stray".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))

        let reopened = try SessionCatalog(url: url)
        #expect(Set(try await reopened.sessions().compactMap(\.title)) == ["kept"])
        #expect(!FileManager.default.fileExists(atPath: url.path + ".restoring"))
        #expect(DiagnosticJournal.forDataRoot(root).lines().contains { $0.contains("completed_after_interruption") })
    }

    @Test func aRestoreInterruptedBeforeAnythingMovedLeavesTheCatalogAndAllowsARetry() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite3")
        do { let (catalog, _) = try await catalog(root, titles: ["kept"]); _ = await catalog.backupStore.backUp() }
        try damage(root)
        let backup = try #require(CatalogRecovery.backups(forCatalogAt: url).first)
        struct Crash: Error {}
        for step in [CatalogRecovery.Step.copied, .verified] {
            #expect(throws: Crash.self) {
                try CatalogRecovery.restore(backup, intoCatalogAt: url, now: Date()) { if $0 == step { throw Crash() } }
            }
            #expect(FileManager.default.fileExists(atPath: url.path))                  // still the damaged file
        }
        // The open that follows still reports the damage (and drops the unfinished staging copy) ...
        do { _ = try SessionCatalog(url: url); Issue.record("opened a damaged catalog") } catch {}
        #expect(!FileManager.default.fileExists(atPath: url.path + ".restoring"))
        // ... and the restore can simply be run again.
        _ = try CatalogRecovery.restore(backup, intoCatalogAt: url)
        #expect(Set(try await SessionCatalog(url: url).sessions().compactMap(\.title)) == ["kept"])
    }
}
