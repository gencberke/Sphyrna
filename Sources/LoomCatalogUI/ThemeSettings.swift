import SwiftUI

/// Settings → Theme (D-63): the appearance, the tone, the sidebar and the project colours, in one card. Every choice applies at once and
/// is kept in `UIPreferences`. Animated art (§17, D-79) is I5's.
struct ThemeSettings: View {
    let model: CatalogModel

    var body: some View {
        SettingsPage {
            SettingsGroup {
                SettingsRow(title: "Appearance",
                            detail: "Ink is dark and Paper is light; Match system follows macOS. Terminal sessions stay dark in all three.") {
                    InkSegmented(values: AppearanceSetting.allCases, title: \.title, selection: model.appearance,
                                 onSelect: { model.setAppearance($0) })
                        .accessibilityLabel("Appearance")
                }
                SettingsRowDivider()
                ToneRow(selection: model.paneTone, onSelect: { model.setPaneTone($0) })
                SettingsRowDivider()
                SettingsRow(title: "Sidebar",
                            detail: "Glass lets the desktop show through softly. Solid is opaque. Reduce Transparency in System Settings always shows Solid.") {
                    InkSegmented(values: SidebarStyle.allCases, title: \.title, selection: model.sidebarStyle,
                                 onSelect: { model.setSidebarStyle($0) })
                        .accessibilityLabel("Sidebar")
                }
                SettingsRowDivider()
                SettingsRow(title: "Project colors",
                            detail: "Give each project a color: its mark, its tabs and its selected session. Off keeps them grey and remembers the colors.") {
                    SettingsSwitch(title: "Project colors", isOn: Binding(
                        get: { model.projectColorsEnabled }, set: { model.setProjectColors($0) }))
                }
            }
        }
    }
}

/// The three tones, each as a small picture of the pane in its own cast, under the row's text.
struct ToneRow: View {
    let selection: PaneTone
    let onSelect: (PaneTone) -> Void

    private typealias S = LoomTheme.Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRowText(
                title: "Tone",
                detail: "A cast over the window's greys, the sidebar and Settings included. Status, accent and project colors stay as they are.")
            HStack(spacing: S.tileGap) {
                ForEach(PaneTone.allCases, id: \.self) { tone in
                    ToneTile(tone: tone, selected: tone == selection) { onSelect(tone) }
                }
            }
            .padding(.top, S.stackTop)
        }
        .padding(.vertical, S.rowPaddingV).padding(.horizontal, S.rowPaddingH)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tone")
    }
}

/// One tone: the pane in miniature, painted with that tone's own three greys (not the tone that is on now), its name and its detail.
struct ToneTile: View {
    let tone: PaneTone
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isFocused) private var focused

    private typealias S = LoomTheme.Settings

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: S.tileRadius)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ToneMiniature(tone: tone)
                Text(tone.title).projectType(S.tileName).foregroundStyle(LoomTheme.Text.primary)
                    .padding(.top, S.tileNameTop).padding(.horizontal, S.tileTextInset)
                Text(tone.detail).projectType(S.tileDetail).lineHeight(.exact(points: S.tileDetailLine))
                    .offset(y: S.tileDetailDrop)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, S.tileDetailTop).padding(.horizontal, S.tileTextInset).padding(.bottom, S.tileBottom)
            }
            .padding(S.tilePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(selected ? LoomTheme.Surface.selected : (hovering ? LoomTheme.Surface.hover : Color.clear)))
            .overlay {
                if selected {
                    shape.strokeBorder(LoomTheme.Accent.base, lineWidth: S.tileSelectedEdge)
                } else {
                    shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline)
                }
            }
            .controlFocusRing(
                visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                radius: S.tileRadius)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tone.title)
        .accessibilityHint(tone.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The reference's `.mini`: the canvas with the sidebar strip, two lines of text, a card, the composer and an accent capsule.
private struct ToneMiniature: View {
    let tone: PaneTone

    private typealias S = LoomTheme.Settings

    var body: some View {
        let greys = LoomTheme.Surface.colors(for: tone)
        let edge = S.miniEdge
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let edgeColor = edge.color
            ZStack(alignment: .topLeading) {
                greys.canvas
                Rectangle().fill(edgeColor).frame(width: LoomTheme.Line.hairline)
                    .frame(maxHeight: .infinity).offset(x: w * S.miniSidebar - LoomTheme.Line.hairline)
                line(S.miniLine1, w: w)
                line(S.miniLine2, w: w)
                let card = S.miniCard
                RoundedRectangle(cornerRadius: card.radius).fill(greys.raised1)
                    .overlay(RoundedRectangle(cornerRadius: card.radius).strokeBorder(edgeColor, lineWidth: LoomTheme.Line.hairline))
                    .frame(width: w * (1 - card.left - card.right), height: card.height)
                    .offset(x: w * card.left, y: card.top)
                let composer = S.miniComposer
                RoundedRectangle(cornerRadius: composer.radius).fill(greys.raised2)
                    .overlay(RoundedRectangle(cornerRadius: composer.radius).strokeBorder(edgeColor, lineWidth: LoomTheme.Line.hairline))
                    .frame(width: w * (1 - composer.left - composer.right), height: composer.height)
                    .offset(x: w * composer.left, y: h - composer.bottom - composer.height)
                let accent = S.miniAccent
                RoundedRectangle(cornerRadius: S.miniLineRadius).fill(LoomTheme.Accent.base)
                    .frame(width: accent.width, height: accent.height)
                    .offset(x: w * accent.right - accent.back, y: h - accent.bottom - accent.height)
            }
            .frame(width: w, height: h, alignment: .topLeading)
        }
        .frame(height: S.miniHeight)
        .clipShape(RoundedRectangle(cornerRadius: S.miniRadius))
        .overlay(RoundedRectangle(cornerRadius: S.miniRadius).strokeBorder(edge.color, lineWidth: LoomTheme.Line.hairline))
        .accessibilityHidden(true)
    }

    private func line(_ spec: (top: CGFloat, width: Double, opacity: Double), w: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: S.miniLineRadius).fill(LoomTheme.Text.primary.opacity(spec.opacity))
            .frame(width: w * spec.width, height: S.miniLineHeight)
            .offset(x: w * S.miniLineLeading, y: spec.top)
    }
}
