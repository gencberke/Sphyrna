import AppKit
import Foundation
import LoomCore

/// What the Connections page says about each harness, as plain values: a test reads the words without a view. The detail's
/// account line carries the email (the one place it is shown); it is built when the page draws and kept nowhere.
enum ConnectionsContent {
    /// The detail of the picked harness.
    struct Detail: Equatable {
        let name: String
        /// The CLI's path in the home-relative form, or nil while it is not found.
        let path: String?
        let location: String
        let version: String
        let account: String
        let profile: String?
        let limits: String
        let checked: String
        /// How to install or sign in, while the state asks for it.
        let setup: HarnessSetupCommand?
        /// "claude doctor".
        let deepCheckCommand: String
        /// Deep Check can run: the CLI is there and the harness is on.
        let canDeepCheck: Bool
    }

    static let switchHelp = "Off, Sphyrna stops checking this agent and reading its usage and models. Sessions that exist keep working. "
        + "Sphyrna never signs the CLI out or changes its settings."

    static func detail(for health: HarnessHealth, now: Date = Date()) -> Detail {
        let provider = health.provider
        let name = ProviderName.title(provider)
        return Detail(
            name: name, path: health.executable.map { ($0 as NSString).abbreviatingWithTildeInPath },
            location: locationText(health), version: versionText(health), account: accountText(health),
            profile: health.profileDirectory.map(SettingsPaths.display), limits: limitsText(health), checked: checkedText(health, now: now),
            setup: HarnessSetupCommand.command(for: provider, state: health.state), deepCheckCommand: HarnessDeepCheck.display(for: provider),
            canDeepCheck: health.executable != nil && health.state != .disabled)
    }

    static func locationText(_ health: HarnessHealth) -> String {
        switch health.state {
        case .disabled: "Turned off"
        case .checking: "Checking…"
        case .install: "Not found on your terminal's PATH"
        default: health.executable.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not read"
        }
    }

    static func versionText(_ health: HarnessHealth) -> String {
        guard let version = health.version else { return health.state == .install ? "—" : "Not read" }
        let text = HarnessVersionTable.text(version)
        let table = HarnessVersionTable.table(for: health.provider)
        let recommended = table.map { HarnessVersionTable.text($0.recommended) } ?? ""
        switch health.versionStatus {
        case .current: return "\(text) · up to date"
        case .belowRecommended: return "\(text) · update recommended (\(recommended))"
        case .belowMinimum:
            let minimum = table?.minimum.map { " (at least \(HarnessVersionTable.text($0)))" } ?? ""
            return "\(text) · update needed\(minimum)"
        case .unknown: return text
        }
    }

    static func accountText(_ health: HarnessHealth) -> String {
        switch health.account {
        case let .subscription(email, plan)?:
            let plan = plan.map { HarnessHealth.planName($0) }
            switch (email, plan) {
            case let (email?, plan?): return "\(email) · \(plan)"
            case let (email?, nil): return email
            case let (nil, plan?): return "\(plan) plan"
            case (nil, nil): return "Signed in"
            }
        case .apiKey?: return "API key"
        case HarnessAccount.none?: return "Nobody is signed in"
        case nil:
            switch health.state {
            case .signIn: return "Nobody is signed in"
            case .ready: return "Not named by the CLI"
            default: return "—"
            }
        }
    }

    static func limitsText(_ health: HarnessHealth) -> String {
        switch health.limitsReadable {
        case true?: return "Readable"
        case false?: return health.account == .apiKey ? "Not for an API key" : "Not readable"
        case nil: return "Not checked yet"
        }
    }

    static func checkedText(_ health: HarnessHealth, now: Date) -> String {
        guard let at = health.checkedAt else { return "Not checked yet" }
        guard now.timeIntervalSince(at) >= 60 else { return "Checked just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked " + formatter.localizedString(for: at, relativeTo: now)
    }
}

extension SettingsBand {
    /// The width of the section tabs of `titles`, as `ViewTabs` lays them out: each label in the tab type, the gap between
    /// two. Computed from the tokens, so a test can say whether seven tabs fit the band.
    static func tabsWidth(of titles: [String]) -> CGFloat {
        let style = LoomTheme.ViewTabs.label
        let weight: NSFont.Weight = style.weight == .medium ? .medium : (style.weight == .semibold ? .semibold : .regular)
        let font = NSFont.systemFont(ofSize: style.size, weight: weight)
        let labels = titles.reduce(CGFloat(0)) { $0 + ($1 as NSString).size(withAttributes: [.font: font]).width }
        return labels + CGFloat(max(0, titles.count - 1)) * LoomTheme.ViewTabs.gap
    }

    /// The room the tabs have in the band: the window's width less the close button's side, taken from both sides because the
    /// tabs are centred.
    static var tabsRoom: CGFloat { LoomTheme.Settings.width - 2 * LoomTheme.Connect.tabsReserve }
}

// The catalogue's row and the current PATH result, combined with the health read for the two supported providers.
extension ConnectionsContent {
    struct HarnessRow: Equatable, Identifiable {
        let descriptor: HarnessDescriptor
        let availability: HarnessAvailabilityState?
        let executable: String?
        let switchPreference: Bool
        let health: HarnessHealth?
        let buildSupportsSessions: Bool
        let canStart: Bool

        var id: HarnessID { descriptor.id }
        var name: String { descriptor.displayName }
        var isOn: Bool { availability == .on }
        var canSwitch: Bool { availability == .on || availability == .off }
        var version: String { availability == .notFound ? "—" : (health?.version.map(HarnessVersionTable.text) ?? "—") }
        var startNote: String? { buildSupportsSessions ? nil : "\(name) comes in a later version" }
        var showsAccountChanged: Bool { isOn && health?.accountChanged == true }

        var state: HarnessHealthState {
            switch availability {
            case .notFound: return .install
            case .off: return .disabled
            case .on:
                guard descriptor.provider != nil else { return .disabled }
                guard let health, health.state != .install && health.state != .disabled else { return .checking }
                return health.state
            case nil: return .checking
            }
        }

        var headline: String {
            switch availability {
            case .notFound: "Not found on this Mac"
            case .off: "Off"
            case .on where descriptor.provider == nil: "Found"
            case .on where state == .checking: "Checking…"
            case .on: health?.headline ?? "Checking…"
            case nil: "Checking…"
            }
        }

        var accessibilityLabel: String {
            var parts = [name, headline]
            if showsAccountChanged { parts.append("Account changed") }
            if let startNote { parts.append(startNote) }
            return parts.joined(separator: ", ")
        }

        var missingExplanation: String {
            "Not found on this Mac. Sphyrna looks for `\(descriptor.command)` on your shell's PATH."
        }
    }

    static func harnessRow(descriptor: HarnessDescriptor, availability: HarnessAvailability?, switchedOn: Bool,
                           health: HarnessHealth?, buildSupportsSessions: Bool, canStart: Bool) -> HarnessRow {
        // The PATH reader is authoritative once it has answered. Before then, a completed provider health check
        // can supply the same fact; the remaining rows stay Checking and cannot be switched yet.
        let found: Bool?
        let executable: String?
        if let availability {
            found = availability.isFound
            executable = availability.executable
        } else if health?.state == .install {
            found = false
            executable = nil
        } else if let path = health?.executable {
            found = true
            executable = path
        } else {
            found = nil
            executable = nil
        }
        let state: HarnessAvailabilityState? = found.map { $0 ? (switchedOn ? .on : .off) : .notFound }
        return HarnessRow(descriptor: descriptor, availability: state, executable: executable,
                          switchPreference: switchedOn, health: health, buildSupportsSessions: buildSupportsSessions, canStart: canStart)
    }
}
