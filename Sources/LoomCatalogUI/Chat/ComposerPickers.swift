import LoomCore
import Observation
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

/// The cursor of a pick list: the row under the pointer or the arrow keys. The chip that opens the list holds it, because the
/// host (not the list) reads the keys (`ComposerPickList.resolve`).
@MainActor @Observable
final class ComposerPickCursor {
    var highlighted: Int?
}

/// The rows of a popover, as in Codex's model list: a header, rows with a rounded highlight under the pointer or the arrow
/// keys, and a check mark on the chosen one. ↑ and ↓ move (and stop at the ends), ↵ and Space choose.
struct ComposerPickList: View {
    var header: String?
    var rows: [ComposerPickRow]
    var identifier: String
    var width: CGFloat = LoomTheme.Composer.pickWidth
    var cursor: ComposerPickCursor
    var onPick: (String) -> Void

    /// What a key does to the list: the new highlight, the row it picks, and whether the list used the key. Pure, so the rules are
    /// tested without a view.
    struct Step: Equatable {
        var highlighted: Int?
        var pick: String?
        var handled: Bool
    }

    static func resolve(_ key: InkKey, highlighted: Int?, rows: [ComposerPickRow]) -> Step {
        let unused = Step(highlighted: highlighted, pick: nil, handled: false)
        guard !rows.isEmpty else { return unused }
        switch key {
        case .down: return Step(highlighted: min((highlighted ?? -1) + 1, rows.count - 1), pick: nil, handled: true)
        case .up: return Step(highlighted: max((highlighted ?? rows.count) - 1, 0), pick: nil, handled: true)
        case .return, .space:
            guard let highlighted, rows.indices.contains(highlighted), rows[highlighted].isEnabled else { return unused }
            return Step(highlighted: highlighted, pick: rows[highlighted].id, handled: true)
        case .left, .right, .escape: return unused
        }
    }

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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func rowView(_ row: ComposerPickRow, index: Int) -> some View {
        // The row draws the hover fill: its secondary text takes the lifted tone that holds 4.5:1 on it (`OnPopover`).
        let lit = row.isEnabled && (cursor.highlighted == index || LookEvidence.forcesHover("pick:\(row.id)"))
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
            if inside { cursor.highlighted = index } else if cursor.highlighted == index { cursor.highlighted = nil }
        }
        .accessibilityLabel(row.subtitle.map { "\(row.title), \($0)" } ?? row.title)
        .accessibilityAddTraits(row.checked ? .isSelected : [])
        .accessibilityIdentifier("\(identifier)-\(row.id)")
    }
}

// MARK: Mode chip

/// The permission mode on the bar: its icon and name in the mode's tone, and the mode list in the window's host (above the chip on
/// the live composer, below it on the draft page, leading edges aligned). The draft passes a `reset` ("Use the default for this
/// project") when its pick differs from what the project would start in.
struct ComposerModeChip: View {
    /// The mode as Loom stores it; nil while nothing says which mode runs.
    var selected: String?
    var title: String
    var help: String
    var identifier: String
    var reset: (() -> Void)?
    /// Ask works in Chat only: false where the session will start in the terminal, and the row says so.
    var askAllowed = true
    /// The draft page's chip opens its list below it; the live composer's dock opens it above (`InkOpeners`).
    var onDraft = false
    /// Gives the keyboard back to the composer's text when the list closes.
    var restoreFocus: (() -> Void)?
    @Binding var isOpen: Bool
    var onPick: (ClaudePermissionMode) -> Void
    @State private var cursor = ComposerPickCursor()

    var body: some View {
        let tint = selected == nil ? LoomTheme.Composer.modeColor : ComposerModeLook.color(forRaw: selected)
        let rows = Self.rows(selected: selected, askAllowed: askAllowed)
        let spot = InkOpeners.placement(.mode, onDraft: onDraft) ?? InkOpeners.Spot(side: .above, alignment: .leading)
        Button { isOpen.toggle() } label: {
            ComposerChipLabel(symbol: ComposerModeLook.symbol(forRaw: selected), title: title)
        }
        .buttonStyle(ComposerChipStyle(tint: tint, key: identifier))
        .help(help)
        .accessibilityLabel("Permission mode, \(title)")
        .accessibilityIdentifier(identifier)
        .inkPopover(isPresented: $isOpen, id: identifier, label: "Mode", side: spot.side,
                    alignment: spot.alignment, keys: { key in
            let step = ComposerPickList.resolve(key, highlighted: cursor.highlighted, rows: rows)
            cursor.highlighted = step.highlighted
            if let pick = step.pick { choose(pick) }
            return step.handled
        }, restoreFocus: restoreFocus, content: {
            VStack(spacing: 0) {
                ComposerPickList(header: "Mode", rows: rows, identifier: "\(identifier)-list", cursor: cursor) { choose($0) }
                if let reset {
                    Divider().overlay(LoomTheme.Composer.pickDivider)
                    Button("Use the default for this project") {
                        isOpen = false
                        reset()
                    }
                    .buttonStyle(ControlButtonStyle(kind: .link, size: .small))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LoomTheme.Composer.pickInset + LoomTheme.Composer.pickRowInsetH)
                    .padding(.vertical, LoomTheme.Composer.pickRowPaddingV)
                    .accessibilityIdentifier("\(identifier)-reset")
                }
            }
        })
        .onChange(of: isOpen) { _, open in if !open { cursor.highlighted = nil } }
    }

    private func choose(_ id: String) {
        isOpen = false
        if let mode = ClaudePermissionMode(rawValue: id) { onPick(mode) }
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
