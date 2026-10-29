import AppKit
import Foundation
import LoomCore
import Observation
import SwiftUI
import Testing
@testable import LoomCatalogUI

@MainActor @Observable
private final class B2ElapsedGate {
    var visible = false
    var active = false
}

private struct B2ElapsedHost: View {
    let id: UUID
    let start: Date
    let gate: B2ElapsedGate

    var body: some View {
        CardWorkingElapsed(id: id, start: start, visible: gate.visible)
            .environment(\.indicatorsAnimate, gate.active)
    }
}

@MainActor @Observable
private final class B2ScrollGate {
    var showSecond = false
}

private struct B2ScrollHost: View {
    let model: CatalogModel
    let first: SessionRowModel
    let second: SessionRowModel
    let gate: B2ScrollGate

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        SessionCardView(row: first, model: model).id(first.id)
                        Color.clear.frame(height: 600)
                        SessionCardView(row: second, model: model).id(second.id)
                    }
                }
                .onChange(of: gate.showSecond) { _, showSecond in
                    proxy.scrollTo(showSecond ? second.id : first.id, anchor: showSecond ? .bottom : .top)
                }
            }
            .environment(\.sidebarViewportSize, viewport.size)
        }
        .coordinateSpace(.named(ProjectReorderModel.viewportSpace))
        .environment(\.indicatorsAnimate, true)
    }
}

@MainActor
struct SidebarB2Tests {
    @Test func newAndMissingPreferencesUseTheLiftedSidebarWithoutChangingLegacyChoices() throws {
        #expect(UIPreferences().sidebarFill == .raised)
        let missing = try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8))
        #expect(missing.sidebarFill == .raised && missing.sidebarOpacity == .solid)
        let legacy = try JSONDecoder().decode(UIPreferences.self, from: Data("{\"sidebarStyle\":\"transparent\"}".utf8))
        #expect(legacy.sidebarFill == .canvas && legacy.sidebarOpacity == .eighty)
        let explicit = try JSONDecoder().decode(UIPreferences.self, from: Data("{\"sidebarFill\":\"deep\"}".utf8))
        #expect(explicit.sidebarFill == .deep)
    }

    @Test func sessionTitleWrapsOnceAndStopsAtTwoLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        func height(_ title: String) -> CGFloat {
            let session = ManagedSession(provider: .claude, workingDirectory: root.path)
            let record = CatalogSession(session: session, title: title, createdAt: Date(), lastUsedAt: Date(),
                                        lifecycle: .idle, pinned: false)
            let row = SessionRowModel(record: record, live: nil)
            let host = NSHostingController(rootView: SessionCardView(row: row, model: model).frame(width: 180))
            host.sizingOptions = []
            return host.sizeThatFits(in: CGSize(width: 180, height: 1_000)).height
        }
        let short = height("Short title")
        let twoLines = height("A session title that wraps over one line")
        let manyLines = height(String(repeating: "A longer session title that wraps ", count: 12))
        #expect(twoLines > short + 10, "a long title gains a second line: \(short), \(twoLines)")
        #expect(abs(manyLines - twoLines) < 2, "titles stop at two lines: \(twoLines), \(manyLines)")
    }

    @Test func searchDoorFillsTheWidthAndHasA32PointField() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let host = NSHostingController(rootView: SearchDoor(model: model).frame(width: 240))
        host.sizingOptions = []
        let size = host.sizeThatFits(in: CGSize(width: 240, height: 1_000))
        #expect(size.width == 240)
        #expect(size.height == 40, "32-point field plus its 8-point bottom gap: \(size.height)")
    }

    @Test func waitingCardExposesTheVisibleNeedsYouStatusAndItsSpecificCause() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let record = CatalogSession(session: ManagedSession(provider: .claude, workingDirectory: root.path),
                                    title: "Review", createdAt: Date(), lastUsedAt: Date(), lifecycle: .active, pinned: false)
        let live = SessionViewState(status: ProviderWorkState(activity: .waitingForApproval), runID: UUID())
        let row = SessionRowModel(record: record, live: live)
        let hosting = NSHostingController(rootView: SessionCardView(row: row, model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let labels = accessibilityElements(in: hosting.view).compactMap { $0.accessibilityLabel?() }
        #expect(labels.contains("Review, Claude, No project, Needs you, Needs approval"), "card labels: \(labels)")
    }

    @Test func statusWordsKeepExceptionalStatesPrecise() {
        #expect(CardStatus.word(.working) == "Working")
        #expect(CardStatus.word(.waitingForApproval) == "Needs you")
        #expect(CardStatus.word(.waitingForInput) == "Needs you")
        #expect(CardStatus.word(.failed("x")) == "Failed")
        #expect(CardStatus.word(.unviewedCompletion) == "Finished")
        #expect(CardStatus.word(.ready) == nil)
        #expect(CardStatus.word(.stopUnverified("x")) == "Stop not verified")
        #expect(CardStatus.word(.identityUnclear) == "Identity unclear")
        #expect(CardStatus.word(.unknown) == "State unknown")
        #expect(SubagentTreeContent.duration(from: Date(timeIntervalSince1970: 100),
                                             to: Date(timeIntervalSince1970: 137)) == "37s")
    }

    @Test func selectedSidebarCardIsNeutralAndRaisedForEveryProjectTone() throws {
        func center(selected: Bool, tone: ProjectTone, appearance: NSAppearance.Name) throws -> NSColor {
            let view = NSHostingView(rootView: Button(action: {}) {
                Color.clear.frame(width: 80, height: 40)
            }.buttonStyle(RowButtonStyle(selected: selected, radius: LoomTheme.Highlight.radius,
                                         tint: tone, sidebarCard: true)))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
            view.layoutSubtreeIfNeeded()
            let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            let scale = image.pixelsWide / 80
            return try #require(image.colorAt(x: 40 * scale, y: 20 * scale)?.usingColorSpace(.sRGB))
        }
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let rose = try center(selected: true, tone: .rose, appearance: appearance)
            let aqua = try center(selected: true, tone: .aqua, appearance: appearance)
            #expect(rose.alphaComponent > 0.95 && aqua.alphaComponent > 0.95, "selection is an opaque raised surface")
            #expect(abs(rose.redComponent - aqua.redComponent) < 0.02
                    && abs(rose.greenComponent - aqua.greenComponent) < 0.02
                    && abs(rose.blueComponent - aqua.blueComponent) < 0.02,
                    "project tone must not tint the selected card")
            let rest = try center(selected: false, tone: .rose, appearance: appearance)
            #expect(rest.alphaComponent < 0.05, "the card has no resting fill")
        }
    }

    @Test func aReadyCardDrawsContentAtItsLeadingInset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        let record = CatalogSession(session: session, title: "MMMMMMMM", createdAt: Date(), lastUsedAt: Date(),
                                    lifecycle: .active, pinned: false)
        let row = SessionRowModel(record: record, live: SessionViewState(
            status: ProviderWorkState(activity: .atPrompt), runID: UUID()))
        #expect(row.indicator == .ready)
        let view = NSHostingView(rootView: SessionCardView(row: row, model: model).frame(width: 240))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 80)
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let scale = image.pixelsWide / 240
        let hasLeadingContent = (12 * scale..<26 * scale).contains { x in
            (0..<image.pixelsHigh).contains { y in (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 }
        }
        #expect(hasLeadingContent, "the ready card must not leave the old status column empty")
    }

    @Test func viewToggleKeepsItsTwoAccessibleChoices() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        model.setViewMode(.projects)
        let hosting = NSHostingController(rootView: ViewPicker(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        func option(_ title: String) -> AnyObject? {
            accessibilityElements(in: hosting.view).first {
                $0.accessibilityRole?() == .radioButton
                    && ($0.accessibilityLabel?() ?? $0.accessibilityTitle?() ?? "") == title
            }
        }
        let activity = try #require(option("Activity"))
        #expect(activity.accessibilityPerformPress?() == true)
        #expect(model.viewMode == .activity)
        try await Task.sleep(for: .milliseconds(300))
        let projects = try #require(option("Projects"))
        #expect(projects.accessibilityPerformPress?() == true)
        #expect(model.viewMode == .projects)
    }

    @Test(.renderProbe) func elapsedClockRunsOnlyForVisibleRowsInAnActiveExpandedSidebar() async throws {
        let id = UUID(), gate = B2ElapsedGate()
        SidebarRenderProbe.watch([id])
        defer { SidebarRenderProbe.watch([]) }
        let hosting = NSHostingController(rootView: B2ElapsedHost(id: id, start: Date().addingTimeInterval(-10), gate: gate))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        defer { window.close() }
        func settle(_ rounds: Int = 5) async throws {
            for _ in 0..<rounds {
                try await Task.sleep(for: .milliseconds(250))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }

        // Hosting and layout occur offscreen. Activating the gate creates only the elapsed label's timer.
        try await settle(2)
        gate.active = true
        gate.visible = true
        try await settle(2)
        SidebarRenderProbe.reset()
        let observedFrom = ContinuousClock.now
        try await settle()
        let observed = observedFrom.duration(to: ContinuousClock.now).components
        let seconds = Double(observed.seconds) + Double(observed.attoseconds) / 1e18
        #expect(SidebarRenderProbe.timeLabelTotal > 0, "a visible working label advances")
        #expect(SidebarRenderProbe.timeLabelTotal <= Int(ceil(seconds)),
                "At most one update per second in the actual \(seconds)s window, including a partial boundary")
        #expect(SidebarRenderProbe.cardTotal == 0, "the timer never rebuilds the card")

        // Leaving the viewport cancels the task, even while the window remains active.
        gate.visible = false
        try await settle(2)
        SidebarRenderProbe.reset()
        try await settle()
        #expect(SidebarRenderProbe.timeLabelTotal == 0, "an offscreen label has no clock")

        // A collapsed sidebar or an inactive window turns off the same indicator environment.
        gate.visible = true
        gate.active = false
        try await settle(2)
        SidebarRenderProbe.reset()
        try await settle()
        #expect(SidebarRenderProbe.timeLabelTotal == 0, "an inactive or collapsed sidebar has no clock")
    }

    @Test(.renderProbe) func missingTurnStartOmitsTheElapsedClockUntilAStartIsKnown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        let record = CatalogSession(session: session, title: "Working", createdAt: Date(), lastUsedAt: Date(),
                                    lifecycle: .active, pinned: false)
        let run = UUID()
        func live(start: Date?) -> SessionViewState {
            SessionViewState(status: ProviderWorkState(activity: .working), runID: run, turnStartedAt: start)
        }
        let row = SessionRowModel(record: record, live: live(start: nil))
        SidebarRenderProbe.watch([row.id])
        defer { SidebarRenderProbe.watch([]) }
        let content = CardStatus(row: row, model: model, indicator: .working)
            .environment(\.indicatorsAnimate, true)
            .environment(\.sidebarViewportSize, CGSize(width: 240, height: 80))
            .coordinateSpace(.named(ProjectReorderModel.viewportSpace))
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 240, height: 80))
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(250))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        try await settle()
        #expect(SidebarRenderProbe.timeLabelBodies[row.id] == nil, "no start means no elapsed label or clock")
        row.apply(live: live(start: Date().addingTimeInterval(-10)))
        try await settle()
        #expect((SidebarRenderProbe.timeLabelBodies[row.id] ?? 0) > 0, "a known start creates the elapsed label")
    }

    @Test(.renderProbe) func scrollingMovesTheClockToTheActuallyVisibleWorkingCard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        func row(_ title: String) -> SessionRowModel {
            let session = ManagedSession(provider: .claude, workingDirectory: root.path)
            let record = CatalogSession(session: session, title: title, createdAt: Date(), lastUsedAt: Date(),
                                        lifecycle: .active, pinned: false)
            let live = SessionViewState(status: ProviderWorkState(activity: .working), runID: UUID(),
                                        turnStartedAt: Date().addingTimeInterval(-10))
            return SessionRowModel(record: record, live: live)
        }
        let first = row("First"), second = row("Second"), gate = B2ScrollGate()
        SidebarRenderProbe.watch([first.id, second.id])
        defer { SidebarRenderProbe.watch([]) }
        let hosting = NSHostingController(rootView: B2ScrollHost(model: model, first: first, second: second, gate: gate))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 240, height: 140))
        defer { window.close() }
        func settle(_ rounds: Int) async throws {
            for _ in 0..<rounds {
                try await Task.sleep(for: .milliseconds(250))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }

        try await settle(3)
        #expect(SidebarRenderProbe.cardBodies[first.id] != nil && SidebarRenderProbe.cardBodies[second.id] != nil,
                "both eagerly hosted cards are laid out")
        #expect(SidebarRenderProbe.timeLabelBodies[first.id] != nil && SidebarRenderProbe.timeLabelBodies[second.id] != nil,
                "both cards have working-time labels before the counters are reset")
        SidebarRenderProbe.reset()
        try await settle(6)
        #expect((SidebarRenderProbe.timeLabelBodies[first.id] ?? 0) > 0)
        #expect((SidebarRenderProbe.timeLabelBodies[second.id] ?? 0) == 0, "the offscreen card must not tick")
        #expect(SidebarRenderProbe.cardTotal == 0)

        gate.showSecond = true
        try await settle(3)
        SidebarRenderProbe.reset()
        try await settle(6)
        #expect((SidebarRenderProbe.timeLabelBodies[first.id] ?? 0) == 0, "the scrolled-away card must stop")
        #expect((SidebarRenderProbe.timeLabelBodies[second.id] ?? 0) > 0)
        #expect(SidebarRenderProbe.cardTotal == 0)
    }
}
