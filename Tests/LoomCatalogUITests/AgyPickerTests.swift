import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

@MainActor struct AgyPickerTests {
    @Test func enabledAgyModelCanSelectItsHarnessWithoutInventingEffortOrFullAccess() throws {
        let catalog = ModelCatalog()
        #expect(catalog.models(for: .agy).isEmpty)
        catalog.connections.setOn(.agy, true)
        let availability = [HarnessID.agy: HarnessAvailability(id: .agy, state: .on)]
        let projection = ModelPickerProjection(catalog: catalog, availability: availability, scope: .agy)
        let entry = try #require(projection.groups.first?.models.first)
        #expect(entry.id == "gemini-3.8-flash-medium" && entry.efforts.isEmpty)
        #expect(projection.choices(defaultFor: .claude) == [.model(ModelPickerKey(entry))])
        let selected = HarnessLaunchChoices(harness: .claude, mode: .fullAccess).choosing(entry)
        #expect(selected.harness == .agy && selected.model == entry.id && selected.effort == nil && selected.mode == nil)
        #expect(HarnessCapabilities.of(.agy, startable: [.agy]).startable)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-picker-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
            preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")),
            startableProviders: [.claude, .agy])
        defer { model.stop() }
        model.modelCatalog = catalog
        model.harnessConnections = catalog.connections
        model.harnessAvailability = [.agy: HarnessAvailability(id: .agy, state: .on, executable: "/tmp/fake-agy")]
        model.showDraft(projectID: nil)
        #expect(ModelPickerDraft.choose(ModelPickerKey(entry), model: model, projectID: nil))
        #expect(model.resolvedStart(for: nil).choices.harness == .agy)
        #expect(model.resolvedStart(for: nil).choices.model == entry.id)
        #expect(model.capabilities(of: .agy).startable)
    }
}
