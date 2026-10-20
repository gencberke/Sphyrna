import SwiftUI

/// Pinned cards (V18, CHAT-SPEC → Requests): approvals, questions and plans above the composer. Geometry, type and the
/// timings the spec names. Colours come from the Ink roles (`Surface`, `Text`, `Accent`, `Status`).
extension LoomTheme {
    enum Pinned {
        // MARK: Geometry

        static let cardRadius: CGFloat = Radius.block
        static let cardPadding: CGFloat = 16
        static let sectionSpacing: CGFloat = 12
        static let stackSpacing: CGFloat = 8
        static let stackPaddingH: CGFloat = 20
        static let stackPaddingBottom: CGFloat = 8
        /// The card stack never takes more than this share of the chat pane (stream, cards and composer): past it the stack
        /// scrolls, so the composer stays on screen.
        static let stackMaxHeightFraction: CGFloat = 0.55
        /// With a card shown the composer is compact (`LoomTheme.Composer.compactTextHeight`), so the stack may take more.
        static let compactStackMaxHeightFraction: CGFloat = 0.68
        static let iconSlot: CGFloat = 22
        static let iconRadius: CGFloat = Radius.sm
        static let buttonHeight: CGFloat = 28
        static let buttonRadius: CGFloat = Radius.md
        static let buttonPaddingH: CGFloat = 12
        static let buttonSpacing: CGFloat = 8
        static let foldedHeight: CGFloat = 30
        static let heldHeight: CGFloat = 34
        static let noteMinHeight: CGFloat = 30
        static let noteRadius: CGFloat = Radius.md
        static let optionRadius: CGFloat = Radius.lg
        static let optionPadding: CGFloat = 12
        static let optionMark: CGFloat = 14
        static let codeRadius: CGFloat = Radius.md
        static let codePadding: CGFloat = 8
        /// An approval's command or diff shows this many lines, then scrolls inside the card.
        static let codeLines = 5
        static let codeLineHeight: CGFloat = 19
        static let planBodyMaxHeight: CGFloat = 170
        /// In a short window the plan's text gives way, so the buttons below it stay on screen: it never takes less than
        /// this, and the rest of the card (title, note field, two button rows, padding) is counted as the allowance.
        static let planBodyMinHeight: CGFloat = 64
        static let planChromeAllowance: CGFloat = 245
        static let optionsMaxHeight: CGFloat = 210
        static let agentGap: CGFloat = 4

        // MARK: Timing

        /// A card that arrives while the composer was typed in within this long waits as a one-line notice.
        static let typingHold: TimeInterval = 1.5
        /// A single-select pick moves to the next question after this long.
        static let questionAdvance: TimeInterval = 0.2
        /// An answered card stays as a folded line in the stack this long.
        static let foldedLinger: TimeInterval = 4
        /// How often a held stack looks at the composer again.
        static let holdPoll: TimeInterval = 0.25

        // MARK: Colour

        static let strokeOpacity = 0.35
        static let planStrokeOpacity = 0.38
        static let iconFillOpacity = 0.16
        /// The card is raised 2 and the command inside it raised 1 (DESIGN §12, E2); both follow the tone, so computed,
        /// never stored.
        static var cardFill: Color { Surface.raised2 }
        static var codeFill: Color { Surface.raised1 }
        static let optionFill = Surface.hoverTone.color
        static let optionSelectedFill = Accent.wash
        static let optionSelectedStroke = Accent.base.opacity(0.55)
        static let focusFill = Highlight.hover

        // MARK: Type

        static let title = Font.system(size: 13, weight: .semibold)
        static let who = Font.system(size: 11.5, weight: .medium)
        static let body = Font.system(size: 12.5)
        static let bodyStrong = Font.system(size: 12.5, weight: .medium)
        static let detail = Font.system(size: 12)
        static let mono = Font.system(size: 12.5, design: .monospaced)
        static let button = Font.system(size: 12.5, weight: .medium)
        static let stepper = Font.system(size: 11.5, weight: .medium)
        static let stepperChevron = Font.system(size: 9, weight: .semibold)
        static let icon = Font.system(size: 12, weight: .semibold)
    }
}
