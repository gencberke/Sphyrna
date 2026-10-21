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
