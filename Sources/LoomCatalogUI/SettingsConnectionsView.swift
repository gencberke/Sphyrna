import AppKit
import LoomCore
import SwiftUI

/// Settings → Connections (D-98, FB5-8): each harness, whether it is found, its version, who is signed in and whether its limits
/// can be read; a switch to connect or disconnect it; and a detail for the one picked, with how to set it up. Opening the page
/// checks the harnesses (under the 5-minute floor).
struct ConnectionsSettings: View {
    let model: CatalogModel
    @State private var picked: ManagedSession.Provider = .claude

    var body: some View {
        if let health = model.harnessHealth {
            ConnectionsPage(model: model, health: health, picked: $picked)
        } else {
            SettingsNote(title: "Connections are not available", text: "This build has no harness check to show.")
        }
    }
}

private struct ConnectionsPage: View {
    let model: CatalogModel
    let health: HarnessHealthModel
    @Binding var picked: ManagedSession.Provider

    private typealias S = LoomTheme.Settings

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: S.groupGap) {
                SettingsGroup(label: "Agents") {
                    ForEach(Array(HarnessHealthModel.providers.enumerated()), id: \.element) { index, provider in
                        if index > 0 { SettingsRowDivider() }
                        ConnectionRow(model: model, health: health, provider: provider, isPicked: picked == provider) { picked = provider }
                    }
                }
                ConnectionDetail(model: model, health: health, provider: picked)
            }
        }
        .onAppear { health.pageOpened() }
        // The mark "Account changed" stays until the page has been seen.
        .onDisappear { for provider in HarnessHealthModel.providers { health.acknowledgeAccountChange(provider) } }
        .accessibilityIdentifier("settings-connections")
    }
}

/// A harness row: the mark, the name over its version, the status dot and headline, and the connect switch.
private struct ConnectionRow: View {
    let model: CatalogModel
    let health: HarnessHealthModel
    let provider: ManagedSession.Provider
    let isPicked: Bool
    let onPick: () -> Void

    private typealias S = LoomTheme.Settings
    private typealias C = LoomTheme.Connect

    var body: some View {
        let row = ConnectionsContent.row(
            for: health.health(of: provider), connected: health.connections.isConnected(provider),
            startNote: model.newSessionUnavailableReason(provider))
        HStack(spacing: C.rowGap) {
            ProviderIcon(provider: provider, size: C.markSize)
            VStack(alignment: .leading, spacing: C.versionTop) {
                Text(row.name).projectType(C.name).foregroundStyle(LoomTheme.Text.primary)
                Text(row.version).projectType(C.version).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
            Spacer(minLength: S.rowGap)
            HStack(spacing: C.dotGap) {
                Circle().fill(C.dotColor(row.health.state)).frame(width: C.dot, height: C.dot).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.headline).projectType(C.headline).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .lineLimit(1).truncationMode(.tail)
                    if row.showsAccountChanged {
                        Text("Account changed").projectType(C.changed).foregroundStyle(LoomTheme.Status.attentionLight)
                    }
                }
            }
            .frame(maxWidth: C.headlineMaxWidth, alignment: .trailing)
            SettingsSwitch(title: "Connect \(row.name)", isOn: Binding(
                get: { health.connections.isConnected(provider) }, set: { health.setConnected(provider, $0) }))
                .help(ConnectionsContent.switchHelp)
        }
        .padding(.vertical, S.rowPaddingV).padding(.horizontal, S.rowPaddingH)
        .frame(minHeight: S.rowMinHeight)
        .background(RoundedRectangle(cornerRadius: C.pickedRadius).fill(isPicked ? LoomTheme.Surface.controlHover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityAction(.default, onPick)
        .accessibilityIdentifier("connection-row-\(provider.rawValue)")
    }
}

/// The detail of the picked harness: where it is, its version, who is signed in, the profile folder, its limits and the last
/// check; how to set it up while that is needed; and Deep Check.
private struct ConnectionDetail: View {
    let model: CatalogModel
    let health: HarnessHealthModel
    let provider: ManagedSession.Provider

    private typealias S = LoomTheme.Settings
    private typealias C = LoomTheme.Connect

    var body: some View {
        let value = health.health(of: provider)
        let detail = ConnectionsContent.detail(for: value)
        let checking = health.isChecking(provider) || value.state == .checking
        SettingsGroup(label: detail.name) {
            SettingsRow(title: "Location", detail: detail.location, detailStyle: S.path) {
                if detail.path != nil, let executable = value.executable {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: executable)]) }
                        .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                        .accessibilityLabel("Reveal \(detail.name) in Finder")
                }
            }
            SettingsRowDivider()
            SettingsRow(title: "Version", detail: detail.version) {}
            SettingsRowDivider()
            SettingsRow(title: "Account", detail: detail.account) {}
            if let profile = detail.profile {
                SettingsRowDivider()
                SettingsRow(title: "Profile folder", detail: profile, detailStyle: S.path) {}
            }
            SettingsRowDivider()
            SettingsRow(title: "Limits", detail: detail.limits) {}
            SettingsRowDivider()
            SettingsRow(title: "Check", detail: detail.checked, notice: detail.setup == nil ? value.note : nil) {
                Button(checking ? "Checking…" : "Check Again") { health.checkAgain(provider) }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                    .disabled(checking || value.state == .disabled)
                    .accessibilityLabel("Check \(detail.name) again")
                    .accessibilityIdentifier("connection-check-again")
            }
            if let setup = detail.setup {
                SettingsRowDivider()
                HarnessSetupBlock(health: health, provider: provider, command: setup, note: value.note)
                    .padding(.vertical, S.rowPaddingV).padding(.horizontal, S.rowPaddingH)
            }
            SettingsRowDivider()
            ConnectionDeepCheck(health: health, provider: provider, detail: detail)
        }
    }
}

/// Deep Check: the CLI's own health command, run only when the button is pressed, shown as text.
private struct ConnectionDeepCheck: View {
    let health: HarnessHealthModel
    let provider: ManagedSession.Provider
    let detail: ConnectionsContent.Detail

    private typealias S = LoomTheme.Settings
    private typealias C = LoomTheme.Connect

    var body: some View {
        let progress = health.deepChecks[provider]
        VStack(spacing: 0) {
            SettingsRow(title: "Deep Check",
                        detail: "Runs \(detail.deepCheckCommand) and shows what it says. It runs only when you choose it, and stops after 30 seconds.") {
                Button(progress == .running ? "Running…" : "Deep Check") { health.runDeepCheck(provider) }
                    .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                    .disabled(!health.offersDeepCheck || !detail.canDeepCheck || progress == .running)
                    .accessibilityLabel("Run Deep Check for \(detail.name)")
                    .accessibilityIdentifier("connection-deep-check")
            }
            if case let .done(result)? = progress {
                ScrollView {
                    Text(result.text).projectType(C.deepFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(C.deepPadding)
                }
                .frame(maxHeight: C.deepMaxHeight)
                .background(RoundedRectangle(cornerRadius: C.commandRadius).fill(C.commandFill))
                .padding(.horizontal, S.rowPaddingH).padding(.bottom, S.rowPaddingV)
                .accessibilityLabel("Deep Check output")
                .accessibilityIdentifier("connection-deep-check-output")
            }
        }
    }
}
