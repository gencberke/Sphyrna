import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

// Nested in ModelPickerTests' serialized suite: both host draft popovers in borderless windows, one at a time.
extension ModelPickerTests {
/// Controlled offscreen checks of the actual draft and Home controls. No provider is started.
@MainActor @Suite(.serialized) struct B5aSurfaceTests {
    private func host<V: View>(_ content: V, size: CGSize, dark: Bool = false) -> (NSWindow, NSView, NSView, InkHost) {
        let ink = InkHost()
        let root = content.frame(width: size.width, height: size.height)
            .background(LoomTheme.Surface.canvas)
            .environment(\.colorScheme, dark ? .dark : .light)
            .inkHost(ink)
        let hosting = NSHostingView(rootView: root)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = container.bounds
        container.addSubview(hosting)
        ink.view.frame = container.bounds
        container.addSubview(ink.view)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = container
        return (window, hosting, container, ink)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func element(_ id: String, in view: NSView) throws -> AnyObject {
        try #require(accessibilityElements(in: view).first { InkAX.identifier($0) == id }, "Missing \(id)")
    }

    private func frame(_ element: AnyObject, in window: NSWindow) -> CGRect {
        let screen = InkAX.frame(element)
        return CGRect(x: screen.minX - window.frame.minX, y: window.frame.height - (screen.maxY - window.frame.minY),
                      width: screen.width, height: screen.height)
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }

    private func picture(_ view: NSView, name: String, dark: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment["LOOM_B5A_RENDER_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try bitmap(view)
        try #require(image.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("b5a-\(name)-\(dark ? "ink" : "paper")-fixture.png"))
    }

    private func color(_ image: NSBitmapImageRep, at point: CGPoint, view: NSView) throws -> NSColor {
        let scale = CGFloat(image.pixelsWide) / view.bounds.width
        return try #require(image.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
    }

    private func assertPaperEdge(_ image: NSBitmapImageRep, rect: CGRect, view: NSView) throws {
        let edge = try color(image, at: CGPoint(x: rect.midX, y: rect.minY + 0.5), view: view)
        let inside = try color(image, at: CGPoint(x: rect.midX, y: rect.minY + 3.5), view: view)
        #expect(inside.redComponent - edge.redComponent > 0.025, "Paper needs a visible hairline: \(edge), \(inside)")
    }

    private func assertNeutralSend(_ image: NSBitmapImageRep, rect: CGRect, view: NSView) throws {
        let fill = try color(image, at: CGPoint(x: rect.minX + 6, y: rect.midY), view: view)
        let expected = LoomTheme.Control.defaultFillPair.light
        #expect(abs(fill.redComponent - CGFloat(expected.red)) < 0.05 && abs(fill.greenComponent - CGFloat(expected.green)) < 0.05
                && abs(fill.blueComponent - CGFloat(expected.blue)) < 0.05, "The ready action is neutral: \(fill)")
    }

    private func assertComposerCorner(_ image: NSBitmapImageRep, rect: CGRect, view: NSView) throws {
        let corner = try color(image, at: CGPoint(x: rect.minX + 5.25, y: rect.minY + 4.75), view: view)
        let canvas = try color(image, at: CGPoint(x: rect.minX - 4, y: rect.minY - 4), view: view)
        #expect(corner.redComponent - canvas.redComponent > 0.04, "The draft card's 16 pt corner: \(corner), \(canvas)")
    }

    @Test func draftUsesTheV4ControlsAndPreservesTheirActions() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b5a-draft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let intents = NewSessionRig.DraftIntents()
        model.intents = intents
        defer { model.stop(); withExtendedLifetime(intents) {} }
        let project = UUID()
        model.showDraft(projectID: project)
        model.newSession.setBranch(.named("main"), for: project)
        model.setDraftText("Start this work", projectID: project)
        model.newSession.addPreset(NewSessionPreset(name: "Review", message: "Review this work", projectID: project))
        let (window, view, container, ink) = host(DraftSessionView(model: model, projectID: project),
                                                   size: CGSize(width: 1000, height: 820))
        defer { ink.state.dismiss(); window.close() }
        try await settle(window)
        #expect(!window.isVisible && model.canSendDraft(projectID: project))
        let card = try element("draft-composer-card", in: view)
        let send = try element("draft-send", in: view)
        let branch = try element("draft-branch-new-branch", in: view)
        let preset = try element("draft-preset", in: view)
        #expect(abs(InkAX.frame(send).width - 32) < 1 && abs(InkAX.frame(send).height - 32) < 1)
        #expect(abs(InkAX.frame(branch).height - 28) < 1)
        #expect(abs(InkAX.frame(preset).height - 28) < 1)
        #expect(abs(InkAX.frame(try element("draft-model", in: view)).height - 28) < 1)
        #expect(abs(InkAX.frame(try element("draft-effort", in: view)).height - 28) < 1)
        let image = try bitmap(container)
        try assertPaperEdge(image, rect: frame(card, in: window), view: container)
        try assertNeutralSend(image, rect: frame(send, in: window), view: container)
        do {
            let (darkWindow, darkView, darkContainer, darkInk) = host(NewSessionComposer(model: model, projectID: project).frame(width: 640),
                                                                         size: CGSize(width: 720, height: 260), dark: true)
            defer { darkInk.state.dismiss(); darkWindow.close() }
            try await settle(darkWindow)
            let darkCard = try element("draft-composer-card", in: darkView)
            try assertComposerCorner(bitmap(darkContainer), rect: frame(darkCard, in: darkWindow), view: darkContainer)
        }

        model.newSession.setBranch(.unavailable, for: project)
        try await settle(window)
        #expect(try element("draft-branch-new-branch", in: view).isAccessibilityEnabled?() == false)
        model.newSession.setBranch(.named("main"), for: project)
        try await settle(window)
        #expect(try element("draft-branch-new-branch", in: view).accessibilityPerformPress?() == true)
        try await settle(window)
        #expect(model.newSession.draft(for: project)?.branchKind == .newBranch && ink.state.active?.id == "draft-branch-name")
        ink.state.dismiss()
        model.setDraftBranch(.stay, projectID: project)
        model.setDraftText("", projectID: project)
        try await settle(window)
        #expect(try element("draft-send", in: view).isAccessibilityEnabled?() == false)
        #expect(preset.accessibilityPerformPress?() == true)
        try await settle(window)
        #expect(model.newSession.draft(for: project)?.text == "Review this work")
        let ready = try element("draft-send", in: view)
        #expect(ready.isAccessibilityEnabled?() == true && ready.accessibilityPerformPress?() == true)
        #expect(intents.sends.count == 1 && intents.sends[0].launch.firstMessage == "Review this work")
    }

    @Test func remoraFieldAndSessionChipUseTheSharedControlFamily() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b5a-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        defer { model.stop() }
        let ui = HomeRemoraUI()
        ui.text = "What changed?"
        let reads = HomeRemoraReads(baselineUndo: nil)
        let context = HomeRemoraContext(state: .whenIAsk, brief: nil, tiles: [], readingFrames: 0,
                                        further: [], quiet: [], pickedUp: 0, now: Date())
        let session = HomeRemoraSession(id: UUID(), projectID: UUID(), projectName: "Project", tone: .orchid,
                                        provider: .claude, title: "Review the change", lastActivityAt: Date(), indicator: .idle)
        var opened = false
        let content = VStack(spacing: 24) {
            HomeRemoraFieldBlock(model: model, ui: ui, reads: reads, context: context, topGap: 0).frame(width: 680)
            HomeRemoraChip(model: model, session: session, open: { opened = true })
        }
        let (window, view, container, ink) = host(content, size: CGSize(width: 900, height: 300))
        defer { ink.state.dismiss(); window.close() }
        try await settle(window)
        let field = try element("home-remora-field-bar", in: view)
        let scope = try element("home-remora-scope", in: view)
        let send = try element("home-remora-send", in: view)
        let chip = try element("home-remora-chip", in: view)
        #expect(abs(InkAX.frame(scope).height - 28) < 1)
        #expect(abs(InkAX.frame(send).width - 32) < 1 && abs(InkAX.frame(send).height - 32) < 1)
        #expect(abs(InkAX.frame(chip).height - 28) < 1)
        let image = try bitmap(container)
        try assertPaperEdge(image, rect: frame(field, in: window), view: container)
        try assertNeutralSend(image, rect: frame(send, in: window), view: container)
        #expect(scope.accessibilityPerformPress?() == true)
        try await settle(window)
        #expect(ink.state.active?.id == "home-remora-scope" && ui.text == "What changed?")
        ink.state.dismiss()
        #expect(chip.accessibilityPerformPress?() == true && opened)
        ui.text = ""
        try await settle(window)
        #expect(try element("home-remora-send", in: view).isAccessibilityEnabled?() == false)
        #expect(!window.isVisible)
    }

    @Test func proseMetadataUsesSansWhilePathsAndTimesRemainMono() {
        #expect(!LoomTheme.Home.connectWord.mono && !LoomTheme.Home.sideNote.mono)
        #expect(!LoomTheme.ProjectPage.cardNote.mono && LoomTheme.ProjectPage.path.mono && LoomTheme.ProjectPage.rowTime.mono)
        #expect(!LoomTheme.Draft.note.mono && !LoomTheme.Draft.originDetail.mono && LoomTheme.Draft.folder.mono)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOM_B5A_RENDER_DIR"] != nil))
    func theThreePagesRenderInBothAppearancesWithoutAProvider() async throws {
        enableAccessibilityTree()
        let seeds: [RemoraHomeRig.Seed] = [.init(title: "Review the branch", project: 0, ago: 180),
                                           .init(title: "Run the checks", project: 0, ago: 3600)]
        let preferences = RemoraPreferences(briefMode: .whenIAsk)
        let rig = try await RemoraHomeRig.make(
            projectNames: ["demo"], seeds: seeds, preferences: preferences, withHost: false)
        defer { Task { await rig.finish() } }
        let model = rig.model
        let intents = NewSessionRig.DraftIntents()
        model.intents = intents
        let project = rig.projects[0].id
        model.newSession.addPreset(NewSessionPreset(name: "Review the branch", message: "Review the branch", projectID: project))
        model.newSession.addPreset(NewSessionPreset(name: "Explain this folder", message: "Explain this folder"))
        for dark in [true, false] {
            model.showHome()
            do {
                let (window, view, container, ink) = host(HomeView(model: model), size: CGSize(width: 1000, height: 820), dark: dark)
                defer { ink.state.dismiss(); window.close() }
                try await settle(window)
                #expect(!window.isVisible && accessibilityElements(in: view).contains { InkAX.identifier($0) == "home" })
                try picture(container, name: "home", dark: dark)
            }
            do {
                let (window, view, container, ink) = host(ProjectPageView(model: model, projectID: project),
                                                           size: CGSize(width: 1000, height: 820), dark: dark)
                defer { ink.state.dismiss(); window.close() }
                try await settle(window)
                #expect(!window.isVisible && accessibilityElements(in: view).contains { InkAX.identifier($0) == "project-page" })
                try picture(container, name: "project", dark: dark)
            }
            model.showDraft(projectID: project)
            model.setDraftText("Review the branch and run the checks.", projectID: project)
            do {
                let (window, view, container, ink) = host(DraftSessionView(model: model, projectID: project),
                                                           size: CGSize(width: 1000, height: 820), dark: dark)
                defer { ink.state.dismiss(); window.close() }
                try await settle(window)
                #expect(!window.isVisible && accessibilityElements(in: view).contains { InkAX.identifier($0) == "draft-model" })
                try picture(container, name: "draft", dark: dark)
            }
        }
        // A held reading state shows Remora's face, date, body place and field without asking a model.
        rig.makeHost(seeds: seeds, preferences: preferences, script: [:], now: rig.base)
        model.remora.phase = .briefing
        model.remora.reading = RemoraReading(sessions: 2, projectNotes: 1)
        defer { model.remora.phase = .idle }
        let ui = HomeRemoraUI()
        ui.text = "What changed?"
        let reads = HomeRemoraReads(baselineUndo: nil)
        for dark in [true, false] {
            let section = HomeRemoraSection(model: model, paneWidth: 1000, ui: ui, reads: reads)
            let (window, view, container, ink) = host(section, size: CGSize(width: 1000, height: 820), dark: dark)
            defer { ink.state.dismiss(); window.close() }
            try await settle(window)
            #expect(!window.isVisible && accessibilityElements(in: view).contains { InkAX.identifier($0) == "home-remora-heading" })
            try picture(container, name: "remora", dark: dark)
        }
        #expect(intents.sends.isEmpty && intents.plainStarts == 0 && !rig.ranAProcess)
        withExtendedLifetime(intents) {}
    }
}
}
