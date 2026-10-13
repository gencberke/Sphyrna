import Foundation
import LoomTerminal

/// The last screens of sessions whose run ended (FB4-3, replacing D-45's live surfaces): static snapshots,
/// memory-only, least recently used out first. Not tied to the selection or the tabs, so a stopped session
/// whose tab closed still shows its last screen when it is selected later. Never persisted: a deleted
/// session leaves nothing behind (contract §8).
struct EndedScreenStore {
    /// A screen is a few tens of KB (a full-screen TUI, measured) up to the per-screen cap of 1 MiB; 16 of
    /// them stay under 4 MiB in the worst case, in practice under 1 MiB.
    static let maxCount = 16
    static let maxBytes = 4 * 1024 * 1024

    let maxCount: Int
    let maxBytes: Int
    private var screens: [UUID: TerminalScreenSnapshot] = [:]
    /// Least recently used first.
    private var order: [UUID] = []

    init(maxCount: Int = Self.maxCount, maxBytes: Int = Self.maxBytes) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    var count: Int { screens.count }
    var totalBytes: Int { screens.values.reduce(0) { $0 + $1.approximateBytes } }
    var sessionIDs: [UUID] { order }

    /// Keeps `snapshot` as the newest use of `id`, then lets the least recently used go until both caps hold.
    mutating func put(_ snapshot: TerminalScreenSnapshot, for id: UUID) {
        screens[id] = snapshot
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > 1, screens.count > maxCount || totalBytes > maxBytes {
            screens[order.removeFirst()] = nil
        }
    }

    /// The screen of `id`, counted as a use.
    mutating func use(_ id: UUID) -> TerminalScreenSnapshot? {
        guard let snapshot = screens[id] else { return nil }
        if order.last != id {
            order.removeAll { $0 == id }
            order.append(id)
        }
        return snapshot
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard screens.removeValue(forKey: id) != nil else { return false }
        order.removeAll { $0 == id }
        return true
    }

    mutating func removeAll() {
        screens.removeAll()
        order.removeAll()
    }
}
