import LoomCore
import SwiftUI

/// Home's "Connect your agents" (D-98, FB5-8): over an empty catalog, one card per connected harness giving its state (Install,
/// Sign In or Ready) in the first run's place; over a catalog with sessions, one compact card under the band while a connected
/// harness needs attention. Both replace the old "no Claude" notice, and both read the harness health, never the plan limits.
enum HomeConnect {
    /// One harness's card.
    struct Card: Identifiable, Equatable {
        let health: HarnessHealth
        let name: String
        /// The state in a word: "Install", "Sign In", "Ready", "Attention", "Checking…".
        let word: String
        /// How to install or sign in, while the state asks for it.
        let command: HarnessSetupCommand?
        /// Why this build cannot start the harness's sessions ("Sessions arrive in a later version"), where it cannot.
        let startNote: String?

        var id: ManagedSession.Provider { health.provider }
    }

    struct Plan: Equatable {
        /// The first run's cards: every connected harness, and only while one of them needs setting up.
        var cards: [Card] = []
        /// The connected harnesses the build can start that need attention (not found, not signed in, too old).
        var attention: [Card] = []

        var showsCards: Bool { !cards.isEmpty }
        var showsNotice: Bool { !attention.isEmpty }
    }

    static let title = "Connect your agents"
    static let firstRunText = "Sphyrna works with the agents already on your Mac. Set up the ones you use, then add the folder you work in."
    static let noticeSuffix = "Sessions already listed stay readable."

    /// What to show for `healths` (the connected harnesses' states). A harness the build cannot start (Codex, in a production
    /// build) never makes the first run or the notice appear on its own: it only stands among the cards when another needs them.
    @MainActor static func plan(healths: [HarnessHealth], startable: Set<ManagedSession.Provider>) -> Plan {
        let connected = healths.filter { $0.state != .disabled }
        let cards = connected.map { card(for: $0, startable: startable) }
        let attention = cards.filter { needsSetup($0.health) && startable.contains($0.health.provider) }
        return Plan(cards: attention.isEmpty ? [] : cards, attention: attention)
    }

    /// Not found, not signed in, or too old. A check that could not tell (also `.attention`) is not setup: it waits on Check
    /// Again in Connections and says nothing here, so a signed-in user is never sent to sign in.
    static func needsSetup(_ health: HarnessHealth) -> Bool {
        switch health.state {
        case .install, .signIn: true
        case .attention: health.versionStatus == .belowMinimum
        default: false
        }
    }

    @MainActor static func card(for health: HarnessHealth, startable: Set<ManagedSession.Provider>) -> Card {
        let word: String
        switch health.state {
        case .install: word = "Install"
        case .signIn: word = "Sign In"
        case .ready: word = "Ready"
        case .attention: word = "Attention"
        case .checking: word = "Checking…"
        case .disabled: word = "Off"
        }
        return Card(health: health, name: ProviderName.title(health.provider), word: word,
                    command: HarnessSetupCommand.command(for: health.provider, state: health.state),
                    startNote: CatalogModel.newSessionUnavailableReason(health.provider, startable: startable))
    }

    /// The compact card's line: "Claude · Not signed in", one per harness, then what stays true.
    static func noticeText(_ attention: [Card]) -> String {
        attention.map { "\($0.name) · \($0.health.headline)" }.joined(separator: ", ") + ". " + noticeSuffix
    }
}

/// The first run's cards, one under the other.
struct HomeConnectCards: View {
    let model: CatalogModel

    var body: some View {
        VStack(spacing: LoomTheme.Home.connectGap) {
            ForEach(model.homeConnect.cards) { HomeConnectCardView(model: model, card: $0) }
        }
        .frame(maxWidth: LoomTheme.Home.connectWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-connect-cards")
    }
}

private struct HomeConnectCardView: View {
    let model: CatalogModel
    let card: HomeConnect.Card

    var body: some View {
        HomeCard(identifier: "home-connect-\(card.health.provider.rawValue)") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: LoomTheme.Home.connectRowGap) {
                    ProviderIcon(provider: card.health.provider, size: LoomTheme.Layout.harnessMarkHeader)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(card.name).homeType(LoomTheme.Home.connectName).foregroundStyle(LoomTheme.Text.primary)
                        Text(card.health.headline).homeType(LoomTheme.Home.connectHeadline)
                            .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    }
                    Spacer(minLength: LoomTheme.Home.connectRowGap)
                    Circle().fill(LoomTheme.Connect.dotColor(card.health.state))
                        .frame(width: LoomTheme.Connect.dot, height: LoomTheme.Connect.dot).accessibilityHidden(true)
                    Text(card.word).homeType(LoomTheme.Home.connectWord).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(card.name), \(card.word), \(card.health.headline)")
                if let note = card.startNote {
                    Text(note).homeType(LoomTheme.Home.codexNote).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        .padding(.top, LoomTheme.Home.codexNoteGap)
                        .accessibilityIdentifier("home-connect-note-\(card.health.provider.rawValue)")
                }
                if let command = card.command, let health = model.harnessHealth {
                    HarnessSetupBlock(health: health, provider: card.health.provider, command: command, note: card.health.note)
                        .padding(.top, LoomTheme.Home.connectSetupTop)
                }
            }
            .padding(LoomTheme.Home.connectPadding)
        }
    }
}

/// Above a catalog that has sessions: one compact card under the band while a connected harness needs attention. Plan limits is
/// left out, and so is the sidebar's New session row.
struct HomeConnectNotice: View {
    let model: CatalogModel

    var body: some View {
        let attention = model.homeConnect.attention
        HomeCard(identifier: "home-connect-notice") {
            HStack(alignment: .center, spacing: LoomTheme.Home.noticeGap) {
                HStack(alignment: .top, spacing: LoomTheme.Home.noticeGap) {
                    Image(systemName: "exclamationmark.triangle").homeType(LoomTheme.Home.noticeSymbol)
                        .foregroundStyle(LoomTheme.Status.attention)
                        .frame(width: LoomTheme.Home.noticeColumn, alignment: .leading).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LoomTheme.Home.noticeTextGap) {
                        Text(HomeConnect.title).homeType(LoomTheme.Home.noticeTitle).foregroundStyle(LoomTheme.Text.primary)
                        Text(HomeConnect.noticeText(attention)).homeType(LoomTheme.Home.noticeText)
                            .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: LoomTheme.Home.noticeGap)
                Button("Set Up…") { model.showConnections() }
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                    .accessibilityLabel("Set up your agents in Settings")
                    .accessibilityIdentifier("home-connect-set-up")
                HomeCheckAgainButton(model: model, size: .small)
            }
            .padding(.vertical, LoomTheme.Home.noticePaddingV).padding(.horizontal, LoomTheme.Home.noticePaddingH)
        }
    }
}

extension CatalogModel {
    /// What Home's "Connect your agents" shows now.
    var homeConnect: HomeConnect.Plan {
        HomeConnect.plan(healths: harnessHealth?.healths ?? [], startable: startableProviders)
    }
}
