import Foundation
import LoomCore

extension ChatSessionDriver {
    // MARK: Queue

    /// Adds a message to the end of the queue. Refused (`queueFull`) past `ChatQueue.maximumItems` items or
    /// `ChatQueue.maximumBytes` bytes.
    @discardableResult
    public func enqueue(_ text: String) throws -> String {
        guard queue.admits(text) else { throw ChatDriverError.queueFull }
        let item = ChatQueue.Item(text: text, queuedAt: clock())
        queue.items.append(item)
        saveQueue()
        return item.id
    }

    public func editQueued(id: String, text: String) throws {
        guard let i = queue.items.firstIndex(where: { $0.id == id }) else { throw ChatDriverError.noSuchQueueItem(id) }
        guard queue.admits(text, replacing: id) else { throw ChatDriverError.queueFull }
        queue.items[i].text = text
        saveQueue()
    }

    public func moveQueued(id: String, to position: Int) throws {
        guard let i = queue.items.firstIndex(where: { $0.id == id }) else { throw ChatDriverError.noSuchQueueItem(id) }
        let item = queue.items.remove(at: i)
        queue.items.insert(item, at: min(max(0, position), queue.items.count))
        saveQueue()
    }

    @discardableResult
    public func removeQueued(id: String) throws -> ChatQueue.Item {
        guard let i = queue.items.firstIndex(where: { $0.id == id }) else { throw ChatDriverError.noSuchQueueItem(id) }
        let item = queue.items.remove(at: i)
        if queue.isEmpty { queue.paused = nil }
        saveQueue()
        return item
    }

    /// Sends a queued item at once: with priority `now` into a running turn, as a new turn otherwise. The item leaves
    /// the queue only once it is written; if it cannot be (the resume failed, a Stop began, the input is full), it
    /// stays where it was and the error says why.
    @discardableResult
    public func sendQueuedNow(id: String) async throws -> String {
        guard queue.items.contains(where: { $0.id == id }) else { throw ChatDriverError.noSuchQueueItem(id) }
        guard !handover.isHolding else { throw ChatDriverError.handingOver }
        // A files rewind (or its Undo) is under way: a turn must not start in the middle of it.
        guard !rewindBusy else { throw ChatDriverError.busy }
        // `now` cancels the running step: into a waiting approval it would land on the request. The user answers it first.
        guard requests.isEmpty else { throw ChatDriverError.requestWaiting }
        try await ensureLive()
        guard let i = queue.items.firstIndex(where: { $0.id == id }) else { throw ChatDriverError.noSuchQueueItem(id) }
        guard requests.isEmpty else { throw ChatDriverError.requestWaiting }
        let item = queue.items.remove(at: i)
        do {
            let uuid = try await write(ChatSentMessage(text: item.text, attachments: []),
                                       priority: turnRunning && requests.isEmpty ? .now : .next)
            if queue.isEmpty { queue.paused = nil }
            saveQueue()
            return uuid
        } catch {
            queue.items.insert(item, at: min(i, queue.items.count))
            saveQueue()
            throw error
        }
    }

    /// Lifts a pause; the first item goes out when no turn runs and no request waits. Refused (the pause stays) while a
    /// files rewind or its Undo runs.
    public func resumeQueue() async throws {
        guard !rewindBusy else { throw ChatDriverError.busy }
        queue.paused = nil
        saveQueue()
        try await releaseQueue()
    }

    @discardableResult
    public func clearQueue() -> [ChatQueue.Item] {
        let items = queue.items
        queue = ChatQueue()
        saveQueue()
        return items
    }

    func pauseQueue(_ reason: ChatQueue.PauseReason) {
        queue.paused = reason
        saveQueue()
    }

    private func saveQueue() {
        do {
            try queueStore?.save(queue, sessionID: sessionID)
            if case .notSaved = queueIssue { queueIssue = nil }
        } catch {
            queueIssue = .notSaved(LoomLog.category(of: error))
            LoomLog.error(.chat, "The Chat queue could not be saved (\(LoomLog.category(of: error)))")
        }
        changed()
    }

    /// Sends the first item when nothing runs, nothing waits and the queue is not paused. The item leaves the queue
    /// only once it is written; one that cannot be goes back to the head and the error is thrown.
    private func releaseQueue() async throws {
        guard queue.paused == nil, !handover.isHolding, phase != .stopping, !turnRunning, requests.isEmpty,
              let first = queue.items.first else { return }
        try await ensureLive()
        guard queue.paused == nil, !handover.isHolding, phase != .stopping, !turnRunning, requests.isEmpty,
              queue.items.first?.id == first.id else { return }
        queue.items.removeFirst()
        do {
            _ = try await write(ChatSentMessage(text: first.text, attachments: []), priority: .next)
            if case .notSent = queueIssue { queueIssue = nil }
            saveQueue()
        } catch {
            queue.items.insert(first, at: 0)
            saveQueue()
            throw error
        }
    }

    func releaseQueueReportingIssue() async {
        do {
            try await releaseQueue()
        } catch {
            queueIssue = .notSent(LoomLog.category(of: error))
            changed()
        }
    }
}
