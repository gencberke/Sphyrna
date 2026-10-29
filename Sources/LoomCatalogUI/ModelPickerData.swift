import Foundation
import LoomCore
import Observation

struct ModelPickerKey: Hashable, Sendable {
    let harness: HarnessID
    let id: String
    init(_ entry: ModelCatalogEntry) { harness = entry.harness; id = entry.id }
    init(harness: HarnessID, id: String) { self.harness = harness; self.id = id }
}

extension ModelCatalogEntry {
    var pickerKey: ModelPickerKey { ModelPickerKey(self) }
}

enum ModelPickerChoice: Hashable, Sendable {
    case model(ModelPickerKey)
    case defaultModel(HarnessID)

    var harness: HarnessID {
        switch self {
        case let .model(key): key.harness
        case let .defaultModel(harness): harness
        }
    }
}

/// A model may appear both in Recent and its harness group; each visible row has its own cursor and scroll target.
struct ModelPickerRow: Hashable {
    let section: ModelPickerController.Section
    let choice: ModelPickerChoice
}

@MainActor @Observable final class ModelPickerState {
    private(set) var recent: [ModelPickerKey] = []
    func record(_ key: ModelPickerKey) {
        let next = Array(([key] + recent.filter { $0 != key }).prefix(5))
        if next != recent { recent = next }
    }
}

@MainActor struct ModelPickerProjection {
    struct Group: Identifiable {
        let descriptor: HarnessDescriptor
        let state: HarnessAvailabilityState
        let models: [ModelCatalogEntry]
        var id: HarnessID { descriptor.id }
    }
    let groups: [Group]
    let recent: [ModelCatalogEntry]
    let notSearched: [String]
    private let search: String
    func choices(defaultFor harness: HarnessID) -> [ModelPickerChoice] {
        groups.filter { $0.state == .on }.flatMap { group in
            let includesDefault = group.id == harness && (search.isEmpty
                || "Default".localizedCaseInsensitiveContains(search)
                || group.descriptor.displayName.localizedCaseInsensitiveContains(search))
            let prefix: [ModelPickerChoice] = includesDefault ? [.defaultModel(harness)] : []
            return prefix + group.models.map { .model(ModelPickerKey($0)) }
        }
    }

    func rows(defaultFor harness: HarnessID) -> [ModelPickerRow] {
        let recentRows = recent.map { ModelPickerRow(section: .recent, choice: .model(ModelPickerKey($0))) }
        let groupRows = choices(defaultFor: harness).map { ModelPickerRow(section: .harness($0.harness), choice: $0) }
        return recentRows + groupRows
    }

    init(catalog: ModelCatalog, availability: [HarnessID: HarnessAvailability]?, connections: HarnessConnections? = nil,
         recentKeys: [ModelPickerKey] = [],
         query: String = "", scope: HarnessID? = nil) {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.search = search
        let descriptors = HarnessCatalogue.all.filter { scope == nil || $0.id == scope }
        let all = descriptors.map { descriptor -> Group in
            let state: HarnessAvailabilityState
            if descriptor.comingLater {
                state = .comingLater
            } else if let availability, availability[descriptor.id]?.state == nil || availability[descriptor.id]?.state == .notFound {
                state = .notFound
            } else if !(connections ?? catalog.connections).isOn(descriptor.id) {
                state = .off
            } else {
                state = .on
            }
            let entries = state == .on ? descriptor.provider.map { catalog.models(for: $0) } ?? [] : []
            return Group(descriptor: descriptor, state: state, models: entries)
        }
        let byKey = Dictionary(all.flatMap(\.models).map { (ModelPickerKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        recent = search.isEmpty ? recentKeys.compactMap { byKey[$0] } : []
        notSearched = search.isEmpty ? [] : all.compactMap { group in
            switch group.state {
            case .on where group.models.isEmpty: "\(group.descriptor.displayName) (no models reported)"
            case .on: nil
            case .off: "\(group.descriptor.displayName) (off)"
            case .notFound: "\(group.descriptor.displayName) (not found)"
            case .comingLater: "\(group.descriptor.displayName) (coming later)"
            }
        }
        groups = all.map { group in
            guard !search.isEmpty else { return group }
            let matches = group.models.filter { entry in
                [entry.id, entry.title, entry.note ?? "", entry.description ?? "", group.descriptor.displayName]
                    .contains { $0.localizedCaseInsensitiveContains(search) }
            }
            return Group(descriptor: group.descriptor, state: group.state, models: matches)
        }
    }
}
