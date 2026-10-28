import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

@MainActor struct EffortPickerTests {
    @Test func onlyTheModelsValidLevelsAndValidDefaultAreOffered() {
        let entry = ModelCatalogEntry(harness: .codex, id: "sol", title: "Sol",
                                      efforts: ["low", "high", "ultra", "bad token"], defaultEffort: "ultra")
        let options = EffortPickerOptions(entry: entry, current: "ultra")
        #expect(options.levels == ["low", "high", "ultra"])
        #expect(options.defaultLevel == "ultra" && options.title == "Ultra")
        let empty = EffortPickerOptions(entry: nil, current: nil)
        #expect(empty.levels.isEmpty && empty.defaultLevel == nil && empty.title == "Default")
    }

    @Test func staleMenuCannotApplyToAnotherModelAndNewLevelsRoundTrip() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b4-effort-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        defer { model.stop() }
        model.modelCatalog.apply(HarnessReading(provider: .codex, models: [
            HarnessModel(id: "first", displayName: "First", isDefault: true, efforts: ["low", "ultra"], defaultEffort: "low"),
            HarnessModel(id: "second", displayName: "Second", isDefault: false, efforts: ["high"], defaultEffort: "high")
        ], readAt: Date()))
        model.showDraft(projectID: nil)
        #expect(ModelPickerDraft.choose(ModelPickerKey(harness: .codex, id: "first"), model: model, projectID: nil))
        let old = ModelPickerDraft.owner(model: model, projectID: nil)
        #expect(ModelPickerDraft.chooseEffort("ultra", expected: old, model: model, projectID: nil))
        #expect(model.resolvedStart(for: nil).choices.effort == "ultra")
        #expect(ModelPickerDraft.choose(ModelPickerKey(harness: .codex, id: "second"), model: model, projectID: nil))
        #expect(!ModelPickerDraft.chooseEffort("ultra", expected: old, model: model, projectID: nil))
        #expect(model.resolvedStart(for: nil).choices.effort == "high")
        let controller = EffortPickerController()
        let owner = ModelPickerDraft.owner(model: model, projectID: nil)
        let options = ModelPickerDraft.options(model: model, projectID: nil)
        controller.prepare(owner: owner, options: options)
        #expect(controller.handle(.return, options: options) == .choose(.level("high")))
        #expect(controller.handle(.escape, options: options) == .dismiss)
    }
}
