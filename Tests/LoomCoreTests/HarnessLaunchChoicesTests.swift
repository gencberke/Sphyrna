import Foundation
import Testing
@testable import LoomCore

struct HarnessLaunchChoicesTests {
    @Test func choosingAnotherHarnessUsesTheDefaultForAnUnsupportedEffortAndNeverCarriesFullAccess() {
        let original = HarnessLaunchChoices(harness: .claude, model: "opus", effort: "max", mode: .fullAccess)
        let model = ModelCatalogEntry(harness: .codex, id: "codex-test", title: "Codex test",
                                      efforts: ["low", "high"], defaultEffort: "high")
        let selected = original.choosing(model)
        #expect(selected.harness == .codex && selected.model == "codex-test")
        #expect(selected.effort == "high")
        #expect(selected.mode == nil, "Codex modes wait for the P0 mapping")
        #expect(selected.claudeChoices == nil)

        let back = selected.choosing(ModelCatalog.claude[0])
        #expect(back.harness == .claude && back.mode == .askBeforeEdits)
        #expect(back.effort == "high", "Claude offers the level picked on the previous model")
    }

    @Test func changingModelsKeepsAnEffortTheNewModelOffers() {
        let original = HarnessLaunchChoices(model: "opus", effort: "high", mode: .plan)
        let otherHarness = ModelCatalogEntry(harness: .codex, id: "codex-test", title: "Codex",
                                             efforts: ["low", "high"], defaultEffort: "low")
        let selected = original.choosing(otherHarness)
        #expect(selected.harness == .codex && selected.effort == "high")
        let sameHarness = ModelCatalogEntry(harness: .claude, id: "sonnet", title: "Sonnet",
                                            efforts: ["low", "high"], defaultEffort: "low")
        #expect(original.choosing(sameHarness).effort == "high")
        let noEffort = ModelCatalogEntry(harness: .codex, id: "plain", title: "Plain")
        #expect(original.choosing(noEffort).effort == nil)
    }

    @Test func validationUsesTheSelectedModelsEffortsAndDescriptorModes() throws {
        let model = ModelCatalogEntry(harness: .codex, id: "codex-test", title: "Codex",
                                      efforts: ["low", "high"], defaultEffort: "low")
        try HarnessLaunchChoices(harness: .codex, model: model.id, effort: "high").validate(models: [model])
        #expect(throws: OpenSessionRejection.self) {
            try HarnessLaunchChoices(harness: .codex, model: model.id, effort: "max").validate(models: [model])
        }
        #expect(throws: OpenSessionRejection.self) {
            try HarnessLaunchChoices(harness: .codex, model: model.id, mode: .auto).validate(models: [model])
        }
        #expect(throws: OpenSessionRejection.self) {
            try HarnessLaunchChoices(harness: .claude, model: "--model").validate(models: ModelCatalog.claude)
        }
        #expect(throws: OpenSessionRejection.self) {
            try HarnessLaunchChoices(mode: .fullAccess).validate(models: ModelCatalog.claude, allowFullAccess: false)
        }
    }

    @Test func theKnownDefaultModelsEffortsConstrainAnEffortWithoutAModelFlag() throws {
        let defaultModel = ModelCatalogEntry(harness: .claude, id: "default", title: "Default", efforts: ["low"])
        try HarnessLaunchChoices(effort: "low").validate(models: [defaultModel])
        #expect(throws: OpenSessionRejection.self) {
            try HarnessLaunchChoices(effort: "high").validate(models: [defaultModel])
        }
    }

    @Test func legacyChoicesDecodeAsClaudeAndFullAccessIsNotRemembered() throws {
        let old = Data(#"{"permissionMode":"acceptEdits","model":"sonnet","effort":"high"}"#.utf8)
        let choices = try JSONDecoder().decode(HarnessLaunchChoices.self, from: old)
        #expect(choices == HarnessLaunchChoices(model: "sonnet", effort: "high", mode: .acceptEdits))
        let full = HarnessLaunchChoices(model: "opus", mode: .fullAccess)
        let kept = full.remembered(over: choices)
        #expect(kept.mode == .acceptEdits && kept.model == "opus")
        #expect(full.remembered(over: nil).mode == nil)
    }
}
