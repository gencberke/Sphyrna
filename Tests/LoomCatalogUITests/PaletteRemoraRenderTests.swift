import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3c, part A: the palette with Ask Remora drawn in a window nobody sees (never ordered front), in Ink and Paper: the list with the
/// row heading it, and the answer with its chip. With `LOOM_PALETTE_RENDER_DIR` set the pictures are written there as
/// `palette-remora-<typing|answer>-<ink|paper>.png`, to be set beside the reference's ⌘K document; without it the test only checks
/// that the panel drew and that the answer stands where the list was. The fake provider answers: no Claude, no profile, no vault.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct PaletteRemoraRenderTests {
    private let size = NSSize(width: 760, height: 560)

    private var directory: URL? {
        ProcessInfo.processInfo.environment["LOOM_PALETTE_RENDER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private func render(_ model: CatalogModel, name: String, dark: Bool) async throws -> (NSBitmapImageRep, [String]) {
        let panel = PalettePanel(model: model, palette: model.palette, windowHeight: size.height)
            .padding(.top, PaletteMetrics.topInset / 2)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(LoomTheme.Surface.canvas)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let ids = accessibilityElements(in: hosting.view).compactMap { element -> String? in
            let id = element.accessibilityIdentifier?() ?? ""
            return id.isEmpty ? nil : id
        }
        let bounds = hosting.view.bounds
        let rep = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.view.cacheDisplay(in: bounds, to: rep)
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("palette-remora-\(name)-\(dark ? "ink" : "paper").png"))
        }
        return (rep, ids)
    }

    @Test func theRowAndTheAnswerDrawInInkAndPaper() async throws {
        enableAccessibilityTree()
        let rig = try await RemoraHomeRig.make(
            projectNames: ["loom", "backend-api"],
            seeds: [.init(title: "Migrate auth to JWT", project: 1, ago: 20_000), .init(title: "Port the sidebar to Ink tokens", project: 0, ago: 3_600)],
            preferences: RemoraPreferences(briefMode: .whenIAsk),
            scriptFor: { sessions in
                let id = sessions[0].uuidString
                return ["LOOM_FAKE_REMORA_ANSWER": "**Migrate auth to JWT** moved the token check into `middleware/auth.py` yesterday at 22:40; nothing in loom touched it.\n\n```remora\n{\"cited\":[\"\(id)\"],\"chips\":[{\"session\":\"\(id)\",\"why\":\"Moved the token check\"}],\"drafts\":[],\"facts\":[]}\n```\n"]
            })
        defer { Task { await rig.finish() } }
        let palette = rig.model.palette
        palette.windowProvider = { nil }
        palette.open(on: rig.model)
        defer { palette.close() }
        palette.setQuery("which session touched the auth middleware?")

        for dark in [true, false] {
            let (_, ids) = try await render(rig.model, name: "typing", dark: dark)
            #expect(ids.contains("palette-remora-ask"), "\(ids)")
        }

        #expect(palette.handleRemoraKey(.return))
        await rig.model.remora.settle()
        await palette.remoraReads?.read(model: rig.model)
        for dark in [true, false] {
            let (rep, ids) = try await render(rig.model, name: "answer", dark: dark)
            #expect(rep.pixelsWide >= Int(size.width))
            #expect(ids.contains("palette-remora-answer") && ids.contains("palette-remora-answer-text"), "\(ids)")
            #expect(ids.contains("home-remora-chip"), "the chip is Home's: \(ids)")
            #expect(!ids.contains("palette-remora-ask"), "the answer takes the list's place")
            #expect(ids.contains("palette-remora-footer"))
        }
    }
}
