import AppKit
import LoomCore
import SwiftUI

/// Values of the Settings window and About (DESIGN §2 item 5, §6; the reference's `settings.css`: `.swin`, `.stitle`, `.sbody`, `.slab`,
/// `.scard`, `.srw`, `.popup`, `.stepper`, `.cbx`, `.ttile`, `.ucard`, `.crow`, `.about`). Colours, hairlines and text tones are the
/// existing tokens; the type is Ink's (`InkType`). Several sizes are the reference's own optical values (22, 26, 11, 14 …) and sit off
/// the 4 pt grid on purpose; `HighlightTests` pins only the grid ones.
extension LoomTheme {
    enum Settings {
        // MARK: The window

        /// The window is 680×520 on the canvas. Its band is the header's 52, where the title would be; the section tabs sit at the band's
        /// bottom edge, centred, on the band's hairline.
        static let width: CGFloat = 680
        static let height: CGFloat = 520
        static let bandHeight = InkHeight.header
        /// A section's content scrolls under the band: 32 at the sides, 22 above and 26 below.
        static let bodyInset: CGFloat = 32
        static let bodyTop: CGFloat = 22
        static let bodyBottom: CGFloat = 26
        /// Groups are 20 apart.
        static let groupGap: CGFloat = 20

        // MARK: A footer (Usage and Sessions)

        static let footerHeight: CGFloat = 32
        static let footerTrailing: CGFloat = 10
        static let footerGap: CGFloat = 8
        static let footerText = InkType.meta
        static let footerButton = CGSize(width: 24, height: 24)
        static let footerGlyph = Font.system(size: 14)

        // MARK: A group label

        /// The label over a card: capitals, 2 in from the card's edge and 8 above it; a link-style button ends the line.
        static let labelLeading: CGFloat = 2
        /// The label's line is as high as its size (the reference's `line-height: 1`), 8 above the card.
        static let labelLine = InkType.label.size
        static let labelBottom: CGFloat = 8
        static let labelGap: CGFloat = 10
        static let linkHeight: CGFloat = 18
        static let linkFont = InkStyle(size: 11.5, weight: .medium)
        static let linkPaddingH: CGFloat = 6
        static let linkRadius = InkRadius.control
        static let linkDisabled = 0.45

        // MARK: A card and its rows

        /// A card: raised 1, radius 12, a hairline edge and the card's depth.
        static let cardRadius = InkRadius.card
        /// A card of rows (D-88, the reference's drawing): the rows sit 5 below the card's top and 6 above its bottom, 16 in from its
        /// leading edge and 8 from its trailing one. A row's content so starts 32 in and ends 24 from the trailing edge, and the rule
        /// between two rows runs from 16 to 8 inside the card. Usage's cards keep their own padding.
        static let rowsInsetTop: CGFloat = 5
        static let rowsInsetBottom: CGFloat = 6
        static let rowsInsetLeading: CGFloat = 16
        static let rowsInsetTrailing: CGFloat = 8
        /// A row: at least 48 high, 11 above and below, 16 inside the rows' inset, 20 between its text and its control.
        static let rowMinHeight: CGFloat = 48
        static let rowPaddingV: CGFloat = 11
        static let rowPaddingH: CGFloat = 16
        static let rowGap: CGFloat = 20
        /// The label in 13 on 18; the help in 12 on 17, at most 380 wide and 2 below; a notice from macOS in 12 on 17, 5 below.
        static let rowTitle = InkType.body
        static let rowTitleLine: CGFloat = 18
        static let rowHelp = InkType.small
        static let rowHelpLine: CGFloat = 17
        static let helpMaxWidth: CGFloat = 380
        static let helpTop: CGFloat = 2
        static let noticeTop: CGFloat = 5
        /// A row's controls are 8 apart.
        static let controlGap: CGFloat = 8
        /// A path in the facts: mono 12, at most 280 wide.
        static let path = InkStyle(size: 12, mono: true)
        static let pathMaxWidth: CGFloat = 280
        /// A stacked row (the tiles under the text) puts its content 12 below the text.
        static let stackTop: CGFloat = 12

        /// The spacing that makes lines of a face as high as `lineHeight` (SwiftUI adds spacing to the font's own line).
        static func lineSpacing(size: CGFloat, mono: Bool = false, lineHeight: CGFloat) -> CGFloat {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
            return max(0, lineHeight - (font.ascender - font.descender + font.leading))
        }

        /// How far a face's glyphs move down in an exact line box to sit as the reference's do. CoreText leaves an exact line's
        /// extra room under the glyphs; CSS splits it above and below. The face's own line is its ascender and descender, each
        /// to a whole point (15 for 12 pt), so 12 pt help in a 17 line moves down 1.
        static func glyphDrop(size: CGFloat, mono: Bool = false, lineHeight: CGFloat) -> CGFloat {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
            return max(0, (lineHeight - (font.ascender.rounded(.up) + (-font.descender).rounded(.up))) / 2)
        }

        // MARK: The popup (a menu picker)

        /// A secondary button with the value and two chevrons: 26 high, radius 6, 10 in on the left and 6 on the right, 8 between.
        static let popupHeight = InkHeight.control
        static let popupRadius = InkRadius.control
        static let popupPaddingLeading: CGFloat = 10
        static let popupPaddingTrailing: CGFloat = 6
        static let popupGap: CGFloat = 8
        static let popupFont = InkStyle(size: 12.5)
        static let popupChevron = Font.system(size: 12)
        /// The Mode picker shows the mode's icon (13) in its tone before the value.
        static let popupIcon = Font.system(size: 13)

        // MARK: The segmented control

        /// A 26 group of radius 7 on the hover fill, 2 inside and between; a segment is 22 high with radius 5 and 10 beside its words. The
        /// chosen one is raised: Segment on, a strong hairline and a 1 pt drop.
        static let segmentGroupHeight = InkHeight.control
        static let segmentGroupRadius = InkRadius.group
        static let segmentPadding: CGFloat = 2
        static let segmentGap: CGFloat = 2
        static let segmentHeight: CGFloat = 22
        static let segmentRadius = InkRadius.groupInner
        static let segmentPaddingH: CGFloat = 10
        static let segmentFont = InkStyle(size: 12, weight: .medium)
        static let segmentDrop = Color.black.opacity(0.22)
        static let segmentDropRadius: CGFloat = 1
        static let segmentDropY: CGFloat = 1

        // MARK: The switch

        /// 28×16, a 12 pt knob 2 in, the accent when on, the stronger hairline when off; a disabled one is drawn at 38 %.
        static let switchSize = CGSize(width: 28, height: 16)
        static let switchKnob: CGFloat = 12
        static let switchInset: CGFloat = 2
        static var switchOffFill: Color { Surface.strongerHairline }
        static var switchOnFill: Color { Accent.base }
        static let switchKnobFill = Color.white
        static let switchKnobShadow = Color.black.opacity(0.35)

        // MARK: The stepper

        /// 26 high, radius 7, a strong-hairline edge; the buttons are 26 wide with a 12 pt glyph; the value is mono 12, at least 64 wide
        /// between two hairlines.
        static let stepperHeight = InkHeight.control
        static let stepperRadius = InkRadius.group
        static let stepperButton: CGFloat = 26
        static let stepperGlyph = Font.system(size: 12, weight: .medium)
        static let stepperValue = InkStyle(size: 12, mono: true)
        static let stepperValueMinWidth: CGFloat = 64

        // MARK: The checkbox

        /// 14×14, radius 4, the stronger hairline for an edge; checked it is the accent with a 10 pt on-accent check. The click answers
        /// over at least 24×24 (`hit`).
        static let checkboxSide: CGFloat = 14
        static let checkboxRadius = InkRadius.key
        static let checkboxGlyph = Font.system(size: 10, weight: .bold)
        static let checkboxHit: CGFloat = 24

        // MARK: Theme: the sidebar's fill preview

        /// The picture beside the fill choices (FB6-6): 44 × 26, radius 6, the fill at the chosen step over the canvas.
        static let sidebarPreviewWidth: CGFloat = 44
        static let sidebarPreviewHeight = InkHeight.control
        static let sidebarPreviewRadius = InkRadius.control

        // MARK: Theme: the tone tiles

        /// Three tiles in a grid, 10 apart; a tile has radius 10, 6 inside, a hairline edge; selected it takes the selected fill and a
        /// 1.5 pt accent edge.
        static let tileGap: CGFloat = 10
        static let tileRadius = InkRadius.activityCard
        static let tilePadding: CGFloat = 6
        static let tileSelectedEdge: CGFloat = 1.5
        /// The pane in miniature: 58 high, radius 6.
        static let miniHeight: CGFloat = 58
        static let miniRadius = InkRadius.control
        /// The sidebar strip is the left 28 %, closed by a hairline.
        static let miniSidebar = 0.28
        /// Two text lines (7 % and 22 pt in, 4 high, radius 3) at 55 % and 30 % of the primary text.
        static let miniLineLeading = 0.07
        static let miniLineHeight: CGFloat = 4
        static let miniLineRadius: CGFloat = 3
        static let miniLine1 = (top: CGFloat(12), width: 0.13, opacity: 0.55)
        static let miniLine2 = (top: CGFloat(22), width: 0.10, opacity: 0.30)
        /// The card: left 36 %, right 8 %, 10 down, 18 high, raised 1, a hairline, radius 5.
        static let miniCard = (left: 0.36, right: 0.08, top: CGFloat(10), height: CGFloat(18), radius: CGFloat(5))
        /// The composer: left 42 %, right 14 %, 8 up, 14 high, raised 2, radius 7.
        static let miniComposer = (left: 0.42, right: 0.14, bottom: CGFloat(8), height: CGFloat(14), radius: CGFloat(7))
        /// The accent capsule: 12×6, 24 left of the right edge's 92 %, 12 up.
        static let miniAccent = (right: 0.92, back: CGFloat(24), bottom: CGFloat(12), width: CGFloat(12), height: CGFloat(6))
        static let tileName = InkStyle(size: 12.5, weight: .medium)
        static let tileNameTop: CGFloat = 7
        static let tileDetail = InkStyle(size: 11.5)
        static let tileDetailLine: CGFloat = 15
        static let tileDetailTop: CGFloat = 1
        static let tileTextInset: CGFloat = 2
        static let tileBottom: CGFloat = 2
        static let tileDetailDrop = glyphDrop(size: 11.5, lineHeight: tileDetailLine)
        /// The miniature's edge and text in Ink and in Paper (`--tl`, `--tf`).
        static let miniEdge = AdaptiveTone(dark: Tone(rgb: whiteRGB, opacity: 0.09), light: Tone(rgb: inkRGB, opacity: 0.10))

        // MARK: Usage

        /// The period line: 12 secondary and the segments at the trailing end, 14 below.
        static let periodText = InkType.small
        static let periodBottom: CGFloat = 14
        static let periodGap: CGFloat = 12
        /// A card: 14 above, 16 at the sides and below; cards are 12 apart. The head is baseline-aligned, 12 above the content.
        static let cardPaddingTop: CGFloat = 14
        static let cardPaddingH: CGFloat = 16
        static let cardPaddingBottom: CGFloat = 16
        static let cardGap: CGFloat = 12
        static let headTitle = InkStyle(size: 13, weight: .semibold)
        static let headMeta = InkType.meta
        static let headGap: CGFloat = 10
        static let headBottom: CGFloat = 12
        /// The title of what a harness says instead of limit windows.
        static let limitLabel = InkStyle(size: 12.5)
        /// The Limits section: groups 22 apart; inside a card the pace line and the read time are 8 apart.
        static let limitGroupGap: CGFloat = 22
        static let limitCardGap: CGFloat = 8
        /// Codex's card: the daily line is 14 below the total, and the lifetime row 14 under the line.
        static let codexBarsTop: CGFloat = 14
        /// The period card: 200 and the rest, 24 apart. The total is 30 semibold with tabular figures; captions 11.5; the cost 15
        /// semibold, 12 below the caption; the fine print 11 on 15, 10 below.
        static let summaryWidth: CGFloat = 200
        static let summaryGap: CGFloat = 24
        static let total = InkStyle(size: 30, weight: .semibold, tracking: -0.01)
        static let totalLine: CGFloat = 33
        static let caption = InkStyle(size: 11.5)
        static let captionTop: CGFloat = 2
        static let cost = InkStyle(size: 15, weight: .semibold)
        static let costTop: CGFloat = 12
        static let fine = InkStyle(size: 11)
        static let fineLine: CGFloat = 15
        static let fineTop: CGFloat = 10
        static let fineDrop = glyphDrop(size: 11, lineHeight: fineLine)
        /// The kinds: a grid of 96, flexible and 56, 10 apart, 24 high; a 3 pt bar of radius 2; the cache line is 6 below with a hairline
        /// above and 8 of padding.
        static let kindColumns = (label: CGFloat(96), value: CGFloat(56))
        static let kindGap: CGFloat = 10
        static let kindHeight: CGFloat = 24
        static let kindLabel = InkType.small
        static let kindValue = InkType.metaLarge
        static let kindBar: CGFloat = 3
        static let kindBarRadius: CGFloat = 2
        static let cacheTop: CGFloat = 6
        static let cachePadding: CGFloat = 8
        static let cacheValue = InkStyle(size: 12, weight: .medium, mono: true)
        /// The bars: 72 high, 4 apart, radius 2 on the top corners; the axis is mono 10.5, 6 below.
        static let barsHeight: CGFloat = 72
        static let barGap: CGFloat = 4
        static let barRadius: CGFloat = 2
        static let axis = InkStyle(size: 10.5, mono: true)
        static let axisTop: CGFloat = 6
        /// The local five hours: 12 below the axis, a hairline and 12 of padding; cells are 26×14 with radius 3, 3 apart; the total is
        /// mono 12 medium, 46 wide; the hour labels are mono 10, 4 below, 56 short of the right edge.
        static let heatTop: CGFloat = 12
        static let heatPadding: CGFloat = 12
        static let heatGap: CGFloat = 10
        static let heatLabel = InkType.small
        static let heatCell = CGSize(width: 26, height: 14)
        static let heatCellRadius: CGFloat = 3
        static let heatCellGap: CGFloat = 3
        static let heatTotal = InkStyle(size: 12, weight: .medium, mono: true)
        static let heatTotalWidth: CGFloat = 46
        static let hourLabel = InkStyle(size: 10, mono: true)
        static let hourLabelTop: CGFloat = 4
        static let hourLabelTrailing: CGFloat = 56
        /// By model: a grid of the name and 72, 110 and 72, 12 apart; rows 28 high with a hairline above, the header 22.
        static let modelColumns = (tokens: CGFloat(72), share: CGFloat(110), cost: CGFloat(72))
        static let modelGap: CGFloat = 12
        static let modelRowHeight: CGFloat = 28
        static let modelHeaderHeight: CGFloat = 22
        static let modelName = InkStyle(size: 12.5)
        static let modelHeader = InkStyle(size: 11, weight: .medium)
        static let modelFigure = InkStyle(size: 12, mono: true)
        static let modelShare = InkType.metaLarge
        static let shareBar = CGSize(width: 48, height: 3)
        static let shareGap: CGFloat = 8
        /// A page state: the title (20 semibold), the text in 12.5 on 1.55, at most 420 wide, 8 below, the path 10 below, the button 14.
        static let noteTop: CGFloat = 70
        static let noteText = InkStyle(size: 12.5)
        static let noteLine: CGFloat = 19.4
        static let noteTextTop: CGFloat = 8
        static let noteMaxWidth: CGFloat = 420
        static let notePath = InkStyle(size: 12, mono: true)
        static let notePathTop: CGFloat = 10
        static let noteButtonTop: CGFloat = 14
        static let noteDrop = glyphDrop(size: 12.5, lineHeight: noteLine)

        // MARK: Sessions

        /// The due line: a card line (raised 1, radius 10, a hairline), 9 above and below, 14 and 10 at the sides, 10 between, 18 below.
        static let dueRadius = InkRadius.activityCard
        static let duePaddingV: CGFloat = 9
        static let duePaddingLeading: CGFloat = 14
        static let duePaddingTrailing: CGFloat = 10
        static let dueGap: CGFloat = 10
        static let dueBottom: CGFloat = 18
        static let dueText = InkStyle(size: 12.5)
        static let dueGlyph = Font.system(size: 14)
        /// A session row: at least 44, 8 above and below, 16 in, 12 between; the title 13 on 18, the line under it mono 11 on 16.
        static let sessionMinHeight: CGFloat = 44
        static let sessionPaddingV: CGFloat = 8
        static let sessionGap: CGFloat = 12
        static let sessionTitle = InkType.body
        static let sessionTitleLine: CGFloat = 18
        static let sessionSub = InkType.meta
        static let sessionSubLine: CGFloat = 16
        static let sessionWhy = InkType.small
        static let sessionResultMaxWidth: CGFloat = 260
        /// The note under the Cleanup card: 12 tertiary, 8 below.
        static let changedNote = InkType.small
        static let changedNoteTop: CGFloat = 8

        // MARK: About

        /// The icon is 64 (the image already carries macOS's shape), with a 1 pt ring and top highlight and a 1 pt drop; the name is title
        /// type 12 below it and the version mono 11.5 tertiary 4 below; the head is 42 from the top and the card 36 below it.
        static let iconSide: CGFloat = 64
        static let iconRadius: CGFloat = 14.336
        static let iconRing = Color.white.opacity(0.13)
        static let iconHighlight = Color.white.opacity(0.16)
        static let iconDrop = Color.black.opacity(0.35)
        static let aboutTop: CGFloat = 42
        static let aboutNameTop: CGFloat = 12
        static let aboutVersionTop: CGFloat = 4
        static let aboutCardTop: CGFloat = 36
    }
}

// MARK: Connections

extension LoomTheme {
    /// Settings → Connections and Home's "Connect your agents" (D-98): the harness rows, the status dot, the setup command's field
    /// and Deep Check's output. Sizes are Settings' own (a row is `Settings.rowMinHeight` high, its text 13 and 12).
    enum Connect {
        /// A harness row: the mark (13), 12 to the name and version, then the status dot (8), 8 from its headline, the switch last.
        static let rowGap: CGFloat = 12
        static let markSize = Layout.harnessMarkHeader
        static let dot: CGFloat = 8
        static let dotGap: CGFloat = 8
        /// The name over its version in mono 11; the headline in 12 at most 250 wide.
        static let name = InkType.body
        static let version = InkType.meta
        static let versionTop: CGFloat = 1
        static let headline = InkType.small
        static let headlineMaxWidth: CGFloat = 250
        /// A picked row takes the control's hover fill, over the card's row inset.
        static let pickedRadius = InkRadius.row
        /// "Account changed" under the headline: mono 11 in the attention text.
        static let changed = InkType.meta
        static let note = InkType.small
        static let noteTop: CGFloat = 8

        /// The setup command: a field of radius 6 on the control fill, mono 12, 8 under the line above; Copy and Open Terminal 8 apart.
        static let commandFont = Settings.path
        static let commandPaddingH: CGFloat = 10
        static let commandPaddingV: CGFloat = 7
        static let commandRadius = InkRadius.control
        static let commandGap: CGFloat = 8
        static let commandTop: CGFloat = 10
        static var commandFill: Color { Surface.control }
        static let alternative = InkType.meta

        /// Deep Check's output: mono 11.5, at most 220 high, scrolling, 10 inside a field like the command's.
        static let deepFont = InkType.metaLarge
        static let deepMaxHeight: CGFloat = 220
        static let deepPadding: CGFloat = 10

        /// The dot of a state: the accent when ready, the attention dot while something must be done, the failure dot when a
        /// check could not tell, and quiet greys for a harness that is off or being checked.
        static func dotColor(_ state: HarnessHealthState) -> Color {
            switch state {
            case .ready: Accent.base
            case .install, .signIn: Status.attention
            case .attention: Status.failure
            case .checking: Text.tertiary
            case .disabled: Surface.strongerHairline
            }
        }

        /// The tab band's room for the section tabs: 680 less the same reserve at each side, where the close button sits at the
        /// left (its 52 pt band centres the tabs between the window's edges).
        static let tabsReserve: CGFloat = 96
    }
}
