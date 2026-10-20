import SwiftUI

/// Ink's type roles, radii and heights (design/DESIGN.md §3 Type, Shape and rhythm), as tokens for the surface slices that
/// follow. No view draws with them yet; today's `Typography`, `TypeScale`, `Radius` and `Layout` keep what the views use.
extension LoomTheme {
    /// A type role: the face, its tracking and its line height, with the size and weight as data.
    struct InkStyle: Equatable, Sendable {
        let size: CGFloat
        let weight: Font.Weight
        let mono: Bool
        /// SF Pro Display for the two large roles, SF Pro Text otherwise (the system picks the optical size).
        let display: Bool
        /// Tracking in em (−0.03 is −3 %); `nil` for the face's own.
        let tracking: Double?
        /// The line height in points, or nil for the system's.
        let lineHeight: CGFloat?
        /// Drawn in capitals (written in sentence case).
        let capitals: Bool

        init(size: CGFloat, weight: Font.Weight = .regular, mono: Bool = false, display: Bool = false, tracking: Double? = nil,
             lineHeight: CGFloat? = nil, capitals: Bool = false) {
            self.size = size
            self.weight = weight
            self.mono = mono
            self.display = display
            self.tracking = tracking
            self.lineHeight = lineHeight
            self.capitals = capitals
        }

        var font: Font { .system(size: size, weight: weight, design: mono ? .monospaced : .default) }
        /// The tracking in points (SwiftUI's `tracking(_:)` takes points).
        var trackingPoints: CGFloat { CGFloat(tracking ?? 0) * size }
    }

    /// Ink's type roles. Weight carries hierarchy before size. Sizes are fixed (no Dynamic Type).
    enum InkType {
        /// The new-session page's one question.
        static let display = InkStyle(size: 46, weight: .ultraLight, display: true, tracking: -0.03)
        /// Home's one sentence.
        static let statement = InkStyle(size: 42, weight: .ultraLight, display: true, tracking: -0.03)
        /// A page's title: a project page, Settings, an empty state.
        static let title = InkStyle(size: 20, weight: .semibold)
        /// The session's title in the header; a card's heading.
        static let header = InkStyle(size: 13, weight: .semibold)
        /// Rows, menus and fields.
        static let body = InkStyle(size: 13)
        /// Buttons.
        static let button = InkStyle(size: 12.5, weight: .medium)
        /// A page's main action (30 high).
        static let pageButton = InkStyle(size: 13)
        /// A small button (22 high).
        static let smallButton = InkStyle(size: 11.5)
        /// Supporting lines, facts, a card's reason line.
        static let small = InkStyle(size: 12)
        /// Section labels, written in sentence case and drawn in capitals, tracked .09 em.
        static let label = InkStyle(size: 10.5, weight: .medium, mono: true, tracking: 0.09, capitals: true)
        /// Branches, paths, times, tokens, counts and key hints (11 to 11.5).
        static let meta = InkStyle(size: 11, mono: true)
        static let metaLarge = InkStyle(size: 11.5, mono: true)
        /// Chat prose, your message and the composer's text.
        static let reading = InkStyle(size: 14, lineHeight: 22)
        /// Code blocks in the chat.
        static let code = InkStyle(size: 12.5, mono: true, lineHeight: 20)
    }

    /// Ink's radii. A nested control steps down by its padding.
    enum InkRadius {
        /// Key caps.
        static let key: CGFloat = 4
        /// Controls: buttons, icon buttons, chips.
        static let control: CGFloat = 6
        /// Rows, fields and large buttons.
        static let row: CGFloat = 8
        /// The activity view's cards.
        static let activityCard: CGFloat = 10
        /// Cards, menus and the window.
        static let card: CGFloat = 12
        /// The composer.
        static let composer: CGFloat = 18
        /// A control group or a segmented control, and what sits inside it.
        static let group: CGFloat = 7
        static let groupInner: CGFloat = 5
        /// The palette.
        static let palette: CGFloat = 14
    }

    /// Ink's heights.
    enum InkHeight {
        /// A chip, a state pill, a small button.
        static let chip: CGFloat = 22
        /// A subagent row.
        static let subagentRow: CGFloat = 24
        /// A control (button, icon button, segment, control group, session tab); the chat's work row.
        static let control: CGFloat = 26
        /// A sidebar row and a project head; the chat's turn fold and live row.
        static let sidebarRow: CGFloat = 28
        /// A field and a large button; a row of the model popover.
        static let field: CGFloat = 30
        /// The tab row.
        static let tabRow: CGFloat = 36
        /// The composer's bar.
        static let composerBar: CGFloat = 38
        /// The header.
        static let header: CGFloat = 52
    }
}
