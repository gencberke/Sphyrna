import Foundation
import AppKit
import Testing
import LoomCore
@testable import LoomCatalogUI

@MainActor
private final class StartRecorder: ConversationIntents {
    var starts: [(ManagedSession.Provider, UUID?)] = []
    func start(provider: ManagedSession.Provider, projectID: UUID?) { starts.append((provider, projectID)) }
    func resume(sessionID: UUID) {}
    func stop(sessionID: UUID) {}
    func answer(sessionID: UUID, requestID: String, accept: Bool) {}
    func viewed(sessionID: UUID) {}
    func terminalView(sessionID: UUID) -> NSView? { nil }
}

/// FB-C items 1 and 2: the project header "+" and the projectless Claude entries. The views only render
/// `ClaudeStartEntry`, so these tests drive the same object the buttons call.
@MainActor
struct SidebarEntryPointTests {
    private struct Fixture {
        let root: URL
        let model: CatalogModel
        let intents: StartRecorder
        let project: CatalogProject
        let projectSession: ManagedSession
    }

    private func makeFixture(startableProviders: Set<ManagedSession.Provider> = [.claude, .codex]) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-entry-\(UUID())")
        let folder = root.appendingPathComponent("rocket", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        let session = ManagedSession(provider: .claude, workingDirectory: folder.path)
        try await catalog.insertSession(session, title: "In rocket", lifecycle: .idle, projectID: project.id)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")),
                                 startableProviders: startableProviders)
        let intents = StartRecorder()
        model.intents = intents
        await model.start()
        await model.stopAndWait()
        return Fixture(root: root, model: model, intents: intents, project: project, projectSession: session)
    }

    // MARK: Item 1, the project header "+"

    @Test func projectPlusOpensTheDraftOfThatProjectAndStartsNothing() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entry = try #require(ClaudeStartEntry.inProject(fixture.project, on: fixture.model))
        #expect(entry.title == "New Claude session in rocket")
        #expect(entry.isEnabled(on: fixture.model))
        entry.perform(on: fixture.model)
        // A Claude session exists only after the draft's first send (V07).
        #expect(fixture.model.destination == .draft(projectID: fixture.project.id))
        #expect(fixture.model.detailRoute == .draft(projectID: fixture.project.id))
        #expect(fixture.intents.starts.isEmpty)
    }

    @Test func projectPlusIsDisabledAndInertWhileQuitting() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entry = try #require(ClaudeStartEntry.inProject(fixture.project, on: fixture.model))
        fixture.model.quitting = true
        #expect(!entry.isEnabled(on: fixture.model))
        entry.perform(on: fixture.model)
        #expect(fixture.intents.starts.isEmpty)
        #expect(fixture.model.destination == nil, "no draft opens either")
    }

    @Test func projectPlusIsAbsentWhereClaudeCannotBeStarted() async throws {
        let fixture = try await makeFixture(startableProviders: [.codex])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(ClaudeStartEntry.inProject(fixture.project, on: fixture.model) == nil)
        #expect(ClaudeStartEntry.withoutProject(title: "x", on: fixture.model) == nil)
    }

    // MARK: Item 2, projectless sessions

    @Test func theEmptyAreaMenuStartsWithoutAProjectEvenWhenAProjectSessionIsSelected() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.select(fixture.projectSession.id)
        #expect(fixture.model.contextProjectID == fixture.project.id, "the footer and Cmd+N would start here")
        let entry = try #require(ClaudeStartEntry.withoutProject(title: ClaudeStartEntry.withoutProjectTitle, on: fixture.model))
        #expect(entry.title == "New Claude Session Without Project")
        entry.perform(on: fixture.model)
        #expect(fixture.model.destination == .draft(projectID: nil), "a draft with no project")
        #expect(fixture.intents.starts.isEmpty)
    }

    @Test func aProjectlessSessionInTheProjectViewGroupHasNoRepeatedNoProjectTitle() {
        let loose = CatalogSession(
            session: ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: nil,
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: 0),
            lifecycle: .idle, pinned: false, projectID: nil)
        // Project view (the "Sessions" group): the group already says it.
        #expect(loose.displayTitle(projectName: nil, repeatsProject: false) == "Claude session")
        // Activity view keeps the explicit label, there is no group around the card.
        #expect(loose.displayTitle(projectName: nil, repeatsProject: true) == "Claude · No project")
    }

    // MARK: Item 4, what Pin promises

    @Test func pinPromisesCleanupOnlyWhereTheCleanupReviewExists() {
        #expect(SessionCardView.pinHelp(cleanupReviewOffered: true).contains("out of cleanup"))
        #expect(!SessionCardView.pinHelp(cleanupReviewOffered: false).contains("cleanup"))
        #expect(SessionCardView.pinnedGlyphHelp(cleanupReviewOffered: true).contains("cleanup"))
        #expect(!SessionCardView.pinnedGlyphHelp(cleanupReviewOffered: false).contains("cleanup"))
    }
}
