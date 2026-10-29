import CoreGraphics
import Testing
@testable import LoomCatalogUI

struct ChatScrollLatchTests {
    @Test func distanceIsMeasuredFromTheTrueContentBottom() {
        // 1000 high content with a 100 pt composer inset under it.
        #expect(ChatScrollLatch.distanceFromBottom(contentHeight: 1000, visibleMaxY: 1100, bottomInset: 100) == 0)
        #expect(ChatScrollLatch.distanceFromBottom(contentHeight: 1000, visibleMaxY: 1000, bottomInset: 100) == 100)
        #expect(ChatScrollLatch.distanceFromBottom(contentHeight: 1000, visibleMaxY: 1060, bottomInset: 0) == -60)
    }

    @Test func scrollingUpLeavesFollowingOnlyWhenTheContentOverflows() {
        var latch = ChatScrollLatch()
        #expect(latch.isFollowing)
        let noOverflow = latch.userScrolled(.up, distanceFromBottom: 0, overflows: false)
        #expect(!noOverflow)
        #expect(latch.isFollowing)
        let left = latch.userScrolled(.up, distanceFromBottom: 200, overflows: true)
        #expect(left)
        #expect(!latch.isFollowing)
    }

    @Test func comingBackWithinFortyPointsFollowsAgain() {
        var latch = ChatScrollLatch()
        latch.userScrolled(.up, distanceFromBottom: 300, overflows: true)
        let near = latch.userScrolled(.down, distanceFromBottom: 41, overflows: true)
        #expect(!near)
        #expect(!latch.isFollowing)
        let back = latch.userScrolled(.down, distanceFromBottom: 40, overflows: true)
        #expect(back)
        #expect(latch.isFollowing)
    }

    @Test func keysAndTheScrollerLeaveFollowing() {
        for key in [ChatScrollLatch.Key.up, .pageUp, .home] {
            var latch = ChatScrollLatch()
            let changed = latch.key(key, overflows: true)
            #expect(changed)
            #expect(!latch.isFollowing)
        }
        var latch = ChatScrollLatch()
        let flat = latch.key(.up, overflows: false)
        let down = latch.key(.pageDown, overflows: true)
        #expect(!flat && !down)
        #expect(latch.isFollowing)
        let dragged = latch.scrollerDragged(overflows: true)
        #expect(dragged)
        #expect(!latch.isFollowing)
        let again = latch.scrollerDragged(overflows: true)
        #expect(!again)
    }

    @Test func jumpShowsOnlyAwayFromTheEndWhileFree() {
        var latch = ChatScrollLatch()
        #expect(!latch.showsJump(distanceFromBottom: 500))
        latch.leaveFollowing()
        #expect(latch.showsJump(distanceFromBottom: 500))
        #expect(!latch.showsJump(distanceFromBottom: 10))
        latch.followAgain()
        #expect(!latch.showsJump(distanceFromBottom: 500))
    }
}
