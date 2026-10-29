import CryptoKit
import Foundation

/// App-owned coordination authority. This is not a transport or process owner:
/// the host authenticates launch-local callers and owns every provider effect.
public actor SessionTaskCoordinator {
    private struct Waiter {
        let taskID: UUID
        let continuation: CheckedContinuation<Void, Never>
        let timeout: Task<Void, Never>
    }

    private let store: SessionTaskStore
    private let host: any SessionTaskHost
    private let now: @Sendable () -> Date
    private var waiters: [UUID: Waiter] = [:]
    private var wakeLeases: [UUID: SessionTaskWakeLease] = [:]
    private var deletionFences: Set<UUID> = []
    private var deletionsInProgress: Set<UUID> = []
    private var activeCreations: [UUID: Int] = [:]
    private var projectionRevision: UInt64 = 0
    private var projectionSubscribers: [UUID: AsyncStream<UInt64>.Continuation] = [:]

    private init(url: URL, host: any SessionTaskHost, now: @escaping @Sendable () -> Date) throws {
        store = try SessionTaskStore(url: url)
        self.host = host
        self.now = now
    }

    /// Opening and SQLite integrity checks can walk the database. Do them away
    /// from the caller, including when the app initiates this from MainActor.
    public static func open(url: URL, host: any SessionTaskHost,
                            now: @escaping @Sendable () -> Date = { Date() }) async throws -> SessionTaskCoordinator {
        try await Task.detached { try SessionTaskCoordinator(url: url, host: host, now: now) }.value
    }

    /// Called by the app only after an explicit delegation approval. The host
    /// proves the reserved child is newly owned by this task, never adopted.
    @discardableResult
    func createApproved(taskID: UUID, parent: SessionTaskClaim, childID: UUID, harness: HarnessID,
                        childName: String, choices: HarnessLaunchChoices,
                        creationOperationID: UUID? = nil, creationFingerprint: String? = nil) async throws -> SessionTaskProjection {
        try SessionTaskLimits.text(childName)
        guard childName.utf8.count <= 160,
              !childName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ClaudeLaunchChoices.isSafeToken(harness.rawValue), choices.harness == harness,
              choices.model.map(ClaudeLaunchChoices.isSafeToken) ?? true,
              choices.effort.map(HarnessEffort.isToken) ?? true, parent.sessionID != childID else {
            throw SessionTaskError.invalidPayload
        }
        guard !deletionFences.contains(parent.sessionID), !deletionFences.contains(childID) else {
            throw SessionTaskError.unverified
        }
        for id in [parent.sessionID, childID] { activeCreations[id, default: 0] += 1 }
        defer {
            for id in [parent.sessionID, childID] {
                let remaining = (activeCreations[id] ?? 1) - 1
                activeCreations[id] = remaining > 0 ? remaining : nil
                if remaining == 0 && !deletionsInProgress.contains(id) { deletionFences.remove(id) }
            }
        }
        let parentBinding = try await authenticated(parent)
        guard !deletionFences.contains(parent.sessionID), !deletionFences.contains(childID) else {
            throw SessionTaskError.unverified
        }
        if let existing = try store.task(taskID) {
            guard existing.parentBinding == parentBinding, existing.childSessionID == childID,
                  existing.harness == harness, existing.childName == childName,
                  existing.requestedChoices == choices, existing.creationOperationID == creationOperationID,
                  existing.creationFingerprint == creationFingerprint else { throw SessionTaskError.conflictingOperation }
            return existing
        }
        guard await host.ownsNewChild(taskID: taskID, parent: parentBinding, childID: childID),
              try await authenticated(parent) == parentBinding else { throw SessionTaskError.unauthorized }
        let created: SessionTaskProjection = try store.transaction {
            guard !deletionFences.contains(parent.sessionID), !deletionFences.contains(childID) else {
                throw SessionTaskError.unverified
            }
            if let existing = try store.task(taskID) {
                guard existing.parentBinding == parentBinding, existing.childSessionID == childID,
                      existing.harness == harness, existing.childName == childName,
                      existing.requestedChoices == choices, existing.creationOperationID == creationOperationID,
                      existing.creationFingerprint == creationFingerprint else { throw SessionTaskError.conflictingOperation }
                return existing
            }
            guard try !store.childExists(childID) else { throw SessionTaskError.childAlreadyOwned }
            var task = SessionTaskProjection(id: taskID, parentSessionID: parent.sessionID, childSessionID: childID,
                harness: harness, childName: childName, requestedChoices: choices,
                effectiveModel: nil, effectiveEffort: nil, effectiveMode: nil,
                parentBinding: parentBinding, childBinding: nil, lifecycle: .active,
                expiresAt: now().addingTimeInterval(SessionTaskLimits.grantLifetime),
                childInputLimit: SessionTaskLimits.childInputs, parentWakeLimit: SessionTaskLimits.parentWakes,
                childInputsUsed: 0, parentWakesUsed: 0, parentWakesConsumed: 0,
                uncertainChildEffects: 0, uncertainWakeEffects: 0, authorityEpoch: 0,
                activeRoundID: nil, pendingRoundID: nil, currentAttentionID: nil,
                nextOrdinal: 1, revision: 1)
            task.creationOperationID = creationOperationID
            task.creationFingerprint = creationFingerprint
            try store.create(task)
            return task
        }
        changed(taskID)
        return created
    }

    /// A parent can queue at most one follow-up, including while the child is
    /// working. No provider input occurs here.
    public func requestRound(taskID: UUID, parent: SessionTaskClaim, operationID: UUID, message: String,
                             replyToEventID: UUID? = nil) async throws -> SessionTaskReceipt {
        try SessionTaskLimits.text(message)
        let principal = try await authenticated(parent)
        let fingerprint = Self.fingerprint(["input", taskID.uuidString, message, replyToEventID?.uuidString ?? ""])
        let receipt = try store.transaction {
            var task = try authorizedTask(taskID, parent: principal, allowRevoked: true)
            if let previous = try sameOperation(operationID, fingerprint: fingerprint) { return previous }
            try requireGrant(task, remaining: task.childInputsUsed < task.childInputLimit)
            guard task.pendingRoundID == nil else { throw SessionTaskError.pendingInput }
            if let replyToEventID {
                guard task.currentAttentionID == replyToEventID,
                      let event = try store.event(replyToEventID), event.taskID == task.id,
                      event.kind == .needsParentInput, event.roundID == task.activeRoundID,
                      let activeID = task.activeRoundID, let active = try store.round(activeID),
                      active.phase == .awaitingParent else { throw SessionTaskError.staleRound }
            }
            let round = SessionTaskRound(id: UUID(), taskID: taskID, ordinal: task.nextOrdinal,
                operationID: operationID, message: message, replyToEventID: replyToEventID,
                phase: .queued, binding: nil, nativeTurnID: nil)
            task.nextOrdinal += 1
            task.pendingRoundID = round.id
            task.revision += 1
            let receipt = SessionTaskReceipt(operationID: operationID, taskID: taskID, roundID: round.id, delivery: .queued)
            try store.create(round)
            try store.createOperation(operationID, taskID: taskID, operation: .init(fingerprint: fingerprint, receipt: receipt))
            try store.save(task)
            return receipt
        }
        changed(taskID)
        return receipt
    }

    /// The parent can withdraw a queued input without stopping the child. A
    /// possibly submitted input stays unknown and cannot be silently cancelled.
    public func cancelQueued(taskID: UUID, parent: SessionTaskClaim, roundID: UUID,
                             operationID: UUID) async throws -> SessionTaskReceipt {
        let principal = try await authenticated(parent)
        let fingerprint = Self.fingerprint(["cancel-queued", taskID.uuidString, roundID.uuidString])
        let receipt = try store.transaction {
            var task = try authorizedTask(taskID, parent: principal, allowRevoked: true)
            if let prior = try sameOperation(operationID, fingerprint: fingerprint) { return prior }
            guard var round = try store.round(roundID), round.taskID == taskID else { throw SessionTaskError.staleRound }
            let result: SessionTaskDelivery
            if round.phase == .queued, task.pendingRoundID == roundID {
                guard var input = try store.operation(round.operationID) else { throw SessionTaskError.storage }
                round.phase = .retired; input.receipt.delivery = .cancelled
                task.pendingRoundID = nil; task.revision += 1
                try store.save(round); try store.saveOperation(round.operationID, operation: input); try store.save(task)
                result = .verified
            } else if round.phase == .deliveringUnknown { throw SessionTaskError.unverified }
            else if round.phase == .retired || round.phase == .completed || round.phase == .failed { result = .alreadySettled }
            else { throw SessionTaskError.notReady }
            let receipt = SessionTaskReceipt(operationID: operationID, taskID: taskID, roundID: roundID, delivery: result)
            try store.createOperation(operationID, taskID: taskID, operation: .init(fingerprint: fingerprint, receipt: receipt))
            return receipt
        }
        changed(taskID)
        return receipt
    }

    /// Runtime-only Ready edge. Host must recheck both live bindings and Ready
    /// atomically at the write boundary. No queued work is replayed on init.
    func deliverPending(taskID: UUID) async throws -> SessionTaskReceipt {
        let prepared: (SessionTaskProjection, SessionTaskRound, SessionTaskStore.Operation, Bool) = try store.transaction {
            guard var task = try store.task(taskID) else { throw SessionTaskError.notFound }
            try requireGrant(task, remaining: task.childInputsUsed < task.childInputLimit)
            guard let pendingID = task.pendingRoundID, var round = try store.round(pendingID),
                  var operation = try store.operation(round.operationID) else { throw SessionTaskError.notReady }
            guard round.phase == .queued else { return (task, round, operation, false) }
            if let activeID = task.activeRoundID, let active = try store.round(activeID) {
                guard active.phase == .awaitingParent, let reply = round.replyToEventID,
                      task.currentAttentionID == reply,
                      let event = try store.event(reply), event.roundID == activeID,
                      event.kind == .needsParentInput else { throw SessionTaskError.missingReport }
            }
            task.childInputsUsed += 1
            task.uncertainChildEffects += 1
            task.revision += 1
            round.phase = .deliveringUnknown
            operation.receipt.delivery = .unknown
            try store.save(task); try store.save(round); try store.saveOperation(round.operationID, operation: operation)
            return (task, round, operation, true)
        }
        let (initialTask, initialRound, initialOperation, shouldSubmit) = prepared
        guard shouldSubmit else { return initialOperation.receipt }
        changed(taskID)
        let outcome = await host.submitIfReady(SessionTaskInputIntent(task: initialTask, round: initialRound))
        let receipt = try store.transaction {
            guard var task = try store.task(taskID), var round = try store.round(initialRound.id),
                  var operation = try store.operation(initialRound.operationID) else { throw SessionTaskError.notFound }
            // A verified child report can arrive before the submit call
            // returns. It has already proved the write and settled the round;
            // a late host reply cannot resurrect it or refund the input.
            if operation.receipt.delivery == .submitted, let bound = round.binding {
                if task.authorityEpoch == initialTask.authorityEpoch {
                    switch outcome {
                    case let .submitted(binding, turn, actualModel, actualEffort, actualMode):
                        if binding != bound || !Self.validMetadata(turn) ||
                            (turn != nil && round.nativeTurnID != nil && turn != round.nativeTurnID) {
                            wakeLeases[taskID]?.cancel()
                            try retireRounds(&task)
                            task.lifecycle = .identityChanged; task.authorityEpoch += 1; task.revision += 1
                            try store.save(task)
                        } else if task.childBinding == bound,
                                  task.activeRoundID == round.id || (task.activeRoundID == nil && task.pendingRoundID == nil),
                                  Self.validMetadata(actualModel), Self.validMetadata(actualEffort) {
                            if round.nativeTurnID == nil, let turn {
                                round.nativeTurnID = turn
                                try store.save(round)
                            }
                            task.effectiveModel = actualModel; task.effectiveEffort = actualEffort; task.effectiveMode = actualMode
                            task.revision += 1
                            try store.save(task)
                        }
                    case .deferred, .started:
                        wakeLeases[taskID]?.cancel()
                        try retireRounds(&task)
                        task.lifecycle = .revoked; task.authorityEpoch += 1; task.revision += 1
                        try store.save(task)
                    case .unknown: break
                    }
                }
                return operation.receipt
            }
            // A concurrent lifecycle fence has already retired the round. The
            // result may update the receipt/identity, never restore authority.
            let sameAuthority = task.authorityEpoch == initialTask.authorityEpoch
            let active = sameAuthority && task.lifecycle == .active && task.pendingRoundID == round.id && round.phase == .deliveringUnknown
            let staleReply = initialRound.replyToEventID.map { task.currentAttentionID != $0 } ?? false
            switch outcome {
            case .deferred:
                task.uncertainChildEffects = max(0, task.uncertainChildEffects - 1)
                if sameAuthority { task.childInputsUsed = max(0, task.childInputsUsed - 1) }
                if active && !staleReply { round.phase = .queued; operation.receipt.delivery = .deferred }
                else {
                    round.phase = .retired; operation.receipt.delivery = .cancelled
                    if task.pendingRoundID == round.id { task.pendingRoundID = nil }
                }
            case let .started(binding):
                guard binding.sessionID == initialTask.childSessionID, Self.validMetadata(binding.nativeSessionID),
                      task.childBinding == nil || task.childBinding == binding else {
                    operation.receipt.delivery = .unknown
                    if sameAuthority { task.lifecycle = .identityChanged; task.authorityEpoch += 1 }
                    break
                }
                // Keep the owned identity even if Stop fenced the relationship
                // while spawn was suspended. A late live child cannot turn an
                // earlier stop into a verified one.
                task.childBinding = binding
                task.uncertainChildEffects = max(0, task.uncertainChildEffects - 1)
                if sameAuthority { task.childInputsUsed = max(0, task.childInputsUsed - 1) }
                if active && !staleReply { round.phase = .queued; operation.receipt.delivery = .deferred }
                else {
                    round.phase = .retired; operation.receipt.delivery = .cancelled
                    if task.pendingRoundID == round.id { task.pendingRoundID = nil }
                    if task.lifecycle == .stopped { task.lifecycle = .stopUnverified }
                }
            case .unknown:
                operation.receipt.delivery = .unknown
            case let .submitted(binding, nativeTurnID, actualModel, actualEffort, actualMode):
                guard binding.sessionID == initialTask.childSessionID,
                      initialTask.childBinding == nil || initialTask.childBinding == binding,
                      Self.validMetadata(binding.nativeSessionID), Self.validMetadata(nativeTurnID),
                      Self.validMetadata(actualModel), Self.validMetadata(actualEffort) else {
                    operation.receipt.delivery = .unknown
                    if sameAuthority {
                        wakeLeases[taskID]?.cancel()
                        task.lifecycle = .identityChanged
                        task.authorityEpoch += 1
                    }
                    break
                }
                task.uncertainChildEffects = max(0, task.uncertainChildEffects - 1)
                if sameAuthority || task.childBinding == nil {
                    task.childBinding = binding
                    task.effectiveModel = actualModel; task.effectiveEffort = actualEffort; task.effectiveMode = actualMode
                }
                round.binding = binding; round.nativeTurnID = nativeTurnID
                operation.receipt.delivery = .submitted
                if active && !staleReply {
                    if let oldID = task.activeRoundID, var old = try store.round(oldID), old.phase == .awaitingParent {
                        old.phase = .retired; try store.save(old)
                    }
                    task.currentAttentionID = nil
                    task.pendingRoundID = nil
                    task.activeRoundID = round.id
                    round.phase = .active
                } else {
                    round.phase = .retired
                    if active && staleReply {
                        // The host should have fenced this at the write. Keep
                        // its receipt, but never claim the new ask was answered.
                        wakeLeases[taskID]?.cancel()
                        task.pendingRoundID = nil; task.lifecycle = .revoked; task.authorityEpoch += 1
                    }
                }
            }
            task.revision += 1
            try store.save(task); try store.save(round); try store.saveOperation(round.operationID, operation: operation)
            return operation.receipt
        }
        changed(taskID)
        return receipt
    }

    /// Child-originated result or attention request. The host resolves its
    /// exact submitted input under the live launch-local binding.
    public func report(taskID: UUID, child: SessionTaskClaim, roundID: UUID,
                       operationID: UUID, eventID: UUID? = nil, kind: SessionTaskReportKind, payload: String) async throws -> SessionTaskReceipt {
        try SessionTaskLimits.text(payload)
        let principal = try await authenticated(child)
        let eventID = eventID ?? operationID
        let fingerprint = Self.fingerprint(["report", taskID.uuidString, roundID.uuidString,
                                            eventID.uuidString, kind.rawValue, payload])
        guard let task = try store.task(taskID), let round = try store.round(roundID), round.taskID == taskID,
              task.lifecycle == .active, !isDeletionFenced(task) else {
            throw SessionTaskError.staleBinding
        }
        let legacyFingerprint = round.nativeTurnID.map {
            Self.fingerprint(["report", taskID.uuidString, roundID.uuidString, $0, eventID.uuidString, kind.rawValue, payload])
        }
        let alreadyBound = task.childBinding == principal && round.binding == principal
        let early = task.pendingRoundID == roundID && round.phase == .deliveringUnknown &&
            principal.sessionID == task.childSessionID && (task.childBinding == nil || task.childBinding == principal)
        guard alreadyBound || early else { throw SessionTaskError.staleBinding }
        if early, let reply = round.replyToEventID, task.currentAttentionID != reply { throw SessionTaskError.staleRound }
        if let prior = try reportOperation(operationID, fingerprint: fingerprint, legacyFingerprint: legacyFingerprint) { return prior }
        var observed: SessionTaskExecutionReference?
        if try store.event(eventID) == nil {
            guard task.activeRoundID == roundID || early else { throw SessionTaskError.staleBinding }
            let target = SessionTaskRoundTarget(taskID: taskID, roundID: roundID, inputOperationID: round.operationID,
                binding: principal, nativeTurnID: round.nativeTurnID, execution: round.execution)
            guard let execution = await host.observedChildExecution(target), Self.validExecution(execution),
                  try await authenticated(child) == principal else { throw SessionTaskError.unauthorized }
            observed = execution
        }
        let receipt = try store.transaction {
            guard var current = try store.task(taskID), var currentRound = try store.round(roundID),
                  currentRound.taskID == taskID, currentRound.operationID == round.operationID,
                  current.lifecycle == .active, current.authorityEpoch == task.authorityEpoch,
                  !isDeletionFenced(current) else {
                throw SessionTaskError.staleBinding
            }
            let boundNow = current.childBinding == principal && currentRound.binding == principal
            let earlyNow = current.pendingRoundID == roundID && currentRound.phase == .deliveringUnknown &&
                principal.sessionID == current.childSessionID && (current.childBinding == nil || current.childBinding == principal)
            guard boundNow || earlyNow else { throw SessionTaskError.staleBinding }
            if earlyNow, let reply = currentRound.replyToEventID, current.currentAttentionID != reply {
                throw SessionTaskError.staleRound
            }
            if let prior = try reportOperation(operationID, fingerprint: fingerprint, legacyFingerprint: legacyFingerprint) { return prior }
            if let existing = try store.event(eventID) {
                guard existing.taskID == taskID, existing.roundID == roundID,
                      existing.kind == kind, existing.payload == payload else { throw SessionTaskError.conflictingOperation }
                let receipt = SessionTaskReceipt(operationID: operationID, taskID: taskID, roundID: roundID, delivery: .verified)
                try store.createOperation(operationID, taskID: taskID, operation: .init(fingerprint: fingerprint, receipt: receipt))
                return receipt
            }
            if earlyNow {
                guard var dispatch = try store.operation(currentRound.operationID), dispatch.receipt.delivery == .unknown,
                      let observed, Self.matches(observed, round: currentRound) else {
                    throw SessionTaskError.staleRound
                }
                if let oldID = current.activeRoundID, var old = try store.round(oldID), old.phase == .awaitingParent {
                    old.phase = .retired; try store.save(old)
                }
                current.childBinding = principal; current.pendingRoundID = nil; current.activeRoundID = roundID
                current.currentAttentionID = nil
                current.uncertainChildEffects = max(0, current.uncertainChildEffects - 1)
                currentRound.binding = principal; currentRound.phase = .active
                dispatch.receipt.delivery = .submitted
                try store.saveOperation(currentRound.operationID, operation: dispatch)
            }
            guard current.activeRoundID == roundID else { throw SessionTaskError.staleBinding }
            guard let observed, (currentRound.phase == .active || currentRound.phase == .awaitingParent),
                  Self.matches(observed, round: currentRound) else {
                throw SessionTaskError.staleRound
            }
            if case let .nativeTurn(nativeTurnID) = observed { currentRound.nativeTurnID = nativeTurnID }
            currentRound.execution = observed
            switch kind {
            case .completed:
                currentRound.phase = .completed; current.activeRoundID = nil; current.currentAttentionID = nil
                try retireStaleReply(&current, keeping: nil)
            case .failed:
                currentRound.phase = .failed; current.activeRoundID = nil; current.currentAttentionID = nil
                try retireStaleReply(&current, keeping: nil)
            case .needsParentInput:
                currentRound.phase = .awaitingParent; current.currentAttentionID = eventID
                try retireStaleReply(&current, keeping: eventID)
            }
            let event = SessionTaskEvent(id: eventID, taskID: taskID, roundID: roundID,
                nativeTurnID: currentRound.nativeTurnID, execution: observed, kind: kind, payload: payload, occurredAt: now())
            let receipt = SessionTaskReceipt(operationID: operationID, taskID: taskID, roundID: roundID, delivery: .verified)
            current.revision += 1
            try store.create(event); try store.save(currentRound); try store.save(current)
            try store.createOperation(operationID, taskID: taskID, operation: .init(fingerprint: fingerprint, receipt: receipt))
            return receipt
        }
        changed(taskID)
        return receipt
    }

    /// Sends a bounded, coalesced nudge under this task's preapproved budget.
    /// It is a separate provider input from the app-only event itself.
    func wakePending(taskID: UUID, operationID: UUID) async throws -> SessionTaskReceipt {
        let fingerprint = Self.fingerprint(["wake", taskID.uuidString])
        let prepared: (SessionTaskProjection, [UUID], SessionTaskReceipt) = try store.transaction {
            guard var task = try store.task(taskID) else { throw SessionTaskError.notFound }
            if let prior = try sameOperation(operationID, fingerprint: fingerprint) { return (task, [], prior) }
            try requireGrant(task, remaining: task.parentWakesUsed < task.parentWakeLimit)
            guard task.uncertainWakeEffects == 0 else { throw SessionTaskError.unverified }
            let events = try store.pendingEventIDs(taskID: taskID, limit: SessionTaskLimits.pageSize)
            guard !events.isEmpty else { throw SessionTaskError.notReady }
            let receipt = SessionTaskReceipt(operationID: operationID, taskID: taskID, roundID: nil, delivery: .unknown)
            task.parentWakesUsed += 1; task.uncertainWakeEffects += 1; task.revision += 1
            try store.claimEvents(events, operationID: operationID)
            try store.createOperation(operationID, taskID: taskID, operation: .init(fingerprint: fingerprint, receipt: receipt,
                                                                                   binding: task.parentBinding, epoch: task.authorityEpoch))
            try store.save(task)
            return (task, events, receipt)
        }
        let (initial, events, initialReceipt) = prepared
        guard !events.isEmpty else { return initialReceipt }
        let lease = SessionTaskWakeLease()
        wakeLeases[taskID] = lease
        changed(taskID)
        let outcome = await host.wakeIfReady(SessionTaskWakeIntent(taskID: taskID, operationID: operationID,
                                                                  parentBinding: initial.parentBinding, eventCount: events.count,
                                                                  lease: lease))
        if wakeLeases[taskID] === lease { wakeLeases[taskID] = nil }
        let receipt = try store.transaction {
            guard var task = try store.task(taskID), var operation = try store.operation(operationID) else {
                throw SessionTaskError.notFound
            }
            // An exact provider-turn observation can arrive before this host
            // call returns; it is stronger evidence than a late unknown reply.
            if operation.receipt.observedConsumption != nil { return operation.receipt }
            switch outcome {
            case .verified:
                operation.receipt.delivery = .submitted
                task.uncertainWakeEffects = max(0, task.uncertainWakeEffects - 1)
                try store.settleEvents(operationID: operationID, delivered: true)
            case .deferred:
                operation.receipt.delivery = .deferred
                task.uncertainWakeEffects = max(0, task.uncertainWakeEffects - 1)
                if task.authorityEpoch == initial.authorityEpoch { task.parentWakesUsed = max(0, task.parentWakesUsed - 1) }
                try store.settleEvents(operationID: operationID, delivered: false)
            case .unknown: operation.receipt.delivery = .unknown
            }
            task.revision += 1
            try store.save(task); try store.saveOperation(operationID, operation: operation)
            return operation.receipt
        }
        changed(taskID)
        return receipt
    }

    /// A host-verified input observation is separate from a successful wake write.
    func observeWakeConsumption(taskID: UUID, operationID: UUID, binding: SessionTaskBinding) async throws -> SessionTaskReceipt {
        guard let prior = try store.operation(operationID),
              prior.receipt.taskID == taskID,
              (prior.receipt.delivery == .submitted || prior.receipt.delivery == .unknown), prior.binding == binding else {
            throw SessionTaskError.staleBinding
        }
        if prior.receipt.observedConsumption != nil { return prior.receipt }
        guard let before = try store.task(taskID), before.lifecycle == .active, before.parentBinding == binding,
              prior.epoch == before.authorityEpoch else { throw SessionTaskError.staleBinding }
        guard let observed = await host.observedWakeExecution(taskID: taskID, operationID: operationID, binding: binding),
              Self.validExecution(observed) else { throw SessionTaskError.unauthorized }
        let receipt = try store.transaction {
            guard var task = try store.task(taskID), var operation = try store.operation(operationID),
                  operation.receipt.taskID == taskID,
                  (operation.receipt.delivery == .submitted || operation.receipt.delivery == .unknown),
                  operation.binding == binding, task.lifecycle == .active, task.parentBinding == binding,
                  operation.epoch == task.authorityEpoch else { throw SessionTaskError.staleBinding }
            if let old = operation.receipt.observedConsumption {
                guard old == observed else { throw SessionTaskError.conflictingOperation }
                return operation.receipt
            }
            if operation.receipt.delivery == .unknown {
                operation.receipt.delivery = .submitted
                task.uncertainWakeEffects = max(0, task.uncertainWakeEffects - 1)
                try store.settleEvents(operationID: operationID, delivered: true)
            }
            operation.receipt.consumedExecution = observed
            if case let .nativeTurn(nativeTurnID) = observed { operation.receipt.consumedTurnID = nativeTurnID }
            if operation.epoch == task.authorityEpoch { task.parentWakesConsumed += 1 }
            task.revision += 1
            try store.save(task); try store.saveOperation(operationID, operation: operation)
            return operation.receipt
        }
        changed(taskID)
        return receipt
    }

    /// Resolve only the safety fence of an unknown wake. Its receipt stays
    /// unverified and its claimed events are never automatically resent.
    func verifyUnknownWakeStopped(taskID: UUID, operationID: UUID) async throws -> SessionTaskReceipt {
        guard let operation = try store.operation(operationID), operation.receipt.taskID == taskID,
              let binding = operation.binding else { throw SessionTaskError.notFound }
        if operation.receipt.delivery == .unverified { return operation.receipt }
        guard operation.receipt.delivery == .unknown else { throw SessionTaskError.notFound }
        guard await host.verifyUnknownWakeStopped(taskID: taskID, operationID: operationID, binding: binding) else {
            throw SessionTaskError.unverified
        }
        let receipt = try store.transaction {
            guard var task = try store.task(taskID), var current = try store.operation(operationID),
                  current.binding == binding else { throw SessionTaskError.staleBinding }
            if current.receipt.delivery == .submitted && current.receipt.observedConsumption != nil { return current.receipt }
            guard current.receipt.delivery == .unknown else { throw SessionTaskError.staleBinding }
            current.receipt.delivery = .unverified
            task.uncertainWakeEffects = max(0, task.uncertainWakeEffects - 1)
            task.revision += 1
            try store.save(task); try store.saveOperation(operationID, operation: current)
            return current.receipt
        }
        changed(taskID)
        return receipt
    }

    /// Only an explicit user-approved retry may release events whose previous
    /// delivery remains unknown. The approval must disclose possible prior
    /// consumption; this changes the mailbox, not a provider session.
    func requeueUnknownWakeAfterApproval(taskID: UUID, operationID: UUID) throws {
        try store.transaction {
            guard var task = try store.task(taskID), let operation = try store.operation(operationID),
                  operation.receipt.taskID == taskID, operation.receipt.delivery == .unverified,
                  operation.binding != nil, task.uncertainWakeEffects == 0 else { throw SessionTaskError.unverified }
            try requireGrant(task, remaining: task.parentWakesUsed < task.parentWakeLimit)
            try store.settleEvents(operationID: operationID, delivered: false)
            task.revision += 1
            try store.save(task)
        }
        changed(taskID)
    }

    /// Interrupt exactly one active round. A settled old round is a no-op and
    /// can never target the newer run. A replacement input is queued separately.
    public func interruptAndUpdate(taskID: UUID, parent: SessionTaskClaim, roundID: UUID, operationID: UUID,
                                   nextOperationID: UUID, message: String) async throws -> SessionTaskReceipt {
        try SessionTaskLimits.text(message)
        guard operationID != nextOperationID else { throw SessionTaskError.conflictingOperation }
        let principal = try await authenticated(parent)
        let fingerprint = Self.fingerprint(["interrupt", taskID.uuidString, roundID.uuidString,
                                            nextOperationID.uuidString, message])
        // A settled round or a replayed old operation must never fence a wake
        // belonging to the current work. An actual interrupt fences it before
        // the synchronous transaction retires the round.
        let current = try authorizedTask(taskID, parent: principal, allowRevoked: true)
        if let prior = try sameOperation(operationID, fingerprint: fingerprint) { return prior }
        guard let candidate = try store.round(roundID), candidate.taskID == taskID else { throw SessionTaskError.staleRound }
        if current.activeRoundID == roundID && candidate.phase != .completed && candidate.phase != .failed && candidate.phase != .retired {
            try requireGrant(current, remaining: current.childInputsUsed < current.childInputLimit)
            guard current.pendingRoundID == nil, candidate.binding != nil else { throw SessionTaskError.pendingInput }
            guard try store.operation(nextOperationID) == nil else { throw SessionTaskError.conflictingOperation }
            wakeLeases[taskID]?.cancel()
        }
        let prepared: (SessionTaskReceipt, SessionTaskRoundTarget?, Int64) = try store.transaction {
            var task = try authorizedTask(taskID, parent: principal, allowRevoked: true)
            if let prior = try sameOperation(operationID, fingerprint: fingerprint) { return (prior, nil, task.authorityEpoch) }
            guard let old = try store.round(roundID), old.taskID == taskID else { throw SessionTaskError.staleRound }
            if task.activeRoundID != roundID || old.phase == .completed || old.phase == .failed || old.phase == .retired {
                let receipt = SessionTaskReceipt(operationID: operationID, taskID: taskID, roundID: roundID, delivery: .alreadySettled)
                try store.createOperation(operationID, taskID: taskID, operation: .init(fingerprint: fingerprint, receipt: receipt))
                return (receipt, nil, task.authorityEpoch)
            }
            try requireGrant(task, remaining: task.childInputsUsed < task.childInputLimit)
            guard task.pendingRoundID == nil, let binding = old.binding else { throw SessionTaskError.pendingInput }
            guard try store.operation(nextOperationID) == nil else { throw SessionTaskError.conflictingOperation }
            var retired = old; retired.phase = .retired
            let next = SessionTaskRound(id: UUID(), taskID: taskID, ordinal: task.nextOrdinal,
                operationID: nextOperationID, message: message, replyToEventID: nil,
                phase: .queued, binding: nil, nativeTurnID: nil)
            task.activeRoundID = nil; task.pendingRoundID = next.id; task.nextOrdinal += 1
            // Revoke while interrupt is in flight: no Ready edge may submit the replacement.
            task.lifecycle = .revoked; task.uncertainChildEffects += 1; task.currentAttentionID = nil; task.revision += 1
            let receipt = SessionTaskReceipt(operationID: operationID, taskID: taskID, roundID: roundID, delivery: .unknown)
            let nextReceipt = SessionTaskReceipt(operationID: nextOperationID, taskID: taskID, roundID: next.id, delivery: .queued)
            try store.save(retired); try store.create(next); try store.save(task)
            try store.createOperation(operationID, taskID: taskID, operation: .init(fingerprint: fingerprint, receipt: receipt))
            try store.createOperation(nextOperationID, taskID: taskID,
                operation: .init(fingerprint: Self.fingerprint(["input", taskID.uuidString, message, ""]), receipt: nextReceipt))
            return (receipt, SessionTaskRoundTarget(taskID: taskID, roundID: roundID, inputOperationID: old.operationID,
                                                    binding: binding, nativeTurnID: old.nativeTurnID, execution: old.execution),
                    task.authorityEpoch)
        }
        guard let target = prepared.1 else { return prepared.0 }
        changed(taskID)
        let outcome = await host.interrupt(target)
        let receipt = try store.transaction {
            guard var task = try store.task(taskID), var operation = try store.operation(operationID) else { throw SessionTaskError.notFound }
            if case .verified = outcome {
                task.uncertainChildEffects = max(0, task.uncertainChildEffects - 1)
                if task.lifecycle == .revoked && task.authorityEpoch == prepared.2 { task.lifecycle = .active }
                operation.receipt.delivery = .verified
            } else { operation.receipt.delivery = .unverified }
            task.revision += 1
            try store.save(task); try store.saveOperation(operationID, operation: operation)
            return operation.receipt
        }
        changed(taskID)
        return receipt
    }

    /// Explicit whole-child stop. Revocation precedes the host effect. Unknown
    /// stop is retained and may be verified/retried by a new operation.
    public func stopChild(taskID: UUID, parent: SessionTaskClaim, operationID: UUID) async throws -> SessionTaskReceipt {
        let principal = try await authenticated(parent)
        let fingerprint = Self.fingerprint(["stop", taskID.uuidString])
        // A repeated old stop must not fence a newer grant. Once authorized,
        // cancel the live wake admission before beginning the stop transaction.
        _ = try authorizedTask(taskID, parent: principal, allowRevoked: true)
        if let prior = try sameOperation(operationID, fingerprint: fingerprint) { return prior }
        wakeLeases[taskID]?.cancel()
        let prepared: (SessionTaskReceipt, SessionTaskBinding?, Bool, Int64) = try store.transaction {
            var task = try authorizedTask(taskID, parent: principal, allowRevoked: true)
            if let prior = try sameOperation(operationID, fingerprint: fingerprint) { return (prior, nil, false, task.authorityEpoch) }
            if task.lifecycle == .stopped {
                let receipt = SessionTaskReceipt(operationID: operationID, taskID: taskID, roundID: nil, delivery: .verified)
                try store.createOperation(operationID, taskID: taskID, operation: .init(fingerprint: fingerprint, receipt: receipt))
                return (receipt, nil, false, task.authorityEpoch)
            }
            guard task.lifecycle != .stopping else { throw SessionTaskError.unverified }
            let hadUncertainStart: Bool
            if let pending = task.pendingRoundID, let round = try store.round(pending) { hadUncertainStart = round.phase == .deliveringUnknown }
            else { hadUncertainStart = false }
            let needsUnknownStop = task.childBinding == nil && (hadUncertainStart || task.uncertainChildEffects > 0)
            try retireRounds(&task)
            task.authorityEpoch += 1
            task.lifecycle = task.childBinding == nil && !needsUnknownStop ? .stopped : .stopping
            task.revision += 1
            let receipt = SessionTaskReceipt(operationID: operationID, taskID: taskID, roundID: nil,
                                              delivery: task.lifecycle == .stopped ? .verified : .unknown)
            try store.createOperation(operationID, taskID: taskID, operation: .init(fingerprint: fingerprint, receipt: receipt))
            try store.save(task)
            return (receipt, task.childBinding, needsUnknownStop, task.authorityEpoch)
        }
        changed(taskID)
        guard prepared.1 != nil || prepared.2 else { return prepared.0 }
        let outcome: SessionTaskEffect
        if let binding = prepared.1 { outcome = await host.stopChild(taskID: taskID, binding: binding) }
        else {
            guard let task = try store.task(taskID) else { throw SessionTaskError.notFound }
            outcome = await host.stopUnknownChild(taskID: taskID, childSessionID: task.childSessionID)
        }
        let receipt = try store.transaction {
            guard var task = try store.task(taskID), var operation = try store.operation(operationID) else { throw SessionTaskError.notFound }
            if case .verified = outcome {
                operation.receipt.delivery = .verified
                if task.authorityEpoch == prepared.3 && task.lifecycle == .stopping {
                    task.lifecycle = .stopped; task.uncertainChildEffects = 0
                }
            } else {
                operation.receipt.delivery = .unverified
                if task.authorityEpoch == prepared.3 && task.lifecycle == .stopping { task.lifecycle = .stopUnverified }
            }
            task.revision += 1
            try store.save(task); try store.saveOperation(operationID, operation: operation)
            return operation.receipt
        }
        changed(taskID)
        return receipt
    }

    /// Runtime lifecycle hook: fence old runs before Stop, Quit, deletion or
    /// identity switch. It is not an agent/wire operation.
    func fence(taskID: UUID, binding: SessionTaskBinding, identityChanged: Bool = false) throws {
        let mutation = {
            try self.store.transaction {
                guard var task = try self.store.task(taskID) else { throw SessionTaskError.notFound }
                guard task.parentBinding == binding || task.childBinding == binding else { throw SessionTaskError.staleBinding }
                try self.retireRounds(&task)
                task.authorityEpoch += 1
                task.lifecycle = identityChanged ? .identityChanged : .revoked
                task.revision += 1
                try self.store.save(task)
                return true
            }
        }
        if let lease = wakeLeases[taskID] { _ = try lease.cancelIfChanged(mutation) } else { _ = try mutation() }
        changed(taskID)
    }

    /// The app calls after explicit approval and authenticating a resumed run.
    /// Native identity must remain the same; a provider /new is never adopted.
    func rebindAndApprove(taskID: UUID, parent: SessionTaskClaim, child: SessionTaskClaim? = nil) async throws -> SessionTaskProjection {
        let parentBinding = try await authenticated(parent)
        let childBinding: SessionTaskBinding?
        if let child { childBinding = try await authenticated(child) } else { childBinding = nil }
        let task = try store.transaction {
            guard var task = try store.task(taskID), task.lifecycle == .revoked || task.lifecycle == .stopped,
                  !isDeletionFenced(task) else {
                throw SessionTaskError.needsApproval
            }
            guard task.uncertainChildEffects == 0 && task.uncertainWakeEffects == 0 else { throw SessionTaskError.unverified }
            guard parentBinding.sessionID == task.parentSessionID,
                  parentBinding.nativeSessionID == task.parentBinding.nativeSessionID else { throw SessionTaskError.staleBinding }
            if let old = task.childBinding {
                guard let childBinding, childBinding.sessionID == task.childSessionID,
                      childBinding.nativeSessionID == old.nativeSessionID else { throw SessionTaskError.staleBinding }
                task.childBinding = childBinding
            } else if childBinding != nil { throw SessionTaskError.staleBinding }
            task.parentBinding = parentBinding
            task.lifecycle = .active
            task.expiresAt = now().addingTimeInterval(SessionTaskLimits.grantLifetime)
            task.childInputsUsed = 0; task.parentWakesUsed = 0; task.parentWakesConsumed = 0
            task.authorityEpoch += 1; task.revision += 1
            try store.save(task)
            return task
        }
        changed(taskID)
        return task
    }

    public func status(taskID: UUID, parent: SessionTaskClaim) async throws -> SessionTaskStatus {
        let principal = try await authenticated(parent)
        let before = try authorizedTask(taskID, parent: principal, allowRevoked: true)
        let native = if let binding = before.childBinding { await host.nativeStatus(binding: binding) }
                     else { SessionTaskNativeStatus.notStarted }
        let current = try authorizedTask(taskID, parent: principal, allowRevoked: true)
        let observed = current.childBinding == before.childBinding ? native : .unknown
        let active = try current.activeRoundID.flatMap { try store.round($0) }
        let pending = try current.pendingRoundID.flatMap { try store.round($0) }
        return SessionTaskStatus(task: current, activeRound: active, pendingRound: pending, nativeStatus: observed,
                                 missingReport: observed == .ready && active?.phase == .active)
    }

    /// App-only projection for a card even when its parent run is stopped.
    /// A future UI bridge must not turn this into an unauthenticated wire read.
    func projectionForUser(taskID: UUID) throws -> SessionTaskProjection? { try store.task(taskID) }

    func latestEventsForUser(taskID: UUID, limit: Int) throws -> [SessionTaskEvent] {
        guard (1...10).contains(limit) else { throw SessionTaskError.invalidPage }
        guard try store.task(taskID) != nil else { throw SessionTaskError.notFound }
        return try store.latestEvents(taskID: taskID, limit: limit)
    }

    func identity(for claim: SessionTaskClaim) async throws -> SessionTaskBinding { try await authenticated(claim) }

    func projectionForChild(_ sessionID: UUID) throws -> SessionTaskProjection? {
        try store.taskForChild(sessionID)
    }

    func projectionsForUser(parentSessionID: UUID? = nil, after: UUID?, limit: Int) throws -> SessionTaskProjectionPage {
        guard (1...SessionTaskLimits.pageSize).contains(limit) else { throw SessionTaskError.invalidPage }
        let values = try store.projections(parentSessionID: parentSessionID, after: after, limit: limit)
        return SessionTaskProjectionPage(items: values, next: values.count == limit ? values.last?.id : nil)
    }

    /// Subscribe before loading pages. Frames coalesce; each revision means
    /// reread durable projections rather than trusting a complete event list.
    func projectionUpdatesForUser() -> AsyncStream<UInt64> {
        let (stream, continuation) = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard projectionSubscribers.count < SessionTaskLimits.maxWaiters else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        projectionSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeProjectionSubscriber(id) } }
        continuation.yield(projectionRevision)
        return stream
    }

    func finishProjectionUpdates() {
        for continuation in projectionSubscribers.values { continuation.finish() }
        projectionSubscribers.removeAll()
    }

    private func removeProjectionSubscriber(_ id: UUID) { projectionSubscribers[id] = nil }

    public func rounds(taskID: UUID, parent: SessionTaskClaim, after: Int64 = 0, limit: Int = 50) async throws -> SessionTaskPage<SessionTaskRound> {
        try validatePage(after: after, limit: limit)
        let principal = try await authenticated(parent)
        _ = try authorizedTask(taskID, parent: principal, allowRevoked: true)
        let values = try store.rounds(taskID: taskID, after: after, limit: limit)
        return SessionTaskPage(items: values, next: values.count == limit ? values.last.map { Int64($0.ordinal) } : nil)
    }

    public func events(taskID: UUID, parent: SessionTaskClaim, after: Int64 = 0, limit: Int = 50) async throws -> SessionTaskPage<SessionTaskEvent> {
        try validatePage(after: after, limit: limit)
        let principal = try await authenticated(parent)
        _ = try authorizedTask(taskID, parent: principal, allowRevoked: true)
        let values = try store.events(taskID: taskID, after: after, limit: limit)
        return SessionTaskPage(items: values.map(\.event), next: values.count == limit ? values.last?.sequence : nil)
    }

    public func eventEntries(taskID: UUID, parent: SessionTaskClaim, after: Int64 = 0,
                             limit: Int = 50) async throws -> SessionTaskPage<SessionTaskEventEntry> {
        try validatePage(after: after, limit: limit)
        let principal = try await authenticated(parent)
        _ = try authorizedTask(taskID, parent: principal, allowRevoked: true)
        let values = try store.events(taskID: taskID, after: after, limit: limit)
        return SessionTaskPage(items: values.map { SessionTaskEventEntry(cursor: $0.sequence, event: $0.event) },
                               next: values.count == limit ? values.last?.sequence : nil)
    }

    /// A child reads only the exact input the trusted host observed for its
    /// current task, round, operation and live run. App IDs alone are not proof.
    func childInput(taskID: UUID, child: SessionTaskClaim, roundID: UUID,
                    inputOperationID: UUID) async throws -> String {
        let binding = try await authenticated(child)
        guard let task = try store.task(taskID), let round = try store.round(roundID),
              task.lifecycle == .active, !isDeletionFenced(task), task.childSessionID == binding.sessionID,
              round.taskID == taskID, round.operationID == inputOperationID,
              (task.activeRoundID == roundID && round.binding == binding && round.phase == .active)
                || (task.pendingRoundID == roundID && round.phase == .deliveringUnknown &&
                    (task.childBinding == nil || task.childBinding == binding)) else {
            throw SessionTaskError.staleRound
        }
        let target = SessionTaskRoundTarget(taskID: taskID, roundID: roundID, inputOperationID: inputOperationID,
                                            binding: binding, nativeTurnID: round.nativeTurnID, execution: round.execution)
        guard let observed = await host.observedChildExecution(target), Self.validExecution(observed),
              Self.matches(observed, round: round), try await authenticated(child) == binding,
              let current = try store.task(taskID), let currentRound = try store.round(roundID),
              current.lifecycle == .active, !isDeletionFenced(current), current.authorityEpoch == task.authorityEpoch,
              currentRound.operationID == inputOperationID,
              (current.activeRoundID == roundID && currentRound.binding == binding && currentRound.phase == .active)
                || (current.pendingRoundID == roundID && currentRound.phase == .deliveringUnknown &&
                    (current.childBinding == nil || current.childBinding == binding)) else {
            throw SessionTaskError.staleRound
        }
        return currentRound.message
    }

    /// The caller explicitly read these task events. This is separate from
    /// provider consumption of a wake.
    public func acknowledgeEvents(taskID: UUID, parent: SessionTaskClaim, eventIDs: [UUID]) async throws {
        guard !eventIDs.isEmpty, eventIDs.count <= SessionTaskLimits.pageSize else { throw SessionTaskError.invalidPage }
        let principal = try await authenticated(parent)
        let mutation = {
            try self.store.transaction {
                var task = try self.authorizedTask(taskID, parent: principal, allowRevoked: true)
                guard try self.store.acknowledgeEvents(eventIDs, taskID: taskID) else { return false }
                task.revision += 1
                try self.store.save(task)
                return true
            }
        }
        let didChange = if let lease = wakeLeases[taskID] { try lease.cancelIfChanged(mutation) } else { try mutation() }
        if didChange { changed(taskID) }
    }

    /// Event driven: one bounded timer only while a caller is waiting. After any
    /// wake, read durable state again rather than trusting a buffered frame.
    public func wait(taskID: UUID, parent: SessionTaskClaim, afterRevision: Int64,
                     seconds: TimeInterval) async throws -> SessionTaskProjection? {
        guard seconds > 0, seconds <= SessionTaskLimits.maxWait, seconds.isFinite else { throw SessionTaskError.invalidDeadline }
        let principal = try await authenticated(parent)
        let current = try authorizedTask(taskID, parent: principal, allowRevoked: true)
        if current.revision > afterRevision { return current }
        guard waiters.count < SessionTaskLimits.maxWaiters else { throw SessionTaskError.tooManyWaiters }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(); return }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    if !Task.isCancelled { await self?.finishWaiter(waiterID) }
                }
                waiters[waiterID] = Waiter(taskID: taskID, continuation: continuation, timeout: timer)
            }
        } onCancel: { Task { await self.finishWaiter(waiterID) } }
        try Task.checkCancellation()
        let again = try await authenticated(parent)
        let result = try authorizedTask(taskID, parent: again, allowRevoked: true)
        return result.revision > afterRevision ? result : nil
    }

    /// Only the runtime's fenced deletion calls this. Stop each owned child
    /// before forgetting any relationship; a failed/uncertain stop remains
    /// durable and makes the deletion retryable.
    func forgetAfterVerifiedStop(sessionID: UUID) async throws {
        guard deletionsInProgress.insert(sessionID).inserted else { throw SessionTaskError.unverified }
        deletionFences.insert(sessionID)
        defer {
            deletionsInProgress.remove(sessionID)
            if activeCreations[sessionID] == nil { deletionFences.remove(sessionID) }
        }
        guard await host.mayForget(sessionID: sessionID) else { throw SessionTaskError.unverified }
        var cursor: UUID?
        repeat {
            let page = try store.projections(parentSessionID: sessionID, after: cursor, limit: SessionTaskLimits.pageSize)
            for task in page { try await stopOwnedChildForDeletion(task.id) }
            cursor = page.count == SessionTaskLimits.pageSize ? page.last?.id : nil
            if cursor != nil { await Task.yield() }
        } while cursor != nil
        guard await host.mayForget(sessionID: sessionID) else { throw SessionTaskError.unverified }
        try store.forget(sessionID: sessionID)
        for id in Array(waiters.keys) { finishWaiter(id) }
        projectionChanged()
    }

    private func stopOwnedChildForDeletion(_ taskID: UUID) async throws {
        wakeLeases[taskID]?.cancel()
        let prepared: (SessionTaskBinding?, UUID, Bool, Int64)? = try store.transaction {
            guard var task = try store.task(taskID) else { return nil }
            if task.lifecycle == .stopped { return nil }
            guard task.lifecycle != .stopping else { throw SessionTaskError.unverified }
            let unknownStart: Bool
            if let pending = task.pendingRoundID, let round = try store.round(pending) {
                unknownStart = round.phase == .deliveringUnknown
            } else { unknownStart = false }
            let needsUnknownStop = task.childBinding == nil && (unknownStart || task.uncertainChildEffects > 0)
            try retireRounds(&task)
            task.authorityEpoch += 1
            task.lifecycle = task.childBinding == nil && !needsUnknownStop ? .stopped : .stopping
            task.revision += 1
            try store.save(task)
            return task.lifecycle == .stopped ? nil : (task.childBinding, task.childSessionID, needsUnknownStop, task.authorityEpoch)
        }
        changed(taskID)
        guard let prepared else { return }
        let outcome: SessionTaskEffect
        if let binding = prepared.0 { outcome = await host.stopChild(taskID: taskID, binding: binding) }
        else if prepared.2 { outcome = await host.stopUnknownChild(taskID: taskID, childSessionID: prepared.1) }
        else { outcome = .unknown }
        let verified = try store.transaction {
            guard var task = try store.task(taskID), task.authorityEpoch == prepared.3, task.lifecycle == .stopping else {
                return false
            }
            if case .verified = outcome {
                task.lifecycle = .stopped
                task.uncertainChildEffects = 0
            } else { task.lifecycle = .stopUnverified }
            task.revision += 1
            try store.save(task)
            return task.lifecycle == .stopped
        }
        changed(taskID)
        guard verified else { throw SessionTaskError.unverified }
    }

    private func isDeletionFenced(_ task: SessionTaskProjection) -> Bool {
        deletionFences.contains(task.parentSessionID) || deletionFences.contains(task.childSessionID)
    }

    private func authenticated(_ claim: SessionTaskClaim) async throws -> SessionTaskBinding {
        guard !claim.credential.isEmpty, claim.credential.utf8.count <= 4_096, !claim.credential.utf8.contains(0),
              let value = await host.authenticate(claim),
              value.sessionID == claim.sessionID, value.managedRunID == claim.managedRunID,
              value.generation == claim.generation, Self.validMetadata(value.nativeSessionID) else { throw SessionTaskError.unauthorized }
        return value
    }

    private func authorizedTask(_ id: UUID, parent: SessionTaskBinding, allowRevoked: Bool = false) throws -> SessionTaskProjection {
        guard let task = try store.task(id) else { throw SessionTaskError.notFound }
        guard task.parentBinding == parent, task.parentSessionID == parent.sessionID,
              !isDeletionFenced(task) else { throw SessionTaskError.unauthorized }
        if !allowRevoked && task.lifecycle != .active { throw SessionTaskError.needsApproval }
        return task
    }

    private func requireGrant(_ task: SessionTaskProjection, remaining: Bool) throws {
        guard task.lifecycle == .active, !isDeletionFenced(task), now() < task.expiresAt, remaining else {
            throw SessionTaskError.needsApproval
        }
    }

    private func sameOperation(_ id: UUID, fingerprint: String) throws -> SessionTaskReceipt? {
        guard let operation = try store.operation(id) else { return nil }
        guard operation.fingerprint == fingerprint else { throw SessionTaskError.conflictingOperation }
        return operation.receipt
    }

    /// Version-one report fingerprints included the native turn supplied by
    /// the caller. Preserve their receipts while new reports use host evidence.
    private func reportOperation(_ id: UUID, fingerprint: String, legacyFingerprint: String?) throws -> SessionTaskReceipt? {
        guard let operation = try store.operation(id) else { return nil }
        guard operation.fingerprint == fingerprint || operation.fingerprint == legacyFingerprint else {
            throw SessionTaskError.conflictingOperation
        }
        return operation.receipt
    }

    private func retireRounds(_ task: inout SessionTaskProjection) throws {
        for id in [task.activeRoundID, task.pendingRoundID].compactMap({ $0 }) {
            guard var round = try store.round(id) else { continue }
            if round.phase == .queued, var operation = try store.operation(round.operationID) {
                operation.receipt.delivery = .cancelled
                try store.saveOperation(round.operationID, operation: operation)
            }
            if round.phase != .completed && round.phase != .failed { round.phase = .retired; try store.save(round) }
        }
        task.activeRoundID = nil; task.pendingRoundID = nil
        task.currentAttentionID = nil
    }

    private func retireStaleReply(_ task: inout SessionTaskProjection, keeping eventID: UUID?) throws {
        guard let pendingID = task.pendingRoundID, var pending = try store.round(pendingID),
              pending.phase == .queued, let reply = pending.replyToEventID, reply != eventID else { return }
        guard var operation = try store.operation(pending.operationID) else { throw SessionTaskError.storage }
        pending.phase = .retired; operation.receipt.delivery = .cancelled; task.pendingRoundID = nil
        try store.save(pending); try store.saveOperation(pending.operationID, operation: operation)
    }

    private func validatePage(after: Int64, limit: Int) throws {
        guard after >= 0, (1...SessionTaskLimits.pageSize).contains(limit) else { throw SessionTaskError.invalidPage }
    }

    private func changed(_ taskID: UUID) {
        let ids = waiters.compactMap { $0.value.taskID == taskID ? $0.key : nil }
        for id in ids { finishWaiter(id) }
        projectionChanged()
    }

    private func projectionChanged() {
        projectionRevision &+= 1
        for continuation in projectionSubscribers.values { continuation.yield(projectionRevision) }
    }

    private func finishWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume()
    }

    private static func fingerprint(_ parts: [String]) -> String {
        let text = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validMetadata(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 256 && !value.utf8.contains(0)
    }

    private static func validExecution(_ execution: SessionTaskExecutionReference) -> Bool {
        switch execution {
        case let .nativeTurn(value), let .providerPrompt(value): validMetadata(value)
        case .appInputObservation: true
        }
    }

    private static func matches(_ execution: SessionTaskExecutionReference, round: SessionTaskRound) -> Bool {
        guard round.execution == nil || round.execution == execution else { return false }
        if case let .nativeTurn(turn) = execution, let existing = round.nativeTurnID { return turn == existing }
        return true
    }
}
