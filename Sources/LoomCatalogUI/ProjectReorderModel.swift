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

    /// The blocks by project, in content coordinates and with no slide applied: each from its head's top to the lowest part
    /// the list has measured.
    private(set) var blocks: [UUID: ProjectReorderBlock] = [:]
    /// The frames of each project's parts, and the gap above each head (A1). They feed `blocks` and are not observed: a part
    /// that is measured or forgotten redraws nothing but the gap it changes.
    @ObservationIgnored private var parts: [UUID: [ProjectReorderPart: CGRect]] = [:]
    @ObservationIgnored private var headTopGaps: [UUID: CGFloat] = [:]

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
    /// The project whose released move has not landed yet (A1): the list still shows the order the drag began with, so its
    /// slides and its hidden head hold until `hasLanded`, and `settle` ends them.
    private(set) var landingID: UUID?

    // MARK: The list

    /// The list viewport's size, and how far its content is scrolled: together they map the pointer onto the blocks.
    var viewportSize: CGSize = .zero
    var contentOffset: CGFloat = 0
    /// The list's scroll view, found from inside its content, so the drag can scroll the list near its edges.
    @ObservationIgnored weak var scrollView: NSScrollView?
    @ObservationIgnored private var escapeMonitor: Any?

    // MARK: Measuring

    /// A project's head reported its frame, in the content's coordinates and before its slide; `topGap` is the list's gap
    /// above the head. The head is where a block starts. The layout is kept while a drag runs (a known part is not updated,
    /// a new one is added), so a slide never feeds back into the geometry the drag reads.
    func measure(_ id: UUID, frame: CGRect, topGap: CGFloat) {
        guard frame.height > 0, frame.width > 0 else { return }
        if dragging != nil, parts[id]?[.head] != nil { return }
        parts[id, default: [:]][.head] = frame
        headTopGaps[id] = topGap
        refreshBlock(id)
    }

    /// Another part of a project (a draft, a card or the note) reported its frame; a part with no height is not in the list.
    func measurePart(_ id: UUID, _ part: ProjectReorderPart, frame: CGRect) {
        guard frame.height > 0, frame.width > 0 else {
            forgetPart(id, part)
            return
        }
        if dragging != nil, parts[id]?[part] != nil { return }
        parts[id, default: [:]][part] = frame
        refreshBlock(id)
    }

    /// A part left the list: scrolled past the built rows, collapsed or deleted. Nothing is forgotten while a drag runs, so
    /// the block the drag started with keeps its extent.
    func forgetPart(_ id: UUID, _ part: ProjectReorderPart) {
        guard dragging == nil, parts[id]?[part] != nil else { return }
        parts[id]?[part] = nil
        refreshBlock(id)
    }

    /// Drops the blocks of projects that left the list (removed, or the list changed views).
    func forget(notIn ids: Set<UUID>) {
        let gone = parts.keys.filter { !ids.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone {
            parts.removeValue(forKey: id)
            headTopGaps.removeValue(forKey: id)
            blocks.removeValue(forKey: id)
        }
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
        // A new drag ends the slides of a move that has not landed yet.
        if landingID != nil { reset() }
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
    /// called once for a drag and not at all for an end that follows one, so a release moves a project once. A release that
    /// moves the project keeps its slides and its hidden head until the new order lands (`hasLanded`) and `settle` ends them,
    /// so the blocks take the new order in one step instead of sliding back to the old one and jumping.
    func end(commit: (UUID, Int?) -> Void) {
        guard let id = dragging else { return }
        let inside = CGRect(origin: .zero, size: viewportSize).contains(pointer)
        let released = inside ? gap : nil
        if let released, let from, ProjectReorder.position(forGap: released, from: from) != nil {
            landingID = id
            dragging = nil
            stopEscapeWatch()
        } else {
            reset()
        }
        commit(id, released)
    }

    /// Escape, or the window losing key status: the drag is over and the order stays as it was.
    func cancel() {
        guard let id = dragging else { return }
        LoomLog.notice(.sidebar, "projectReorder end \(ProjectReorder.shortID(id)) cancelled")
        reset()
    }

    /// Whether a project's block stays out of its place: it is the one dragged (its head follows the pointer), or the one
    /// released and not landed yet (its place is the gap the slides hold open).
    func isMoving(_ id: UUID, order current: [UUID]) -> Bool {
        dragging == id || (landingID == id && !hasLanded(current))
    }

    /// Whether the released move has landed: the list's order is no longer the order the drag began with. Until then the
    /// slides hold; from then on the blocks show the new order without them.
    func hasLanded(_ current: [UUID]) -> Bool { landingID != nil && current != order }

    /// The released move has ended, whether its order landed or the catalog refused it. Only the move that started the
    /// landing is ended, so a settle that comes late for an earlier move changes nothing.
    func settle(_ id: UUID) {
        guard landingID == id else { return }
        reset()
    }

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

    /// A project's block: from its head's top to the lowest of its measured parts. A project without its head measured has none.
    private func refreshBlock(_ id: UUID) {
        guard let measured = parts[id], let head = measured[.head] else {
            if blocks.removeValue(forKey: id) != nil { refreshGap() }
            return
        }
        let bottom = measured.values.map(\.maxY).max() ?? head.maxY
        let block = ProjectReorderBlock(id: id, minX: head.minX, minY: head.minY, width: head.width,
                                        height: bottom - head.minY, headTop: head.minY + (headTopGaps[id] ?? 0))
        guard blocks[id] != block else { return }
        blocks[id] = block
        refreshGap()
    }

    private func refreshGap() {
        guard dragging != nil else { return }
        let next = ProjectReorder.gap(pointerY: pointer.y + contentOffset, blocks: orderedBlocks, order: order)
        guard next != gap else { return }
        gap = next
        if let dragging { LoomLog.notice(.sidebar, "projectReorder gap \(ProjectReorder.shortID(dragging)) \(next)") }
    }

    private func reset() {
        stopEscapeWatch()
        dragging = nil
        landingID = nil
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
