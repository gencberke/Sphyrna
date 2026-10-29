import AppKit
import Foundation
@testable import LoomChat
import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

private typealias LookupCount = HarnessCatalogShared.LookupCount

/// The connect switch's preference and the composer's model lists as they come from `ModelCatalog` (D-98, D-99).
@MainActor
struct HarnessCatalogTests: HarnessCatalogFixtures {
    // MARK: The lists

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

    // MARK: Startable (C2B)
}
