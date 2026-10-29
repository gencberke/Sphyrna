import AppKit
import Foundation
import LoomChat
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// Release B's fix round 2, the look and composer items: one composer for the draft and the live session (item 3) and the
/// user row's text (item 5). The popover contrast is `HighlightTests`, the Usage meters `UsageCardsTests`, the `@` menu
/// `ChatComposerBehaviorTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct FixRoundLookTests {
    // MARK: Item 3, one composer

    /// The draft's composer kept an inset of 18, a top of 10 and a chip gap of 6 after the live composer moved to 16, 12 and 8
    /// (V17). The draft reads the live composer's tokens, so they cannot drift apart again.
    @Test func theDraftComposerUsesTheLiveComposersInsetsTopAndChipSpacing() {
        #expect(NewSessionLayout.textInset == LoomTheme.Composer.textInsetH)
        #expect(NewSessionLayout.textTop == LoomTheme.Composer.textTop)
        #expect(NewSessionLayout.chipSpacing == LoomTheme.Composer.chipGap)
        #expect(NewSessionLayout.textInset == 16 && NewSessionLayout.textTop == 12 && NewSessionLayout.chipSpacing == 8)
    }

    // MARK: Item 5, long user rows
}
