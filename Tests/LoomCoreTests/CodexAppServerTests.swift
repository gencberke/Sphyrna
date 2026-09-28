import Foundation
import Testing
@testable import LoomCore

struct CodexAppServerTests {
    @Test func installedSchemaEventsDecodeWithoutRejectingUnknownFields() throws {
        let started = CodexAppServerClient.decodeEvent(
            method: "thread/started",
            params: try value("""
                {
                  "thread": {
                    "id": "thread-one",
                    "cwd": "/tmp/workspace",
                    "originator": "codex-tui",
                    "source": "cli",
                    "ephemeral": false,
                    "futureField": {"nested": true}
                  }
                }
                """)
        )
        #expect(started == .threadStarted(CodexThreadIdentity(
            id: "thread-one", workingDirectory: "/tmp/workspace",
            originator: "codex-tui", source: "cli", ephemeral: false
        )))

        let status = CodexAppServerClient.decodeEvent(
            method: "thread/status/changed",
            params: try value("""
                {
                  "threadId": "thread-one",
                  "status": {
                    "type": "active",
                    "activeFlags": ["waitingOnApproval", "futureFlag"]
                  }
                }
                """)
        )
        #expect(status == .threadStatusChanged(
            threadID: "thread-one",
            status: .active([.waitingOnApproval, .other("futureFlag")])
        ))

        let completed = CodexAppServerClient.decodeEvent(
            method: "turn/completed",
            params: try value("""
                {
                  "threadId": "thread-one",
                  "turn": {
                    "id": "turn-one",
                    "status": "completed",
                    "items": [
                      {"type": "reasoning", "text": "hidden"},
                      {"type": "agentMessage", "phase": "final_answer", "text": "done"}
                    ]
                  }
                }
                """)
        )
        #expect(completed == .turnCompleted(
            threadID: "thread-one", turnID: "turn-one",
            outcome: .completed, lastAssistantMessage: "done"
        ))
        #expect(CodexAppServerClient.decodeEvent(
            method: "future/event", params: .object(["anything": .bool(true)])
        ) == .unknown(method: "future/event"))
    }

    @Test func reducerSeparatesWorkingApprovalFailureAndOldRunEvents() async {
        let firstRun = UUID(), secondRun = UUID()
        let tracker = CodexEventStateTracker(
            threadID: "thread-one", managedRunID: firstRun, after: 10
        )
        let promptTime = Date(timeIntervalSince1970: 100)
        #expect(await tracker.receive(
            .event(sequence: 11, .turnStarted(
                threadID: "thread-one", turnID: "turn-one"
            )), for: firstRun, receivedAt: promptTime
        ) == .applied)
        #expect(await tracker.status().activity == .working)
        #expect(await tracker.status().lastUsedAt == promptTime)

        let request = CodexServerRequest(
            id: .number(7), method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string("thread-one")]),
            threadID: "thread-one", kind: .commandExecution
        )
        #expect(await tracker.receive(
            .request(sequence: 12, request), for: firstRun
        ) == .applied)
        #expect(await tracker.status().activity == .waitingForApproval)
        #expect(await tracker.status().pendingRequestCount == 1)

        await tracker.requestResolved(requestSequence: 12)
        #expect(await tracker.status().activity == .working)
        #expect(await tracker.status().pendingRequestCount == 0)

        #expect(await tracker.receive(
            .request(sequence: 13, request), for: firstRun
        ) == .applied)

        #expect(await tracker.receive(
            .event(sequence: 14, .error(
                threadID: "thread-one", turnID: "turn-one",
                message: "API unavailable", willRetry: false
            )), for: firstRun
        ) == .applied)
        #expect(await tracker.status().activity == .failed("API unavailable"))
        await tracker.requestResolved(requestSequence: 13)
        #expect(await tracker.status().pendingRequestCount == 0)
        #expect(await tracker.status().activity == .failed("API unavailable"))

        await tracker.beginRun(secondRun, after: 20)
        #expect(await tracker.receive(
            .event(sequence: 19, .turnCompleted(
                threadID: "thread-one", turnID: "old-turn",
                outcome: .completed, lastAssistantMessage: "stale"
            )), for: secondRun
        ) == .staleSequence)
        #expect(await tracker.receive(
            .event(sequence: 21, .unknown(method: "future/event")),
            for: secondRun
        ) == .applied)
        #expect(await tracker.status().activity == .unknown)

        #expect(await tracker.refresh(CodexThreadSnapshot(
            threadID: "thread-one", lastTurnID: "turn-two",
            lastTurnStartedAt: Date(timeIntervalSince1970: 200),
            lastTurnOutcome: .completed, lastAssistantMessage: "hydrated"
        ), after: 22) == .applied)
        #expect(await tracker.status().activity == .turnComplete)
        #expect(await tracker.status().lastAssistantMessage == "hydrated")
    }

    @Test func newTUILaunchesAreSerializedAndMatchedByCwd() async throws {
        let matcher = CodexLaunchMatcher()
        let first = await matcher.reserveNewLaunch(
            sessionID: UUID(), managedRunID: UUID(),
            workingDirectory: "/tmp/one", after: 1
        )
        let secondTask = Task {
            await matcher.reserveNewLaunch(
                sessionID: UUID(), managedRunID: UUID(),
                workingDirectory: "/tmp/two", after: 2
            )
        }
        try await Task.sleep(for: .milliseconds(20))

        await matcher.receive(.event(sequence: 2, .threadStarted(CodexThreadIdentity(
            id: "wrong", workingDirectory: "/tmp/two",
            originator: "codex-tui", source: "cli", ephemeral: false
        ))))
        await matcher.receive(.event(sequence: 3, .threadStarted(CodexThreadIdentity(
            id: "thread-one", workingDirectory: "/tmp/one",
            originator: "codex-tui", source: "cli", ephemeral: false
        ))))
        #expect(try await matcher.waitForMatch(first) == "thread-one")

        let second = await secondTask.value
        await matcher.receive(.event(sequence: 4, .threadStarted(CodexThreadIdentity(
            id: "thread-two", workingDirectory: "/tmp/two",
            originator: "codex-tui", source: "cli", ephemeral: false
        ))))
        #expect(try await matcher.waitForMatch(second) == "thread-two")
    }

    @Test func routerMapsNewThreadOnlyWhenItsRunningTUIIsUnambiguous() async {
        let router = CodexSessionRouter()
        let one = CodexRunBinding(
            sessionID: UUID(), managedRunID: UUID(), threadID: "thread-one",
            workingDirectory: "/tmp/shared"
        )
        await router.register(one)
        let newThread = CodexAppServerInbound.event(
            sequence: 5,
            .threadStarted(CodexThreadIdentity(
                id: "thread-new", workingDirectory: "/tmp/shared",
                originator: "loom", source: "vscode", ephemeral: false
            ))
        )
        #expect(await router.route(newThread) == .newConversation(
            previous: one,
            identity: CodexThreadIdentity(
                id: "thread-new", workingDirectory: "/tmp/shared",
                originator: "loom", source: "vscode", ephemeral: false
            )
        ))

        let two = CodexRunBinding(
            sessionID: UUID(), managedRunID: UUID(), threadID: "thread-two",
            workingDirectory: "/tmp/shared"
        )
        await router.register(two)
        guard case let .ambiguous(candidates) = await router.route(newThread) else {
            Issue.record("Same-cwd /new was guessed instead of reported ambiguous")
            return
        }
        #expect(Set(candidates.map(\.threadID)) == ["thread-one", "thread-two"])
    }

    @Test func routerUsesReservationBeforeExistingSameCwdBindings() async throws {
        let matcher = CodexLaunchMatcher()
        let router = CodexSessionRouter(launchMatcher: matcher)
        await router.register(CodexRunBinding(
            sessionID: UUID(), managedRunID: UUID(), threadID: "existing",
            workingDirectory: "/tmp/shared"
        ))
        let sessionID = UUID(), runID = UUID()
        let reservation = await matcher.reserveNewLaunch(
            sessionID: sessionID, managedRunID: runID,
            workingDirectory: "/tmp/shared", after: 3
        )
        let decision = await router.route(.event(
            sequence: 4,
            .threadStarted(CodexThreadIdentity(
                id: "new-launch", workingDirectory: "/tmp/shared",
                originator: "loom", source: "vscode", ephemeral: false
            ))
        ))
        #expect(decision == .initialLaunchMatched(CodexRunBinding(
            sessionID: sessionID, managedRunID: runID,
            threadID: "new-launch", workingDirectory: "/tmp/shared"
        ), sequence: 4))
        #expect(try await matcher.waitForMatch(reservation) == "new-launch")
    }

    private func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}
