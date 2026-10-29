import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

@MainActor
struct SidebarInkLayoutTests {
    /// RESCUE C3: the view's name once, its own action beside it, and the picker apart (no "PROJECTS projects · activity").
    @Test func theListHeadingNamesTheViewOnceWithItsActionAndThePickerOffersBoth() {
        #expect(SidebarListHeading.name(of: .projects) == "Projects" && SidebarListHeading.name(of: .activity) == "Activity")
        #expect(SidebarListHeading.action(of: .projects) == .addProject && SidebarListHeading.action(of: .activity) == .newSession)
        #expect(SidebarListHeading.Action.addProject.title == "Add Project…")
        #expect(SidebarListHeading.options == [.activity, .projects])
    }

    @Test func theRowsAreInksHeightsAndRadii() {
        #expect(LoomTheme.Sidebar.homeRowHeight == 28 && LoomTheme.Sidebar.lineRowHeight == 28)
        #expect(LoomTheme.Sidebar.headLeading == 10 && LoomTheme.Sidebar.headNameSize == 13)
        #expect(LoomTheme.Highlight.radiusCompact == 8 && LoomTheme.Highlight.radius == 10, "rows 8, activity cards 10")
        #expect(LoomTheme.Sidebar.doorHeight == 32 && LoomTheme.Sidebar.doorRadius == 8)
        #expect(LoomTheme.Sidebar.footerHeight == 46)
        #expect(LoomTheme.Sidebar.chipMeter == CGSize(width: 40, height: 4))
        #expect(LoomTheme.Sidebar.cardInset == 12)
    }

    // MARK: The fixes from the lunch pairs (I3f)

    @Test func theActivityHeadingsStartOnTheStatusColumnsLeftEdgeAndPadAsTheReferenceDoes() {
        typealias S = LoomTheme.Sidebar
        // The list's 8 plus the heading's 16: 24 from the sidebar's edge, where the status column starts.
        #expect(LoomTheme.Space.listInset + S.rowLeading == 24)
        #expect(S.activityHeadingTop == 12 && S.activityHeadingBottom == 5 && S.activityHeadingSpacing == 6)
        #expect(ActivityHeading.top(for: .first, hasDrafts: true) == 0, "the first heading pads nothing above")
        #expect(ActivityHeading.top(for: .firstUnlessDrafts, hasDrafts: false) == 0)
        #expect(ActivityHeading.top(for: .firstUnlessDrafts, hasDrafts: true) == 12, "under the Drafts it is a later heading")
        #expect(ActivityHeading.top(for: .later, hasDrafts: false) == 12)
        // The heading has 6 above and 2 below; the first project head adds 2, later heads 10.
        #expect(S.headingTop == 6 && S.headingBottom == 2)
        #expect(ProjectHeader.topGap(isFirst: true) == 2 && ProjectHeader.topGap(isFirst: false) == 10)
    }

    @Test func theProjectHeadsAttentionDotStandsAtTheTrailingEndOrJustBeforeTheControls() {
        // At rest 12 from the head's edge (the content row ends 4 in); with the controls shown, before their three 22 pt buttons.
        #expect(ProjectHeader.attentionDotTrailing(showsControls: false) == 12 - LoomTheme.Sidebar.headTrailing)
        #expect(ProjectHeader.controlsWidth == 66)
        #expect(ProjectHeader.attentionDotTrailing(showsControls: true) == 66)
    }

    @Test func theNewSessionRowDrawsAPlusAndTheKeyCapAndItsTextTakesPrimaryUnderThePointer() {
        #expect(NewSessionRow.keyHint == "\u{2318}N", "the cap is the command's own key")
        #expect(NewSessionRow.keyHint != SearchDoor.keyHint)
        #expect(!NewSessionRow.titleIsPrimary(hovering: false) && NewSessionRow.titleIsPrimary(hovering: true))
        #expect(LoomTheme.Sidebar.homeGlyphColumn == 16)
    }

    @Test func theListStacksItsEntriesAndTheCardsPadTenAndTwelve() {
        typealias S = LoomTheme.Sidebar
        #expect(S.listSpacing == 0)
        #expect(S.cardTop == 10 && S.cardBottom == 10 && S.cardInset == 12)
        // The branch's stroked centre aligns with the leading mark in both views.
        #expect(LoomTheme.Branches.column + LoomTheme.Branches.lineWidth / 2 + S.cardBranchOffset
                == S.cardInset + S.cardMarkSide / 2)
    }

    @Test func theCardUsesFourteenPointTopMarksAndElevenPointTrailingHarnessMarks() {
        typealias S = LoomTheme.Sidebar
        #expect(S.cardMarkSide == 14 && S.cardHarnessMark == 11 && LoomTheme.Layout.harnessMarkRow == 12)
        #expect(S.cardTopHeight == 18 && S.cardTitleHeight == 20 && S.cardMetaHeight == 16)
    }

    @Test func aReasonLineDrawsItsCommandInMono() {
        let command = SessionReasonLine(StatusReason(.approval(tool: "Bash"), detail: "git push origin fix/webhook-sig"))
        #expect(command?.mono == "git push origin fix/webhook-sig")
        #expect(command?.lead == "Asks to run: ")
        let path = SessionReasonLine(StatusReason(.approval(tool: "Write"), detail: "/tmp/ws/hello.txt"))
        #expect(path?.lead == "Asks to write: " && path?.mono == "/tmp/ws/hello.txt")
        // Words are not machine talk: only an approval's command or path is mono.
        for reason in [StatusReason(.question, detail: "PDF library"), StatusReason(.planReady),
                       StatusReason(.failure(category: nil), detail: "Too many requests"), StatusReason(.approval(tool: "Bash"))] {
            let line = SessionReasonLine(reason)
            #expect(line?.mono == nil && line?.lead == line?.text)
        }
    }

    @Test func theProjectHeadShowsItsControlsUnderThePointerOrWithTheKeyboard() {
        #expect(ProjectHeader.showsControls(hovering: true, focused: false))
        #expect(ProjectHeader.showsControls(hovering: false, focused: true))
        #expect(!ProjectHeader.showsControls(hovering: false, focused: false))
    }
}
