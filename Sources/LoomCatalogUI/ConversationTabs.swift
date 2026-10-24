import Foundation
import Observation

/// Result of asking to pin a conversation as a tab.
public enum TabPinResult: Equatable, Sendable {
    /// Newly pinned; `evicted` is the oldest idle tab that made room, if any.
    case pinned(evicted: UUID?)
    case alreadyPinned
    case refused(String)
}

/// The pinned conversation tabs (D-33): an ordered, capped list of ids. The
/// strip shows these plus the selected conversation as one transient tab.
/// Pure presentation state: it never starts, stops or owns a run, and closing
/// a tab only unpins it.
@MainActor @Observable
public final class ConversationTabs {
    public static let capacity = UIPreferences.maxOpenTabs

    public private(set) var pinned: [UUID]

    public init(pinned: [UUID] = []) {
        self.pinned = UIPreferences.normalizedTabs(pinned)
    }

    public func isPinned(_ id: UUID) -> Bool { pinned.contains(id) }

    /// Pinned tabs in order, then the selected conversation when it is not pinned.
    public func visible(selected: UUID?) -> [UUID] {
        guard let selected, !pinned.contains(selected) else { return pinned }
        return pinned + [selected]
    }

    /// Appends the conversation. When the strip is full the oldest pinned tab
    /// for which `canEvict` is true makes room; if none can, the pin is refused.
    public func pin(_ id: UUID, canEvict: (UUID) -> Bool) -> TabPinResult {
        if pinned.contains(id) { return .alreadyPinned }
        var evicted: UUID?
        if pinned.count >= Self.capacity {
            guard let victim = pinned.first(where: canEvict) else {
                return .refused(
                    "All \(Self.capacity) tabs are running or need you. Close one to open another."
                )
            }
            pinned.removeAll { $0 == victim }
            evicted = victim
        }
        pinned.append(id)
        return .pinned(evicted: evicted)
    }

    /// Pins the conversation at `index` of the pinned tabs (clamped), as a drop on the strip does. An already pinned
    /// conversation moves there instead; a full strip makes room as `pin(_:canEvict:)` does, or refuses.
    public func pin(_ id: UUID, at index: Int, canEvict: (UUID) -> Bool) -> TabPinResult {
        if pinned.contains(id) {
            move(id, to: index)
            return .alreadyPinned
        }
        let result = pin(id, canEvict: canEvict)
        if case .pinned = result { move(id, to: index) }
        return result
    }

    /// Moves a pinned tab so that it ends at `index` (clamped); returns whether the order changed.
    @discardableResult
    public func move(_ id: UUID, to index: Int) -> Bool {
        guard let from = pinned.firstIndex(of: id) else { return false }
        let to = min(max(index, 0), pinned.count - 1)
        guard to != from else { return false }
        pinned.remove(at: from)
        pinned.insert(id, at: to)
        return true
    }

    /// Where a tab dropped into the gap before visible tab `gap` ends among the pinned tabs: a tab that moves right
    /// leaves its own place first, and a gap after the last pinned tab (by the transient tab) is the end.
    public func position(forGap gap: Int, of id: UUID) -> Int {
        let gap = min(max(gap, 0), pinned.count)
        guard let from = pinned.firstIndex(of: id), gap > from else { return gap }
        return gap - 1
    }

    /// Removes the tab; returns whether it was pinned.
    @discardableResult
    public func unpin(_ id: UUID) -> Bool {
        guard let index = pinned.firstIndex(of: id) else { return false }
        pinned.remove(at: index)
        return true
    }

    /// What to show after closing `id`: the right neighbor, else the left, else
    /// nothing. Only meaningful when `id` is the selected tab.
    public func neighbor(ofClosing id: UUID, selected: UUID?) -> UUID? {
        let tabs = visible(selected: selected)
        guard let index = tabs.firstIndex(of: id) else { return nil }
        if tabs.indices.contains(index + 1) { return tabs[index + 1] }
        return index > 0 ? tabs[index - 1] : nil
    }

    /// A terminal moved to a new card (`/clear`, `/new`): a pinned old owner is
    /// replaced in place. Returns whether anything changed.
    @discardableResult
    public func replace(_ old: UUID, with new: UUID) -> Bool {
        guard old != new, let index = pinned.firstIndex(of: old) else { return false }
        if pinned.contains(new) {
            pinned.remove(at: index)
        } else {
            pinned[index] = new
        }
        return true
    }

    /// Drops a conversation that no longer exists.
    @discardableResult
    public func forget(_ id: UUID) -> Bool { unpin(id) }
}
