import LoomChat
import SwiftUI

// The pieces every pinned card is built from (V18): the frame with its title and counter, the buttons, the note field, the
// code block, the keyboard region.

/// One button of a card. Nothing here is a default action: no button answers to Return, and Esc answers to none.
struct PinnedAction: Identifiable {
    enum Style { case neutral, accent }

    let id: String
    let title: String
    var style: Style = .neutral
    /// A mode segment that is the current choice.
    var isOn = false
    var isEnabled = true
    let perform: () -> Void
}

struct PinnedButtonStyle: ButtonStyle {
    let style: PinnedAction.Style
    let isOn: Bool
    let isFocused: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(LoomTheme.Pinned.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, LoomTheme.Pinned.buttonPaddingH)
            .frame(height: LoomTheme.Pinned.buttonHeight)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Pinned.buttonRadius).fill(fill(pressed: pressed)))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Pinned.buttonRadius)
                .strokeBorder(isFocused ? AnyShapeStyle(LoomTheme.Surface.focusRing) : AnyShapeStyle(LoomTheme.Surface.hairlineStyle),
                              lineWidth: isFocused ? LoomTheme.Line.focusRing : LoomTheme.Line.hairline))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Pinned.buttonRadius))
            .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
    }

    private var foreground: Color {
        style == .accent && !isOn ? LoomTheme.Accent.onAccent : LoomTheme.Text.primary
    }

    private func fill(pressed: Bool) -> Color {
        if style == .accent { return LoomTheme.Accent.base.opacity(pressed ? LoomTheme.Opacity.accentPressed : 1) }
        if isOn { return LoomTheme.Accent.base.opacity(LoomTheme.Opacity.accentTintPressed) }
        return pressed ? LoomTheme.Surface.controlPressed : LoomTheme.Surface.control
    }
}

/// A row of buttons; the one at `focused` wears the focus ring.
struct PinnedButtonRow: View {
    let actions: [PinnedAction]
    let focused: Int?
    /// The position of the first button among all of the card's buttons, when a card shows them in more than one row.
    var firstIndex = 0

    var body: some View {
        HStack(spacing: LoomTheme.Pinned.buttonSpacing) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                Button(action: action.perform) { Text(verbatim: action.title).lineLimit(1).fixedSize() }
                    .buttonStyle(PinnedButtonStyle(style: action.style, isOn: action.isOn, isFocused: focused == firstIndex + index))
                    .disabled(!action.isEnabled)
                    .accessibilityAddTraits(action.isOn ? .isSelected : [])
            }
        }
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

/// The frame of a card: its icon, title and who it concerns, the counter, the body, and the failure of the last answer.
struct PinnedCardChrome<Content: View>: View {
    let cards: PinnedCardsModel
    let symbol: String
    let title: String
    let who: String?
    var tint: Color = LoomTheme.Status.attention
    var strokeOpacity = LoomTheme.Pinned.strokeOpacity
    var showsCounter = true
    var failure: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Pinned.sectionSpacing) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(LoomTheme.Pinned.icon).foregroundStyle(tint)
                    .frame(width: LoomTheme.Pinned.iconSlot, height: LoomTheme.Pinned.iconSlot)
                    .background(RoundedRectangle(cornerRadius: LoomTheme.Pinned.iconRadius).fill(tint.opacity(LoomTheme.Pinned.iconFillOpacity)))
                    .accessibilityHidden(true)
                Text(verbatim: title).font(LoomTheme.Pinned.title).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                Spacer(minLength: 8)
                if let who {
                    Text(verbatim: who).font(LoomTheme.Pinned.who).foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
                }
                if showsCounter, let counter = cards.counter { PinnedStepper(cards: cards, counter: counter) }
            }
            content
            if let failure {
                Text(verbatim: failure).font(LoomTheme.Pinned.detail).foregroundStyle(LoomTheme.Status.failure)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pinned-failure")
            }
        }
        .padding(LoomTheme.Pinned.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Pinned.cardRadius).fill(LoomTheme.Pinned.cardFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Pinned.cardRadius).strokeBorder(tint.opacity(strokeOpacity)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// "‹ 1 of 3 ›": the counter, and the way to look at the other cards. It answers nothing.
struct PinnedStepper: View {
    let cards: PinnedCardsModel
    let counter: String

    var body: some View {
        HStack(spacing: 4) {
            Button { cards.step(-1) } label: { Image(systemName: "chevron.left").font(LoomTheme.Pinned.stepperChevron) }
                .accessibilityLabel("Previous request")
            Text(verbatim: counter).font(LoomTheme.Pinned.stepper).monospacedDigit()
                .accessibilityIdentifier("pinned-counter")
            Button { cards.step(1) } label: { Image(systemName: "chevron.right").font(LoomTheme.Pinned.stepperChevron) }
                .accessibilityLabel("Next request")
        }
        .buttonStyle(.plain)
        .foregroundStyle(LoomTheme.Text.secondaryStyle)
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(width: 1, height: 14) }
    }
}

/// A command or a diff in mono: five lines, then it scrolls inside the card.
struct PinnedCodeBlock: View {
    let lines: [PinnedApprovalContent.Line]
    let prompt: String?

    var body: some View {
        let visible = min(lines.count, LoomTheme.Pinned.codeLines)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let prompt {
                            Text(verbatim: index == 0 ? prompt : " ").foregroundStyle(LoomTheme.Text.faint)
                        }
                        Text(verbatim: line.text.isEmpty ? " " : line.text).foregroundStyle(color(line.tone))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(LoomTheme.Pinned.mono)
                    .frame(minHeight: LoomTheme.Pinned.codeLineHeight, alignment: .leading)
                    .background(background(line.tone))
                }
            }
            .padding(LoomTheme.Pinned.codePadding)
            .textSelection(.enabled)
        }
        .frame(height: CGFloat(visible) * LoomTheme.Pinned.codeLineHeight + 2 * LoomTheme.Pinned.codePadding)
        .scrollBounceBehavior(.basedOnSize)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Pinned.codeRadius).fill(LoomTheme.Pinned.codeFill))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Pinned.codeRadius).strokeBorder(LoomTheme.Surface.hairlineStyle))
        .accessibilityIdentifier("pinned-code")
    }

    private func color(_ tone: PinnedApprovalContent.Line.Tone) -> Color {
        switch tone {
        case .plain: LoomTheme.Chat.syntaxPlain
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
