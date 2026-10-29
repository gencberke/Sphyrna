import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// The project name on a session card belongs to the activity view and never to the project view,
/// whichever view a card was first drawn in. The same card ids exist in both views, so the real
/// sidebar is hosted in a window that is never ordered front and switched between the views.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionCardProjectLabelTests {
    @Test func labelDecisionFollowsTheViewMode() {
        #expect(SessionCardView.projectLabel(mode: .activity, name: "rocket") == "rocket")
        #expect(SessionCardView.projectLabel(mode: .projects, name: "rocket") == nil)
        #expect(SessionCardView.projectLabel(mode: .activity, name: nil) == nil)
        #expect(SessionCardView.repeatsProject(mode: .activity))
        #expect(!SessionCardView.repeatsProject(mode: .projects))
    }

    private func fixture() async throws -> (CatalogModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        let folder = root.appendingPathComponent("edd-backend", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        // No title: the default title names the project only where the card repeats it.
        for _ in 0..<2 {
            try await catalog.insertSession(ManagedSession(provider: .claude, workingDirectory: folder.path),
                                            title: nil, lifecycle: .idle, projectID: project.id)
        }
        try await catalog.insertSession(ManagedSession(provider: .claude, workingDirectory: root.path),
                                        title: nil, lifecycle: .idle)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait()
        await model.settle()
        return (model, root)
    }

    /// The cards' accessibility labels carry the default title, which is the project-repeating one
    /// ("Claude · edd-backend") or the plain one ("Claude session"), chosen in the same evaluation
    /// as the label on the card's second row.
    private func cardLabels(in view: NSView) -> [String] {
        accessibilityElements(in: view).compactMap { $0.accessibilityLabel?() }.filter { $0.hasPrefix("Claude") }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    @Test(arguments: [CatalogViewMode.projects, .activity])
    func cardsFollowTheViewModeWhicheverViewDrewThemFirst(first: CatalogViewMode) async throws {
        enableAccessibilityTree()
        let (model, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setViewMode(first)
        await model.settle()
        let hosting = NSHostingController(rootView: SidebarView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 300, height: 600))
        // Never ordered front: the layout runs against a window nobody sees. ARC owns it.
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let second: CatalogViewMode = first == .projects ? .activity : .projects
        for (step, mode) in [first, second, first, second].enumerated() {
            if step > 0 {
                model.setViewMode(mode)
                await model.settle()
            }
            try await settle(window)
            let seen = cardLabels(in: hosting.view)
            #expect(seen.count == 3, "all three cards are laid out in \(mode), step \(step)")
            for label in seen {
                switch mode {
                case .activity: #expect(label.hasPrefix("Claude · "), "step \(step), activity: \(label)")
                case .projects: #expect(label.hasPrefix("Claude session"), "step \(step), projects: \(label)")
                }
            }
        }
    }
}
