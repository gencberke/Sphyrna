import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3c B, the draft page with Remora's brief row hosted in a window nobody sees (never ordered front, so nothing reaches the
/// screen): idle, reading, and drafted with the line above the composer, each read from the accessibility tree. With
/// `LOOM_DRAFT_REMORA_RENDER_DIR` set, each is drawn in Ink and Paper and written there as `draft-remora-<state>-<ink|paper>.png`
/// to be set beside the reference; without it, each is drawn once in Ink. No call is made: the states are set on the model.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(4)))
struct DraftRemoraRenderTests {
    private let size = NSSize(width: 1000, height: 820)

    private var directory: URL? {
        ProcessInfo.processInfo.environment["LOOM_DRAFT_REMORA_RENDER_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private var looks: [Bool] { directory == nil ? [true] : [true, false] }

    private func identifiers(in view: NSView) -> Set<String> {
        Set(accessibilityElements(in: view).compactMap { element in
            let id = element.accessibilityIdentifier?() ?? ""
            return id.isEmpty ? nil : id
        })
    }

    private func spoken(in view: NSView) -> [String] {
        accessibilityElements(in: view).flatMap { element -> [String] in
            [InkAX.text(element, "accessibilityLabel"), InkAX.value(element), InkAX.text(element, "accessibilityTitle")]
                .compactMap { $0 }.filter { !$0.isEmpty }
        }
    }

    /// Draws the page and returns what its tree holds; writes the picture when asked.
    /// The row's height as the tree reports it (nil without a row).
    private func rowHeight(in view: NSView) -> CGFloat? {
        accessibilityElements(in: view).first { $0.accessibilityIdentifier?() == "draft-remora" }.flatMap { $0.accessibilityFrame?() }?.height
    }

    private func render(_ model: CatalogModel, project: UUID, name: String, dark: Bool)
        async throws -> (ids: Set<String>, words: [String], rowHeight: CGFloat?) {
        enableAccessibilityTree()
        let hosting = NSHostingController(rootView: DraftSessionView(model: model, projectID: project)
            .frame(width: size.width, height: size.height)
            .background(LoomTheme.Surface.canvas)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = hosting.view
        // SwiftUI builds the accessibility tree once it is asked: ask on every pass, as Home's settle does.
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            _ = identifiers(in: view)
        }
        if let directory {
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = "draft-remora-\(name)-\(dark ? "ink" : "paper").png"
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(file))
        }
        return (identifiers(in: view), spoken(in: view), rowHeight(in: view))
    }

    private func rig() async throws -> RemoraHomeRig {
        try await RemoraHomeRig.make(
            projectNames: ["loom"],
            seeds: [.init(title: "Port the sidebar to Ink tokens", project: 0, ago: 60), .init(title: "Review the gate failure", project: 0, ago: 180),
                    .init(title: "Remora spike S10", project: 0, ago: 7_200)],
            preferences: RemoraPreferences(briefMode: .whenIAsk))
    }

    @Test func thePageDrawsItsThreeRowStates() async throws {
        let rig = try await rig()
        let model = rig.model
        let project = rig.projects[0].id
        // The rig names the project after its folder.
        let name = rig.projects[0].name
        model.showDraft(projectID: project)

        for dark in looks {
            model.remora.draft = .idle
            let idle = try await render(model, project: project, name: "idle", dark: dark)
            #expect(idle.ids.isSuperset(of: ["draft-remora", "draft-remora-draft", "draft-remora-text"]))
            #expect(!idle.ids.contains("draft-remora-origin") && !idle.ids.contains("draft-remora-stop"))
            #expect(idle.words.contains { $0.contains("Remora can write this session's brief from \(name)'s recent work.") }, "\(idle.words)")
        }

        for dark in looks {
            model.remora.draft = .reading(project: project, reading: RemoraReading(sessions: 3, projectNotes: 1, project: .init(id: project, name: name)))
            let reading = try await render(model, project: project, name: "reading", dark: dark)
            #expect(reading.ids.isSuperset(of: ["draft-remora", "draft-remora-stop"]) && !reading.ids.contains("draft-remora-draft"))
            #expect(reading.words.contains { $0.contains("Reading 3 sessions in \(name) and its note\u{2026}") }, "\(reading.words)")
            // One line high: the spinner takes its own slot, not the column's height.
            #expect((reading.rowHeight ?? .infinity) < 40, "the reading row is \(String(describing: reading.rowHeight)) high")
        }

        let brief = """
            Continue the Ink sidebar port in loom, on ui/ink-sidebar.

            Where it stands: steps 1 to 5 are done; SidebarInkTests passes.

            Next: move the footer to the Ink tokens, then run the contrast tests.

            Files: Sources/LoomCatalogUI/SidebarFooter.swift, Sources/LoomCatalogUI/LoomTheme+Sidebar.swift.

            Watch for: the Glass sidebar keeps its canvas at 0.6 over the material.
            """
        model.noteRemoraDraftClick(projectID: project, at: rig.base.addingTimeInterval(-6.2))
        model.remora.draft = .drafted(RemoraDraftedBrief(project: project, text: brief, citedSessionIDs: rig.sessions, sessionsRead: 3,
                                                         draftedAt: rig.base))
        // Lands here (with a copy that would fail the test), so the page's own landing finds nothing new.
        #expect(model.landRemoraDraft(copy: { _ in Issue.record("an empty composer copies nothing") }) == .placed)
        for dark in looks {
            let drafted = try await render(model, project: project, name: "drafted", dark: dark)
            #expect(drafted.ids.isSuperset(of: ["draft-remora", "draft-remora-again", "draft-remora-time", "draft-remora-origin",
                                                "draft-remora-sources", "draft-remora-clear"]), "\(drafted.ids.sorted())")
            #expect(drafted.words.contains { $0.contains("Remora drafted the brief above. Nothing is sent until you press \u{21B5}.") })
            #expect(drafted.words.contains { $0.contains("from 3 sessions in \(name) \u{00B7} not sent") }, "\(drafted.words)")
        }
        #expect(model.newSession.draft(for: project)?.text == brief && !model.newSession.isSending(project) && !rig.ranAProcess)
        await rig.finish()
    }

    @Test func remoraOffHasNoRowAndNoLine() async throws {
        let rig = try await rig()
        let model = rig.model
        let project = rig.projects[0].id
        model.showDraft(projectID: project)
        model.remora.draft = .drafted(RemoraDraftedBrief(project: project, text: "A brief.", citedSessionIDs: [], sessionsRead: 1,
                                                         draftedAt: rig.base))
        model.landRemoraDraft(copy: { _ in })
        model.setRemoraOn(false)
        await model.remora.settle()
        let off = try await render(model, project: project, name: "off", dark: true)
        #expect(off.ids.contains("draft-session") && off.ids.contains("draft-composer-card"), "the tree was read: \(off.ids.sorted())")
        #expect(!off.ids.contains("draft-remora") && !off.ids.contains("draft-remora-origin"), "\(off.ids.sorted())")
        await rig.finish()
    }
}
