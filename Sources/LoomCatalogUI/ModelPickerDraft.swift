import Foundation
import LoomCore

/// The current draft identity prevents a menu opened for another draft or model from applying a stale effort.
struct EffortPickerOwner: Equatable {
    let draftID: UUID?
    let harness: HarnessID
    let model: String?
}

@MainActor enum ModelPickerDraft {
    static func projection(model: CatalogModel, query: String = "") -> ModelPickerProjection {
        ModelPickerProjection(catalog: model.modelCatalog, availability: model.harnessAvailability,
                              connections: model.harnessConnections,
                              recentKeys: model.modelPickerState.recent, query: query)
    }

    static func owner(model: CatalogModel, projectID: UUID?) -> EffortPickerOwner {
        let choices = model.resolvedStart(for: projectID).choices
        return EffortPickerOwner(draftID: model.newSession.draft(for: projectID)?.id, harness: choices.harness, model: choices.model)
    }

    static func options(model: CatalogModel, projectID: UUID?) -> EffortPickerOptions {
        let choices = model.resolvedStart(for: projectID).choices
        guard isAvailable(choices.harness, model: model) else {
            return EffortPickerOptions(entry: nil, current: nil)
        }
        let entries = model.modelCatalog.validationModels(for: choices.harness)
        if let id = choices.model {
            return EffortPickerOptions(entry: entries.first { $0.id == id }, current: choices.effort)
        }
        return defaultOptions(harness: choices.harness, current: choices.effort, model: model)
    }

    /// Looks the entry up again at the moment of application: a switch, PATH result or model list may have changed while open.
    @discardableResult static func choose(_ key: ModelPickerKey, model: CatalogModel, projectID: UUID?) -> Bool {
        guard isAvailable(key.harness, model: model) else { return false }
        let groups = ModelPickerProjection(catalog: model.modelCatalog, availability: model.harnessAvailability,
                                           connections: model.harnessConnections, scope: key.harness).groups
        guard let group = groups.first(where: { $0.id == key.harness }), group.state == .on,
              let entry = group.models.first(where: { $0.id == key.id }) else { return false }
        model.setDraftModel(entry, projectID: projectID)
        model.modelPickerState.record(key)
        return true
    }

    /// Default is a reset action for the current harness, not a fabricated model entry.
    @discardableResult static func chooseDefault(harness: HarnessID, model: CatalogModel, projectID: UUID?) -> Bool {
        let current = model.resolvedStart(for: projectID).choices
        guard current.harness == harness, isAvailable(harness, model: model) else { return false }
        let defaults = defaultOptions(harness: harness, current: current.effort, model: model)
        let nextEffort = defaults.current ?? defaults.defaultLevel
        model.newSession.update(projectID) { draft in
            draft.modelPick = .claudeDefault
            draft.effortPick = nextEffort.map(DraftPick.value) ?? .claudeDefault
        }
        return true
    }

    @discardableResult static func chooseEffort(_ level: String, expected: EffortPickerOwner,
                                                model: CatalogModel, projectID: UUID?) -> Bool {
        guard owner(model: model, projectID: projectID) == expected,
              options(model: model, projectID: projectID).levels.contains(level) else { return false }
        model.setDraftEffort(.value(level), projectID: projectID)
        return true
    }

    @discardableResult static func resetEffort(expected: EffortPickerOwner, model: CatalogModel, projectID: UUID?) -> Bool {
        guard owner(model: model, projectID: projectID) == expected, isAvailable(expected.harness, model: model),
              !options(model: model, projectID: projectID).levels.isEmpty else { return false }
        model.setDraftEffort(.claudeDefault, projectID: projectID)
        return true
    }

    private static func defaultOptions(harness: HarnessID, current: String?, model: CatalogModel) -> EffortPickerOptions {
        let entries = model.modelCatalog.validationModels(for: harness)
        if let entry = entries.first(where: { $0.isDefault || $0.id == "default" }) {
            return EffortPickerOptions(entry: entry, current: current)
        }
        let levels = HarnessCatalogue.descriptor(for: harness)?.defaultEfforts ?? []
        return EffortPickerOptions(levels: levels, current: current)
    }

    private static func isAvailable(_ harness: HarnessID, model: CatalogModel) -> Bool {
        guard HarnessCatalogue.descriptor(for: harness) != nil,
              (model.harnessConnections ?? model.modelCatalog.connections).isOn(harness),
              model.modelCatalog.connections.isOn(harness) else { return false }
        guard let availability = model.harnessAvailability else { return true }
        return availability[harness]?.state != nil && availability[harness]?.state != .notFound
    }
}
