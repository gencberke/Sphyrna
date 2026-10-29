import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// Settings pages in the window's fixed size, hosted in a window nobody sees (never ordered front).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SettingsLayoutTests {
    /// The frames of the General page's static texts as the accessibility tree reports them, by their text. The page is a scrolling
    /// section under the 52 pt band now, with a capital label over each card: the texts are found by what they say, not by their place.
    private func textFrames() async throws -> [String: NSRect] {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-settings-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let size = NSSize(width: LoomTheme.Settings.width, height: LoomTheme.Settings.height - LoomTheme.Settings.bandHeight)
        let hosting = NSHostingController(rootView: GeneralSettings(model: model, sheets: SheetPresenter<SettingsSheet>())
            .frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var frames: [String: NSRect] = [:]
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            frames = [:]
            for element in accessibilityElements(in: hosting.view) where element.accessibilityRole?() == .staticText {
                let text = InkAX.value(element) ?? InkAX.label(element)
                if !text.isEmpty { frames[text] = element.accessibilityFrame() }
            }
            if frames[GeneralSettings.startModeDetail] != nil, frames["Applies to existing and new terminals."] != nil { break }
        }
        return frames
    }

    /// D-88, the reference's drawing: a card's rows sit 16 in from its leading edge, so a row's text starts 32 inside the card, 64
    /// from the window's edge under the page's 32. It started 16 inside the card before.
    @Test func aRowsTextStartsThirtyTwoInsideItsCard() async throws {
        let frames = try await textFrames()
        // The first row since the Chat face was frozen (D-100) is "Mode of new sessions".
        let title = try #require(frames["Mode of new sessions"])
        let S = LoomTheme.Settings.self
        #expect(S.rowsInsetLeading + S.rowPaddingH == 32 && S.rowsInsetTrailing + S.rowPaddingH == 24)
        #expect(abs(title.minX - (S.bodyInset + S.rowsInsetLeading + S.rowPaddingH)) <= 1, "the title starts at \(title.minX)")
    }

    /// A card of rows keeps 5 above its rows and 6 below them; Usage's cards lay out their own content and take no inset.
    @Test func aCardOfRowsKeepsFiveAboveAndSixBelowAndUsagesCardsKeepTheirOwn() {
        let S = LoomTheme.Settings.self
        func height<V: View>(_ view: V) -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: 616))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let rows = height(SettingsCard { SettingsRow(title: "One") { EmptyView() } })
        #expect(abs(rows - (S.rowMinHeight + S.rowsInsetTop + S.rowsInsetBottom)) <= 0.5, "\(rows)")
        let own = height(SettingsCard(holdsRows: false) { Color.clear.frame(height: 40) })
        #expect(abs(own - 40) <= 0.5, "\(own)")
    }

    /// The reference's verticals: a line of help is exactly 17, so a row with two lines of help is 11 + 18 + 2 + 34 + 11 = 76 (it was
    /// 78: the face's own line is 15, not the 14.1 its ascender and descender give, and the spacing was worked out from the
    /// latter); and a group's label is a 10.5 line 8 above its card (it took its face's own, taller line).
    @Test func twoLinesOfHelpMakeASeventySixRowAndTheCardSitsEighteenAndAHalfUnderItsLabel() {
        let S = LoomTheme.Settings.self
        func height<V: View>(_ view: V) -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: 592))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let row = SettingsRow(title: "Sessions run in", detail: GeneralSettings.sessionFaceDetail) { EmptyView() }
        #expect(abs(height(row) - (2 * S.rowPaddingV + S.rowTitleLine + S.helpTop + 2 * S.rowHelpLine)) <= 0.5, "\(height(row))")
        let label = height(SettingsGroup(label: "Sessions") { row }) - height(SettingsCard { row })
        #expect(abs(label - (S.labelLine + S.labelBottom)) <= 0.5, "\(label)")
        #expect(S.glyphDrop(size: S.rowHelp.size, lineHeight: S.rowHelpLine) == 1)
    }

    /// A sheet's facts are an exact line box: 12.5 on 18.75, under a 12 pt top, so one line is 30.75 high and two are 49.5, whatever
    /// the face's own line would have given.
    @Test func aSheetTextIsItsTopAndAWholeExactLineForEachLine() {
        let Sheet = LoomTheme.Sheet.self
        func height<V: View>(_ view: V) -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: 592))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let one = height(SheetText(text: "One short line"))
        #expect(abs(one - (Sheet.textTop + Sheet.textLine)) <= 0.5, "\(one)")
        let two = height(SheetText(text: "One short line\nAnother short line"))
        #expect(abs(two - (Sheet.textTop + 2 * Sheet.textLine)) <= 0.5, "\(two)")
    }

    /// The rest of Settings' family text sits on the theme's exact line too: one more line makes the view exactly one line token taller,
    /// in the sheet's title and subject and its list's items, and in a page state's text.
    @Test func everyFamilyTextGrowsByExactlyOneLine() {
        let Sheet = LoomTheme.Sheet.self
        let S = LoomTheme.Settings.self
        func height<V: View>(_ view: V, width: CGFloat) -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: width))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        func lines(_ count: Int) -> String { (1...count).map { "Line \($0)" }.joined(separator: "\n") }

        let title = height(InkSheet(title: lines(4), cancel: {}, actions: []) { EmptyView() }, width: Sheet.width)
            - height(InkSheet(title: lines(3), cancel: {}, actions: []) { EmptyView() }, width: Sheet.width)
        #expect(abs(title - Sheet.titleLine) <= 0.5, "\(title)")

        // The subject is cut at two lines, so it can only grow from one to two.
        let subject = height(InkSheet(title: "A question", subject: lines(2), cancel: {}, actions: []) { EmptyView() },
                             width: Sheet.width)
            - height(InkSheet(title: "A question", subject: lines(1), cancel: {}, actions: []) { EmptyView() },
                     width: Sheet.width)
        #expect(abs(subject - Sheet.subjectLine) <= 0.5, "\(subject)")

        let item = height(SheetList(label: "Removed", items: [lines(5)]), width: Sheet.width)
            - height(SheetList(label: "Removed", items: [lines(4)]), width: Sheet.width)
        #expect(abs(item - Sheet.textLine) <= 0.5, "\(item)")

        let note = height(SettingsNote(title: "Nothing yet", text: lines(5)), width: 592)
            - height(SettingsNote(title: "Nothing yet", text: lines(4)), width: 592)
        #expect(abs(note - S.noteLine) <= 0.5, "\(note)")
    }

    /// A list's label sits on the reference's 10.5 line: the list's 14 pt top, that line and its 6 pt bottom, then the first item's
    /// exact line. A second item adds the item gap and its line.
    @Test func aSheetListsLabelSitsOnItsOwnLine() {
        let Sheet = LoomTheme.Sheet.self
        func height<V: View>(_ view: V) -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: Sheet.width))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let one = height(SheetList(label: "Removed", items: ["One short line"]))
        // The host lays each line out on whole points: the 10.5 label line is 11 high and the 18.75 item line 19.
        let expected = Sheet.listTop + Sheet.labelLine.rounded(.up) + Sheet.labelBottom + Sheet.textLine.rounded(.up)
        #expect(abs(one - expected) <= 0.5, "\(one)")
        let two = height(SheetList(label: "Removed", items: ["One short line", "Another short line"]))
        #expect(abs(two - (one + Sheet.itemGap + Sheet.textLine)) <= 0.5, "\(two)")
    }

    /// At 680 pt wide the description of "Sessions run in" and of "Mode of new sessions" took two lines and was cut to one
    /// with an ellipsis (a row beside a segmented control or a menu was sized from the control), while rows beside a switch
    /// showed in full. A description is at most 380 wide now (the reference's), so the first two take two lines or more and
    /// "Applies to existing and new terminals." one. A description shows in full when its frame holds every line the text
    /// needs at its width.
    @Test func everyGeneralDescriptionShowsInFull() async throws {
        let frames = try await textFrames()
        #expect(frames[GeneralSettings.sessionFaceDetail] == nil, "no Sessions run in row while the Chat face is frozen (D-100)")
        let mode = try #require(frames[GeneralSettings.startModeDetail], "the second row's description is on the page")
        let font = try #require(frames["Applies to existing and new terminals."], "the third row's description is on the page")
        let line = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: LoomTheme.InkType.small.size))
        #expect(font.height < 1.5 * line, "a description that fits one line is one line high")
        #expect(mode.height > 1.5 * line, "\"\(GeneralSettings.startModeDetail.prefix(20))…\" is \(mode.height) pt high, one line is \(line)")
        #expect(mode.width <= LoomTheme.Settings.helpMaxWidth + 1, "a description is at most \(LoomTheme.Settings.helpMaxWidth) wide")
    }
}
