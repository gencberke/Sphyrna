import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// I5's spike, the art hosted in a window nobody sees (never ordered front), in Ink and Paper: each shark of the cast, Home's
/// band and the new-session page's pair with the whale shark below. With `LOOM_ART_RENDER_DIR` set the pictures are written
/// there as `art-<name>-<ink|paper>.png`, to be set beside the reference's school document; without it the test only checks
/// that the art drew. And the art is hidden from VoiceOver.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ArtRenderTests {
    private var directory: URL? {
        ProcessInfo.processInfo.environment["LOOM_ART_RENDER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private func host<Content: View>(_ content: Content, size: CGSize, dark: Bool) -> (NSWindow, NSHostingController<AnyView>) {
        let root = AnyView(content.frame(width: size.width, height: size.height)
            .background(LoomTheme.Surface.canvas)
            .environment(\.colorScheme, dark ? .dark : .light))
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        return (window, hosting)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// Renders `content` and returns how many pixels stand clear of the canvas (the art, not the faint grid).
    @discardableResult
    private func render<Content: View>(_ content: Content, name: String, size: CGSize, dark: Bool) async throws -> Int {
        let (window, hosting) = host(content, size: size, dark: dark)
        defer { window.close() }
        try await settle(window)
        let bounds = hosting.view.bounds
        let rep = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.view.cacheDisplay(in: bounds, to: rep)
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("art-\(name)-\(dark ? "ink" : "paper").png"))
        }
        let base = try #require(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        var lit = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let d = max(abs(c.redComponent - base.redComponent), abs(c.greenComponent - base.greenComponent),
                            abs(c.blueComponent - base.blueComponent))
                if d > 20.0 / 255 { lit += 1 }
            }
        }
        return lit
    }

    private static let draftScene = ArtScene.sea(specs: ArtScenes.draft,
                                                 options: .init(alpha: LoomTheme.Art.draftAlpha, plankton: 26, wake: true), seed: 3)

    @Test func theCastHomesBandAndTheNewSessionPageDrawInInkAndPaper() async throws {
        for dark in [true, false] {
            for kind in ArtKind.allCases {
                let scene = ArtScene.sea(specs: ArtScenes.inPlace(kind, length: ArtScenes.castLength[kind] ?? 200),
                                         options: .init(alpha: LoomTheme.Art.inPlaceAlpha, plankton: 0, wake: false), seed: 5)
                let lit = try await render(ArtSurface(scene: scene, cell: LoomTheme.Art.castCell, kind: .inPlace, time: 1.5),
                                           name: "cast-\(kind.rawValue)", size: CGSize(width: 420, height: 240), dark: dark)
                #expect(lit > 100, "\(kind) \(dark): \(lit)")
            }
            for t in [20.0, 45.0] {
                let band = ArtBackdrop(scene: .homeLoop(precomputed: false, seed: 1), cell: LoomTheme.Art.bandCell, kind: .homeLoop,
                                       mask: .band, grid: .band, time: t)
                let lit = try await render(band, name: "band-\(Int(t))s", size: ArtEngineTests.band, dark: dark)
                #expect(lit > 100, "band \(t) \(dark): \(lit)")
            }
            let draft = ArtBackdrop(scene: Self.draftScene, cell: LoomTheme.Art.ambientCell, kind: .ambient, mask: .calm, grid: .radial,
                                    time: 30)
            let lit = try await render(draft, name: "draft", size: ArtEngineTests.draft, dark: dark)
            #expect(lit > 200, "draft \(dark): \(lit)")
        }
    }

    @Test func theFontHasEveryGlyph() {
        for cell in [LoomTheme.Art.ambientCell, LoomTheme.Art.inPlaceCell, LoomTheme.Art.castCell] {
            #expect(ArtPainter(cell: cell).missingCodes.isEmpty)
        }
    }

    @Test func theArtIsHiddenFromVoiceOver() async throws {
        enableAccessibilityTree()
        let page = ZStack {
            ArtBackdrop(scene: Self.draftScene, cell: LoomTheme.Art.ambientCell, kind: .ambient, mask: .calm)
            Text("Probe").accessibilityIdentifier("art-probe")
        }
        let (window, hosting) = host(page, size: CGSize(width: 600, height: 400), dark: true)
        defer { window.close() }
        try await settle(window)
        func arts(in view: NSView) -> [ArtLayerView] { (view as? ArtLayerView).map { [$0] } ?? view.subviews.flatMap(arts(in:)) }
        let art = try #require(arts(in: hosting.view).first, "the art is drawn")
        #expect(!art.isAccessibilityElement())
        #expect((art.accessibilityChildren() ?? []).isEmpty)
        let elements = accessibilityElements(in: hosting.view)
        let ids = elements.compactMap { $0.accessibilityIdentifier?() }
        #expect(ids.contains("art-probe"), "the tree was read: \(ids)")
        #expect(!elements.contains { $0 is ArtLayerView })
        #expect(!elements.contains { ($0.accessibilityRole?() ?? nil) == .image }, "no image for the art")
        let labelled = elements.filter { element in
            let label = element.accessibilityLabel?() ?? ""
            return !label.isEmpty && label != "Probe"
        }
        #expect(labelled.isEmpty, "\(labelled.map { $0.accessibilityLabel?() ?? "" })")
    }
}
