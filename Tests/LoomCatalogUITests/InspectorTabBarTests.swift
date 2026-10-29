import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// The inspector's view tabs in Ink (DESIGN §6 Tabs): a 36 pt bar, and every tab shows its name, the open one as much as
/// the closed ones (the old bar showed a symbol and a count for a closed tab).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct InspectorTabBarTests {
    /// The Settings and project tab bar's actual accessibility frames, in a window never ordered on screen.
    private func offscreenViewTabFrames() async throws -> (bar: CGRect, tab: CGRect, size: NSSize) {
        enableAccessibilityTree()
        let tabs = [ViewTabItem(id: "overview", title: "Overview", identifier: "test-view-tab", hoverKey: "test-view-tab")]
        let size = NSSize(width: 300, height: LoomTheme.ViewTabs.barHeight)
        let root = ViewTabs(tabs: tabs, selection: "overview", onSelect: { _ in })
            .frame(width: size.width, height: size.height)
            .accessibilityElement(children: .contain).accessibilityIdentifier("test-view-tab-bar")
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(!window.isVisible)
        let elements = accessibilityElements(in: host)
        let bar = try #require(elements.first { $0.accessibilityIdentifier?() == "test-view-tab-bar" }?.accessibilityFrame?())
        let tab = try #require(elements.first { $0.accessibilityIdentifier?() == "test-view-tab" }?.accessibilityFrame?())
        print("VIEW-TABS-OFFSCREEN bar=\(bar) tab=\(tab) host=\(host.frame) visible=\(window.isVisible)")
        return (bar, tab, size)
    }

    /// The halo stays within the bar vertically, including while drawn (the forced-focus probe runs this same test).
    @Test func theOffscreenViewTabsStayInsideTheirBar() async throws {
        let (bar, tab, size) = try await offscreenViewTabFrames()
        #expect(abs(bar.height - size.height) < 0.5)
        #expect(tab.minY >= bar.minY - 0.5 && tab.maxY <= bar.maxY + 0.5)
    }

    /// Without keyboard focus, an invisible halo must not expand the bar's accessibility frame sideways.
    @Test func unfocusedViewTabsKeepTheirBarWidth() async throws {
        let (bar, _, size) = try await offscreenViewTabFrames()
        #expect(abs(bar.width - size.width) < 0.5, "bar width \(bar.width), expected \(size.width)")
    }

    private func fitting(_ model: CatalogModel) -> CGSize {
        let host = NSHostingView(rootView: InspectorTabBar(model: model).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: LoomTheme.Rhythm.inspectorWidth, height: 80)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func theBarIsThirtySixHighAndEveryTabShowsItsName() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        let model = rig.model
        model.readOnlyChatEnabled = true // the Side tab is the frozen Chat face's (D-100)
        model.select(rig.ids[0])
        #expect(model.inspectorTabs == InspectorTab.allCases, "a Claude session with a conversation id has all four tabs")
        #expect(LoomTheme.Inspector.tabBarHeight == 36)

        // The bar is as wide as its labels and gaps need, whichever tab is open: the closed tabs show their names too.
        let face = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let names = InspectorTab.allCases.map { InspectorTabBar.title($0) }
        let text = names.reduce(0) { $0 + ($1 as NSString).size(withAttributes: [.font: face]).width }
        let gaps = LoomTheme.Inspector.tabGap * CGFloat(names.count - 1) + 2 * LoomTheme.Inspector.tabBarInset
        for tab in InspectorTab.allCases {
            model.selectInspectorTab(tab)
            let size = fitting(model)
            #expect(size.height == 36, "the bar is \(size.height) high with \(tab) open")
            #expect(size.width >= text + gaps - 1, "the bar is \(size.width) wide with \(tab) open; the names and gaps take \(text + gaps)")
        }
    }
}
