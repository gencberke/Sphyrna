import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

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
            if frames[GeneralSettings.sessionFaceDetail] != nil, frames["Applies to existing and new terminals."] != nil { break }
        }
        return frames
    }

    /// D-88, the reference's drawing: a card's rows sit 16 in from its leading edge, so a row's text starts 32 inside the card, 64
    /// from the window's edge under the page's 32. It started 16 inside the card before.
    @Test func aRowsTextStartsThirtyTwoInsideItsCard() async throws {
        let frames = try await textFrames()
        let title = try #require(frames["Sessions run in"])
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

    /// At 680 pt wide the description of "Sessions run in" and of "Mode of new sessions" took two lines and was cut to one
    /// with an ellipsis (a row beside a segmented control or a menu was sized from the control), while rows beside a switch
    /// showed in full. A description is at most 380 wide now (the reference's), so the first two take two lines or more and
    /// "Applies to existing and new terminals." one. A description shows in full when its frame holds every line the text
    /// needs at its width.
    @Test func everyGeneralDescriptionShowsInFull() async throws {
        let frames = try await textFrames()
        let face = try #require(frames[GeneralSettings.sessionFaceDetail], "the first row's description is on the page")
        let mode = try #require(frames[GeneralSettings.startModeDetail], "the second row's description is on the page")
        let font = try #require(frames["Applies to existing and new terminals."], "the third row's description is on the page")
        let line = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: LoomTheme.InkType.small.size))
        #expect(font.height < 1.5 * line, "a description that fits one line is one line high")
        #expect(face.height > 1.5 * line, "\"\(GeneralSettings.sessionFaceDetail.prefix(20))…\" is \(face.height) pt high, one line is \(line)")
        #expect(mode.height > 1.5 * line, "\"\(GeneralSettings.startModeDetail.prefix(20))…\" is \(mode.height) pt high, one line is \(line)")
        #expect(face.width <= LoomTheme.Settings.helpMaxWidth + 1, "a description is at most \(LoomTheme.Settings.helpMaxWidth) wide")
    }
}
