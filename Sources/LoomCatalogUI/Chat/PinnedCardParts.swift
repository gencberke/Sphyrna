import LoomChat
import SwiftUI

// The pieces every pinned card is built from (V18, DESIGN §12): the surface and the frame with its heading and counter, the
// buttons and the build-mode segments, the more menu, the code box and the keyboard region.

/// One button of a card. Nothing here is a default action: no button answers to Return, and Esc answers to none.
struct PinnedAction: Identifiable {
    /// A neutral button is the control family's secondary one, an accent button its filled one (the way forward), a segment is
    /// one choice of a group (a plan's build mode).
    enum Style { case neutral, accent, segment }

    let id: String
    let title: String
    var style: Style = .neutral
    /// A mode segment that is the current choice.
    var isOn = false
    var isEnabled = true
    /// A segment's glyph and tone (its mode's).
    var symbol: String?
    var tone: Color?
    let perform: () -> Void
}

/// The words of a card that its models do not word as commands: Title Case for what a button says (DESIGN §6 Voice).
enum PinnedCopy {
    private static let small: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to"]

    /// "Allow for this session" -> "Allow for This Session". A word that already has a capital inside ("WebFetch") stays;
    /// the first word is always capitalised.
    static func titleCase(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { index, word in
            let word = String(word)
            guard let first = word.first else { return word }
            if word.contains(where: \.isUppercase) { return word }
            if index > 0, small.contains(word) { return word }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// The mono hint of an approval: how the keys reach the card (E3).
    static let approvalHint = "tab to the request \u{00B7} \u{2190} \u{2192} \u{00B7} space"

    /// The mono hint of a question: the digits that pick, and where the user's own answer goes.
    static func questionHint(optionCount: Int) -> String {
        let digits = min(max(optionCount, 1), 9)
        return (digits == 1 ? "1" : "1\u{2013}\(digits)") + " pick \u{00B7} or write your own answer below"
    }
}

// MARK: Buttons

/// The control family's button on a card (26 high, radius 6, 12.5 medium): secondary with a strong-hairline edge, or filled with
/// the accent. The card's own ring (`isFocused`, moved with ← and →) is the family's focus ring; the button does not read the
/// system focus, which the card's key region holds for all of its buttons.
struct PinnedButtonStyle: ButtonStyle {
    let style: PinnedAction.Style
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, accent: style == .accent, isFocused: isFocused)
    }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        let accent: Bool
        let isFocused: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let active = enabled && hovering
            let pressed = enabled && configuration.isPressed
            let shape = RoundedRectangle(cornerRadius: LoomTheme.Pinned.buttonRadius)
            configuration.label
                .font(LoomTheme.InkType.button.font)
                .foregroundStyle(accent ? LoomTheme.Accent.onAccent : LoomTheme.Text.primary)
                .padding(.horizontal, LoomTheme.Pinned.buttonPaddingH)
                .frame(height: LoomTheme.Pinned.buttonHeight)
                .background(shape.fill(fill(active: active, pressed: pressed)))
                .overlay(shape.strokeBorder(edge(active: active), lineWidth: LoomTheme.Line.hairline))
                .controlFocusRing(visible: isFocused, radius: LoomTheme.Pinned.buttonRadius)
                .contentShape(shape)
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }

        private func fill(active: Bool, pressed: Bool) -> Color {
            if accent {
                if pressed { return LoomTheme.Accent.base.opacity(LoomTheme.Opacity.accentPressed) }
                return active ? LoomTheme.Control.primaryHover : LoomTheme.Accent.base
            }
            return pressed ? LoomTheme.Surface.pressed : (active ? LoomTheme.Surface.hover : .clear)
        }

        private func edge(active: Bool) -> AnyShapeStyle {
            guard !accent else { return AnyShapeStyle(Color.clear) }
            if contrast == .increased { return AnyShapeStyle(LoomTheme.Surface.hairlineStyle) }
            return AnyShapeStyle(active ? LoomTheme.Surface.strongerHairline : LoomTheme.Surface.strongHairline)
        }
    }
}

/// One choice of a segmented group (DESIGN §6 Tabs): 22 high, radius 5, in its own tone; the chosen one is raised (Segment on,
/// a strong hairline and a 1 pt drop).
struct PinnedSegmentStyle: ButtonStyle {
    let tone: Color
    let isOn: Bool
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, tone: tone, isOn: isOn, isFocused: isFocused)
    }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        let tone: Color
        let isOn: Bool
        let isFocused: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: LoomTheme.Pinned.segmentRadius)
            configuration.label
                .font(LoomTheme.Pinned.segment)
                .foregroundStyle(tone)
                .padding(.horizontal, LoomTheme.Pinned.segmentPaddingH)
                .frame(height: LoomTheme.Pinned.segmentHeight)
                .background {
                    if isOn {
                        shape.fill(LoomTheme.Surface.segmentOn)
                            .shadow(color: LoomTheme.Pinned.segmentDrop, radius: 1, x: 0, y: 1)
                            .overlay(shape.strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
                    } else if enabled && (hovering || configuration.isPressed) {
                        shape.fill(configuration.isPressed ? LoomTheme.Surface.pressed : LoomTheme.Surface.hover)
                    }
                }
                .controlFocusRing(visible: isFocused, radius: LoomTheme.Pinned.segmentRadius)
                .contentShape(shape)
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }
    }
}

/// A row of buttons; the one at `focused` wears the focus ring. Segments that follow one another are one group.
struct PinnedButtonRow: View {
    let actions: [PinnedAction]
    let focused: Int?
    /// The position of the first button among all of the card's buttons, when a card shows them in more than one row.
    var firstIndex = 0

    private enum Run: Identifiable {
        case button(offset: Int, PinnedAction)
        case segments([(offset: Int, action: PinnedAction)])

        var id: String {
            switch self {
            case let .button(_, action): action.id
            case let .segments(items): "segments:" + (items.first?.action.id ?? "")
            }
        }
    }

    private var runs: [Run] {
        var out: [Run] = []
        for (offset, action) in actions.enumerated() {
            if action.style == .segment {
                if case var .segments(items)? = out.last {
                    items.append((offset, action))
                    out[out.count - 1] = .segments(items)
                } else {
                    out.append(.segments([(offset, action)]))
                }
            } else {
                out.append(.button(offset: offset, action))
            }
        }
        return out
    }

    var body: some View {
        HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
            ForEach(runs) { run in
                switch run {
                case let .button(offset, action):
                    Button(action: action.perform) { Text(verbatim: action.title).lineLimit(1).fixedSize() }
                        .buttonStyle(PinnedButtonStyle(style: action.style, isFocused: focused == firstIndex + offset))
                        .disabled(!action.isEnabled)
                case let .segments(items):
                    HStack(spacing: LoomTheme.Pinned.segmentInset) {
                        ForEach(items, id: \.action.id) { item in
                            Button(action: item.action.perform) {
                                HStack(spacing: LoomTheme.Pinned.segmentGap) {
                                    if let symbol = item.action.symbol {
                                        Image(systemName: symbol).font(LoomTheme.Pinned.segmentIcon).accessibilityHidden(true)
                                    }
                                    Text(verbatim: item.action.title).lineLimit(1).fixedSize()
                                }
                            }
                            .buttonStyle(PinnedSegmentStyle(tone: item.action.tone ?? LoomTheme.Text.secondary, isOn: item.action.isOn,
                                                            isFocused: focused == firstIndex + item.offset))
                            .disabled(!item.action.isEnabled)
                            .accessibilityAddTraits(item.action.isOn ? .isSelected : [])
                        }
                    }
                    .padding(LoomTheme.Pinned.segmentInset)
                    .background(RoundedRectangle(cornerRadius: LoomTheme.Pinned.segmentGroupRadius).fill(LoomTheme.Surface.hover))
                }
            }
        }
    }
}

/// ⋯: the answers a card keeps behind it (Deny and Stop, Stop This Turn), and the Side composer's "…". An icon button of the
/// control family: 26 pt on a card.
struct PinnedMoreMenu<Items: View>: View {
    let busy: Bool
    var label = "More answers"
    var side = LoomTheme.Control.iconSize.width
    @ViewBuilder let items: Items
    @State private var hovering = false

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis").font(LoomTheme.Pinned.ellipsis)
                .foregroundStyle(hovering ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                .frame(width: side, height: side)
                .background(RowHighlight(state: hovering ? .hover : .none, radius: LoomTheme.Control.iconRadius))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .disabled(busy)
        .accessibilityLabel(label)
    }
}

/// The mono line at the left of a card's buttons: where the keys lead (E3). It is the first thing to go when the row is narrow.
struct PinnedHint: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(LoomTheme.Pinned.hint).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            .lineLimit(1).fixedSize()
    }
}

/// The keyboard of a card (CHAT-SPEC → Requests → Keys). The region takes the focus when the composer's Tab asks for it;
/// ← and → move the ring over its buttons, Space presses the one it is on, digits pick a question's options, and Tab gives
/// the keyboard back to the composer. Return and Esc are `PinnedKeys`' nothing: Return is swallowed here (it must not reach
/// anything that could read it as a default), Esc passes on untouched.
struct PinnedKeyRegion: ViewModifier {
    let cards: PinnedCardsModel
    let kind: ChatPendingRequest.Kind
    let actions: [PinnedAction]
    let pickOption: (Int) -> Void
    @Binding var focusedIndex: Int?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handle(press) }
            .onChange(of: cards.focusRequest) { focused = true }
            // Focus puts no ring on any button: a Space right after Tab presses nothing until ← or → chose one.
            .onChange(of: focused) { _, now in if !now { focusedIndex = nil } }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let key = Self.key(of: press)
        guard let action = PinnedKeys.action(for: key, kind: kind) else {
            // Return and Esc do nothing here (taken, never passed on); every other unmapped key goes on.
            return key == .returnKey || key == .escape ? .handled : .ignored
        }
        switch action {
        case let .moveFocus(delta):
            guard !actions.isEmpty else { return .handled }
            focusedIndex = Self.moved(from: focusedIndex, by: delta, count: actions.count)
        case .pressFocused:
            guard let index = focusedIndex, actions.indices.contains(index), actions[index].isEnabled else { return .handled }
            actions[index].perform()
        case let .pickOption(number):
            pickOption(number - 1)
        case .returnToComposer:
            cards.returnToComposer()
        }
        return .handled
    }

    /// The button the ring moves to. With none chosen yet, → goes to the first button and ← to the last.
    static func moved(from index: Int?, by delta: Int, count: Int) -> Int {
        guard let index else { return delta >= 0 ? 0 : count - 1 }
        return (index + delta + count) % count
    }

    static func key(of press: KeyPress) -> PinnedKey {
        // Shift-Tab arrives as the back-tab character, not as `.tab`: it goes back to the composer too.
        if press.characters == "\u{19}" { return .tab }
        switch press.key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .space: return .space
        case .return: return .returnKey
        case .escape: return .escape
        case .tab: return .tab
        default:
            if press.characters.count == 1, let digit = press.characters.first?.wholeNumberValue, press.characters.first?.isASCII == true {
                return .digit(digit)
            }
            return .other
        }
    }
}

extension View {
    func pinnedKeys(cards: PinnedCardsModel, kind: ChatPendingRequest.Kind, actions: [PinnedAction],
                    focusedIndex: Binding<Int?>, pickOption: @escaping (Int) -> Void = { _ in }) -> some View {
        modifier(PinnedKeyRegion(cards: cards, kind: kind, actions: actions, pickOption: pickOption, focusedIndex: focusedIndex))
    }
}

// MARK: Surface

extension View {
    /// A card's or a line's surface: the fill and a 1 pt edge inside it. A lifted card takes `Pinned.depth` (level 1 in Ink v4: no
    /// drop, no inner highlight).
    func pinnedSurface(radius: CGFloat, fill: Color, edge: AnyShapeStyle, lifted: Bool = false) -> some View {
        modifier(PinnedSurface(radius: radius, fill: fill, edge: edge, lifted: lifted))
    }
}

private struct PinnedSurface: ViewModifier {
    let radius: CGFloat
    let fill: Color
    let edge: AnyShapeStyle
    let lifted: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .background {
                if lifted { shape.fill(fill).depth(LoomTheme.Pinned.depth) } else { shape.fill(fill) }
            }
            .overlay(shape.strokeBorder(edge, lineWidth: LoomTheme.Line.hairline).allowsHitTesting(false))
    }
}

// MARK: Card

/// What leads a card's heading (E1): the attention dot for an approval, a 15 pt glyph for a question and a plan, and a quiet
/// triangle for the card a dead process cut off.
enum PinnedMark: Equatable {
    case dot
    case glyph(String)
    case cutOff
}

/// The frame of a card: its mark, the request in Sphyrna's words, the kind in mono and the counter, the body, and the failure of
/// the last answer. Raised 2 with radius 12 and the attention edge at 34 %; the card itself stays neutral.
struct PinnedCardChrome<Content: View>: View {
    let cards: PinnedCardsModel
    let mark: PinnedMark
    let title: String
    let kind: String?
    var showsCounter = true
    var failure: String?
    @ViewBuilder let content: Content

    private var isCutOff: Bool { mark == .cutOff }

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Pinned.sectionSpacing) {
            HStack(spacing: LoomTheme.Pinned.headerGap) {
                markView
                Text(verbatim: title).font(LoomTheme.Pinned.title).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                    .layoutPriority(1)
                if let kind {
                    Text(verbatim: kind).font(LoomTheme.Pinned.kind).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                }
                Spacer(minLength: LoomTheme.Pinned.headerGap)
                if showsCounter, let counter = cards.counter { PinnedStepper(cards: cards, counter: counter) }
            }
            content
            if let failure {
                Text(verbatim: failure).font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Status.failureLight)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pinned-failure")
            }
        }
        .padding(LoomTheme.Pinned.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pinnedSurface(radius: LoomTheme.Pinned.cardRadius, fill: LoomTheme.Pinned.cardFill,
                       edge: isCutOff ? AnyShapeStyle(LoomTheme.Surface.strongHairline)
                           : AnyShapeStyle(LoomTheme.Status.attention.opacity(LoomTheme.Pinned.edgeOpacity)),
                       lifted: true)
        .opacity(isCutOff ? LoomTheme.Pinned.cutOffOpacity : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder private var markView: some View {
        switch mark {
        case .dot:
            Circle().fill(LoomTheme.Status.attention).frame(width: LoomTheme.Pinned.headerDot, height: LoomTheme.Pinned.headerDot)
                .accessibilityHidden(true)
        case let .glyph(symbol):
            Image(systemName: symbol).font(LoomTheme.Pinned.headerGlyph).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .accessibilityHidden(true)
        case .cutOff:
            Image(systemName: "exclamationmark.triangle").font(LoomTheme.Pinned.headerGlyph)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle).accessibilityHidden(true)
        }
    }
}

/// "1 of 3" in mono, tertiary, with ‹ › beside it: the way to look at the other cards. It answers nothing.
struct PinnedStepper: View {
    let cards: PinnedCardsModel
    let counter: String

    var body: some View {
        HStack(spacing: LoomTheme.Pinned.stepGap) {
            Button { cards.step(-1) } label: { Image(systemName: "chevron.left").font(LoomTheme.Pinned.stepChevron) }
                .buttonStyle(ChromeButtonStyle(size: LoomTheme.Pinned.stepButton))
                .accessibilityLabel("Previous request")
            Text(verbatim: counter).font(LoomTheme.Pinned.counter).foregroundStyle(LoomTheme.Text.tertiaryStyle).monospacedDigit()
                .accessibilityIdentifier("pinned-counter")
            Button { cards.step(1) } label: { Image(systemName: "chevron.right").font(LoomTheme.Pinned.stepChevron) }
                .buttonStyle(ChromeButtonStyle(size: LoomTheme.Pinned.stepButton))
                .accessibilityLabel("Next request")
        }
    }
}

/// A command or a diff in mono: five lines (111 pt), then it scrolls inside the card. Raised 1 with a hairline, `$` before a
/// command in the tertiary tone.
struct PinnedCodeBlock: View {
    let lines: [PinnedApprovalContent.Line]
    let prompt: String?

    var body: some View {
        let visible = min(lines.count, LoomTheme.Pinned.codeLines)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Pinned.headerGap) {
                        if let prompt {
                            Text(verbatim: index == 0 ? prompt : " ").foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        }
                        Text(verbatim: line.text.isEmpty ? " " : line.text).foregroundStyle(color(line.tone))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(LoomTheme.Pinned.mono)
                    .frame(minHeight: LoomTheme.Pinned.codeLineHeight, alignment: .leading)
                    .background(background(line.tone))
                }
            }
            .padding(.vertical, LoomTheme.Pinned.codePaddingV).padding(.horizontal, LoomTheme.Pinned.codePaddingH)
            .textSelection(.enabled)
        }
        .frame(height: CGFloat(visible) * LoomTheme.Pinned.codeLineHeight + 2 * LoomTheme.Pinned.codePaddingV)
        .scrollBounceBehavior(.basedOnSize)
        .pinnedSurface(radius: LoomTheme.Pinned.codeRadius, fill: LoomTheme.Pinned.codeFill,
                       edge: AnyShapeStyle(LoomTheme.Surface.hairlineStyle))
        .accessibilityIdentifier("pinned-code")
    }

    private func color(_ tone: PinnedApprovalContent.Line.Tone) -> Color {
        switch tone {
        case .plain: LoomTheme.Text.primary
        case .added: LoomTheme.Chat.diffAdd
        case .removed: LoomTheme.Chat.diffRemove
        case .meta: LoomTheme.Text.secondary
        }
    }

    private func background(_ tone: PinnedApprovalContent.Line.Tone) -> Color {
        switch tone {
        case .added: LoomTheme.Chat.diffAddFill
        case .removed: LoomTheme.Chat.diffRemoveFill
        default: .clear
        }
    }
}

extension PinnedCardsModel {
    var focusedBinding: Binding<Int?> { Binding { self.focusedIndex } set: { self.focusedIndex = $0 } }
}
