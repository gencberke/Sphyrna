import SwiftUI

/// A separate menu of only the current model's supported levels, plus its explicit Default reset.
struct EffortPickerMenu: View {
    let modelTitle: String
    let options: EffortPickerOptions
    let cursor: EffortPickerController
    let identifier: String
    let choose: (EffortPickerController.Choice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LoomTheme.ModelPicker.rowGap) {
                Text("Effort").font(LoomTheme.ModelPicker.groupFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                Spacer(minLength: 0)
                Text(modelTitle).font(LoomTheme.ModelPicker.countFont).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
            }
            .padding(.horizontal, LoomTheme.ModelPicker.rowInset).frame(height: LoomTheme.ModelPicker.effortHeaderHeight)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        row(.default, title: "Default", note: "Let the harness decide", checked: options.current == nil, isDefault: false)
                            .id(EffortPickerController.Choice.default)
                        ForEach(options.levels, id: \.self) { level in
                            row(.level(level), title: ComposerBarText.effortLabel(level), note: Self.note(level),
                                checked: options.current == level, isDefault: options.defaultLevel == level)
                                .id(EffortPickerController.Choice.level(level))
                        }
                    }
                }
                .frame(height: min(CGFloat(options.levels.count + 1) * LoomTheme.ModelPicker.rowHeight,
                                   LoomTheme.ModelPicker.effortListMaxHeight))
                .onChange(of: cursor.cursor) { _, choice in if let choice { proxy.scrollTo(choice) } }
            }
        }
        .padding(LoomTheme.ModelPicker.effortInset)
        .frame(width: LoomTheme.ModelPicker.effortWidth)
        .accessibilityElement(children: .contain).accessibilityLabel("Effort for \(modelTitle)")
        .accessibilityIdentifier("\(identifier)-list")
    }

    private func row(_ choice: EffortPickerController.Choice, title: String, note: String?, checked: Bool, isDefault: Bool) -> some View {
        Button { cursor.cursor = choice; choose(choice) } label: {
            HStack(spacing: LoomTheme.ModelPicker.rowGap) {
                Text(title).font(LoomTheme.ModelPicker.rowFont).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                    .frame(width: LoomTheme.ModelPicker.effortNameWidth, alignment: .leading)
                if let note {
                    Text(note).font(LoomTheme.ModelPicker.descriptionFont).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if isDefault {
                    Text("Default").font(LoomTheme.ModelPicker.countFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .padding(.horizontal, LoomTheme.ModelPicker.effortTagInset).frame(height: LoomTheme.ModelPicker.effortTagHeight)
                        .background(Capsule().fill(LoomTheme.Surface.muted))
                }
                Group {
                    if checked { Image(systemName: "checkmark").font(LoomTheme.ModelPicker.iconFont).foregroundStyle(LoomTheme.Accent.base) }
                }
                .frame(width: LoomTheme.ModelPicker.checkWidth).accessibilityHidden(true)
            }
            .padding(.horizontal, LoomTheme.ModelPicker.rowInset).frame(height: LoomTheme.ModelPicker.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RowHighlight(state: cursor.cursor == choice ? .selected : .none, radius: LoomTheme.ModelPicker.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { if $0 { cursor.cursor = choice } }
        .accessibilityLabel([title, note, isDefault ? "Model default" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(checked ? .isSelected : [])
        .accessibilityIdentifier("\(identifier)-choice-\(title)")
    }

    /// Unknown future levels get no guessed promise.
    static func note(_ level: String) -> String? {
        switch level {
        case "low": "For straightforward work"
        case "medium": "For everyday work"
        case "high": "For harder work"
        case "xhigh": "For demanding work"
        case "max": "Maximum effort"
        default: nil
        }
    }
}
