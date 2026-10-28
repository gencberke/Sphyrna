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
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .regular))
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

/// Where mode and model come from when it is not the draft's own pick, as a quiet line under the presets.
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
