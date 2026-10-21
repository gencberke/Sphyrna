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

    @Test func theControlFamilyHasOneHeightRadiusAndFocusRing() {
        typealias S = LoomTheme.Control.Size
        #expect(S.regular.height == 26 && S.regular.radius == 6 && S.page.height == 30 && S.page.radius == 8
                && S.small.height == 22 && S.small.radius == 5)
        #expect(LoomTheme.Layout.chromeButton == CGSize(width: 26, height: 26), "an icon button is 26 pt")
        #expect(LoomTheme.Control.iconRadius == 6 && LoomTheme.Header.groupHeight == 26 && LoomTheme.Header.toggleSize == 26)
        #expect(LoomTheme.Header.groupRadius == 7 && LoomTheme.TabStrip.tabHeight == 26)
        #expect(LoomTheme.Opacity.disabled == 0.38)
        // Sphyrna's ring: 2 pt, 2 pt outside; 2.5 under Increase Contrast.
        #expect(LoomTheme.Line.focusRing(for: .standard) == 2 && LoomTheme.Line.focusRingOffset == 2
                && LoomTheme.Line.focusRing(for: .increased) == 2.5)
        // The icon button's hit area stays at least 24 x 24.
        #expect(ChromeButtonStyle.hitSize(for: LoomTheme.Layout.chromeButton) == CGSize(width: 26, height: 26))
        #expect(ChromeButtonStyle.hitSize(for: CGSize(width: 20, height: 20)) == CGSize(width: 24, height: 24))
    }

    /// The filled button's text is the on-accent colour (light text on the Ink accent is 3.0:1), also under the pointer, where the
    /// accent steps toward white in Ink and toward black in Paper.
    @Test func theFilledButtonKeepsItsContrastUnderThePointer() {
        for appearance in LoomTheme.Appearance.allCases {
            let onAccent = LoomTheme.Accent.onAccentPair[appearance]
            let rest = LoomTheme.Accent.basePair[appearance]
            let hover = LoomTheme.Control.primaryHoverPair[appearance]
            #expect(onAccent.contrast(with: rest) >= 4.5, "\(appearance) at rest")
            #expect(onAccent.contrast(with: hover) >= 4.5, "\(appearance) hovered")
            #expect(appearance == .dark ? hover.luminance > rest.luminance : hover.luminance < rest.luminance)
        }
    }

    /// The text kinds: filled on-accent, secondary with the primary text, ghost in secondary until hovered, destructive in the
    /// failure text variant (4.5:1 on its own wash), tinted in the accent's high step.
    @Test func theButtonKindsUseTheTextTheFamilyAsksFor() {
        for appearance in LoomTheme.Appearance.allCases {
            let canvas = LoomTheme.Surface.greys(appearance, tone: .neutral).canvas
            let failureWash = LoomTheme.Status.failureWashTone[appearance]
            let wash = failureWash.rgb.composited(over: canvas, opacity: failureWash.opacity)
            #expect(LoomTheme.Status.failureLightPair[appearance].contrast(with: wash) >= 4.5, "\(appearance) destructive on hover")
            let tint = LoomTheme.Accent.basePair[appearance].composited(over: canvas, opacity: LoomTheme.Opacity.accentTintPressed)
            #expect(LoomTheme.Accent.highPair[appearance].contrast(with: tint) >= 4.5, "\(appearance) tinted")
        }
        #expect(ControlButtonStyle.Kind.allCases.count == 5)
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
        #expect(abs(Double(ink.alphaComponent) - 0.075) < 0.002 && ink.redComponent > 0.99, "white 7.5 % in Ink")
        #expect(abs(Double(paper.alphaComponent) - 0.085) < 0.002 && paper.redComponent < 0.2, "the ink 8.5 % in Paper")
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
