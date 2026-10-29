import CryptoKit
import Foundation

/// Where a message the user sent from Sphyrna (the Changes tab's comments) stands in its session's mailbox.
public enum UserMessageDelivery: Equatable, Sendable {
    /// Stored and unread: the pointer waits for the session's Ready edge, or the session has not run `inbox` yet.
    case waiting
    /// The session read it with `inbox`.
    case read
    /// Not in the mailbox any more (the session was deleted).
    case gone
}

/// The user's own sends into a running session (F11). They take F1's path from the mailbox on: the message is stored for
/// the target, one pointer line is typed on the target's next Ready edge, and the target reads the text with `inbox`. The
/// user's click is the approval, so there is no request card; nothing else differs from an approved peer send.
extension SessionRuntime {
    /// The live run that takes a message from the user now, or nil: a terminal run of a harness with a task transport,
    /// authenticated on its native session, and not being deleted. Reads the runtime's state and the catalog only.
    public func userMessageRun(sessionID: UUID) async -> UUID? {
        await userMessageTarget(sessionID)?.binding.managedRunID
    }

    /// Stores `message` for the session as sent and asks for its pointer on the next Ready edge. Returns the message's id.
    /// Throws when the session cannot take it now (stopped, deleting, a harness without the channel) or the text is invalid.
    public func sendUserMessage(_ message: String, to sessionID: UUID, senderTitle: String) async throws -> UUID {
        try SessionTaskLimits.text(message)
        guard let mailbox = peerMailbox, let target = await userMessageTarget(sessionID),
              !deletionsInFlight.contains(sessionID), let fence = peerTargetFences.acquire(sessionID) else {
            throw SessionTaskError.notReady
        }
        // As an approval does: deletion waits for this store before it forgets the target's mailbox.
        peerApprovalsInFlight[sessionID, default: 0] += 1
        defer { finishUserMessage(sessionID) }
        let id = UUID()
        let sender = SessionTaskBinding(sessionID: Self.userSender(for: sessionID), nativeSessionID: "sphyrna-user",
                                        managedRunID: UUID(), generation: UUID())
        let offer = PeerSendOffer(id: id, sender: sender, senderTitle: senderTitle, targetID: sessionID,
                                  targetNativeID: target.binding.nativeSessionID, targetTitle: target.title,
                                  targetHarness: target.harness, message: message)
        guard try await mailbox.offer(offer) == .pending else { throw SessionTaskError.conflictingOperation }
        guard fence.isActive, !deletionsInFlight.contains(sessionID) else {
            try? await mailbox.failPending(id: id)
            throw SessionTaskError.notReady
        }
        let status: PeerSendStatus
        do { status = try await mailbox.decide(id: id, accept: true) } catch {
            try? await mailbox.failPending(id: id)
            throw error
        }
        guard status == .sent else { throw SessionTaskError.unverified }
        markPeerNeedsDelivery(sessionID)
        return id
    }

    /// Whether the session has read the user's message `id` yet. Nil when the mailbox cannot answer now.
    public func userMessageDelivery(_ id: UUID, to sessionID: UUID) async -> UserMessageDelivery? {
        guard let mailbox = peerMailbox else { return nil }
        do {
            guard let record = try await mailbox.record(id), record.offer.targetID == sessionID else { return .gone }
            var after: Int64 = 0
            while true {
                let page = try await mailbox.unread(target: sessionID, after: after, limit: SessionTaskLimits.pageSize)
                if page.contains(where: { $0.id == id }) { return .waiting }
                guard page.count == SessionTaskLimits.pageSize, let last = page.last else { return .read }
                after = last.sequence
            }
        } catch { return nil }
    }

    private func userMessageTarget(_ sessionID: UUID) async -> (binding: SessionTaskBinding, title: String, harness: HarnessID)? {
        guard !shuttingDown, peerMailbox != nil, !deletionsInFlight.contains(sessionID),
              let plan = taskRunPlans[sessionID], let binding = await authenticateTaskRun(plan.claim),
              let target = try? await catalog.session(id: sessionID), !target.isSideChat, target.runEndpoint != .pipe,
              target.session.providerConversationID == binding.nativeSessionID,
              harnesses[target.session.provider]?.taskTransport != nil,
              (try? await catalog.isDeletionPending(sessionID)) == false,
              !deletionsInFlight.contains(sessionID), taskRunPlans[sessionID]?.lease === plan.lease else { return nil }
        return (binding, String((target.title ?? "Session").prefix(200)), target.session.harnessID)
    }

    /// The approval counter's release, as `finishPeerApproval` does for a peer send: the last one wakes a waiting deletion.
    private func finishUserMessage(_ sessionID: UUID) {
        guard let count = peerApprovalsInFlight[sessionID] else { return }
        if count > 1 { peerApprovalsInFlight[sessionID] = count - 1; return }
        peerApprovalsInFlight[sessionID] = nil
        for waiter in peerApprovalWaiters.removeValue(forKey: sessionID) ?? [] { waiter.resume() }
    }

    /// The user as a sender to one session: a fixed id per target, so the mailbox's per-sender bounds (one pending send,
    /// ten an hour) count the user's sends to that session alone. It never names a catalog session.
    static func userSender(for target: UUID) -> UUID {
        let digest = Array(SHA256.hash(data: Data("sphyrna-user-sender:\(target.uuidString)".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
