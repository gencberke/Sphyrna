import Foundation
import LoomCore
import Testing
@testable import LoomCatalogUI

/// The connect switch's preference and the composer's model lists as they come from `ModelCatalog` (D-98, D-99).
@MainActor
struct HarnessCatalogTests {
    private func picker(codexNote: String = ComposerModelNotes.inNewSession) -> ComposerModelPicker {
        ComposerModelPicker(
            modelTitle: "Sonnet", effortTitle: nil, rows: ModelCatalog.claude.map { ComposerBarText.ModelRow(value: $0.id, title: $0.title) },
            chosenModel: nil, levels: NewSessionModels.effortLevels, chosenLevel: nil, canResetEffort: false, codexNote: codexNote)
    }

    // MARK: The preference

    @Test func theSwitchIsStoredPerHarnessAndReadsOnInAnOlderFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-harness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let store = UIPreferencesStore(url: url)
        #expect(store.current.isHarnessConnected(.claude) && store.current.isHarnessConnected(.codex), "on by default")
        try store.update { $0.setHarnessConnected(.codex, false) }

        let reread = UIPreferencesStore(url: url).current
        #expect(!reread.isHarnessConnected(.codex) && reread.isHarnessConnected(.claude))
        #expect(reread.disconnectedHarnesses == [.codex])
        let connections = HarnessConnections(disconnected: reread.disconnectedHarnesses)
        #expect(!connections.isConnected(.codex) && connections.isConnected(.claude))

        try store.update { $0.setHarnessConnected(.codex, true) }
        #expect(UIPreferencesStore(url: url).current == UIPreferences(), "on again is the default, so the file says nothing")
    }

    @Test func anOlderOrDamagedFileReadsEveryHarnessAsOn() throws {
        for json in ["{}", #"{"viewMode":"projects"}"#, #"{"harnessConnections":{"codex":"no"}}"#, #"{"harnessConnections":[1]}"#] {
            let old = try JSONDecoder().decode(UIPreferences.self, from: Data(json.utf8))
            #expect(old.isHarnessConnected(.claude) && old.isHarnessConnected(.codex), "\(json)")
            #expect(old.disconnectedHarnesses.isEmpty)
        }
        let named = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"harnessConnections":{"codex":false,"unknown":false}}"#.utf8))
        #expect(!named.isHarnessConnected(.codex))
        #expect(named.disconnectedHarnesses == [.codex], "a harness this build does not know is ignored")
    }

    // MARK: The lists

    @Test func claudeIsTheCatalogsList() {
        #expect(ModelCatalog.claudeTitle(of: "sonnet") == "Sonnet" && ModelCatalog.claudeTitle(of: "fable") == "fable")
        #expect(HeaderModelContent.launchTitle("haiku") == "Haiku")
        let claude = picker().groups()[0]
        #expect(claude.rows.map(\.id) == ["default"] + ModelCatalog.claude.map(\.id))
    }

    @Test func codexRowsComeFromTheGivenListAndTheGroupIsLeftOutWhenThereIsNone() {
        let probed = [ModelCatalogEntry(id: "fake-alpha", title: "Fake Alpha", note: "Default"),
                      ModelCatalogEntry(id: "fake-beta", title: "Fake Beta")]
        let codex = picker().groups(codex: probed)[1]
        #expect(codex.rows.map(\.title) == ["Fake Alpha", "Fake Beta"])
        #expect(codex.rows.map(\.subtitle) == ["Default", nil])
        #expect(codex.rows.allSatisfy { !$0.isEnabled && !$0.checked && $0.id.hasPrefix("codex:") })
        #expect(picker().groups().count == 2, "without a list: today's names")
        #expect(picker().groups()[1].rows.map(\.title) == ModelCatalog.codexFallback.map(\.title))
        #expect(picker().groups(codex: []).map(\.provider) == [.claude], "switched off: Claude's group only")
    }
}
