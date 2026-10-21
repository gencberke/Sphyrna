import Foundation

/// A project's note: dated items, each citing its sessions, in `projects/<project id>.md` (one `RemoraDatedItem` line per
/// item, oldest first), at most 2 KiB. It is rewritten, never appended to.
public struct RemoraProjectNote: Equatable, Sendable {
    public enum Limits {
        public static let bytes = 2 * 1024
        public static let itemCharacters = 300
    }

    public struct Item: Equatable, Sendable {
        /// `YYYY-MM-DD`: when the item was written.
        public var date: String
        public var text: String
        public var sessions: [UUID]
    }

    var items: [RemoraDatedItem]

    /// The items as they read.
    public var readableItems: [Item] { items.map { Item(date: $0.day.string, text: $0.text, sessions: $0.sessions) } }

    /// The note's file text.
    public var text: String { items.isEmpty ? "" : items.map(\.line).joined(separator: "\n") + "\n" }

    var sessionIDs: [UUID] {
        var seen = Set<UUID>()
        return items.flatMap(\.sessions).filter { seen.insert($0).inserted }
    }

    /// The newest day an item carries: how recently the project moved, as far as the note knows.
    var newestDay: RemoraDay? { items.map(\.day).max() }

    init(items: [RemoraDatedItem]) { self.items = items }

    init(text: String) { items = RemoraFiles.lines(of: text).compactMap(RemoraDatedItem.init(line:)) }

    /// Cuts the note to `Limits.bytes`: newest items first stay (same day: the earlier line first); an item that alone
    /// does not fit has its text cut. The items keep the order they had.
    static func fitted(_ items: [RemoraDatedItem], bytes: Int = Limits.bytes) -> Self {
        func size(_ item: RemoraDatedItem) -> Int { item.line.utf8.count + 1 }
        let priority = items.indices.sorted { items[$0].day != items[$1].day ? items[$0].day > items[$1].day : $0 < $1 }
        var kept = Set<Int>()
        var used = 0
        var cutFirst: (Int, RemoraDatedItem)?
        for index in priority {
            if used + size(items[index]) <= bytes {
                kept.insert(index)
                used += size(items[index])
            } else if kept.isEmpty {
                var item = items[index]
                let overhead = size(item) - item.text.utf8.count
                item.text = clip(item.text, toBytes: bytes - overhead)
                if size(item) <= bytes, item.text.count > 1 { cutFirst = (index, item); kept.insert(index) }
                break
            } else {
                break
            }
        }
        return Self(items: items.indices.filter(kept.contains).map { $0 == cutFirst?.0 ? cutFirst!.1 : items[$0] })
    }

    func forgetting(_ session: UUID) -> Self {
        Self(items: items.compactMap { $0.forgetting(session) })
    }
}
