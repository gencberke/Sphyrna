import Foundation
import Testing
@testable import LoomCore

/// R2: the session directory, on a temporary catalog and hub. Nothing here starts a run or touches a real profile.
@Suite(.serialized)
struct SessionDirectoryTests {
    struct World {
        let root: URL
        let catalog: SessionCatalog
        let hub: SessionEventHub
        let directory: SessionDirectory
    }

    private func makeWorld(openRequests: @escaping @Sendable () async -> [OpenSessionRequest] = { [] }) throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-directory-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let hub = SessionEventHub()
        return World(root: root, catalog: catalog, hub: hub,
                     directory: SessionDirectory(catalog: catalog, events: hub, openRequests: openRequests))
    }

    @discardableResult
    private func add(_ world: World, provider: ManagedSession.Provider = .claude, title: String? = nil, project: UUID? = nil,
                     activity: TimeInterval, lifecycle: SessionLifecycle = .idle, id: UUID = UUID(),
                     sideChatOf parent: UUID? = nil) async throws -> UUID {
        try await world.catalog.insertSession(
            ManagedSession(id: id, provider: provider, workingDirectory: world.root.path), title: title,
            createdAt: Date(timeIntervalSince1970: 1_000), lastUsedAt: Date(timeIntervalSince1970: activity),
            lifecycle: lifecycle, projectID: project, lastActivityAt: Date(timeIntervalSince1970: activity),
            sideChat: parent.map { SideChatLink(parentSessionID: $0, forkedAt: Date(timeIntervalSince1970: 1_500)) })
        return id
    }

    private func project(_ world: World, _ name: String) async throws -> CatalogProject {
        let folder = world.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await world.catalog.addProject(path: folder.path).project
    }

    @Test func listsNewestActivityFirstWithTitleHarnessAndProject() async throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let alpha = try await project(world, "alpha")
        let old = try await add(world, title: "Old", project: alpha.id, activity: 2_000)
        let new = try await add(world, provider: .codex, title: "New", activity: 4_000)
        let untitled = try await add(world, project: alpha.id, activity: 3_000)

        let summaries = try await world.directory.summaries()
        #expect(summaries.map(\.id) == [new, untitled, old])
        #expect(summaries[0] == SessionSummary(
            id: new, harness: .codex, title: "New", projectID: nil, projectName: nil, state: .idle, face: nil,
            lastActivityAt: Date(timeIntervalSince1970: 4_000)))
        #expect(summaries[1].title == nil)
        #expect(summaries[1].projectID == alpha.id)
        #expect(summaries[1].projectName == alpha.name)
    }

    @Test func theLimitDefaultsToTwentyAndIsBoundedToOneHundred() async throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        for index in 0..<130 { try await add(world, activity: 2_000 + Double(index)) }

        #expect(try await world.directory.summaries().count == 20)
        #expect(try await world.directory.summaries(SessionQuery(limit: 5)).count == 5)
        #expect(try await world.directory.summaries(SessionQuery(limit: 1_000)).count == 100)
        #expect(try await world.directory.summaries(SessionQuery(limit: 0)).count == 1)
        #expect(try await world.directory.summaries(SessionQuery(limit: -3)).count == 1)
        // The newest come first.
        let top = try await world.directory.summaries(SessionQuery(limit: 3))
        #expect(top.map(\.lastActivityAt) == [2_129, 2_128, 2_127].map(Date.init(timeIntervalSince1970:)))
    }

    @Test func aProjectQueryListsOnlyThatProject() async throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let alpha = try await project(world, "alpha")
        let beta = try await project(world, "beta")
        let inAlpha = try await add(world, project: alpha.id, activity: 2_000)
        let inBeta = try await add(world, project: beta.id, activity: 3_000)
        let loose = try await add(world, activity: 4_000)

        #expect(try await world.directory.summaries(SessionQuery(project: alpha.id)).map(\.id) == [inAlpha])
        #expect(try await world.directory.summaries(SessionQuery(project: beta.id)).map(\.id) == [inBeta])
        #expect(try await world.directory.summaries().map(\.id) == [loose, inBeta, inAlpha])
    }

    @Test func excludedSessionsAreLeftOutAndTheLimitStillFills() async throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        var ids: [UUID] = []
        for index in 0..<4 { ids.append(try await add(world, activity: 2_000 + Double(index))) }

        let asker = ids[3]
        let result = try await world.directory.summaries(SessionQuery(limit: 2, excluding: [asker]))
        #expect(result.map(\.id) == [ids[2], ids[1]])
        let none = try await world.directory.summaries(SessionQuery(excluding: Set(ids)))
        #expect(none.isEmpty)
    }

    @Test func sideChatsDeletingAndSyntheticSessionsAreNeverListed() async throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let shown = try await add(world, title: "Shown", activity: 2_000)
        _ = try await add(world, title: "Side", activity: 5_000, sideChatOf: shown)
        let deleting = try await add(world, title: "Deleting", activity: 4_000)
        _ = try await add(world, provider: .synthetic, title: "Synthetic", activity: 3_000)
        try await world.catalog.beginDeletion(
            sessionID: deleting,
            plan: CatalogDeletionPlan(provider: .claude, providerIDs: ["x"], configDirectory: nil, workingDirectory: nil))

        #expect(try await world.directory.summaries().map(\.id) == [shown])
    }

    @Test func theFaceComesFromTheRunEndpointOfALiveRun() async throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let terminal = try await add(world, activity: 2_000)
        let chat = try await add(world, activity: 3_000)
        let stopped = try await add(world, activity: 4_000)
        let starting = try await add(world, activity: 5_000)
        let runs = [terminal: UUID(), chat: UUID(), starting: UUID()]
        for (id, run) in runs { await world.hub.publish(sessionID: id, change: .runStarted(run)) }
        await world.hub.publish(sessionID: terminal, change: .runEndpoint(runs[terminal]!, .terminal))
        await world.hub.publish(sessionID: chat, change: .runEndpoint(runs[chat]!, .pipe))
        // A session whose run ended has no face, whatever the catalog remembers of its last one.
        let ended = UUID()
        await world.hub.publish(sessionID: stopped, change: .runStarted(ended))
        await world.hub.publish(sessionID: stopped, change: .runEndpoint(ended, .pipe))
        await world.hub.publish(sessionID: stopped, change: .runEnded(ended, .processExited))

        let faces = Dictionary(uniqueKeysWithValues: try await world.directory.summaries().map { ($0.id, $0.face) })
        #expect(faces[terminal] == .some(.terminal))
        #expect(faces[chat] == .some(.chat))
        #expect(faces[stopped] == .some(nil))
        // A run whose endpoint is not known yet has no face yet.
        #expect(faces[starting] == .some(nil))
    }

    @Test func theStateWordFollowsTheHub() async throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let id = try await add(world, activity: 2_000, lifecycle: .idle)
        func word() async throws -> SessionStateWord { try await world.directory.summaries().first { $0.id == id }!.state }

        #expect(try await word() == .idle)
        let run = UUID()
        await world.hub.publish(sessionID: id, change: .runStarted(run))
        #expect(try await word() == .unknown)
        await world.hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .atPrompt)))
        #expect(try await word() == .ready)
        await world.hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        #expect(try await word() == .working)
        await world.hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .waitingForApproval)))
        #expect(try await word() == .needsApproval)
        await world.hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .waitingForInput)))
        #expect(try await word() == .waiting)
        await world.hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .failed("x"))))
        #expect(try await word() == .failed)
        await world.hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .turnComplete)))
        #expect(try await word() == .finished)
        await world.hub.publish(sessionID: id, change: .issue("trouble"))
        #expect(try await word() == .problem)
        await world.hub.publish(sessionID: id, change: .issue(nil))
        await world.hub.publish(sessionID: id, change: .runEnded(run, .processExited))
        // The finish nobody saw stays visible after the run.
        #expect(try await word() == .finished)
        await world.hub.setViewed(sessionID: id)
        #expect(try await word() == .idle)
    }

    @Test func aRequesterWaitingOnAnOpenRequestNeedsApproval() async throws {
        let box = OpenRequestBox()
        let world = try makeWorld(openRequests: { await box.requests })
        defer { try? FileManager.default.removeItem(at: world.root) }
        let alpha = try await project(world, "alpha")
        let asker = try await add(world, activity: 2_000)
        let run = UUID()
        await world.hub.publish(sessionID: asker, change: .runStarted(run))
        await world.hub.publish(sessionID: asker, change: .status(ProviderWorkState(activity: .working)))
        func word() async throws -> SessionStateWord { try await world.directory.summaries().first { $0.id == asker }!.state }
        func request(_ phase: OpenSessionRequest.Phase) -> OpenSessionRequest {
            OpenSessionRequest(requesterID: asker, projectID: alpha.id, projectName: alpha.name, title: "T", message: "M",
                               phase: phase)
        }

        #expect(try await word() == .working)
        await box.set([request(.waiting)])
        #expect(try await word() == .needsApproval)
        await box.set([request(.starting)])
        #expect(try await word() == .working)
        await box.set([request(.failed("no"))])
        #expect(try await word() == .needsApproval)
    }

    @Test func readingWritesNothingToTheCatalogOrTheHub() async throws {
        let world = try makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root) }
        let id = try await add(world, title: "Keep", activity: 2_000, lifecycle: .active)
        let before = try await world.catalog.session(id: id)
        let frame = await world.hub.snapshot()

        _ = try await world.directory.summaries()
        _ = try await world.directory.summaries(SessionQuery(limit: 1))

        #expect(try await world.catalog.session(id: id) == before)
        let after = await world.hub.snapshot()
        #expect(after.sequence == frame.sequence)
        #expect(after.sessions.isEmpty)
    }

    @Test func summariesRoundTripThroughJSONWithStableWireNames() throws {
        let summary = SessionSummary(
            id: UUID(), harness: .claude, title: nil, projectID: nil, projectName: nil, state: .needsApproval, face: .chat,
            lastActivityAt: Date(timeIntervalSince1970: 7))
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(SessionSummary.self, from: data) == summary)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"needs-approval\""))
        #expect(text.contains("\"chat\""))
        #expect(SessionStateWord.allCases.map(\.rawValue).sorted() == [
            "failed", "finished", "idle", "needs-approval", "problem", "ready", "stale", "stopped", "unknown", "waiting",
            "working",
        ])
    }
}

private actor OpenRequestBox {
    private(set) var requests: [OpenSessionRequest] = []
    func set(_ new: [OpenSessionRequest]) { requests = new }
}
