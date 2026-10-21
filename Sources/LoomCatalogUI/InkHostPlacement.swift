import AppKit

/// Where a popover or menu sits against its control (DESIGN §8 Composer, §10 Project menu; the reference's `place` and
/// `placeBelow`). Pure, so every case is tested without a view. Coordinates are the window's content, y growing downwards (the
/// host view is flipped).
enum InkPlacement {
    /// Which side of the control the popover prefers.
    enum Side: Equatable, Sendable { case below, above }
    /// Which edge of the control the popover lines up with.
    enum Alignment: Equatable, Sendable { case leading, trailing }

    /// A popover of `size` against `anchor` inside `bounds`.
    /// - It sits `LoomTheme.Host.anchorGap` (6) from the control, on the preferred side.
    /// - When that side does not leave `edgeMargin` (8) to the window's edge it flips to the other.
    /// - When neither fits, it stays on the preferred side and is pushed inside the bounds, 8 from the edges (and may then
    ///   cover its control).
    /// - x always stays 8 from the sides.
    static func frame(anchor: CGRect, size: CGSize, bounds: CGRect, side: Side, alignment: Alignment) -> CGRect {
        let gap = LoomTheme.Host.anchorGap
        let margin = LoomTheme.Host.edgeMargin

        let wantedX = alignment == .trailing ? anchor.maxX - size.width : anchor.minX
        let lowestX = bounds.minX + margin
        let highestX = max(lowestX, bounds.maxX - size.width - margin)
        let x = min(max(wantedX, lowestX), highestX)

        let below = anchor.maxY + gap
        let above = anchor.minY - gap - size.height
        func fits(_ y: CGFloat) -> Bool { y >= bounds.minY + margin && y + size.height <= bounds.maxY - margin }
        let preferred = side == .below ? below : above
        let other = side == .below ? above : below
        let natural = fits(preferred) ? preferred : (fits(other) ? other : preferred)
        let lowestY = bounds.minY + margin
        let highestY = max(lowestY, bounds.maxY - size.height - margin)
        let y = min(max(natural, lowestY), highestY)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// The keys a popover's own handler sees (the host reads them from the key event; nothing else reaches a popover).
enum InkKey: Equatable, Sendable {
    case up, down, left, right, `return`, space, escape

    /// The key of a key event, or nil for any other key and for a chord with ⌘, ⌃ or ⌥.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 36, 76: self = .return
        case 49: self = .space
        case 53: self = .escape
        default: return nil
        }
    }

    init?(event: NSEvent) { self.init(keyCode: event.keyCode, modifiers: event.modifierFlags) }
}

/// Where each opener's popover sits against its control (the planner's table of 21 Oct, DESIGN §8; the reference's `above-left`,
/// `above-right` and `below-right`). One table, so the live composer, the draft page and a test read the same answer.
enum InkOpeners {
    enum Opener: Equatable, Sendable {
        /// The model chip: its trailing edge, so it stays put when the name changes.
        case model
        /// The mode chip.
        case mode
        /// The composer's + (the live composer only).
        case plus
        /// The context ring (the live composer only).
        case ring
        /// The draft's branch-name popover, from its segment.
        case branchName
        /// The project menu's ⋯, on the sidebar's head and on the project page.
        case projectMenu
    }

    /// Side and alignment, as a popover asks for them.
    struct Spot: Equatable, Sendable {
        let side: InkPlacement.Side
        let alignment: InkPlacement.Alignment
    }

    /// The side and alignment of `opener`'s popover; nil where that surface has none (the draft bar has no + and no ring).
    /// The live composer is docked at the bottom, so its popovers open above their chips; the draft page's open below them.
    static func placement(_ opener: Opener, onDraft: Bool) -> Spot? {
        let vertical: InkPlacement.Side = onDraft ? .below : .above
        switch opener {
        case .model: return Spot(side: vertical, alignment: .trailing)
        case .mode: return Spot(side: vertical, alignment: .leading)
        case .plus: return onDraft ? nil : Spot(side: .above, alignment: .leading)
        case .ring: return onDraft ? nil : Spot(side: .above, alignment: .trailing)
        case .branchName: return Spot(side: .below, alignment: .leading)
        case .projectMenu: return Spot(side: .below, alignment: .trailing)
        }
    }
}
