import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// The inspector in a narrow pane and after a resize (Release A UI fix round, item 2). The threshold is pure; the
/// window tests host the real `DetailView` offscreen and watch what the terminal and the chat stream are given.
struct InspectorPlacementTests {
    @Test func theInspectorOverlaysBelowFourHundredEightyOfContentAndIsAColumnAbove() {
        let column = LoomTheme.Rhythm.inspectorWidth
        let threshold = column + LoomTheme.Inspector.minimumContent
        #expect(LoomTheme.Inspector.minimumContent == 480 && column == 328)
        #expect(InspectorPlacement.of(open: true, detailWidth: threshold - 1) == .overlay)
        #expect(InspectorPlacement.of(open: true, detailWidth: threshold) == .column)
        #expect(InspectorPlacement.of(open: true, detailWidth: 464) == .overlay, "the 780 pt window's pane")
        #expect(InspectorPlacement.of(open: true, detailWidth: 1_084) == .column)
        #expect(InspectorPlacement.of(open: false, detailWidth: 300) == .closed)
        // A column takes its width from the content; an overlay and a closed inspector take none.
        #expect(InspectorPlacement.column.contentWidth(detailWidth: 900) == 900 - column)
        #expect(InspectorPlacement.overlay.contentWidth(detailWidth: 700) == 700)
        #expect(InspectorPlacement.closed.contentWidth(detailWidth: 700) == 700)
    }
}
