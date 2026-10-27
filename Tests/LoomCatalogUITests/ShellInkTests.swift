import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// The session window's shell in Ink (I2a; DESIGN §2 item 2, §6 Header, Tabs, Controls, Iconography and Terminal framing):
/// the harness marks, the control family, the divider, the flush terminal and the one canvas around the main pane. The
/// header's and the tab row's own rules are in `SessionHeaderTests` and `ConversationTabStripTests`, the project mark's in
/// `ProjectColorUITests`.
@MainActor
struct ShellInkTests {
    // MARK: Harness marks

    /// Codex is the ChatGPT knot as a template image tinted with primary text; a bundle without that file (the packaging scripts
    /// copy only `harness-codex.png` today) falls back to the old file. Claude keeps its own clay; the synthetic has no file.
    @Test func codexIsTheTemplateWhenTheBundleHasItAndTheOldFileWhenItDoesNot() {
        let withTemplate = ProviderImages.asset(for: .codex, exists: { _ in true })
        #expect(withTemplate?.name == "harness-codex-template" && withTemplate?.template == true)
        let without = ProviderImages.asset(for: .codex, exists: { $0 != "harness-codex-template" })
        #expect(without?.name == "harness-codex" && without?.template == false)
        for exists in [true, false] {
            let claude = ProviderImages.asset(for: .claude, exists: { _ in exists })
            #expect(claude?.name == "harness-claude" && claude?.template == false, "the spark is never tinted")
        }
        #expect(ProviderImages.asset(for: .synthetic, exists: { _ in true }) == nil)
    }

    @Test func theHarnessMarkSizesAreInks() {
        #expect(LoomTheme.Layout.harnessMarkRow == 12 && LoomTheme.Layout.harnessMarkHeader == 13
                && LoomTheme.Layout.harnessMarkMenu == 14)
        #expect(LoomTheme.Layout.providerIconHeader == 13, "the header's mark")
        #expect(ProviderIcon(provider: .claude).size == 12, "rows, cards and tabs by default")
    }

    // MARK: The control family

    @Test func theIconButtonIsTwentyEightAndKeepsItsHitArea() {
        #expect(LoomTheme.Layout.chromeButton == CGSize(width: 28, height: 28), "an icon button is 28 pt")
        #expect(LoomTheme.Control.iconRadius == 8 && LoomTheme.Header.groupHeight == 26 )
        #expect(LoomTheme.Header.groupRadius == 7 && LoomTheme.TabStrip.tabHeight == 26)
        #expect(LoomTheme.Opacity.disabled == 0.38)
        // Sphyrna's hand-drawn rings keep their 2 pt line; a control's ring is checked in ControlFamilyTests.
        #expect(LoomTheme.Line.focusRing(for: .standard) == 2 && LoomTheme.Line.focusRingOffset == 2
                && LoomTheme.Line.focusRing(for: .increased) == 2.5)
        // The icon button's hit area stays at least 24 x 24.
        #expect(ChromeButtonStyle.hitSize(for: LoomTheme.Layout.chromeButton) == CGSize(width: 28, height: 28))
        #expect(ChromeButtonStyle.hitSize(for: CGSize(width: 20, height: 20)) == CGSize(width: 24, height: 24))
    }

    // MARK: The canvas

    /// DESIGN §2 item 2: the divider between the sidebar and the main pane is the canvas's hairline.
    @Test func theDividerIsTheCanvasHairline() {
        let color = LoomTheme.Shell.dividerColor
        func resolved(_ name: NSAppearance.Name) -> NSColor {
            var result = NSColor.clear
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
            return result
        }
        let ink = resolved(.darkAqua), paper = resolved(.aqua)
        #expect(abs(Double(ink.alphaComponent) - 0.07) < 0.002 && ink.redComponent > 0.99, "white 7 % in Ink")
        #expect(paper.alphaComponent > 0.99 && abs(paper.redComponent - 229.0 / 255.0) < 0.01, "the solid #E5E5E5 in Paper")
    }

    /// FB6-1: the divider's 1 pt gap is painted with the opaque canvas under the hairline, so a clear window behind the split
    /// view never shows the desktop through it. The hairline alone was 7.5 % opaque; the canvas under it is what fills the gap.
    @Test func theDividerPaintsAnOpaqueRectUnderItsHairline() throws {
        let split = CanvasSplitView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        split.appearance = NSAppearance(named: .darkAqua)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 40).fill()
        split.drawDivider(in: NSRect(x: 3, y: 0, width: 1, height: 40))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let inside = try #require(rep.colorAt(x: 3, y: 20)?.usingColorSpace(.sRGB))
        let outside = try #require(rep.colorAt(x: 6, y: 20)?.usingColorSpace(.sRGB))
        #expect(inside.alphaComponent == 1, "the canvas fills the divider's rect before the hairline draws over it")
        #expect(outside.alphaComponent == 0, "and only inside the divider's rect")
    }

    /// Flush on the canvas (A6): the terminal's text keeps 16 pt around it, 20 at the leading edge, and nothing else.
    @Test func theTerminalSitsFlushWithItsInset() {
        let terminal = NSView()
        let container = TerminalContainerView(terminal: terminal)
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        container.layoutSubtreeIfNeeded()
        #expect(terminal.frame == NSRect(x: 20, y: 16, width: 600 - 20 - 16, height: 400 - 32))
        #expect(LoomTheme.Space.terminalLeadingInset == 20 && LoomTheme.Space.terminalInset == 16)
    }

    /// No panel inset, no border, no radius and no second background around the main pane: every pixel along the pane's edges
    /// is the canvas, where the Night Fleece panel drew its 8 pt backdrop and a hairline stroke inside it.
    @Test func theMainPaneIsTheCanvasAllTheWayToItsEdges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-shell-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        defer { model.stop() }
        let host = NSHostingView(rootView: DetailView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.isReleasedWhenClosed = false
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = rep.pixelsWide / 800
        let corner = try #require(rep.colorAt(x: 2 * scale, y: 2 * scale)?.usingColorSpace(.sRGB))
        // Along the left edge and the bottom edge, 0 to 20 pt in: the Night Fleece panel put its hairline at 8 pt.
        var worst = 0.0
        for offset in 0..<20 {
            for (x, y) in [(offset * scale, 300 * scale), (400 * scale, rep.pixelsHigh - 1 - offset * scale)] {
                let pixel = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                worst = max(worst, abs(Double(pixel.redComponent - corner.redComponent)))
            }
        }
        #expect(worst < 0.01, "no hairline or backdrop near the pane's edges: \(worst)")
    }

    /// The main window's split view puts the sidebar beside the main pane. A split view set in place of the controller's
    /// own starts horizontal, which stacked the sidebar above the pane (seen in batch B's first screenshots).
    @MainActor @Test func theCanvasSplitViewSetsTheSidebarBesideThePane() {
        let split = CanvasSplitView()
        #expect(split.isVertical)
        #expect(split.dividerStyle == .thin)
    }
}
