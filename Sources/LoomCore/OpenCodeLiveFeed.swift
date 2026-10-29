import Foundation

/// One server generation and one application/native session binding. Only
/// bounded identity/status metadata survives; observers receive the newest
/// snapshot rather than a backlog of native events.
public final class OpenCodeLiveFeed: @unchecked Sendable {
    private let lock = NSLock()
    private let appSessionID: UUID
    private let runID: UUID
    private var connected = false
    private var ended = false
    private var early: [OpenCodeEvent] = []
    private var state: OpenCodeLiveState?
    private var observerID: UUID?
    private var observer: AsyncStream<OpenCodeLiveSnapshot>.Continuation?
    private let cleanupQueue = DispatchQueue(label: "sphyrna.opencode.events.observers")

    init(appSessionID: UUID, runID: UUID) {
        self.appSessionID = appSessionID
        self.runID = runID
    }

    func didConnect() {
        lock.withLock { if !ended { connected = true } }
    }

    /// Return false on loss of bounded ordering so the stream closes.
    func receive(_ event: OpenCodeEvent) -> Bool {
        lock.withLock {
            guard connected, !ended else { return false }
            if state == nil {
                guard early.count < 128 else { ended = true; connected = false; early.removeAll(); return false }
                early.append(event)
                return true
            }
            let before = state!.snapshot
            state!.receive(event)
            publishIfChanged(before)
            let reliable = state!.isReliable
            if !reliable { connected = false; ended = true }
            return reliable
        }
    }

    func didDisconnect() {
        let prior = lock.withLock {
            ended = true
            connected = false
            early.removeAll()
            if let before = state?.snapshot {
                state?.disconnected()
                publishIfChanged(before)
            }
            let prior = observer
            observer = nil
            observerID = nil
            return prior
        }
        prior?.finish()
    }

    func bind(nativeSessionID: String) throws {
        try lock.withLock {
            guard connected, !ended, state == nil,
                  OpenCodeLaunchProfile.validID(nativeSessionID, prefix: "ses") else { throw OpenCodeError.unavailable }
            var next = OpenCodeLiveState(appSessionID: appSessionID, runID: runID, nativeSessionID: nativeSessionID)
            for event in early { next.receive(event) }
            early.removeAll()
            guard next.isReliable else {
                state = next
                connected = false
                ended = true
                publish()
                throw OpenCodeError.unavailable
            }
            state = next
            publish()
        }
    }

    public var isConnected: Bool { lock.withLock { connected && !ended } }
    public var snapshot: OpenCodeLiveSnapshot? { lock.withLock { state?.snapshot } }
    var permitsFirstAttachment: Bool {
        lock.withLock { connected && !ended && state?.snapshot.creationSequence != nil }
    }

    /// Reserves the exact app round and input before sending any bytes.
    func begin(roundID: UUID, inputID: String, requireCreation: Bool) throws {
        try lock.withLock {
            guard connected, !ended, let before = state?.snapshot,
                  !requireCreation || before.creationSequence != nil else { throw OpenCodeError.unavailable }
            try state?.begin(roundID: roundID, inputID: inputID)
            publishIfChanged(before)
        }
    }

    func receipt(inputID: String) throws {
        try lock.withLock {
            guard connected, !ended, let before = state?.snapshot else { throw OpenCodeError.unavailable }
            try state?.receipt(inputID: inputID)
            publishIfChanged(before)
        }
    }

    func indeterminate(inputID: String) {
        lock.withLock {
            guard let before = state?.snapshot else { return }
            state?.indeterminate(inputID: inputID)
            publishIfChanged(before)
        }
    }

    /// A single bounded subscriber per feed. A later subscriber replaces the
    /// former one; events continue to update the authoritative snapshot.
    public func updates() -> AsyncStream<OpenCodeLiveSnapshot> {
        let pair = AsyncStream<OpenCodeLiveSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        pair.continuation.onTermination = { [weak self] _ in
            self?.cleanupQueue.async { [weak self] in
                self?.lock.withLock {
                    if self?.observerID == token { self?.observerID = nil; self?.observer = nil }
                }
            }
        }
        let (old, finish) = lock.withLock {
            let old = observer
            observer = nil
            observerID = nil
            if ended {
                if let value = state?.snapshot { _ = pair.continuation.yield(value) }
                return (old, true)
            }
            observerID = token
            observer = pair.continuation
            publish()
            return (old, false)
        }
        old?.finish()
        if finish { pair.continuation.finish() }
        return pair.stream
    }

    private func publishIfChanged(_ before: OpenCodeLiveSnapshot) {
        if state?.snapshot != before { publish() }
    }
    private func publish() {
        if let value = state?.snapshot { _ = observer?.yield(value) }
    }
}
