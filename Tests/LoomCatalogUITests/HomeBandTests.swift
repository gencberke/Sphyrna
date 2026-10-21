import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// DESIGN §9, the plain values of Home: the band's words, which cards show in which state, and the layout values of a row and
/// a card. No view is hosted (the hosted checks are in `HomeRenderTests`).
@Suite struct HomeBandTests {
    // MARK: The sentence

    @Test func theSentenceSaysWhatWorksAndWhatNeedsYouInTheWordsOfDesign() {
        func said(_ working: Int, _ needsYou: Int) -> String { HomeBandText.Sentence(working: working, needsYou: needsYou).text }
        #expect(said(2, 1) == "Two sessions are working. One needs you.")
        #expect(said(0, 1) == "One session needs you.")
        #expect(said(1, 0) == "One session is working. Nothing needs you.")
        #expect(said(0, 0) == "Nothing is working or waiting.")
        #expect(said(0, 0) == MenuBarMenu.emptyTitle, "the menu bar's line")
        // The plural forms, and digits past ten.
        #expect(said(3, 2) == "Three sessions are working. Two need you.")
        #expect(said(1, 4) == "One session is working. Four need you.")
        #expect(said(0, 3) == "Three sessions need you.")
        #expect(said(12, 0) == "12 sessions are working. Nothing needs you.")
        #expect(said(0, 11) == "11 sessions need you.")
    }

    @Test func onlyNeedsYouTakesTheAttentionColourAndOnlyWhenSomethingDoes() {
        func coloured(_ working: Int, _ needsYou: Int) -> [String] {
            HomeBandText.Sentence(working: working, needsYou: needsYou).runs.filter(\.attention).map(\.text)
        }
        #expect(coloured(2, 1) == ["needs you"] && coloured(0, 1) == ["needs you"])
        #expect(coloured(2, 3) == ["need you"])
        #expect(coloured(1, 0).isEmpty, "Nothing needs you is not a call for attention")
        #expect(coloured(0, 0).isEmpty)
    }

    // MARK: The date line

    private var utc: TimeZone { TimeZone(identifier: "UTC")! }
    private var locale: Locale { Locale(identifier: "en_US") }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = locale
        return calendar
    }

    /// 20 October 2026 (a Tuesday) at 09:12 and at 15:05 UTC.
    private func moment(hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: hour, minute: minute))!
    }

    @Test func theDateLineIsTheWeekdayTheDayTheMonthAndTheTimeOnA24HourClock() {
        func line(_ date: Date) -> String { HomeBandText.dateLine(date, zone: utc, locale: locale, calendar: calendar) }
        #expect(line(moment(hour: 9, minute: 12)) == "tuesday 20 october \u{00B7} 09:12")
        // A locale on a 12-hour clock still reads 24 hours here.
        #expect(line(moment(hour: 15, minute: 5)) == "tuesday 20 october \u{00B7} 15:05")
        #expect(LoomDateFormat.time24(moment(hour: 0, minute: 7), zone: utc, locale: locale, calendar: calendar) == "00:07")
        #expect(LoomDateFormat.time(moment(hour: 15, minute: 5), zone: utc, locale: locale, calendar: calendar) != "15:05",
                "the plain time kind keeps the locale's own clock")
    }

    // MARK: The counts line

    @Test func theCountsLineLeavesOutWhatThereIsNothingToCount() {
        func said(_ working: Int, _ toContinue: Int, _ today: Int?) -> [String] {
            HomeBandText.counts(working: working, toContinue: toContinue, sessionsToday: today).map { "\($0.figure) \($0.label)" }
        }
        #expect(said(1, 0, 5) == ["1 working", "5 sessions today"])
        #expect(said(0, 2, 7) == ["2 to continue", "7 sessions today"])
        #expect(said(0, 0, 3) == ["3 sessions today"])
        #expect(said(0, 0, 1) == ["1 session today"])
        #expect(said(0, 0, 0) == ["0 sessions today"])
        #expect(said(0, 0, nil).isEmpty, "before the first read there is nothing to say")
    }

    // MARK: Which cards, and where

    @Test func continueIsTheListsFirstCardAndNeedsYouStaysWhenEmpty() {
        typealias Card = HomeLayout.Card
        #expect(HomeLayout.cards(needsYou: 2, finished: 1, toContinue: 3) == [.continueSessions, .needsYou, .finished])
        #expect(HomeLayout.cards(needsYou: 0, finished: 0, toContinue: 2) == [.continueSessions, .needsYou])
        #expect(HomeLayout.cards(needsYou: 0, finished: 0, toContinue: 0) == [.needsYou], "the empty Needs you card replaces Nothing needs you")
        #expect(HomeLayout.cards(needsYou: 0, finished: 2, toContinue: 0) == [.needsYou, .finished])
        #expect(HomeLayout.cards(needsYou: 1, finished: 0, toContinue: 0) == [.needsYou])
    }

    @Test func theSideColumnSitsBesideTheListsFrom820OfContentAndUnderThemBelow() {
        let inset = LoomTheme.Home.sideInset
        #expect(LoomTheme.Home.wideFrom == 820 && LoomTheme.Home.sideColumn == 316 && LoomTheme.Home.columnGap == 24)
        #expect(HomeLayout.isWide(paneWidth: 820 + 2 * inset))
        #expect(!HomeLayout.isWide(paneWidth: 820 + 2 * inset - 1))
        // A pane wider than the column keeps the column's width.
        #expect(HomeLayout.contentWidth(paneWidth: 2_400) == LoomTheme.Home.maxWidth - 2 * inset)
        #expect(HomeLayout.isWide(paneWidth: 2_400))
    }

    @Test func theBandKeepsClearOfTheWindowButtonsOnlyWhereTheColumnDoesNot() {
        // Sidebar open: no clearance asked, nothing added.
        #expect(HomeLayout.bandLeadingExtra(paneWidth: 900, clearance: 0) == 0)
        // Collapsed in a narrow pane: the column starts at its 32 inset, so the text moves to the clearance.
        #expect(HomeLayout.bandLeadingExtra(paneWidth: 700, clearance: 84) == 84 - LoomTheme.Home.sideInset)
        // A wide pane centres the column well past the clearance.
        #expect(HomeLayout.bandLeadingExtra(paneWidth: 2_000, clearance: 84) == 0)
    }

    // MARK: Values of the band, a card and a row

    @Test func theBandAndTheCardsHaveDesignsValues() {
        typealias H = LoomTheme.Home
        #expect(H.bandAbove == 84 && H.bandBelow == 34 && H.blockGap == 14 && H.maxWidth == 1_000 && H.sideInset == 32)
        #expect(LoomTheme.InkType.statement.size == 42 && LoomTheme.InkType.statement.weight == .ultraLight)
        #expect(H.eyebrow.size == 11 && H.eyebrow.mono && H.eyebrow.tracking == 0.04)
        #expect(H.headHeight == 42 && H.pip == 7 && H.headGap == 9 && H.itemPadding == 16)
        #expect(H.sideCardPadding == 16 && H.sideHeadGap == 4 && H.paceGap == 14)
        #expect(LoomTheme.Radius.block == 12)
        #expect(H.iconSide == 84 && H.symbol.size == 40 && H.textWidth == 420 && H.lift == 40)
    }

    @Test func aRowIsOneLineWithTheHarnessMarkAndItsActionsShowOnHoverOrFocus() {
        typealias H = LoomTheme.Home
        #expect(H.rowTop == 11 && H.rowBottom == 12 && H.rowOneLine == 9 && H.rowLineGap == 3)
        #expect(H.statusColumn == LoomTheme.Layout.indicatorSlot.width && H.rowColumnGap == 10)
        #expect(LoomTheme.Layout.harnessMarkRow == 12, "the harness's mark is 12")
        #expect(H.rowTitle.size == 13 && H.rowTitle.weight == .medium && H.rowMeta.mono && H.rowMeta.size == 11)
        #expect(H.reason.size == 12 && H.reasonMono.size == 11.5 && H.reasonMono.mono)
        #expect(LoomTheme.Control.Size.small.height == 22, "Open Session, Mark as Read and Resume are small buttons")
        #expect(H.continueShown == 5)
        // The actions: the pointer, the held hover of an evidence run, or keyboard focus.
        #expect(!HomeRowActions.revealed(hovering: false, focused: false))
        #expect(HomeRowActions.revealed(hovering: true, focused: false))
        #expect(HomeRowActions.revealed(hovering: false, focused: true))
    }

    @Test func theHeadingsAndTheCheckAgainButtonSayWhatTheyAre() {
        #expect(HomeListHeading.label(title: "Needs you", count: 1) == "Needs you, 1")
        #expect(HomeListHeading.label(title: "Needs you", count: nil) == "Needs you")
        #expect(HomeCheckAgain.title(checking: false) == "Check Again" && HomeCheckAgain.title(checking: true) == "Checking…")
    }
}
