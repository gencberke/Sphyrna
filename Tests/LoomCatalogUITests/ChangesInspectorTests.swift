import Foundation
import Testing
@testable import LoomCatalogUI

/// V20: the Changes tab in the inspector's frame (the wide column and the overlay rule, the tab bar) and the
/// diff bands' contrast. The tab's reads and comments are in `ChangesModelTests`.
struct ChangesInspectorTests {
    private typealias RGB = LoomTheme.RGB

    @Test func theChangesTabIsTheWideColumnAndTheOthersKeepTheNarrowOne() {
        #expect(InspectorTab.allCases == [.overview, .changes, .agents])
        #expect(InspectorTab.changes.width == LoomTheme.Rhythm.inspectorWidthReview && InspectorTab.changes.width == 556)
        #expect(InspectorTab.overview.width == LoomTheme.Rhythm.inspectorWidth && InspectorTab.agents.width == 328)
    }

    @Test func theOverlayRuleUsesTheOpenTabsWidth() {
        let review = InspectorTab.changes.width, narrow = InspectorTab.overview.width
        let minimum = LoomTheme.Inspector.minimumContent
        // 556 + 480 = 1036: the content keeps 480 pt beside the wide column, or the column is drawn over it.
        #expect(InspectorPlacement.of(open: true, detailWidth: review + minimum, inspectorWidth: review) == .column)
        #expect(InspectorPlacement.of(open: true, detailWidth: review + minimum - 1, inspectorWidth: review) == .overlay)
        // The same pane holds the narrow column and not the wide one.
        #expect(InspectorPlacement.of(open: true, detailWidth: 900, inspectorWidth: narrow) == .column)
        #expect(InspectorPlacement.of(open: true, detailWidth: 900, inspectorWidth: review) == .overlay)
        #expect(InspectorPlacement.of(open: false, detailWidth: 2_000, inspectorWidth: review) == .closed)
        // The default is the narrow column, as before.
        #expect(InspectorPlacement.of(open: true, detailWidth: 808) == .column)
        #expect(InspectorPlacement.of(open: true, detailWidth: 807) == .overlay)
        // A column takes its width from the content; an overlay takes none, and is never wider than the pane it covers.
        #expect(InspectorPlacement.column.contentWidth(detailWidth: 1_200, inspectorWidth: review) == 1_200 - review)
        #expect(InspectorPlacement.overlay.contentWidth(detailWidth: 900, inspectorWidth: review) == 900)
        #expect(InspectorPlacement.column.inspectorWidth(detailWidth: 1_200, tabWidth: review) == review)
        #expect(InspectorPlacement.overlay.inspectorWidth(detailWidth: 900, tabWidth: review) == review)
        #expect(InspectorPlacement.overlay.inspectorWidth(detailWidth: 464, tabWidth: review) == 464)
    }

    @Test func theTabBarNamesTheTabAndGivesItItsSymbol() {
        #expect(InspectorTabBar.title(.changes) == "Changes")
        #expect(InspectorTabBar.symbol(.changes) == "plus.forwardslash.minus")
    }

    @Test func aChangedLineHoldsItsTextContrastInBothLooksOnEveryToneAndLevelItCanSitOn() {
        // The code card is a dim backing over the inspector (or the popover, when the inspector is drawn over the pane);
        // a changed line is a band of the success or failure hue over that. Primary text is 7:1, secondary (the numbers)
        // 4.5:1, and the Increase Contrast secondary at least as much.
        for appearance in LoomTheme.Appearance.allCases {
            for tone in PaneTone.allCases {
                let levels = LoomTheme.Surface.levels(appearance, tone: tone)
                for (name, level) in [("inspector", levels.inspector), ("popover", levels.popover)] {
                    let fill = LoomTheme.Changes.cardFillTone[appearance]
                    let card = fill.rgb.composited(over: level, opacity: fill.opacity)
                    for (label, backdrop) in [("context", card),
                                              ("added", LoomTheme.Changes.bandRGB(added: true, appearance)
                                                .composited(over: card, opacity: LoomTheme.Changes.bandOpacity(added: true))),
                                              ("removed", LoomTheme.Changes.bandRGB(added: false, appearance)
                                                .composited(over: card, opacity: LoomTheme.Changes.bandOpacity(added: false)))] {
                        let place = "\(label) on \(name), \(appearance), \(tone)"
                        #expect(LoomTheme.Text.primaryPair[appearance].contrast(with: backdrop) >= 7, "primary, \(place)")
                        #expect(LoomTheme.Text.secondaryPair[appearance].contrast(with: backdrop) >= 4.5, "secondary, \(place)")
                        #expect(LoomTheme.Text.secondaryIncreasedPair[appearance].contrast(with: backdrop)
                                >= LoomTheme.Text.secondaryPair[appearance].contrast(with: backdrop), "increased, \(place)")
                    }
                }
            }
        }
        // The "+" in the gutter is dark text on the accent, as every filled accent control.
        #expect(LoomTheme.Accent.onAccentRGB.contrast(with: LoomTheme.Accent.baseRGB) >= 4.5)
    }
}
