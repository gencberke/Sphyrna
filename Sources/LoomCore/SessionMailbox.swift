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
    let createdAt: Date
    let message: String
}

/// The actor stores approved peer messages and request receipts; the runtime
/// remains the sole owner of provider processes and delivery decisions.
private final class PeerMailboxStore {
    private let db: OpaquePointer
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var pending: [UUID: PeerSendOffer] = [:]

    init(url: URL, now: @escaping @Sendable () -> Date) throws {
        self.now = now
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o077 == 0 else {
            throw SessionTaskError.storage
        }
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
            guard (appID == 0 && version == 0 && tables == 0) || (appID == 1_397_608_242 && version == 1) else {
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
                    try exec("PRAGMA user_version = 1")
                }
            }
            guard try scalarText("PRAGMA quick_check") == "ok",
                  try scalarText("PRAGMA journal_mode = WAL").lowercased() == "wal" else { throw SessionTaskError.storage }
            try exec("PRAGMA synchronous = FULL")
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    func offer(_ offer: PeerSendOffer) throws -> PeerSendStatus {
        try SessionTaskLimits.text(offer.message)
        guard offer.sender.sessionID != offer.targetID,
              [offer.senderTitle, offer.targetTitle].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains(0) }),
              !offer.sender.nativeSessionID.isEmpty, !offer.sender.nativeSessionID.utf8.contains(0),
              offer.targetNativeID.map({ !$0.isEmpty && !$0.utf8.contains(0) && $0.utf8.count <= 256 }) ?? true,
              offer.targetHarness.provider != nil else { throw SessionTaskError.invalidPayload }
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
            let count = try integer("SELECT count(*) FROM peer_messages WHERE sender=? AND created>=?",
                                    [offer.sender.sessionID.uuidString, String(timestamp - 3_600)])
            guard count < 10 else { throw SessionTaskError.needsApproval }
            try run("INSERT INTO peer_messages(id,sender,sender_run,sender_generation,target,created,state,body) VALUES(?,?,?,?,?,?,'pending','')",
                    [offer.id.uuidString, offer.sender.sessionID.uuidString, offer.sender.managedRunID.uuidString,
                     offer.sender.generation.uuidString, offer.targetID.uuidString, String(timestamp)])
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
            return next
        }
        pending[id] = nil
        return result
    }

    func status(id: UUID) throws -> PeerSendStatus? { try metadata(id)?.status }

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
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)), message: offer.message))
                step = sqlite3_step(stmt)
            }
            guard step == SQLITE_DONE else { throw SessionTaskError.storage }
            return result
        }
    }

    func acknowledge(target: UUID, ids: [UUID]) throws {
        guard !ids.isEmpty, ids.count <= SessionTaskLimits.pageSize, Set(ids).count == ids.count else {
            throw SessionTaskError.invalidPage
        }
        try transaction {
            for id in ids {
                guard let row = try record(id), row.offer.targetID == target, row.status == .sent else {
                    throw SessionTaskError.notFound
                }
                try run("UPDATE peer_messages SET unread=0 WHERE id=? AND target=?", [id.uuidString, target.uuidString])
            }
        }
    }

    func forget(target: UUID) throws {
        try transaction { try run("DELETE FROM peer_messages WHERE target=?", [target.uuidString]) }
        pending = pending.filter { $0.value.targetID != target }
        try exec("PRAGMA wal_checkpoint(TRUNCATE)")
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
    private let store: PeerMailboxStore
    private init(store: PeerMailboxStore) { self.store = store }

    static func open(url: URL, now: @escaping @Sendable () -> Date = { Date() }) async throws -> SessionMailbox {
        try await Task.detached { try SessionMailbox(store: PeerMailboxStore(url: url, now: now)) }.value
    }
    func offer(_ offer: PeerSendOffer) throws -> PeerSendStatus { try store.offer(offer) }
    func decide(id: UUID, accept: Bool) throws -> PeerSendStatus { try store.decide(id: id, accept: accept) }
    func status(id: UUID) throws -> PeerSendStatus? { try store.status(id: id) }
    func unread(target: UUID, after: Int64 = 0, limit: Int = 50) throws -> [PeerMailboxEntry] {
        try store.unread(target: target, after: after, limit: limit)
    }
    func acknowledge(target: UUID, ids: [UUID]) throws { try store.acknowledge(target: target, ids: ids) }
    func forget(target: UUID) throws { try store.forget(target: target) }
    func record(_ id: UUID) throws -> (offer: PeerSendOffer, status: PeerSendStatus)? { try store.record(id) }
}
