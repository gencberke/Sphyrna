import AppKit
import Foundation
import LoomCore
import Observation
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

private typealias OpenFlag = InkHostShared.OpenFlag

// MARK: Pure

/// The host's rules that need no view: where a popover sits against its control, where each opener opens, which keys the host reads,
/// what the host takes while nothing is open, the project menu's swatches and keys, and the motion rule (DESIGN §6 Motion).
@MainActor
struct InkHostPureTests {
    private let window = CGRect(x: 0, y: 0, width: 1_000, height: 700)

    // MARK: Keys

    // MARK: The project menu's swatches and keys

    @Test func theModelPopoversKeysStepTheEffortAndPickOnReturn() {
        let picker = ComposerModelPicker(
            modelTitle: "Sonnet 5.5", effortTitle: "High",
            rows: ["opus", "sonnet", "haiku"].map { ComposerBarText.ModelRow(value: $0, title: $0.capitalized) },
            chosenModel: "sonnet", levels: ["low", "medium", "high"], chosenLevel: "medium", canResetEffort: false)
        let down = ComposerModelPopover.resolve(.down, picker: picker, cursor: "haiku")
        #expect(down.handled && down.cursor != "haiku", "↓ wraps from the last row")
        #expect(ComposerModelPopover.resolve(.right, picker: picker, cursor: nil).effort == "high")
        #expect(ComposerModelPopover.resolve(.left, picker: picker, cursor: nil).effort == "low")
        let done = ComposerModelPopover.resolve(.return, picker: picker, cursor: "haiku")
        #expect(done.pickModel == "haiku" && done.done && done.handled)
        #expect(ComposerModelPopover.resolve(.return, picker: picker, cursor: picker.chosenID).pickModel == nil, "the chosen one only closes")
        #expect(!ComposerModelPopover.resolve(.space, picker: picker, cursor: nil).handled)
    }
}

// MARK: Hosted (offscreen: no window is ordered front)

/// The real chips presenting through the host: each opens on the side and edge the table gives it, with the surface 6 from the chip.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct InkHostOpenersTests: InkHostOpenersFixtures {
    private func picker() -> ComposerModelPicker {
        ComposerModelPicker(
            modelTitle: "Sonnet 5.5", effortTitle: "High",
            rows: ["opus", "sonnet", "haiku"].map { ComposerBarText.ModelRow(value: $0, title: $0.capitalized) },
            chosenModel: "sonnet", levels: ["low", "medium", "high"], chosenLevel: "high", canResetEffort: false)
    }

    @Test func theModelChipOpensAboveItInTheLiveComposerAndBelowItOnTheDraftPageTrailingEdgeAligned() async throws {
        for onDraft in [false, true] {
            let flag = OpenFlag()
            let open = Binding(get: { flag.on }, set: { flag.on = $0 })
            let view = HStack {
                Spacer(minLength: 300)
                ComposerModelChip(picker: picker(), identifier: "composer-model", help: "Model", onDraft: onDraft, isOpen: open,
                                  onPickModel: { _ in }, onPickEffort: { _ in }, onResetEffort: {})
                Spacer(minLength: 300)
            }
            // A tall window, so the draft's popover has the room under the chip.
            let (window, host) = host(view, size: CGSize(width: 1_000, height: 900))
            defer { host.state.dismiss(); window.contentView = nil; window.close() }
            await settle(window, host)
            try check(host, side: onDraft ? .below : .above, alignment: .trailing, id: "composer-model")
            #expect(host.state.contentSize.width == LoomTheme.Composer.modelPopoverWidth)
        }
    }

    @Test func thePlusChipAndTheRingOpenAboveTheirChips() async throws {
        let plus = OpenFlag()
        let (plusWindow, plusHost) = host(
            HStack { Spacer(minLength: 300); ComposerPlusChip(isOpen: Binding(get: { plus.on }, set: { plus.on = $0 })) { _ in }; Spacer(minLength: 300) },
            size: CGSize(width: 1_000, height: 700))
        defer { plusHost.state.dismiss(); plusWindow.contentView = nil; plusWindow.close() }
        await settle(plusWindow, plusHost)
        try check(plusHost, side: .above, alignment: .leading, id: "composer-plus")

        let ring = OpenFlag()
        let (ringWindow, ringHost) = host(
            HStack {
                Spacer(minLength: 300)
                ComposerRing(usage: nil, canCompact: false, onCompact: {}, showsPopover: Binding(get: { ring.on }, set: { ring.on = $0 }))
                Spacer(minLength: 300)
            }, size: CGSize(width: 1_000, height: 700))
        defer { ringHost.state.dismiss(); ringWindow.contentView = nil; ringWindow.close() }
        await settle(ringWindow, ringHost)
        try check(ringHost, side: .above, alignment: .trailing, id: "composer-ring")
    }
}
