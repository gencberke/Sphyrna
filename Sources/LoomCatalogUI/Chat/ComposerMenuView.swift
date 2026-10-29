import SwiftUI

/// The `/` and `@` menu, opening above the composer (DESIGN §11, the reference's `slashA` and `atA`): one flat popover list
/// with no divider or footer, a quiet head ("Commands and skills", or "Files" and "Sessions" between the two kinds of `@`
/// rows), and each row with its kind's icon. ↑ and ↓ wrap, ↵ or Tab inserts, Esc closes.
struct ComposerMenuPanel: View {
    let model: ChatComposerModel
    let menu: ComposerMenuState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The menu enters with opacity and a 3 pt rise over 160 ms, and at once under Reduce Motion (DESIGN §6 Motion).
    @State private var entered = false

    /// What the menu is called for VoiceOver.
    private var title: String {
        switch menu.kind {
        case .commands: "Commands and skills"
        case .mention: "Files, folders and sessions"
        }
    }

    /// The head over the first row of a kind: "Commands and skills" for `/`; "Files" and "Sessions" for `@`.
    static func head(for index: Int, in items: [ComposerMenuItem], kind: ComposerMenuState.Kind) -> String? {
        guard items.indices.contains(index) else { return nil }
        switch kind {
        case .commands: return index == 0 ? "Commands and skills" : nil
        case .mention:
            let isSession: (ComposerMenuItem) -> Bool = { $0.kind == .session }
            if index == 0 { return isSession(items[0]) ? "Sessions" : "Files" }
            return isSession(items[index]) && !isSession(items[index - 1]) ? "Sessions" : nil
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                        if let head = Self.head(for: index, in: menu.items, kind: menu.kind) { headView(head, first: index == 0) }
                        row(item, index: index)
                    }
                }
                .padding(LoomTheme.Composer.menuInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: CGFloat(LoomTheme.Composer.menuMaxRows) * LoomTheme.Composer.menuRowHeight
                + LoomTheme.Composer.menuInset * 2 + LoomTheme.Composer.menuHeadHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: menu.selection) { _, selection in
                guard menu.items.indices.contains(selection) else { return }
                proxy.scrollTo(menu.items[selection].id)
            }
        }
        .frame(width: LoomTheme.Composer.menuWidth)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Composer.menuRadius).fill(LoomTheme.Surface.popover))
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Composer.menuRadius))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Composer.menuRadius)
            .strokeBorder(LoomTheme.Surface.hairline, lineWidth: LoomTheme.Line.hairline))
        .depth(LoomTheme.Elevation.popover)
        .opacity(entered ? 1 : 0)
        .offset(y: entered ? 0 : LoomTheme.Host.rise)
        .onAppear { withAnimation(LoomTheme.Host.entrance(reduceMotion: reduceMotion)) { entered = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("composer-menu")
    }

    private func headView(_ text: String, first: Bool) -> some View {
        HStack(spacing: LoomTheme.Space.bannerRowSpacing) {
            Text(text).font(LoomTheme.Composer.menuHeadFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
            if first, menu.loading {
                Text("Searching\u{2026}").font(LoomTheme.Composer.menuHintFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Composer.modelRowPaddingH).frame(height: LoomTheme.Composer.menuHeadHeight)
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: ComposerMenuItem, index: Int) -> some View {
        let selected = index == menu.selection
        let dimmed = item.isTerminalOnly
        // The row draws the hover fill: its secondary text takes the lifted tone that holds 4.5:1 on it (`OnPopover`).
        let lit = selected || LookEvidence.forcesHover("menu:\(item.id)")
        let secondary = LoomTheme.OnPopover.secondary(lit: lit)
        return Button { model.choose(item) } label: {
            HStack(spacing: LoomTheme.Composer.modelColumnGap) {
                icon(for: item, lit: lit, dimmed: dimmed)
                switch item.kind {
                case .command, .skill, .terminalOnly:
                    Text(item.title).font(LoomTheme.Composer.menuCommandFont).lineLimit(1)
                        .foregroundStyle(dimmed ? AnyShapeStyle(secondary) : AnyShapeStyle(LoomTheme.Text.primary))
                    if let detail = item.detail {
                        Text("\u{00B7} \(detail)").font(LoomTheme.Composer.menuDetailFont).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(secondary)
                    }
                case .file, .folder:
                    Text(item.title).font(LoomTheme.Composer.menuCommandFont).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(dimmed ? AnyShapeStyle(secondary) : AnyShapeStyle(LoomTheme.Text.primary))
                    if let detail = item.detail {
                        Text(detail).font(LoomTheme.Composer.menuDetailFont).lineLimit(1).foregroundStyle(secondary)
                    }
                case .session:
                    Text(item.title).font(LoomTheme.Composer.menuTitleFont).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(LoomTheme.Text.primary)
                    if let detail = item.detail {
                        Text(detail).font(LoomTheme.Composer.menuDetailFont).lineLimit(1).foregroundStyle(secondary)
                    }
                }
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                if let trailing = item.trailing {
                    Text(trailing).font(LoomTheme.Composer.menuHintFont).lineLimit(1).foregroundStyle(secondary)
                }
            }
            .padding(.horizontal, LoomTheme.Composer.modelRowPaddingH)
            .frame(height: LoomTheme.Composer.menuRowHeight)
            .background(RowHighlight(
                state: .resolve(selected: false, hovering: lit),
                radius: LoomTheme.Composer.modelRowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            if case .active = phase, menu.selection != index { model.selectMenuItem(at: index) }
        }
        .id(item.id)
        .accessibilityLabel(item.title + (item.detail.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The row's icon: `/` for a command, sparkles for a skill, a page, a folder, a bubble for a session.
    private func icon(for item: ComposerMenuItem, lit: Bool, dimmed: Bool) -> some View {
        InkIcon(systemName: Self.symbol(for: item.kind), size: LoomTheme.Icon.body)
            .foregroundStyle(dimmed ? AnyShapeStyle(LoomTheme.Text.faint) : AnyShapeStyle(LoomTheme.OnPopover.secondary(lit: lit)))
            .frame(width: LoomTheme.Composer.menuIconSlot)
            .accessibilityHidden(true)
    }

    static func symbol(for kind: ComposerMenuItem.Kind) -> String {
        switch kind {
        case .command, .terminalOnly: "slash.circle"
        case .skill: "sparkles"
        case .file: "doc"
        case .folder: "folder"
        case .session: "bubble.left"
        }
    }
}
