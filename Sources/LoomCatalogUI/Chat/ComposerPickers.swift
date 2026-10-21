import LoomCore
import SwiftUI

// The composer bar's mode picker (D-63, after Codex's). The model chip with its one popover is `ComposerModelPopover.swift`.
// The draft's composer and the session's own composer both draw them, with the same pieces and their own actions.

// MARK: Look of a mode

/// A permission mode's icon and colour: minimal outline glyphs and soft tones (`LoomTheme.Composer.ModeTone`).
enum ComposerModeLook {
    /// `raw` is the mode as Loom stores it. A word that is not one of ours gets the plain shield.
    static func symbol(forRaw raw: String?) -> String {
        switch raw.flatMap(ClaudePermissionMode.init(rawValue:)) {
        case .ask?: "bubble.left"
        case .askBeforeEdits?: "shield"
        case .acceptEdits?: "pencil.line"
        case .auto?: "bolt"
        case .fullAccess?: "exclamationmark.circle"
        case .plan?: "list.bullet.rectangle"
        case nil: "shield"
        }
    }

    static func color(forRaw raw: String?) -> Color { LoomTheme.Composer.ModeTone.color(forRaw: raw) }
}

// MARK: Pick list

/// One row of a pick list: an optional icon in its own tone, a title with an optional second line, and a check mark.
struct ComposerPickRow: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color?
    var checked: Bool
    /// A row that cannot be chosen here shows its reason as the second line (Ask on a terminal start: "Chat only").
    var isEnabled = true
}

/// The rows of a popover, as in Codex's model list: a header, rows with a rounded highlight under the pointer or the arrow
/// keys, and a check mark on the chosen one. ↑ and ↓ move, ↵ and Space choose.
struct ComposerPickList: View {
    var header: String?
    var rows: [ComposerPickRow]
    var identifier: String
    var width: CGFloat = LoomTheme.Composer.pickWidth
    var onPick: (String) -> Void
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header).font(LoomTheme.Composer.pickHeaderFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
                    .padding(.horizontal, LoomTheme.Composer.pickRowInsetH).frame(height: LoomTheme.Composer.pickHeaderHeight)
                    .accessibilityAddTraits(.isHeader)
            }
            ScrollView {
                VStack(spacing: LoomTheme.Composer.pickRowSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, index: index)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: LoomTheme.Composer.pickMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LoomTheme.Composer.pickInset)
        .frame(width: width)
        .background(LoomTheme.Surface.popover)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .space]) { press in handle(press.key) }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        switch key {
        case .downArrow: highlighted = min((highlighted ?? -1) + 1, rows.count - 1)
        case .upArrow: highlighted = max((highlighted ?? rows.count) - 1, 0)
        case .return, .space:
            guard let highlighted, rows.indices.contains(highlighted), rows[highlighted].isEnabled else { return .ignored }
            onPick(rows[highlighted].id)
        default: return .ignored
        }
        return .handled
    }

    private func rowView(_ row: ComposerPickRow, index: Int) -> some View {
        // The row draws the hover fill: its secondary text takes the lifted tone that holds 4.5:1 on it (`OnPopover`).
        let lit = row.isEnabled && (highlighted == index || LookEvidence.forcesHover("pick:\(row.id)"))
        return Button { if row.isEnabled { onPick(row.id) } } label: {
            HStack(alignment: row.subtitle == nil ? .center : .top, spacing: LoomTheme.Composer.modelColumnGap) {
                if let symbol = row.symbol {
                    Image(systemName: symbol).font(LoomTheme.Composer.pickIcon)
                        .foregroundStyle(row.isEnabled ? row.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(LoomTheme.OnPopover.secondary(lit: lit))
                                         : AnyShapeStyle(LoomTheme.OnPopover.placeholder))
                        .frame(width: LoomTheme.Composer.pickIconSide, height: LoomTheme.Composer.pickIconSide)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(LoomTheme.Composer.pickTitleFont)
                        .foregroundStyle(row.isEnabled ? row.tint ?? LoomTheme.Text.primary : LoomTheme.OnPopover.placeholder)
                    if let subtitle = row.subtitle {
                        Text(subtitle).font(LoomTheme.Composer.pickSubtitleFont).foregroundStyle(LoomTheme.OnPopover.secondary(lit: lit))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: LoomTheme.Space.requestPadding)
                if row.checked {
                    Image(systemName: "checkmark").font(LoomTheme.Composer.pickCheck).foregroundStyle(LoomTheme.Text.primary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, LoomTheme.Composer.pickRowInsetH)
            .padding(.top, LoomTheme.Composer.pickRowTop).padding(.bottom, LoomTheme.Composer.pickRowBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RowHighlight(
                state: .resolve(selected: false, hovering: lit, enabled: row.isEnabled),
                radius: LoomTheme.Composer.pickRowRadius))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Composer.pickRowRadius))
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .onHover { inside in
            if inside { highlighted = index } else if highlighted == index { highlighted = nil }
        }
        .accessibilityLabel(row.subtitle.map { "\(row.title), \($0)" } ?? row.title)
        .accessibilityAddTraits(row.checked ? .isSelected : [])
        .accessibilityIdentifier("\(identifier)-\(row.id)")
    }
}

// MARK: Mode chip

/// The permission mode on the bar: its icon and name in the mode's tone, and the mode list in a popover. The draft passes a
/// `reset` ("Use the default for this project") when its pick differs from what the project would start in.
struct ComposerModeChip: View {
    /// The mode as Loom stores it; nil while nothing says which mode runs.
    var selected: String?
    var title: String
    var help: String
    var identifier: String
    var reset: (() -> Void)?
    /// Ask works in Chat only: false where the session will start in the terminal, and the row says so.
    var askAllowed = true
    @Binding var isOpen: Bool
    var onPick: (ClaudePermissionMode) -> Void

    var body: some View {
        let tint = selected == nil ? LoomTheme.Composer.modeColor : ComposerModeLook.color(forRaw: selected)
        Button { isOpen.toggle() } label: {
            ComposerChipLabel(symbol: ComposerModeLook.symbol(forRaw: selected), title: title)
        }
        .buttonStyle(ComposerChipStyle(tint: tint, key: identifier))
        .help(help)
        .accessibilityLabel("Permission mode, \(title)")
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(spacing: 0) {
                ComposerPickList(header: "Mode", rows: Self.rows(selected: selected, askAllowed: askAllowed), identifier: "\(identifier)-list") { id in
                    isOpen = false
                    if let mode = ClaudePermissionMode(rawValue: id) { onPick(mode) }
                }
                if let reset {
                    Divider().overlay(LoomTheme.Composer.pickDivider)
                    Button("Use the default for this project") {
                        isOpen = false
                        reset()
                    }
                    .buttonStyle(.plain).font(LoomTheme.Composer.pickSubtitleFont).foregroundStyle(LoomTheme.OnPopover.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LoomTheme.Composer.pickInset + LoomTheme.Composer.pickRowInsetH)
                    .padding(.vertical, LoomTheme.Composer.pickRowPaddingV)
                    .accessibilityIdentifier("\(identifier)-reset")
                }
            }
            .background(LoomTheme.Surface.popover)
        }
    }

    /// The mode list: the five modes the menus offer, with the chosen one checked. A session in plan mode (not offered) has no check.
    static func rows(selected: String?, askAllowed: Bool = true) -> [ComposerPickRow] {
        ClaudePermissionMode.menuModes.map { mode in
            let blocked = mode == .ask && !askAllowed
            return ComposerPickRow(
                id: mode.rawValue, title: mode.title, subtitle: blocked ? "Chat only" : ComposerBarText.modeDetail(mode),
                symbol: ComposerModeLook.symbol(forRaw: mode.rawValue), tint: ComposerModeLook.color(forRaw: mode.rawValue),
                checked: selected == mode.rawValue, isEnabled: !blocked)
        }
    }
}
