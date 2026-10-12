import Darwin
import Foundation
import SQLite3

/// One catalog backup on disk (`<data root>/backups/catalog-<timestamp>.sqlite3`).
public struct CatalogBackupInfo: Equatable, Sendable, Identifiable {
    public let url: URL
    public let createdAt: Date
    public let byteCount: Int64
    public var id: String { url.path }
}

public enum CatalogBackupOutcome: Equatable, Sendable {
    case created(CatalogBackupInfo)
    /// The newest backup is younger than 24 hours (or one is being written).
    case notDue
    /// A deletion finished while the backup was being written: it was discarded, because it could
    /// still hold the deleted session.
    case superseded
    /// An error category, never a path or content.
    case failed(String)
}

public enum CatalogRecoveryError: Error, CustomStringConvertible, Equatable, Sendable {
    /// The file is not one of this catalog's backups.
    case notABackup
    case backupMissing
    /// The backup did not open and pass its integrity check; nothing was changed.
    case backupUnreadable(String)
    case io(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .notABackup: "That file is not a backup of this catalog"
        case .backupMissing: "The backup no longer exists"
        case let .backupUnreadable(category): "The backup could not be opened (\(category)); the catalog was not changed"
        case let .io(operation, code): "Restoring failed at \(operation) (errno \(code))"
        }
    }
}

public extension SessionCatalogError {
    /// The open failed because the file is damaged (not because it is newer, foreign or busy): the
    /// case a launch prompt offers a backup or a fresh start for.
    var isDamaged: Bool {
        guard case let .sqlite(_, code, _) = self else { return false }
        return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }
}

/// Takes and prunes the catalog's backups. One instance per catalog file (`forCatalog(at:)`), so
/// the deletion rule below sees every backup in flight.
///
/// Backups are `VACUUM INTO` copies written through a second connection, off the catalog actor and
/// off the main thread: a copy holds only live rows. A backup must never keep a permanently
/// deleted session (contract §8), so `purgeAll` (called when a deletion removes its rows and when
/// it finishes) removes every backup and discards any copy still being written; the app then takes
/// a fresh one.
public final class CatalogBackupStore: @unchecked Sendable {
    public static let keepCount = 3
    public static let minimumInterval: TimeInterval = 24 * 3_600

    public let catalogURL: URL
    public var directory: URL { catalogURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true) }

    private let lock = NSLock()
    private var generation = 0
    private var writing = false
    /// Test seam: runs after the copy is written and before it is accepted.
    var afterCopyHook: (@Sendable () -> Void)?
    func setAfterCopyHookForTesting(_ hook: (@Sendable () -> Void)?) { afterCopyHook = hook }
    /// Test seam: a deletion landing while a copy is written, without removing any file.
    func invalidateInFlightForTesting() { lock.withLock { generation += 1 } }

    private static let registry = NSLock()
    nonisolated(unsafe) private static var stores: [String: CatalogBackupStore] = [:]

    public static func forCatalog(at url: URL) -> CatalogBackupStore {
        let key = url.standardizedFileURL.path
        return registry.withLock {
            if let existing = stores[key] { return existing }
            let created = CatalogBackupStore(catalogURL: url.standardizedFileURL)
            stores[key] = created
            return created
        }
    }

    init(catalogURL: URL) { self.catalogURL = catalogURL }

    private var journal: DiagnosticJournal { .forDataRoot(catalogURL.deletingLastPathComponent()) }

    // MARK: Listing

    /// Complete backups, newest first.
    public func list() -> [CatalogBackupInfo] { CatalogRecovery.backups(forCatalogAt: catalogURL) }

    // MARK: Taking

    /// A backup when the newest one is older than 24 hours (or none exists). Cheap when not due.
    @discardableResult
    public func backUpIfDue(now: Date = Date()) async -> CatalogBackupOutcome {
        if let newest = list().first, newest.createdAt <= now,
           now.timeIntervalSince(newest.createdAt) < Self.minimumInterval {
            return .notDue
        }
        return await backUp(now: now, waitingForOneInFlight: false)
    }

    /// A backup now (the app calls this after a deletion finished: an earlier copy still being
    /// written is discarded by the deletion, so this one waits for it and then takes a fresh one).
    /// One at a time.
    @discardableResult
    public func backUp(now: Date = Date()) async -> CatalogBackupOutcome {
        await backUp(now: now, waitingForOneInFlight: true)
    }

    private func backUp(now: Date, waitingForOneInFlight wait: Bool) async -> CatalogBackupOutcome {
        var started: Int?
        for attempt in 0..<300 {
            started = lock.withLock {
                guard !writing else { return nil }
                writing = true
                return generation
            }
            if started != nil || !wait || Task.isCancelled { break }
            if attempt < 299 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard let started else { return .notDue }
        let outcome = await Task.detached(priority: .utility) { [self] in write(now: now, generation: started) }.value
        lock.withLock { writing = false }
        switch outcome {
        case let .created(info):
            let kept = list().count
            LoomLog.notice(.catalog, "Catalog backup written (\(info.byteCount) bytes, \(kept) kept)")
            journal.record("catalog_backup", ["outcome": "created", "bytes": .int(Int(info.byteCount)), "kept": .int(kept)])
        case .superseded:
            LoomLog.notice(.catalog, "Catalog backup discarded: a deletion finished while it was written")
            journal.record("catalog_backup", ["outcome": "superseded"])
        case let .failed(category):
            LoomLog.error(.catalog, key: "backup", "Catalog backup failed (\(category))")
            journal.record("catalog_backup", ["outcome": "failed", "category": .string(category)])
        case .notDue:
            break
        }
        return outcome
    }

    /// Removes every backup and makes a copy that is still being written discard itself.
    public func purgeAll() {
        lock.withLock {
            generation += 1
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where CatalogRecovery.isBackupName(name) || name.hasSuffix(".partial") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        journal.record("catalog_backup", ["outcome": "purged"])
    }

    /// Removes the damaged catalogs set aside by a restore or a fresh start (`catalog.damaged-<stamp>.sqlite3`
    /// with their -wal and -shm). Like a backup, such a file can still hold a session that is now being
    /// permanently deleted (contract §8), so every deletion removes them.
    public func purgeDamagedCopies() {
        let removed = CatalogRecovery.removeDamagedCopies(besideCatalogAt: catalogURL)
        guard removed > 0 else { return }
        LoomLog.notice(.catalog, "Removed \(removed) set-aside damaged catalog file(s) with a permanent deletion")
        journal.record("catalog_damaged_purged", ["files": .int(removed)])
    }

    private func write(now: Date, generation started: Int) -> CatalogBackupOutcome {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch { return .failed("create backups folder") }
        let stamp = CatalogRecovery.stamp(now)
        let final = directory.appendingPathComponent("catalog-\(stamp).sqlite3")
        let partial = directory.appendingPathComponent("catalog-\(stamp).sqlite3.partial")
        try? fileManager.removeItem(at: partial)
        var source: OpaquePointer?
        guard sqlite3_open_v2(catalogURL.path, &source, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let source else {
            if let source { sqlite3_close(source) }
            return .failed("open catalog")
        }
        sqlite3_busy_timeout(source, 5_000)
        let quoted = partial.path.replacingOccurrences(of: "'", with: "''")
        let result = sqlite3_exec(source, "VACUUM INTO '\(quoted)'", nil, nil, nil)
        sqlite3_close(source)
        guard result == SQLITE_OK else {
            try? fileManager.removeItem(at: partial)
            return .failed("vacuum into \(result)")
        }
        guard Self.passesQuickCheck(partial) else {
            try? fileManager.removeItem(at: partial)
            return .failed("integrity check")
        }
        afterCopyHook?()
        let accepted: Bool = lock.withLock {
            guard generation == started else { return false }
            return rename(partial.path, final.path) == 0
        }
        guard accepted else {
            try? fileManager.removeItem(at: partial)
            return generationChanged(since: started) ? .superseded : .failed("rename")
        }
        chmod(final.path, 0o600)
        prune()
        let size = (try? fileManager.attributesOfItem(atPath: final.path)[.size] as? NSNumber)?.map(\.int64Value) ?? 0
        return .created(CatalogBackupInfo(url: final, createdAt: CatalogRecovery.date(of: final.lastPathComponent) ?? now, byteCount: size))
    }

    private func generationChanged(since started: Int) -> Bool { lock.withLock { generation != started } }

    private static func passesQuickCheck(_ url: URL) -> Bool {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            return false
        }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text) == "ok"
    }

    /// The `keepCount` newest stay.
    private func prune() {
        lock.withLock {
            for stale in list().dropFirst(Self.keepCount) { try? FileManager.default.removeItem(at: stale.url) }
        }
    }
}

/// Backup listing and the launch prompt's two actions, usable when no catalog could be opened.
public enum CatalogRecovery {
    static let namePrefix = "catalog-"
    static let nameSuffix = ".sqlite3"

    /// The restore steps a test can interrupt (the name is passed to the failpoint after the step).
    enum Step: String { case copied, verified, walAside, movedAside }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    static func date(of name: String) -> Date? {
        guard isBackupName(name) else { return nil }
        let text = String(name.dropFirst(namePrefix.count).dropLast(nameSuffix.count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.date(from: text)
    }

    static func isBackupName(_ name: String) -> Bool {
        guard name.hasPrefix(namePrefix), name.hasSuffix(nameSuffix) else { return false }
        let middle = name.dropFirst(namePrefix.count).dropLast(nameSuffix.count)
        return middle.count == 19 && middle.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// Whether `name` is a catalog set aside by `setAside` (or one of its -wal / -shm files) for the
    /// catalog file called `catalogName`.
    static func isDamagedName(_ name: String, catalogName: String) -> Bool {
        let url = URL(fileURLWithPath: catalogName)
        let prefix = url.deletingPathExtension().lastPathComponent + ".damaged-"
        let suffix = "." + url.pathExtension
        guard name.hasPrefix(prefix) else { return false }
        var rest = Substring(name.dropFirst(prefix.count))
        for sidecar in ["-wal", "-shm"] where rest.hasSuffix(suffix + sidecar) {
            rest = rest.dropLast(sidecar.count)
        }
        guard rest.hasSuffix(suffix) else { return false }
        let stamp = rest.dropLast(suffix.count)
        return stamp.count == 19 && stamp.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// Removes every set-aside damaged catalog (and its -wal and -shm) beside the catalog at
    /// `catalogURL`; returns how many files went.
    @discardableResult
    static func removeDamagedCopies(besideCatalogAt catalogURL: URL) -> Int {
        let directory = catalogURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where isDamagedName(name, catalogName: catalogURL.lastPathComponent) {
            if unlink(directory.appendingPathComponent(name).path) == 0 { removed += 1 }
        }
        return removed
    }

    /// Complete backups of the catalog at `catalogURL`, newest first.
    public static func backups(forCatalogAt catalogURL: URL) -> [CatalogBackupInfo] {
        let directory = catalogURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> CatalogBackupInfo? in
            guard let date = date(of: name) else { return nil }
            let url = directory.appendingPathComponent(name)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            else { return nil }
            return CatalogBackupInfo(url: url, createdAt: date, byteCount: size)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private static func sibling(_ catalogURL: URL, _ name: String) -> URL {
        catalogURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func restoringURL(_ catalogURL: URL) -> URL { sibling(catalogURL, catalogURL.lastPathComponent + ".restoring") }

    /// The damaged catalog (and its -wal and -shm) set aside as `catalog.damaged-<timestamp>.sqlite3`.
    /// The sidecars go first: a write-ahead log left beside a different main file would be replayed
    /// into it.
    @discardableResult
    static func setAside(catalogAt catalogURL: URL, now: Date, failpoint: ((Step) throws -> Void)? = nil) throws -> URL? {
        let base = catalogURL.deletingPathExtension().lastPathComponent
        let target = sibling(catalogURL, "\(base).damaged-\(stamp(now)).\(catalogURL.pathExtension)")
        var moved = false
        for suffix in ["-wal", "-shm", ""] {
            let from = URL(fileURLWithPath: catalogURL.path + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            let to = URL(fileURLWithPath: target.path + suffix)
            guard rename(from.path, to.path) == 0 else { throw CatalogRecoveryError.io(operation: "set aside", code: errno) }
            moved = true
            if suffix == "-shm" { try failpoint?(.walAside) }
        }
        return moved ? target : nil
    }

    /// The prompt's "start fresh": the damaged catalog is moved aside and nothing else changes; the
    /// next open creates an empty catalog. Returns where the old one went.
    @discardableResult
    public static func startFresh(catalogAt catalogURL: URL, now: Date = Date()) throws -> URL? {
        let aside = try setAside(catalogAt: catalogURL, now: now)
        LoomLog.notice(.catalog, "Catalog set aside; the next open starts empty")
        DiagnosticJournal.forDataRoot(catalogURL.deletingLastPathComponent())
            .record("catalog_restore", ["outcome": "started_fresh"])
        return aside
    }

    /// The prompt's "restore": checks the backup opens and passes its integrity check (on a copy,
    /// so the backup itself is never touched), moves the damaged catalog aside, and puts the copy
    /// in its place. An interruption at any point is completed or harmless on the next open
    /// (`finishInterruptedRestore`, run by `SessionCatalog.init`). Anything after the backup was
    /// taken is lost; the damaged files stay beside the catalog.
    @discardableResult
    public static func restore(_ backup: CatalogBackupInfo, intoCatalogAt catalogURL: URL,
                               now: Date = Date()) throws -> URL? {
        try restore(backup, intoCatalogAt: catalogURL, now: now, failpoint: nil)
    }

    static func restore(_ backup: CatalogBackupInfo, intoCatalogAt catalogURL: URL, now: Date,
                        failpoint: ((Step) throws -> Void)?) throws -> URL? {
        let backups = catalogURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        guard backup.url.deletingLastPathComponent().standardizedFileURL == backups.standardizedFileURL,
              isBackupName(backup.url.lastPathComponent) else { throw CatalogRecoveryError.notABackup }
        guard FileManager.default.fileExists(atPath: backup.url.path) else { throw CatalogRecoveryError.backupMissing }
        let staging = restoringURL(catalogURL)
        removeFiles(of: staging)
        do {
            try FileManager.default.copyItem(at: backup.url, to: staging)
        } catch {
            removeFiles(of: staging)
            throw CatalogRecoveryError.io(operation: "copy", code: Int32((error as NSError).code))
        }
        let descriptor = open(staging.path, O_RDONLY | O_CLOEXEC)
        if descriptor >= 0 { fsync(descriptor); close(descriptor) }
        try failpoint?(.copied)
        do { _ = try CatalogDatabase(url: staging) }
        catch {
            removeFiles(of: staging)
            throw CatalogRecoveryError.backupUnreadable(LoomLog.category(of: error))
        }
        // Closing the connection checkpointed and removed the staging copy's log.
        for suffix in ["-wal", "-shm"] { unlink(staging.path + suffix) }
        try failpoint?(.verified)
        let aside = try setAside(catalogAt: catalogURL, now: now, failpoint: failpoint)
        try failpoint?(.movedAside)
        guard rename(staging.path, catalogURL.path) == 0 else {
            throw CatalogRecoveryError.io(operation: "put the backup in place", code: errno)
        }
        LoomLog.notice(.catalog, "Catalog restored from a backup of \(backup.createdAt.formatted(.iso8601))")
        DiagnosticJournal.forDataRoot(catalogURL.deletingLastPathComponent()).record("catalog_restore", [
            "outcome": "restored", "backupTime": .string(ISO8601DateFormatter.journalString(from: backup.createdAt)),
            "damagedKept": .bool(aside != nil),
        ])
        return aside
    }

    /// A restore that was interrupted after the damaged catalog went aside leaves no catalog and a
    /// verified staging copy: finish it, instead of letting the next open create an empty catalog.
    /// Called at the start of every `SessionCatalog.init`. A staging copy beside a catalog that is
    /// still there is an interrupted earlier step and is removed.
    static func finishInterruptedRestore(catalogAt catalogURL: URL) {
        let staging = restoringURL(catalogURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: staging.path) else { return }
        if fileManager.fileExists(atPath: catalogURL.path) {
            removeFiles(of: staging)
            return
        }
        // No catalog: whatever log files are left belong to the one that went aside.
        for suffix in ["-wal", "-shm"] { unlink(catalogURL.path + suffix) }
        if rename(staging.path, catalogURL.path) == 0 {
            LoomLog.notice(.catalog, "An interrupted catalog restore was completed")
            DiagnosticJournal.forDataRoot(catalogURL.deletingLastPathComponent())
                .record("catalog_restore", ["outcome": "completed_after_interruption"])
        } else {
            LoomLog.error(.catalog, "An interrupted catalog restore could not be completed (errno \(errno))")
        }
    }

    private static func removeFiles(of url: URL) {
        for suffix in ["", "-wal", "-shm"] { unlink(url.path + suffix) }
    }
}
