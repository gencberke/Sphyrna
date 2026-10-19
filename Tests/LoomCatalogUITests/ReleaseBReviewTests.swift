import AppKit
import Foundation
import LoomChat
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// Release B's UI review: the fixes its screenshots called for. Nothing here opens a window; the Home line is drawn
/// offscreen, to PNGs when `LOOM_REVIEW_RENDER_DIR` is set.
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

    // MARK: Home's plan-limits line

    private func pace(_ kind: PlanLimitKind, used: Int, resetsIn: TimeInterval) -> PlanPace {
        PlanPace(kind: kind, window: PlanLimitWindow(usedPercent: used, resetsAt: Self.now.addingTimeInterval(resetsIn)), at: Self.now)!
    }

    /// The line's height at `width`, drawn as Home's card draws it.
    private func height(_ paces: [PlanPace], width: CGFloat, name: String) throws -> CGFloat {
        let line = PlanLimitsLine(paces: paces, now: Self.now, timeZone: Self.zone)
        let page = HomePlanLimitsLine(line: line, paces: paces, now: Self.now, timeZone: Self.zone, updated: nil)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(LoomTheme.Surface.card)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        if let directory = ProcessInfo.processInfo.environment["LOOM_REVIEW_RENDER_DIR"], !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("home-limits-\(name).png"))
        }
        return CGFloat(image.height) / renderer.scale
    }

    /// At 1220×780 Home's side card leaves the line 308 pt, and a week that runs out on another day was cut before its
    /// time ("Wk runs out Tu…"). The verdict now takes a second line under the windows; a line that fits stays one row.
    @Test func aVerdictThatDoesNotFitTakesASecondLineAndALineThatFitsStaysOneRow() throws {
        let sideCard = LoomTheme.Home.sideColumn - 2 * LoomTheme.Home.sideCardPadding
        let five = pace(.fiveHour, used: 38, resetsIn: 4_800)
        let tight = pace(.weekly, used: 80, resetsIn: 4 * 86_400) // 80 % gone in 3 of 7 days: runs out Thursday
        let runsOut = [five, tight]
        let verdict = try #require(PlanLimitsLine(paces: runsOut, now: Self.now, timeZone: Self.zone).verdict)
        #expect(verdict.text.hasPrefix("Wk runs out Thu"))

        let row = LoomTheme.Home.usageRowHeight
        let wrapped = try height(runsOut, width: sideCard, name: "runs-out-side-card")
        #expect(wrapped > row + 4, "the verdict is on its own line: \(wrapped) pt")
        #expect(try height(runsOut, width: 600, name: "runs-out-wide") == row, "a wide card keeps one row")
        let onPace = [five, pace(.weekly, used: 26, resetsIn: 4 * 86_400)]
        #expect(try height(onPace, width: sideCard, name: "on-pace-side-card") == row, "\"on pace\" fits the side card")
    }
}
