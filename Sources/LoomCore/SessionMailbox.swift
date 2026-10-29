import Darwin
import Foundation
import SQLite3

struct PeerSendOffer: Codable, Equatable, Sendable {
    let id: UUID
    let sender: SessionTaskBinding
    let senderTitle: String
    let targetID: UUID
    let targetNativeID: String?
    let targetTitle: String
    let targetHarness: HarnessID
    let message: String
}

enum PeerSendStatus: String, Codable, Sendable { case pending, sent, denied, failed }

struct PeerMailboxEntry: Equatable, Sendable {
    let sequence: Int64
    let id: UUID
    let senderID: UUID
    let senderTitle: String
    let targetNativeID: String?
    let createdAt: Date
    let message: String
}

struct PeerPointerIntent: Sendable {
    let targetID: UUID
    let operationID: UUID
    let nativeSessionID: String
    let senderTitle: String
    let lease: SessionTaskWakeLease
    func attemptDelivery(_ body: () -> Bool) -> Bool { lease.attempt(body) }
}

/// Only one live runtime may recover its transient, unapproved offers. The
/// kernel releases this private lock on process exit; an unrelated live owner
/// cannot have its requests retired by a second runtime.
private final class PeerMailboxOwner {
    private let fd: Int32
    init(directory: URL) throws {
        let path = directory.appendingPathComponent("owner.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw SessionTaskError.storage }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw SessionTaskError.storage
        }
        fd = descriptor
    }
    deinit { close(fd) }
}

/// The actor stores approved peer messages and request receipts; the runtime
/// remains the sole owner of provider processes and delivery decisions.
private final class PeerMailboxStore {
    private let db: OpaquePointer
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let owner: PeerMailboxOwner?
    private var pending: [UUID: PeerSendOffer] = [:]

    init(url: URL, now: @escaping @Sendable () -> Date, exclusive: Bool) throws {
        self.now = now
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o077 == 0 else {
            throw SessionTaskError.storage
        }
        owner = try exclusive ? PeerMailboxOwner(directory: directory) : nil
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        if fd >= 0 { close(fd) }
        else if errno == EEXIST {
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0 else {
                throw SessionTaskError.storage
            }
        } else { throw SessionTaskError.storage }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw SessionTaskError.storage
        }
        db = connection
        encoder.outputFormatting = [.sortedKeys]
        sqlite3_busy_timeout(db, 2_000)
        do {
            try exec("PRAGMA secure_delete = ON")
            let appID = try scalar("PRAGMA application_id"), version = try scalar("PRAGMA user_version")
            let tables = try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            guard (appID == 0 && version == 0 && tables == 0) ||
                    (appID == 1_397_608_242 && (version == 1 || version == 2)) else {
                throw SessionTaskError.storage
            }
            if version == 0 {
                try transaction {
                    try exec("PRAGMA application_id = 1397608242")
                    try exec("""
                        CREATE TABLE peer_messages(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                          sender TEXT NOT NULL, sender_run TEXT NOT NULL, sender_generation TEXT NOT NULL,
                          target TEXT NOT NULL, created REAL NOT NULL, state TEXT NOT NULL,
                          unread INTEGER NOT NULL DEFAULT 0, body TEXT NOT NULL)
                        """)
                    try exec("CREATE INDEX peer_sender ON peer_messages(sender, created)")
                    try exec("CREATE INDEX peer_sender_state ON peer_messages(sender, state)")
                    try exec("CREATE INDEX peer_target_unread ON peer_messages(target, unread, sequence)")
                    try exec("""
                        CREATE TABLE peer_notifications(target TEXT PRIMARY KEY, revision INTEGER NOT NULL,
                          state TEXT NOT NULL, operation TEXT, claimed_revision INTEGER)
                        """)
                    try exec("CREATE INDEX peer_state ON peer_messages(state)")
                    try exec("CREATE TABLE peer_rates(id TEXT PRIMARY KEY, sender TEXT NOT NULL, created REAL NOT NULL)")
                    try exec("CREATE INDEX peer_rates_sender ON peer_rates(sender,created)")
                    try exec("PRAGMA user_version = 2")
                }
            }
            if version == 1 {
                // One-time migration from the earlier mailbox schema. Rate
                // receipts contain no target, message or body derivative.
                try transaction {
                    try exec("""
                        CREATE TABLE IF NOT EXISTS peer_notifications(target TEXT PRIMARY KEY, revision INTEGER NOT NULL,
                          state TEXT NOT NULL, operation TEXT, claimed_revision INTEGER)
                        """)
                    try exec("CREATE INDEX IF NOT EXISTS peer_state ON peer_messages(state)")
                    try exec("CREATE TABLE peer_rates(id TEXT PRIMARY KEY, sender TEXT NOT NULL, created REAL NOT NULL)")
                    try exec("CREATE INDEX peer_rates_sender ON peer_rates(sender,created)")
                    let cutoff = now().timeIntervalSince1970 - 3_600
                    guard cutoff.isFinite else { throw SessionTaskError.storage }
                    try run("INSERT INTO peer_rates(id,sender,created) SELECT id,sender,created FROM peer_messages WHERE created>=?", [String(cutoff)])
                    try exec("PRAGMA user_version = 2")
                }
            }
            guard try scalarText("PRAGMA journal_mode = WAL").lowercased() == "wal" else { throw SessionTaskError.storage }
            try exec("PRAGMA synchronous = FULL")
            if owner != nil {
                let pendingIDs = try statement("SELECT id FROM peer_messages WHERE state='pending' LIMIT 33", []) { stmt in
                    var ids: [String] = []
                    var step = sqlite3_step(stmt)
                    while step == SQLITE_ROW {
                        guard let id = sqlite3_column_text(stmt, 0) else { throw SessionTaskError.storage }
                        ids.append(String(cString: id)); step = sqlite3_step(stmt)
                    }
                    guard step == SQLITE_DONE, ids.count <= OpenSessionCoordinator.maximumWaiting else { throw SessionTaskError.storage }
                    return ids
                }
                try transaction {
                    for id in pendingIDs { try run("UPDATE peer_messages SET state='failed' WHERE id=? AND state='pending'", [id]) }
                }
            }
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    func offer(_ offer: PeerSendOffer) throws -> PeerSendStatus {
        if let terminal = try terminalStatus(id: offer.id, sender: offer.sender) { return terminal }
        try SessionTaskLimits.text(offer.message)
        guard offer.sender.sessionID != offer.targetID,
              [offer.senderTitle, offer.targetTitle].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains(0) }),
              !offer.sender.nativeSessionID.isEmpty, !offer.sender.nativeSessionID.utf8.contains(0),
              offer.targetNativeID.map({ !$0.isEmpty && !$0.utf8.contains(0) && $0.utf8.count <= 256 }) ?? true,
              HarnessCatalogue.descriptor(for: offer.targetHarness)?.provider != nil else { throw SessionTaskError.invalidPayload }
        let timestamp = now().timeIntervalSince1970
        guard timestamp.isFinite else { throw SessionTaskError.storage }
        var inserted = false
        let result: PeerSendStatus = try transaction {
            if let prior = try metadata(offer.id) {
                guard prior.sender == offer.sender.sessionID.uuidString,
                      prior.run == offer.sender.managedRunID.uuidString,
                      prior.generation == offer.sender.generation.uuidString else { throw SessionTaskError.unauthorized }
                switch prior.status {
                case .denied, .failed: return prior.status
                case .pending:
                    guard let existing = pending[offer.id] else {
                        try run("UPDATE peer_messages SET state='failed' WHERE id=? AND state='pending'", [offer.id.uuidString])
                        return .failed
                    }
                    guard Self.sameRequest(existing, offer) else { throw SessionTaskError.conflictingOperation }
                    return .pending
                case .sent:
                    guard let existing = try record(offer.id), Self.sameRequest(existing.offer, offer) else {
                        throw SessionTaskError.conflictingOperation
                    }
                    return .sent
                }
            }
            if try exists("SELECT 1 FROM peer_messages WHERE sender=? AND state='pending' LIMIT 1", [offer.sender.sessionID.uuidString]) {
                throw SessionTaskError.pendingInput
            }
            guard pending.count < OpenSessionCoordinator.maximumWaiting else { throw SessionTaskError.tooManyWaiters }
            try run("DELETE FROM peer_rates WHERE sender=? AND created<?", [offer.sender.sessionID.uuidString, String(timestamp - 3_600)])
            if try exists("SELECT 1 FROM peer_rates WHERE id=? LIMIT 1", [offer.id.uuidString]) {
                throw SessionTaskError.conflictingOperation
            }
            let count = try integer("SELECT count(*) FROM peer_rates WHERE sender=? AND created>=?",
                                    [offer.sender.sessionID.uuidString, String(timestamp - 3_600)])
            guard count < 10 else { throw SessionTaskError.needsApproval }
            try run("INSERT INTO peer_messages(id,sender,sender_run,sender_generation,target,created,state,body) VALUES(?,?,?,?,?,?,'pending','')",
                    [offer.id.uuidString, offer.sender.sessionID.uuidString, offer.sender.managedRunID.uuidString,
                     offer.sender.generation.uuidString, offer.targetID.uuidString, String(timestamp)])
            try run("INSERT INTO peer_rates(id,sender,created) VALUES(?,?,?)",
                    [offer.id.uuidString, offer.sender.sessionID.uuidString, String(timestamp)])
            inserted = true
            return .pending
        }
        if inserted { pending[offer.id] = offer }
        return result
    }

    func decide(id: UUID, accept: Bool) throws -> PeerSendStatus {
        let result: PeerSendStatus = try transaction {
            guard let row = try metadata(id) else { throw SessionTaskError.notFound }
            let next: PeerSendStatus = accept ? .sent : .denied
            if row.status == next { return next }
            guard row.status == .pending else { throw SessionTaskError.conflictingOperation }
            guard let offer = pending[id] else { throw SessionTaskError.unverified }
            let body = accept ? try json(offer) : ""
            try run("UPDATE peer_messages SET state=?, unread=?, body=? WHERE id=? AND state='pending'",
                    [next.rawValue, accept ? "1" : "0", body, id.uuidString])
            guard sqlite3_changes(db) == 1 else { throw SessionTaskError.storage }
            if accept {
                try run("""
                    INSERT INTO peer_notifications(target,revision,state) VALUES(?,1,'pending')
                    ON CONFLICT(target) DO UPDATE SET revision=revision+1,
                      state=CASE WHEN state IN ('idle','delivered') THEN 'pending' ELSE state END
                    """, [offer.targetID.uuidString])
            }
            return next
        }
        pending[id] = nil
        return result
    }

    func status(id: UUID) throws -> PeerSendStatus? { try metadata(id)?.status }

    func terminalStatus(id: UUID, sender: SessionTaskBinding) throws -> PeerSendStatus? {
        guard let prior = try metadata(id) else { return nil }
        guard prior.sender == sender.sessionID.uuidString, prior.run == sender.managedRunID.uuidString,
              prior.generation == sender.generation.uuidString else { throw SessionTaskError.unauthorized }
        return prior.status == .denied || prior.status == .failed ? prior.status : nil
    }

    func unread(target: UUID, after: Int64 = 0, limit: Int = 50) throws -> [PeerMailboxEntry] {
        guard after >= 0, (1...SessionTaskLimits.pageSize).contains(limit) else { throw SessionTaskError.invalidPage }
        return try statement("SELECT sequence,created,body FROM peer_messages WHERE target=? AND unread=1 AND sequence>? ORDER BY sequence LIMIT ?",
                             [target.uuidString, String(after), String(limit)]) { stmt in
            var result: [PeerMailboxEntry] = []
            var step = sqlite3_step(stmt)
            while step == SQLITE_ROW {
                guard let raw = sqlite3_column_text(stmt, 2),
                      let data = String(cString: raw).data(using: .utf8) else { throw SessionTaskError.storage }
                let offer = try decoder.decode(PeerSendOffer.self, from: data)
                result.append(PeerMailboxEntry(sequence: sqlite3_column_int64(stmt, 0), id: offer.id,
                    senderID: offer.sender.sessionID, senderTitle: offer.senderTitle,
                    targetNativeID: offer.targetNativeID,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)), message: offer.message))
                step = sqlite3_step(stmt)
            }
            guard step == SQLITE_DONE else { throw SessionTaskError.storage }
            return result
        }
    }

    func acknowledge(target: UUID, ids: [UUID]) throws -> Bool {
        guard !ids.isEmpty, ids.count <= SessionTaskLimits.pageSize, Set(ids).count == ids.count else {
            throw SessionTaskError.invalidPage
        }
        return try transaction {
            var changed = false
            for id in ids {
                guard let row = try record(id), row.offer.targetID == target, row.status == .sent else {
                    throw SessionTaskError.notFound
                }
                try run("UPDATE peer_messages SET unread=0 WHERE id=? AND target=? AND unread=1", [id.uuidString, target.uuidString])
                if sqlite3_changes(db) > 0 { changed = true }
            }
            if try !exists("SELECT 1 FROM peer_messages WHERE target=? AND unread=1 LIMIT 1", [target.uuidString]) {
                try run("UPDATE peer_notifications SET state='idle', operation=NULL, claimed_revision=NULL WHERE target=?",
                        [target.uuidString])
            }
            return changed
        }
    }

    func forget(target: UUID) throws {
        try transaction {
            try run("DELETE FROM peer_messages WHERE target=?", [target.uuidString])
            try run("DELETE FROM peer_notifications WHERE target=?", [target.uuidString])
            try run("DELETE FROM peer_rates WHERE sender=?", [target.uuidString])
        }
        pending = pending.filter { $0.value.targetID != target }
        try statement("PRAGMA wal_checkpoint(TRUNCATE)", []) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 0 else {
                throw SessionTaskError.storage
            }
        }
    }

    func hasUnread(target: UUID) throws -> Bool {
        try exists("SELECT 1 FROM peer_messages WHERE target=? AND unread=1 LIMIT 1", [target.uuidString])
    }

    func failPending(id: UUID) throws -> PeerSendStatus {
        let result = try transaction {
            guard let meta = try metadata(id) else { throw SessionTaskError.notFound }
            guard meta.status == .pending else { return meta.status }
            try run("UPDATE peer_messages SET state='failed' WHERE id=? AND state='pending'", [id.uuidString])
            return PeerSendStatus.failed
        }
        pending[id] = nil
        return result
    }

    func pendingIDs(target: UUID) -> [UUID] {
        pending.compactMap { $0.value.targetID == target ? $0.key : nil }
    }

    func beginPointer(target: UUID, nativeSessionID: String) throws -> (UUID, String)? {
        try transaction {
            guard let notification = try notification(target), notification.state == "pending",
                  let entry = try unread(target: target, limit: 1).first,
                  let row = try record(entry.id), row.offer.targetNativeID == nativeSessionID else { return nil }
            let operation = UUID()
            try run("UPDATE peer_notifications SET state='unknown', operation=?, claimed_revision=revision WHERE target=? AND state='pending'",
                    [operation.uuidString, target.uuidString])
            guard sqlite3_changes(db) == 1 else { throw SessionTaskError.storage }
            return (operation, entry.senderTitle)
        }
    }

    func settlePointer(target: UUID, operation: UUID, outcome: SessionTaskEffect) throws {
        try transaction {
            guard let value = try notification(target), value.state == "unknown", value.operation == operation.uuidString else { return }
            let next: String
            switch outcome {
            case .deferred: next = "pending"
            case .unknown: return
            case .verified: next = value.revision > (value.claimedRevision ?? value.revision) ? "pending" : "delivered"
            }
            try run("UPDATE peer_notifications SET state=?, operation=NULL, claimed_revision=NULL WHERE target=? AND operation=?",
                    [next, target.uuidString, operation.uuidString])
        }
    }

    private func notification(_ target: UUID) throws -> (revision: Int64, state: String, operation: String?, claimedRevision: Int64?)? {
        try statement("SELECT revision,state,operation,claimed_revision FROM peer_notifications WHERE target=?", [target.uuidString]) { stmt in
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW, let state = sqlite3_column_text(stmt, 1) else { throw SessionTaskError.storage }
            let operation = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let claimed = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)
            return (sqlite3_column_int64(stmt, 0), String(cString: state), operation, claimed)
        }
    }

    func record(_ id: UUID) throws -> (offer: PeerSendOffer, status: PeerSendStatus)? {
        guard let meta = try metadata(id) else { return nil }
        if meta.status == .pending { return pending[id].map { ($0, meta.status) } }
        guard meta.status == .sent else { return nil }
        return try statement("SELECT body,state FROM peer_messages WHERE id=?", [id.uuidString]) { stmt in
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0),
                  let data = String(cString: raw).data(using: .utf8), let state = sqlite3_column_text(stmt, 1),
                  let status = PeerSendStatus(rawValue: String(cString: state)) else { throw SessionTaskError.storage }
            return (try decoder.decode(PeerSendOffer.self, from: data), status)
        }
    }

    private static func sameRequest(_ lhs: PeerSendOffer, _ rhs: PeerSendOffer) -> Bool {
        lhs.sender == rhs.sender && lhs.targetID == rhs.targetID && lhs.targetNativeID == rhs.targetNativeID &&
            lhs.targetHarness == rhs.targetHarness && lhs.message == rhs.message
    }

    private func metadata(_ id: UUID) throws -> (status: PeerSendStatus, sender: String, run: String, generation: String)? {
        try statement("SELECT state,sender,sender_run,sender_generation FROM peer_messages WHERE id=?", [id.uuidString]) { stmt in
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW, let state = sqlite3_column_text(stmt, 0),
                  let sender = sqlite3_column_text(stmt, 1), let run = sqlite3_column_text(stmt, 2),
                  let generation = sqlite3_column_text(stmt, 3),
                  let status = PeerSendStatus(rawValue: String(cString: state)) else { throw SessionTaskError.storage }
            return (status, String(cString: sender), String(cString: run), String(cString: generation))
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        guard let text = String(data: try encoder.encode(value), encoding: .utf8) else { throw SessionTaskError.storage }
        return text
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result = try body(); try exec("COMMIT"); return result }
        catch { try? exec("ROLLBACK"); throw error }
    }
    private func integer(_ sql: String, _ values: [String]) throws -> Int64 {
        try statement(sql, values) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw SessionTaskError.storage }
            return sqlite3_column_int64(stmt, 0)
        }
    }
    private func exists(_ sql: String, _ values: [String]) throws -> Bool {
        try statement(sql, values) { stmt in
            let result = sqlite3_step(stmt)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw SessionTaskError.storage }
            return result == SQLITE_ROW
        }
    }
    private func scalar(_ sql: String) throws -> Int64 { try integer(sql, []) }
    private func scalarText(_ sql: String) throws -> String {
        try statement(sql, []) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else { throw SessionTaskError.storage }
            return String(cString: raw)
        }
    }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SessionTaskError.storage }
    }
    private func run(_ sql: String, _ values: [String]) throws {
        try statement(sql, values) { stmt in guard sqlite3_step(stmt) == SQLITE_DONE else { throw SessionTaskError.storage } }
    }
    private func statement<T>(_ sql: String, _ values: [String], _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw SessionTaskError.storage }
        defer { sqlite3_finalize(stmt) }
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(offset + 1), value, -1,
                                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
                throw SessionTaskError.storage
            }
        }
        return try body(stmt)
    }
}


actor SessionMailbox {
    private struct Waiter {
        let requestID: UUID
        let continuation: CheckedContinuation<PeerSendStatus, Never>
        let timeout: Task<Void, Never>
    }
    private let store: PeerMailboxStore
    private var waiters: [UUID: Waiter] = [:]
    private var pointerLeases: [UUID: SessionTaskWakeLease] = [:]
    private var observers: [UUID: AsyncStream<UInt64>.Continuation] = [:]
    private var revision: UInt64 = 0
    private init(store: PeerMailboxStore) { self.store = store }

    static func open(url: URL, now: @escaping @Sendable () -> Date = { Date() }, exclusive: Bool = false) async throws -> SessionMailbox {
        try await Task.detached { try SessionMailbox(store: PeerMailboxStore(url: url, now: now, exclusive: exclusive)) }.value
    }
    func offer(_ offer: PeerSendOffer) throws -> PeerSendStatus { try store.offer(offer) }
    func decide(id: UUID, accept: Bool) throws -> PeerSendStatus {
        let result = try store.decide(id: id, accept: accept)
        if let target = try store.record(id)?.offer.targetID { publish(target) }
        finishWaiters(requestID: id, result: result)
        return result
    }
    func status(id: UUID) throws -> PeerSendStatus? { try store.status(id: id) }
    func terminalStatus(id: UUID, sender: SessionTaskBinding) throws -> PeerSendStatus? {
        try store.terminalStatus(id: id, sender: sender)
    }
    func unread(target: UUID, after: Int64 = 0, limit: Int = 50) throws -> [PeerMailboxEntry] {
        try store.unread(target: target, after: after, limit: limit)
    }
    func acknowledge(target: UUID, ids: [UUID]) throws {
        let mutation = { try self.store.acknowledge(target: target, ids: ids) }
        let changed = if let lease = pointerLeases[target] { try lease.cancelIfChanged(mutation) } else { try mutation() }
        if changed { publish(target) }
    }
    func forget(target: UUID) throws {
        pointerLeases[target]?.cancel()
        let ids = store.pendingIDs(target: target)
        try store.forget(target: target)
        for id in ids { finishWaiters(requestID: id, result: .failed) }
        publish(target)
    }
    func record(_ id: UUID) throws -> (offer: PeerSendOffer, status: PeerSendStatus)? { try store.record(id) }
    func hasUnread(target: UUID) throws -> Bool { try store.hasUnread(target: target) }
    func failPending(id: UUID) throws {
        let result = try store.failPending(id: id)
        finishWaiters(requestID: id, result: result)
    }

    func beginPointer(target: UUID, nativeSessionID: String) throws -> PeerPointerIntent? {
        guard pointerLeases[target] == nil, let (operation, title) = try store.beginPointer(target: target, nativeSessionID: nativeSessionID) else { return nil }
        let lease = SessionTaskWakeLease()
        pointerLeases[target] = lease
        return PeerPointerIntent(targetID: target, operationID: operation, nativeSessionID: nativeSessionID,
                                 senderTitle: title, lease: lease)
    }

    func settlePointer(_ intent: PeerPointerIntent, outcome: SessionTaskEffect) throws {
        if pointerLeases[intent.targetID] === intent.lease { pointerLeases[intent.targetID] = nil }
        try store.settlePointer(target: intent.targetID, operation: intent.operationID, outcome: outcome)
    }

    func waitForDecision(id: UUID, seconds: TimeInterval = 85) async -> PeerSendStatus {
        guard let status = try? store.status(id: id) else { return .failed }
        guard status == .pending else { return status }
        guard waiters.count < OpenSessionCoordinator.maximumWaiting, seconds > 0, seconds <= 85 else { return .failed }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: .failed); return }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    await self?.finishWaiter(waiterID, result: .pending)
                }
                waiters[waiterID] = Waiter(requestID: id, continuation: continuation, timeout: timeout)
            }
        } onCancel: { Task { await self.finishWaiter(waiterID, result: .failed) } }
    }

    func updates() -> AsyncStream<UInt64> {
        guard observers.count < OpenSessionCoordinator.maximumWaiting else { return AsyncStream { $0.finish() } }
        let pair = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID(); observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        pair.continuation.yield(revision)
        return pair.stream
    }

    func shutdown() {
        for lease in pointerLeases.values { lease.cancel() }
        pointerLeases.removeAll()
        for id in Array(waiters.keys) { finishWaiter(id, result: .failed) }
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(_ target: UUID) {
        revision &+= 1
        for observer in observers.values { observer.yield(revision) }
    }
    private func finishWaiters(requestID: UUID, result: PeerSendStatus) {
        let ids = waiters.compactMap { $0.value.requestID == requestID ? $0.key : nil }
        for id in ids { finishWaiter(id, result: result) }
    }
    private func finishWaiter(_ id: UUID, result: PeerSendStatus) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel(); waiter.continuation.resume(returning: result)
    }
}
