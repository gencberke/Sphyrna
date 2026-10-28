import AppKit
import LoomCore
import SwiftUI

/// Settings → Connections: every catalogue harness, its PATH and switch state, and the selected harness's detail.
struct ConnectionsSettings: View {
    let model: CatalogModel
    @State private var picked: HarnessID = .claude

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
    @Binding var picked: HarnessID
    private typealias S = LoomTheme.Settings

    var body: some View {
        let rows = model.connectionRows
        SettingsPage {
            VStack(alignment: .leading, spacing: S.groupGap) {
                SettingsGroup(label: "Agents") {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsRowDivider() }
                        ConnectionRow(model: model, row: row, isPicked: picked == row.id) { picked = row.id }
                    }
                }
                if let row = rows.first(where: { $0.id == picked }) {
                    ConnectionDetail(model: model, health: health, row: row)
                }
            }
        }
        .onAppear { health.pageOpened() }
        .onDisappear { for provider in HarnessHealthModel.providers { health.acknowledgeAccountChange(provider) } }
        .accessibilityIdentifier("settings-connections")
    }
}

private struct ConnectionRow: View {
    let model: CatalogModel
    let row: ConnectionsContent.HarnessRow
    let isPicked: Bool
    let onPick: () -> Void
    private typealias S = LoomTheme.Settings
    private typealias C = LoomTheme.Connect

    var body: some View {
        HStack(spacing: C.rowGap) {
            HStack(spacing: C.rowGap) {
                ProviderIcon(harness: row.id, size: C.markSize)
                VStack(alignment: .leading, spacing: C.versionTop) {
                    Text(row.name).projectType(C.name).foregroundStyle(LoomTheme.Text.primary)
                    Text(row.version).projectType(C.version).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                }
                Spacer(minLength: S.rowGap)
                HStack(spacing: C.dotGap) {
                    Circle().fill(C.dotColor(row.state)).frame(width: C.dot, height: C.dot).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.headline).projectType(C.headline).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .lineLimit(1).truncationMode(.tail)
                        if row.showsAccountChanged {
                            Text("Account changed").projectType(C.changed).foregroundStyle(LoomTheme.Status.attentionLight)
                        }
                    }
                }
                .frame(maxWidth: C.headlineMaxWidth, alignment: .trailing)
            }
            .opacity(row.availability == .off ? C.offOpacity : 1)
            SettingsSwitch(title: "Connect \(row.name)", isOn: Binding(
                get: { row.isOn }, set: { model.setHarnessConnected(row.id, $0) }))
                .disabled(!row.canSwitch)
                .help(ConnectionsContent.switchHelp)
                .accessibilityIdentifier("connection-switch-\(row.id.rawValue)")
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
        .accessibilityIdentifier("connection-row-\(row.id.rawValue)")
    }
}

private struct ConnectionDetail: View {
    let model: CatalogModel
    let health: HarnessHealthModel
    let row: ConnectionsContent.HarnessRow
    private typealias S = LoomTheme.Settings

    var body: some View {
        SettingsGroup(label: row.name) {
            if row.availability == .notFound {
                SettingsRow(title: "Status", detail: row.missingExplanation) { checkButton }
                if let command = row.descriptor.install {
                    SettingsRowDivider()
                    HarnessSetupBlock(health: health, id: row.id, command: command)
                        .padding(.vertical, S.rowPaddingV).padding(.horizontal, S.rowPaddingH)
                }
                documentation
            } else if let provider = row.descriptor.provider {
                providerDetail(provider)
            } else {
                SettingsRow(title: "Location", detail: row.executable ?? "Not read", detailStyle: S.path) { checkButton }
                SettingsRowDivider()
                SettingsRow(title: "Status", detail: row.headline, notice: row.startNote) {}
                documentation
            }
        }
    }

    private var checkButton: some View {
        let checking = model.harnessRecheckInProgress || (row.descriptor.provider.map { health.isChecking($0) } ?? false)
        return Button(checking ? "Checking…" : "Check Again") { model.recheckHarness(row.id) }
            .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
            .disabled(checking)
            .accessibilityLabel("Check \(row.name) again")
            .accessibilityIdentifier("connection-check-again")
    }

    @ViewBuilder private var documentation: some View {
        if let url = row.descriptor.docs {
            SettingsRowDivider()
            SettingsRow(title: "Documentation", detail: "Open the vendor's setup guide.") {
                Link("Open Docs", destination: url).buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
            }
        }
    }

    @ViewBuilder private func providerDetail(_ provider: ManagedSession.Provider) -> some View {
        let value = health.health(of: provider)
        let detail = ConnectionsContent.detail(for: value)
        SettingsRow(title: "Location", detail: row.executable ?? detail.location, detailStyle: S.path) {
            if let executable = row.executable {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: executable)]) }
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
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
        SettingsRow(title: "Check", detail: detail.checked, notice: detail.setup == nil ? value.note : nil) { checkButton }
        if let setup = detail.setup, value.state == .signIn {
            SettingsRowDivider()
            HarnessSetupBlock(health: health, id: row.id, command: setup, note: value.note)
                .padding(.vertical, S.rowPaddingV).padding(.horizontal, S.rowPaddingH)
        }
        if let note = row.startNote {
            SettingsRowDivider()
            SettingsRow(title: "Sessions", detail: note) {}
        }
        SettingsRowDivider()
        ConnectionDeepCheck(health: health, provider: provider, detail: detail)
    }
}

/// Deep Check runs a provider's own health command only when chosen.
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
                        detail: "Runs \(detail.deepCheckCommand) and shows what it says. It runs only when you choose it, and stops after \(Int(HarnessDeepCheck.defaultTimeout)) seconds.") {
                Button(progress == .running ? "Running…" : "Deep Check") { health.runDeepCheck(provider) }
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
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
