import LoomCore
import SwiftUI

/// The presets row under the strip (DESIGN §8 Presets): a "Presets" label and the saved starts as chips, centred, and at the end
/// "Save as preset" once there is text. A click puts the preset's message into the composer; nothing starts.
struct PresetRow: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        let presets = model.presets(for: projectID)
        let canSave = model.newSession.draft(for: projectID)?.isVisible ?? false
        if !presets.isEmpty || canSave {
            FlowLayout(spacing: NewSessionLayout.presetGap) {
                if !presets.isEmpty {
                    Text("Presets").draftType(LoomTheme.InkType.label).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        .padding(.trailing, LoomTheme.Draft.labelExtraGap)
                        .accessibilityHidden(true)
                }
                ForEach(presets) { preset in
                    Button { model.applyPreset(preset, projectID: projectID) } label: {
                        Text(preset.name).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: LoomTheme.Draft.chipMaxWidth)
                    }
                    .buttonStyle(PresetChipStyle())
                    .contextMenu { Button("Remove Preset") { model.removePreset(preset) } }
                    .help(preset.message)
                    .accessibilityIdentifier("draft-preset")
                }
                if canSave {
                    Button { model.savePreset(projectID: projectID) } label: { Text("Save as preset") }
                        .buttonStyle(ControlButtonStyle(kind: .ghost))
                        .accessibilityIdentifier("draft-save-preset")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, NewSessionLayout.presetsTop)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Presets")
        }
    }
}

/// A preset chip: 26 high, radius 6, 12 secondary words on the canvas at 72 % under a strong-hairline edge; the pointer makes the
/// words primary and the edge the stronger hairline (the reference's `.pchip`).
struct PresetChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Chip(configuration: configuration) }

    private struct Chip: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: LoomTheme.InkRadius.control)
            let active = enabled && (hovering || configuration.isPressed)
            configuration.label
                .draftType(LoomTheme.Draft.chipText)
                .foregroundStyle(active ? AnyShapeStyle(LoomTheme.Text.primary) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                .padding(.horizontal, LoomTheme.Draft.chipPaddingH)
                .frame(height: LoomTheme.InkHeight.control)
                .background(shape.fill(LoomTheme.Surface.canvas.opacity(LoomTheme.Draft.chipFillOpacity)))
                .overlay(shape.strokeBorder(edge, lineWidth: LoomTheme.Line.hairline))
                .controlFocusRing(
                    visible: ChromeButtonStyle.showsFocusRing(focused: focused, keyboardNavigation: KeyboardNavigation.shared.isEnabled),
                    radius: LoomTheme.InkRadius.control)
                .contentShape(shape)
                .opacity(enabled ? 1 : LoomTheme.Opacity.disabled)
                .onHover { hovering = $0 }
        }

        private var edge: AnyShapeStyle {
            if contrast == .increased { return AnyShapeStyle(LoomTheme.Surface.hairlineStyle) }
            let active = enabled && (hovering || configuration.isPressed)
            return AnyShapeStyle(active ? LoomTheme.Surface.strongerHairline : LoomTheme.Surface.strongHairline)
        }
    }
}

/// Where mode and model come from when it is not the draft's own pick (the defaults of CHAT-SPEC), as a quiet line under the
/// presets: mono tertiary, centred, and nothing when the draft's own picks decide.
struct DraftSourceNote: View {
    let model: CatalogModel
    let projectID: UUID?

    var body: some View {
        if let note = Self.words(resolved: model.resolvedStart(for: projectID), projectName: model.draftProject(projectID)?.name) {
            Text(note).draftType(LoomTheme.Draft.note).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .padding(.top, NewSessionLayout.presetsTop)
        }
    }

    static func words(resolved: ResolvedStart, projectName: String?) -> String? {
        if resolved.mode.source == .lastUsed || resolved.model.source == .lastUsed {
            return "Mode and model as last used" + (projectName.map { " in \($0)" } ?? "")
        }
        if resolved.mode.source == .settings || resolved.model.source == .settings { return "Mode and model from Settings" }
        return nil
    }
}
