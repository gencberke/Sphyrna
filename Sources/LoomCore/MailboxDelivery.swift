import Foundation

/// Fences pending approvals and pointer writes when a target stops, changes
/// identity or begins deletion. A replacement run gets a new fence.
final class PeerTargetFence: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func revoke() { lock.withLock { active = false } }
    var isActive: Bool { lock.withLock { active } }
    func attempt(_ body: () -> Bool) -> Bool { lock.withLock { active && body() } }
}

final class PeerTargetFences: @unchecked Sendable {
    private final class WeakFence { weak var value: PeerTargetFence?; init(_ value: PeerTargetFence) { self.value = value } }
    private let lock = NSLock()
    private var entries: [UUID: WeakFence] = [:]
    private var blocked: Set<UUID> = []

    func acquire(_ target: UUID) -> PeerTargetFence? {
        lock.withLock {
            guard !blocked.contains(target) else { return nil }
            if let existing = entries[target]?.value { return existing }
            if entries.count >= 256 { entries = entries.filter { $0.value.value != nil } }
            guard entries.count < 256 else { return nil }
            let fence = PeerTargetFence(); entries[target] = WeakFence(fence)
            return fence
        }
    }

    func rotate(_ target: UUID) {
        lock.withLock { entries.removeValue(forKey: target)?.value?.revoke() }
    }

    func block(_ target: UUID) {
        lock.withLock { blocked.insert(target); entries.removeValue(forKey: target)?.value?.revoke() }
    }

    func unblock(_ target: UUID) { _ = lock.withLock { blocked.remove(target) } }
}
