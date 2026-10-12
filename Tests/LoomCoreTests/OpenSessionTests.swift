import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore

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

    static func make(replyDelay: TimeInterval = 5) async throws -> OpenRig {
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
            root: root, catalog: catalog, projects: projects, requester: requester, replyDelay: replyDelay
        )
    }

    private init(root: URL, catalog: SessionCatalog, projects: [CatalogProject],
                 requester: ManagedSession, replyDelay: TimeInterval) throws {
        self.root = root
        self.catalog = catalog
        projectA = projects[0]
        projectB = projects[1]
        self.requester = requester
        socketPath = root.appendingPathComponent("c.sock").path
        let runID = self.runID, cardID = requester.id
        let box = RunningBox()
        runningBox = box
        let coordinator = OpenSessionCoordinator(
            catalog: catalog,
            authorize: { session, run in session == cardID && run == runID ? cardID : nil },
            isRunning: { box.contains($0) },
            replyDelay: replyDelay
        )
        self.coordinator = coordinator
        server = try OpenSessionControlServer(
            socketPath: socketPath, authenticationToken: token
        ) { call in await coordinator.submit(call) }
    }

    final class RunningBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []
        func contains(_ id: UUID) -> Bool { lock.withLock { ids.contains(id) } }
        func insert(_ id: UUID) { lock.withLock { _ = ids.insert(id) } }
    }
    let runningBox: RunningBox

    func cleanup() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    func wire(
        title: String = "Fix the login", ticket: String? = nil, project: String? = nil,
        message: String = "Please look at login.", token: String? = nil,
        session: UUID? = nil, run: UUID? = nil
    ) -> OpenSessionWireRequest {
        OpenSessionWireRequest(
            authenticationToken: token ?? self.token, sessionID: session ?? requester.id,
            managedRunID: run ?? runID, title: title, ticketKey: ticket, project: project, message: message
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

    /// An existing session of a project, created the way a user's session would be.
    @discardableResult
    func addSession(title: String?, ticket: String? = nil, project: CatalogProject? = nil,
                    running: Bool = false) async throws -> ManagedSession {
        let project = project ?? projectA
        let session = ManagedSession(provider: .claude, workingDirectory: project.path)
        try await catalog.insertSession(
            session, title: title, createdAt: Date(timeIntervalSince1970: Double(Int.random(in: 1_000...9_000))),
            projectID: project.id, ticketKey: ticket
        )
        if running { runningBox.insert(session.id) }
        return session
    }
}

/// Records the specs `approve` handed to the start path and answers with a new id.
final class StartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var specs: [OpenSessionSpec] = []
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

@Suite(.serialized, .timeLimit(.minutes(1)))
struct OpenSessionTests {
    // MARK: Validation

    @Test func inputRulesCoverTitleTicketMessageAndProject() throws {
        func check(_ title: String = "ok", _ ticket: String? = nil, _ project: String? = nil,
                   _ message: String = "go") throws -> OpenSessionInput {
            try OpenSessionInput.validated(title: title, ticketKey: ticket, project: project, message: message)
        }
        #expect(try check("  Fix login  ").title == "Fix login")
        #expect(throws: OpenSessionRejection.self) { try check("   ") }
        #expect(throws: OpenSessionRejection.self) { try check(String(repeating: "t", count: 161)) }
        #expect(try check(String(repeating: "t", count: 160)).title.count == 160)
        #expect(throws: OpenSessionRejection.self) { try check("two\nlines") }

        #expect(try check("ok", "EDDP-412").ticketKey == "EDDP-412")
        #expect(try check("ok", "a_b.c-9").ticketKey == "a_b.c-9")
        #expect(throws: OpenSessionRejection.self) { try check("ok", "") }
        #expect(throws: OpenSessionRejection.self) { try check("ok", "EDDP 412") }
        #expect(throws: OpenSessionRejection.self) { try check("ok", "EDDP/412") }
        #expect(throws: OpenSessionRejection.self) { try check("ok", "İŞ-1") }
        #expect(throws: OpenSessionRejection.self) { try check("ok", String(repeating: "k", count: 41)) }
        #expect(try check("ok", String(repeating: "k", count: 40)).ticketKey?.count == 40)

        #expect(throws: OpenSessionRejection.self) { try check("ok", nil, nil, "  \n ") }
        #expect(throws: OpenSessionRejection.self) { try check("ok", nil, nil, "a\u{0}b") }
        #expect(try check("ok", nil, nil, String(repeating: "m", count: 65_536)).message.utf8.count == 65_536)
        #expect(throws: OpenSessionRejection.self) { try check("ok", nil, nil, String(repeating: "m", count: 65_537)) }
        // The cap counts UTF-8 bytes, not characters.
        #expect(throws: OpenSessionRejection.self) { try check("ok", nil, nil, String(repeating: "ş", count: 32_769)) }
        #expect(throws: OpenSessionRejection.self) { try check("ok", nil, "  ") }
    }

    // MARK: Authentication

    @Test func aRequestIsAcceptedOnlyFromTheLiveRunOfItsCardWithTheRunToken() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let cases: [(String, OpenSessionWireRequest)] = [
            ("wrong token", rig.wire(token: "not-the-token")),
            ("unknown or stale run", rig.wire(run: UUID())),
            ("wrong session", rig.wire(session: UUID())),
        ]
        for (name, request) in cases {
            let reply = try await rig.send(request)
            #expect(reply.status == .unavailable, "\(name)")
            #expect(reply.exitCode == 3, "\(name)")
        }
        #expect(await rig.coordinator.snapshot().isEmpty)
        // The same message from the right run is accepted (and waits for the user).
        let accepted = rig.sendInBackground(rig.wire())
        #expect(await rig.waitForEntries(1).count == 1)
        try await rig.coordinator.deny(try #require(await rig.coordinator.snapshot().first).id)
        #expect(try await accepted.value.status == .denied)
    }

    @Test func malformedAndOversizeRequestsAreRefusedWithoutBecomingRequests() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let path = rig.socketPath
        let garbage = try await Task.detached {
            try OpenSessionClient.exchange(raw: Data("not json".utf8), socketPath: path)
        }.value
        #expect(garbage.status == .invalid)

        // Past the 64 KiB cap by one byte: Loom refuses, whatever the client checked.
        let over = try await rig.send(rig.wire(message: String(repeating: "m", count: 65_537)))
        #expect(over.status == .invalid)
        #expect(over.line.contains("64 KiB"))
        // Exactly at the cap is accepted.
        let at = rig.sendInBackground(rig.wire(message: String(repeating: "m", count: 65_536)))
        let entries = await rig.waitForEntries(1)
        #expect(entries.first?.message.utf8.count == 65_536)
        try await rig.coordinator.deny(try #require(entries.first).id)
        #expect(try await at.value.status == .denied)
    }

    // MARK: Validation, project and the one-pending rule

    @Test func invalidInputIsAnErrorWithTheReasonAndNothingWaits() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        for request in [
            rig.wire(title: "  "), rig.wire(title: String(repeating: "x", count: 161)),
            rig.wire(ticket: "bad key"), rig.wire(message: "   "),
        ] {
            let reply = try await rig.send(request)
            #expect(reply.status == .invalid)
            #expect(reply.exitCode == 2)
            #expect(reply.line.hasPrefix("error: "))
        }
        #expect(await rig.coordinator.snapshot().isEmpty)
    }

    @Test func aSecondRequestFromTheSameSessionIsRefusedWhileOneWaits() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let first = rig.sendInBackground(rig.wire(title: "First"))
        let waiting = await rig.waitForEntries(1)
        let second = try await rig.send(rig.wire(title: "Second"))
        #expect(second.status == .invalid)
        #expect(second.line == "error: a request from this session is already waiting")
        #expect(await rig.coordinator.snapshot().count == 1)

        try await rig.coordinator.deny(try #require(waiting.first).id)
        #expect(try await first.value.status == .denied)
        // Decided: the session may ask again.
        let third = rig.sendInBackground(rig.wire(title: "Third"))
        #expect(await rig.waitForEntries(1).first?.title == "Third")
        try await rig.coordinator.deny(try #require(await rig.coordinator.snapshot().first).id)
        #expect(try await third.value.status == .denied)
    }

    @Test func theProjectIsTheRequestersOrOneNamedByExactNameOrPathAndNeverCreated() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        func projectOf(_ request: OpenSessionWireRequest) async throws -> OpenSessionRequest? {
            let task = rig.sendInBackground(request)
            let entry = await rig.waitForEntries(1).first
            if let entry { try await rig.coordinator.deny(entry.id) }
            _ = try await task.value
            return entry
        }
        #expect(try await projectOf(rig.wire())?.projectID == rig.projectA.id)
        #expect(try await projectOf(rig.wire(project: "beta"))?.projectID == rig.projectB.id)
        #expect(try await projectOf(rig.wire(project: rig.projectB.path))?.projectID == rig.projectB.id)

        for unknown in ["Beta", "gamma", "/tmp"] {
            let reply = try await rig.send(rig.wire(project: unknown))
            #expect(reply.status == .invalid, "\(unknown)")
            #expect(reply.line.contains("alpha, beta"), "the error names the known projects")
        }
        #expect(try await rig.catalog.projects().count == 2, "a request never creates a project")

        // Two projects with one name: the name alone does not choose.
        let twin = rig.root.appendingPathComponent("elsewhere/alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: twin, withIntermediateDirectories: true)
        _ = try await rig.catalog.addProject(path: twin.path)
        let ambiguous = try await rig.send(rig.wire(project: "alpha"))
        #expect(ambiguous.status == .invalid)
        #expect(try await projectOf(rig.wire(project: rig.projectA.path))?.projectID == rig.projectA.id)
    }

    @Test func aSessionOutsideEveryProjectMustNameOne() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let loose = ManagedSession(provider: .claude, workingDirectory: rig.root.path)
        try await rig.catalog.insertSession(loose, title: "Loose")
        let runID = UUID()
        let coordinator = OpenSessionCoordinator(
            catalog: rig.catalog, authorize: { $0 == loose.id && $1 == runID ? loose.id : nil },
            isRunning: { _ in true }
        )
        func call(project: String?) -> OpenSessionCall {
            OpenSessionCall(sessionID: loose.id, managedRunID: runID, title: "T", ticketKey: nil,
                            project: project, message: "m")
        }
        let refused = await coordinator.submit(call(project: nil))
        #expect(refused.status == .invalid)
        #expect(refused.line.contains("--project"))
        let named = Task { await coordinator.submit(call(project: "beta")) }
        for _ in 0..<500 where await coordinator.snapshot().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let entry = try #require(await coordinator.snapshot().first)
        #expect(entry.projectID == rig.projectB.id)
        try await coordinator.deny(entry.id)
        #expect(await named.value.status == .denied)
    }

    // MARK: Ticket lookup

    @Test func aTicketMatchesByKeyOrByTitlePrefixInTheSameProjectOnly() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let byKey = try await rig.addSession(title: "Anything", ticket: "eddp-412")
        let byTitle = try await rig.addSession(title: "ENMUSAIT-7 - Raporlar", ticket: nil)
        let atEnd = try await rig.addSession(title: "ENMUSAIT-8", ticket: nil)
        let turkish = try await rig.addSession(title: "iş-9 İstanbul düzeltmesi", ticket: nil)
        try await rig.addSession(title: "EDDP-4123 something else")
        try await rig.addSession(title: "Fix EDDP-55 login")
        try await rig.addSession(title: "EDDP-1: colon is not a boundary")
        let other = try await rig.addSession(title: "OTHER-1 first", project: rig.projectB)
        let catalog = rig.catalog
        let projectA = rig.projectA.id, projectB = rig.projectB.id

        #expect(try await catalog.session(projectID: projectA, ticket: "EDDP-412")?.session.id == byKey.id)
        #expect(try await catalog.session(projectID: projectA, ticket: "eDdP-412")?.session.id == byKey.id)
        #expect(try await catalog.session(projectID: projectA, ticket: "enmusait-7")?.session.id == byTitle.id)
        #expect(try await catalog.session(projectID: projectA, ticket: "ENMUSAIT-8")?.session.id == atEnd.id)
        #expect(try await catalog.session(projectID: projectA, ticket: "İş-9") == nil, "İ is not ASCII i")
        #expect(try await catalog.session(projectID: projectA, ticket: "iş-9")?.session.id == turkish.id)
        #expect(try await catalog.session(projectID: projectA, ticket: "EDDP-41") == nil)
        #expect(try await catalog.session(projectID: projectA, ticket: "EDDP-4123")?.title == "EDDP-4123 something else")
        #expect(try await catalog.session(projectID: projectA, ticket: "EDDP-55") == nil, "not at the start")
        #expect(try await catalog.session(projectID: projectA, ticket: "EDDP-1") == nil, "a colon is no boundary")
        #expect(try await catalog.session(projectID: projectA, ticket: "OTHER-1") == nil, "another project's ticket")
        #expect(try await catalog.session(projectID: projectB, ticket: "OTHER-1")?.session.id == other.id)
        // LIKE wildcards in a key are not wildcards.
        #expect(try await catalog.session(projectID: projectA, ticket: "ENMUSAIT_%") == nil)
    }

    @Test func theAskingSessionIsNeverItsOwnTicketSessionByTitle() async throws {
        // Real Claude, 12 Oct: asked to start TEST-9, Claude titled the asking session after that prompt, and the
        // lookup answered `exists` with the asking session itself, so nothing could ever open.
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        #expect(try await rig.catalog.recordTerminalTitle(sessionID: rig.requester.id, title: "TEST-9 hello.txt file"))
        let asked = rig.sendInBackground(rig.wire(title: "TEST-9 - create hello.txt", ticket: "TEST-9"))
        for _ in 0..<500 where await rig.coordinator.snapshot().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let entry = try #require(await rig.coordinator.snapshot().first)
        #expect(entry.kind == .open && entry.phase == .waiting)
        try await rig.coordinator.deny(entry.id)
        #expect(try await asked.value.status == .denied)
    }

    @Test func aTicketThatHasASessionIsReportedAtOnceWithoutApprovalAndNothingStarts() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let live = try await rig.addSession(title: "EDDP-412 Fix login", ticket: "EDDP-412", running: true)
        let stopped = try await rig.addSession(title: "ENMUSAIT-7 Raporlar")

        let first = try await rig.send(rig.wire(title: "Another go", ticket: "eddp-412"))
        #expect(first.status == .exists)
        #expect(first.exitCode == 0)
        #expect(first.line == "exists \(live.id.uuidString.lowercased()) \"EDDP-412 Fix login\" running")
        let second = try await rig.send(rig.wire(title: "Again", ticket: "ENMUSAIT-7"))
        #expect(second.line == "exists \(stopped.id.uuidString.lowercased()) \"ENMUSAIT-7 Raporlar\" stopped")

        // The UI is told: one notice per existing session, nothing waits for approval.
        let notices = await rig.coordinator.snapshot()
        #expect(notices.count == 2)
        #expect(notices.allSatisfy { $0.kind == .exists && $0.phase == .waiting })
        #expect(Set(notices.compactMap(\.existingSessionID)) == [live.id, stopped.id])
        #expect(notices.first { $0.existingSessionID == live.id }?.ticketKey == "eddp-412")
        #expect(notices.allSatisfy { $0.requesterID == rig.requester.id && $0.projectID == rig.projectA.id })

        // Asking again replaces the notice instead of stacking it.
        _ = try await rig.send(rig.wire(title: "Once more", ticket: "EDDP-412"))
        #expect(await rig.coordinator.snapshot().count == 2)
        let recorder = StartRecorder()
        await #expect(throws: OpenSessionError.self) {
            _ = try await rig.coordinator.approve(notices[0].id, start: recorder.start)
        }
        #expect(recorder.recorded.isEmpty)
        for notice in await rig.coordinator.snapshot() { try await rig.coordinator.dismiss(notice.id) }
        #expect(await rig.coordinator.snapshot().isEmpty)
    }

    // MARK: Approve, deny and the pending wait

    @Test func approveStartsTheSessionAndAnswersTheWaitingAgent() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let recorder = StartRecorder()
        let reply = rig.sendInBackground(rig.wire(title: "  Fix login  ", ticket: "EDDP-412", message: "Line one\nLine two"))
        let entry = try #require(await rig.waitForEntries(1).first)
        #expect(entry.kind == .open && entry.phase == .waiting)
        #expect(entry.requesterID == rig.requester.id && entry.requesterTitle == "Planner")
        #expect(entry.projectID == rig.projectA.id && entry.projectName == "alpha")
        #expect(entry.title == "Fix login" && entry.ticketKey == "EDDP-412" && entry.message == "Line one\nLine two")
        #expect(recorder.recorded.isEmpty, "nothing starts without an approval call")

        let approval = try await rig.coordinator.approve(entry.id, start: recorder.start)
        guard case let .started(newID) = approval else { Issue.record("not started"); return }
        let spec = try #require(recorder.recorded.first)
        #expect(spec.requesterID == rig.requester.id && spec.projectID == rig.projectA.id)
        #expect(spec.title == "Fix login" && spec.ticketKey == "EDDP-412" && spec.message == "Line one\nLine two")
        let answer = try await reply.value
        #expect(answer.status == .started && answer.sessionID == newID)
        #expect(answer.line == "started \(newID.uuidString.lowercased()) \"Fix login\"")
        #expect(await rig.coordinator.snapshot().isEmpty)
        // The request is spent: the same id cannot start a second session.
        await #expect(throws: OpenSessionError.self) { _ = try await rig.coordinator.approve(entry.id, start: recorder.start) }
        #expect(recorder.recorded.count == 1)
    }

    @Test func denyAnswersDeniedAndStartsNothing() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let recorder = StartRecorder()
        let reply = rig.sendInBackground(rig.wire())
        let entry = try #require(await rig.waitForEntries(1).first)
        try await rig.coordinator.deny(entry.id)
        let answer = try await reply.value
        #expect(answer.status == .denied && answer.exitCode == 1 && answer.line == "denied")
        #expect(await rig.coordinator.snapshot().isEmpty)
        await #expect(throws: OpenSessionError.self) { _ = try await rig.coordinator.approve(entry.id, start: recorder.start) }
        #expect(recorder.recorded.isEmpty)
    }

    @Test func aRequestNobodyDecidesIsAnsweredPendingAndALaterApprovalStillStartsIt() async throws {
        let rig = try await OpenRig.make(replyDelay: 0.3)
        defer { rig.cleanup() }
        let recorder = StartRecorder()
        let answer = try await rig.send(rig.wire(title: "Slow decision", ticket: "SLOW-1"))
        #expect(answer.status == .pending)
        #expect(answer.exitCode == 0)
        #expect(answer.line.hasPrefix("pending: approve or deny it in Loom"))
        #expect(answer.line.contains("lost if Loom quits"))

        // The request is still there, still waiting, and still blocks a second one.
        let kept = try #require(await rig.coordinator.snapshot().first)
        #expect(kept.phase == .waiting)
        #expect(try await rig.send(rig.wire(title: "Second")).status == .invalid)
        #expect(recorder.recorded.isEmpty)

        let approval = try await rig.coordinator.approve(kept.id, start: recorder.start)
        guard case .started = approval else { Issue.record("not started"); return }
        #expect(recorder.recorded.map(\.title) == ["Slow decision"])
        #expect(await rig.coordinator.snapshot().isEmpty)
    }

    @Test func aFailedStartIsReportedOnceAndNeverRunAgain() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let recorder = StartRecorder()
        recorder.failure = SessionRuntimeError.missingDirectory("/gone")
        let reply = rig.sendInBackground(rig.wire())
        let entry = try #require(await rig.waitForEntries(1).first)
        await #expect(throws: SessionRuntimeError.self) { _ = try await rig.coordinator.approve(entry.id, start: recorder.start) }
        let answer = try await reply.value
        #expect(answer.status == .failed && answer.exitCode == 1)
        #expect(answer.line.hasPrefix("error: the session could not be started"))
        let failed = try #require(await rig.coordinator.snapshot().first)
        guard case .failed = failed.phase else { Issue.record("not failed"); return }
        // Spent: another approve is refused (the agent asks again if it still wants the session).
        recorder.failure = nil
        await #expect(throws: OpenSessionError.self) { _ = try await rig.coordinator.approve(entry.id, start: recorder.start) }
        #expect(recorder.recorded.isEmpty)
        try await rig.coordinator.dismiss(entry.id)
        // A busy project (another start in flight) leaves the request waiting for another approve.
        recorder.failure = SessionRuntimeError.alreadyStarting(UUID())
        let next = rig.sendInBackground(rig.wire(title: "Retry later"))
        let retry = try #require(await rig.waitForEntries(1).first)
        await #expect(throws: SessionRuntimeError.self) { _ = try await rig.coordinator.approve(retry.id, start: recorder.start) }
        #expect(await rig.coordinator.snapshot().first?.phase == .waiting)
        recorder.failure = nil
        _ = try await rig.coordinator.approve(retry.id, start: recorder.start)
        #expect(try await next.value.status == .started)
    }

    @Test func approveRechecksTheTicketAndReportsExistsInsteadOfOpeningACopy() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let recorder = StartRecorder()
        let reply = rig.sendInBackground(rig.wire(title: "Fix login", ticket: "EDDP-9"))
        let entry = try #require(await rig.waitForEntries(1).first)
        // Meanwhile the user (or another request) opens a session for the ticket.
        let appeared = try await rig.addSession(title: "EDDP-9 Fix login", ticket: "EDDP-9")
        let approval = try await rig.coordinator.approve(entry.id, start: recorder.start)
        #expect(approval == .exists(appeared.id))
        #expect(recorder.recorded.isEmpty)
        let answer = try await reply.value
        #expect(answer.status == .exists && answer.sessionID == appeared.id)
        let notice = try #require(await rig.coordinator.snapshot().first)
        #expect(notice.kind == .exists && notice.existingSessionID == appeared.id)
    }

    @Test func quittingAnswersEveryWaitingAgentAndDropsTheList() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        let reply = rig.sendInBackground(rig.wire())
        _ = await rig.waitForEntries(1)
        await rig.coordinator.shutdown()
        let answer = try await reply.value
        #expect(answer.status == .unavailable && answer.exitCode == 3)
        #expect(await rig.coordinator.snapshot().isEmpty)
        #expect(try await rig.send(rig.wire()).status == .unavailable)
    }

    @Test func theListIsPublishedToTheUIAsItChanges() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        var updates = await rig.coordinator.updates().makeAsyncIterator()
        #expect(await updates.next()?.isEmpty == true)
        let reply = rig.sendInBackground(rig.wire(title: "Watched"))
        let added = await updates.next()
        #expect(added?.first?.title == "Watched")
        try await rig.coordinator.deny(try #require(added?.first).id)
        #expect(await updates.next()?.isEmpty == true)
        _ = try await reply.value
    }

    // MARK: The control socket

    @Test func theControlSocketLivesNextToTheHookSocketWithOwnerOnlyPermissions() async throws {
        let rig = try await OpenRig.make()
        defer { rig.cleanup() }
        var metadata = stat()
        #expect(lstat(rig.socketPath, &metadata) == 0)
        #expect(metadata.st_mode & 0o777 == 0o600)
        // A second server refuses a path that exists (same rule as the hook socket).
        #expect(throws: ClaudeHookTransportError.self) {
            _ = try OpenSessionControlServer(socketPath: rig.socketPath, authenticationToken: "x") { _ in
                OpenSessionReply(status: .denied)
            }
        }
        // And one too long for sockaddr_un is refused up front.
        let tooLong = rig.root.appendingPathComponent(String(repeating: "x", count: 120) + ".sock").path
        #expect(throws: ClaudeHookTransportError.self) {
            _ = try OpenSessionControlServer(socketPath: tooLong, authenticationToken: "x") { _ in
                OpenSessionReply(status: .denied)
            }
        }
    }
}
