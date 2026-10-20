import AppKit
import SwiftUI

/// Chat stream tokens (CHAT-SPEC → Stream, concept §6.1/§6.2): geometry, type and the syntax palette of code
/// blocks. Values that exist in the Ink roles are used from there (`Surface`, `Text`, `Accent`, `Status`,
/// `Success`, `Radius`, `TypeScale`, `Rhythm`); only what the chat adds lives here. This file is exempt from the theme
/// guard like every `LoomTheme*.swift`.
extension LoomTheme {
    enum Chat {
        // MARK: Geometry

        /// The reading column (700) with its side padding; rows centre in the panel.
        static let column = Rhythm.readingColumn
        static let columnPadding: CGFloat = 32
        static let streamTopInset: CGFloat = 12
        static let streamBottomInset: CGFloat = 20

        /// A one-line work row: icon, label, time on hover, chevron (spec: about 24 pt; the prototype draws 30).
        static let workRowHeight: CGFloat = 26
        static let workRowRadius: CGFloat = Radius.md
        static let workRowPaddingH: CGFloat = 12
        static let iconSlot: CGFloat = 16
        /// One step of nesting (the tools of an open group).
        static let indentStep: CGFloat = 16
        static let blockSpacing: CGFloat = 12
        static let cardPadding: CGFloat = 12
        static let cardRadius: CGFloat = Radius.lg
        static let codeRadius: CGFloat = Radius.md
        static let codeHeaderHeight: CGFloat = 26
        static let bodyMaxHeight: CGFloat = 16 * 19 + 14
        static let bodyLineHeight: CGFloat = 19
        static let diffMaxLines = 200
        static let failedTailLines = 12
        static let thoughtLineLimit = 4
        static let userMaxWidthFraction: CGFloat = 0.82
        static let userCollapsedLines = 7
        static let userCollapseCharacters = 600
        static let userCollapseLines = 8
        static let planCollapseCharacters = 900
        static let planCollapseLines = 20
        static let planPreviewLines = 10
        static let markerHeight: CGFloat = 28
        static let jumpPillHeight: CGFloat = 28
        /// Below this stream width the view chip shrinks to its glyph and key: the full chip would sit over the
        /// text, which fills the pane once it is narrower than the reading column.
        static let chipCompactBelow: CGFloat = 700
        /// Below this stream height (a card, the banner and the composer take the rest) the view chip is not drawn.
        static let viewChipMinimumStreamHeight: CGFloat = 90

        // MARK: Scroll latch

        /// Back to following only within this distance of the true content bottom (CHAT-SPEC → Scrolling).
        static let followDistance: CGFloat = 40
        /// "Jump to latest" appears this long after the reader leaves the end.
        static let jumpDelay: TimeInterval = 0.15
        /// A sent message scrolls to this far below the top.
        static let sendAnchorOffset: CGFloat = 24
        /// The stream asks for older turns when the top is within this many viewports.
        static let olderTriggerViewports: CGFloat = 1
        /// Keyboard line step.
        static let lineStep: CGFloat = 44

        // MARK: Timing

        /// New blocks fade in; Reduce Motion makes it instant.
        static let fadeDuration = 0.18
        /// "No activity" after this long with nothing new.
        static let quietAfter: TimeInterval = 40
        /// Copy shows "Copied" for this long.
        static let copiedDuration: TimeInterval = 1.2

        // MARK: Type

        static let reading = TypeScale.reading
        /// 22 pt lines with the 14 pt reading size.
        static let readingLineSpacing: CGFloat = TypeScale.readingLineHeight - TypeScale.readingSize * 1.2
        static let readingMono = Font.system(size: 12.5, design: .monospaced)
        static let toolLabel = Font.system(size: 12.5)
        static let toolLabelStrong = Font.system(size: 12.5, weight: .medium)
        static let toolMono = Font.system(size: 12, design: .monospaced)
        static let meta = Font.system(size: 11.5)
        static let metaMono = Font.system(size: 11.5, design: .monospaced)
        static let body = Font.system(size: 12.5, design: .monospaced)
        static let thinkingLabel = Font.system(size: 12.5)
        static let thinkingText = Font.system(size: 13).italic()
        static let heading1 = Font.system(size: 17, weight: .semibold)
        static let heading2 = Font.system(size: 15.5, weight: .semibold)
        static let heading3 = Font.system(size: 14.5, weight: .semibold)
        static let markerText = Font.system(size: 11.5)
        static let chevron = Font.system(size: 9, weight: .semibold)
        static let rowIcon = Font.system(size: 12)
        static let cardIcon = Font.system(size: 13)
        static let jumpPill = Font.system(size: 12, weight: .medium)
        static let viewChip = Font.system(size: 11, weight: .medium)

        // MARK: Colour

        /// Your message: an accent wash with a thin accent line (the prototype's `.um`).
        static let userFill = Accent.base.opacity(0.12)
        static let userStroke = Accent.base.opacity(0.20)
        static let userRadius: CGFloat = 16
        static let userTailRadius: CGFloat = 5
        static let hoverFill = Highlight.hover
        static let inlineCodeFill = Surface.selectedTone.color
        static let inlineCodePair = Adaptive(dark: RGB(hex: 0xE3DFF0), light: RGB(hex: 0x3B3550))
        static let inlineCodeRGB = inlineCodePair.dark
        static let inlineCode = inlineCodePair.color
        /// A command's output is a code card: raised 1 (follows the tone, so computed, never stored).
        static var outputFill: Color { Surface.raised1 }
        static let outputPair = Adaptive(dark: RGB(hex: 0xB9B5C6), light: RGB(hex: 0x5A5568))
        static let outputRGB = outputPair.dark
        static let output = outputPair.color
        static let diffAddFill = Changes.addedBand
        static let diffRemoveFill = Changes.removedBand
        static let diffAdd = Success.light
        static let diffRemove = Status.failureLight
        static let quoteBar = Surface.strongerHairline
        static let tableHeaderFill = Surface.control
        /// The jump pill and other fills that are a panel level follow the tone, so they are computed.
        static var jumpFill: Color { Surface.popover }
        static let foldFill = Surface.hoverTone.color
        static let agentBadgeFill = Accent.wash

        // MARK: Syntax (VS Code Dark+, the terminal's palette; Light+ for the light theme, a step deeper where
        // a Light+ colour fell under 4.5:1 on a card)

        static let syntaxPlainPair = Adaptive(dark: RGB(hex: 0xCFCBDA), light: RGB(hex: 0x3B3846))
        static let syntaxKeywordPair = Adaptive(dark: RGB(hex: 0xC586C0), light: RGB(hex: 0x8F2D9A))
        static let syntaxFunctionPair = Adaptive(dark: RGB(hex: 0xDCDCAA), light: RGB(hex: 0x6F5620))
        static let syntaxStringPair = Adaptive(dark: RGB(hex: 0xCE9178), light: RGB(hex: 0x9C2B1E))
        static let syntaxCommentPair = Adaptive(dark: RGB(hex: 0x6A9955), light: RGB(hex: 0x2F6A2A))
        static let syntaxTypePair = Adaptive(dark: RGB(hex: 0x4EC9B0), light: RGB(hex: 0x176579))
        static let syntaxNumberPair = Adaptive(dark: RGB(hex: 0xB5CEA8), light: RGB(hex: 0x0A7048))
        static let syntaxPairs = [syntaxPlainPair, syntaxKeywordPair, syntaxFunctionPair, syntaxStringPair,
                                  syntaxCommentPair, syntaxTypePair, syntaxNumberPair]
        static let syntaxPlainRGB = syntaxPlainPair.dark
        static let syntaxKeywordRGB = syntaxKeywordPair.dark
        static let syntaxFunctionRGB = syntaxFunctionPair.dark
        static let syntaxStringRGB = syntaxStringPair.dark
        static let syntaxCommentRGB = syntaxCommentPair.dark
        static let syntaxTypeRGB = syntaxTypePair.dark
        static let syntaxNumberRGB = syntaxNumberPair.dark
        static let syntaxPlain = syntaxPlainPair.color
        static let syntaxKeyword = syntaxKeywordPair.color
        static let syntaxFunction = syntaxFunctionPair.color
        static let syntaxString = syntaxStringPair.color
        static let syntaxComment = syntaxCommentPair.color
        static let syntaxType = syntaxTypePair.color
        static let syntaxNumber = syntaxNumberPair.color

        // MARK: ANSI colours in command output (the 16 standard colours; black is lifted so it reads on the canvas;
        // in Light every colour is deep enough to read on a card)

        static let ansiStandardPairs: [Adaptive] = [
            (0x666666, 0x3A3A3A), (0xCD3131, 0xB8281F), (0x0DBC79, 0x0E6F39), (0xE5E510, 0x7A5F00),
            (0x2472C8, 0x1F5FBF), (0xBC3FBC, 0x8A3290), (0x11A8CD, 0x095F70), (0xE5E5E5, 0x5E5E66),
        ].map { Adaptive(dark: RGB(hex: $0.0), light: RGB(hex: $0.1)) }
        static let ansiBrightPairs: [Adaptive] = [
            (0x666666, 0x5A5A5A), (0xF14C4C, 0xB5251C), (0x23D18B, 0x0B6B35), (0xF5F543, 0x6C5400),
            (0x3B8EEA, 0x1A55B3), (0xD670D6, 0x8F2F95), (0x29B8DB, 0x0A6577), (0xFFFFFF, 0x4E4E57),
        ].map { Adaptive(dark: RGB(hex: $0.0), light: RGB(hex: $0.1)) }
        static let ansiStandard: [Color] = ansiStandardPairs.map(\.color)
        static let ansiBright: [Color] = ansiBrightPairs.map(\.color)

        // MARK: Small shapes

        static let thumbnail = CGSize(width: 96, height: 72)
        static let quoteBarWidth: CGFloat = 2
    }
}

extension LoomTheme.RGB {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}
