import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// D-120: opencode and agy are frozen for 1.8.0. Each surface that lists harnesses marks them "Coming later" from the
/// catalogue's one field and offers nothing that would start them: Settings → Connections, Home's connect cards, the
/// draft's model picker (which is also its harness picker), Remora's model setting, and a stored draft's send.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HarnessComingLaterSurfaceTests {
    static let frozen: [HarnessID] = [.opencode, .agy]

    @Test func everyHarnessListMarksAFrozenHarnessComingLaterAndStartsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-later-\(UUID())", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["claude", "codex", "opencode", "agy"] {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // The person had switched both on before the freeze: the choice is kept, and still nothing is offered.
        let connections = HarnessConnections(choices: [.opencode: true, .agy: true])
        let rig = ConnectionsRig.Rig(claude: ConnectionsRig.max, codex: ConnectionsRig.max, codexFound: true,
                                     connections: connections)
        let store = UIPreferencesStore(url: root.appendingPathComponent("preferences.json"))
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: store,
                                 startableProviders: [.claude, .codex, .agy])
        defer { model.stop() }
        let catalog = ModelCatalog(connections: connections)
        model.modelCatalog = catalog
        model.harnessConnections = connections
        model.installHarnessHealth(rig.model)
        model.installHarnessAvailability(HarnessAvailabilityReader(environment: { [path = bin.path] in ["PATH": path] }))
        #expect(await inspectorWaitUntil { model.harnessAvailability != nil }, "the PATH read never answered")

        // Settings → Connections.
        for id in Self.frozen {
            let row = try #require(model.connectionRows.first { $0.id == id })
            #expect(row.headline == "Coming later", "\(id.rawValue): \(row.headline)")
            #expect(!row.isOn && !row.canSwitch && !row.canStart && !row.buildSupportsSessions)
            #expect(row.accessibilityLabel.contains("Coming later"))
            model.setHarnessConnected(id, false)
            #expect(store.current.harnessConnections[id.rawValue] == nil, "the unusable switch writes nothing")
        }

        // Home's connect cards: no setup action and never a reason for the notice.
        for id in Self.frozen {
            let card = HomeConnect.card(for: try #require(model.connectionRows.first { $0.id == id }))
            #expect(card.word == "Coming later" && card.action == nil, "\(id.rawValue): \(card.word)")
            #expect(!HomeConnect.needsSetup(card.row))
        }

        // The draft's model picker: no group's models, no choice, and the search says why.
        let browse = ModelPickerProjection(catalog: catalog, availability: model.harnessAvailability, connections: connections)
        #expect(!browse.choices(defaultFor: .claude).contains { Self.frozen.contains($0.harness) })
        for id in Self.frozen {
            #expect(browse.groups.first { $0.id == id }?.models.isEmpty == true)
        }
        let search = ModelPickerProjection(catalog: catalog, availability: model.harnessAvailability,
                                           connections: connections, query: "gemini")
        #expect(search.notSearched.contains("opencode (coming later)") && search.notSearched.contains("agy (coming later)"),
                "\(search.notSearched)")

        // Remora's model setting runs only behind models the catalog offers, and none is a frozen harness's.
        let remora = RemoraChoices.models(from: catalog.claudeModels, including: "sonnet")
        #expect(!remora.contains { option in
            Self.frozen.contains { id in catalog.validationModels(for: id).contains { $0.id == option.value } } })
        #expect(Self.frozen.allSatisfy { catalog.validationModels(for: $0).isEmpty })

        // A stored draft for a frozen harness cannot be sent, and says why.
        for id in Self.frozen {
            model.showDraft(projectID: nil)
            model.newSession.update(nil) { draft in
                draft.choices = HarnessLaunchChoices(harness: id)
                draft.followsProjectHarness = false
                draft.text = "Start this"
            }
            #expect(!model.canSendDraft(projectID: nil))
            #expect(model.draftSendBlock(projectID: nil)
                == "\(id.rawValue) is coming later: this version of Sphyrna cannot start its sessions",
                "\(id.rawValue): \(model.draftSendBlock(projectID: nil) ?? "no reason")")
        }
        #expect(!model.capabilities(of: .agy).startable)
    }
}
