import AppKit
import LoomCore
import SwiftUI

/// One drag of a project head in the sidebar's project view (A1, FEEDBACK-7 FB7-3): the blocks the list measured, where
/// the pointer is, the gap it picks and the slide each block takes. The list owns one for the length of its view and hands
/// it to every block and to the lifted head; the geometry itself is `ProjectReorder`'s plain functions.
@MainActor @Observable
final class ProjectReorderModel {
    /// The list content's coordinates, on the stack that holds the blocks: the blocks' frames are read in it.
    static let contentSpace = "loom.projectReorderContent"
    /// The list viewport's coordinates: the pointer and the lifted head sit in them, so the list scrolling under a held
    /// pointer moves the blocks and not the head.
    static let viewportSpace = "loom.projectReorderViewport"

    // MARK: The measured layout

    /// The blocks by project, in content coordinates and with no slide applied.
    private(set) var blocks: [UUID: ProjectReorderBlock] = [:]

    /// The blocks in list order: the one the pointer's gap is counted against.
    var orderedBlocks: [ProjectReorderBlock] { blocks.values.sorted { $0.minY < $1.minY } }

    // MARK: The drag

    /// The project whose head is being dragged, its place and the height the other blocks slide by.
    private(set) var dragging: UUID?
    private(set) var from: Int?
    private(set) var draggedHeight: CGFloat = 0
    /// The list's project order at the start of the drag: the measured window's places are read off it, so a lazy list
    /// that measured only part of itself still lands where the full list says.
    @ObservationIgnored private var order: [UUID] = []
    /// The gap the pointer picks, and where the pointer is in the viewport.
    private(set) var gap: Int?
    private(set) var pointer: CGPoint = .zero
    /// How far below the dragged head's top the pointer holds it, so the lifted head keeps that distance all the way.
    private(set) var grab: CGFloat = 0

    // MARK: The list

    /// The list viewport's size, and how far its content is scrolled: together they map the pointer onto the blocks.
    var viewportSize: CGSize = .zero
    var contentOffset: CGFloat = 0
    /// The list's scroll view, found from inside its content, so the drag can scroll the list near its edges.
    @ObservationIgnored weak var scrollView: NSScrollView?
    @ObservationIgnored private var escapeMonitor: Any?

    // MARK: Measuring

    /// A block reported its frame, in the content's coordinates and before its slide; `topGap` is the list's gap above its
    /// head. The layout is kept while a drag runs, so a slide never feeds back into the geometry the drag reads; a block
    /// the list loads then (while it scrolls itself) is added.
    func measure(_ id: UUID, frame: CGRect, topGap: CGFloat) {
        guard frame.height > 0, frame.width > 0 else { return }
        let block = ProjectReorderBlock(id: id, minX: frame.minX, minY: frame.minY, width: frame.width,
                                        height: frame.height, headTop: frame.minY + topGap)
        guard blocks[id] != block else { return }
        if dragging != nil, blocks[id] != nil { return }
        blocks[id] = block
        refreshGap()
    }

    /// Drops the blocks of projects that left the list (removed, or the list changed views).
    func forget(notIn ids: Set<UUID>) {
        let gone = blocks.keys.filter { !ids.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone { blocks.removeValue(forKey: id) }
        refreshGap()
    }

    func setContentOffset(_ y: CGFloat) {
        guard y != contentOffset else { return }
        contentOffset = y
        refreshGap()
    }

    func attach(_ scrollView: NSScrollView?) { self.scrollView = scrollView }

    // MARK: The drag

    /// The head under the pointer becomes the drag. It starts after `ProjectReorder.startDistance`, so the click that opens
    /// the project page never starts one; `pointer` is in the viewport's coordinates, and `order` is the list's projects.
    @discardableResult
    func begin(_ id: UUID, pointer: CGPoint, order: [UUID]) -> Bool {
        guard dragging == nil, let block = blocks[id], let index = order.firstIndex(of: id) else { return false }
        dragging = id
        from = index
        self.order = order
        draggedHeight = block.height
        self.pointer = pointer
        grab = pointer.y + contentOffset - block.headTop
        gap = nil
        refreshGap()
        LoomLog.notice(.sidebar, "projectReorder start \(ProjectReorder.shortID(id)) place \(index)")
        watchEscape()
        return true
    }

    /// The pointer moved: the gap follows it.
    func move(pointer: CGPoint) {
        guard dragging != nil else { return }
        self.pointer = pointer
        refreshGap()
    }

    /// Ends the drag: the project and the gap it is released in, or nil when the pointer is outside the list. `commit` is
    /// called once for a drag and not at all for an end that follows one, so a release moves a project once.
    func end(commit: (UUID, Int?) -> Void) {
        guard let id = dragging else { return }
        let inside = CGRect(origin: .zero, size: viewportSize).contains(pointer)
        let released = inside ? gap : nil
        reset()
        commit(id, released)
    }

    /// Escape, or the window losing key status: the drag is over and the order stays as it was.
    func cancel() {
        guard let id = dragging else { return }
        LoomLog.notice(.sidebar, "projectReorder end \(ProjectReorder.shortID(id)) cancelled")
        reset()
    }

    /// Whether this project's block is the one being dragged: it goes quiet while its head follows the pointer.
    func isDragging(_ id: UUID) -> Bool { dragging == id }

    /// The slide of the block at `index` while another project's head is over its gap.
    func offsetY(blockAt index: Int) -> CGFloat {
        ProjectReorder.offsetY(blockAt: index, dragging: from, gap: gap, draggedHeight: draggedHeight)
    }

    /// The lifted head's frame in the viewport's coordinates: the pointer keeps the distance it grabbed the head by.
    var liftedFrame: CGRect? {
        guard let id = dragging, let block = blocks[id] else { return nil }
        return CGRect(x: block.minX, y: pointer.y - grab, width: block.width,
                      height: LoomTheme.InkHeight.sidebarRow)
    }

    // MARK: The list's own scroll

    /// The points the list scrolls itself this tick; 0 when the pointer stands away from both edges.
    var edgeStep: CGFloat {
        dragging == nil ? 0 : ProjectReorder.edgeScroll(pointerY: pointer.y, viewportHeight: viewportSize.height)
    }

    /// One tick of that scroll, clamped to the list's content.
    func scrollByEdgeStep() {
        guard edgeStep != 0, let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let furthest = max(0, document.frame.height - clip.bounds.height)
        let y = min(max(0, clip.bounds.origin.y + edgeStep), furthest)
        guard y != clip.bounds.origin.y else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Private

    private func refreshGap() {
        guard dragging != nil else {
            if gap != nil { gap = nil }
            return
        }
        let next = ProjectReorder.gap(pointerY: pointer.y + contentOffset, blocks: orderedBlocks, order: order)
        guard next != gap else { return }
        gap = next
        if let dragging { LoomLog.notice(.sidebar, "projectReorder gap \(ProjectReorder.shortID(dragging)) \(next)") }
    }

    private func reset() {
        stopEscapeWatch()
        dragging = nil
        from = nil
        draggedHeight = 0
        order = []
        gap = nil
        grab = 0
        pointer = .zero
    }

    /// Escape cancels the drag the way a release outside the list does. The monitor is only up while a drag runs.
    private func watchEscape() {
        stopEscapeWatch()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
    }

    private func stopEscapeWatch() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
