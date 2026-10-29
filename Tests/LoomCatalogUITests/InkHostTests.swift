import AppKit
import Foundation
import LoomCore
import Observation
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

// MARK: Pure

/// The host's rules that need no view: where a popover sits against its control, where each opener opens, which keys the host reads,
/// what the host takes while nothing is open, the project menu's swatches and keys, and the motion rule (DESIGN §6 Motion).
@MainActor
struct InkHostPureTests {
    private let window = CGRect(x: 0, y: 0, width: 1_000, height: 700)

    // MARK: Placement

    @Test func belowAndAboveSitSixFromTheControlWithTheChosenEdgeAligned() {
        let chip = CGRect(x: 600, y: 300, width: 100, height: 22)
        let size = CGSize(width: 332, height: 200)
        let belowTrailing = InkPlacement.frame(anchor: chip, size: size, bounds: window, side: .below, alignment: .trailing)
        #expect(belowTrailing == CGRect(x: 368, y: 328, width: 332, height: 200), "right edge on the chip's, 6 under it")
        let belowLeading = InkPlacement.frame(anchor: chip, size: size, bounds: window, side: .below, alignment: .leading)
        #expect(belowLeading == CGRect(x: 600, y: 328, width: 332, height: 200))
        let aboveTrailing = InkPlacement.frame(anchor: chip, size: size, bounds: window, side: .above, alignment: .trailing)
        #expect(aboveTrailing == CGRect(x: 368, y: 94, width: 332, height: 200), "bottom edge 6 over the chip")
        let aboveLeading = InkPlacement.frame(anchor: chip, size: size, bounds: window, side: .above, alignment: .leading)
        #expect(aboveLeading == CGRect(x: 600, y: 94, width: 332, height: 200))
        #expect(LoomTheme.Host.anchorGap == 6 && LoomTheme.Host.edgeMargin == 8)
    }

    @Test func aSideThatDoesNotFitFlipsToTheOther() {
        let size = CGSize(width: 300, height: 200)
        // Near the bottom, a popover that wants to open below opens above.
        let low = CGRect(x: 100, y: 600, width: 60, height: 22)
        #expect(InkPlacement.frame(anchor: low, size: size, bounds: window, side: .below, alignment: .leading).minY == 394)
        // Near the top, one that wants to open above opens below.
        let high = CGRect(x: 100, y: 50, width: 60, height: 22)
        #expect(InkPlacement.frame(anchor: high, size: size, bounds: window, side: .above, alignment: .leading).minY == 78)
        // A side that fits is kept.
        let middle = CGRect(x: 100, y: 300, width: 60, height: 22)
        #expect(InkPlacement.frame(anchor: middle, size: size, bounds: window, side: .above, alignment: .leading).minY == 94)
    }

    @Test func xAlwaysStaysEightFromTheSides() {
        let size = CGSize(width: 332, height: 100)
        let left = CGRect(x: 5, y: 300, width: 20, height: 22)
        #expect(InkPlacement.frame(anchor: left, size: size, bounds: window, side: .below, alignment: .leading).minX == 8)
        let leftTrailing = CGRect(x: 80, y: 300, width: 20, height: 22)
        #expect(InkPlacement.frame(anchor: leftTrailing, size: size, bounds: window, side: .below, alignment: .trailing).minX == 8,
                "trailing-aligned, it would start left of the window")
        let right = CGRect(x: 900, y: 300, width: 60, height: 22)
        #expect(InkPlacement.frame(anchor: right, size: size, bounds: window, side: .below, alignment: .leading).maxX == 992)
        // Wider than the window: it starts at the margin and runs over the far edge rather than off the near one.
        let wide = CGSize(width: 1_200, height: 100)
        #expect(InkPlacement.frame(anchor: right, size: wide, bounds: window, side: .below, alignment: .leading).minX == 8)
    }

    /// The draft page's model popover (about 440 tall) in the smallest window: neither side fits under or over the chip, so it
    /// stays on the preferred side and is pushed inside the window's bounds, 8 from the edges.
    @Test func theDraftsModelPopoverInTheSmallestWindowIsClampedInsideIt() {
        let small = CGRect(x: 0, y: 0, width: 780, height: 500)
        let chip = CGRect(x: 600, y: 290, width: 80, height: 22)
        let frame = InkPlacement.frame(anchor: chip, size: CGSize(width: 332, height: 440), bounds: small, side: .below, alignment: .trailing)
        #expect(frame == CGRect(x: 348, y: 52, width: 332, height: 440))
        #expect(frame.minY >= 8 && frame.maxY <= 500 - 8 && frame.minX >= 8 && frame.maxX <= 780 - 8)
        // Taller than the window: it starts at the top margin.
        let tall = InkPlacement.frame(anchor: chip, size: CGSize(width: 332, height: 600), bounds: small, side: .below, alignment: .trailing)
        #expect(tall.minY == 8)
        // Room above, none below: above wins even though below was wanted.
        let lower = CGRect(x: 600, y: 440, width: 80, height: 22)
        #expect(InkPlacement.frame(anchor: lower, size: CGSize(width: 332, height: 300), bounds: small, side: .below, alignment: .trailing).minY == 134)
    }

    // MARK: Where each opener opens

    @Test func eachOpenerKnowsItsSideAndAlignment() {
        typealias Spot = InkOpeners.Spot
        // The live composer is docked at the bottom: its popovers open above their chips.
        #expect(InkOpeners.placement(.model, onDraft: false) == Spot(side: .above, alignment: .trailing))
        #expect(InkOpeners.placement(.mode, onDraft: false) == Spot(side: .above, alignment: .leading))
        #expect(InkOpeners.placement(.plus, onDraft: false) == Spot(side: .above, alignment: .leading))
        #expect(InkOpeners.placement(.ring, onDraft: false) == Spot(side: .above, alignment: .trailing))
        // The draft page opens under its chips (DESIGN §8); it has no + and no ring.
        #expect(InkOpeners.placement(.model, onDraft: true) == Spot(side: .below, alignment: .trailing))
        #expect(InkOpeners.placement(.mode, onDraft: true) == Spot(side: .below, alignment: .leading))
        #expect(InkOpeners.placement(.plus, onDraft: true) == nil && InkOpeners.placement(.ring, onDraft: true) == nil)
        #expect(InkOpeners.placement(.branchName, onDraft: true) == Spot(side: .below, alignment: .leading))
        #expect(InkOpeners.placement(.projectMenu, onDraft: false) == Spot(side: .below, alignment: .trailing))
    }

    // MARK: Keys

    @Test func theHostReadsTheArrowKeysReturnSpaceAndEscAndNothingWithACommandChord() {
        let map: [(UInt16, InkKey)] = [(126, .up), (125, .down), (123, .left), (124, .right), (36, .return), (76, .return),
                                       (49, .space), (53, .escape)]
        for (code, key) in map { #expect(InkKey(keyCode: code, modifiers: []) == key, "\(code)") }
        #expect(InkKey(keyCode: 125, modifiers: .shift) == .down, "shift changes nothing")
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            #expect(InkKey(keyCode: 125, modifiers: modifier) == nil, "a chord is not the popover's")
            #expect(InkKey(keyCode: 36, modifiers: modifier) == nil)
        }
        #expect(InkKey(keyCode: 0, modifiers: []) == nil && InkKey(keyCode: 48, modifiers: []) == nil)
    }

    private func spec(_ anchor: InkAnchor, id: String, keys: ((InkKey) -> Bool)? = nil, takesKeyboard: Bool = true,
                      onClose: @escaping () -> Void) -> InkHostState.Open {
        InkHostState.Open(owner: ObjectIdentifier(anchor), id: id, anchor: anchor, side: .below, alignment: .leading, label: id,
                          content: { AnyView(Color.clear.frame(width: 10, height: 10)) }, keys: keys, takesKeyboard: takesKeyboard,
                          restoreFocus: nil, onClose: onClose)
    }

    /// Esc closes a popover while one is open and is nobody's while none is, so a pinned card or the composer keeps its Esc.
    @Test func escIsNotConsumedWhileNothingIsOpenAndClosesAPopoverThatIs() {
        let state = InkHostState()
        for key: InkKey in [.escape, .return, .space, .up, .down, .left, .right] { #expect(!state.handle(key), "\(key) with nothing open") }
        var closed = 0
        let anchor = InkAnchor()
        state.present(spec(anchor, id: "a") { closed += 1 })
        #expect(state.isOpen)
        #expect(state.handle(.escape), "Esc is taken while a popover is open")
        #expect(!state.isOpen && closed == 1, "and tells the control that opened it")
        #expect(!state.handle(.escape), "gone again once it is shut")
    }

    @Test func theOtherKeysGoToTheOpenPopoversOwnHandler() {
        let state = InkHostState()
        var seen: [InkKey] = []
        let anchor = InkAnchor()
        state.present(spec(anchor, id: "a", keys: { key in seen.append(key); return key == .down }) {})
        #expect(state.handle(.down) && !state.handle(.left))
        #expect(seen == [.down, .left])
        let silent = InkHostState()
        silent.present(spec(InkAnchor(), id: "b") {})
        #expect(!silent.handle(.return), "a popover without a handler uses no key but Esc")
    }

    @Test func oneIsOpenAtATimeAndOnlyTheOwnerClosesItWithoutBeingTold() {
        let state = InkHostState()
        var closed: [String] = []
        let first = InkAnchor(), second = InkAnchor()
        state.present(spec(first, id: "first") { closed.append("first") })
        let count = state.openCount
        // The same control rendering again refreshes what is open and does not open it afresh.
        state.present(spec(first, id: "first") { closed.append("first") })
        #expect(state.openCount == count)
        // Another control opening takes over; the first one is told, so it lets go of its flag.
        state.present(spec(second, id: "second") { closed.append("second") })
        #expect(state.active?.id == "second" && closed == ["first"] && state.openCount == count + 1)
        // A control that is not the owner closes nothing.
        state.close(owner: ObjectIdentifier(first))
        #expect(state.active?.id == "second")
        // The owner closing its own popover (a pick) is not told: it did it.
        state.close(owner: ObjectIdentifier(second))
        #expect(!state.isOpen && closed == ["first"])
    }

    // MARK: Motion

    @Test func aPopoverEntersOverOneSixtyMillisecondsWithAThreePointRiseAndAtOnceUnderReduceMotion() {
        #expect(LoomTheme.Host.entranceDuration == 0.16 && LoomTheme.Host.rise == 3)
        #expect(LoomTheme.Host.entrance(reduceMotion: false) != nil)
        #expect(LoomTheme.Host.entrance(reduceMotion: true) == nil, "instant under Reduce Motion")
        // Above its control it rises from 3 pt below; under its control it settles from 3 pt above (the reference's translateY).
        #expect(InkPopoverSurface.entryOffset(side: .above) == 3 && InkPopoverSurface.entryOffset(side: .below) == -3)
    }

    @Test func theSlashAndAtMenusSitSixAboveTheCardLikeEveryOtherPopover() {
        #expect(LoomTheme.Composer.menuGap == 6 && LoomTheme.Composer.menuGap == LoomTheme.Host.anchorGap)
    }

    // MARK: The project menu's swatches and keys

    @Test func theSwatchRowIsTheSixTonesInOrderThenNoneWithTheCurrentOneMarked() {
        let items = ProjectSwatchRow.items(tone: .orchid, isNone: false)
        #expect(items.map(\.name) == ["Rose", "Orchid", "Aqua", "Mint", "Sage", "Lemon", "None"])
        #expect(items.map(\.tone) == ProjectTone.allCases.map { Optional($0) } + [nil])
        #expect(items.map(\.isCurrent) == [false, true, false, false, false, false, false])
        #expect(ProjectSwatchRow.currentName(tone: .orchid, isNone: false) == "Orchid")
        #expect(ProjectSwatchRow.currentIndex(tone: .orchid, isNone: false) == 1)
        // None is the seventh and is current when the user chose it.
        let none = ProjectSwatchRow.items(tone: nil, isNone: true)
        #expect(none.last == ProjectSwatchRow.Item(tone: nil, name: "None", isCurrent: true) && none.dropLast().allSatisfy { !$0.isCurrent })
        #expect(ProjectSwatchRow.currentName(tone: nil, isNone: true) == "None" && ProjectSwatchRow.currentIndex(tone: nil, isNone: true) == 6)
        // A tone this build does not know is no swatch's.
        let unknown = ProjectSwatchRow.items(tone: nil, isNone: false)
        #expect(unknown.allSatisfy { !$0.isCurrent } && ProjectSwatchRow.currentName(tone: nil, isNone: false) == "")
        #expect(ProjectSwatchRow.currentIndex(tone: nil, isNone: false) == nil)
    }

    private func plan(sessions: Int = 0, index: Int = 1, codex: Bool = true, colors: Bool = true) -> ProjectMenuPlan {
        ProjectMenuPlan.make(
            starts: [ProjectMenuPlan.Start(provider: .claude, title: "New Claude Session", enabled: true, reason: nil),
                     ProjectMenuPlan.Start(provider: .codex, title: "New Codex Session", enabled: codex,
                                           reason: codex ? nil : CatalogModel.codexLaterReason)],
            colorsEnabled: colors, index: index, count: 3, sessions: sessions)
    }

    @Test func theMenuKeysStopOnWhatCanBeUsedAndWrap() throws {
        let menu = plan(sessions: 2, index: 0, codex: false)
        // Claude, Color and Move Down are usable; Codex is off, Move Up is off at the top, Remove is off with sessions.
        let stops = ProjectMenuKeys.stops(menu)
        #expect(stops.map { menu.entries[$0] } == [.start(provider: .claude, title: "New Claude Session", enabled: true), .color,
                                                   .moveDown(enabled: true)])
        var state = ProjectMenuKeys.State()
        var visited: [Int] = []
        for _ in 0..<4 {
            let step = ProjectMenuKeys.resolve(.down, plan: menu, state: state, currentSwatch: 1)
            #expect(step.handled)
            state = step.state
            visited.append(try #require(state.stop))
        }
        #expect(visited == [stops[0], stops[1], stops[2], stops[0]], "↓ walks the usable rows and wraps")
        #expect(ProjectMenuKeys.resolve(.up, plan: menu, state: ProjectMenuKeys.State(), currentSwatch: nil).state.stop == stops[2],
                "↑ from nothing starts at the last")
    }

    @Test func theColorRowIsOneStopWhoseSwatchesTheLeftAndRightKeysWalk() throws {
        let menu = plan()
        let color = try #require(menu.entries.firstIndex(of: .color))
        // Arriving on Color puts the swatch cursor on the current tone.
        var state = ProjectMenuKeys.State(stop: color - 2)
        state = ProjectMenuKeys.resolve(.down, plan: menu, state: state, currentSwatch: 1).state
        #expect(state.stop == color && state.swatch == 1)
        // ← → move between the swatches and stop at the ends.
        state = ProjectMenuKeys.resolve(.right, plan: menu, state: state, currentSwatch: 1).state
        #expect(state.swatch == 2)
        var end = ProjectMenuKeys.State(stop: color, swatch: 6)
        #expect(ProjectMenuKeys.resolve(.right, plan: menu, state: end, currentSwatch: 1).state.swatch == 6)
        end.swatch = 0
        #expect(ProjectMenuKeys.resolve(.left, plan: menu, state: end, currentSwatch: 1).state.swatch == 0)
        // ↵ picks the swatch under the cursor and leaves the menu open; the seventh is None.
        let pick = ProjectMenuKeys.resolve(.return, plan: menu, state: ProjectMenuKeys.State(stop: color, swatch: 3), currentSwatch: nil)
        #expect(pick.action == .setTone(.mint) && !pick.closes && pick.handled)
        let none = ProjectMenuKeys.resolve(.space, plan: menu, state: ProjectMenuKeys.State(stop: color, swatch: 6), currentSwatch: nil)
        #expect(none.action == .setTone(nil))
        // ← → mean nothing on any other row.
        let start = ProjectMenuKeys.State(stop: 0)
        #expect(!ProjectMenuKeys.resolve(.left, plan: menu, state: start, currentSwatch: nil).handled)
    }

    @Test func aRowsReturnRunsItsActionAndClosesTheMenu() {
        let menu = plan()
        let start = ProjectMenuKeys.resolve(.return, plan: menu, state: ProjectMenuKeys.State(stop: 0), currentSwatch: nil)
        #expect(start.action == .start(.claude) && start.closes)
        let up = menu.entries.firstIndex(of: .moveUp(enabled: true))!
        #expect(ProjectMenuKeys.resolve(.return, plan: menu, state: ProjectMenuKeys.State(stop: up), currentSwatch: nil).action == .moveUp)
        let remove = menu.entries.firstIndex(of: .removeEmpty(enabled: true))!
        let removal = ProjectMenuKeys.resolve(.space, plan: menu, state: ProjectMenuKeys.State(stop: remove), currentSwatch: nil)
        #expect(removal.action == .removeEmpty && removal.closes)
        // With nothing under the cursor, ↵ does nothing; a key the menu does not use is not handled.
        #expect(!ProjectMenuKeys.resolve(.return, plan: menu, state: ProjectMenuKeys.State(), currentSwatch: nil).handled)
        #expect(!ProjectMenuKeys.resolve(.escape, plan: menu, state: ProjectMenuKeys.State(stop: 0), currentSwatch: nil).handled)
    }

    @Test func theMenusRowsAreTheSharedPlansAndColorIsOneRowWithTheSwatchesUnderIt() {
        let withColors = plan()
        #expect(withColors.entries.filter { $0 == .color }.count == 1)
        #expect(!plan(colors: false).entries.contains(.color), "no Color row and no swatches while Project colors are off")
        // The pick list of the mode popover and the plus popover keep their own rules.
        let rows = ComposerModeChip.rows(selected: "auto")
        #expect(ComposerPickList.resolve(.down, highlighted: nil, rows: rows).highlighted == 0)
        #expect(ComposerPickList.resolve(.up, highlighted: nil, rows: rows).highlighted == rows.count - 1)
        #expect(ComposerPickList.resolve(.down, highlighted: rows.count - 1, rows: rows).highlighted == rows.count - 1, "the mode list clamps")
        #expect(ComposerPickList.resolve(.space, highlighted: 1, rows: rows).pick == rows[1].id)
        #expect(ComposerPickList.resolve(.return, highlighted: nil, rows: rows).pick == nil)
        #expect(ComposerPlusChip.resolve(.down, highlighted: 2).highlighted == 0, "the + rows wrap")
        #expect(ComposerPlusChip.resolve(.return, highlighted: 1).pick == ComposerPlusItem.allCases[1])
    }

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

@Observable @MainActor
private final class OpenFlag {
    var on = true
}

/// A view that takes the keyboard, standing for the composer's text.
@MainActor
private final class KeyboardView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// The host in a window that is never ordered front: where a popover lands for a control, who holds the keyboard, and how it closes.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct InkHostHostedTests {
    @MainActor private final class Rig {
        let window: NSWindow
        let host = InkHost()
        let content: NSView
        let size: CGSize

        init(size: CGSize) {
            self.size = size
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            content = NSView(frame: NSRect(origin: .zero, size: size))
            window.contentView = content
        }

        func install() {
            host.view.frame = content.bounds
            host.view.autoresizingMask = [.width, .height]
            content.addSubview(host.view)
        }

        /// A bare view standing for a chip, `top` and `left` from the window's top-left corner.
        func control(left: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> NSView {
            let view = NSView(frame: NSRect(x: left, y: size.height - top - height, width: width, height: height))
            content.addSubview(view)
            return view
        }

        func settle(until done: @MainActor () -> Bool = { true }) async {
            for _ in 0..<40 {
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                if done() { return }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }

        func close() {
            host.state.dismiss()
            window.contentView = nil
            window.close()
        }
    }

    private func spec(_ anchor: InkAnchor, side: InkPlacement.Side, alignment: InkPlacement.Alignment, width: CGFloat = 200,
                      height: CGFloat = 100, takesKeyboard: Bool = true, restoreFocus: (() -> Void)? = nil,
                      keys: ((InkKey) -> Bool)? = nil, onClose: @escaping () -> Void = {}) -> InkHostState.Open {
        InkHostState.Open(owner: ObjectIdentifier(anchor), id: "t", anchor: anchor, side: side, alignment: alignment, label: "Test",
                          content: { AnyView(Color.clear.frame(width: width, height: height)) }, keys: keys,
                          takesKeyboard: takesKeyboard, restoreFocus: restoreFocus, onClose: onClose)
    }

    private func click(_ type: NSEvent.EventType = .leftMouseDown, atTop top: CGFloat, left: CGFloat, in rig: Rig) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: left, y: rig.size.height - top), modifierFlags: [], timestamp: 0,
            windowNumber: rig.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    // MARK: Closed

    @Test func aClosedHostAnswersNoHitTakesNoKeyboardAndNoEsc() throws {
        let rig = Rig(size: CGSize(width: 780, height: 500))
        defer { rig.close() }
        rig.install()
        let view = rig.host.view
        #expect(view.hitTest(NSPoint(x: 100, y: 100)) == nil, "every click goes through")
        #expect(!view.acceptsFirstResponder)
        #expect(!rig.host.state.handle(.escape), "Esc belongs to whoever holds it")
        #expect(rig.host.state.frame == nil)
    }

    // MARK: Placement

    @Test func aPopoverLandsWhereThePlacementPutsItForItsControl() async throws {
        let rig = Rig(size: CGSize(width: 1_000, height: 700))
        defer { rig.close() }
        rig.install()
        let control = rig.control(left: 600, top: 300, width: 80, height: 22)
        let anchor = InkAnchor(view: control)
        rig.host.state.present(spec(anchor, side: .below, alignment: .trailing))
        await rig.settle { rig.host.state.frame != nil }
        let state = rig.host.state
        #expect(state.anchorRect == CGRect(x: 600, y: 300, width: 80, height: 22), "the control's rect in the layer's top-left space")
        #expect(state.contentSize == CGSize(width: 200, height: 100))
        #expect(state.frame == CGRect(x: 480, y: 328, width: 200, height: 100), "trailing edges aligned, 6 below")
    }

    @Test func theDraftsModelPopoverInTheSmallestWindowIsInsideIt() async throws {
        let rig = Rig(size: CGSize(width: 780, height: 500))
        defer { rig.close() }
        rig.install()
        let anchor = InkAnchor(view: rig.control(left: 600, top: 290, width: 80, height: 22))
        rig.host.state.present(spec(anchor, side: .below, alignment: .trailing, width: 332, height: 440))
        await rig.settle { rig.host.state.frame != nil }
        #expect(rig.host.state.frame == CGRect(x: 348, y: 52, width: 332, height: 440))
    }

    @Test func aClickInsideTheSurfaceIsTheContentsAndAnyOtherPointIsTheLayersToDismiss() async throws {
        let rig = Rig(size: CGSize(width: 1_000, height: 700))
        defer { rig.close() }
        rig.install()
        let anchor = InkAnchor(view: rig.control(left: 600, top: 300, width: 80, height: 22))
        rig.host.state.present(spec(anchor, side: .below, alignment: .trailing))
        await rig.settle { rig.host.state.frame != nil }
        func hit(top: CGFloat, left: CGFloat) -> NSView? {
            rig.host.view.hitTest(rig.content.convert(NSPoint(x: left, y: rig.size.height - top), to: rig.content))
        }
        #expect(hit(top: 20, left: 20) === rig.host.view, "outside the surface the layer takes the click")
        #expect(hit(top: 310, left: 640) === rig.host.view, "even over the control that opened it: that click is the toggle")
        #expect(hit(top: 360, left: 560) != nil)
    }

    // MARK: Dismissal

    @Test func anOutsideClickDismissesAndTellsTheOwnerAndAClickInsideDoesNot() async throws {
        let rig = Rig(size: CGSize(width: 1_000, height: 700))
        defer { rig.close() }
        rig.install()
        var closed = 0
        let anchor = InkAnchor(view: rig.control(left: 600, top: 300, width: 80, height: 22))
        rig.host.state.present(spec(anchor, side: .below, alignment: .trailing) { closed += 1 })
        await rig.settle { rig.host.state.frame != nil }
        rig.host.view.mouseDown(with: try click(atTop: 360, left: 560, in: rig))
        #expect(rig.host.state.isOpen && closed == 0, "a click on the surface leaves it open")
        rig.host.view.mouseDown(with: try click(atTop: 20, left: 20, in: rig))
        #expect(!rig.host.state.isOpen && closed == 1)
    }

    @Test func aSecondClickOnTheControlClosesItAndIsNotPassedOn() async throws {
        let rig = Rig(size: CGSize(width: 1_000, height: 700))
        defer { rig.close() }
        rig.install()
        var closed = 0
        let anchor = InkAnchor(view: rig.control(left: 600, top: 300, width: 80, height: 22))
        rig.host.state.present(spec(anchor, side: .below, alignment: .trailing) { closed += 1 })
        await rig.settle { rig.host.state.frame != nil }
        // The click on the control reaches the layer, not the control: the layer dismisses it (the control's toggle never runs, so
        // it is not opened again).
        #expect(rig.host.view.hitTest(NSPoint(x: 640, y: 700 - 311)) === rig.host.view)
        rig.host.view.mouseDown(with: try click(atTop: 311, left: 640, in: rig))
        #expect(!rig.host.state.isOpen && closed == 1)
    }

    @Test func escClosesAndTheArrowKeysGoToTheHandler() async throws {
        let rig = Rig(size: CGSize(width: 1_000, height: 700))
        defer { rig.close() }
        rig.install()
        var seen: [InkKey] = []
        var closed = 0
        let anchor = InkAnchor(view: rig.control(left: 600, top: 300, width: 80, height: 22))
        rig.host.state.present(spec(anchor, side: .below, alignment: .trailing, keys: { seen.append($0); return true }) { closed += 1 })
        await rig.settle { rig.host.state.frame != nil }
        rig.host.view.keyDown(with: try key(125, "\u{F701}"))
        rig.host.view.keyDown(with: try key(36, "\r"))
        #expect(seen == [.down, .return] && rig.host.state.isOpen)
        rig.host.view.keyDown(with: try key(0, "a"))
        #expect(seen == [.down, .return] && rig.host.state.isOpen, "a letter is taken and goes nowhere")
        rig.host.view.keyDown(with: try key(53, "\u{1B}"))
        #expect(!rig.host.state.isOpen && closed == 1)
        // A text field in the popover sends Esc up the chain as cancelOperation.
        rig.host.state.present(spec(anchor, side: .below, alignment: .trailing) { closed += 1 })
        rig.host.view.cancelOperation(nil)
        #expect(!rig.host.state.isOpen && closed == 2)
    }

    @Test func theWindowLosingKeyDismisses() async throws {
        let rig = Rig(size: CGSize(width: 1_000, height: 700))
        defer { rig.close() }
        rig.install()
        var closed = 0
        let anchor = InkAnchor(view: rig.control(left: 600, top: 300, width: 80, height: 22))
        rig.host.state.present(spec(anchor, side: .below, alignment: .trailing) { closed += 1 })
        await rig.settle { rig.host.state.frame != nil }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: rig.window)
        await rig.settle { !rig.host.state.isOpen }
        #expect(!rig.host.state.isOpen && closed == 1)
    }

    // MARK: Focus

    @Test func theHostTakesTheKeyboardWhileOpenAndGivesItBackToWhatHadIt() async throws {
        let rig = Rig(size: CGSize(width: 1_000, height: 700))
        defer { rig.close() }
        let text = KeyboardView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        rig.content.addSubview(text)
        rig.install()
        #expect(rig.window.makeFirstResponder(text) && rig.window.firstResponder === text)
        let anchor = InkAnchor(view: rig.control(left: 600, top: 300, width: 80, height: 22))
        rig.host.state.present(spec(anchor, side: .above, alignment: .leading))
        #expect(rig.window.firstResponder === rig.host.view, "keys go to the popover")
        rig.host.state.close(owner: ObjectIdentifier(anchor))
        #expect(rig.window.firstResponder === text, "and come back to the composer's text")
        // The opener can say where they go.
        let other = KeyboardView(frame: NSRect(x: 0, y: 100, width: 100, height: 40))
        rig.content.addSubview(other)
        var restored = 0
        rig.host.state.present(spec(anchor, side: .above, alignment: .leading, restoreFocus: { restored += 1; rig.window.makeFirstResponder(other) }))
        rig.host.state.dismiss()
        #expect(restored == 1 && rig.window.firstResponder === other)
    }

    @Test func aPopoverThatOpenedUnderThePointerLeavesTheKeyboardAlone() async throws {
        let rig = Rig(size: CGSize(width: 1_000, height: 700))
        defer { rig.close() }
        let text = KeyboardView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        rig.content.addSubview(text)
        rig.install()
        _ = rig.window.makeFirstResponder(text)
        let anchor = InkAnchor(view: rig.control(left: 600, top: 300, width: 80, height: 22))
        rig.host.state.present(spec(anchor, side: .above, alignment: .trailing, takesKeyboard: false))
        #expect(rig.window.firstResponder === text, "typing goes on while the ring's popover shows")
        rig.host.state.dismiss()
        #expect(rig.window.firstResponder === text)
    }
}

/// The real chips presenting through the host: each opens on the side and edge the table gives it, with the surface 6 from the chip.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct InkHostOpenersTests {
    private func picker() -> ComposerModelPicker {
        ComposerModelPicker(
            modelTitle: "Sonnet 5.5", effortTitle: "High",
            rows: ["opus", "sonnet", "haiku"].map { ComposerBarText.ModelRow(value: $0, title: $0.capitalized) },
            chosenModel: "sonnet", levels: ["low", "medium", "high"], chosenLevel: "high", canResetEffort: false)
    }

    private func host<V: View>(_ view: V, size: CGSize) -> (NSWindow, InkHost) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = InkHost()
        let hosting = NSHostingView(rootView: view.inkHost(host).frame(width: size.width, height: size.height))
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = content.bounds
        host.view.frame = content.bounds
        content.addSubview(hosting)
        content.addSubview(host.view)
        window.contentView = content
        return (window, host)
    }

    private func settle(_ window: NSWindow, _ host: InkHost) async {
        for _ in 0..<60 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if host.state.frame != nil { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func check(_ host: InkHost, side: InkPlacement.Side, alignment: InkPlacement.Alignment, id: String) throws {
        let state = host.state
        let active = try #require(state.active, "\(id) is open")
        #expect(active.id == id && active.side == side && active.alignment == alignment)
        let anchor = try #require(state.anchorRect)
        let frame = try #require(state.frame)
        switch side {
        case .above: #expect(abs(frame.maxY - (anchor.minY - 6)) < 0.5, "\(id): \(frame) over \(anchor)")
        case .below: #expect(abs(frame.minY - (anchor.maxY + 6)) < 0.5, "\(id): \(frame) under \(anchor)")
        }
        switch alignment {
        case .leading: #expect(abs(frame.minX - anchor.minX) < 0.5, "\(id): \(frame) from \(anchor)")
        case .trailing: #expect(abs(frame.maxX - anchor.maxX) < 0.5, "\(id): \(frame) from \(anchor)")
        }
    }

    private func chips(_ flag: OpenFlag, onDraft: Bool) -> some View {
        let open = Binding(get: { flag.on }, set: { flag.on = $0 })
        return HStack {
            Spacer(minLength: 300)
            ComposerModeChip(selected: "auto", title: "Auto", help: "Mode", identifier: "composer-mode", onDraft: onDraft, isOpen: open) { _ in }
            Spacer(minLength: 300)
        }
    }

    @Test func theLiveModeChipOpensItsListAboveItWithTheLeadingEdgesAligned() async throws {
        let flag = OpenFlag()
        let (window, host) = host(chips(flag, onDraft: false), size: CGSize(width: 1_000, height: 700))
        defer { host.state.dismiss(); window.contentView = nil; window.close() }
        await settle(window, host)
        try check(host, side: .above, alignment: .leading, id: "composer-mode")
        // The list is the mode popover: 312 wide.
        #expect(host.state.contentSize.width == LoomTheme.Composer.pickWidth)
    }

    @Test func theDraftsModeChipOpensItsListBelowIt() async throws {
        let flag = OpenFlag()
        let (window, host) = host(chips(flag, onDraft: true), size: CGSize(width: 1_000, height: 700))
        defer { host.state.dismiss(); window.contentView = nil; window.close() }
        await settle(window, host)
        try check(host, side: .below, alignment: .leading, id: "composer-mode")
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

    @Test func aControlThatShutsItsFlagClosesTheHostsPopover() async throws {
        let flag = OpenFlag()
        let (window, host) = host(chips(flag, onDraft: false), size: CGSize(width: 1_000, height: 700))
        defer { host.state.dismiss(); window.contentView = nil; window.close() }
        await settle(window, host)
        #expect(host.state.isOpen)
        flag.on = false
        for _ in 0..<40 where host.state.isOpen {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(30))
        }
        #expect(!host.state.isOpen, "the flag is the control's, and the host follows it")
        // And the host shutting it (an outside click) lets go of the flag.
        flag.on = true
        await settle(window, host)
        #expect(host.state.isOpen)
        host.state.dismiss()
        #expect(!flag.on)
    }
}

// MARK: The swatches as VoiceOver reads them

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ProjectSwatchAccessibilityTests {
    @Test func theSwatchesAreSevenNamedButtonsWithTheCurrentOneSelected() async throws {
        enableAccessibilityTree()
        let items = ProjectSwatchRow.items(tone: .aqua, isNone: false)
        let row = HStack(spacing: LoomTheme.Host.swatchGap) {
            ForEach(Array(items.enumerated()), id: \.offset) { position, item in
                ProjectSwatchButton(item: item, focused: position == 3) {}
            }
        }.padding(20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: row)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(60))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let buttons = accessibilityElements(in: hosting).filter { ($0.accessibilityIdentifier?() ?? "").hasPrefix("project-menu-color-") }
        #expect(buttons.count == 7)
        let nodes = buttons.map { axTree(of: $0) }
        #expect(nodes.map { $0.label ?? "" } == ["Rose", "Orchid", "Aqua", "Mint", "Sage", "Lemon", "None"])
        #expect(nodes.allSatisfy { $0.role == "AXButton" })
        // UIAccessibilityTraitSelected is the bit SwiftUI sets for `.isSelected`; only the current swatch carries it.
        #expect(nodes.map { $0.traits & 0x8 != 0 } == [false, false, true, false, false, false, false], "\(nodes.map(\.traits))")
        // Each answers over 24 × 24 although it is drawn 18 × 18.
        for button in buttons {
            let frame = try #require(button.accessibilityFrame?())
            #expect(frame.width >= LoomTheme.Host.swatchSide && frame.height >= LoomTheme.Host.swatchSide, "\(frame)")
        }
    }

    @Test func theSwatchSizesAreDesignsAndNoneIsHollow() {
        #expect(LoomTheme.Host.swatchSide == 18 && LoomTheme.Host.swatchRadius == 5 && LoomTheme.Host.swatchGap == 7)
        #expect(LoomTheme.Host.swatchFill == 0.24 && LoomTheme.Host.swatchFillLight == 0.15 && LoomTheme.Host.swatchRingOpacity == 0.46)
        #expect(LoomTheme.Host.swatchHit >= LoomTheme.Layout.minimumHitTarget.width)
        #expect(LoomTheme.Host.menuWidth == 276 && LoomTheme.Host.rowHeight == 28 && LoomTheme.Host.rowRadius == 8)
        #expect(LoomTheme.Host.iconColumn == 16 && LoomTheme.Host.noteIndent == 34 && LoomTheme.Host.swatchRowLeading == 34,
                "the swatches line up with the labels")
        // The tone washes: Ink 24 % and Paper 15 % of the Light tone.
        let rose = LoomTheme.Host.swatchFillTone(.rose)
        #expect(rose.dark.opacity == 0.24 && rose.light.opacity == 0.15)
        #expect(rose.dark.rgb == LoomTheme.ProjectColor.baseRGB(.rose) && rose.light.rgb == LoomTheme.ProjectColor.lightBaseRGB(.rose))
    }
}
