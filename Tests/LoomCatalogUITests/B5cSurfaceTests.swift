import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct B5cSurfaceTests {
    private struct CardFixture: View {
        var body: some View {
            SettingsCard(holdsRows: false) { Color.clear.frame(height: 80) }
                .frame(width: 180).padding(20).background(LoomTheme.Surface.canvas)
        }
    }

    private final class HeldSearch: PaletteSources {
        private var waiter: CheckedContinuation<Void, Never>?
        func olderSessions(matching query: String) async throws -> [CatalogSession] { [] }
        func searchTranscripts(query: String, budget: PaletteSearchBudget,
                               progress: @escaping @MainActor (PaletteTranscriptOutcome) -> Void) async throws -> PaletteTranscriptOutcome {
            await withCheckedContinuation { waiter = $0 }
            return PaletteTranscriptOutcome()
        }
        func release() { waiter?.resume(); waiter = nil }
    }

    private func model() -> CatalogModel {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b5c-\(UUID()).json")
        return CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: path))
    }

    private func host<V: View>(_ view: V, size: NSSize) async throws -> (NSWindow, NSHostingView<V>) {
        enableAccessibilityTree()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(!window.isVisible && !window.isKeyWindow)
        return (window, host)
    }

    @Test func paletteRowsExposeTheFullRowAsAnAction() async throws {
        var pressed = 0
        let item = PaletteItem(id: "b5c-action", target: .action(.settings), title: "Settings", detail: nil,
                               trailing: "⌘,", indicator: nil, symbol: "gear", snippet: nil)
        let view = PaletteRow(item: item, selected: false, animates: false) { pressed += 1 }.frame(width: 320)
        let (window, host) = try await host(view, size: NSSize(width: 320, height: PaletteMetrics.rowHeight))
        defer { window.close() }
        let elements = accessibilityElements(in: host)
        let button = try #require(elements.first { $0.accessibilityRole?() == .button && InkAX.label($0).contains("Settings") })
        let frame = InkAX.frame(button)
        #expect(abs(frame.width - 320) < 1 && abs(frame.height - PaletteMetrics.rowHeight) < 1,
                "the action fills the visible row, including its padding: \(frame)")
        #expect(button.accessibilityPerformPress?() == true && pressed == 1)

    }

    @Test func remoraRowExposesTheFullRowAsAnAction() async throws {
        var pressed = 0
        let palette = PaletteState()
        let view = PaletteRemoraRow(palette: palette, busy: false, selected: false) { pressed += 1 }.frame(width: 320)
        let (window, host) = try await host(view, size: NSSize(width: 320, height: PaletteMetrics.rowHeight))
        defer { window.close() }
        let elements = accessibilityElements(in: host)
        let button = try #require(elements.first { $0.accessibilityRole?() == .button && InkAX.label($0).contains("Ask Remora") })
        let frame = InkAX.frame(button)
        #expect(abs(frame.width - 320) < 1 && abs(frame.height - PaletteMetrics.rowHeight) < 1,
                "the action fills the visible row, including its padding: \(frame)")
        #expect(button.accessibilityPerformPress?() == true && pressed == 1)
    }

    @Test func projectColorSwatchHasTheFull24PointActionTarget() async throws {
        var pressed = 0
        let items = ProjectSwatchRow.items(tone: nil, isNone: true)
        let view = HStack(spacing: LoomTheme.Host.swatchGap) {
            ForEach(items, id: \.name) { choice in
                ProjectSwatchButton(item: choice, focused: false) { pressed += 1 }
            }
        }
        let (window, host) = try await host(view, size: NSSize(width: 7 * 18 + 6 * 7, height: 24))
        defer { window.close() }
        let elements = accessibilityElements(in: host)
        let button = try #require(elements.first { InkAX.identifier($0) == "project-menu-color-none" })
        let frame = InkAX.frame(button)
        #expect(frame.width >= 24 && frame.height >= 24, "the visible swatch has a 24-point action target: \(frame)")
        #expect(button.accessibilityPerformPress?() == true && pressed == 1)
    }

    @Test func clearMemoryConfirmationUsesNoDestructiveRed() throws {
        let model = model()
        let view = RemoraClearSheet(model: model, presenter: SheetPresenter<SettingsSheet>(), returnsToMemory: false)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        var red = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { continue }
                if c.redComponent > c.greenComponent + 0.12 && c.redComponent > c.blueComponent + 0.12 { red += 1 }
            }
        }
        #expect(red < 10, "Clear is an outline action, not the Delete red (\(red) red pixels)")
    }

    @Test func searchingUsesTheSharedActivityIndicatorOnlyWhileActive() async throws {
        let model = model()
        let palette = model.palette
        let search = HeldSearch()
        palette.sourcesOverride = search
        palette.settle = .milliseconds(1)
        palette.windowProvider = { nil }
        palette.open(on: model)
        defer { palette.close(); search.release() }
        palette.setQuery("session search")
        for _ in 0..<100 where !palette.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        try #require(palette.isSearching)
        let view = PalettePanel(model: model, palette: palette, windowHeight: 500)
        let (window, host) = try await host(view, size: NSSize(width: PaletteMetrics.width, height: 420))
        defer { window.close() }
        func spinners(_ view: NSView) -> [BrailleSpinner.LayerView] {
            (view as? BrailleSpinner.LayerView).map { [$0] } ?? view.subviews.flatMap(spinners)
        }
        let indicator = try #require(spinners(host).first, "search uses the shared activity indicator")
        #expect(!indicator.isRunning, "an inactive window does not animate")
        model.setWindowActive(true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(indicator.isRunning, "an active window animates while search is held open")
        model.setWindowActive(false)
        try await Task.sleep(for: .milliseconds(120))
        #expect(!indicator.isRunning)
    }

    @Test func paletteGroupHeadingUsesUppercaseGlyphs() async throws {
        let model = model()
        let palette = model.palette
        palette.windowProvider = { nil }
        palette.open(on: model)
        defer { palette.close() }
        let (window, host) = try await host(PalettePanel(model: model, palette: palette, windowHeight: 500),
                                            size: NSSize(width: PaletteMetrics.width, height: 420))
        defer { window.close() }
        let header = try #require(accessibilityElements(in: host).first { InkAX.label($0) == "ACTIONS" })
        #expect(InkAX.text(header, "accessibilityRole") == "AXHeading")
    }

    @Test func remoraScopeUsesTheReadingFace() throws {
        func bitmap<V: View>(_ view: V) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let row = try bitmap(PaletteRemoraRow(palette: PaletteState(), busy: false, selected: false, activate: {})
            .frame(width: 320, height: PaletteMetrics.rowHeight))
        func reference(mono: Bool) throws -> NSBitmapImageRep {
            try bitmap(Text("All projects").font(.system(size: 11, design: mono ? .monospaced : .default))
                .foregroundStyle(LoomTheme.OnPopover.secondary(lit: false)).fixedSize())
        }
        func alpha(_ bitmap: NSBitmapImageRep) -> [Double] {
            (0..<bitmap.pixelsHigh).flatMap { y in
                (0..<bitmap.pixelsWide).map { x in Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) }
            }
        }
        let source = alpha(row)
        func bestError(_ sample: NSBitmapImageRep) -> Double {
            let target = alpha(sample)
            var best = Double.infinity
            for y in 0...(row.pixelsHigh - sample.pixelsHigh) {
                for x in 140...(row.pixelsWide - sample.pixelsWide) {
                    var error = 0.0
                    for dy in 0..<sample.pixelsHigh {
                        for dx in 0..<sample.pixelsWide {
                            let difference = source[(y + dy) * row.pixelsWide + x + dx] - target[dy * sample.pixelsWide + dx]
                            error += difference * difference
                        }
                    }
                    best = min(best, error / Double(sample.pixelsWide * sample.pixelsHigh))
                }
            }
            return best
        }
        let sansError = bestError(try reference(mono: false))
        let monoError = bestError(try reference(mono: true))
        print("B5C scope image error sans=\(sansError), mono=\(monoError)")
        #expect(sansError < monoError, "the human-readable scope is drawn in the reading face")
    }

    @Test func settingsCardKeepsItsPaperEdgeAndReactsToTone() async throws {
        let previous = LoomTheme.ThemeState.shared.tone
        defer { LoomTheme.ThemeState.shared.tone = previous }
        var inkCenters: [PaneTone: NSColor] = [:]
        var paperCanvases: [PaneTone: NSColor] = [:]
        for dark in [true, false] {
            let content = CardFixture()
                .environment(\.colorScheme, dark ? .dark : .light)
            let (window, host) = try await host(content, size: NSSize(width: 220, height: 120))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            defer { window.close() }
            for tone in [PaneTone.neutral, .warm, .cool] {
                LoomTheme.ThemeState.shared.tone = tone
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                func pixel(_ x: Int, _ y: Int) throws -> NSColor {
                    let px = x * rep.pixelsWide / 220, py = y * rep.pixelsHigh / 120
                    return try #require(rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
                }
                let center = try pixel(110, 60), edge = try pixel(20, 60), canvas = try pixel(5, 60)
                if dark { inkCenters[tone] = center } else {
                    paperCanvases[tone] = canvas
                    #expect(edge.redComponent < center.redComponent - 0.01, "Paper card has a visible edge: \(tone)")
                }
                if let path = ProcessInfo.processInfo.environment["LOOM_B5C_RENDER_DIR"], !path.isEmpty {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(rep.representation(using: .png, properties: [:])).write(
                        to: directory.appendingPathComponent("settings-card-\(dark ? "ink" : "paper")-\(tone.rawValue).png"))
                }
            }
        }
        let warm = try #require(inkCenters[.warm]), cool = try #require(inkCenters[.cool])
        #expect(warm.redComponent > warm.blueComponent && cool.blueComponent > cool.redComponent,
                "the existing card reacts to the observed tone while hosted")
        let neutralPaper = try #require(paperCanvases[.neutral]), warmPaper = try #require(paperCanvases[.warm])
        #expect(neutralPaper.blueComponent > warmPaper.blueComponent + 0.005)
    }
}
