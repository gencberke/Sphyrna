import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore
import LoomTestSupport

/// D-40: a session asks Loom to open another one. The rig is the real control server, the real
/// coordinator and a real catalog; only the run table and the start itself are stand-ins.
final class OpenRig: @unchecked Sendable {
    let root: URL
    let socketPath: String
    let token = "open-test-token"
    let catalog: SessionCatalog
    let coordinator: OpenSessionCoordinator
    let server: OpenSessionControlServer
    let projectA: CatalogProject
    let projectB: CatalogProject
    /// The live run and the card it was launched on (it asks from project A).
    let runID = UUID()
    let requester: ManagedSession

    static func make(replyDelay: TimeInterval = 5,
                     models: @escaping @Sendable (HarnessID) async -> [ModelCatalogEntry] = { _ in ModelCatalog.claude }) async throws -> OpenRig {
        let root = URL(fileURLWithPath: "/tmp/lo-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var projects: [CatalogProject] = []
        for name in ["alpha", "beta"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projects.append(try await catalog.addProject(path: folder.path).project)
        }
        let requester = ManagedSession(provider: .claude, workingDirectory: projects[0].path)
        try await catalog.insertSession(requester, title: "Planner", projectID: projects[0].id)
        return try OpenRig(
            root: root, catalog: catalog, projects: projects, requester: requester, replyDelay: replyDelay, models: models
        )
    }

    init(root: URL, catalog: SessionCatalog, projects: [CatalogProject],
                 requester: ManagedSession, replyDelay: TimeInterval,
                 models: @escaping @Sendable (HarnessID) async -> [ModelCatalogEntry]) throws {
        self.root = root
        self.catalog = catalog
        projectA = projects[0]
        projectB = projects[1]
        self.requester = requester
        socketPath = root.appendingPathComponent("c.sock").path
        let runID = self.runID, cardID = requester.id
        let coordinator = OpenSessionCoordinator(
            catalog: catalog,
            authorize: { session, run in session == cardID && run == runID ? cardID : nil },
            replyDelay: replyDelay, models: models
        )
        self.coordinator = coordinator
        server = try OpenSessionControlServer(
            socketPath: socketPath, authenticationToken: token
        ) { call in await coordinator.submit(call) }
    }

    func cleanup() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func wire(
        title: String = "Fix the login", project: String? = nil,
        message: String = "Please look at login.", token: String? = nil,
        session: UUID? = nil, run: UUID? = nil
    ) -> OpenSessionWireRequest {
        OpenSessionWireRequest(
            authenticationToken: token ?? self.token, sessionID: session ?? requester.id,
            managedRunID: run ?? runID, title: title, project: project, message: message
        )
    }

    func send(_ request: OpenSessionWireRequest, timeout: TimeInterval = 10) async throws -> OpenSessionReply {
        let path = socketPath
        return try await Task.detached {
            try OpenSessionClient.exchange(request, socketPath: path, replyTimeout: timeout)
        }.value
    }

    /// Sends in the background (the call blocks while the request is pending).
    func sendInBackground(_ request: OpenSessionWireRequest, timeout: TimeInterval = 10) -> Task<OpenSessionReply, any Error> {
        let path = socketPath
        return Task.detached {
            try OpenSessionClient.exchange(request, socketPath: path, replyTimeout: timeout)
        }
    }

    func waitForEntries(_ count: Int) async -> [OpenSessionRequest] {
        for _ in 0..<500 {
            let list = await coordinator.snapshot()
            if list.count == count { return list }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await coordinator.snapshot()
    }
}

/// Records the specs `approve` handed to the start path and answers with a new id.
final class StartRecorder: @unchecked Sendable {
    let lock = NSLock()
    var specs: [OpenSessionSpec] = []
    var failure: (any Error)?
    var recorded: [OpenSessionSpec] { lock.withLock { specs } }

    func start(_ spec: OpenSessionSpec) throws -> UUID {
        try lock.withLock {
            if let failure { throw failure }
            specs.append(spec)
        }
        return UUID()
    }
}
