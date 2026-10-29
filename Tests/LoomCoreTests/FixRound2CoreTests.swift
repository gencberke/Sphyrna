import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

// Release B fix round 2, the core part: what each project remembers for its next session, and the pause between looks.

struct FixRound2CoreTests {
    private func catalog() throws -> (URL, SessionCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-fix2-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3")))
    }

    /// D11: the catalog remembers, per project, the newest mode, model and effort a start or a live change set; Full access is
    /// never remembered; a session without a project has its own entry; the one-time import never replaces what is there.
    @Test func theCatalogRemembersWhatEachProjectUsedLastFromStartsAndLiveChanges() async throws {
        let (root, catalog) = try catalog()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await catalog.addProject(path: folder.path).project.id
        let inProject = ManagedSession(provider: .claude, workingDirectory: root.path)
        let loose = ManagedSession(provider: .claude, workingDirectory: root.path)
        try await catalog.insertSession(inProject, projectID: project)
        try await catalog.insertSession(loose)
        #expect(try await catalog.lastUsedLaunchChoices().isEmpty)

        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "plan", model: "haiku"), sessionID: inProject.id)
        // A live change later in the same session: the mode changes, the model stays.
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(permissionMode: "acceptEdits"), sessionID: inProject.id)
        try await catalog.recordLaunchChoices(
            ClaudeLaunchChoices(permissionMode: ClaudePermissionMode.fullAccess.rawValue, effort: "high"), sessionID: inProject.id)
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(model: "opus"), sessionID: loose.id)
        let all = try await catalog.lastUsedLaunchChoices()
        #expect(all[project.uuidString] == ClaudeLaunchChoices(permissionMode: "acceptEdits", model: "haiku", effort: "high"))
        #expect(all[SessionCatalog.noProjectKey] == ClaudeLaunchChoices(model: "opus"))
        // A session the catalog does not have remembers nothing.
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(model: "sonnet"), sessionID: UUID())
        #expect(try await catalog.lastUsedLaunchChoices() == all)

        // The import fills a project the catalog knows nothing about and leaves the others.
        let other = UUID().uuidString
        let imported = try await catalog.importLastUsedLaunchChoices([
            project.uuidString: ClaudeLaunchChoices(permissionMode: "plan"),
            other: ClaudeLaunchChoices(permissionMode: ClaudePermissionMode.fullAccess.rawValue, model: "sonnet"),
        ])
        #expect(imported == 1)
        let after = try await catalog.lastUsedLaunchChoices()
        #expect(after[project.uuidString] == all[project.uuidString])
        #expect(after[other] == ClaudeLaunchChoices(model: "sonnet"), "Full access is not imported either")
    }

    /// D11: a model recorded early can be taken back to none (D7).
    @Test func aRecordedModelCanBeSetBackToNone() async throws {
        let (root, catalog) = try catalog()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        try await catalog.insertSession(session)
        try await catalog.recordLaunchChoices(ClaudeLaunchChoices(model: "opus"), sessionID: session.id)
        try await catalog.setLaunchModel(nil, sessionID: session.id)
        #expect(try await catalog.launchChoices(sessionID: session.id).model == nil)
    }

    /// D15: the pause between looks starts at 1 ms and doubles up to 25 ms.
    @Test func thePauseBetweenLooksGrowsToACeiling() {
        var backoff = PollBackoff()
        let pauses = (0..<8).map { _ in backoff.next() }
        #expect(pauses == [.milliseconds(1), .milliseconds(2), .milliseconds(4), .milliseconds(8), .milliseconds(16),
                           .milliseconds(25), .milliseconds(25), .milliseconds(25)])
        // About 7.9 s of waiting costs a few hundred looks, not thousands.
        var total = Duration.zero
        var looks = 0
        var fresh = PollBackoff()
        while total < .seconds(7.9) { total += fresh.next(); looks += 1 }
        #expect(looks < 400, "\(looks)")
    }
}
