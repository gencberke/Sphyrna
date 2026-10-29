import Foundation

/// A live read/wait gets first chance to acknowledge its returned page. This
/// prevents a redundant nudge while the provider's blocking tool is receiving
/// the same events. A disconnected reader releases its bounded lease.
final class SessionTaskReadFence: @unchecked Sendable {
    private struct Owner: Equatable {
        let taskID: UUID
        let sessionID: UUID
        let runID: UUID
        let generation: UUID
        init(taskID: UUID, claim: SessionTaskClaim) {
            self.taskID = taskID; sessionID = claim.sessionID; runID = claim.managedRunID; generation = claim.generation
        }
    }
    private struct Entry {
        let owner: Owner
        var eventIDs: Set<UUID>?
        var timeout: Task<Void, Never>?
    }
    private let lock = NSLock()
    private let wake: @Sendable (UUID) -> Void
    private var entries: [UUID: Entry] = [:]
    private var pending: Set<UUID> = []
    private var stopped = false

    init(wake: @escaping @Sendable (UUID) -> Void) { self.wake = wake }
    deinit { stop() }

    func begin(taskID: UUID, claim: SessionTaskClaim) throws -> UUID {
        try lock.withLock {
            guard !stopped, entries.count < 32 else { throw SessionTaskError.tooManyWaiters }
            let id = UUID()
            entries[id] = Entry(owner: Owner(taskID: taskID, claim: claim))
            return id
        }
    }

    func delivered(_ id: UUID, eventIDs: [UUID]) {
        guard !eventIDs.isEmpty else { release(id); return }
        lock.withLock {
            guard entries[id] != nil, !stopped else { return }
            entries[id]?.eventIDs = Set(eventIDs)
            entries[id]?.timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.release(id)
            }
        }
    }

    func acknowledge(_ id: UUID, taskID: UUID, claim: SessionTaskClaim, eventIDs: [UUID]) {
        let matches = lock.withLock {
            guard let entry = entries[id] else { return false }
            return entry.owner == Owner(taskID: taskID, claim: claim) && entry.eventIDs == Set(eventIDs)
        }
        if matches { release(id) }
    }

    func scheduleWake(taskID: UUID) {
        let canWake = lock.withLock {
            guard !stopped else { return false }
            if entries.values.contains(where: { $0.owner.taskID == taskID }) {
                pending.insert(taskID)
                return false
            }
            return true
        }
        if canWake { wake(taskID) }
    }

    /// Called around the synchronous queue admission, not just when a wake is
    /// scheduled, so a read that starts in the meantime still wins safely.
    func attemptWake(taskID: UUID, _ admit: () -> Bool) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            if entries.values.contains(where: { $0.owner.taskID == taskID }) {
                pending.insert(taskID)
                return false
            }
            return admit()
        }
    }

    func hasReader(taskID: UUID) -> Bool {
        lock.withLock { entries.values.contains { $0.owner.taskID == taskID } }
    }

    func release(_ id: UUID) {
        let wakeID: UUID? = lock.withLock {
            guard let entry = entries.removeValue(forKey: id) else { return nil }
            entry.timeout?.cancel()
            guard !stopped, pending.contains(entry.owner.taskID),
                  !entries.values.contains(where: { $0.owner.taskID == entry.owner.taskID }) else { return nil }
            pending.remove(entry.owner.taskID)
            return entry.owner.taskID
        }
        if let wakeID { wake(wakeID) }
    }

    func stop() {
        let timers: [Task<Void, Never>] = lock.withLock {
            guard !stopped else { return [] }
            stopped = true
            let result = entries.values.compactMap(\.timeout)
            entries.removeAll(); pending.removeAll()
            return result
        }
        for timer in timers { timer.cancel() }
    }
}
