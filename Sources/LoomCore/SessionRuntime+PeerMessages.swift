import CryptoKit
import Foundation

struct PeerPendingRequest: Sendable {
    let sender: SessionTaskClaim
    let senderBinding: SessionTaskBinding
    let targetID: UUID
    let nativeID: String
    let harness: HarnessID
    let targetBinding: SessionTaskBinding?
    let fence: PeerTargetFence
}

extension SessionRuntime {
    func submitPeerSend(_ call: SessionTaskWireRequest) async -> SessionTaskWireReply {
        do {
            guard let id = call.operationID, let targetID = call.targetSessionID, let message = call.message,
                  let senderBinding = await authenticateTaskRun(call.claim),
                  senderBinding.sessionID != targetID else { throw SessionTaskError.unauthorized }
            // A mailbox that did not open (logged at start) is no refusal of this caller.
            guard let mailbox = peerMailbox else { return .init(status: "unavailable") }
            if let prior = try await mailbox.terminalStatus(id: id, sender: senderBinding) {
                return .init(status: prior.rawValue)
            }
            try SessionTaskLimits.text(message)
            guard !deletionsInFlight.contains(targetID),
                  try await !catalog.isDeletionPending(targetID),
                  let sender = try await catalog.session(id: senderBinding.sessionID),
                  let target = try await catalog.session(id: targetID), !target.isSideChat,
                  target.runEndpoint != .pipe, let nativeID = target.session.providerConversationID,
                  !nativeID.isEmpty, harnesses[target.session.provider]?.taskTransport != nil,
                  let fence = peerTargetFences.acquire(targetID) else { throw SessionTaskError.notReady }
            let targetBinding: SessionTaskBinding?
            if let plan = taskRunPlans[targetID] {
                guard let binding = await authenticateTaskRun(plan.claim), binding.nativeSessionID == nativeID else {
                    throw SessionTaskError.staleBinding
                }
                targetBinding = binding
            } else { targetBinding = nil }
            guard fence.isActive, !deletionsInFlight.contains(targetID),
                  try await !catalog.isDeletionPending(targetID),
                  await authenticateTaskRun(call.claim) == senderBinding else { throw SessionTaskError.unauthorized }
            let senderTitle = sender.title ?? "Session", targetTitle = target.title ?? "Session"
            let offer = PeerSendOffer(id: id, sender: senderBinding, senderTitle: senderTitle, targetID: targetID,
                targetNativeID: nativeID, targetTitle: targetTitle, targetHarness: target.session.harnessID, message: message)
            let status = try await mailbox.offer(offer)
            guard status == .pending else { return .init(status: status.rawValue) }
            if peerPendingRequests[id] == nil {
                let pending = PeerPendingRequest(sender: call.claim, senderBinding: senderBinding, targetID: targetID,
                    nativeID: nativeID, harness: target.session.harnessID, targetBinding: targetBinding, fence: fence)
                peerPendingRequests[id] = pending
                let request = OpenSessionRequest(id: id, requesterID: senderBinding.sessionID, requesterTitle: senderTitle,
                    projectID: target.projectID ?? sender.projectID ?? senderBinding.sessionID, projectName: "",
                    title: targetTitle, message: message, choices: HarnessLaunchChoices(harness: target.session.harnessID),
                    send: OpenSessionSendRequest(targetSessionID: targetID, targetTitle: targetTitle,
                                                 targetHarness: target.session.harnessID, operationID: id))
                let offered = await openRequests.submitSend(request) { [weak self] in
                    await self?.peerRequestIsAuthorized(id) ?? false
                }
                if !offered {
                    peerPendingRequests[id] = nil
                    try? await mailbox.failPending(id: id)
                    throw SessionTaskError.notReady
                }
            }
            return .init(status: await mailbox.waitForDecision(id: id).rawValue)
        } catch let error as SessionTaskError {
            return .init(status: "refused", detail: String(describing: error))
        } catch { return .init(status: "unavailable") }
    }

    func peerRequestIsAuthorized(_ id: UUID) async -> Bool {
        guard let pending = peerPendingRequests[id], pending.fence.isActive, !shuttingDown,
              !deletionsInFlight.contains(pending.targetID),
              await authenticateTaskRun(pending.sender) == pending.senderBinding,
              let target = try? await catalog.session(id: pending.targetID), !target.isSideChat,
              target.runEndpoint != .pipe, target.session.providerConversationID == pending.nativeID,
              target.session.harnessID == pending.harness, harnesses[target.session.provider]?.taskTransport != nil,
              (try? await catalog.isDeletionPending(pending.targetID)) == false else { return false }
        if let expected = pending.targetBinding {
            guard let plan = taskRunPlans[pending.targetID], await authenticateTaskRun(plan.claim) == expected else { return false }
        } else if taskRunPlans[pending.targetID] != nil { return false }
        return pending.fence.isActive && peerPendingRequests[id]?.fence === pending.fence &&
            !deletionsInFlight.contains(pending.targetID) && !shuttingDown
    }

    /// An explicit user approval is required for every ordinary peer send.
    public func approvePeerSendRequest(_ requestID: UUID) async throws {
        guard await openRequests.snapshot().first(where: { $0.id == requestID })?.send != nil else {
            throw SessionTaskError.unauthorized
        }
        do {
            _ = try await openRequests.approve(requestID) { spec in
                guard let send = spec.send, send.operationID == requestID,
                      let target = try await self.acceptPeerApproval(requestID, target: send.targetSessionID) else {
                    throw SessionTaskError.unauthorized
                }
                return target
            }
        } catch {
            try? await peerMailbox?.failPending(id: requestID)
            peerPendingRequests[requestID] = nil
            throw error
        }
    }

    /// Claim approval on the runtime actor before leaving it. Deletion blocks
    /// new claims and waits for an already-claimed decision before forgetting.
    private func acceptPeerApproval(_ id: UUID, target: UUID) async throws -> UUID? {
        guard await peerRequestIsAuthorized(id), let pending = peerPendingRequests[id], pending.targetID == target,
              pending.fence.isActive, !deletionsInFlight.contains(target), !shuttingDown,
              let mailbox = peerMailbox else { return nil }
        peerApprovalsInFlight[target, default: 0] += 1
        let result: PeerSendStatus
        do {
            result = try await mailbox.decide(id: id, accept: true)
        } catch {
            finishPeerApproval(target)
            throw error
        }
        finishPeerApproval(target)
        guard result == .sent else { throw SessionTaskError.unverified }
        peerPendingRequests[id] = nil
        markPeerNeedsDelivery(target)
        return target
    }

    private func finishPeerApproval(_ target: UUID) {
        guard let count = peerApprovalsInFlight[target] else { return }
        if count > 1 { peerApprovalsInFlight[target] = count - 1; return }
        peerApprovalsInFlight[target] = nil
        let waiters = peerApprovalWaiters.removeValue(forKey: target) ?? []
        for waiter in waiters { waiter.resume() }
    }

    func waitForPeerApprovals(target: UUID) async {
        guard peerApprovalsInFlight[target] != nil else { return }
        await withCheckedContinuation { continuation in
            peerApprovalWaiters[target, default: []].append(continuation)
        }
    }

    func failPeerRequests(from claim: SessionTaskClaim) {
        let ids = peerPendingRequests.compactMap { id, pending in
            pending.sender.sessionID == claim.sessionID && pending.sender.managedRunID == claim.managedRunID &&
                pending.sender.generation == claim.generation ? id : nil
        }
        for id in ids {
            peerPendingRequests[id] = nil
            Task { [weak self] in
                guard let self else { return }
                try? await self.peerMailbox?.failPending(id: id)
                try? await self.openRequests.dismiss(id)
            }
        }
    }

    func peerInbox(_ call: SessionTaskWireRequest) async -> Data {
        let unavailable = Data(#"{"version":5,"status":"unavailable"}"#.utf8)
        guard let mailbox = peerMailbox, let fence = peerReadFence,
              let binding = await authenticateTaskRun(call.claim),
              (try? await catalog.isDeletionPending(binding.sessionID)) == false else { return unavailable }
        do {
            let lease = try fence.begin(taskID: binding.sessionID, claim: call.claim)
            do {
                let limit = call.limit ?? SessionTaskLimits.pageSize
                let entries = try await mailbox.unread(target: binding.sessionID, after: call.after ?? 0, limit: limit)
                guard entries.allSatisfy({ $0.targetNativeID == binding.nativeSessionID }),
                      await authenticateTaskRun(call.claim) == binding,
                      (try? await catalog.isDeletionPending(binding.sessionID)) == false else { throw SessionTaskError.unauthorized }
                let page = try PeerWirePacking.page(entries, limit: limit, readLeaseID: lease)
                fence.delivered(lease, eventIDs: page.ids)
                return page.data
            } catch { fence.release(lease); throw error }
        } catch { return unavailable }
    }

    func peerInboxAck(_ call: SessionTaskWireRequest) async -> SessionTaskWireReply {
        do {
            guard let ids = call.eventIDs, let mailbox = peerMailbox,
                  let binding = await authenticateTaskRun(call.claim),
                  (try? await catalog.isDeletionPending(binding.sessionID)) == false else { throw SessionTaskError.unauthorized }
            try await mailbox.acknowledge(target: binding.sessionID, ids: ids)
            if let lease = call.readLeaseID {
                peerReadFence?.acknowledge(lease, taskID: binding.sessionID, claim: call.claim, eventIDs: ids)
            }
            markPeerNeedsDelivery(binding.sessionID)
            return .init(status: "ok")
        } catch { return .init(status: "unavailable") }
    }

    public func sessionMailboxHasUnread(sessionID: UUID) async throws -> Bool {
        guard let mailbox = peerMailbox else { throw SessionTaskError.notReady }
        return try await mailbox.hasUnread(target: sessionID)
    }
    /// Revisions coalesce; readers refresh unread state for their visible sessions.
    public func sessionMailboxUpdates() async -> AsyncStream<UInt64> {
        guard let mailbox = peerMailbox else { return AsyncStream { $0.finish() } }
        return await mailbox.updates()
    }
}

extension SessionRuntime {
    func markPeerNeedsDelivery(_ sessionID: UUID) {
        guard !shuttingDown, taskRunPlans[sessionID] != nil else { return }
        peersNeedingDelivery.insert(sessionID)
        updateTaskQuiescenceObservers()
        schedulePeerDelivery(sessionID)
    }

    func schedulePeerDelivery(_ sessionID: UUID) {
        guard !shuttingDown, peersNeedingDelivery.contains(sessionID) else { return }
        guard peerDeliveriesInFlight.insert(sessionID).inserted else {
            peerDeliveriesRequested.insert(sessionID); return
        }
        Task { [weak self] in await self?.performPeerDelivery(sessionID) }
    }

    private func performPeerDelivery(_ sessionID: UUID) async {
        var deferred = false
        // The step a pass ended at, for the log: an outcome line per pass, ids and step words only.
        var step = "start"
        defer {
            LoomLog.notice(.session, "Peer pointer \(LoomLog.ref(sessionID)) \(deferred ? "deferred" : "ended") at \(step)")
            let anotherEdge = peerDeliveriesRequested.remove(sessionID) != nil
            peerDeliveriesInFlight.remove(sessionID)
            if !deferred && !anotherEdge { peersNeedingDelivery.remove(sessionID) }
            updateTaskQuiescenceObservers()
            if anotherEdge { schedulePeerDelivery(sessionID) }
        }
        guard !shuttingDown, let mailbox = peerMailbox, let readFence = peerReadFence,
              let plan = taskRunPlans[sessionID] else { return }
        // Attachment can precede native identity and provider ingress. Keep
        // the durable delivery pending until the next observed Ready edge.
        step = "identity"
        guard let revision = plan.lease.admit({ $0 }), let binding = await authenticateTaskRun(plan.claim) else {
            deferred = true; return
        }
        step = "deletion"
        guard (try? await catalog.isDeletionPending(sessionID)) == false,
              !deletionsInFlight.contains(sessionID), let targetFence = peerTargetFences.acquire(sessionID) else { return }
        let status = await taskNativeStatus(binding)
        step = "status-\(status.rawValue)"
        guard status == .ready else { deferred = true; return }
        _ = inputGate.establishFreshCleanInput(runID: binding.managedRunID)
        step = "input-gate"
        guard let ticket = inputGate.reserveAutomaticInput(runID: binding.managedRunID) else {
            deferred = true
            _ = inputGate.notifyWhenAutomaticMayProceed(runID: binding.managedRunID) { [weak self] in
                Task { await self?.markPeerNeedsDelivery(sessionID) }
            }
            return
        }
        defer { inputGate.releaseReservedAutomatic(runID: binding.managedRunID, ticket: ticket) }
        step = "begin"
        guard let intent = try? await mailbox.beginPointer(target: sessionID, nativeSessionID: binding.nativeSessionID) else { return }
        let outcome = await deliverPeerPointer(intent, binding: binding, plan: plan, revision: revision,
                                               targetFence: targetFence, readFence: readFence, ticket: ticket)
        step = "pointer-\(outcome)"
        try? await mailbox.settlePointer(intent, outcome: outcome)
        if case .deferred = outcome { deferred = true }
    }

    private func deliverPeerPointer(_ intent: PeerPointerIntent, binding: SessionTaskBinding, plan: SessionTaskRunPlan,
                                    revision: UInt64, targetFence: PeerTargetFence, readFence: SessionTaskReadFence,
                                    ticket: TerminalInputQueue.AutomaticInputTicket) async -> SessionTaskEffect {
        guard let record = runs[binding.managedRunID], let transport = harnesses[record.provider]?.taskTransport,
              targetFence.isActive,
              plan.lease.permits(revision: revision), !deletionsInFlight.contains(binding.sessionID),
              (try? await catalog.isDeletionPending(binding.sessionID)) == false else {
            LoomLog.notice(.session, "Peer pointer \(LoomLog.ref(binding.sessionID)) not written: run"); return .deferred
        }
        let title = String(intent.senderTitle.unicodeScalars.prefix(80).map { scalar -> Character in
            let ascii = scalar.value
            return (ascii >= 0x20 && ascii <= 0x7e && scalar != "\"" && scalar != "\\") ? Character(scalar) : "_"
        })
        let pointer = "Sphyrna: message from \(title). Run \"$SPHYRNA_CLI\" inbox"
        let purpose = SessionTaskExpectedInput.Purpose.peer(targetID: binding.sessionID, operationID: intent.operationID)
        let digest = Data(SHA256.hash(data: Data(pointer.utf8)))
        let effect = SessionTaskInputEffectMarker()
        let clientID = transport == .ownedAppServer ? UUID().uuidString.lowercased() : nil
        guard await prepareTaskInput(purpose: purpose, binding: binding, digest: digest, effect: effect, ticket: ticket,
                                     requiresNativeReceipt: transport == .ownedAppServer, clientMessageID: clientID),
              targetFence.isActive, plan.lease.permits(revision: revision) else {
            LoomLog.notice(.session, "Peer pointer \(LoomLog.ref(binding.sessionID)) not written: expected input")
            clearTaskExpectation(purpose, binding: binding); return .deferred
        }
        let transaction: TerminalWriteTransaction = { write in
            var result: Result<Int?, Error>?
            let allowed = readFence.attemptWake(taskID: binding.sessionID) {
                intent.attemptDelivery {
                    targetFence.attempt {
                        result = Result { try plan.lease.withOptionalAdmission(revision: revision) { try effect.write(write) } }
                        return true
                    }
                }
            }
            guard allowed, let result else { return nil }
            return try result.get()
        }
        if transport == .ownedAppServer {
            guard let client = record.server?.client else {
                LoomLog.notice(.session, "Peer pointer \(LoomLog.ref(binding.sessionID)) not written: no app-server client")
                clearTaskExpectation(purpose, binding: binding); return .deferred
            }
            let gate = inputGate
            do {
                guard let turn = try await client.startTaskTurn(threadID: binding.nativeSessionID, text: pointer,
                    clientMessageID: clientID, transaction: { write in
                        try transaction { try gate.writeReservedAutomatic(runID: binding.managedRunID, ticket: ticket, write) ?? 0 }
                    }) else {
                    LoomLog.notice(.session, "Peer pointer \(LoomLog.ref(binding.sessionID)) not written: turn not started")
                    clearTaskExpectation(purpose, binding: binding); return .deferred
                }
                guard confirmCodexTaskTurn(turn, purpose: purpose, binding: binding) else { return .unknown }
                return .verified
            } catch { return .unknown }
        }
        guard transport == .terminalHook,
              inputGate.enqueueReservedAutomatic(runID: binding.managedRunID, ticket: ticket,
                                                  bytes: Data((pointer + "\r").utf8), transaction: transaction) else {
            clearTaskExpectation(purpose, binding: binding); return .deferred
        }
        switch await ticket.writeOutcome() {
        case .written: return .verified
        case .notWritten: clearTaskExpectation(purpose, binding: binding); return .deferred
        case .unknown: return .unknown
        }
    }
}
