import Foundation

/// One project's block as the live reorder reads it (A1): the head, its drafts, its cards and its note, in the project
/// list's content coordinates. A block's top is the list's gap above its head; `headTop` is the head row's own top.
struct ProjectReorderBlock: Equatable, Sendable {
    let id: UUID
    let minX: CGFloat
    let minY: CGFloat
    let width: CGFloat
    let height: CGFloat
    let headTop: CGFloat

    init(id: UUID, minX: CGFloat = 0, minY: CGFloat, width: CGFloat = 260, height: CGFloat, headTop: CGFloat? = nil) {
        self.id = id
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
        self.headTop = headTop ?? minY
    }

    /// The middle of the block: the line the pointer crosses to move the gap under the next block or the previous one.
    var midY: CGFloat { minY + height / 2 }
}

/// The project view's live reorder (A1, FEEDBACK-7 FB7-3). The pointer against the blocks' mid-lines picks the gap the
/// dragged project lands in, and every block between its place and that gap slides by the dragged block's height. The
/// numbers are plain functions, so the gap, the slide and the outcome are tested without a window; `ProjectReorderModel`
/// carries them through a drag the user makes.
enum ProjectReorder {
    /// How far the pointer moves before the head becomes a drag, so a click still opens the project page and a right click
    /// still opens the menu.
    static let startDistance: CGFloat = 4
    /// How close to the list's top or bottom edge the pointer scrolls it.
    static let edgeZone: CGFloat = 28
    /// How far one tick of that scroll moves the list.
    static let edgeStep: CGFloat = 8
    /// The beat between two ticks of that scroll.
    static let edgeInterval: Duration = .milliseconds(40)

    /// The first 8 digits of an id, lower case: what a log line carries, never a name or a path.
    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    /// The gap the pointer is over in a list of `blocks` (given in content order): 0 is above the first head and `count`
    /// below the last. The number of blocks whose middle stands above the pointer; the dragged block counts too, so the
    /// places before and after it are gaps like any other.
    static func gap(pointerY: CGFloat, blocks: [ProjectReorderBlock]) -> Int {
        blocks.reduce(0) { count, block in count + (block.midY < pointerY ? 1 : 0) }
    }

    /// The place project `from` takes when it is released in `gap`, or nil when that gap is the place it already has
    /// (before or after itself): a release there changes nothing. A project that moves down leaves its own place first.
    static func position(forGap gap: Int, from: Int) -> Int? {
        guard gap != from, gap != from + 1 else { return nil }
        return gap > from ? gap - 1 : gap
    }

    /// The vertical offset the block at `index` takes while project `from` hovers at `gap`: the blocks between the two
    /// places slide by the dragged block's height, and everything else stands still.
    static func offsetY(blockAt index: Int, dragging from: Int?, gap: Int?, draggedHeight: CGFloat) -> CGFloat {
        guard let from, let gap, draggedHeight > 0 else { return 0 }
        if from < gap { return index > from && index < gap ? -draggedHeight : 0 }
        if gap < from { return index >= gap && index < from ? draggedHeight : 0 }
        return 0
    }

    /// The points one tick of the edge scroll moves the list: negative near the top edge, positive near the bottom, and
    /// none in the middle or in a viewport too short for a zone at each end.
    static func edgeScroll(pointerY: CGFloat, viewportHeight: CGFloat,
                           zone: CGFloat = edgeZone, step: CGFloat = edgeStep) -> CGFloat {
        guard zone > 0, viewportHeight > 2 * zone else { return 0 }
        if pointerY < zone { return -step }
        if pointerY > viewportHeight - zone { return step }
        return 0
    }
}
