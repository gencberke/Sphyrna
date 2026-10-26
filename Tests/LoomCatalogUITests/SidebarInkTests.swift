import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// The sidebar in Ink (I3r; DESIGN §2 items 1, 3, 4 and 5, §6 Rows): the header row, the list heading's switch, the rows' and
/// cards' lines. What the views evaluate is in `SidebarRenderTests`, the pill's fills in `HighlightTests`, the selection's tint in
/// `ProjectColorUITests`, the palette that the search door opens in `PaletteTests` and `SearchFocusAndHitTests`.
extension WindowEventTests {
    @MainActor
    @Suite(.timeLimit(.minutes(2)))
    struct SidebarInkTests {
        private func model() throws -> (CatalogModel, URL) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ink-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                     preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
            return (model, root)
        }

        private func labels(in view: NSView) -> [String] {
            accessibilityElements(in: view).compactMap { $0.accessibilityLabel?() }.filter { !$0.isEmpty }
        }

        @Test func theHeaderRowHoldsTheSidebarToggleAndNoViewButtonsOrMenu() async throws {
            enableAccessibilityTree()
            let (model, root) = try model()
            defer { try? FileManager.default.removeItem(at: root) }
            let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 300, height: 500))
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(400))
            let all = labels(in: hosting.view)
            #expect(all.contains("Hide sidebar"))
            for gone in ["Group by project", "Recent activity", "More actions"] {
                #expect(!all.contains(gone), "\(gone) left the header: \(all)")
            }
            // Add Project stays in the footer's `+` menu.
            let nodes = axTree(of: hosting.view).flattened()
            #expect(nodes.contains { [$0.label, $0.title, $0.help].contains("New session or project") }, "\(all)")
        }

        @Test func theListHeadingNamesTheViewAndItsSwitchChangesIt() async throws {
            enableAccessibilityTree()
            let (model, root) = try model()
            defer { try? FileManager.default.removeItem(at: root) }
            model.setViewMode(.projects)
            let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 300, height: 500))
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(400))

            let tree = axTree(of: hosting.view).flattened()
            print("AXDUMP switch:", tree.filter { $0.role.contains("Radio") || $0.label == "Projects" || $0.label == "Activity" }.map(\.description))
            func heading(_ nodes: [AXNode], _ name: String) -> Bool {
                nodes.contains { $0.role == "AXHeading" && $0.label?.caseInsensitiveCompare(name) == .orderedSame }
            }
            #expect(heading(tree, "Projects"), "the heading names the view")

            // The segmented picker is exposed as radio buttons (tab buttons), one per option.
            func option(_ title: String) -> AnyObject? {
                accessibilityElements(in: hosting.view).first {
                    $0.accessibilityRole?() == .radioButton && ($0.accessibilityLabel?() ?? $0.accessibilityTitle?() ?? "") == title
                }
            }
            let activity = try #require(option("Activity"), "the switch is a two-option control")
            let projects = try #require(option("Projects"))
            #expect(activity.accessibilityPerformPress?() == true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.viewMode == .activity, "a click on a word switches the view")
            try await Task.sleep(for: .milliseconds(300))
            let again = axTree(of: hosting.view).flattened()
            #expect(heading(again, "Activity"))

            let back = try #require(option("Projects"))
            #expect(back.accessibilityPerformPress?() == true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.viewMode == .projects)
        }
    }
}

@MainActor
struct SidebarInkLayoutTests {
    /// RESCUE C3: the view's name once, its own action beside it, and the picker apart (no "PROJECTS projects · activity").
    @Test func theListHeadingNamesTheViewOnceWithItsActionAndThePickerOffersBoth() {
        #expect(SidebarListHeading.name(of: .projects) == "Projects" && SidebarListHeading.name(of: .activity) == "Activity")
        #expect(SidebarListHeading.action(of: .projects) == .addProject && SidebarListHeading.action(of: .activity) == .newSession)
        #expect(SidebarListHeading.Action.addProject.title == "Add Project…")
        #expect(SidebarListHeading.options == [.activity, .projects])
        #expect(Set(SidebarListHeading.options.map(SidebarListHeading.symbol(of:))).count == 2, "an icon each")
    }

    @Test func theRowsAreInksHeightsAndRadii() {
        #expect(LoomTheme.Sidebar.homeRowHeight == 28 && LoomTheme.Sidebar.lineRowHeight == 28)
        #expect(LoomTheme.Highlight.radiusCompact == 8 && LoomTheme.Highlight.radius == 10, "rows 8, activity cards 10")
        #expect(LoomTheme.Sidebar.doorHeight == 30 && LoomTheme.Sidebar.doorRadius == 8)
        #expect(LoomTheme.Sidebar.footerHeight == 46)
        #expect(LoomTheme.Sidebar.chipMeter == CGSize(width: 40, height: 4))
        // The title and the lines under it start under the mark, on one edge: the status slot and one gap, 20 in all (FB6-2).
        #expect(LoomTheme.Sidebar.cardTextIndent == 20)
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
        // 8 under the label in both views; the first project head adds 2, the heads that follow a group 10.
        #expect(S.headingBottom == 8)
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

    @Test func theListStacksItsEntriesAndTheCardsPadFiveAndSix() {
        typealias S = LoomTheme.Sidebar
        #expect(S.listSpacing == 0)
        #expect(S.cardTop == 5 && S.cardBottom == 6)
        // The trunk of a card's line still starts 7 pt under the status mark's centre, read from the card's own padding.
        let markCentre = S.cardTop + LoomTheme.Layout.indicatorSlot.height / 2
        #expect(LoomTheme.Branches.cardTrunkTop == markCentre + 7)
    }

    @Test func theHarnessMarkKeepsItsTwelvePointsAndTheLinesStartUnderIt() {
        typealias S = LoomTheme.Sidebar
        #expect(S.markSlot == LoomTheme.Layout.harnessMarkRow && S.markSlot == 12)
        // The name after the mark on the top line (40); the title and the lines under it at the mark's own edge (20).
        #expect(S.titleIndent == 40 && S.cardTextIndent == 20)
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
