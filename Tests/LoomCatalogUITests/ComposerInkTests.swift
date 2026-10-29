import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// The composer in Ink (I6m, DESIGN §11, D-75): the one model chip and its popover (the groups, the dimmed rows, the keys),
// what Send says, the keys line, the `@` menu's heads and the sizes the reference gives. No window and no process; the
// popover is hosted offscreen and never ordered front.

struct ComposerInkTests {
    // MARK: The keys

    @Test func upAndDownMoveBetweenTheModelsAndWrap() {
        #expect(ComposerPopoverKeys.cursor(from: 0, delta: 1, count: 4) == 1)
        #expect(ComposerPopoverKeys.cursor(from: 3, delta: 1, count: 4) == 0, "down from the last row wraps to the first")
        #expect(ComposerPopoverKeys.cursor(from: 0, delta: -1, count: 4) == 3, "up from the first row wraps to the last")
        #expect(ComposerPopoverKeys.cursor(from: nil, delta: 1, count: 4) == 0 && ComposerPopoverKeys.cursor(from: nil, delta: -1, count: 4) == 3)
        #expect(ComposerPopoverKeys.cursor(from: 0, delta: 1, count: 0) == nil)
    }

    // MARK: The keys line and the menus

    @Test func aHintIsItsKeyThenItsWords() {
        #expect(ComposerHints.split("\u{21B5} send now") == ("\u{21B5}", "send now"))
        #expect(ComposerHints.split("esc interrupt") == ("esc", "interrupt"))
        #expect(ComposerHints.split("@ files and sessions") == ("@", "files and sessions"))
        #expect(ComposerHints.split("tab") == ("tab", ""))
    }

    // MARK: Sizes

    @Test func theBarAndItsPopoversHaveTheReferencesSizes() {
        #expect(LoomTheme.Composer.barHeight == 38 && LoomTheme.Composer.controlSide == 28 && LoomTheme.Composer.sendSide == 30)
        #expect(LoomTheme.Composer.modelPopoverWidth == 332 && LoomTheme.Composer.pickWidth == 312)
        #expect(LoomTheme.Composer.ringPopoverWidth == 268 && LoomTheme.Composer.plusPopoverWidth == 300)
        #expect(LoomTheme.Composer.modelRowHeight == 30 && LoomTheme.Composer.groupHeadHeight == 28)
        #expect(LoomTheme.Composer.radius == 18 && LoomTheme.Composer.chipRadius == 6)
        // The track, the thumb and the dots.
        #expect(LoomTheme.Composer.effortTrackThickness == 6 && LoomTheme.Composer.effortThumb == 14 && LoomTheme.Composer.effortDot == 4)
        // The thumb fits in the track's hit height, so a click on it never misses.
        #expect(LoomTheme.Composer.effortTrackHeight >= LoomTheme.Composer.effortThumb)
        #expect(LoomTheme.Layout.minimumHitTarget.height <= LoomTheme.Composer.effortTrackHeight)
    }

    /// Ink v4 (DESIGN §0.3): the composer is elevation 2, a hairline and a small drop; no ring, no inner highlight.
    @Test func theCardIsLiftedWithALevelTwoDropOnly() {
        #expect(LoomTheme.Composer.depth == LoomTheme.Elevation.lift)
        let dark = LoomTheme.Composer.depth[.dark]
        #expect(dark.ring == nil && dark.drops.first?.blur == 2 && dark.drops.first?.y == 1)
    }
}
