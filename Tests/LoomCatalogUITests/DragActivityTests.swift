import AppKit
import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// FB6-5: one value says which session is dragged and which targets take it, so every target shows one of the three looks
/// and a drag that ends without a drop leaves nothing behind. Projects are not in it any more: their reorder is live and
/// keeps its own state (A1).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DragActivityTests {
    private func fresh() -> DragActivity {
        let activity = DragActivity.shared
        activity.end(why: "test")
        return activity
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

    @Test func aDragWhoseButtonIsUpEndsByItself() async throws {
        let activity = fresh()
        activity.begin(UUID())
        #expect(activity.active != nil)
        // No button is down under test: the watch calls the drag over after its settling beat.
        try await Task.sleep(for: .milliseconds(700))
        #expect(activity.active == nil, "a cancelled drag leaves nothing behind")
    }
}
