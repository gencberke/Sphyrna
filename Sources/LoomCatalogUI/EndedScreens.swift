import Foundation

/// When the last screen of a run that ended stays on show (D-45). The controller keeps the surfaces; these
/// are the rules, free of any view.
enum EndedScreenPolicy {
    /// At most this many ended surfaces are kept; each holds a terminal engine and its scrollback.
    static let limit = 8

    /// A kept screen belongs to a session the user can reach without looking for it: the selected one or
    /// a pinned tab. Any other session shows its record, as before.
    static func keeps(session: UUID, selected: UUID?, pinned: [UUID]) -> Bool {
        session == selected || pinned.contains(session)
    }

    /// The screens to let go of so that at most `limit` stay: the oldest first, never the selected one.
    /// `order` lists the kept sessions oldest first.
    static func evictions(order: [UUID], selected: UUID?, limit: Int = EndedScreenPolicy.limit) -> [UUID] {
        var excess = order.count - limit
        var evicted: [UUID] = []
        for id in order where excess > 0 && id != selected {
            evicted.append(id)
            excess -= 1
        }
        return evicted
    }
}
