import AppKit
import Foundation
import LoomChat
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// Release B's UI review: the fixes its screenshots called for. Nothing here opens a window.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ReleaseBReviewTests {
    // MARK: The card's note

    /// While a card waits the note is one line. The narrowest composer (780×500 with the sidebar open) leaves it about
    /// 362 pt (`b-card-approval-dark-780x500.png`), where the old notes, 430 pt and more, were cut. Each note fits in
    /// 340 pt, which leaves room for a wider system font.
    @Test func everyCardNoteFitsOneLineOfTheNarrowestComposer() throws {
        let font = NSFont.systemFont(ofSize: LoomTheme.Composer.cardNoteSize, weight: .medium)
        for kind: ChatPendingRequest.Kind in [.approval, .question, .plan] {
            let note = try #require(ChatComposerModel.cardNoteHint(for: kind))
            let width = (note as NSString).size(withAttributes: [.font: font]).width
            #expect(width <= 340, "the \(kind) note is \(Int(width.rounded())) pt wide")
        }
        #expect(ChatComposerModel.cardNoteHint(for: nil) == nil)
    }

    // MARK: Home's plan-limits card
}
