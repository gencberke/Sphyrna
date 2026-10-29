import AppKit
import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// FB6-5: one value says which session is dragged and which targets take it, so every target shows one of the three looks
/// and a drag that ends without a drop leaves nothing behind. Projects are not in it any more: their reorder is live and
/// keeps its own state (A1).
///
/// Each test has its own activity and its own mouse: never the process's `shared` one, and never the real buttons, which the
/// person at the Mac can press at any moment (the 29 Oct gate failed so).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DragActivityTests {
    /// The buttons as the watch sees them. It notes when it was asked.
    @MainActor final class Mouse {
        var held: Bool
        private(set) var asked: [ContinuousClock.Instant] = []
        init(held: Bool) { self.held = held }
        func buttonsDown() -> Bool {
            asked.append(.now)
            return held
        }
    }

    /// A button that stays down unless the test lets go, so the watch never ends a drag on its own.
    private func fresh(_ mouse: Mouse = Mouse(held: true)) -> DragActivity {
        DragActivity(buttonsDown: mouse.buttonsDown)
    }

    /// Waits, bounded, for `condition`; the main actor stays free between checks.
    private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func aDragIsActiveUntilADropOrTheEndOfTheDrag() {
        let activity = fresh()
        let id = UUID()
        activity.begin(id)
        #expect(activity.active == id)
        activity.end(why: "test")
        #expect(activity.active == nil)
    }

    @Test func theSourceIsDimmedOnlyWhileNothingUnderThePointerTakesTheDrag() {
        let activity = fresh()
        let id = UUID(), other = UUID()
        #expect(!activity.refuses(id), "no drag, no dimming")
        activity.begin(id)
        #expect(activity.refuses(id) && !activity.refuses(other))
        activity.enter(DragActivity.tabs)
        #expect(!activity.refuses(id), "over a target that takes it")
        activity.leave(DragActivity.tabs)
        #expect(activity.refuses(id))
        activity.end(why: "test")
        #expect(!activity.refuses(id))
    }

    @Test func twoTargetsAreToldApartWhenThePointerMovesFromOneToTheNext() {
        let activity = fresh()
        let a = DragActivity.composerChips, b = DragActivity.terminal
        activity.begin(UUID())
        activity.enter(a)
        activity.enter(b)
        activity.leave(a)
        #expect(activity.over == [b], "the second one's enter before the first one's exit leaves it standing")
        activity.end(why: "test")
        #expect(activity.over.isEmpty)
    }

    /// SwiftUI says nothing when a drag is cancelled: the watch calls it over once the button is up, never inside the settling
    /// beat (`Task.sleep` does not return early, so the lower bound holds under any load).
    @Test func aDragWhoseButtonIsUpEndsByItselfAfterTheSettlingBeat() async throws {
        let mouse = Mouse(held: false)
        let activity = fresh(mouse)
        let began = ContinuousClock.now
        activity.begin(UUID())
        #expect(activity.active != nil)
        #expect(await eventually { activity.active == nil },
                "a cancelled drag leaves nothing behind: still \(String(describing: activity.active))")
        let firstLook = try #require(mouse.asked.first) - began
        #expect(firstLook >= DragActivity.settle, "the button was read \(firstLook) after the drag began")
    }

    @Test func aHeldButtonKeepsTheDragUntilItComesUp() async {
        let mouse = Mouse(held: true)
        let activity = fresh(mouse)
        let id = UUID()
        activity.begin(id)
        #expect(await eventually { mouse.asked.count >= 2 }, "the watch read the button \(mouse.asked.count) times")
        #expect(activity.active == id, "a drag whose button is still down is not over")
        mouse.held = false
        #expect(await eventually { activity.active == nil }, "the drag ends once the button is up")
    }
}
