import AppKit
import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// Home's "Connect your agents" (D-98): the cards for a fresh catalog, the compact card over sessions, and no card when every
/// connected harness is ready. Plain values and the model's reads; no view is drawn (HomeRenderTests hosts the views).
@MainActor
struct HomeConnectTests {
    typealias Rig = ConnectionsTests.Rig

    private func catalogModel(startable: Set<ManagedSession.Provider> = [.claude, .codex]) throws -> (CatalogModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-connections-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")), startableProviders: startable)
        return (model, root)
    }

    private func health(_ provider: ManagedSession.Provider, _ state: HarnessHealthState, _ headline: String) -> HarnessHealth {
        HarnessHealth(provider: provider, state: state, headline: headline)
    }

    @Test func aFreshCatalogShowsOneCardPerConnectedHarnessWhileOneNeedsSetup() {
        let plan = HomeConnect.plan(
            healths: [health(.claude, .install, "Not found"), health(.codex, .signIn, "Not signed in")], startable: [.claude, .codex])
        #expect(plan.showsCards && plan.cards.map(\.word) == ["Install", "Sign In"])
        #expect(plan.cards.map(\.command?.command) == ["brew install --cask claude-code", "codex login"])
        #expect(plan.cards.map(\.name) == ["Claude", "Codex"])

        let mixed = HomeConnect.plan(
            healths: [health(.claude, .ready, "Ready · Claude Max"), health(.codex, .install, "Not found")], startable: [.claude, .codex])
        #expect(mixed.cards.map(\.word) == ["Ready", "Install"], "a Ready card stands beside the one that needs setup")
        #expect(mixed.cards[0].command == nil)

        let off = HomeConnect.plan(
            healths: [health(.claude, .disabled, "Turned off"), health(.codex, .install, "Not found")], startable: [.claude, .codex])
        #expect(off.cards.map(\.name) == ["Codex"], "a harness that is off has no card")
        let allOff = HomeConnect.plan(healths: [health(.claude, .disabled, "Turned off"), health(.codex, .disabled, "Turned off")],
                                      startable: [.claude, .codex])
        #expect(!allOff.showsCards && !allOff.showsNotice)
    }

    @Test func noCardWhenEveryConnectedHarnessIsReadyOrOnlyACodexThatCannotStartIsMissing() {
        let ready = HomeConnect.plan(
            healths: [health(.claude, .ready, "Ready · Claude Max"), health(.codex, .ready, "Ready")], startable: [.claude, .codex])
        #expect(!ready.showsCards && !ready.showsNotice)
        let checking = HomeConnect.plan(
            healths: [health(.claude, .checking, "Checking…"), health(.codex, .checking, "Checking…")], startable: [.claude, .codex])
        #expect(!checking.showsCards && !checking.showsNotice, "nothing is said before a check has answered")
        // A production build cannot start Codex: its absence alone is not Home's business.
        let production = HomeConnect.plan(
            healths: [health(.claude, .ready, "Ready"), health(.codex, .install, "Not found")], startable: [.claude])
        #expect(!production.showsCards && !production.showsNotice)
        // Claude needs setup there: both cards show, and Codex's says why it cannot start.
        let both = HomeConnect.plan(
            healths: [health(.claude, .signIn, "Not signed in"), health(.codex, .install, "Not found")], startable: [.claude])
        #expect(both.cards.count == 2 && both.attention.map(\.name) == ["Claude"])
        #expect(both.cards[0].startNote == nil && both.cards[1].startNote == CatalogModel.codexLaterReason)
    }

    @Test func aClaudeThatCouldNotBeCheckedRaisesNoSetupCard() async throws {
        let (model, root) = try catalogModel()
        defer { try? FileManager.default.removeItem(at: root) }
        // A failed first check: the probe answered nothing, and nobody is said to be signed out.
        let rig = Rig(claude: nil, codex: ConnectionsTests.max, codexFound: true)
        model.installHarnessHealth(rig.model)
        rig.model.checkAll()
        await rig.model.settle()
        let claude = rig.model.health(of: .claude)
        #expect(claude.state == .attention && claude.headline == "Could not check")
        #expect(!model.homeConnect.showsNotice && !model.homeConnect.showsCards, "no card asks a signed-in user to run claude auth login")

        let plan = HomeConnect.plan(
            healths: [health(.claude, .attention, "Could not check"), health(.codex, .ready, "Ready")], startable: [.claude, .codex])
        #expect(!plan.showsCards && !plan.showsNotice)
        // A CLI below the minimum still asks for an update.
        var old = health(.claude, .attention, "Update needed")
        old.versionStatus = .belowMinimum
        #expect(HomeConnect.plan(healths: [old], startable: [.claude]).showsNotice)
    }

    @Test func withSessionsOneCompactCardShowsWhileAConnectedHarnessNeedsAttention() async throws {
        let (model, root) = try catalogModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!model.homeConnect.showsNotice && !model.homeClaudeCLIMissing, "no health model: nothing to say")

        let rig = Rig(claude: nil, claudeFound: false, codex: ConnectionsTests.max, codexFound: true)
        model.installHarnessHealth(rig.model)
        rig.model.checkAll()
        await rig.model.settle()
        #expect(model.homeClaudeCLIMissing, "Claude is not found")
        let notice = model.homeConnect
        #expect(notice.showsNotice && notice.attention.map(\.name) == ["Claude"])
        #expect(HomeConnect.noticeText(notice.attention) == "Claude · Not found. Sessions already listed stay readable.")

        // "Check Again" asks the health of every connected harness, past the floor; it does not ask the plan limits.
        let asks = rig.codex.asks
        model.recheckHarnesses()
        await rig.model.settle()
        #expect(rig.codex.asks == asks + 1)
        #expect(rig.claude.asks == 0, "a CLI that is not found is not asked")

        // Everything ready: no card.
        let ready = Rig(codex: ConnectionsTests.max, codexFound: true)
        model.installHarnessHealth(ready.model)
        ready.model.checkAll()
        await ready.model.settle()
        #expect(!model.homeConnect.showsNotice && !model.homeConnect.showsCards && !model.homeClaudeCLIMissing)
    }

    @Test func theFirstRunWordsAreCalmAndSayWhatToDo() {
        let copies: [HomeEmptyCopy] = [.noProjects, .connect]
        for copy in copies {
            let words = copy.title + " " + copy.text
            #expect(!words.contains("!") && !words.lowercased().contains("oops"), "no exclamation marks, no Oops")
            #expect(!words.contains("onversation") && !words.contains("Loom"), "session and Sphyrna")
            #expect(copy.title.first?.isUppercase == true && !copy.title.hasSuffix("."))
            #expect(copy.text.hasSuffix("."))
        }
        #expect(HomeEmptyCopy.connect.title == "Connect your agents")
        #expect(HomeEmptyCopy.noProjects.text.contains("Add the folder"))
        #expect(HomeEmptyCatalog.showsMark(connectCards: false) && !HomeEmptyCatalog.showsMark(connectCards: true))
    }
}
