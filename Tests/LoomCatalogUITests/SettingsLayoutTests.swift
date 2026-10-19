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
    /// The heights of the General page's text lines, top to bottom (each row is a title and its description), as the
    /// accessibility tree reports their frames.
    private func textHeights() async throws -> [CGFloat] {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-settings-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let size = NSSize(width: LoomTheme.Layout.settingsWidth,
                          height: LoomTheme.Layout.settingsHeight - LoomTheme.Layout.settingsTopHeight)
        let hosting = NSHostingController(rootView: GeneralSettings(model: model)
            .frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var texts: [NSRect] = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            texts = accessibilityElements(in: hosting.view)
                .filter { $0.accessibilityRole?() == .staticText }
                .map { $0.accessibilityFrame() }
                .sorted { $0.maxY > $1.maxY }
            if texts.count >= 6 { break }
        }
        return texts.map(\.height)
    }

    /// At 680 pt wide the description of "Sessions run in" and of "Mode of new sessions" took two lines and was cut to one
    /// with an ellipsis (a row beside a segmented control or a menu was sized from the control), while rows beside a switch
    /// showed in full. The first rows are: Sessions run in, Mode of new sessions (each a title over a two-line
    /// description), then Terminal font size (a one-line description). A description shows in full when its frame holds
    /// every line the text needs at its width.
    @Test func everyGeneralDescriptionShowsInFull() async throws {
        let heights = try await textHeights()
        try #require(heights.count >= 6, "the page's first three rows have a title and a description each")
        let line = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 11))
        // The descriptions are the second text of each row. Their widths decide the lines: the words of the first two need two.
        #expect(heights[5] < 1.5 * line, "a description that fits one line is one line high")
        #expect(heights[1] > 1.5 * line, "\"\(GeneralSettings.sessionFaceDetail.prefix(20))…\" is \(heights[1]) pt high, one line is \(line)")
        #expect(heights[3] > 1.5 * line, "\"\(GeneralSettings.startModeDetail.prefix(20))…\" is \(heights[3]) pt high, one line is \(line)")
    }
}
