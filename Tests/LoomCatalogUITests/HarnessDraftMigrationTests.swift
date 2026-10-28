import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// These are the actual 1.7.2 reader shapes. Unknown keys are ignored by its synthesized Codable readers.
private struct LegacyStoredDraft: Decodable {
    var id: UUID?
    var projectID: UUID?
    var text: String
    var modePick: DraftPick
    var modelPick: DraftPick
    var effortPick: DraftPick?
    var branchKind: BranchKind
    var branchName: String?
    var updatedAt: Date
}

private struct LegacyPreset: Decodable {
    var id: UUID
    var name: String
    var message: String
    var permissionMode: String?
    var model: String?
    var projectID: UUID?
}

private struct LegacyFile: Decodable {
    var drafts: [LegacyStoredDraft]
    var lastUsed: [String: ClaudeLaunchChoices]
    var presets: [LegacyPreset]
    var settings: NewSessionSettings
    var launched: [LaunchedSession]
}

@MainActor
struct HarnessDraftMigrationTests {
    @Test func newFilesPreserveDraftIdentityAndGiveTheOldReaderSafeClaudeChoices() throws {
        let project = UUID(), claudeID = UUID(), codexID = UUID()
        var claude = SessionDraft(id: claudeID, projectID: project, text: "Claude draft")
        claude.modePick = .value("plan")
        claude.modelPick = .value("opus")
        var codex = SessionDraft(id: codexID, projectID: project, text: "Codex draft")
        codex.choices = HarnessLaunchChoices(harness: .codex, model: "codex-test", effort: "high")
        var file = NewSessionFile()
        file.drafts = [StoredDraft(claude), StoredDraft(codex)]
        file.presets = [NewSessionPreset(name: "Codex preset", message: "go", choices: codex.choices, projectID: project)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let bytes = try encoder.encode(file)

        let old = try decoder.decode(LegacyFile.self, from: bytes)
        #expect(old.drafts.map(\.id) == [claudeID, codexID])
        #expect(old.drafts.map(\.projectID) == [project, project])
        #expect(old.drafts.map(\.text) == ["Claude draft", "Codex draft"])
        #expect(old.drafts[0].modelPick == .value("opus") && old.drafts[0].modePick == .value("plan"))
        #expect(old.drafts[1].modelPick == .inherit && old.drafts[1].modePick == .inherit && old.drafts[1].effortPick == .inherit)
        #expect(old.presets[0].model == nil && old.presets[0].permissionMode == nil)

        let current = try decoder.decode(NewSessionFile.self, from: bytes)
        #expect(current.drafts.map(\.draft.id) == [claudeID, codexID])
        #expect(current.drafts[1].draft.choices == codex.choices)
        #expect(current.presets[0].choices == codex.choices)
    }

    @Test func oldDraftAndPresetWithoutAHarnessReadAsClaude() throws {
        let id = UUID(), project = UUID()
        let old = """
        {"drafts":[{"id":"\(id)","projectID":"\(project)","text":"kept", "modePick":{"kind":"value","value":"plan"},
                    "modelPick":{"kind":"value","value":"sonnet"}, "branchKind":"stay", "updatedAt":"2026-10-28T00:00:00Z"}],
         "presets":[{"id":"\(UUID())","name":"P","message":"hello","permissionMode":"acceptEdits","model":"opus"}]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(NewSessionFile.self, from: Data(old.utf8))
        let draft = try #require(file.drafts.first?.draft)
        #expect(draft.id == id && draft.projectID == project && draft.text == "kept")
        #expect(draft.choices == HarnessLaunchChoices(model: "sonnet", mode: .plan))
        #expect(file.presets.first?.choices == HarnessLaunchChoices(model: "opus", mode: .acceptEdits))
    }

    @Test func anUnknownFutureModeDoesNotDiscardDraftOrPresetText() throws {
        let draftID = UUID(), presetID = UUID(), project = UUID()
        let json = """
        {"drafts":[{"id":"\(draftID)","projectID":"\(project)","text":"draft survives",
                    "modePick":{"kind":"inherit"},"modelPick":{"kind":"inherit"},"branchKind":"stay",
                    "updatedAt":"2026-10-28T00:00:00Z","choices":{"harness":"claude","mode":"future-mode"}}],
         "presets":[{"id":"\(presetID)","name":"P","message":"preset survives",
                     "choices":{"harness":"claude","mode":"future-mode"}}]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(NewSessionFile.self, from: Data(json.utf8))
        let draft = try #require(file.drafts.first?.draft)
        let preset = try #require(file.presets.first)
        #expect(draft.id == draftID && draft.projectID == project && draft.text == "draft survives")
        #expect(draft.choices.mode == nil)
        #expect(preset.id == presetID && preset.message == "preset survives" && preset.choices.mode == nil)
    }

    @Test func selectingAModelChangesDraftOwnershipAndAPresetKeepsItsOwnChoices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-c4-draft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        defer { model.stop() }
        model.showDraft(projectID: nil)
        model.setDraftText("hello", projectID: nil)
        model.setDraftMode(.value("bypassPermissions"), projectID: nil)
        model.setDraftModel(ModelCatalog.claude[0], projectID: nil)
        #expect(!model.draftKeepsFullAccess(projectID: nil), "changing a Claude model preserves the user's current pick")
        model.setDraftEffort(.value("max"), projectID: nil)
        let entry = ModelCatalogEntry(harness: .codex, id: "codex-test", title: "Codex test",
                                      efforts: ["low", "high"], defaultEffort: "high")
        model.modelCatalog.apply(HarnessReading(provider: .codex, models: [HarnessModel(
            id: entry.id, displayName: entry.title, isDefault: true, efforts: entry.efforts,
            defaultEffort: entry.defaultEffort)], readAt: Date()))
        model.setDraftModel(entry, projectID: nil)
        let draft = try #require(model.newSession.draft(for: nil))
        #expect(draft.choices == HarnessLaunchChoices(harness: .codex, model: entry.id, effort: "high"))
        #expect(model.resolvedStart(for: nil).choices == draft.choices)
        #expect(!model.canSendDraft(projectID: nil))

        let sharedClaude = ModelCatalogEntry(harness: .claude, id: "opus", title: "Opus",
                                             efforts: ["low", "high"], defaultEffort: "low")
        model.setDraftModel(sharedClaude, projectID: nil)
        #expect(model.resolvedStart(for: nil).choices.effort == "high", "the new model offers the current effort")
        model.setDraftModel(entry, projectID: nil)
        #expect(model.resolvedStart(for: nil).choices.effort == "high")

        let preset = NewSessionPreset(name: "Claude", message: "saved", choices: HarnessLaunchChoices(mode: .fullAccess))
        model.applyPreset(preset, projectID: nil)
        #expect(model.newSession.draft(for: nil)?.harness == .claude)
        #expect(model.resolvedStart(for: nil).choices.mode == .fullAccess)
        #expect(model.draftKeepsFullAccess(projectID: nil))
    }

    @Test func lastUsedRefreshDoesNotChangeAnEditedDraftButANewDraftUsesTheNewHarness() throws {
        let state = NewSessionState()
        state.open(projectID: nil)
        state.setText("my work", for: nil)
        state.update(nil) { $0.modePick = .value("plan") }
        let saved = try #require(state.draft(for: nil))
        state.setLastUsedChoices(["none": HarnessProjectChoices(lastHarness: .codex)])
        let afterRefresh = try #require(state.draft(for: nil))
        #expect(afterRefresh.id == saved.id && afterRefresh.text == "my work")
        #expect(afterRefresh.harness == .claude && afterRefresh.choices.mode == .plan)
        state.openEmpty(projectID: nil)
        let next = try #require(state.draft(for: nil))
        #expect(next.id != saved.id && next.harness == .codex)
    }

    @Test func optimisticLastUsedClearsTheOldModelsEffortOnACompleteStart() throws {
        let state = NewSessionState()
        let old = HarnessLaunchChoices(model: "opus", effort: "high", mode: .plan)
        state.setLastUsedChoices(["none": HarnessProjectChoices(byHarness: ["claude": old])])
        state.open(projectID: nil)
        let draft = try #require(state.draft(for: nil))
        state.started(draft, choices: HarnessLaunchChoices(model: "sonnet", mode: .plan), clearsSlot: false)
        #expect(state.lastUsed(for: nil)?.model == "sonnet")
        #expect(state.lastUsed(for: nil)?.effort == nil)
    }

    @Test func draftEffortUsesTheCachedDefaultModelsLevels() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-c4-default-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        defer { model.stop() }
        model.modelCatalog.apply(HarnessReading(provider: .claude, models: [
            HarnessModel(id: "default", displayName: "Default", isDefault: true, efforts: ["low"]),
            HarnessModel(id: "opus", displayName: "Opus", isDefault: false, efforts: ["low", "high"]),
        ], readAt: Date()))
        model.showDraft(projectID: nil)
        model.setDraftEffort(.value("high"), projectID: nil)
        #expect(model.resolvedStart(for: nil).effort.value == nil)
        model.setDraftEffort(.value("low"), projectID: nil)
        #expect(model.resolvedStart(for: nil).effort.value == "low")
    }

    @Test func aRememberedEffortFromTheModelCatalogSurvivesEvenWhenItIsNew() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-c4-effort-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        defer { model.stop() }
        model.modelCatalog.apply(HarnessReading(provider: .claude, models: [
            HarnessModel(id: "opus", displayName: "Opus", isDefault: false, efforts: ["low", "turbo"]),
        ], readAt: Date()))
        let previous = HarnessLaunchChoices(model: "opus", effort: "turbo", mode: .plan)
        model.newSession.setLastUsedChoices(["none": HarnessProjectChoices(byHarness: ["claude": previous])])
        model.showDraft(projectID: nil)
        #expect(model.resolvedStart(for: nil).choices.effort == "turbo")
    }
}
