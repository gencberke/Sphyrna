import CoreGraphics
import Foundation
import Testing
@testable import LoomCatalogUI

/// A1 (FEEDBACK-7 FB7-3): the project list's live reorder. The pointer against the blocks' mid-lines picks the gap, the
/// blocks between the dragged head's place and that gap slide by the dragged block's height, the list scrolls itself near
/// its edges, and a cancelled, unchanged or second release commits nothing.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ProjectReorderTests {
    /// Three blocks: an expanded project (100), a collapsed one (40) and an expanded one (300), top to bottom.
    private func threeBlocks(_ ids: [UUID]) -> [ProjectReorderBlock] {
        [ProjectReorderBlock(id: ids[0], minY: 0, height: 100, headTop: 2),
         ProjectReorderBlock(id: ids[1], minY: 100, height: 40, headTop: 110),
         ProjectReorderBlock(id: ids[2], minY: 140, height: 300, headTop: 150)]
    }

    private func model(_ ids: [UUID]) -> ProjectReorderModel {
        let reorder = ProjectReorderModel()
        reorder.viewportSize = CGSize(width: 260, height: 600)
        for block in threeBlocks(ids) {
            reorder.measure(block.id, frame: CGRect(x: block.minX, y: block.minY, width: block.width,
                                                    height: block.height), topGap: block.headTop - block.minY)
        }
        return reorder
    }

    @Test func thePointerAboveTheFirstBetweenTwoAndBelowTheLastPicksTheGap() {
        let blocks = threeBlocks([UUID(), UUID(), UUID()])
        #expect(ProjectReorder.gap(pointerY: -20, blocks: blocks) == 0, "above the first head")
        #expect(ProjectReorder.gap(pointerY: 49, blocks: blocks) == 0, "above the first block's mid-line (50)")
        #expect(ProjectReorder.gap(pointerY: 51, blocks: blocks) == 1, "under it")
        #expect(ProjectReorder.gap(pointerY: 119, blocks: blocks) == 1, "above the collapsed block's mid-line (120)")
        #expect(ProjectReorder.gap(pointerY: 121, blocks: blocks) == 2)
        #expect(ProjectReorder.gap(pointerY: 289, blocks: blocks) == 2, "above the last block's mid-line (290)")
        #expect(ProjectReorder.gap(pointerY: 291, blocks: blocks) == 3)
        #expect(ProjectReorder.gap(pointerY: 10_000, blocks: blocks) == 3, "below the last head")
        #expect(ProjectReorder.gap(pointerY: 120, blocks: []) == 0, "an empty list has one gap")
    }

    @Test func theProjectsOwnPlaceIsBeforeOrAfterItselfAndAReleaseThereMovesNothing() {
        #expect(ProjectReorder.position(forGap: 0, from: 0) == nil)
        #expect(ProjectReorder.position(forGap: 1, from: 0) == nil)
        #expect(ProjectReorder.position(forGap: 1, from: 1) == nil)
        #expect(ProjectReorder.position(forGap: 2, from: 1) == nil)
        #expect(ProjectReorder.position(forGap: 2, from: 2) == nil)
        #expect(ProjectReorder.position(forGap: 3, from: 2) == nil)
        // Anywhere else: a project that moves down leaves its own place first.
        #expect(ProjectReorder.position(forGap: 2, from: 0) == 1)
        #expect(ProjectReorder.position(forGap: 3, from: 0) == 2)
        #expect(ProjectReorder.position(forGap: 0, from: 1) == 0)
        #expect(ProjectReorder.position(forGap: 3, from: 1) == 2)
        #expect(ProjectReorder.position(forGap: 0, from: 2) == 0)
        #expect(ProjectReorder.position(forGap: 1, from: 2) == 1)
    }

    @Test func theBlocksBetweenThePlaceAndTheGapSlideByTheDraggedBlocksHeight() {
        // The first block (100 high) down to gap 3: the two under it slide up 100.
        #expect(ProjectReorder.offsetY(blockAt: 0, dragging: 0, gap: 3, draggedHeight: 100) == 0)
        #expect(ProjectReorder.offsetY(blockAt: 1, dragging: 0, gap: 3, draggedHeight: 100) == -100)
        #expect(ProjectReorder.offsetY(blockAt: 2, dragging: 0, gap: 3, draggedHeight: 100) == -100)
        // The last block (300 high) up to gap 0: the two above it slide down 300.
        #expect(ProjectReorder.offsetY(blockAt: 0, dragging: 2, gap: 0, draggedHeight: 300) == 300)
        #expect(ProjectReorder.offsetY(blockAt: 1, dragging: 2, gap: 0, draggedHeight: 300) == 300)
        #expect(ProjectReorder.offsetY(blockAt: 2, dragging: 2, gap: 0, draggedHeight: 300) == 0)
        // Its own place, before or after itself, moves nothing.
        #expect(ProjectReorder.offsetY(blockAt: 0, dragging: 1, gap: 1, draggedHeight: 40) == 0)
        #expect(ProjectReorder.offsetY(blockAt: 2, dragging: 1, gap: 1, draggedHeight: 40) == 0)
        #expect(ProjectReorder.offsetY(blockAt: 0, dragging: 1, gap: 2, draggedHeight: 40) == 0)
        #expect(ProjectReorder.offsetY(blockAt: 2, dragging: 1, gap: 2, draggedHeight: 40) == 0)
        // Nothing dragged: nothing slides.
        #expect(ProjectReorder.offsetY(blockAt: 0, dragging: nil, gap: nil, draggedHeight: 0) == 0)
        #expect(ProjectReorder.offsetY(blockAt: 1, dragging: 0, gap: nil, draggedHeight: 100) == 0)
    }

    @Test func aCollapsedBlockSlidesByItsOwnHeightAndAnExpandedOneByItsWholeBlock() {
        // The same gap, two dragged blocks: the slide is exactly the height of the one that is dragged, so a collapsed
        // project (40) moves the others less than an expanded one (300).
        #expect(ProjectReorder.offsetY(blockAt: 2, dragging: 0, gap: 3, draggedHeight: 100) == -100)
        #expect(ProjectReorder.offsetY(blockAt: 2, dragging: 1, gap: 3, draggedHeight: 40) == -40)
        #expect(ProjectReorder.offsetY(blockAt: 0, dragging: 2, gap: 0, draggedHeight: 300) == 300)
        let blocks = threeBlocks([UUID(), UUID(), UUID()])
        #expect(ProjectReorder.gap(pointerY: 130, blocks: blocks) == 2,
                "the collapsed block is only 40 high, so its mid-line sits at 120, not half of an expanded block")
        #expect(ProjectReorder.gap(pointerY: 250, blocks: blocks) == 2,
                "the expanded block below is 300 high")
    }

    @Test func theListScrollsItselfOnlyNearTheViewportsEdges() {
        #expect(ProjectReorder.edgeScroll(pointerY: 4, viewportHeight: 600) == -ProjectReorder.edgeStep)
        #expect(ProjectReorder.edgeScroll(pointerY: 100, viewportHeight: 600) == 0)
        #expect(ProjectReorder.edgeScroll(pointerY: 596, viewportHeight: 600) == ProjectReorder.edgeStep)
        #expect(ProjectReorder.edgeScroll(pointerY: 10, viewportHeight: 40) == 0, "a viewport too short for a zone")
    }

    @Test func aDragOverAnotherBlocksMidLineOpensTheGapThereAndReleasesOnce() {
        let ids = [UUID(), UUID(), UUID()]
        let reorder = model(ids)
        reorder.begin(ids[0], pointer: CGPoint(x: 40, y: 10), index: 0)
        #expect(reorder.dragging == ids[0])
        #expect(reorder.gap == 0, "its own place")
        #expect(reorder.offsetY(blockAt: 1) == 0)
        #expect(reorder.liftedFrame?.minY == 2, "the head starts where its block's head stood")
        reorder.move(pointer: CGPoint(x: 40, y: 130))
        #expect(reorder.gap == 2)
        #expect(reorder.offsetY(blockAt: 1) == -100, "the block it passes slides up")
        #expect(reorder.liftedFrame.map { $0.minY - 130 } == -8, "the head keeps the distance it was grabbed by")
        var releases: [(UUID, Int?)] = []
        reorder.end { releases.append(($0, $1)) }
        #expect(releases.count == 1)
        #expect(releases.first?.0 == ids[0] && releases.first?.1 == 2)
        reorder.end { releases.append(($0, $1)) }
        #expect(releases.count == 1, "one release for one drag")
        #expect(reorder.dragging == nil && reorder.gap == nil)
    }

    @Test func aCancelledDragReleasesNothing() {
        let ids = [UUID(), UUID(), UUID()]
        let reorder = model(ids)
        reorder.begin(ids[1], pointer: CGPoint(x: 40, y: 110), index: 1)
        reorder.move(pointer: CGPoint(x: 40, y: 500))
        #expect(reorder.gap == 3)
        reorder.cancel()
        var releases = 0
        reorder.end { _, _ in releases += 1 }
        #expect(releases == 0, "Escape or a lost key window leaves the order as it was")
        #expect(reorder.dragging == nil && reorder.gap == nil && reorder.offsetY(blockAt: 2) == 0)
    }

    @Test func aReleaseOutsideTheListCancels() {
        let ids = [UUID(), UUID(), UUID()]
        let reorder = model(ids)
        reorder.begin(ids[0], pointer: CGPoint(x: 40, y: 10), index: 0)
        reorder.move(pointer: CGPoint(x: 40, y: 700))
        var releases: [(UUID, Int?)] = []
        reorder.end { releases.append(($0, $1)) }
        #expect(releases.count == 1)
        #expect(releases.first?.1 == nil, "outside the list: cancelled")
        #expect(reorder.offsetY(blockAt: 1) == 0)
    }

    @Test func aReleaseOverItsOwnPlaceIsReleasedAsItsOwnGapAndMovesNothing() {
        let ids = [UUID(), UUID(), UUID()]
        let reorder = model(ids)
        reorder.begin(ids[1], pointer: CGPoint(x: 40, y: 110), index: 1)
        #expect(reorder.gap == 1)
        var released: Int??
        reorder.end { released = $1 }
        #expect((released ?? nil) == 1, "the release carries the gap; the model settles that it is its own place")
    }
}
