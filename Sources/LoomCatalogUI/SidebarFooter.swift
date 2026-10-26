import SwiftUI

/// The sidebar's bottom bar (D-32; DESIGN §2 item 5): 46 pt with a hairline above it, holding the `+` menu, a compact Claude usage
/// chip in mono 11 and Settings. The chip is the one flexible element, so its text never moves anything above it.
struct SidebarFooter: View {
    let model: CatalogModel

    /// Without a selected session's project the plain entries already start without one.
    static func offersWithoutProject(contextProjectID: UUID?) -> Bool { contextProjectID != nil }

    var body: some View {
        HStack(spacing: LoomTheme.Sidebar.footerSpacing) {
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
            .menuStyle(.button).buttonStyle(ChromeButtonStyle())
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
            .buttonStyle(ChromeButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .focusEffectDisabled()
        .padding(.horizontal, LoomTheme.Sidebar.footerInset)
        .frame(height: LoomTheme.Sidebar.footerHeight(lines: model.usage?.chip?.lines.count ?? 1))
        .overlay(alignment: .top) {
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
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
                    .buttonStyle(UsageChipButtonStyle(lines: chip.lines.count))
                    .help(chip.tooltip)
                    .accessibilityLabel(chip.accessibilityLabel)
                    .accessibilityHint("Opens Usage in Settings")
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: LoomTheme.Sidebar.chipHeight(lines: usage.chip?.lines.count ?? 1))
    }
}

/// Tokens on the left, the limit (name, meter, percent) pinned to the right, in mono 11. Narrow: the meter
/// drops first, then the tokens are cut with an ellipsis; the limit is never cut. No money.
struct UsageChipLabel: View {
    let chip: UsageChipContent
    @Environment(\.usageChipHovered) private var hovered

    var body: some View {
        // The words are the quiet voice and the figures one step up (the reference's `usage`); the pointer lifts both to primary.
        let tone = hovered ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.tertiaryStyle)
        let value = hovered ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle)
        Group {
            if chip.lines.count > 1 {
                // A line per harness: its mark, today's tokens and its tightest limit.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chip.lines.prefix(LoomTheme.Sidebar.chipMaxLines).enumerated()), id: \.offset) { _, line in
                        harnessLine(line, tone, value).frame(height: LoomTheme.Sidebar.chipLineHeight)
                    }
                }
            } else if let limit = chip.limit {
                ViewThatFits(in: .horizontal) {
                    // No fixedSize here: ViewThatFits tests the ideal width (tokens, the least gap, limit), and the
                    // chosen child then takes the whole proposal so the spacer pushes the limit to the trailing edge.
                    // When none fits the last one is used and the tokens truncate.
                    split(tone, value, limit, showMeter: true)
                    split(tone, value, limit, showMeter: false)
                }
            } else {
                tokens(tone, value).truncationMode(.tail)
            }
        }
        .font(LoomTheme.Sidebar.chipFont)
        .lineLimit(1)
    }

    private func split(_ tone: AnyShapeStyle, _ value: AnyShapeStyle, _ limit: UsageChipContent.Limit,
                       showMeter: Bool) -> some View {
        HStack(spacing: 0) {
            tokens(tone, value).truncationMode(.tail)
            Spacer(minLength: LoomTheme.Space.chipSplitGap)
            limitGroup(limit, tone, value, showMeter: showMeter)
        }
    }

    private func limitGroup(_ limit: UsageChipContent.Limit, _ tone: AnyShapeStyle, _ value: AnyShapeStyle,
                            showMeter: Bool) -> some View {
        HStack(spacing: LoomTheme.Space.chipLimitGap) {
            Text(limit.name).foregroundStyle(tone)
            if showMeter { UsageChipMeter(remainingPercent: limit.remainingPercent, isLow: limit.isLow) }
            Text(UsageFormat.percent(limit.remainingPercent))
                .foregroundStyle(limit.isLow ? AnyShapeStyle(LoomTheme.Status.attentionLight) : value)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// `[mark] 168M  Wk ▬ 15%`: the meter drops first when the line is narrow, then the tokens are cut.
    private func harnessLine(_ line: UsageChipContent.Line, _ tone: AnyShapeStyle, _ value: AnyShapeStyle) -> some View {
        HStack(spacing: 0) {
            ProviderIcon(provider: line.harness, size: LoomTheme.Sidebar.chipHarnessMark)
                .padding(.trailing, LoomTheme.Space.chipLimitGap)
            Text(line.figure).foregroundStyle(value).truncationMode(.tail)
            Spacer(minLength: LoomTheme.Space.chipSplitGap)
            if let limit = line.limit {
                ViewThatFits(in: .horizontal) {
                    limitGroup(limit, tone, value, showMeter: true)
                    limitGroup(limit, tone, value, showMeter: false)
                }
            }
        }
    }

    private func tokens(_ tone: AnyShapeStyle, _ value: AnyShapeStyle) -> Text {
        let lead = Text(chip.lead).foregroundStyle(tone)
        let figure = Text(chip.figure).foregroundStyle(value)
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
            .frame(width: LoomTheme.Sidebar.chipMeter.width, height: LoomTheme.Sidebar.chipMeter.height)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim)
                    .fill(isLow ? LoomTheme.Status.attention : LoomTheme.Text.secondary)
                    .frame(width: LoomTheme.Sidebar.chipMeter.width * fraction)
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

/// One 24 pt button with the shared pill on hover and press, like the chrome buttons.
private struct UsageChipButtonStyle: ButtonStyle {
    var lines = 1

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, lines: lines)
    }

    private struct Chip: View {
        let configuration: ButtonStyle.Configuration
        let lines: Int
        @State private var hovering = false
        @Environment(\.isFocused) private var focused

        var body: some View {
            let state = HighlightState.resolve(selected: false, hovering: hovering, pressed: configuration.isPressed)
            configuration.label
                .environment(\.usageChipHovered, hovering || configuration.isPressed)
                .padding(.horizontal, LoomTheme.Space.chipInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: LoomTheme.Sidebar.chipHeight(lines: lines))
                .background(RowHighlight(state: state, radius: LoomTheme.Highlight.radiusControl))
                .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.control)
                    .strokeBorder(ChromeButtonStyle.showsFocusRing(
                        focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled)
                        ? LoomTheme.Surface.focusRing : .clear, lineWidth: LoomTheme.Line.focusRing))
                .contentShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
                .onHover { hovering = $0 }
        }
    }
}
