import SwiftUI

/// The `/` and `@` menu, anchored above the composer (design/v2-studio-preview.html `.menu`): one flat list, ↑ and ↓ wrap,
/// ↵ or Tab inserts, Esc closes.
struct ComposerMenuPanel: View {
    let model: ChatComposerModel
    let menu: ComposerMenuState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        switch menu.kind {
        case .commands: "Commands and skills"
        case .mention: "Files, folders and sessions"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LoomTheme.Space.bannerRowSpacing) {
                Text(title).font(LoomTheme.Typography.smallMedium).foregroundStyle(LoomTheme.OnPopover.placeholder)
                if menu.loading {
                    Text("Searching\u{2026}").font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.OnPopover.placeholder)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LoomTheme.Space.requestPadding).frame(height: LoomTheme.Composer.menuFooterHeight + 6)
            Divider().overlay(LoomTheme.Surface.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index)
                        }
                    }
                    .padding(LoomTheme.Composer.menuInset)
                }
                .frame(height: min(CGFloat(max(menu.items.count, 1)), CGFloat(LoomTheme.Composer.menuMaxRows))
                    * LoomTheme.Composer.menuRowHeight + LoomTheme.Composer.menuInset * 2)
                .onChange(of: menu.selection) { _, selection in
                    guard menu.items.indices.contains(selection) else { return }
                    proxy.scrollTo(menu.items[selection].id)
                }
            }
            Divider().overlay(LoomTheme.Surface.hairline)
            HStack(spacing: LoomTheme.Space.requestPadding) {
                Text("\u{2191}\u{2193} move")
                Text("\u{21B5} insert")
                Text("esc close")
                Spacer(minLength: 0)
            }
            .font(LoomTheme.Composer.menuHintFont).foregroundStyle(LoomTheme.OnPopover.placeholder)
            .padding(.horizontal, LoomTheme.Space.requestPadding).frame(height: LoomTheme.Composer.menuFooterHeight)
        }
        .background(RoundedRectangle(cornerRadius: LoomTheme.Composer.menuRadius).fill(LoomTheme.Surface.popover))
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Composer.menuRadius))
        .overlay(RoundedRectangle(cornerRadius: LoomTheme.Composer.menuRadius)
            .strokeBorder(LoomTheme.Surface.strongHairline, lineWidth: LoomTheme.Line.hairline))
        .depth(LoomTheme.Elevation.popover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("composer-menu")
    }

    private func row(_ item: ComposerMenuItem, index: Int) -> some View {
        let selected = index == menu.selection
        let dimmed = item.isTerminalOnly
        // The row draws the hover fill: its secondary text takes the lifted tone that holds 4.5:1 on it (`OnPopover`).
        let lit = selected || LookEvidence.forcesHover("menu:\(item.id)")
        let secondary = LoomTheme.OnPopover.secondary(lit: lit)
        return Button { model.choose(item) } label: {
            HStack(spacing: LoomTheme.Space.chipInset) {
                icon(for: item, lit: lit)
                switch item.kind {
                case .command, .skill, .terminalOnly:
                    Text(item.title).font(LoomTheme.Composer.menuCommandFont).lineLimit(1)
                        .frame(minWidth: LoomTheme.Composer.menuNameColumn, alignment: .leading)
                        .foregroundStyle(dimmed ? AnyShapeStyle(secondary) : AnyShapeStyle(LoomTheme.Text.primary))
                    if let detail = item.detail {
                        Text(detail).font(LoomTheme.Composer.menuDetailFont).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(secondary)
                    }
                default:
                    Text(item.title).font(LoomTheme.Composer.menuTitleFont).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(dimmed ? AnyShapeStyle(secondary) : AnyShapeStyle(LoomTheme.Text.primary))
                    if let detail = item.detail {
                        Text(detail).font(LoomTheme.Composer.menuDetailFont).lineLimit(1)
                            .foregroundStyle(secondary)
                    }
                }
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
                if let trailing = item.trailing {
                    Text(trailing).font(LoomTheme.Composer.menuHintFont).lineLimit(1)
                        .foregroundStyle(secondary)
                }
            }
            .padding(.horizontal, LoomTheme.Space.chipInset)
            .frame(height: LoomTheme.Composer.menuRowHeight)
            .background(RowHighlight(
                state: .resolve(selected: false, hovering: lit),
                radius: LoomTheme.Highlight.radiusCompact))
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

    @ViewBuilder private func icon(for item: ComposerMenuItem, lit: Bool) -> some View {
        let symbol: String? = switch item.kind {
        case .file: "doc"
        case .folder: "folder"
        case .session: "bubble.left"
        case .command, .skill, .terminalOnly: nil
        }
        if let symbol {
            Image(systemName: symbol).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.OnPopover.secondary(lit: lit))
                .frame(width: LoomTheme.Layout.indicatorSlot.width)
        }
    }
}
