import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomCore
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// H1-F (D-49, D-52) without a window or a system service: the menu bar item's state and menu, the
/// notification decision, the mark's path, the drawn dot, the preferences and the Settings lines.
@MainActor
struct MenuBarTests {
    private func entry(_ n: Int, _ indicator: SessionIndicator, at seconds: Double = 0, project: String? = "Loom") -> MenuBarEntry {
        MenuBarEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, indicator: indicator,
                     lastActivityAt: Date(timeIntervalSince1970: seconds), title: "s\(n)", project: project)
    }

    private func ids(_ rows: [MenuBarRow]) -> [Int] {
        rows.map { Int(String($0.id.uuidString.suffix(12)))! }
    }

    // MARK: State

    @Test func theDotBeatsTheSpinnerAndTheStrongestClassWins() {
        let working = entry(1, .working)
        #expect(MenuBarState.derive([]).summary.badge == .none)
        #expect(MenuBarState.derive([working]).summary.badge == .working)
        #expect(MenuBarState.derive([working, entry(2, .unviewedCompletion)]).summary.badge == .unviewed)
        #expect(MenuBarState.derive([working, entry(2, .unviewedCompletion), entry(3, .waitingForInput)]).summary.badge == .attention)
        #expect(MenuBarState.derive([working, entry(2, .waitingForApproval), entry(3, .stopUnverified("x"))]).summary.badge == .failure)
        // Identity unclear is attention; a problem is failure; a ready session is nothing.
        #expect(MenuBarState.derive([entry(1, .identityUnclear)]).summary.badge == .attention)
        #expect(MenuBarState.derive([entry(1, .problem("x"))]).summary.badge == .failure)
        #expect(MenuBarState.derive([entry(1, .ready), entry(2, .idle), entry(3, .ended)]).summary.badge == .none)
    }

    @Test func needsYouIsOrderedByClassThenRecentActivityThenId() {
        let state = MenuBarState.derive([
            entry(1, .unviewedCompletion, at: 900),
            entry(2, .waitingForApproval, at: 100),
            entry(3, .failed("x"), at: 50),
            entry(4, .waitingForInput, at: 300),
            entry(5, .waitingForInput, at: 300), // same time as 4: the id decides
            entry(6, .working, at: 999),
        ])
        #expect(ids(state.needsYou) == [3, 4, 5, 2, 1])
        #expect(state.needsYou.map(\.attention) == [.failure, .attention, .attention, .attention, .unviewed])
        #expect(ids(state.working) == [6])
        #expect(state.working.map(\.attention) == [nil])
    }

    @Test func eachSectionShowsFiveRowsAndCountsTheRest() {
        let needing = (1...8).map { entry($0, .waitingForInput, at: Double($0)) }
        let working = (11...17).map { entry($0, .working, at: Double($0)) }
        let state = MenuBarState.derive(needing + working)
        #expect(ids(state.needsYou) == [8, 7, 6, 5, 4], "most recent first")
        #expect(state.needsYouMore == 3)
        #expect(ids(state.working) == [17, 16, 15, 14, 13])
        #expect(state.workingMore == 2)
        #expect(state.summary.needsYou == 8 && state.summary.working == 7, "the label counts all, not the rows")
        let five = MenuBarState.derive((1...5).map { entry($0, .working, at: Double($0)) })
        #expect(five.working.count == 5 && five.workingMore == 0)
    }

    @Test func theAccessibilityLabelReadsSingularAndPlural() {
        func label(_ needs: Int, _ working: Int) -> String {
            MenuBarSummary(badge: .none, needsYou: needs, working: working, approvals: []).accessibilityLabel
        }
        #expect(label(0, 0) == "Sphyrna")
        #expect(label(0, 1) == "Sphyrna, 1 session working")
        #expect(label(0, 2) == "Sphyrna, 2 sessions working")
        #expect(label(1, 0) == "Sphyrna, 1 session needs you")
        #expect(label(3, 0) == "Sphyrna, 3 sessions need you")
        #expect(label(1, 2) == "Sphyrna, 1 session needs you, 2 working")
        #expect(label(2, 1) == "Sphyrna, 2 sessions need you, 1 working")
    }

    @Test func approvalsIncludeOnlySessionsAtNeedsApproval() {
        let summary = MenuBarState.derive([entry(1, .waitingForApproval), entry(2, .waitingForInput), entry(3, .failed(nil))]).summary
        #expect(summary.approvals == [entry(1, .ready).id])
    }

    // MARK: Menu

    @Test func theMenuHasSectionsOnlyForSessionsAndTheFixedItemsAfter() {
        func kinds(_ items: [MenuBarMenuItem]) -> [MenuBarMenuItem.Kind] { items.map(\.kind) }
        let tail: [MenuBarMenuItem.Kind] = [.separator, .newSession, .openLoom, .separator, .settings, .quit]

        let empty = MenuBarMenu.items(for: MenuBarState.derive([]))
        #expect(kinds(empty) == [.empty] + tail)
        #expect(empty[0].title == "Nothing is working or waiting." && !empty[0].enabled)

        let workingOnly = MenuBarMenu.items(for: MenuBarState.derive([entry(1, .working)]))
        #expect(kinds(workingOnly) == [.header, .workingSession] + tail)
        #expect(workingOnly[0].title == "Working")

        let both = MenuBarMenu.items(for: MenuBarState.derive([entry(1, .working), entry(2, .failed(nil))]))
        #expect(kinds(both) == [.header, .needsYouSession, .header, .workingSession] + tail)
        #expect(both[0].title == "Needs you" && !both[0].enabled)
        #expect(both[1].attention == .failure && both[1].project == "Loom" && both[1].sessionID != nil)

        let many = MenuBarMenu.items(for: MenuBarState.derive((1...7).map { entry($0, .waitingForInput) }))
        let more = many.first { $0.kind == .more }
        #expect(more?.title == "and 2 more…" && more?.enabled == true && more?.sessionID == nil)

        let items = both.filter { [.newSession, .settings, .quit].contains($0.kind) }
        #expect(items.map(\.title) == ["New Claude Session", "Settings…", "Quit Sphyrna"])
        #expect(items.map(\.key) == ["⌘N", "⌘,", "⌘Q"])
        #expect(MenuBarMenu.items(for: MenuBarState.derive([]), canStartSession: false).first { $0.kind == .newSession }?.enabled == false)
    }

    @Test func aLongTitleIsCutAtItsEndAndTheProjectKeepsItsRoom() {
        let theme = LoomTheme.MenuBar.self
        let long = String(repeating: "A very long session title ", count: 8)
        let shown = MenuBarRowText.fit(title: long, project: "edd-backend")
        #expect(shown.title.hasSuffix("…") && shown.title.hasPrefix("A very long"))
        #expect(shown.project == "edd-backend")
        func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        #expect(width(shown.title, MenuBarRowText.titleFont) + theme.titleProjectGap
                + width("edd-backend", MenuBarRowText.projectFont) <= theme.rowTextWidth)
        let wide = MenuBarRowText.fit(title: "short", project: String(repeating: "project", count: 20))
        #expect(wide.title == "short")
        #expect(width(try! #require(wide.project), MenuBarRowText.projectFont) <= theme.projectMaxWidth)
        #expect(MenuBarRowText.fit(title: "no project", project: nil).project == nil)
        #expect(MenuBarRowText.fit(title: "two\nlines", project: nil).title == "two lines")
    }

    // MARK: Notifications

    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    @Test func aBannerIsPostedOnlyOnTheTransitionWhileLoomIsElsewhereAndTheSettingIsOn() {
        typealias Planner = ApprovalNotificationPlanner
        #expect(Planner.plan(previous: [], current: [a], appIsActive: false, enabled: true).post == [a])
        // Already waiting: no second banner, whatever else changed.
        #expect(Planner.plan(previous: [a], current: [a, b], appIsActive: false, enabled: true).post == [b])
        #expect(Planner.plan(previous: [a], current: [a], appIsActive: false, enabled: true).isEmpty)
        // Loom is the active app, or the setting is off: nothing.
        #expect(Planner.plan(previous: [], current: [a], appIsActive: true, enabled: true).post.isEmpty)
        #expect(Planner.plan(previous: [], current: [a], appIsActive: false, enabled: false).post.isEmpty)
        // Nothing for sessions that are not at Needs approval is possible: only approvals reach the planner.
        #expect(Planner.plan(previous: [], current: [], appIsActive: false, enabled: true).isEmpty)
    }

    @Test func aBannerGoesWhenItsSessionLeavesNeedsApprovalWhateverTheSetting() {
        typealias Planner = ApprovalNotificationPlanner
        #expect(Planner.plan(previous: [a, b], current: [b], appIsActive: false, enabled: true).remove == [a])
        #expect(Planner.plan(previous: [a], current: [], appIsActive: true, enabled: false).remove == [a])
        // A session that waits again after leaving is a new transition.
        let first = Planner.plan(previous: [], current: [a], appIsActive: false, enabled: true)
        let left = Planner.plan(previous: [a], current: [], appIsActive: false, enabled: true)
        let again = Planner.plan(previous: [], current: [a], appIsActive: false, enabled: true)
        #expect(first.post == [a] && left.remove == [a] && again.post == [a])
    }

    @Test func theBannerBodyNamesTheProjectWhenThereIsOne() {
        #expect(ApprovalNotificationPlanner.body(project: "edd-backend") == "edd-backend · Claude is waiting for your approval.")
        #expect(ApprovalNotificationPlanner.body(project: nil) == "Claude is waiting for your approval.")
        #expect(ApprovalNotificationPlanner.body(project: "") == "Claude is waiting for your approval.")
    }

    // MARK: Mark

    /// Front (D-77): the source's path data is the identity file's, in M, L, C and Z only, 18 wide and centred on the
    /// 20 pt canvas, with an open eye hole at each tip of the hammer.
    @Test func theFrontMarkIsTheIdentityFilesPathsEighteenWideOnTheCanvas() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let svg = try String(contentsOf: root.appendingPathComponent("design/identity/menubar-front.svg"), encoding: .utf8)
        let identity = svg.matches(of: /<path d="([^"]+)"/).map { String($0.output.1) }
        #expect(MenuBarMark.data == identity)
        for data in MenuBarMark.data {
            #expect(Set(data.filter(\.isLetter)).isSubset(of: ["M", "L", "C", "Z"]), "\(data.prefix(20))")
        }
        let bounds = MenuBarMark.bounds
        let canvas = LoomTheme.MenuBar.canvas
        #expect(abs(bounds.width - 18) < 0.15, "\(bounds)")
        #expect(abs(bounds.midX - canvas.width / 2) < 0.01 && bounds.minY >= 0 && bounds.maxY <= canvas.height)
        let hammer = MenuBarMark.paths[1]
        #expect(!hammer.contains(CGPoint(x: 2.55, y: 8.8), using: .evenOdd), "the left eye is a hole")
        #expect(!hammer.contains(CGPoint(x: 17.45, y: 8.8), using: .evenOdd), "the right eye is a hole")
        #expect(hammer.contains(CGPoint(x: 5, y: 8.6), using: .evenOdd) && hammer.contains(CGPoint(x: 10, y: 8), using: .evenOdd))
    }

    @Test func theSVGPathParserReadsAbsoluteRelativeAndImplicitCommands() {
        let path = SVGPathParser.parse("M10 10 20 10 l0 10 c0 5 5 10 10 10 z m5 5 h")
        // M with a second pair is a line; l and c are relative to the current point; z returns to the start.
        let box = path.boundingBoxOfPath
        #expect(box.minX == 10 && box.minY == 10 && box.maxX == 30 && box.maxY == 30)
        #expect(SVGPathParser.parse("").isEmpty)
    }

    // MARK: Drawing

    private func pixel(_ png: Data, x: Double, y: Double) throws -> NSColor {
        let bitmap = try #require(NSBitmapImageRep(data: png))
        // The bitmap's own components, no colour-space conversion in between.
        return try #require(bitmap.colorAt(x: Int(x * 2), y: Int(y * 2)))
    }

    @Test func theBadgeDotIsDrawnInTheBarsColourWithTheMarkCutAwayAroundIt() throws {
        let theme = LoomTheme.MenuBar.self
        // Canvas origin in the evidence picture, then the dot's centre in canvas coordinates.
        let origin = CGPoint(x: (theme.barWidth - theme.canvas.width) / 2, y: (theme.barHeight - theme.canvas.height) / 2)
        let dot = CGPoint(x: origin.x + theme.dotCenter.x, y: origin.y + theme.dotCenter.y)
        for (darkBar, expected) in [(true, theme.dotRGB(.attention, darkBar: true, increasedContrast: false)),
                                    (false, theme.dotRGB(.attention, darkBar: false, increasedContrast: false))] {
            let png = try #require(MenuBarArt.evidencePNG(badge: .attention, darkBar: darkBar, increasedContrast: false))
            let color = try pixel(png, x: dot.x, y: dot.y)
            #expect(abs(Double(color.redComponent) - expected.red) < 0.04 && abs(Double(color.greenComponent) - expected.green) < 0.04
                    && abs(Double(color.blueComponent) - expected.blue) < 0.04, "dot colour on a \(darkBar ? "dark" : "light") bar")
            // Just inside the cut-away ring, outside the dot, the bar shows through.
            let ring = try pixel(png, x: dot.x - (theme.dotDiameter / 2 + 0.7), y: dot.y)
            let bar = (darkBar ? theme.barDarkRGB : theme.barLightRGB)
            #expect(abs(Double(ring.redComponent) - bar.red) < 0.06 && abs(Double(ring.blueComponent) - bar.blue) < 0.06)
        }
        // The mark itself is white on a dark bar and black on a light one (a point on the hammer).
        let markPoint = CGPoint(x: origin.x + 5, y: origin.y + 8.6)
        let onDark = try pixel(try #require(MenuBarArt.evidencePNG(badge: .none, darkBar: true, increasedContrast: false)),
                               x: markPoint.x, y: markPoint.y)
        let onLight = try pixel(try #require(MenuBarArt.evidencePNG(badge: .none, darkBar: false, increasedContrast: false)),
                                x: markPoint.x, y: markPoint.y)
        #expect(onDark.brightnessComponent > 0.9 && onLight.brightnessComponent < 0.1)
    }

    /// The badge's cut (5.2 around the 7 pt dot) takes the right pectoral fin's tip away; the eye holes show the bar.
    @Test func theBadgeCutsTheFrontMarkAroundTheDotAndTheEyesShowTheBar() throws {
        let theme = LoomTheme.MenuBar.self
        let origin = CGPoint(x: (theme.barWidth - theme.canvas.width) / 2, y: (theme.barHeight - theme.canvas.height) / 2)
        // A point whose whole 2x pixel lies on the fin, outside the dot and inside the cut.
        let fin = CGPoint(x: 13.0, y: 12.6)
        let distance = hypot(fin.x - theme.dotCenter.x, fin.y - theme.dotCenter.y)
        #expect(distance > theme.dotDiameter / 2 + 0.2 && distance < theme.dotCutoutRadius - 0.2, "the point is in the cut ring")
        #expect(MenuBarMark.paths[4].contains(fin, using: .evenOdd), "the point is on the fin")
        for darkBar in [true, false] {
            let bar = darkBar ? theme.barDarkRGB : theme.barLightRGB
            let idle = try pixel(try #require(MenuBarArt.evidencePNG(badge: .none, darkBar: darkBar, increasedContrast: false)),
                                 x: origin.x + fin.x, y: origin.y + fin.y)
            let cut = try pixel(try #require(MenuBarArt.evidencePNG(badge: .attention, darkBar: darkBar, increasedContrast: false)),
                                x: origin.x + fin.x, y: origin.y + fin.y)
            #expect(darkBar ? idle.brightnessComponent > 0.9 : idle.brightnessComponent < 0.1, "the fin without a badge")
            #expect(abs(Double(cut.redComponent) - bar.red) < 0.06 && abs(Double(cut.blueComponent) - bar.blue) < 0.06,
                    "the cut shows the \(darkBar ? "dark" : "light") bar")
            let eye = try pixel(try #require(MenuBarArt.evidencePNG(badge: .none, darkBar: darkBar, increasedContrast: false)),
                                x: origin.x + 2.55, y: origin.y + 8.8)
            #expect(abs(Double(eye.redComponent) - bar.red) < 0.06 && abs(Double(eye.blueComponent) - bar.blue) < 0.06, "an eye")
        }
    }

    /// Writes the item idle and with each badge, on a dark and a light bar (and with Increase Contrast), at 4x, when
    /// `LOOM_MENUBAR_RENDER_DIR` is set; otherwise only checks that every picture is made. The item's own drawing.
    @Test func rendersTheFrontMarkInEveryStateOnBothBars() throws {
        let directory = ProcessInfo.processInfo.environment["LOOM_MENUBAR_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let badges: [MenuBarBadge] = [.none, .working, .failure, .attention, .unviewed]
        for badge in badges {
            for darkBar in [true, false] {
                for increased in [false, true] {
                    let png = try #require(MenuBarArt.evidencePNG(badge: badge, darkBar: darkBar, increasedContrast: increased, scale: 4))
                    let name = "menubar-\(badge == .none ? "idle" : badge.rawValue)-\(darkBar ? "dark" : "light")\(increased ? "-contrast" : "").png"
                    if let directory { try png.write(to: directory.appendingPathComponent(name)) }
                }
            }
        }
    }

    /// The working badge is the spinner's first frame, white on a dark bar and black on a light one, in the badge slot
    /// that the mark is cut away around.
    @Test func theWorkingBadgeDrawsTheSpinnerOnADarkAndALightBar() throws {
        let theme = LoomTheme.MenuBar.self
        let origin = CGPoint(x: (theme.barWidth - theme.canvas.width) / 2, y: (theme.barHeight - theme.canvas.height) / 2)
        let slot = MenuBarArt.spinnerRect()
        for darkBar in [true, false] {
            let png = try #require(MenuBarArt.evidencePNG(badge: .working, darkBar: darkBar, increasedContrast: false))
            let bitmap = try #require(NSBitmapImageRep(data: png))
            let bar = darkBar ? theme.barDarkRGB : theme.barLightRGB
            var glyph = 0
            for y in Int((origin.y + slot.minY) * 2)..<Int((origin.y + slot.maxY) * 2) {
                for x in Int((origin.x + slot.minX) * 2)..<Int((origin.x + slot.maxX) * 2) {
                    let color = try #require(bitmap.colorAt(x: x, y: y))
                    // Glyph pixels are the bar's opposite: white on a dark bar, black on a light one.
                    if darkBar ? color.brightnessComponent > 0.9 : color.brightnessComponent < 0.1 { glyph += 1 }
                }
            }
            #expect(glyph > 8, "the spinner's dots on a \(darkBar ? "dark" : "light") bar: \(glyph) pixels (bar \(bar))")
        }
        // Increase Contrast changes nothing on the glyph: it has no dim part.
        #expect(MenuBarArt.spinnerColor(darkBar: true) == LoomTheme.MenuBar.markRGB(darkBar: true).cgColor)
        #expect(MenuBarArt.spinnerColor(darkBar: false) == LoomTheme.MenuBar.markRGB(darkBar: false).cgColor)
    }

    @Test func increaseContrastEnlargesTheDotAndUsesAStrongerHue() {
        let theme = LoomTheme.MenuBar.self
        #expect(theme.dotDiameterIncreased == 8 && theme.dotDiameter == 7)
        for attention in [ProjectAttention.failure, .attention, .unviewed] {
            let dark = theme.dotRGB(attention, darkBar: true, increasedContrast: false)
            let darkStrong = theme.dotRGB(attention, darkBar: true, increasedContrast: true)
            let light = theme.dotRGB(attention, darkBar: false, increasedContrast: false)
            let lightStrong = theme.dotRGB(attention, darkBar: false, increasedContrast: true)
            #expect(darkStrong.luminance > dark.luminance, "lighter on a dark bar")
            #expect(lightStrong.luminance < light.luminance, "darker on a light bar")
        }
        #expect(theme.dotRGB(.attention, darkBar: false, increasedContrast: false) == LoomTheme.RGB(hex: 0xB05A00))
        #expect(theme.dotRGB(.unviewed, darkBar: false, increasedContrast: false) == LoomTheme.RGB(hex: 0x2A5FD6))
        #expect(theme.dotRGB(.failure, darkBar: false, increasedContrast: false) == LoomTheme.RGB(hex: 0xC9332E))
        #expect(theme.dotRGB(.attention, darkBar: true, increasedContrast: false) == LoomTheme.Status.attentionRGB)
    }

    // MARK: Preferences and Settings lines

    @Test func anOlderPreferencesFileReadsAsMenuBarOnAndNotifyOn() throws {
        #expect(UIPreferences().showInMenuBar && UIPreferences().notifyApprovals)
        let old = Data(#"{"sidebarWidth": 320, "projectColors": false}"#.utf8)
        let decoded = try JSONDecoder().decode(UIPreferences.self, from: old)
        #expect(decoded.showInMenuBar && decoded.notifyApprovals && !decoded.projectColors)
        var off = UIPreferences()
        off.showInMenuBar = false
        off.notifyApprovals = false
        let again = try JSONDecoder().decode(UIPreferences.self, from: JSONEncoder().encode(off))
        #expect(!again.showInMenuBar && !again.notifyApprovals)
        let odd = Data(#"{"showInMenuBar": "maybe", "notifyApprovals": 3}"#.utf8)
        let fallback = try JSONDecoder().decode(UIPreferences.self, from: odd)
        #expect(fallback.showInMenuBar && fallback.notifyApprovals)
    }

    @Test func aSettingsRowAddsALineOnlyWhereMacOSSaysSomethingIsWrong() {
        let denied = SettingsNotice.notifications(.denied)
        #expect(denied?.text == "Notifications for Sphyrna are off in System Settings, so no banner will appear.")
        #expect(denied?.buttonTitle == "Open System Settings")
        #expect(SettingsNotice.notifications(.authorized) == nil && SettingsNotice.notifications(.notDetermined) == nil)

        let approval = SettingsNotice.loginItem(.requiresApproval)
        #expect(approval?.text == "Allow Sphyrna in System Settings → General → Login Items.")
        #expect(approval?.buttonTitle == "Open Login Items")
        #expect(SettingsNotice.loginItem(.enabled) == nil && SettingsNotice.loginItem(.notRegistered) == nil
                && SettingsNotice.loginItem(.notFound) == nil)

        // The switch shows the system's state.
        #expect(LoginItemStatus.enabled.switchIsOn && LoginItemStatus.requiresApproval.switchIsOn)
        #expect(!LoginItemStatus.notRegistered.switchIsOn && !LoginItemStatus.notFound.switchIsOn)
    }
}
