import Foundation
import SQLite3
import Testing
@testable import LoomCore
import LoomTestSupport

@Suite(.serialized)
struct SessionMailboxTests {
    private func makeOffer(id: UUID = UUID(), sender: UUID, target: UUID, message: String = "approved message") -> PeerSendOffer {
        PeerSendOffer(id: id, sender: SessionTaskBinding(sessionID: sender, nativeSessionID: "sender-native",
            managedRunID: UUID(), generation: UUID()), senderTitle: "Sender", targetID: target,
            targetNativeID: "target-native", targetTitle: "Target", targetHarness: .claude, message: message)
    }

    @Test func approvalPersistsOnlyTheTargetMessageAndReadAcknowledgesItOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mail.sqlite3"), target = UUID(), sender = UUID()
        let store = try await SessionMailbox.open(url: url)
        let offer = makeOffer(sender: sender, target: target)
        #expect(try await store.offer(offer) == .pending)
        #expect(try await store.unread(target: target).isEmpty)
        #expect(try await store.decide(id: offer.id, accept: true) == .sent)
        #expect(try await store.decide(id: offer.id, accept: true) == .sent)
        let reopened = try await SessionMailbox.open(url: url)
        let first = try #require(try await reopened.unread(target: target).first)
        #expect(first.id == offer.id && first.senderID == sender && first.message == offer.message)
        #expect(try await reopened.unread(target: UUID()).isEmpty)
        #expect(try await reopened.unread(target: target).count == 1, "peek leaves the message unread")
        try await reopened.acknowledge(target: target, ids: [first.id])
        #expect(try await reopened.unread(target: target).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0)
    }

    @Test func denialAndForgettingDoNotLeakAcrossTargets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SessionMailbox.open(url: root.appendingPathComponent("mail.sqlite3"))
        let sender = UUID(), one = UUID(), two = UUID()
        let denied = makeOffer(sender: sender, target: one)
        #expect(try await store.offer(denied) == .pending)
        #expect(try await store.decide(id: denied.id, accept: false) == .denied)
        #expect(try await store.unread(target: one).isEmpty)
        let first = makeOffer(sender: sender, target: one), second = makeOffer(sender: sender, target: two)
        #expect(try await store.offer(first) == .pending)
        #expect(try await store.decide(id: first.id, accept: true) == .sent)
        #expect(try await store.offer(second) == .pending)
        #expect(try await store.decide(id: second.id, accept: true) == .sent)
        try await store.forget(target: one)
        try await store.forget(target: one)
        #expect(try await store.unread(target: one).isEmpty)
        #expect(try await store.unread(target: two).map(\.id) == [second.id])
    }

    @Test func anUnapprovedOrDeniedMessageNeverEntersTheDurableMailbox() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mail.sqlite3"), marker = "unapproved-peer-secret-\(UUID().uuidString)"
        let store = try await SessionMailbox.open(url: url), offer = makeOffer(sender: UUID(), target: UUID(), message: marker)
        #expect(try await store.offer(offer) == .pending)
        func containsMarker() -> Bool {
            [url.path, url.path + "-wal"].contains { path in
                (try? Data(contentsOf: URL(fileURLWithPath: path)).range(of: Data(marker.utf8))) != nil
            }
        }
        let beforeDenial = containsMarker()
        #expect(!beforeDenial)
        #expect(try await store.decide(id: offer.id, accept: false) == .denied)
        let afterDenial = containsMarker()
        #expect(!afterDenial)
        #expect(try await store.unread(target: offer.targetID).isEmpty)
        let changed = PeerSendOffer(id: offer.id, sender: offer.sender, senderTitle: offer.senderTitle,
            targetID: offer.targetID, targetNativeID: offer.targetNativeID, targetTitle: offer.targetTitle,
            targetHarness: offer.targetHarness, message: "a different body")
        #expect(try await store.offer(changed) == .denied)
        let malformedRetry = PeerSendOffer(id: offer.id, sender: offer.sender, senderTitle: offer.senderTitle,
            targetID: UUID(), targetNativeID: offer.targetNativeID, targetTitle: offer.targetTitle,
            targetHarness: offer.targetHarness, message: String(repeating: "x", count: 16_385))
        #expect(try await store.offer(malformedRetry) == .denied)
    }

    @Test func sameOperationIsIdempotentButAConflictAndSecondPendingAreRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SessionMailbox.open(url: root.appendingPathComponent("mail.sqlite3"))
        let sender = UUID(), target = UUID(), offer = makeOffer(sender: sender, target: target)
        #expect(try await store.offer(offer) == .pending)
        #expect(try await store.offer(offer) == .pending)
        let conflict = PeerSendOffer(id: offer.id, sender: offer.sender, senderTitle: offer.senderTitle,
            targetID: target, targetNativeID: offer.targetNativeID, targetTitle: offer.targetTitle,
            targetHarness: offer.targetHarness, message: "different")
        await #expect(throws: SessionTaskError.conflictingOperation) { _ = try await store.offer(conflict) }
        await #expect(throws: SessionTaskError.pendingInput) { _ = try await store.offer(makeOffer(sender: sender, target: target)) }
        await #expect(throws: SessionTaskError.invalidPayload) {
            _ = try await store.offer(makeOffer(sender: UUID(), target: target, message: String(repeating: "x", count: 16_385)))
        }
        let unsupported = makeOffer(sender: UUID(), target: target)
        let synthetic = PeerSendOffer(id: unsupported.id, sender: unsupported.sender, senderTitle: unsupported.senderTitle,
            targetID: target, targetNativeID: unsupported.targetNativeID, targetTitle: unsupported.targetTitle,
            targetHarness: HarnessID(.synthetic), message: unsupported.message)
        await #expect(throws: SessionTaskError.invalidPayload) { _ = try await store.offer(synthetic) }
    }

    @Test func senderRateLimitAndTargetScopedAcknowledgementAreDurable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mail.sqlite3"), sender = UUID(), target = UUID()
        let store = try await SessionMailbox.open(url: url, now: { Date(timeIntervalSince1970: 10_000) })
        for _ in 0..<10 {
            let offer = makeOffer(sender: sender, target: target)
            #expect(try await store.offer(offer) == .pending)
            _ = try await store.decide(id: offer.id, accept: true)
        }
        let reopened = try await SessionMailbox.open(url: url, now: { Date(timeIntervalSince1970: 10_001) })
        await #expect(throws: SessionTaskError.needsApproval) { _ = try await reopened.offer(makeOffer(sender: sender, target: target)) }
        let entry = try #require(try await reopened.unread(target: target, limit: 1).first)
        await #expect(throws: SessionTaskError.notFound) { try await reopened.acknowledge(target: UUID(), ids: [entry.id]) }
        #expect(try await reopened.unread(target: target).count == 10)
        await #expect(throws: SessionTaskError.invalidPage) { _ = try await reopened.unread(target: target, limit: 51) }
    }

    @Test func pointerReceiptsCoalesceAndAcknowledgementFencesThePendingWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mail.sqlite3"), target = UUID(), sender = UUID()
        let store = try await SessionMailbox.open(url: url)
        let first = makeOffer(sender: sender, target: target), second = makeOffer(sender: sender, target: target)
        _ = try await store.offer(first); _ = try await store.decide(id: first.id, accept: true)
        let firstPointer = try #require(try await store.beginPointer(target: target, nativeSessionID: "target-native"))
        _ = try await store.offer(second); _ = try await store.decide(id: second.id, accept: true)
        try await store.settlePointer(firstPointer, outcome: .verified)
        let next = try #require(try await store.beginPointer(target: target, nativeSessionID: "target-native"))
        try await store.acknowledge(target: target, ids: [first.id, second.id])
        #expect(!next.attemptDelivery { true }, "a read wins against a pending write")
        try await store.settlePointer(next, outcome: .deferred)
        #expect(try await store.beginPointer(target: target, nativeSessionID: "target-native") == nil)
        #expect(try await store.unread(target: target).isEmpty)
    }

    @Test func uncertainPointerIsNotAutomaticallyReplayedAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mail.sqlite3"), target = UUID()
        let store = try await SessionMailbox.open(url: url), offer = makeOffer(sender: UUID(), target: target)
        _ = try await store.offer(offer); _ = try await store.decide(id: offer.id, accept: true)
        let pointer = try #require(try await store.beginPointer(target: target, nativeSessionID: "target-native"))
        try await store.settlePointer(pointer, outcome: .unknown)
        let reopened = try await SessionMailbox.open(url: url)
        #expect(try await reopened.beginPointer(target: target, nativeSessionID: "target-native") == nil)
        #expect(try await reopened.unread(target: target).map(\.id) == [offer.id])
    }

    @Test func wirePageNeverExceedsReplyBudgetOrAcknowledgesExcludedMessages() throws {
        let entries = (1...50).map { i in PeerMailboxEntry(sequence: Int64(i), id: UUID(), senderID: UUID(),
            senderTitle: "Sender", targetNativeID: "target-native", createdAt: Date(),
            message: String(repeating: "x", count: 16_384)) }
        let lease = UUID(), packed = try PeerWirePacking.page(entries, limit: 50, readLeaseID: lease)
        let page = try JSONDecoder().decode(PeerWirePage.self, from: packed.data)
        #expect(packed.data.count <= SessionTaskWireLimits.replyBytes)
        #expect(!page.messages.isEmpty && page.messages.count < entries.count)
        #expect(packed.ids == page.messages.map(\.id))
        #expect(page.next == page.messages.last?.sequence && page.readLeaseID == lease)
    }


    @Test func exclusiveOwnerProtectsLiveOffersAndRecoversLostPendingReceipts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-mail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mail.sqlite3"), sender = UUID(), target = UUID()
        let offer = makeOffer(sender: sender, target: target, message: "never persisted")
        var owner: SessionMailbox? = try await SessionMailbox.open(url: url, exclusive: true)
        #expect(try await owner?.offer(offer) == .pending)
        await #expect(throws: SessionTaskError.storage) { _ = try await SessionMailbox.open(url: url, exclusive: true) }
        #expect(try await owner?.status(id: offer.id) == .pending, "another owner must not retire a live offer")
        weak var released = owner
        owner = nil
        // The owner's lock goes with its last reference, and the actor's executor can hold one a moment after `owner = nil`
        // (the full run's free pool reopened inside that moment once). An owner that is never released still fails here.
        let deadline = ContinuousClock.now + .seconds(2)
        var lockFree: SessionMailbox?
        while lockFree == nil {
            do { lockFree = try await SessionMailbox.open(url: url, exclusive: true) }
            catch SessionTaskError.storage where ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(released == nil, "the first owner was released")
        let reopened = try #require(lockFree)
        #expect(try await reopened.status(id: offer.id) == .failed)
        let next = makeOffer(sender: sender, target: target)
        #expect(try await reopened.offer(next) == .pending, "a lost offer does not permanently block its sender")
        #expect(try await reopened.unread(target: target).isEmpty)
    }


    @Test func deletingATargetDoesNotEraseAnotherSendersHourlyLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-rate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let sender = UUID(), target = UUID()
        let store = try await SessionMailbox.open(url: root.appendingPathComponent("mail.sqlite3"),
                                                  now: { Date(timeIntervalSince1970: 10_000) })
        for _ in 0..<10 {
            let offer = makeOffer(sender: sender, target: target)
            _ = try await store.offer(offer); _ = try await store.decide(id: offer.id, accept: true)
        }
        try await store.forget(target: target)
        #expect(try await store.unread(target: target).isEmpty)
        await #expect(throws: SessionTaskError.needsApproval) {
            _ = try await store.offer(makeOffer(sender: sender, target: UUID()))
        }
    }


    @Test func versionOneMigrationPreservesRecentSenderLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mail.sqlite3"), sender = UUID(), target = UUID()
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw SessionTaskError.storage }
        let schema = """
            PRAGMA application_id=1397608242; PRAGMA user_version=1;
            CREATE TABLE peer_messages(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
              sender TEXT NOT NULL, sender_run TEXT NOT NULL, sender_generation TEXT NOT NULL,
              target TEXT NOT NULL, created REAL NOT NULL, state TEXT NOT NULL,
              unread INTEGER NOT NULL DEFAULT 0, body TEXT NOT NULL);
            CREATE INDEX peer_sender ON peer_messages(sender,created);
            CREATE INDEX peer_sender_state ON peer_messages(sender,state);
            CREATE INDEX peer_target_unread ON peer_messages(target,unread,sequence);
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); throw SessionTaskError.storage }
        for _ in 0..<10 {
            let sql = "INSERT INTO peer_messages(id,sender,sender_run,sender_generation,target,created,state,body) " +
                "VALUES('\(UUID().uuidString)','\(sender.uuidString)','\(UUID().uuidString)','\(UUID().uuidString)'," +
                "'\(target.uuidString)',10000,'denied','')"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); throw SessionTaskError.storage }
        }
        sqlite3_close(db)
        let migrated = try await SessionMailbox.open(url: url, now: { Date(timeIntervalSince1970: 10_001) }, exclusive: true)
        try await migrated.forget(target: target)
        await #expect(throws: SessionTaskError.needsApproval) {
            _ = try await migrated.offer(makeOffer(sender: sender, target: UUID()))
        }
    }

    @Test func forgettingRemainsIncompleteWhileAReaderRetainsPayloadInTheWAL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-mail-wal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mail.sqlite3"), target = UUID()
        let marker = "OWNED_PEER_PAYLOAD_\(UUID().uuidString)"
        let mailbox = try await SessionMailbox.open(url: url)
        let offer = makeOffer(sender: UUID(), target: target, message: marker)
        _ = try await mailbox.offer(offer)
        _ = try await mailbox.decide(id: offer.id, accept: true)
        var rawReader: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &rawReader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let reader = try #require(rawReader)
        defer { sqlite3_close(reader) }
        #expect(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM peer_messages", nil, nil, nil) == SQLITE_OK)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        await #expect(throws: SessionTaskError.storage) { try await mailbox.forget(target: target) }
        #expect(try await mailbox.unread(target: target).isEmpty, "logical deletion does not establish payload erasure")
        #expect(try Data(contentsOf: wal).range(of: Data(marker.utf8)) != nil)
        #expect(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        try await mailbox.forget(target: target)
        #expect(try Data(contentsOf: wal).isEmpty)
        #expect(try Data(contentsOf: url).range(of: Data(marker.utf8)) == nil)
    }
}
