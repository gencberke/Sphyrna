import Foundation
import LoomCore

struct EffortPickerOptions: Equatable {
    let levels: [String]
    let current: String?
    let defaultLevel: String?
    var title: String { current.map(ComposerBarText.effortLabel) ?? "Default" }

    init(entry: ModelCatalogEntry?, current: String?) {
        self.init(levels: entry?.efforts ?? [], defaultLevel: entry?.defaultEffort, current: current)
    }

    init(levels: [String], defaultLevel: String? = nil, current: String?) {
        var seen = Set<String>()
        let valid = HarnessEffort.tokens(levels).filter { seen.insert($0).inserted }
        self.levels = valid
        self.current = current.flatMap { valid.contains($0) ? $0 : nil }
        self.defaultLevel = defaultLevel.flatMap { valid.contains($0) ? $0 : nil }
    }
}
