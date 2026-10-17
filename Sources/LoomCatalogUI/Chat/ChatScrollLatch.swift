import CoreGraphics
import Foundation

/// The follow latch of the stream (CHAT-SPEC → Scrolling). Two states: Following keeps the newest content in sight; Free
/// leaves the view where the reader put it. The rules are T3 Code's latch with the fixes its scroll bugs taught
/// (MIT, Copyright 2026 T3 Tools Inc.; apps/web/src/components/chat/MessagesTimeline.tsx and the issues #4668, #5566):
/// the distance is measured from the true content bottom in Loom's own scroll view, never from a list library's
/// "near the end" flag, and a programmatic scroll never changes the state. No T3 code is copied.
///
/// Pure value logic, so the rules are unit-tested; the stream controller feeds it the events.
struct ChatScrollLatch: Equatable {
    enum State: Equatable { case following, free }

    /// Back to Following only within this distance of the true content bottom.
    static let followDistance: CGFloat = LoomTheme.Chat.followDistance

    private(set) var state = State.following

    var isFollowing: Bool { state == .following }

    /// The distance from the true bottom of the content: the document's height minus the bottom edge of what is visible,
    /// with the inset under the composer taken off. Zero when scrolled to the end.
    static func distanceFromBottom(contentHeight: CGFloat, visibleMaxY: CGFloat, bottomInset: CGFloat) -> CGFloat {
        contentHeight - (visibleMaxY - bottomInset)
    }

    enum Direction { case up, down }

    /// The reader moved the view with the wheel, the trackpad or the scroller. Scrolling up while the content overflows
    /// leaves Following; a move that ends within 40 pt of the end returns to it. Returns whether the state changed.
    @discardableResult
    mutating func userScrolled(_ direction: Direction, distanceFromBottom distance: CGFloat, overflows: Bool) -> Bool {
        let before = state
        if direction == .up, overflows { state = .free }
        if distance <= Self.followDistance { state = .following }
        return state != before
    }

    enum Key: Equatable { case up, pageUp, home, down, pageDown, end }

    /// Page Up, Home and ↑ leave Following when the content overflows; Page Down, End and ↓ matter only away from the end
    /// (they can bring the reader back to it). Call `userScrolled` afterwards with the new distance.
    @discardableResult
    mutating func key(_ key: Key, overflows: Bool) -> Bool {
        switch key {
        case .up, .pageUp, .home:
            guard overflows, state != .free else { return false }
            state = .free
            return true
        case .down, .pageDown, .end:
            return false
        }
    }

    /// Dragging the scroller leaves Following at once (when the content overflows).
    @discardableResult
    mutating func scrollerDragged(overflows: Bool) -> Bool {
        guard overflows, state != .free else { return false }
        state = .free
        return true
    }

    /// The reader scrolled back to the end, or the content stopped overflowing.
    mutating func followAgain() { state = .following }

    /// The view opens away from the end (the remembered place).
    mutating func leaveFollowing() { state = .free }

    /// Whether "Jump to latest" should show: away from the end and not following.
    func showsJump(distanceFromBottom distance: CGFloat) -> Bool {
        state == .free && distance > Self.followDistance
    }
}
