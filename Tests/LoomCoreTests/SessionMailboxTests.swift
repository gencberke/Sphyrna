import Foundation
import Testing
@testable import LoomCore

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
}
