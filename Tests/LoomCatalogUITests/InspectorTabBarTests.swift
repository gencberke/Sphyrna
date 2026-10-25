import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// The inspector's view tabs in Ink (DESIGN §6 Tabs): a 36 pt bar, and every tab shows its name, the open one as much as
/// the closed ones (the old bar showed a symbol and a count for a closed tab).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct InspectorTabBarTests {
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
