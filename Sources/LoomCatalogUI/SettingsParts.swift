import SwiftUI

// The building blocks of a Settings section (DESIGN §2 item 5; the reference's `.sbody`, `.slab`, `.scard`, `.srw`): a scrolling page
// with a 32 inset, groups of cards under capital labels, and rows with a label, one line of help and a control at the trailing edge.

private typealias S = LoomTheme.Settings

extension EnvironmentValues {
    /// Set under a switch that turned a part of a page off (Remora's): the parts draw their text at 38 % as the controls draw
    /// themselves when disabled.
    @Entry var settingsDimmed = false
}

extension View {
    /// Turns this part of a page off: it answers nothing, the keyboard skips it, and its text and controls are drawn at 38 %.
    func settingsDimmed(_ dimmed: Bool) -> some View {
        disabled(dimmed).environment(\.settingsDimmed, dimmed)
    }
}

/// A section's page: its content scrolls under the title band, 32 in from the sides, 22 below the band and 26 above the window's edge.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, S.bodyInset).padding(.top, S.bodyTop).padding(.bottom, S.bodyBottom)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A section label: capitals in the label type, tertiary.
struct SettingsLabel: View {
    let text: String
    @Environment(\.settingsDimmed) private var dimmed

    var body: some View {
        Text(text).projectType(LoomTheme.InkType.label).textCase(.uppercase)
            .foregroundStyle(LoomTheme.Text.tertiaryStyle)
            // The reference's line box (line-height 1): the glyphs overflow it evenly, and the card sits 8 below it.
            .frame(height: S.labelLine)
            .opacity(dimmed ? LoomTheme.RemoraTab.dimmed : 1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A group: an optional label over a card, with a link-style button at the end of the label's line where one is given.
struct SettingsGroup<Content: View, Trailing: View>: View {
    var label: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                HStack(alignment: .firstTextBaseline, spacing: S.labelGap) {
                    SettingsLabel(text: label)
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.leading, S.labelLeading).padding(.bottom, S.labelBottom)
            }
            SettingsCard { content }
        }
    }
}

extension SettingsGroup where Trailing == EmptyView {
    init(label: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(label: label, trailing: { EmptyView() }, content: content)
    }
}

/// A card: raised 1, radius 12, a hairline edge and the card's depth. Its rows sit inside the rows' inset, and the hairlines between them
/// run within it.
struct SettingsCard<Content: View>: View {
    /// A card of rows takes the rows' inset (`S.rowsInset*`); a card that lays out its own content (Usage's) does not.
    var holdsRows = true
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: S.cardRadius)
        VStack(spacing: 0) { content }
            .padding(.top, holdsRows ? S.rowsInsetTop : 0).padding(.bottom, holdsRows ? S.rowsInsetBottom : 0)
            .padding(.leading, holdsRows ? S.rowsInsetLeading : 0).padding(.trailing, holdsRows ? S.rowsInsetTrailing : 0)
            .frame(maxWidth: .infinity)
            .background(shape.fill(LoomTheme.Surface.raised1))
            .overlay(shape.strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
            .depth(LoomTheme.Elevation.card)
    }
}

/// A row's text: the label in 13, one line of help in 12 secondary (at most 380 wide), and, where macOS says something is wrong, a line in
/// the attention text.
struct SettingsRowText: View {
    let title: String
    var detail: String?
    /// One attention line under the help.
    var notice: String?
    /// A fact in the mono face instead of a line of help (Remora's counts and path): one line, cut in the middle if it is long, and
    /// selectable, at most `detailWidth` wide.
    var detailStyle: LoomTheme.InkStyle?
    var detailWidth = S.helpMaxWidth
    @Environment(\.settingsDimmed) private var dimmed

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).projectType(S.rowTitle).foregroundStyle(LoomTheme.Text.primary)
                .frame(minHeight: S.rowTitleLine, alignment: .leading)
            // Each line of help is exactly 17 (the reference's line box), whatever the face's own metrics give, with its glyphs
            // where the reference centres them (`glyphDrop`).
            if let detail, let detailStyle {
                Text(detail).projectType(detailStyle).lineHeight(.exact(points: S.rowHelpLine))
                    .offset(y: S.glyphDrop(size: detailStyle.size, mono: detailStyle.mono, lineHeight: S.rowHelpLine))
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: detailWidth, alignment: .leading)
                    .padding(.top, S.helpTop)
            } else if let detail {
                Text(detail).projectType(S.rowHelp).lineHeight(.exact(points: S.rowHelpLine))
                    .offset(y: S.glyphDrop(size: S.rowHelp.size, lineHeight: S.rowHelpLine))
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .frame(maxWidth: S.helpMaxWidth, alignment: .leading)
                    .padding(.top, S.helpTop)
            }
            if let notice {
                Text(notice).projectType(S.rowHelp).lineHeight(.exact(points: S.rowHelpLine))
                    .offset(y: S.glyphDrop(size: S.rowHelp.size, lineHeight: S.rowHelpLine))
                    .foregroundStyle(LoomTheme.Status.attentionLight)
                    .padding(.top, S.noticeTop)
            }
        }
        // The text takes the lines it needs: beside a control the row was sized from the control, and the help was cut to one line.
        .fixedSize(horizontal: false, vertical: true)
        .opacity(dimmed ? LoomTheme.RemoraTab.dimmed : 1)
    }
}

/// A row: its text, and its control at the trailing edge. At least 48 high.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    var notice: String?
    var detailStyle: LoomTheme.InkStyle?
    var detailWidth = S.helpMaxWidth
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: S.rowGap) {
            SettingsRowText(title: title, detail: detail, notice: notice, detailStyle: detailStyle, detailWidth: detailWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: S.controlGap) { trailing }.fixedSize()
        }
        .padding(.vertical, S.rowPaddingV).padding(.horizontal, S.rowPaddingH)
        .frame(minHeight: S.rowMinHeight)
    }
}

/// The hairline between two rows.
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline).accessibilityHidden(true)
    }
}

/// A switch whose label is only for assistive technologies.
struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden().toggleStyle(InkSwitchStyle())
            .accessibilityLabel(title)
    }
}

/// A page state in the middle of a section (Usage, Sessions): the title, a line of text, an optional path and button.
struct SettingsNote: View {
    let title: String
    let text: String
    var path: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Text(title).projectType(LoomTheme.InkType.title).foregroundStyle(LoomTheme.Text.primary)
            Text(text).projectType(S.noteText).lineHeight(.exact(points: S.noteLine))
                .offset(y: S.noteDrop)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).multilineTextAlignment(.center)
                .frame(maxWidth: S.noteMaxWidth).fixedSize(horizontal: false, vertical: true)
                .padding(.top, S.noteTextTop)
            if let path {
                Text(path).projectType(S.notePath).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .padding(.top, S.notePathTop)
            }
            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                    .padding(.top, S.noteButtonTop)
            }
        }
        .padding(.horizontal, S.bodyInset).padding(.top, S.noteTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

/// A section's footer: 32 high under a hairline, a mono line at the leading edge and the section's buttons at the trailing edge.
struct SettingsFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: S.footerGap) {
            leading.projectType(S.footerText).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
            Spacer(minLength: 0)
            trailing
        }
        .monospacedDigit()
        .padding(.leading, S.bodyInset).padding(.trailing, S.footerTrailing)
        .frame(height: S.footerHeight)
        .overlay(alignment: .top) { SettingsRowDivider() }
    }
}

/// A footer's refresh button: an icon button of 24 with a 14 pt glyph.
struct SettingsRefreshButton: View {
    let label: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "arrow.clockwise").font(S.footerGlyph) }
            .buttonStyle(ChromeButtonStyle(size: S.footerButton))
            .disabled(disabled)
            .help(label)
            .accessibilityLabel(label)
    }
}
