import SwiftUI

/// The sidebar's bottom bar (D-32): the new-conversation menu, a compact Claude usage chip and
/// Settings. The bar keeps today's 38 pt; the chip is the one flexible element, so its text never
/// moves anything above it.
struct SidebarFooter: View {
    let model: CatalogModel

    /// Without a selected session's project the plain entries already start without one.
    static func offersWithoutProject(contextProjectID: UUID?) -> Bool { contextProjectID != nil }

    var body: some View {
        HStack(spacing: LoomTheme.Space.footerSpacing) {
            Menu {
                NewConversationButtons(model: model, projectID: model.contextProjectID)
                // The entries above start in the selected session's project; this one says "no project".
                if Self.offersWithoutProject(contextProjectID: model.contextProjectID) {
                    WithoutProjectStartButton(model: model, title: ClaudeStartEntry.withoutProjectTitle)
                }
                Divider()
                Button("Add Project…") { model.presentAddProject() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.button).buttonStyle(ChromeButtonStyle(size: LoomTheme.Layout.footerButton))
            .menuIndicator(.hidden).fixedSize()
            .help("New session or project")
            .accessibilityLabel("New session or project")
            if let usage = model.usage {
                UsageChip(usage: usage) { model.showSettings(.usage) }
            } else {
                Spacer(minLength: 0)
            }
            Button { model.showSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(ChromeButtonStyle(size: LoomTheme.Layout.footerButton))
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .font(LoomTheme.Typography.footerIcon)
        .focusEffectDisabled()
        .padding(.horizontal, LoomTheme.Space.footerInset)
        .frame(height: LoomTheme.Layout.footerHeight)
    }
}

/// Reads only `UsageModel.chip`, so the footer redraws when the chip's text changes and not on
/// catalog or list changes (and not when a refresh finds the same figures).
struct UsageChip: View {
    let usage: UsageModel
    let open: () -> Void

    var body: some View {
        Group {
            if let chip = usage.chip {
                Button(action: open) { UsageChipLabel(chip: chip) }
                    .buttonStyle(UsageChipButtonStyle())
                    .help(chip.tooltip)
                    .accessibilityLabel(chip.accessibilityLabel)
                    .accessibilityHint("Opens Usage in Settings")
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: LoomTheme.Layout.footerChipHeight)
    }
}

/// Tokens on the left, the limit (name, meter, percent) pinned to the right. Narrow: the meter
/// drops first, then the tokens are cut with an ellipsis; the limit is never cut. No money.
struct UsageChipLabel: View {
    let chip: UsageChipContent
    @Environment(\.usageChipHovered) private var hovered

    var body: some View {
        let tone = hovered ? LoomTheme.Text.primary : LoomTheme.Text.secondary
        Group {
            if let limit = chip.limit {
                ViewThatFits(in: .horizontal) {
                    // No fixedSize here: ViewThatFits tests the ideal width (tokens, the least gap, limit), and the
                    // chosen child then takes the whole proposal so the spacer pushes the limit to the trailing edge.
                    // When none fits the last one is used and the tokens truncate.
                    split(tone, limit, showMeter: true)
                    split(tone, limit, showMeter: false)
                }
            } else {
                tokens(tone).truncationMode(.tail)
            }
        }
        .font(LoomTheme.Typography.statusLabel).monospacedDigit()
        .lineLimit(1)
    }

    private func split(_ tone: Color, _ limit: UsageChipContent.Limit, showMeter: Bool) -> some View {
        HStack(spacing: 0) {
            tokens(tone).truncationMode(.tail)
            Spacer(minLength: LoomTheme.Space.chipSplitGap)
            HStack(spacing: LoomTheme.Space.chipLimitGap) {
                Text(limit.name).foregroundStyle(tone)
                if showMeter { UsageChipMeter(remainingPercent: limit.remainingPercent, isLow: limit.isLow) }
                Text("\(limit.remainingPercent)%").fontWeight(.semibold)
                    .foregroundStyle(limit.isLow ? LoomTheme.Status.attention : LoomTheme.Text.primary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func tokens(_ tone: Color) -> Text {
        let lead = Text(chip.lead).foregroundStyle(tone)
        let figure = Text(chip.figure).fontWeight(.semibold).foregroundStyle(LoomTheme.Text.primary)
        let suffix = Text(chip.suffix).foregroundStyle(tone)
        return Text("\(lead)\(figure)\(suffix)")
    }
}

/// The remaining share of the limit window: a thin track and a fill in the secondary tone (orange when low).
private struct UsageChipMeter: View {
    let remainingPercent: Int
    let isLow: Bool

    var body: some View {
        let fraction = CGFloat(min(max(remainingPercent, 0), 100)) / 100
        RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim)
            .fill(LoomTheme.Surface.chipMeterTrack)
            .frame(width: LoomTheme.Layout.chipMeter.width, height: LoomTheme.Layout.chipMeter.height)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim)
                    .fill(isLow ? LoomTheme.Status.attention : LoomTheme.Text.secondary)
                    .frame(width: LoomTheme.Layout.chipMeter.width * fraction)
            }
            .accessibilityHidden(true)
    }
}

private struct UsageChipHoverKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    fileprivate var usageChipHovered: Bool {
        get { self[UsageChipHoverKey.self] }
        set { self[UsageChipHoverKey.self] = newValue }
    }
}

/// One 24 pt button: white 9 % fill on hover and 14 % pressed, like the chrome buttons.
private struct UsageChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration)
    }

    private struct Chip: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            let background: Color = configuration.isPressed ? LoomTheme.Surface.controlPressed
                : (hovering ? LoomTheme.Surface.controlHover : .clear)
            configuration.label
                .environment(\.usageChipHovered, hovering || configuration.isPressed)
                .padding(.horizontal, LoomTheme.Space.chipInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: LoomTheme.Layout.footerChipHeight)
                .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.control).fill(background))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
                    .strokeBorder(ChromeButtonStyle.showsFocusRing(
                        focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled)
                        ? LoomTheme.Surface.focusRing : .clear, lineWidth: LoomTheme.Line.focusRing))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
                .onHover { hovering = $0 }
        }
    }
}
