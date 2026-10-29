import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// V09 in a window: the real `DetailView` hosted offscreen with a real terminal view per session. They share
/// the app's windows with the other window tests, so they run one at a time (`WindowEventTests`).
extension WindowEventTests {
@MainActor
@Suite(.timeLimit(.minutes(3)))
struct InspectorWindowTests {
    /// The grid changes (each asks for a PTY resize) and the laid-out sizes of each session's terminal so far.
    private func counts(_ rig: InspectorRig) -> (grids: [Int], sizes: [Int]) {
        (rig.spies.map { $0.sizes.count }, rig.spies.map { $0.laidOutSizes.count })
    }

    @Test func theTerminalResizesOncePerToggleAndNeverOnASelectionChange() async throws {
        let rig = try await InspectorRig.make(hosted: true)
        defer { rig.cleanup() }
        let (a, b) = (rig.ids[0], rig.ids[1])
        // Both terminals have been laid out once, with the inspector closed.
        rig.model.select(b)
        await rig.settle()
        rig.model.select(a)
        await rig.settle()
        var before = counts(rig)
        let wide = rig.spies[0].surface.gridSize.columns

        // The user's toggle: one change of the grid and one of the size, on the selected terminal only.
        rig.model.toggleInspector()
        await rig.settle()
        var after = counts(rig)
        #expect(after.grids == [before.grids[0] + 1, before.grids[1]], "grid changes \(rig.spies.map(\.sizes))")
        #expect(after.sizes == [before.sizes[0] + 1, before.sizes[1]], "sizes \(rig.spies.map(\.laidOutSizes))")
        let narrow = rig.spies[0].surface.gridSize.columns
        #expect(narrow < wide)

        // Selection changes, both ways and repeated, move nothing: a closed session keeps its width, an open
        // one its own.
        before = counts(rig)
        for id in [b, a, b, a, b] {
            rig.model.select(id)
            await rig.settle()
        }
        after = counts(rig)
        #expect(after.grids == before.grids, "a selection change resized a terminal: \(rig.spies.map(\.sizes))")
        #expect(after.sizes == before.sizes, "a selection change resized a terminal: \(rig.spies.map(\.laidOutSizes))")
        #expect(rig.spies[1].surface.gridSize.columns == wide)
        rig.model.select(a)
        await rig.settle()
        #expect(rig.spies[0].surface.gridSize.columns == narrow)
        #expect(rig.model.inspector.openSessions == [a], "a selection change never wrote the inspector's state")

        // Closing is one more resize.
        before = counts(rig)
        rig.model.toggleInspector()
        await rig.settle()
        after = counts(rig)
        #expect(after.grids == [before.grids[0] + 1, before.grids[1]])
        #expect(rig.spies[0].surface.gridSize.columns == wide)
        #expect(rig.model.inspector.openSessions.isEmpty)
    }

    @Test func theInspectorSlidesNowhere() async throws {
        let rig = try await InspectorRig.make(hosted: true)
        defer { rig.cleanup() }
        rig.model.select(rig.ids[0])
        await rig.settle()
        let before = rig.spies[0].laidOutSizes.count
        rig.model.toggleInspector()
        await rig.settle()
        // An animated column would hand the terminal a size per frame on its way from 1100 to 772 points (the pane is
        // flush since Ink: no panel margin around the terminal).
        #expect(Array(rig.spies[0].laidOutSizes.dropFirst(before)).map(\.width) == [772])
    }

    @Test func switchingBetweenSessionsWithTheirInspectorsOpenResizesNothing() async throws {
        let rig = try await InspectorRig.make(hosted: true)
        defer { rig.cleanup() }
        let (a, b) = (rig.ids[0], rig.ids[1])
        rig.model.select(a)
        rig.model.toggleInspector()
        await rig.settle()
        rig.model.select(b)
        rig.model.toggleInspector()
        await rig.settle()
        let before = counts(rig)
        for id in [a, b, a, b] {
            rig.model.select(id)
            await rig.settle()
        }
        let after = counts(rig)
        #expect(after.grids == before.grids && after.sizes == before.sizes)
        #expect(rig.model.inspector.openSessions == [a, b])
    }

    @Test func aSubagentClickOpensTheInspectorWithOneResizeAndLeavesTheTerminalOnScreen() async throws {
        enableAccessibilityTree()
        let rig = try await InspectorRig.make(hosted: true)
        defer { rig.cleanup() }
        let (a, b) = (rig.ids[0], rig.ids[1])
        await rig.goLive(1, [inspectorRecord()])
        rig.model.select(a)
        await rig.settle()
        rig.model.select(b)
        await rig.settle()
        let before = counts(rig)

        rig.model.openSubagent("a1", in: b)
        await rig.settle()
        let after = counts(rig)
        #expect(after.grids == [before.grids[0], before.grids[1] + 1], "grid changes \(rig.spies.map(\.sizes))")
        #expect(after.sizes == [before.sizes[0], before.sizes[1] + 1])
        #expect(rig.spies[1].surface.view.window != nil, "the terminal is still on screen")
        #expect(rig.model.detailRoute == .terminal(sessionID: b))
        let labels = rig.labels()
        #expect(!labels.contains("Back to the session"), "the old back control is gone")
        #expect(labels.contains("Back to the list of agents"), "labels \(labels)")
        #expect(rig.model.inspector.tab == .agents)

        // The back control returns to the list, which keeps 328 while a transcript takes 556 (D-78): the terminal takes
        // the width back in one resize, and the other session's terminal does not move.
        rig.model.closeSubagent()
        await rig.settle()
        #expect(counts(rig).grids == [after.grids[0], after.grids[1] + 1], "grid changes \(rig.spies.map(\.sizes))")
    }

    @Test func theHeaderToggleOpensTheAgentsTabWithTheSubagentsListed() async throws {
        enableAccessibilityTree()
        let rig = try await InspectorRig.make(hosted: true)
        defer { rig.cleanup() }
        let b = rig.ids[1]
        await rig.goLive(1, [inspectorRecord(), inspectorRecord("a2", running: false, type: "Explore", description: "find handlers")])
        rig.model.select(b)
        await rig.settle()
        #expect(!rig.model.inspector.isOpen(for: b))
        #expect(rig.labels().contains("Show inspector") && !rig.labels().contains("Hide inspector"))

        // The header button does what the menu item does.
        let content = try #require(rig.window.contentView)
        let found = accessibilityElements(in: content).first { $0.accessibilityLabel?() == "Show inspector" }
        let button = try #require(found)
        #expect(button.accessibilityPerformPress?() == true)
        await rig.settle()
        #expect(rig.model.inspector.isOpen(for: b))
        #expect(rig.labels().contains("Hide inspector"))

        rig.model.selectInspectorTab(.agents)
        await rig.settle()
        let labels = rig.labels()
        // Each row names the agent and its harness, never the brief (D-114).
        #expect(labels.contains { $0.hasPrefix("implementer, Claude, Running") }, "labels \(labels)")
        #expect(labels.contains { $0.hasPrefix("Explore, Claude, Finished") }, "labels \(labels)")
        #expect(!labels.contains { $0.contains("map the module") || $0.contains("find handlers") }, "labels \(labels)")
        #expect(labels.contains("Agents, 2") || labels.contains("Agents"), "labels \(labels)")
    }

    @Test func theOverviewDrawsTheContextRingAndNamesOnlyTheSelectedSession() async throws {
        enableAccessibilityTree()
        let rig = try await InspectorRig.make(hosted: true)
        defer { rig.cleanup() }
        let (a, b) = (rig.ids[0], rig.ids[1])
        let index = ContextFakeIndex()
        index.set(["conv-0": SessionContextSample(
            model: "claude-opus-5-5", timestamp: inspectorT0,
            tokens: UsageTokens(input: 4_000, output: 1_500, cacheWrite5m: 200, cacheRead: 80_000))])
        let usage = UsageModel(index: index, clock: { Date() }, timeZone: TimeZone(identifier: "UTC")!,
                               debounce: .milliseconds(20), activationCooldown: .zero)
        rig.model.usage = usage
        rig.model.select(a)
        await rig.settle()
        await usage.settle()
        // The header's model segment shows the context of the selected terminal session, inspector or not (fix round 3 F).
        #expect(index.lookups.last == ["conv-0"] && usage.contexts["conv-0"]?.tokens == 84_200)

        rig.model.toggleInspector()
        await rig.settle()
        await usage.settle()
        await rig.settle()
        #expect(index.lookups.last == ["conv-0"])
        #expect(usage.contexts["conv-0"]?.tokens == 84_200)
        let labels = rig.labels()
        #expect(labels.contains("Overview"), "labels \(labels)")
        #expect(labels.contains { $0.hasPrefix("Context, 84") }, "labels \(labels)")

        // Only the selected session is named: another one has no reading in the index, and the first loses its entry.
        rig.model.select(b)
        await rig.settle()
        await usage.settle()
        #expect(usage.contexts.isEmpty)
        #expect(index.lookups.last == ["conv-1"])
        // A tab without the ring still names the selected session: the header's segment shows it.
        rig.model.select(a)
        rig.model.selectInspectorTab(.agents)
        await rig.settle()
        await usage.settle()
        #expect(usage.contexts["conv-0"]?.tokens == 84_200)
        rig.model.selectInspectorTab(.overview)
        rig.model.toggleInspector()
        await rig.settle()
        #expect(rig.model.inspectorContextSessions == ["conv-0"])
    }
}
}
