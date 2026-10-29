import AppKit
import Foundation
@testable import LoomChat
import LoomCore
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `HarnessCatalogTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum HarnessCatalogShared {
    /// Counts the PATH lookups a test's reader makes.
    actor LookupCount {
        private(set) var value = 0
        func bump() { value += 1 }
    }
}

/// `HarnessCatalogTests`'s fixtures, for both halves of the suite.
@MainActor protocol HarnessCatalogFixtures {}

extension HarnessCatalogFixtures {
    typealias LookupCount = HarnessCatalogShared.LookupCount

    func picker(codexNote: String = ComposerModelNotes.inNewSession) -> ComposerModelPicker {
        ComposerModelPicker(
            modelTitle: "Sonnet", effortTitle: nil, rows: ModelCatalog.claude.map { ComposerBarText.ModelRow(value: $0.id, title: $0.title) },
            chosenModel: nil, levels: NewSessionModels.effortLevels, chosenLevel: nil, canResetEffort: false, codexNote: codexNote)
    }

    /// Waits until the lookups reach `count`, for a read that runs off the main actor; returns how many there were.
    func lookups(_ reads: LookupCount, reached count: Int) async -> Int {
        for _ in 0..<500 {
            let value = await reads.value
            if value >= count { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await reads.value
    }
}
