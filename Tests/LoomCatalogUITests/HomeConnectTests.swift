import AppKit
import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

@MainActor
struct HomeConnectTests {
    typealias Rig = ConnectionsTests.Rig

    private func catalogModel(startable: Set<ManagedSession.Provider> = [.claude, .codex]) throws -> (CatalogModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-connections-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (CatalogModel(catalog: nil, events: SessionEventHub(),
                             preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")),
                             startableProviders: startable), root)
    }

    private func row(_ provider: ManagedSession.Provider, _ state: HarnessHealthState, _ headline: String,
                     supported: Bool = true, versionStatus: HarnessVersionStatus = .unknown) -> ConnectionsContent.HarnessRow {
        let descriptor = HarnessCatalogue.descriptor(for: HarnessID(provider))!
        var health = HarnessHealth(provider: provider, state: state, headline: headline)
        health.versionStatus = versionStatus
        let availability: HarnessAvailability?
        switch state {
        case .install: availability = HarnessAvailability(id: descriptor.id, state: .notFound)
        case .disabled: availability = HarnessAvailability(id: descriptor.id, state: .off, executable: "/fake/\(descriptor.command)")
        case .checking: availability = nil
        default: availability = HarnessAvailability(id: descriptor.id, state: .on, executable: "/fake/\(descriptor.command)")
        }
        return ConnectionsContent.harnessRow(descriptor: descriptor, availability: availability,
                                             switchedOn: state != .disabled, health: health,
                                             buildSupportsSessions: supported, canStart: supported && state != .disabled && state != .install)
    }

    @Test func onboardingIncludesOffAndReadyHarnessesWithOneRelevantAction() {
        let plan = HomeConnect.plan(rows: [row(.claude, .disabled, "Turned off"), row(.codex, .install, "Not found")])
        #expect(plan.showsCards && plan.cards.map(\.name) == ["Claude", "Codex"])
        #expect(plan.cards.map(\.action?.title) == ["Turn On", "Copy Install Command"])
        #expect(plan.showsNotice && plan.attention.map(\.name) == ["Codex"])
        let ready = HomeConnect.plan(rows: [row(.claude, .ready, "Ready"), row(.codex, .ready, "Ready")])
        #expect(!ready.showsCards && !ready.showsNotice)
        let off = HomeConnect.plan(rows: [row(.claude, .disabled, "Turned off"), row(.codex, .ready, "Ready")])
        #expect(off.showsCards && !off.showsNotice, "an off switch is offered on first run without nagging over sessions")
    }

    @Test func aBuildFrozenHarnessNeverForcesSetup() {
        let codex = row(.codex, .install, "Not found", supported: false)
        let production = HomeConnect.plan(rows: [row(.claude, .ready, "Ready"), codex])
        #expect(!production.showsCards && !production.showsNotice)
        let both = HomeConnect.plan(rows: [row(.claude, .signIn, "Not signed in"), codex])
        #expect(both.cards.count == 2 && both.attention.map(\.name) == ["Claude"])
        #expect(both.cards[0].action?.title == "Copy Sign-In Command")
        #expect(both.cards[1].action == nil && both.cards[1].row.startNote == CatalogModel.codexLaterReason)
    }

    @Test func aClaudeThatCouldNotBeCheckedRaisesNoSetupCard() async throws {
        let (model, root) = try catalogModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = Rig(claude: nil, codex: ConnectionsTests.max, codexFound: true)
        model.installHarnessHealth(rig.model)
        rig.model.checkAll()
        await rig.model.settle()
        #expect(rig.model.health(of: .claude).state == .attention)
        #expect(!model.homeConnect.showsNotice && !model.homeConnect.showsCards)
        let old = row(.claude, .attention, "Update needed", versionStatus: .belowMinimum)
        #expect(HomeConnect.plan(rows: [old]).showsNotice)
    }

    @Test func withSessionsOneCompactNoticeShowsWhileASupportedHarnessNeedsSetup() async throws {
        let (model, root) = try catalogModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!model.homeConnect.showsNotice && !model.homeClaudeCLIMissing)
        let rig = Rig(claude: nil, claudeFound: false, codex: ConnectionsTests.max, codexFound: true)
        model.installHarnessHealth(rig.model)
        rig.model.checkAll()
        await rig.model.settle()
        #expect(model.homeClaudeCLIMissing)
        let notice = model.homeConnect
        #expect(notice.showsNotice && notice.attention.map(\.name) == ["Claude"])
        #expect(HomeConnect.noticeText(notice.attention) == "Claude · Not found on this Mac. Sessions already listed stay readable.")
        let asks = rig.codex.asks
        model.recheckHarnesses()
        #expect(await inspectorWaitUntil { !model.harnessRecheckInProgress })
        await rig.model.settle()
        #expect(rig.codex.asks == asks + 1 && rig.claude.asks == 0)
    }

    @Test func theFirstRunWordsAreCalmAndSayWhatToDo() {
        let copies: [HomeEmptyCopy] = [.noProjects, .connect]
        for copy in copies {
            let words = copy.title + " " + copy.text
            #expect(!words.contains("!") && !words.lowercased().contains("oops"))
            #expect(!words.contains("onversation") && !words.contains("Loom"))
            #expect(copy.title.first?.isUppercase == true && !copy.title.hasSuffix("."))
            #expect(copy.text.hasSuffix("."))
        }
        #expect(HomeEmptyCopy.connect.title == "Connect your agents")
        #expect(HomeEmptyCopy.noProjects.text.contains("Add the folder"))
        #expect(HomeEmptyCatalog.showsMark(connectCards: false) && !HomeEmptyCatalog.showsMark(connectCards: true))
    }
}
