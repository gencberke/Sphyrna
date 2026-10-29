import Foundation
import AppKit
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

@MainActor
private func spinnerViews(in view: NSView) -> [BrailleSpinner.LayerView] {
    (view as? BrailleSpinner.LayerView).map { [$0] } ?? view.subviews.flatMap(spinnerViews(in:))
}

@MainActor
struct SidebarStatusTests {
    /// The wiring, not the predicate: a real hosting view in a real window.
    @Test func hostedWorkingIndicatorRunsOnlyWhenTheEnvironmentAllowsIt() async throws {
        func running(animate: Bool) async throws -> Bool {
            let view = IndicatorView(indicator: .working)
                .environment(\.indicatorsAnimate, animate)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            // The spinner view exists, in the window, once SwiftUI has laid the hosting view out; how long that takes
            // depends on the load, so wait for it. Its animation is installed in the same pass that puts it there.
            var found: BrailleSpinner.LayerView?
            for _ in 0..<500 where found?.window == nil {
                try await Task.sleep(for: .milliseconds(20))
                found = spinnerViews(in: hosting).first
            }
            let spinner = try #require(found)
            #expect(spinner.window != nil, "the spinner view never reached the window")
            if animate {
                for _ in 0..<500 where !spinner.isRunning { try await Task.sleep(for: .milliseconds(20)) }
                return spinner.isRunning
            }
            // Not running must hold, not only at the first look.
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(20))
                if spinner.isRunning { return true }
            }
            return false
        }
        #expect(try await running(animate: true))
        #expect(!(try await running(animate: false)))
    }

    @Test(.timeLimit(.minutes(1)))
    func realSidebarRunsAWorkingRowOnlyForAnActiveWindowAndExpandedSidebar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        try await catalog.insertSession(session, title: "Busy", lifecycle: .idle)
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait()
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        model.apply(try #require(await iterator.next()))
        await hub.publish(sessionID: session.id, change: .runStarted(UUID()))
        await hub.publish(sessionID: session.id, change: .status(ProviderWorkState(activity: .working)))
        model.apply(try #require(await iterator.next()))
        let row = try #require(model.list(for: .activity).rows.first)
        #expect(row.indicator == .working)

        let hosting = NSHostingController(rootView: SidebarView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 300, height: 400))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func running() async throws -> Bool {
            try await Task.sleep(for: .milliseconds(400))
            return spinnerViews(in: hosting.view).contains { $0.isRunning }
        }
        #expect(!(try await running()), "inactive window must be static")
        model.setWindowActive(true)
        #expect(try await running(), "active window with an expanded sidebar must animate")
        model.setSidebarCollapsed(true)
        #expect(!(try await running()), "collapsed sidebar must be static")
        model.setSidebarCollapsed(false)
        #expect(try await running())
        model.setWindowActive(false)
        #expect(!(try await running()), "deactivated window must be static again")
    }
}
