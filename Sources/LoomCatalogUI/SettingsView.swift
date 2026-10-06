import SwiftUI

public struct SettingsView: View {
    let model: CatalogModel
    public init(model: CatalogModel) { self.model = model }

    public var body: some View {
        Form {
            Picker("Terminal font size", selection: Binding(
                get: { model.terminalFontSize }, set: { model.setTerminalFontSize($0) }
            )) {
                ForEach(11...20, id: \.self) { size in
                    Text("\(size) pt").tag(Double(size))
                }
            }
            .accessibilityLabel("Terminal font size")
            Text("Applies to existing and new terminals.").font(.caption).foregroundStyle(.secondary)
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(LoomTheme.Space.settingsPadding)
        .frame(width: LoomTheme.Layout.settingsWidth)
    }
}
