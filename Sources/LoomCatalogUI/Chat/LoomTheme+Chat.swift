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

        /// A one-line work row (DESIGN §7): 26 pt, its hover pill hanging `workRowPaddingH` outside the column so the icon
        /// stands on the column's edge.
        static let workRowHeight: CGFloat = InkHeight.control
        static let workRowRadius: CGFloat = InkRadius.row
        static let workRowPaddingH: CGFloat = 8
        static let iconSlot: CGFloat = 16
        /// One step of nesting (the tools of an open group).
        static let indentStep: CGFloat = 16
        static let blockSpacing: CGFloat = 12
        static let cardPadding: CGFloat = 12
        /// A card of the stream (the subagent and changed-files cards, the plan card): raised 1, radius 12.
        static let cardRadius: CGFloat = InkRadius.card
        /// A code block and an output box: raised 1, radius 8.
        static let codeRadius: CGFloat = InkRadius.row
        static let codeHeaderHeight: CGFloat = 30
        /// A code block's padding: 10 above, 14 aside, 12 below (the reference's optical values, off the 4 pt grid).
        static let codePaddingTop: CGFloat = 10
        static let codePaddingH: CGFloat = 14
        static let codePaddingBottom: CGFloat = 12
        /// A tool's output box (the reference's `.out`): a 28 pt header, text of 11.5 / 18, up to 306 high.
        static let outputHeaderHeight: CGFloat = 28
        static let outputFooterHeight: CGFloat = 30
        static let outputLineHeight: CGFloat = 18
        static let outputPaddingTop: CGFloat = 8
        static let outputPaddingH: CGFloat = 12
        static let outputPaddingBottom: CGFloat = 10
        static let outputMaxLines = 16
        /// 16 lines and the padding: 306.
        static var outputMaxHeight: CGFloat { CGFloat(outputMaxLines) * outputLineHeight + outputPaddingTop + outputPaddingBottom }
        /// A failed command's edge: the failure colour at 36 %, its header's rule at 22 %.
        static let failureEdgeOpacity = 0.36
        static let failureRuleOpacity = 0.22
        static let bodyLineHeight: CGFloat = InkType.code.lineHeight ?? 20
        /// The body of an opened row under its icon: 24 in, 3 above and 10 below (`.wbody`).
        static let bodyInset: CGFloat = iconSlot + 8
        static let bodyTop: CGFloat = 3
        static let bodyBottom: CGFloat = 10
        /// A diff's gutter (the sign) and the lines' height.
        static let diffGutter: CGFloat = 22
        /// A table row, and the line under a settled answer.
        static let tableRowHeight: CGFloat = InkHeight.field
        static let replyFooterHeight: CGFloat = 18
        static let diffLineHeight: CGFloat = 20
        static let diffMaxLines = 200
        static let failedTailLines = 12
        static let thoughtLineLimit = 4
        /// Your message: at most 80 % of the column and 560 wide, padded 9 × 14 (an optical value, off the 4 pt grid).
        static let userMaxWidthFraction: CGFloat = 0.8
        static let userMaxWidth: CGFloat = 560
        static let userPaddingH: CGFloat = 14
        static let userPaddingV: CGFloat = 9
        /// Above your message (the turn's rhythm) and the height of the line under it.
        static let userTopGap: CGFloat = 20
        static let userFooterHeight: CGFloat = 26
        static let userCollapsedLines = 7
        static let userCollapseCharacters = 600
        static let userCollapseLines = 8
        static let planCollapseCharacters = 900
        static let planCollapseLines = 20
        static let planPreviewLines = 10
        /// A marker: a 16 pt line with 20 above and below (28 from its label's middle to the next row).
        static let markerLineHeight: CGFloat = 16
        static let markerPaddingV: CGFloat = 20
        static let markerHeight: CGFloat = markerLineHeight + 2 * markerPaddingV
        static let markerGap: CGFloat = 12
        static let jumpPillHeight: CGFloat = InkHeight.sidebarRow
        /// The turn fold and the live row are 28 pt lines (DESIGN §3 Heights).
        static let foldHeight: CGFloat = InkHeight.sidebarRow
        static let liveHeight: CGFloat = InkHeight.sidebarRow
        /// The live thought sits 21 in, as the live row's text does.
        static let thoughtInset: CGFloat = 21
        /// The subagent card (`.acard`) and its group header.
        static let agentCardRadius: CGFloat = InkRadius.card
        static let agentCardPaddingH: CGFloat = 12
        static let agentCardPaddingV: CGFloat = 10
        static let agentsHeaderHeight: CGFloat = InkHeight.control
        /// The changed-files card: a 40 pt header, 28 pt folders, 29 pt files (the reference's own).
        static let changesHeaderHeight: CGFloat = 40
        static let changesFolderHeight: CGFloat = 28
        static let changesFileHeight: CGFloat = 29
        /// The view chip: 24 pt, radius 6, the canvas at 92 % under it.
        static let viewChipHeight: CGFloat = 24
        static let viewChipFillOpacity = 0.92
        /// The chip's key cap (\u{2303}O): mono 10, radius 4.
        static let keyCap = Font.system(size: 10, design: .monospaced)
        static let jumpPillPaddingLeading: CGFloat = 9
        static let jumpPillPaddingTrailing: CGFloat = 12
        /// Below this stream width the view chip shrinks to its glyph and key: the full chip would sit over the
        /// text, which fills the pane once it is narrower than the reading column.
        static let chipCompactBelow: CGFloat = 700
        /// Below this stream height (a card, the banner and the composer take the rest) the view chip is not drawn.
        static let viewChipMinimumStreamHeight: CGFloat = 90

        // MARK: Tree

        /// The stream's two trees (DESIGN §7), in the tree colour: the steps of an open group branch from its icon, and the
        /// work of an open turn fold hangs on a guide. Offsets are the reference's own and stay off the 4 pt grid (§3).
        enum Tree {
            /// A group's branch: its line's left edge from the column's edge (the icon's centre), the turn's radius and the arm
            /// that reaches the next step's icon.
            static let groupLine: CGFloat = 8
            static let curveRadius: CGFloat = 6
            static let arm: CGFloat = 7
            /// A step's line starts this far above its row, where it leaves the group's icon.
            static let overhang: CGFloat = 7
            /// The turn fold's guide: its left edge, and the indent the folded work takes.
            static let foldGuide: CGFloat = 7
            static let foldIndent: CGFloat = 22
            /// The guide stops this far above the end of the last folded row.
            static let foldGuideEnd: CGFloat = 10
            static let lineWidth: CGFloat = Line.hairline
        }

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

        /// New rows and the Jump to Latest pill fade in over 150 ms; Reduce Motion makes it instant.
        static let fadeDuration = 0.15
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
        static let metaMono = InkType.metaLarge.font
        /// Times and counts on a row: mono 11.
        static let timeMono = InkType.meta.font
        static let body = InkType.code.font
        /// A tool's output: mono 11.5 on 18 pt lines.
        static let outputFont = Font.system(size: 11.5, design: .monospaced)
        static let linkLabel = Font.system(size: 11.5, weight: .medium)
        static let linkSymbol = Font.system(size: 13)
        /// A link and an icon button of a row: 22 pt.
        static let linkHeight: CGFloat = InkHeight.chip
        static let thoughtText = Font.system(size: 12.5)
        static let thinkingLabel = Font.system(size: 12.5)
        static let thinkingText = Font.system(size: 12.5).italic()
        static let thinkingMark = Font.system(size: 13, weight: .semibold, design: .monospaced)
        static let heading1 = Font.system(size: 17, weight: .semibold)
        static let heading2 = Font.system(size: 15.5, weight: .semibold)
        static let heading3 = Font.system(size: 14.5, weight: .semibold)
        static let markerText = InkType.meta.font
        static let chevron = Font.system(size: 9, weight: .semibold)
        static let rowIcon = Font.system(size: 12)
        /// A work row's icon: 14 in a 16 slot.
        static let workIcon = Font.system(size: 14)
        static let cardIcon = Font.system(size: 13)
        static let jumpPill = Font.system(size: 12, weight: .medium)
        /// The live thought: italic 12.5 / 19; a thinking block's text: italic 12.5 / 20.
        static let thoughtLineHeight: CGFloat = 19
        static let thinkingLineHeight: CGFloat = 20
        static let viewChip = Font.system(size: 11.5, weight: .medium)

        // MARK: Line spacing

        /// The spacing that makes lines of `font` as high as `lineHeight` (SwiftUI adds spacing to the font's own line).
        static func lineSpacing(size: CGFloat, mono: Bool, lineHeight: CGFloat) -> CGFloat {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
            return max(0, lineHeight - (font.ascender - font.descender + font.leading))
        }

        static let outputLineSpacing = lineSpacing(size: 11.5, mono: true, lineHeight: outputLineHeight)
        static let codeLineSpacing = lineSpacing(size: 12.5, mono: true, lineHeight: bodyLineHeight)
        static let thoughtLineSpacing = lineSpacing(size: 12.5, mono: false, lineHeight: thoughtLineHeight)
        static let thinkingLineSpacing = lineSpacing(size: 12.5, mono: false, lineHeight: thinkingLineHeight)

        // MARK: Colour

        /// Your message: the bubble fill (white 7 % in Ink, ink 6 % in Paper) with no edge, radius 12.
        static let bubbleTone = overlay(dark: 0.07, light: 0.06)
        static let userFill = bubbleTone.color
        static let userRadius: CGFloat = InkRadius.card
        static let hoverFill = Highlight.hover
        static let inlineCodeFill = Surface.hoverTone.color
        static let inlineCodePair = Text.primaryPair
        static let inlineCodeRGB = inlineCodePair.dark
        static let inlineCode = inlineCodePair.color
        /// A command's output is a code card: raised 1 (follows the tone, so computed, never stored).
        static var outputFill: Color { Surface.raised1 }
        static let outputPair = Text.secondaryPair
        static let outputRGB = outputPair.dark
        static let output = outputPair.color
        static let diffAddFill = Changes.addedBand
        static let diffRemoveFill = Changes.removedBand
        static let diffAdd = Success.light
        static let diffRemove = Status.failureLight
        static let quoteBar = Surface.strongerHairline
        static let tableHeaderFill = Surface.control
        /// A card of the stream (raised 1; follows the tone, so computed).
        static var cardFill: Color { Surface.raised1 }
        /// The jump pill's and the view chip's fills.
        /// The jump pill and other fills that are a panel level follow the tone, so they are computed.
        static var jumpFill: Color { Surface.popover }
        static let foldFill = Surface.hoverTone.color
        static var viewChipFill: Color { Surface.canvas.opacity(viewChipFillOpacity) }

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
