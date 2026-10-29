import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

extension WindowEventTests {
/// The handle in a shown window: the real `DetailView` with a real terminal (see COMMON's window rule).
@MainActor
@Suite(.timeLimit(.minutes(3)))
struct InspectorResizeWindowTests {
    @Test func aDragResizesTheTerminalOnceOnRelease() async throws {
        let rig = try await InspectorRig.make(hosted: true)
        defer { rig.cleanup() }
        rig.model.select(rig.ids[0])
        rig.model.toggleInspector()
        await rig.settle()
        let spy = rig.spies[0]
        let before = (grids: spy.sizes.count, sizes: spy.laidOutSizes.count)
        let width = try #require(spy.laidOutSizes.last).width
        for step in 1...20 {
            rig.model.dragInspectorEdge(by: CGFloat(-5 * step), from: 328, range: 280...500)
            if step % 5 == 0 { await rig.settle() }
        }
        #expect(spy.sizes.count == before.grids && spy.laidOutSizes.count == before.sizes,
                "the terminal was resized while dragging: \(spy.laidOutSizes.suffix(4))")
        rig.model.endInspectorDrag()
        await rig.settle()
        #expect(spy.laidOutSizes.count == before.sizes + 1, "\(spy.laidOutSizes.suffix(4))")
        #expect(spy.sizes.count <= before.grids + 1)
        #expect(spy.laidOutSizes.last?.width == width - 100)
    }

    @Test func theHandleIsAThinStripAtTheLeadingEdgeClearOfTheTabs() async throws {
        enableAccessibilityTree()
        let rig = try await InspectorRig.make(hosted: true)
        defer { rig.cleanup() }
        rig.model.select(rig.ids[0])
        rig.model.toggleInspector()
        await rig.settle()
        let elements = accessibilityElements(in: try #require(rig.window.contentView))
        func frame(_ id: String) -> CGRect? {
            elements.first { $0.accessibilityIdentifier?() == id }?.accessibilityFrame?()
        }
        let handle = try #require(frame("inspector-resize-handle"))
        let inspector = try #require(frame("inspector"))
        #expect(abs(handle.width - LoomTheme.Inspector.resizeHandleWidth) < 0.5)
        #expect(abs(handle.minX - inspector.minX) < 0.5 && abs(handle.height - inspector.height) < 0.5)
        let tabs = elements.filter { ($0.accessibilityLabel?() ?? "") == "Overview" }.compactMap { $0.accessibilityFrame?() }
        #expect(!tabs.isEmpty && tabs.allSatisfy { !$0.intersects(handle) }, "the handle covers no tab")
        #expect(rig.labels().contains("Inspector width"))
    }
}
}
