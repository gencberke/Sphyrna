import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

/// V22 part 2: deleting around a side chat. A fork is a session of its own to Claude (its own id, its own files); Loom links it to
/// its parent, so deleting the parent deletes the side chats first, each through the verified path, and discarding a side chat
/// never touches the parent's files. Stopped conversations over temp trees; the fake provider is not started.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct SideChatDeletionTests {
    typealias Env = ConversationDeletionTests.Env
    typealias World = ConversationDeletionTests.World

    /// A stopped side chat of `parent` with its own provider id and seeded files.
    @discardableResult
    private func addSideChat(_ world: World, of parent: ManagedSession, projectID: UUID? = nil) async throws -> ManagedSession {
        let session = ManagedSession(provider: .claude, providerConversationID: UUID().uuidString.lowercased(),
                                     workingDirectory: world.env.home.path)
        try await world.supervisor.createSession(
            session, projectID: projectID, sideChat: SideChatLink(parentSessionID: parent.id, forkedAt: Date()))
        try world.env.seed(ConversationDeletionTests.ids(session))
        return session
    }

    private func addParent(_ world: World, projectID: UUID? = nil) async throws -> ManagedSession {
        try await ConversationDeletionTests.addConversation(world, projectID: projectID)
    }

    @Test func deletingAParentDeletesItsSideChatsFirstAndNothingElse() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await ConversationDeletionTests.makeWorld(env)
        let parent = try await addParent(world)
        let first = try await addSideChat(world, of: parent)
        let second = try await addSideChat(world, of: parent)
        let other = try await addParent(world)
        let otherSide = try await addSideChat(world, of: other)
        let ids = ConversationDeletionTests.ids
        let keptBefore = try env.snapshot(of: ids(other) + ids(otherSide))
        #expect(!keptBefore.isEmpty)

        let preview = try await world.runtime.deletionPreview(id: parent.id)
        #expect(preview.sideChatCount == 2)
        #expect(try await world.runtime.deletionPreview(id: other.id).sideChatCount == 1)

        #expect(try await world.runtime.deleteConversation(id: parent.id) == .deleted)
        for gone in [parent, first, second] {
            #expect(try await world.catalog.session(id: gone.id) == nil)
            #expect(await world.supervisor.session(id: gone.id) == nil)
            #expect(try env.snapshot(of: ids(gone)).isEmpty, "files of \(gone.id) remain")
        }
        #expect(try await world.catalog.pendingDeletions().isEmpty)
        // The other conversation and its side chat are exactly as they were.
        #expect(try env.snapshot(of: ids(other) + ids(otherSide)) == keptBefore)
        #expect(try await world.catalog.sideChats(of: other.id).map(\.session.id) == [otherSide.id])
        #expect(try await world.catalog.sessions().map(\.session.id) == [other.id])
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func discardingASideChatLeavesItsParentsFilesAndCardAlone() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await ConversationDeletionTests.makeWorld(env)
        let parent = try await addParent(world)
        let side = try await addSideChat(world, of: parent)
        let ids = ConversationDeletionTests.ids
        let parentBefore = try env.snapshot(of: ids(parent))
        let parentRow = try #require(try await world.catalog.session(id: parent.id))

        #expect(try await world.runtime.discardSideChat(id: side.id) == .deleted)
        #expect(try await world.catalog.session(id: side.id) == nil)
        #expect(try env.snapshot(of: ids(side)).isEmpty)
        #expect(try env.snapshot(of: ids(parent)) == parentBefore)
        #expect(try await world.catalog.session(id: parent.id) == parentRow)
        // Only a side chat can be discarded this way: a main session is not a fork.
        await #expect(throws: (any Error).self) { _ = try await world.runtime.discardSideChat(id: parent.id) }
        #expect(try await world.catalog.session(id: parent.id) != nil)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func removingAParentFromLoomOnlyRemovesItsSideChatsToo() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await ConversationDeletionTests.makeWorld(env)
        let parent = try await addParent(world)
        let side = try await addSideChat(world, of: parent)
        let ids = ConversationDeletionTests.ids

        try await world.runtime.removeFromLoomOnly(id: parent.id)
        #expect(try await world.catalog.session(id: parent.id) == nil)
        #expect(try await world.catalog.session(id: side.id) == nil, "no side chat outlives its parent")
        // Nothing was deleted from Claude's folders: that is what "from Loom only" means.
        #expect(!(try env.snapshot(of: ids(parent))).isEmpty)
        #expect(!(try env.snapshot(of: ids(side))).isEmpty)
        #expect((await world.runtime.shutdown()).succeeded)
    }

    @Test func aProjectIsRemovedOnlyOnceItsSessionsAreGoneAndItsSideChatsGoWithThem() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let world = try await ConversationDeletionTests.makeWorld(env)
        let folder = env.root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await world.catalog.addProject(path: folder.path).project
        let parent = try await addParent(world, projectID: project.id)
        let side = try await addSideChat(world, of: parent, projectID: project.id)

        // A session blocks it, and a refused removal deletes nothing: the side chat belongs to a session that stays.
        func refusedAsNotEmpty(_ body: () async throws -> Void) async -> Bool {
            do { try await body(); return false } catch SessionCatalogError.projectNotEmpty { return true } catch { return false }
        }
        #expect(await refusedAsNotEmpty { try await world.runtime.removeProject(id: project.id) })
        #expect(await refusedAsNotEmpty { try await world.runtime.deleteSideChats(inProject: project.id) })
        #expect(try await world.catalog.session(id: parent.id) != nil)
        #expect(try await world.catalog.session(id: side.id) != nil, "the side chat of a session that stays is kept")

        // The parent's deletion takes its side chat; then the project is empty and goes.
        #expect(try await world.runtime.deleteConversation(id: parent.id) == .deleted)
        #expect(try await world.catalog.session(id: side.id) == nil)
        try await world.runtime.removeProject(id: project.id)
        #expect(try await world.catalog.projects().isEmpty)
        #expect((await world.runtime.shutdown()).succeeded)
    }
}
