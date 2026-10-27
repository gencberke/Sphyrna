import Foundation
@testable import LoomChat
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
        #expect(store.current.isHarnessConnected(HarnessID.claude) && store.current.isHarnessConnected(HarnessID.codex),
                "on by default")
        #expect(!store.current.isHarnessConnected(HarnessID.opencode), "off until switched on")
        try store.update { $0.setHarnessConnected(HarnessID.codex, false) }

        let reread = UIPreferencesStore(url: url).current
        #expect(!reread.isHarnessConnected(HarnessID.codex) && reread.isHarnessConnected(HarnessID.claude))
        #expect(reread.disconnectedHarnesses == [.codex])
        #expect(reread.harnessChoices == [.codex: false])
        let connections = HarnessConnections(choices: reread.harnessChoices)
        #expect(!connections.isOn(.codex) && connections.isOn(.claude))

        try store.update { $0.setHarnessConnected(HarnessID.codex, true) }
        #expect(UIPreferencesStore(url: url).current == UIPreferences(), "on again is the default, so the file says nothing")
    }

    @Test func aNewHarnessKeepsItsExplicitChoiceAndAnOlderBuildStillReadsTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-harness-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        let store = UIPreferencesStore(url: url)
        try store.update { $0.setHarnessConnected(HarnessID.opencode, true) }
        #expect(store.current.harnessConnections == ["opencode": true], "an explicit on is written for a harness off by default")

        // 1.7.2 reads the key as a [String: Bool] and ignores a harness it does not know; the type is unchanged.
        struct OlderPreferences: Decodable { let harnessConnections: [String: Bool]? }
        let written = try JSONDecoder().decode(OlderPreferences.self, from: Data(contentsOf: url))
        #expect(written.harnessConnections == ["opencode": true])

        let reread = UIPreferencesStore(url: url).current
        #expect(reread.isHarnessConnected(HarnessID.opencode))
        #expect(reread.harnessChoices == [.opencode: true])
        #expect(reread.disconnectedHarnesses.isEmpty, "1.7.2 reads the same [String: Bool] and ignores a harness it does not know")

        try store.update { $0.setHarnessConnected(HarnessID.opencode, false) }
        #expect(UIPreferencesStore(url: url).current == UIPreferences(), "off is its default, so the file says nothing")
    }

    @Test func anOlderOrDamagedFileReadsClaudeAndCodexOnAndTheNewHarnessesOff() throws {
        for json in ["{}", #"{"viewMode":"projects"}"#, #"{"harnessConnections":{"codex":"no"}}"#, #"{"harnessConnections":[1]}"#] {
            let old = try JSONDecoder().decode(UIPreferences.self, from: Data(json.utf8))
            #expect(old.isHarnessConnected(HarnessID.claude) && old.isHarnessConnected(HarnessID.codex), "\(json)")
            #expect(!old.isHarnessConnected(HarnessID.opencode) && !old.isHarnessConnected(HarnessID.agy)
                    && !old.isHarnessConnected(HarnessID.pi), "\(json)")
            #expect(old.disconnectedHarnesses.isEmpty)
        }
        let named = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"harnessConnections":{"codex":false,"unknown":false}}"#.utf8))
        #expect(!named.isHarnessConnected(HarnessID.codex))
        #expect(named.disconnectedHarnesses == [.codex], "a harness this build does not know is ignored")
        #expect(named.harnessChoices == [.codex: false])
    }

    // MARK: The lists

    @Test func claudeIsTheCatalogsList() {
        #expect(ModelCatalog.claudeTitle(of: "sonnet") == "Sonnet" && ModelCatalog.claudeTitle(of: "fable") == "fable")
        #expect(HeaderModelContent.launchTitle("haiku", catalog: ModelCatalog()) == "Haiku")
        let claude = picker().groups()[0]
        #expect(claude.rows.map(\.id) == ["default"] + ModelCatalog.claude.map(\.id))
    }

    /// Full model names (D-100 round): a Claude alias is named by the release the probe said it resolves to; an id not shaped
    /// like a release falls back to the CLI's display name.
    @Test func claudeAliasesTakeTheFullNamesOfTheirReleases() {
        let catalog = ModelCatalog()
        #expect(catalog.claudeTitle(of: "opus") == "Opus", "before a probe answered: the fixed short title")
        catalog.apply(HarnessReading(provider: .claude, models: [
            HarnessModel(id: "default", displayName: "Default", isDefault: true, efforts: [], resolvedModel: "claude-opus-5-5"),
            HarnessModel(id: "opus", displayName: "Opus", isDefault: false, efforts: [], resolvedModel: "claude-opus-5-5"),
            HarnessModel(id: "sonnet", displayName: "Sonnet", isDefault: false, efforts: [], resolvedModel: "claude-sonnet-5-5"),
            HarnessModel(id: "haiku", displayName: "Haiku", isDefault: false, efforts: [], resolvedModel: "claude-haiku-5-5-20260901"),
            HarnessModel(id: "fable", displayName: "Fable", isDefault: false, efforts: [], resolvedModel: "claude-fable-5-1"),
            HarnessModel(id: "mystery", displayName: "Mystery Model", isDefault: false, efforts: [], resolvedModel: "m-7"),
            HarnessModel(id: "opus[1m]", displayName: "Opus 1M", isDefault: false, efforts: [], resolvedModel: "claude-opus-5-5[1m]"),
        ], readAt: Date()))
        #expect(catalog.claudeModels.map(\.id) == ["opus", "sonnet", "haiku", "fable", "mystery"])
        #expect(catalog.claudeModels.map(\.title) == ["Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Fable 5.1", "Mystery Model"])
        #expect(catalog.claudeTitle(of: "sonnet") == "Sonnet 5.5" && catalog.claudeTitle(of: "unknown") == "unknown")
        #expect(ModelCatalog.claudeFullName(resolvedModel: "claude-3-5-sonnet-20241022", displayName: nil) == "Sonnet 3.5")
        // The live composer's chip: the release's full name, not the CLI's short display name.
        var state = ChatComposerState.idle(sessionID: UUID())
        state.resolvedModel = "claude-opus-5-5"
        state.models = [ModelOption(value: "opus", resolvedModel: "claude-opus-5-5", displayName: "Opus",
                                    supportedEffortLevels: [])]
        #expect(ComposerBarText.modelTitle(state) == "Opus 5.5")
    }

    @Test func codexRowsComeFromTheGivenListAndTheGroupIsLeftOutWhenThereIsNone() {
        let probed = [ModelCatalogEntry(harness: .codex, id: "fake-alpha", title: "Fake Alpha", note: "Default"),
                      ModelCatalogEntry(harness: .codex, id: "fake-beta", title: "Fake Beta")]
        let codex = picker().groups(codex: probed)[1]
        #expect(codex.rows.map(\.title) == ["Fake Alpha", "Fake Beta"])
        #expect(codex.rows.map(\.subtitle) == ["Default", nil])
        #expect(codex.rows.allSatisfy { !$0.isEnabled && !$0.checked && $0.id.hasPrefix("codex:") })
        #expect(picker().groups().count == 2, "without a list: today's names")
        #expect(picker().groups()[1].rows.map(\.title) == ModelCatalog.codexFallback.map(\.title))
        #expect(picker().groups(codex: []).map(\.provider) == [.claude], "switched off: Claude's group only")
    }
}
