import Foundation
@testable import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// W3-f: the palette's Add project… and Reveal in Finder, listed where they apply and found by their words; "draft" finds New
/// session, which does what ⌘N does.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PaletteFlowActionsTests {
    private struct Rig {
        let root: URL
        let model: CatalogModel
        let intents: InspectorIntents
        let projectID: UUID
        let sessionID: UUID
        let folder: URL

        @MainActor func cleanup() {
            model.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeRig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-palette-flow-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("api-gateway", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let projectID = try await catalog.addProject(path: folder.path).project.id
        let session = ManagedSession(provider: .claude, providerConversationID: "conv-0", workingDirectory: folder.path)
        try await catalog.insertSession(session, title: "Token rotation", createdAt: Date(timeIntervalSince1970: 1_000),
                                        lastUsedAt: Date(), lifecycle: .idle, projectID: projectID)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        let intents = InspectorIntents()
        model.intents = intents // New session is offered where a session can start, as ⌘N is
        await model.start()
        _ = await inspectorWaitUntil { model.list(for: .activity).rows.count == 1 }
        return Rig(root: root, model: model, intents: intents, projectID: projectID, sessionID: session.id, folder: folder)
    }

    private func selected(_ model: CatalogModel, _ query: String) -> PaletteItem? {
        model.openPalette()
        model.palette.setQuery(query)
        defer { model.palette.close() }
        return model.palette.items.first { $0.id == model.palette.selectedID }
    }

    @Test func theyAreFoundByTheirWords() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let model = rig.model
        for query in ["add project", "repository"] {
            #expect(selected(model, query)?.target == .action(.addProject), "\"\(query)\"")
        }
        model.showProjectPage(rig.projectID)
        for query in ["draft", "write", "prompt"] {
            #expect(selected(model, query)?.target == .action(.newSession), "\"\(query)\"")
        }
        #expect(selected(model, "draft")?.detail == "in api-gateway")
        // On the project page, Reveal in Finder is the project's folder.
        let project = try #require(selected(model, "reveal in finder"))
        #expect(project.target == .action(.revealInFinder) && project.detail == "for api-gateway")
        #expect(model.revealInFinderTarget()?.path == rig.folder.path)
        // With a session selected, it is the session's folder.
        model.select(rig.sessionID)
        #expect(await inspectorWaitUntil { model.selectedRow?.id == rig.sessionID })
        let session = try #require(selected(model, "finder"))
        #expect(session.target == .action(.revealInFinder) && session.detail?.hasPrefix("for Token rotation") == true)
        #expect(model.revealInFinderTarget()?.path == rig.folder.path)
    }

    @Test func revealInFinderIsNotOfferedWithoutAFolder() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let model = rig.model
        model.showHome()
        #expect(model.revealInFinderTarget() == nil, "Home has no folder")
        #expect(!PaletteAction.revealInFinder.isEnabled(on: model))
        model.select(rig.sessionID)
        #expect(await inspectorWaitUntil { model.selectedRow?.id == rig.sessionID })
        #expect(model.revealInFinderTarget(folderExists: { _ in false }) == nil, "a folder that is gone")
        #expect(PaletteAction.addProject.isEnabled(on: model))
    }

    @Test func draftFindsNewSessionWhichOpensTheDraftAsCommandNDoes() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let model = rig.model
        model.showProjectPage(rig.projectID)
        model.openPalette()
        model.palette.setQuery("draft")
        #expect(model.palette.selectedID == "action:" + PaletteAction.newSession.rawValue)
        #expect(!PaletteAction.allCases.map(\.rawValue).contains("newDraft"), "one action for ⌘N")
        model.palette.activateSelected()
        #expect(!model.palette.isOpen)
        #expect(model.destination == .draft(projectID: rig.projectID))
    }
}
