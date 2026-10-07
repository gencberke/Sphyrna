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
                    WithoutProjectStartButton(model: model, title: ClaudeStartEntry.withoutProjectFooterTitle)
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

/// Tokens and limit, then the limit alone, then the tokens cut with an ellipsis. No money.
private struct UsageChipLabel: View {
    let chip: UsageChipContent
    @Environment(\.usageChipHovered) private var hovered

    var body: some View {
        let tone = hovered ? LoomTheme.Text.primary : LoomTheme.Text.secondary
        ViewThatFits(in: .horizontal) {
            text(tone, showLimit: true).fixedSize(horizontal: true, vertical: false)
            if let limit = chip.limit {
                Text(limit).foregroundStyle(tone).fixedSize(horizontal: true, vertical: false)
            }
            text(tone, showLimit: false).truncationMode(.tail)
        }
        .font(LoomTheme.Typography.statusLabel).monospacedDigit()
        .lineLimit(1)
    }

    private func text(_ tone: Color, showLimit: Bool) -> Text {
        let lead = Text(chip.lead).foregroundStyle(tone)
        let figure = Text(chip.figure).fontWeight(.semibold).foregroundStyle(LoomTheme.Text.primary)
        let suffix = Text(chip.suffix).foregroundStyle(tone)
        let limit = Text(showLimit ? chip.limit.map { " · " + $0 } ?? "" : "").foregroundStyle(tone)
        return Text("\(lead)\(figure)\(suffix)\(limit)")
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
