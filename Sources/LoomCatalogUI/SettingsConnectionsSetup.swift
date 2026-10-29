import AppKit
import LoomCore
import SwiftUI

/// The setup of a harness without credentials (D-98): the vendor's command in a selectable field, with Copy and Open Terminal.
/// Sphyrna runs nothing, types into nothing and never handles a password: the person runs the command in their own Terminal.
/// Provider-backed setup also makes the next activation check that provider once.
struct HarnessSetupBlock: View {
    let health: HarnessHealthModel
    let id: HarnessID
    let command: HarnessSetupCommand
    var note: String?

    private typealias C = LoomTheme.Connect

    var body: some View {
        let name = HarnessCatalogue.descriptor(for: id)?.displayName ?? id.rawValue
        VStack(alignment: .leading, spacing: 0) {
            Text("\(command.title) \(name)").projectType(LoomTheme.Settings.rowTitle).foregroundStyle(LoomTheme.Text.primary)
            Text(Self.help(command: command, name: name))
                .projectType(LoomTheme.Settings.rowHelp).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, LoomTheme.Settings.helpTop)
            if let note {
                Text(note).projectType(LoomTheme.Settings.rowHelp).foregroundStyle(LoomTheme.Status.attentionLight)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LoomTheme.Settings.noticeTop)
            }
            commandField(command.command, label: "\(command.title) command for \(name)", id: "setup-command-\(id.rawValue)")
                .padding(.top, C.commandTop)
            if let alternative = command.alternative {
                Text("Or: \(alternative)").projectType(C.alternative).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, C.commandGap)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Other way to \(command.title.lowercased()) \(name)")
            }
            HStack(spacing: C.commandGap) {
                Button("Copy") { health.copy(command, forHarness: id) }
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                    .accessibilityLabel("Copy the \(command.title.lowercased()) command for \(name)")
                    .accessibilityIdentifier("setup-copy-\(id.rawValue)")
                Button("Open Terminal") { health.openTerminal(forHarness: id) }
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                    .accessibilityLabel("Open Terminal")
                    .accessibilityIdentifier("setup-open-terminal-\(id.rawValue)")
            }
            .padding(.top, C.commandTop)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup-\(id.rawValue)")
    }

    /// What the block says it does: show the command, never run it.
    static func help(command: HarnessSetupCommand, name: String) -> String {
        "Run this in Terminal, then choose Check Again. Sphyrna does not run it for you."
    }

    /// The command reads as the text of a group named by `label`: a selectable Text must never carry its own accessibility
    /// label, which SwiftUI resolves by asking the text's AppKit element again, without end (ARCHITECTURE §12).
    private func commandField(_ text: String, label: String, id: String) -> some View {
        Text(text).projectType(C.commandFont).foregroundStyle(LoomTheme.Text.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, C.commandPaddingH).padding(.vertical, C.commandPaddingV)
            .background(RoundedRectangle(cornerRadius: C.commandRadius).fill(C.commandFill))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }
}
