import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// W1-b: the inspector's leading edge drags, with a remembered width per class (narrow, side, review). A drag moves only its
/// guide; the release changes the class's width once, so the content (a terminal, a Chat stream) takes its new width once.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct InspectorResizeTests {
    private func openRig() async throws -> InspectorRig {
        let rig = try await InspectorRig.make()
        rig.model.readOnlyChatEnabled = true // the Side tab is the frozen Chat face's (D-100)
        rig.model.select(rig.ids[0])
        rig.model.setInspector(open: true, for: rig.ids[0])
        return rig
    }

    /// A whole drag, as the handle makes it: from the drawn width to `target`, in steps, then the release.
    private func drag(_ rig: InspectorRig, to target: CGFloat, pane: CGFloat, steps: Int = 6) {
        let from = rig.model.inspectorLayout(detailWidth: pane).inspectorWidth
        let range = rig.model.inspectorResizeRange(detailWidth: pane)
        for step in 1...steps {
            rig.model.dragInspectorEdge(by: (from - target) * CGFloat(step) / CGFloat(steps), from: from, range: range)
        }
        rig.model.endInspectorDrag()
    }

    private func storedWidths(_ rig: InspectorRig) -> InspectorWidths {
        UIPreferencesStore(url: rig.root.appendingPathComponent("prefs.json")).current.inspectorWidths
    }

    @Test func aDragChangesTheContentsWidthOnceOnReleaseAndWritesOnce() async throws {
        let rig = try await openRig()
        defer { rig.cleanup() }
        let pane: CGFloat = 1_100
        let range = rig.model.inspectorResizeRange(detailWidth: pane)
        #expect(range == 280...620, "the narrow class's floor, and what leaves the content 480 pt")
        var contentWidths = [rig.model.inspectorLayout(detailWidth: pane).contentWidth]
        func record() {
            let width = rig.model.inspectorLayout(detailWidth: pane).contentWidth
            if contentWidths.last != width { contentWidths.append(width) }
        }
        for step in 1...24 {
            rig.model.dragInspectorEdge(by: CGFloat(-5 * step), from: 328, range: range)
            record()
            #expect(rig.model.inspector.resize?.live == CGFloat(328 + 5 * step), "the guide follows the pointer")
        }
        // A live resize would have handed the content a new width on each of the 24 steps (24 PTY resizes, 24 re-measures).
        #expect(contentWidths == [772], "the content kept its width while dragging: \(contentWidths)")
        #expect(rig.model.shownInspectorWidth == 328)
        #expect(storedWidths(rig)[.narrow] == 328, "nothing is written while dragging")

        rig.model.endInspectorDrag()
        record()
        #expect(contentWidths == [772, 652], "one change, on release")
        #expect(rig.model.inspector.resize == nil)
        #expect(rig.model.shownInspectorWidth == 448)
        #expect(storedWidths(rig)[.narrow] == 448, "the release is written")

        // A drag that ends where it started writes and resizes nothing.
        rig.model.dragInspectorEdge(by: 30, from: 448, range: range)
        rig.model.dragInspectorEdge(by: 0, from: 448, range: range)
        rig.model.endInspectorDrag()
        record()
        #expect(contentWidths == [772, 652])
    }

    @Test func eachClassKeepsItsOwnWidth() async throws {
        let rig = try await openRig()
        defer { rig.cleanup() }
        let model = rig.model
        let pane: CGFloat = 1_300
        try #require(model.inspectorTabs.contains(.side))
        #expect(model.shownInspectorWidth == 328)
        drag(rig, to: 300, pane: pane)
        model.selectInspectorTab(.changes)
        #expect(model.shownInspectorWidth == 556, "Changes keeps its default")
        drag(rig, to: 640, pane: pane)
        model.selectInspectorTab(.side)
        #expect(model.shownInspectorWidth == 392, "Side keeps its default")
        drag(rig, to: 430, pane: pane)
        model.selectInspectorTab(.agents)
        #expect(model.shownInspectorWidth == 300, "the Agents list is the narrow class, as Overview")

        // Overview → Changes → Side → Overview shows each class's width; they survive a relaunch.
        for (tab, width) in [(InspectorTab.overview, 300.0), (.changes, 640), (.side, 430), (.overview, 300)] {
            model.selectInspectorTab(tab)
            #expect(model.shownInspectorWidth == CGFloat(width), "\(tab)")
        }
        let stored = storedWidths(rig)
        #expect(stored[.narrow] == 300 && stored[.side] == 430 && stored[.review] == 640)
        #expect(InspectorState(open: [], widths: stored).widths == model.inspector.widths)
    }

    @Test func aDragStopsAtTheClassMinimumAndAtTheContentsFourHundredEighty() async throws {
        let rig = try await openRig()
        defer { rig.cleanup() }
        let model = rig.model
        drag(rig, to: 10, pane: 1_100)
        #expect(model.shownInspectorWidth == 280, "the narrow class's floor")
        drag(rig, to: 2_000, pane: 1_100)
        #expect(model.shownInspectorWidth == 620)
        #expect(model.inspectorLayout(detailWidth: 1_100).contentWidth == 480)
        model.selectInspectorTab(.changes)
        drag(rig, to: 10, pane: 1_100)
        #expect(model.shownInspectorWidth == 440, "the review class's floor")

        // A wider window lets review grow; a smaller one shows it clamped as a column and keeps what is stored.
        drag(rig, to: 760, pane: 1_400)
        #expect(model.shownInspectorWidth == 760)
        let clamped = model.inspectorLayout(detailWidth: 1_100)
        #expect(clamped.placement == .column && clamped.inspectorWidth == 620 && clamped.contentWidth == 480)
        #expect(model.inspector.widths[.review] == 760 && storedWidths(rig)[.review] == 760)
        // Narrower than the default needs: the overlay rule of D-78 still holds, at the stored width but never wider than the pane.
        let overlaid = model.inspectorLayout(detailWidth: 900)
        #expect(overlaid.placement == .overlay && overlaid.inspectorWidth == 760 && overlaid.contentWidth == 900)
        #expect(model.inspectorLayout(detailWidth: 600).inspectorWidth == 600)
        // A dragged-narrower class stays a column where its default would be overlaid.
        model.selectInspectorTab(.overview)
        drag(rig, to: 280, pane: 1_100)
        #expect(model.inspectorLayout(detailWidth: 770).placement == .column)
        // An overlaid inspector covers the content, which keeps its width: a drag there may reach the pane's.
        model.selectInspectorTab(.changes)
        #expect(model.inspectorResizeRange(detailWidth: 900) == 440...900)
    }

    @Test func theDefaultsLayTheInspectorOutAsBefore() async throws {
        let rig = try await openRig()
        defer { rig.cleanup() }
        for (tab, width) in [(InspectorTab.overview, 328.0), (.changes, 556), (.side, 392)] {
            rig.model.selectInspectorTab(tab)
            for pane: CGFloat in [464, 808, 900, 1_036, 1_084, 1_300] {
                // D-78's rule: a column while the content keeps 480 pt beside the tab's width, else an overlay no wider than the pane.
                let column = pane - CGFloat(width) >= 480
                let layout = rig.model.inspectorLayout(detailWidth: pane)
                #expect(layout.placement == (column ? .column : .overlay), "\(tab) in \(pane)")
                #expect(layout.inspectorWidth == min(CGFloat(width), pane))
                #expect(layout.contentWidth == (column ? pane - CGFloat(width) : pane))
            }
        }
    }

    @Test func aDoubleClickResetsTheShownClassOnly() async throws {
        let rig = try await openRig()
        defer { rig.cleanup() }
        let model = rig.model
        drag(rig, to: 400, pane: 1_100)
        model.selectInspectorTab(.changes)
        drag(rig, to: 600, pane: 1_100)
        model.resetInspectorWidth()
        #expect(model.shownInspectorWidth == 556)
        model.selectInspectorTab(.overview)
        #expect(model.shownInspectorWidth == 400, "the other class keeps its width")
        model.resetInspectorWidth()
        #expect(model.shownInspectorWidth == 328)
        #expect(storedWidths(rig) == InspectorWidths())
    }

    @Test func theAdjustableActionStepsInsideTheRange() async throws {
        let rig = try await openRig()
        defer { rig.cleanup() }
        let range = rig.model.inspectorResizeRange(detailWidth: 1_100)
        rig.model.stepInspectorWidth(by: LoomTheme.Inspector.resizeStep, from: 328, range: range)
        #expect(rig.model.shownInspectorWidth == 344)
        rig.model.stepInspectorWidth(by: -100, from: 344, range: range)
        #expect(rig.model.shownInspectorWidth == 280)
    }

    @Test func theWidthsRoundTripAndAnOlderFileReadsTheDefaults() throws {
        var widths = InspectorWidths()
        widths[.narrow] = 360
        widths[.side] = 100
        widths[.review] = .nan
        #expect(widths[.narrow] == 360 && widths[.side] == 280 && widths[.review] == 556, "floored, and a non-finite one is the default")
        widths[.review] = 700.4
        let preferences = UIPreferences(inspectorWidths: widths)
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(UIPreferences.self, from: data) == preferences)

        let old = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"inspectorOpen": []}"#.utf8))
        #expect(old.inspectorWidths == InspectorWidths())
        let partial = try JSONDecoder().decode(UIPreferences.self, from: Data(
            #"{"inspectorWidths": {"review": "wide", "side": 120, "narrow": 400}}"#.utf8))
        #expect(partial.inspectorWidths[.review] == 556 && partial.inspectorWidths[.side] == 280
                && partial.inspectorWidths[.narrow] == 400)
        let unreadable = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"inspectorWidths": 3}"#.utf8))
        #expect(unreadable.inspectorWidths == InspectorWidths())

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-inspector-widths-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("prefs.json")
        try UIPreferencesStore(url: url).update { $0.inspectorWidths = widths }
        #expect(UIPreferencesStore(url: url).current.inspectorWidths[.review] == 700)
    }
}
