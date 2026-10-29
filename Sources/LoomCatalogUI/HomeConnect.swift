import LoomCore
import SwiftUI

/// The first-run cards and the notice over a catalog with sessions share Connections' PATH and switch states.
enum HomeConnect {
    enum Action: Equatable {
        case copyInstall(HarnessSetupCommand)
        case copySignIn(HarnessSetupCommand)
        case turnOn

        var title: String {
            switch self {
            case .copyInstall: "Copy Install Command"
            case .copySignIn: "Copy Sign-In Command"
            case .turnOn: "Turn On"
            }
        }
    }

    struct Card: Identifiable, Equatable {
        let row: ConnectionsContent.HarnessRow
        let action: Action?
        var id: HarnessID { row.id }
        var name: String { row.name }
        var word: String {
            switch row.availability {
            case .notFound: "Not found"
            case .off: "Off"
            case .on where row.descriptor.provider == nil: "Found"
            case .on:
                switch row.state {
                case .install: "Not found"
                case .signIn: "Sign In"
                case .ready: "Ready"
                case .attention: "Attention"
                case .checking: "Checking…"
                case .disabled: "Off"
                }
            case nil: "Checking…"
            }
        }
    }

    struct Plan: Equatable {
        var cards: [Card] = []
        var attention: [Card] = []
        var showsCards: Bool { !cards.isEmpty }
        var showsNotice: Bool { !attention.isEmpty }
    }

    static let title = "Connect your agents"
    static let firstRunText = "Sphyrna works with the agents already on your Mac. Set up the ones you use, then add the folder you work in."
    static let noticeSuffix = "Sessions already listed stay readable."

    /// Claude and Codex always appear on onboarding; the other harnesses only when found. An unsupported build never asks
    /// for its setup, and a deliberate off choice does not raise the notice over an existing catalog.
    static func plan(rows: [ConnectionsContent.HarnessRow]) -> Plan {
        let visible = rows.filter { $0.descriptor.showsOnboardingWhenMissing || $0.canSwitch }
        let cards = visible.map(card(for:))
        let attention = cards.filter { needsSetup($0.row) }
        let offNeedsOnboarding = cards.contains { $0.row.buildSupportsSessions && $0.row.availability == .off }
        return Plan(cards: attention.isEmpty && !offNeedsOnboarding ? [] : cards, attention: attention)
    }

    static func needsSetup(_ row: ConnectionsContent.HarnessRow) -> Bool {
        guard row.buildSupportsSessions, row.switchPreference else { return false }
        switch row.availability {
        case .notFound: return true
        case .on:
            return row.state == .signIn || (row.state == .attention && row.health?.versionStatus == .belowMinimum)
        default: return false
        }
    }

    static func card(for row: ConnectionsContent.HarnessRow) -> Card {
        let action: Action?
        if row.availability == .off {
            action = .turnOn
        } else if row.availability == .notFound, row.buildSupportsSessions, let command = row.descriptor.install {
            action = .copyInstall(command)
        } else if row.canStart, row.state == .signIn, let command = row.descriptor.signIn {
            action = .copySignIn(command)
        } else {
            action = nil
        }
        return Card(row: row, action: action)
    }

    static func noticeText(_ attention: [Card]) -> String {
        attention.map { "\($0.name) · \($0.row.headline)" }.joined(separator: ", ") + ". " + noticeSuffix
    }
}

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
        HomeCard(identifier: "home-connect-\(card.id.rawValue)") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: LoomTheme.Home.connectRowGap) {
                    ProviderIcon(harness: card.id, size: LoomTheme.Layout.harnessMarkHeader)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(card.name).homeType(LoomTheme.Home.connectName).foregroundStyle(LoomTheme.Text.primary)
                        Text(card.row.headline).homeType(LoomTheme.Home.connectHeadline)
                            .foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                    }
                    Spacer(minLength: LoomTheme.Home.connectRowGap)
                    Circle().fill(LoomTheme.Connect.dotColor(card.row.state))
                        .frame(width: LoomTheme.Connect.dot, height: LoomTheme.Connect.dot).accessibilityHidden(true)
                    Text(card.word).homeType(LoomTheme.Home.connectWord).foregroundStyle(LoomTheme.Text.secondaryOnCardStyle)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(card.name), \(card.word), \(card.row.headline)")
                if let note = card.row.startNote {
                    Text(note).homeType(LoomTheme.Home.codexNote).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        .padding(.top, LoomTheme.Home.codexNoteGap)
                        .accessibilityIdentifier("home-connect-note-\(card.id.rawValue)")
                }
                if let action = card.action {
                    Button(action.title) { perform(action) }
                        .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                        .padding(.top, LoomTheme.Home.connectSetupTop)
                        .accessibilityIdentifier("home-connect-action-\(card.id.rawValue)")
                }
            }
            .padding(LoomTheme.Home.connectPadding)
        }
    }

    private func perform(_ action: HomeConnect.Action) {
        switch action {
        case .turnOn: model.setHarnessConnected(card.id, true)
        case let .copyInstall(command), let .copySignIn(command):
            model.harnessHealth?.copy(command, forHarness: card.id)
        }
    }
}

/// Above a catalog that has sessions: a compact notice while a supported, switched-on harness needs setup.
struct HomeConnectNotice: View {
    let model: CatalogModel

    var body: some View {
        let attention = model.homeConnect.attention
        HomeCard(identifier: "home-connect-notice") {
            HStack(alignment: .center, spacing: LoomTheme.Home.noticeGap) {
                HStack(alignment: .top, spacing: LoomTheme.Home.noticeGap) {
                    InkIcon(.warning)
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
    var homeConnect: HomeConnect.Plan { HomeConnect.plan(rows: connectionRows) }
}
