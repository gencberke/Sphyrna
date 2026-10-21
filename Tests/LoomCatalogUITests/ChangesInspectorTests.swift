import Foundation
import Testing
@testable import LoomCatalogUI

/// V20: the Changes tab in the inspector's frame (the wide column and the overlay rule, the tab bar) and the
/// diff bands' contrast. The tab's reads and comments are in `ChangesModelTests`.
struct ChangesInspectorTests {
    private typealias RGB = LoomTheme.RGB

    @Test func theChangesTabIsTheWideColumnAndTheOthersKeepTheNarrowOne() {
        #expect(InspectorTab.allCases == [.overview, .changes, .agents, .side])
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

    @Test func theTabBarNamesTheTab() {
        #expect(InspectorTabBar.title(.changes) == "Changes")
    }

    @Test func aChangedLineHoldsItsTextContrastInBothAppearancesOnEveryTone() {
        // The code card is raised 1; a changed line is a band of the success or failure hue over that (9 % in Ink, 8 % in
        // Paper). Primary text is 7:1 and the line numbers, tertiary, 4.5:1; Increase Contrast gives tertiary secondary's
        // value, which holds at least as much.
        for appearance in LoomTheme.Appearance.allCases {
            for tone in PaneTone.allCases {
                let card = LoomTheme.Surface.greys(appearance, tone: tone).raised1
                for (label, backdrop) in [("context", card),
                                          ("added", LoomTheme.Changes.bandRGB(added: true, appearance)
                                            .composited(over: card, opacity: LoomTheme.Changes.bandOpacity(added: true, appearance))),
                                          ("removed", LoomTheme.Changes.bandRGB(added: false, appearance)
                                            .composited(over: card, opacity: LoomTheme.Changes.bandOpacity(added: false, appearance)))] {
                    let place = "\(label), \(appearance), \(tone)"
                    #expect(LoomTheme.Text.primaryPair[appearance].contrast(with: backdrop) >= 7, "primary, \(place)")
                    #expect(LoomTheme.Text.tertiaryPair[appearance].contrast(with: backdrop) >= 4.5, "line numbers, \(place)")
                    #expect(LoomTheme.Text.tertiaryIncreasedPair[appearance].contrast(with: backdrop)
                            >= LoomTheme.Text.tertiaryPair[appearance].contrast(with: backdrop), "increased, \(place)")
                }
            }
        }
        // The "+" in the gutter is dark text on the accent, as every filled accent control.
        #expect(LoomTheme.Accent.onAccentRGB.contrast(with: LoomTheme.Accent.baseRGB) >= 4.5)
    }
}
