import SwiftUI

/// Settings → Theme (D-63): the appearance, the tone of the main pane, the sidebar and the project colours. Every
/// choice applies at once and is kept in `UIPreferences`.
struct ThemeSettings: View {
    let model: CatalogModel

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.settingsSectionGap) {
            SettingsCard {
                SettingsRow(title: "Appearance",
                            detail: "Dark, Light, or the one macOS uses. Terminal sessions stay dark in all three.") {
                    SegmentedControl(values: AppearanceSetting.allCases, title: \.title, selection: model.appearance,
                                     compact: true, onSelect: { model.setAppearance($0) })
                        .accessibilityLabel("Appearance")
                }
                SettingsRowDivider()
                ToneRow(selection: model.paneTone, onSelect: { model.setPaneTone($0) })
                SettingsRowDivider()
                SettingsRow(title: "Sidebar",
                            detail: "Glass lets the desktop show through softly. Solid is opaque. Reduce Transparency in System Settings always shows Solid.") {
                    SegmentedControl(values: SidebarStyle.allCases, title: \.title, selection: model.sidebarStyle,
                                     compact: true, onSelect: { model.setSidebarStyle($0) })
                        .accessibilityLabel("Sidebar")
                }
                SettingsRowDivider()
                SettingsRow(title: "Project colors",
                            detail: "Give each project a color in the sidebar, the tab strip and the session header. Off shows Loom as before.") {
                    Toggle("Project colors", isOn: Binding(
                        get: { model.projectColorsEnabled }, set: { model.setProjectColors($0) }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel("Project colors")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LoomTheme.Space.settingsInset)
        .padding(.top, LoomTheme.Space.settingsSegmentH)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The main pane's three tones, each as a small picture of the pane in the look that is on now (the dark panel in
/// Dark, its light counterpart in Light).
struct ToneRow: View {
    let selection: PaneTone
    let onSelect: (PaneTone) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.Space.toneRowGap) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Main pane").font(LoomTheme.Typography.smallMedium)
                Text("The tone of the area where a session's terminal or Chat view is drawn.")
                    .font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
            }
            HStack(spacing: LoomTheme.Space.toneRowGap) {
                ForEach(PaneTone.allCases, id: \.self) { tone in
                    ToneTile(tone: tone, selected: tone == selection) { onSelect(tone) }
                }
            }
        }
        .padding(.vertical, LoomTheme.Space.settingsRowV)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main pane")
    }
}

struct ToneTile: View {
    let tone: PaneTone
    let selected: Bool
    let action: () -> Void
    @Environment(\.isFocused) private var focused

    var body: some View {
        let colors = LoomTheme.Surface.colors(for: tone)
        Button(action: action) {
            VStack(alignment: .leading, spacing: LoomTheme.ThemeTile.captionGap) {
                // The pane in miniature: a line of text, a card with a button.
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: LoomTheme.Radius.md).fill(colors.panel)
                    VStack(alignment: .leading, spacing: LoomTheme.ThemeTile.previewGap) {
                        Capsule().fill(LoomTheme.Text.secondary)
                            .frame(width: LoomTheme.ThemeTile.previewLine, height: LoomTheme.ThemeTile.previewLineHeight)
                        RoundedRectangle(cornerRadius: LoomTheme.Radius.sm).fill(colors.card)
                            .overlay(alignment: .leading) {
                                Capsule().fill(LoomTheme.Accent.base)
                                    .frame(width: LoomTheme.ThemeTile.previewButton, height: LoomTheme.ThemeTile.previewLineHeight)
                                    .padding(.leading, LoomTheme.ThemeTile.previewGap)
                            }
                            .frame(height: LoomTheme.ThemeTile.previewCard)
                    }
                    .padding(LoomTheme.ThemeTile.previewPadding)
                }
                .frame(height: LoomTheme.ThemeTile.previewHeight)
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.md)
                    .strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
                Text(tone.title).font(LoomTheme.Typography.smallMedium).foregroundStyle(LoomTheme.Text.primary)
                Text(tone.detail).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(LoomTheme.ThemeTile.tilePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.lg).fill(selected ? LoomTheme.Surface.selected : .clear))
            .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.lg)
                .strokeBorder(selected ? AnyShapeStyle(LoomTheme.Accent.base) : AnyShapeStyle(Color.clear),
                              lineWidth: LoomTheme.Line.focusRing))
            .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.lg))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tone.title)
        .accessibilityHint(tone.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
