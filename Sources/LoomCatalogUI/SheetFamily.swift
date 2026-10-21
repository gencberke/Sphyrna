import Observation
import SwiftUI

// The sheet family (DESIGN §6 Sheets, D-78, D-83): every question asked before something changes is one shape, with one keys rule and
// one presenter. Settings uses it now (Full Access, Delete); the main window's sheets move onto it with I6b.
//
// The family takes its keys through its own key handling (`onKeyPress`), never through a default or cancel action, an exit command or
// a submit action: over the chat those would meet the composer's keys (`PinnedFixRoundTests`), and `InkSettingsSheetTests.theSheetFamilyBindsNoDefaultCancelExitOrSubmitKey`
// pins it over this file.

// MARK: Rules

/// The widths of the family: 420 for a question, 480 for one that lists files, 560 for Remora's memory (DESIGN §20).
enum SheetWidth: CaseIterable, Sendable {
    case standard, files, memory
}

/// How wide a sheet is: 420, or 480 when it lists files, or 560 for the memory sheet.
enum SheetLayout {
    static func width(_ kind: SheetWidth) -> CGFloat {
        switch kind {
        case .standard: LoomTheme.Sheet.width
        case .files: LoomTheme.Sheet.wideWidth
        case .memory: LoomTheme.Sheet.memoryWidth
        }
    }

    static func width(listsFiles: Bool) -> CGFloat { width(listsFiles ? .files : .standard) }
}

/// The keys of a sheet. Esc cancels. Return does nothing, unless the sheet has a filled button (only a sheet that saves has one), and
/// then it presses that button. Tab and Shift-Tab move between the sheet's buttons and stay inside it. Other keys are not the sheet's.
enum SheetKeys {
    enum Reaction: Equatable {
        case cancel
        /// Return on a sheet with a filled button.
        case confirm
        /// The key is taken and nothing happens.
        case swallow
        case moveFocus(forward: Bool)
        case ignore
    }

    static func reaction(to key: KeyEquivalent, shift: Bool = false, hasFilledButton: Bool) -> Reaction {
        switch key {
        case .escape: .cancel
        case .return: hasFilledButton ? .confirm : .swallow
        case .tab: .moveFocus(forward: !shift)
        default: .ignore
        }
    }
}

/// The order the focus runs through a sheet's buttons: Cancel has it first, and Tab wraps around.
enum SheetFocusOrder {
    static let cancel = "cancel"

    /// The stop after `current` in `stops` (before it going back), wrapping; the first stop when nothing is focused.
    static func next(from current: String?, in stops: [String], forward: Bool) -> String? {
        guard !stops.isEmpty else { return nil }
        guard let current, let index = stops.firstIndex(of: current) else { return stops.first }
        let step = forward ? 1 : stops.count - 1
        return stops[(index + step) % stops.count]
    }
}

// MARK: Presenter

/// Which sheet a window shows: nil for none. The window's own keys (⌘W, ⌘N …) read `isOpen` to hold back while one is open.
///
/// A window that holds its questions in its own state (the main window's four) gives the presenter a `source`: the sheet is then read
/// from that state on every access, so the sheet and the question it asks cannot disagree, and `present`/`dismiss` are not used.
@MainActor @Observable
final class SheetPresenter<Sheet: Hashable> {
    private var own: Sheet?
    /// Where the sheet comes from when it is not this presenter's (a model's derived sheet); nil for a presenter that owns its own.
    @ObservationIgnored var source: (@MainActor () -> Sheet?)?

    init(source: (@MainActor () -> Sheet?)? = nil) { self.source = source }

    var presented: Sheet? { source?() ?? own }

    var isOpen: Bool { presented != nil }

    func present(_ sheet: Sheet) { own = sheet }

    func dismiss() { own = nil }
}

extension View {
    /// Lays the presenter's sheet over this view: the scrim takes every click, what is behind is out of reach and hidden from
    /// accessibility while it is open, and the sheet comes down `headerOffset` under the top of the window, centred.
    func sheetLayer<Sheet: Hashable, Body: View>(
        _ presenter: SheetPresenter<Sheet>, headerOffset: CGFloat = LoomTheme.Sheet.defaultHeaderOffset,
        @ViewBuilder sheet: @escaping (Sheet) -> Body
    ) -> some View {
        modifier(SheetLayer(presenter: presenter, headerOffset: headerOffset, sheet: sheet))
    }
}

private struct SheetLayer<Sheet: Hashable, Body: View>: ViewModifier {
    let presenter: SheetPresenter<Sheet>
    let headerOffset: CGFloat
    let sheet: (Sheet) -> Body
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let open = presenter.isOpen
        ZStack(alignment: .top) {
            // Out of reach for the pointer and for assistive technologies. Not `.disabled`: that would grey the controls behind the
            // scrim. The keyboard stays inside the sheet because the sheet holds the focus and takes Tab itself.
            content
                .allowsHitTesting(!open)
                .accessibilityHidden(open)
            if let current = presenter.presented {
                // The scrim answers every click, so nothing under it does.
                Rectangle().fill(LoomTheme.Surface.scrim)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("sheet-scrim")
                    .transition(.opacity)
                sheet(current)
                    .padding(.top, headerOffset)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: LoomTheme.Sheet.fade), value: open)
    }
}

// MARK: Buttons

/// One button of a sheet.
struct SheetAction: Identifiable {
    enum Tint {
        /// A secondary button.
        case plain
        /// The filled accent button: the sheet's default, so Return presses it. Only a sheet that saves has one.
        case filled
        /// The accent wash and text (Rewind Files).
        case accent
        /// The failure wash and text (Delete Permanently).
        case failure
        /// A mode's tone at 14 % with text in the tone (Use Full Access).
        case tone(LoomTheme.Adaptive)
    }

    let id: String
    let title: String
    var tint: Tint = .plain
    var isEnabled = true
    let perform: () -> Void

    var isFilled: Bool { if case .filled = tint { true } else { false } }
}

/// A tinted button of a sheet: the tone's wash, the tone's text, a step darker under the pointer; disabled it is the hover fill and
/// tertiary text at full opacity (`.btn.dtint:disabled`).
struct SheetTintButtonStyle: ButtonStyle {
    let fill: Color
    let hoverFill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, fill: fill, hoverFill: hoverFill, text: text)
    }

    private struct Styled: View {
        let configuration: ButtonStyle.Configuration
        let fill: Color
        let hoverFill: Color
        let text: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused

        var body: some View {
            let size = LoomTheme.Control.Size.regular
            let shape = RoundedRectangle(cornerRadius: size.radius)
            let active = enabled && (hovering || configuration.isPressed)
            configuration.label
                .font(size.font)
                .foregroundStyle(enabled ? text : LoomTheme.Text.tertiary)
                .padding(.horizontal, size.paddingH)
                .frame(height: size.height)
                .background(shape.fill(enabled ? (active ? hoverFill : fill) : LoomTheme.Surface.hover))
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: size.radius)
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

private struct SheetButton: View {
    let action: SheetAction
    var focus: FocusState<String?>.Binding

    var body: some View {
        let button = Button(action.title, action: action.perform)
            .disabled(!action.isEnabled)
            .focused(focus, equals: action.id)
            .accessibilityIdentifier("sheet-\(action.id)")
        switch action.tint {
        case .plain: button.buttonStyle(ControlButtonStyle(kind: .secondary))
        case .filled: button.buttonStyle(ControlButtonStyle(kind: .primary))
        case .accent:
            button.buttonStyle(SheetTintButtonStyle(
                fill: LoomTheme.Accent.base.opacity(LoomTheme.Sheet.tintFill),
                hoverFill: LoomTheme.Accent.base.opacity(LoomTheme.Sheet.tintHover), text: LoomTheme.Accent.high))
        case .failure:
            button.buttonStyle(SheetTintButtonStyle(
                fill: LoomTheme.Status.failureWash,
                hoverFill: LoomTheme.Status.failurePair.color.opacity(LoomTheme.Sheet.failureHover),
                text: LoomTheme.Status.failureLight))
        case let .tone(pair):
            button.buttonStyle(SheetTintButtonStyle(
                fill: pair.color.opacity(LoomTheme.Sheet.tintFill), hoverFill: pair.color.opacity(LoomTheme.Sheet.tintHover),
                text: pair.color))
        }
    }
}

// MARK: The sheet

/// A sheet: the question as the title, an optional subject under it, the facts, and the buttons at the trailing edge, Cancel first.
/// A way out sits at the leading edge. The focus starts on Cancel (on the sheet itself where a button cannot hold it); Esc cancels; Return does nothing unless a button is filled.
struct InkSheet<Content: View>: View {
    let title: String
    var subject: String?
    /// 480 wide instead of 420.
    var listsFiles = false
    /// A width of the family beyond those two (560 for the memory sheet); it wins over `listsFiles`.
    var width: SheetWidth?
    /// The way out is "Cancel" unless a sheet that only shows things calls it "Done": it closes as Esc does and is not filled.
    var cancelTitle = "Cancel"
    var cancelEnabled = true
    let cancel: () -> Void
    var leading: SheetAction?
    let actions: [SheetAction]
    @ViewBuilder let content: Content
    @FocusState private var focus: String?
    /// The sheet itself holds the focus when no button can: a button takes focus only with keyboard navigation on, and Esc has to
    /// cancel for everyone. Focus on a button inside is focus inside the sheet, so the same key handler hears both.
    @FocusState private var holdsSheet: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.Sheet.radius)
        let ring = LoomTheme.Elevation.popover[LoomTheme.Appearance(scheme)].ring
        VStack(alignment: .leading, spacing: 0) {
            Text(title).projectType(LoomTheme.Sheet.title).lineHeight(.exact(points: LoomTheme.Sheet.titleLine))
                .offset(y: LoomTheme.Sheet.titleDrop)
                .foregroundStyle(LoomTheme.Text.primary).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subject {
                Text(subject).projectType(LoomTheme.Sheet.subject).lineHeight(.exact(points: LoomTheme.Sheet.subjectLine))
                    .offset(y: LoomTheme.Sheet.subjectDrop)
                    .foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(LoomTheme.Sheet.subjectLines).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LoomTheme.Sheet.subjectTop)
            }
            content
            buttons.padding(.top, LoomTheme.Sheet.buttonsTop)
        }
        .padding(LoomTheme.Sheet.padding)
        .frame(width: width.map { SheetLayout.width($0) } ?? SheetLayout.width(listsFiles: listsFiles), alignment: .leading)
        .background(shape.fill(LoomTheme.Surface.popover))
        .overlay { if let ring { shape.strokeBorder(ring.color, lineWidth: LoomTheme.Line.hairline) } }
        .depth(LoomTheme.Elevation.popover)
        .focusable()
        .focused($holdsSheet)
        .focusEffectDisabled()
        .defaultFocus($focus, SheetFocusOrder.cancel)
        .onAppear {
            // The sheet first, so the keys always have a target; then Cancel, which takes the focus where a button can hold it.
            holdsSheet = true
            focus = SheetFocusOrder.cancel
        }
        .onKeyPress(phases: .down) { press in handle(press) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(title)
        .accessibilityIdentifier("sheet")
    }

    private var buttons: some View {
        HStack(spacing: LoomTheme.Sheet.buttonGap) {
            if let leading { SheetButton(action: leading, focus: $focus) }
            Spacer(minLength: 0)
            SheetButton(action: cancelButton, focus: $focus)
            ForEach(actions) { SheetButton(action: $0, focus: $focus) }
        }
    }

    private var cancelButton: SheetAction {
        SheetAction(id: SheetFocusOrder.cancel, title: cancelTitle, isEnabled: cancelEnabled, perform: cancel)
    }

    /// The buttons the focus can reach, in the order Tab runs through them.
    private var stops: [String] {
        var all: [SheetAction] = []
        if let leading { all.append(leading) }
        all.append(cancelButton)
        all += actions
        return all.filter(\.isEnabled).map(\.id)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let filled = actions.first(where: \.isFilled)
        switch SheetKeys.reaction(to: press.key, shift: press.modifiers.contains(.shift), hasFilledButton: filled != nil) {
        case .cancel:
            if cancelEnabled { cancel() }
            return .handled
        case .confirm:
            if let filled, filled.isEnabled { filled.perform() }
            return .handled
        case .swallow:
            return .handled
        case let .moveFocus(forward):
            focus = SheetFocusOrder.next(from: focus, in: stops, forward: forward)
            return .handled
        case .ignore:
            return .ignored
        }
    }
}

// MARK: Facts

/// A list under a label ("Removed", "Kept"): the items with a 4 pt dot, and optionally a line of mono under them.
struct SheetList: View {
    let label: String
    let items: [String]
    var meta: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).projectType(LoomTheme.InkType.label).textCase(.uppercase)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .frame(height: LoomTheme.Sheet.labelLine)
                .padding(.bottom, LoomTheme.Sheet.labelBottom)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: LoomTheme.Sheet.itemGap) {
                ForEach(items, id: \.self) { item in
                    Text(item).projectType(LoomTheme.Sheet.text).lineHeight(.exact(points: LoomTheme.Sheet.textLine))
                        .offset(y: LoomTheme.Sheet.textDrop)
                        .foregroundStyle(LoomTheme.Text.primary).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, LoomTheme.Sheet.itemInset)
                        .overlay(alignment: .topLeading) {
                            Circle().fill(LoomTheme.Text.tertiaryStyle)
                                .frame(width: LoomTheme.Sheet.dot, height: LoomTheme.Sheet.dot)
                                .padding(.leading, LoomTheme.Sheet.dotLeading)
                                .padding(.top, LoomTheme.Sheet.dotTop)
                                .accessibilityHidden(true)
                        }
                }
            }
            if let meta {
                Text(meta).projectType(LoomTheme.Sheet.meta).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .padding(.leading, LoomTheme.Sheet.itemInset).padding(.top, LoomTheme.Sheet.metaTop)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, LoomTheme.Sheet.listTop)
        .accessibilityElement(children: .contain)
    }
}

/// The facts of a sheet in prose: 12.5 on 1.5, 12 under the title or subject.
struct SheetText: View {
    let text: String

    var body: some View {
        Text(text).projectType(LoomTheme.Sheet.text).lineHeight(.exact(points: LoomTheme.Sheet.textLine))
            .offset(y: LoomTheme.Sheet.textDrop)
            .foregroundStyle(LoomTheme.Text.primary).fixedSize(horizontal: false, vertical: true)
            .padding(.top, LoomTheme.Sheet.textTop)
    }
}
