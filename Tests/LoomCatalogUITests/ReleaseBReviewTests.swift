import AppKit
import Foundation
import LoomChat
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// Release B's UI review: the fixes its screenshots called for. Nothing here opens a window.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ReleaseBReviewTests {
    private static let zone = TimeZone(identifier: "UTC")!
    private static let now = Date(timeIntervalSince1970: 1_791_374_400) // Wednesday 2026-10-07 12:00 UTC

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

    private func pace(_ kind: PlanLimitKind, used: Int, resetsIn: TimeInterval) -> PlanPace {
        PlanPace(kind: kind, window: PlanLimitWindow(usedPercent: used, resetsAt: Self.now.addingTimeInterval(resetsIn)), at: Self.now)!
    }

    /// The pace line's height at `width`, drawn as Home's card draws it.
    private func height(_ pace: PlanPace, width: CGFloat) -> CGFloat {
        NSHostingController(rootView: PlanPaceLine(pace: pace, now: Self.now, timeZone: Self.zone))
            .sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
    }

    /// At 1220×780 the side card leaves a pace line 308 pt, and a week that runs out on another day was cut before its
    /// time. The sentence wraps instead, so the time a limit runs out is never lost; a sentence that fits stays one line.
    @Test func aPaceSentenceThatDoesNotFitWrapsAndOneThatFitsStaysOneLine() throws {
        let tight = pace(.weekly, used: 80, resetsIn: 4 * 86_400) // 80 % gone in 3 of 7 days: runs out Thursday
        let sentence = PlanPaceText.sentence(tight, now: Self.now, timeZone: Self.zone)
        #expect(sentence.contains("runs out Thu"))
        let wide = height(tight, width: 600)
        #expect(height(tight, width: 150) > wide, "the sentence takes a second line in a narrow card")
        #expect(height(tight, width: 308) >= wide)
        let lasts = pace(.fiveHour, used: 38, resetsIn: 4_800)
        #expect(height(lasts, width: 308) == height(lasts, width: 600), "\"at this pace it lasts\" fits the side card")
    }
}
