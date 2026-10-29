import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

private final class ListOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []
    var stdout: [String] { lock.withLock { out } }
    var stderr: [String] { lock.withLock { err } }
    var output: OpenSessionCommand.Output {
        .init(standardOutput: { [self] line in lock.withLock { out.append(line) } },
              standardError: { [self] line in lock.withLock { err.append(line) } })
    }
}

/// C5a: a session lists the other sessions. The rig is the real control server and coordinator on a temporary catalog and hub
/// with the real socket; only the run table is a stand-in. Nothing starts a run or touches a real profile.
private final class ListRig: @unchecked Sendable {
    let root: URL
    let socketPath: String
    let token = "list-test-token"
    let catalog: SessionCatalog
    let coordinator: OpenSessionCoordinator
    let server: OpenSessionControlServer
    let alpha: CatalogProject
    let beta: CatalogProject
    let runID = UUID()
    let requester: ManagedSession

    /// `inAlpha: false` makes the asking session one without a project.
    static func make(inAlpha: Bool = true) async throws -> ListRig {
        let root = URL(fileURLWithPath: "/tmp/ls-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
        try await catalog.insertSession(requester, title: "Planner", projectID: inAlpha ? projects[0].id : nil,
                                        lastActivityAt: Date(timeIntervalSince1970: 9_000))
        return try ListRig(root: root, catalog: catalog, projects: projects, requester: requester)
    }

    private init(root: URL, catalog: SessionCatalog, projects: [CatalogProject], requester: ManagedSession) throws {
        self.root = root
        self.catalog = catalog
        alpha = projects[0]
        beta = projects[1]
        self.requester = requester
        socketPath = root.appendingPathComponent("c.sock").path
        let runID = self.runID, cardID = requester.id
        let coordinator = OpenSessionCoordinator(
            catalog: catalog, authorize: { session, run in session == cardID && run == runID ? cardID : nil }
        )
        self.coordinator = coordinator
        let directory = SessionDirectory(catalog: catalog, events: SessionEventHub())
        server = try OpenSessionControlServer(
            socketPath: socketPath, authenticationToken: token,
            sessions: { call in await coordinator.listSessions(call, directory: directory) },
            whoAmI: { call in await coordinator.whoAmI(call, directory: directory) }
        ) { call in await coordinator.submit(call) }
    }

    func cleanup() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func add(_ title: String?, project: CatalogProject?, activity: TimeInterval, provider: ManagedSession.Provider = .claude,
             sideChatOf parent: UUID? = nil, openedBy: UUID? = nil) async throws -> UUID {
        let session = ManagedSession(provider: provider, workingDirectory: (project?.path ?? root.path))
        try await catalog.insertSession(
            session, title: title, createdAt: Date(timeIntervalSince1970: 1_000),
            lastUsedAt: Date(timeIntervalSince1970: activity), lifecycle: .idle, projectID: project?.id,
            lastActivityAt: Date(timeIntervalSince1970: activity), openedBy: openedBy,
            sideChat: parent.map { SideChatLink(parentSessionID: $0, forkedAt: Date(timeIntervalSince1970: 1_500)) })
        return session.id
    }

    var environment: [String: String] {
        ["LOOM_CONTROL_SOCKET": socketPath, "LOOM_HOOK_TOKEN": token,
         "LOOM_SESSION_ID": requester.id.uuidString, "LOOM_MANAGED_RUN_ID": runID.uuidString]
    }

    func wire(project: String? = nil, all: Bool = false, limit: Int? = nil, token: String? = nil,
              run: UUID? = nil) -> SessionListWireRequest {
        SessionListWireRequest(authenticationToken: token ?? self.token, sessionID: requester.id,
                               managedRunID: run ?? runID, project: project, all: all, limit: limit)
    }

    func send(_ request: SessionListWireRequest) async throws -> SessionListReply {
        let path = socketPath
        return try await onOwnThread("session-list exchange") { try OpenSessionClient.exchange(request, socketPath: path) }
    }

    func run(_ arguments: [String], environment: [String: String]? = nil) async -> (code: Int32, out: ListOutput) {
        let out = ListOutput()
        let env = environment ?? self.environment
        let code = await onTestThread("open-session command") {
            OpenSessionCommand.run(arguments: arguments, environment: env, readStandardInput: { Data() },
                                   output: out.output, replyTimeout: 10)
        }
        return (code, out)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SessionListTests {
    // MARK: The command's arguments (pure)

    @Test func theArgumentsAreParsedAndBadOnesRefusedBeforeAnythingIsSent() throws {
        let parse = OpenSessionCommand.parseSessions
        #expect(try parse([]) == .init())
        #expect(try parse(["--all", "--json", "--limit", "5"]) == .init(all: true, limit: 5, json: true))
        #expect(try parse(["--project=beta", "--limit=100"]) == .init(project: "beta", limit: 100))
        #expect(try parse(["--project", "  beta "]).project == "beta")
        #expect(try parse(["--help"]).help)
        for bad in [["--limit", "0"], ["--limit", "101"], ["--limit", "-1"], ["--limit", "many"], ["--limit"],
                    ["--project"], ["--project", "  "], ["--all", "--project", "beta"], ["--all", "--all"],
                    ["--json", "--json"], ["--all=yes"], ["--bogus"], ["beta"], ["--limit", "5", "--limit", "6"]] {
            #expect(throws: OpenSessionRejection.self, "\(bad)") { try parse(bad) }
        }
    }

    @Test func badArgumentsExitTwoWithoutSending() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        for arguments in [["sessions", "--limit", "0"], ["sessions", "--all", "--project", "beta"], ["sessions", "--bogus"]] {
            let (code, out) = await rig.run(arguments)
            #expect(code == 2, "\(arguments)")
            #expect(out.stderr.joined().hasPrefix("error: ") && out.stderr.joined().contains("usage: \"$SPHYRNA_CLI\" sessions"))
            #expect(out.stdout.isEmpty)
        }
    }

    @Test func helpListsBothCommandsAndEachCommandHasItsOwn() async throws {
        for arguments in [["--help"], ["-h"], ["help"]] {
            let out = ListOutput()
            let code = OpenSessionCommand.run(arguments: arguments, environment: [:], readStandardInput: { Data() },
                                              output: out.output)
            let text = out.stdout.joined()
            #expect(code == 0 && text.contains("usage: \"$SPHYRNA_CLI\" open --title") && text.contains("usage: \"$SPHYRNA_CLI\" sessions"))
        }
        let sessions = ListOutput()
        #expect(OpenSessionCommand.run(arguments: ["sessions", "--help"], environment: [:], readStandardInput: { Data() },
                                       output: sessions.output) == 0)
        #expect(sessions.stdout == [OpenSessionCommand.sessionsUsage])
        let unknown = ListOutput()
        #expect(OpenSessionCommand.run(arguments: ["frobnicate"], environment: [:], readStandardInput: { Data() },
                                       output: unknown.output) == 2)
        #expect(unknown.stderr.joined().contains("sessions"))
        for text in [OpenSessionCommand.usage, OpenSessionCommand.sessionsUsage] {
            #expect(text.contains("Sphyrna") && !text.contains("Loom"), "the agent reads Sphyrna")
        }
    }

    @Test func outsideSphyrnaOrWithoutAnAnswerTheCommandExitsThree() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        let bare = await rig.run(["sessions"], environment: [:])
        #expect(bare.code == 3 && bare.out.stdout.first?.hasPrefix("error: not running inside a Sphyrna session") == true)

        var gone = rig.environment
        gone["LOOM_CONTROL_SOCKET"] = rig.root.appendingPathComponent("nobody.sock").path
        #expect(await rig.run(["sessions"], environment: gone).code == 3)

        var wrong = rig.environment
        wrong["LOOM_HOOK_TOKEN"] = "someone else"
        let refused = await rig.run(["sessions"], environment: wrong)
        #expect(refused.code == 3 && refused.out.stdout.first?.hasPrefix("error: ") == true)
        #expect(!refused.out.stdout.joined().contains("Planner"), "a refused request learns nothing")

        var stale = rig.environment
        stale["LOOM_MANAGED_RUN_ID"] = UUID().uuidString
        #expect(await rig.run(["sessions"], environment: stale).code == 3, "a run Sphyrna does not know")
    }

    // MARK: Scope

    @discardableResult
    private func fill(_ rig: ListRig) async throws -> (a1: UUID, a2: UUID, b1: UUID, n1: UUID, side: UUID) {
        let a1 = try await rig.add("Older in alpha", project: rig.alpha, activity: 2_000)
        let a2 = try await rig.add("Newer in alpha", project: rig.alpha, activity: 3_000, provider: .codex)
        let b1 = try await rig.add("In beta", project: rig.beta, activity: 4_000)
        let n1 = try await rig.add(nil, project: nil, activity: 5_000)
        let side = try await rig.add("A side chat", project: rig.alpha, activity: 8_000, sideChatOf: a1)
        return (a1, a2, b1, n1, side)
    }

    @Test func theDefaultIsTheRequestersProjectWithoutTheRequesterOrSideChats() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        let ids = try await fill(rig)

        let reply = try await rig.send(rig.wire())
        #expect(reply.status == .ok && !reply.truncated)
        #expect(reply.sessions.map(\.id) == [ids.a2, ids.a1], "newest first; not the requester (activity 9000), not the side chat")
        #expect(reply.sessions.allSatisfy { $0.projectName == "alpha" })
        #expect(reply.sessions[0].harness == .codex && reply.sessions[0].state == .idle && reply.sessions[0].face == nil)
        #expect(reply.sessions[0].lastActivityAt == Date(timeIntervalSince1970: 3_000))
    }

    @Test func aProjectByNameOrPathAndAllWidenTheScope() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        let ids = try await fill(rig)

        let byName = try await rig.send(rig.wire(project: "beta"))
        #expect(byName.sessions.map(\.id) == [ids.b1])
        let byPath = try await rig.send(rig.wire(project: rig.beta.path))
        #expect(byPath.sessions.map(\.id) == [ids.b1])

        let all = try await rig.send(rig.wire(all: true))
        #expect(all.status == .ok)
        #expect(all.sessions.map(\.id) == [ids.n1, ids.b1, ids.a2, ids.a1], "every project and the one without; still not the requester or the side chat")
        #expect(all.sessions.first?.projectName == nil && all.sessions.first?.title == nil)

        let unknown = try await rig.send(rig.wire(project: "nope"))
        #expect(unknown.status == .invalid && unknown.sessions.isEmpty)
        #expect(unknown.detail?.hasPrefix("no Sphyrna project is named or located at \"nope\"") == true)
        let both = try await rig.send(rig.wire(project: "beta", all: true))
        #expect(both.status == .invalid)
    }

    @Test func aSessionWithoutAProjectMustSayAllOrAProject() async throws {
        let rig = try await ListRig.make(inAlpha: false)
        defer { rig.cleanup() }
        let ids = try await fill(rig)

        let plain = await rig.run(["sessions"])
        #expect(plain.code == 2)
        #expect(plain.out.stdout.first?.contains("--all") == true && plain.out.stdout.first?.contains("--project") == true)
        let all = try await rig.send(rig.wire(all: true))
        #expect(all.sessions.map(\.id) == [ids.n1, ids.b1, ids.a2, ids.a1])
        let named = try await rig.send(rig.wire(project: "alpha"))
        #expect(named.sessions.map(\.id) == [ids.a2, ids.a1])
    }

    @Test func theLimitDefaultsToTwentyAndStopsAtOneHundred() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        for index in 0..<110 { try await rig.add("s\(index)", project: rig.alpha, activity: 2_000 + Double(index)) }

        let byDefault = try await rig.send(rig.wire())
        #expect(byDefault.sessions.count == 20)
        #expect(byDefault.sessions.first?.title == "s109", "the newest first")
        #expect(try await rig.send(rig.wire(limit: 3)).sessions.count == 3)
        #expect(try await rig.send(rig.wire(limit: 100)).sessions.count == 100)
        for bad in [0, 101, -4] {
            let reply = try await rig.send(rig.wire(limit: bad))
            #expect(reply.status == .invalid, "limit \(bad)")
        }
        let command = await rig.run(["sessions", "--limit", "2", "--json"])
        let decoded = try SessionListCoding.decoder().decode([SessionSummary].self, from: Data(command.out.stdout.joined().utf8))
        #expect(command.code == 0 && decoded.map(\.title) == ["s109", "s108"])
    }

    // MARK: Output

    @Test func theTableHasAHeaderAndOneTabSeparatedLinePerSession() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        let quoted = try await rig.add("Say \"hi\"\tand \\ go\nnow", project: rig.alpha, activity: 3_000)
        let untitled = try await rig.add(nil, project: nil, activity: 2_000)

        let all = await rig.run(["sessions", "--all"])
        #expect(all.code == 0 && all.out.stderr.isEmpty)
        let lines = all.out.stdout.joined().components(separatedBy: "\n")
        #expect(lines[0] == "id\tstate\tharness\tface\tlast-activity\tproject\ttitle\topened-by")
        #expect(lines.count == 3)
        #expect(lines[1] == "\(quoted.uuidString.lowercased())\tidle\tclaude\t-\t1970-01-01T00:50:00Z\talpha\t\"Say \\\"hi\\\" and \\\\ go now\"\t-")
        #expect(lines[2] == "\(untitled.uuidString.lowercased())\tidle\tclaude\t-\t1970-01-01T00:33:20Z\t-\t\"\"\t-")

        let none = await rig.run(["sessions", "--project", "beta"])
        #expect(none.code == 0 && none.out.stdout == ["id\tstate\tharness\tface\tlast-activity\tproject\ttitle\topened-by"])
    }

    @Test func jsonIsAnArrayOfTheSummariesAndHoldsNoContent() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        let ids = try await fill(rig)

        let result = await rig.run(["sessions", "--json", "--project", "alpha"])
        #expect(result.code == 0)
        let data = Data(result.out.stdout.joined().utf8)
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.count == 2)
        #expect(Set(objects[0].keys) == ["id", "harness", "title", "projectID", "projectName", "state", "lastActivityAt"])
        #expect(objects[0]["id"] as? String == ids.a2.uuidString)
        #expect(objects[0]["state"] as? String == "idle" && objects[0]["lastActivityAt"] as? String == "1970-01-01T00:50:00Z")
        let decoded = try SessionListCoding.decoder().decode([SessionSummary].self, from: data)
        #expect(decoded.map(\.id) == [ids.a2, ids.a1])
    }

    @Test func whoAmIPrintsThisSessionItsOpenerAndTheSessionsItOpened() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        let child = try await rig.add("Child", project: rig.alpha, activity: 2_000, openedBy: rig.requester.id)

        let table = await rig.run(["whoami"])
        #expect(table.code == 0 && table.out.stderr.isEmpty)
        let text = table.out.stdout.joined(separator: "\n")
        #expect(text.contains("id: \(rig.requester.id.uuidString.lowercased())"))
        #expect(text.contains("project: alpha") && text.contains("title: \"Planner\""))
        #expect(text.contains("opened-by: -"))
        #expect(text.contains("opened: \(child.uuidString.lowercased()) idle \"Child\""))

        let json = await rig.run(["whoami", "--json"])
        #expect(json.code == 0)
        let decoded = try SessionListCoding.decoder().decode(
            SessionWhoAmI.self, from: Data(json.out.stdout.joined().utf8))
        #expect(decoded.session.id == rig.requester.id && decoded.opener == nil)
        #expect(decoded.opened.map(\.id) == [child])
        #expect(decoded.opened.first?.openedBy == rig.requester.id)
        #expect(decoded.opened.first?.projectName == "alpha" && decoded.opened.first?.state == .idle)

        // `sessions` names the opener in its own column, and `--json` carries it.
        let sessions = await rig.run(["sessions", "--project", "alpha"])
        #expect(sessions.out.stdout.joined(separator: "\n").contains("\t\"Child\"\t\(rig.requester.id.uuidString.lowercased())"))
        let listJSON = await rig.run(["sessions", "--project", "alpha", "--json"])
        let listed = try SessionListCoding.decoder().decode(
            [SessionSummary].self, from: Data(listJSON.out.stdout.joined().utf8))
        #expect(listed.first { $0.id == child }?.openedBy == rig.requester.id)

        let bad = await rig.run(["whoami", "--bogus"])
        #expect(bad.code == 2 && bad.out.stderr.joined().contains("usage: \"$SPHYRNA_CLI\" whoami"))
    }

    @Test func aListTooLargeForOneAnswerIsCutAndSaysSo() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        let long = String(repeating: "t", count: 2_000)
        for index in 0..<100 { try await rig.add("\(index) \(long)", project: rig.alpha, activity: 2_000 + Double(index)) }

        let reply = try await rig.send(rig.wire(limit: 100))
        #expect(reply.status == .ok && reply.truncated)
        #expect(reply.sessions.count > 20 && reply.sessions.count < 100, "\(reply.sessions.count)")
        #expect(try SessionListCoding.encoder().encode(reply).count <= 64 * 1024)
        #expect(reply.sessions.first?.title?.hasPrefix("99 ") == true, "the newest are kept")

        let command = await rig.run(["sessions", "--limit", "100"])
        #expect(command.code == 0)
        #expect(command.out.stderr.first?.hasPrefix("note: the list was cut at \(reply.sessions.count) sessions") == true)
        #expect(command.out.stdout.joined().components(separatedBy: "\n").count == reply.sessions.count + 1)
    }

    // MARK: The socket's other requests

    @Test func aWrongTokenOrUnknownRunIsRefusedAndAMalformedRequestIsInvalid() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        try await fill(rig)

        let wrongToken = try await rig.send(rig.wire(token: "nope"))
        #expect(wrongToken.status == .unavailable && wrongToken.sessions.isEmpty)
        let unknownRun = try await rig.send(rig.wire(run: UUID()))
        #expect(unknownRun.status == .unavailable && unknownRun.sessions.isEmpty)

        // Version 2 with another command, and a version nobody knows.
        let path = rig.socketPath
        for body in [#"{"version":2,"command":"frobnicate"}"#, #"{"version":3}"#, "not json"] {
            let reply = try await onOwnThread("open-session exchange") {
                try OpenSessionClient.exchange(raw: Data(body.utf8), socketPath: path)
            }
            #expect(reply.status == .invalid && reply.detail == "the request is malformed", "\(body)")
        }
    }

    @Test func aVersionOneOpenRequestIsStillAnsweredAsBefore() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        let path = rig.socketPath
        func open(_ project: String?, token: String? = nil) -> OpenSessionWireRequest {
            OpenSessionWireRequest(authenticationToken: token ?? rig.token, sessionID: rig.requester.id,
                                   managedRunID: rig.runID, title: "Fix", project: project, message: "go")
        }
        let unknownRequest = open("nope")
        let unknown = try await onOwnThread("open-session exchange") {
            try OpenSessionClient.exchange(unknownRequest, socketPath: path)
        }
        #expect(unknown.status == .invalid && unknown.line.hasPrefix("error: no Sphyrna project"))
        let wrongRequest = open(nil, token: "x")
        let wrong = try await onOwnThread("open-session exchange") {
            try OpenSessionClient.exchange(wrongRequest, socketPath: path)
        }
        #expect(wrong.status == .unavailable)

        let pendingRequest = open(nil)
        let pending = Task {
            try await onOwnThread("open-session exchange") { try OpenSessionClient.exchange(pendingRequest, socketPath: path) }
        }
        var entries: [OpenSessionRequest] = []
        for _ in 0..<500 where entries.isEmpty {
            entries = await rig.coordinator.snapshot()
            try? await Task.sleep(for: .milliseconds(10))
        }
        let entry = try #require(entries.first)
        #expect(entry.title == "Fix" && entry.projectID == rig.alpha.id)
        let started = try await rig.coordinator.approve(entry.id, start: StartRecorder().start)
        let reply = try await pending.value
        #expect(reply.status == .started && reply.sessionID == started)
    }

    // MARK: The helper binary

    @Test func theHelperBinaryListsOverTheSocket() async throws {
        let rig = try await ListRig.make()
        defer { rig.cleanup() }
        let ids = try await fill(rig)
        let helper = Products.directory.appendingPathComponent("loom-hook")
        let process = Process()
        process.executableURL = helper
        process.arguments = ["sessions", "--project", "alpha"]
        process.environment = rig.environment
        process.standardInput = Pipe()
        let result = try await runToEnd(process)
        #expect(result.status == 0)
        let lines = result.outputText.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3 && lines[1].hasPrefix(ids.a2.uuidString.lowercased()) && lines[2].hasPrefix(ids.a1.uuidString.lowercased()))
    }
}
