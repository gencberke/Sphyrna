import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// The sidebar in Ink (I3r; DESIGN §2 items 1, 3, 4 and 5, §6 Rows): the header row, the list heading's switch, the rows' and
/// cards' lines. What the views evaluate is in `SidebarRenderTests`, the pill's fills in `HighlightTests`, the selection's tint in
/// `ProjectColorUITests`, the palette that the search door opens in `PaletteTests` and `SearchFocusAndHitTests`.
extension WindowEventTests {
    @MainActor
    @Suite(.timeLimit(.minutes(2)))
    struct SidebarInkTests {
        private func model() throws -> (CatalogModel, URL) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ink-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                     preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
            return (model, root)
        }

        private func labels(in view: NSView) -> [String] {
            accessibilityElements(in: view).compactMap { $0.accessibilityLabel?() }.filter { !$0.isEmpty }
        }

        @Test func theHeaderRowHoldsTheSidebarToggleAndNoViewButtonsOrMenu() async throws {
            enableAccessibilityTree()
            let (model, root) = try model()
            defer { try? FileManager.default.removeItem(at: root) }
            let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 300, height: 500), key: true)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(400))
            let all = labels(in: hosting.view)
            #expect(all.contains("Hide sidebar"))
            for gone in ["Group by project", "Recent activity", "More actions"] {
                #expect(!all.contains(gone), "\(gone) left the header: \(all)")
            }
            // The heading owns the current view's action; the window-wide bar owns Settings and Help.
            let nodes = axTree(of: hosting.view).flattened()
            #expect(nodes.contains { $0.role == "AXButton" && [$0.label, $0.title, $0.help].contains("New Session") }, "\(all)")
            #expect(!all.contains("Settings") && !all.contains("Help"))
        }

        @Test func theListHeadingNamesTheViewAndItsSwitchChangesIt() async throws {
            enableAccessibilityTree()
            let (model, root) = try model()
            defer { try? FileManager.default.removeItem(at: root) }
            model.setViewMode(.projects)
            let (window, hosting) = host(SidebarView(model: model), size: NSSize(width: 300, height: 500), key: true)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(400))

            let tree = axTree(of: hosting.view).flattened()
            print("AXDUMP switch:", tree.filter { $0.role.contains("Radio") || $0.label == "Projects" || $0.label == "Activity" }.map(\.description))
            func heading(_ nodes: [AXNode], _ name: String) -> Bool {
                nodes.contains { $0.role == "AXHeading" && $0.label?.caseInsensitiveCompare(name) == .orderedSame }
            }
            #expect(heading(tree, "Projects"), "the heading names the view")

            // The segmented picker is exposed as radio buttons (tab buttons), one per option.
            func option(_ title: String) -> AnyObject? {
                accessibilityElements(in: hosting.view).first {
                    $0.accessibilityRole?() == .radioButton && ($0.accessibilityLabel?() ?? $0.accessibilityTitle?() ?? "") == title
                }
            }
            let activity = try #require(option("Activity"), "the switch is a two-option control")
            let projects = try #require(option("Projects"))
            #expect(activity.accessibilityPerformPress?() == true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.viewMode == .activity, "a click on a word switches the view")
            try await Task.sleep(for: .milliseconds(300))
            let again = axTree(of: hosting.view).flattened()
            #expect(heading(again, "Activity"))

            let back = try #require(option("Projects"))
            #expect(back.accessibilityPerformPress?() == true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(model.viewMode == .projects)
        }
    }
}
