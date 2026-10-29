import AppKit
import Foundation
import LoomCore
import Observation
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

@MainActor @Observable
private final class ManagedAgentProbe {
    struct Call: Equatable {
        let task: UUID
        let occurrence: UUID
        let decision: ManagedTaskUserDecision
    }
    var presentation: ManagedTaskPresentation
    var calls: [Call] = []
    var takeoverCalls: [ManagedTaskRun] = []
    var next: ManagedTaskWriteOutcome = .submitted
    var holdResponse = false
    var takeoverFails = false
    var holdTakeover = false
    @ObservationIgnored var pending: CheckedContinuation<ManagedTaskWriteOutcome, Never>?
    @ObservationIgnored var takeoverPending: CheckedContinuation<Void, any Error>?

    init(_ presentation: ManagedTaskPresentation) { self.presentation = presentation }

    func respond(_ task: UUID, _ occurrence: UUID, _ decision: ManagedTaskUserDecision) async -> ManagedTaskWriteOutcome {
        calls.append(Call(task: task, occurrence: occurrence, decision: decision))
        if holdResponse { return await withCheckedContinuation { pending = $0 } }
        return next
    }

    func takeOver(_ run: ManagedTaskRun) async throws {
        takeoverCalls.append(run)
        if holdTakeover {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                takeoverPending = continuation
            }
        }
        if takeoverFails { throw Failure() }
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { "The terminal could not be opened." }
    }
}

private struct ManagedAgentHost: View {
    let probe: ManagedAgentProbe
    var body: some View {
        ManagedAgentView(presentation: probe.presentation, taskName: "Dependency review",
                         respond: probe.respond, takeOver: probe.takeOver)
    }
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ManagedAgentViewTests {
    private struct Hosted {
        let probe: ManagedAgentProbe
        let window: NSWindow
        let hosting: NSHostingController<ManagedAgentHost>
    }

    private func run(harness: HarnessID = .claude, model: String? = nil, effort: String? = nil,
                     mode: HarnessMode? = nil) -> ManagedTaskRun {
        ManagedTaskRun(taskID: UUID(), sessionID: UUID(), runID: UUID(), generation: UUID(), workingDirectory: "/fixture",
                       requestedChoices: HarnessLaunchChoices(harness: harness, model: model, effort: effort, mode: mode))
    }

    private func binding(_ run: ManagedTaskRun) -> SessionTaskBinding {
        SessionTaskBinding(sessionID: run.sessionID, nativeSessionID: "native-fixture", managedRunID: run.runID,
                           generation: run.generation)
    }

    private func occurrence(_ run: ManagedTaskRun, id: UUID = UUID(), kind: ProviderPendingRequest.Kind,
                            tool: String, summary: String, note: String? = nil,
                            input: JSONValue = .object([:])) throws -> ManagedTaskPermissionOccurrence {
        try ManagedTaskPermissionOccurrence(id: id, binding: binding(run), taskID: run.taskID, roundID: UUID(),
            operationID: UUID(), nativeRequestID: .string("native-request"),
            request: ProviderPendingRequest(requestID: "fixture-request", toolUseID: nil, kind: kind, toolName: tool,
                                            summary: summary, note: note, arrivedAt: nil), originalInput: input)
    }

    private func snapshot(_ run: ManagedTaskRun, status: SessionTaskNativeStatus = .waitingForUser,
                          settings: ManagedTaskEffectiveSettings? = nil, progress: [ManagedTaskProgress] = [],
                          permissions: [ManagedTaskPermissionOccurrence] = [], canTakeOver: Bool = true) throws -> ManagedTaskPresentation {
        try ManagedTaskPresentation(run: run, binding: binding(run), effectiveSettings: settings, status: status,
                                    progress: progress, permissions: permissions, canTakeOver: canTakeOver)
    }

    private func host(_ snapshot: ManagedTaskPresentation, width: CGFloat = 720, height: CGFloat = 840,
                      appearance: NSAppearance.Name = .darkAqua) async throws -> Hosted {
        enableAccessibilityTree()
        let probe = ManagedAgentProbe(snapshot)
        let hosting = NSHostingController(rootView: ManagedAgentHost(probe: probe))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: width, height: height))
        let hosted = Hosted(probe: probe, window: window, hosting: hosting)
        try await settle(hosted)
        return hosted
    }

    private func settle(_ hosted: Hosted) async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(80))
            hosted.window.contentView?.layoutSubtreeIfNeeded()
            hosted.window.displayIfNeeded()
        }
    }

    private func element(_ id: String, in hosted: Hosted) -> AnyObject? {
        accessibilityElements(in: hosted.hosting.view).first { InkAX.identifier($0) == id }
    }

    private func text(in hosted: Hosted) -> String {
        accessibilityElements(in: hosted.hosting.view).flatMap {
            [InkAX.label($0), InkAX.value($0) ?? "", InkAX.text($0, "accessibilityTitle") ?? ""]
        }.map { String($0.prefix(256)) }.joined(separator: " | ")
    }

    @Test func reportedAndRequestedSettingsAndProgressStayReadOnlyAtNarrowAndWideSizes() async throws {
        let run = run(harness: .codex, model: "requested-model", effort: "high", mode: .askBeforeEdits)
        let settings = ManagedTaskEffectiveSettings(model: "reported-model", effort: nil, permissionMode: "plan")
        let progress = try ManagedTaskProgress(kind: .tool, text: "Inspecting dependencies")
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for width in [CGFloat(320), 720] {
                let hosted = try await host(snapshot(run, status: .working, settings: settings, progress: [progress],
                                                     canTakeOver: false), width: width, appearance: appearance)
                defer { hosted.window.close() }
                let words = text(in: hosted)
                #expect(words.contains("Dependency review") && words.contains("Codex") && words.contains("Working"))
                #expect(words.contains("Model: reported-model") && words.contains("reported"))
                #expect(!words.contains("requested-model"))
                #expect(words.contains("Effort: high") && words.contains("requested"))
                #expect(words.contains("Mode: plan") && words.contains("Inspecting dependencies"))
                let takeOver = try #require(element("managed-takeover", in: hosted))
                #expect(takeOver.isAccessibilityEnabled?() == false)
                #expect(!accessibilityElements(in: hosted.hosting.view).contains { $0.accessibilityRole?() == .textField })
                #expect(!words.contains("Send message") && !words.contains("Terminal"))
                let frame = InkAX.frame(takeOver)
                #expect(frame.width > 0 && frame.width <= width)
                #expect(!hosted.window.isVisible && !hosted.window.isKeyWindow)
            }
        }
    }

    @Test func requestsUseExactOccurrenceAndCoalesceWhileAnActionIsInFlight() async throws {
        let run = run()
        let first = try occurrence(run, kind: .approval, tool: "Bash", summary: "git status", note: "Check the worktree")
        let second = try occurrence(run, kind: .approval, tool: "Write", summary: "Sources/example.swift")
        let hosted = try await host(snapshot(run, permissions: [first, second]))
        defer { hosted.window.close() }
        hosted.probe.holdResponse = true
        let words = text(in: hosted)
        #expect(words.contains("Bash") && words.contains("git status") && words.contains("Check the worktree"))
        #expect(words.contains("Write") && words.contains("Sources/example.swift"))
        #expect(!words.contains("Allow for This Session") && !words.contains("Allow for Session"))
        let allow = try #require(element("managed-allow:\(first.id.uuidString)", in: hosted))
        #expect(InkAX.label(allow) == "Allow Once, Bash")
        _ = allow.accessibilityPerformPress?()
        _ = allow.accessibilityPerformPress?()
        try await settle(hosted)
        #expect(hosted.probe.calls == [.init(task: run.taskID, occurrence: first.id, decision: .allow)])
        #expect(try #require(element("managed-allow:\(first.id.uuidString)", in: hosted)).isAccessibilityEnabled?() == false)
        #expect(try #require(element("managed-takeover", in: hosted)).isAccessibilityEnabled?() == false)
        guard let pending = hosted.probe.pending else { Issue.record("Response did not reach its callback"); return }
        pending.resume(returning: .deferred)
        hosted.probe.pending = nil
        hosted.probe.holdResponse = false
        try await settle(hosted)
        #expect(text(in: hosted).contains("could not be sent"))
        #expect(element("managed-request:\(first.id.uuidString)", in: hosted) != nil)
        #expect(try #require(element("managed-allow:\(first.id.uuidString)", in: hosted)).isAccessibilityEnabled?() == true)
        let deny = try #require(element("managed-deny:\(second.id.uuidString)", in: hosted))
        #expect(InkAX.label(deny) == "Deny, Write")
        #expect(deny.accessibilityPerformPress?() == true)
        try await settle(hosted)
        #expect(hosted.probe.calls.last == .init(task: run.taskID, occurrence: second.id, decision: .deny))
        #expect(hosted.probe.calls.count == 2)
    }

    @Test func replacedAndCancelledCardsCannotDispatchAnEarlierClick() async throws {
        let run = run()
        let old = try occurrence(run, kind: .approval, tool: "Bash", summary: "old command")
        let replacement = try occurrence(run, kind: .approval, tool: "Bash", summary: "new command")
        let hosted = try await host(snapshot(run, permissions: [old]))
        defer { hosted.window.close() }
        let stale = try #require(element("managed-allow:\(old.id.uuidString)", in: hosted))
        hosted.probe.presentation = try snapshot(run, permissions: [replacement])
        try await settle(hosted)
        _ = stale.accessibilityPerformPress?()
        try await settle(hosted)
        #expect(hosted.probe.calls.isEmpty)
        #expect(text(in: hosted).contains("new command") && !text(in: hosted).contains("old command"))
        let current = try #require(element("managed-allow:\(replacement.id.uuidString)", in: hosted))
        #expect(current.accessibilityPerformPress?() == true)
        try await settle(hosted)
        #expect(hosted.probe.calls == [.init(task: run.taskID, occurrence: replacement.id, decision: .allow)])
        let reusedID = try occurrence(run, id: replacement.id, kind: .approval, tool: "Bash", summary: "changed command")
        hosted.probe.presentation = try snapshot(run, permissions: [reusedID])
        try await settle(hosted)
        _ = current.accessibilityPerformPress?()
        try await settle(hosted)
        #expect(hosted.probe.calls.count == 1)
        #expect(try #require(element("managed-allow:\(replacement.id.uuidString)", in: hosted)).isAccessibilityEnabled?() == false)
        #expect(text(in: hosted).contains("This request changed"))
    }

    @Test func responseCoordinatorRejectsAnEarlierOccurrenceTicket() async throws {
        let run = run()
        let old = try occurrence(run, kind: .approval, tool: "Bash", summary: "old command")
        let replacement = try occurrence(run, kind: .approval, tool: "Bash", summary: "new command")
        let actions = ManagedAgentActions()
        var sent: [ManagedAgentProbe.Call] = []
        actions.update(try snapshot(run, permissions: [old]))
        let oldTicket = try #require(actions.ticket(for: old))
        actions.update(try snapshot(run, permissions: [replacement]))
        actions.respond(to: old, ticket: oldTicket, decision: .allow) { task, id, decision in
            sent.append(.init(task: task, occurrence: id, decision: decision))
            return .submitted
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(sent.isEmpty, "a removed occurrence must not reach the runtime callback")
        let current = try #require(actions.ticket(for: replacement))
        actions.respond(to: replacement, ticket: current, decision: .deny) { task, id, decision in
            sent.append(.init(task: task, occurrence: id, decision: decision))
            return .submitted
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(sent == [.init(task: run.taskID, occurrence: replacement.id, decision: .deny)])
    }

    @Test func aStoppedRunCannotReceiveAnOldRequestAction() async throws {
        let run = run()
        let request = try occurrence(run, kind: .approval, tool: "Bash", summary: "run tests")
        let hosted = try await host(snapshot(run, permissions: [request]))
        defer { hosted.window.close() }
        let old = try #require(element("managed-allow:\(request.id.uuidString)", in: hosted))
        hosted.probe.presentation = try snapshot(run, status: .stopped, permissions: [request], canTakeOver: false)
        try await settle(hosted)
        _ = old.accessibilityPerformPress?()
        try await settle(hosted)
        #expect(hosted.probe.calls.isEmpty)
        #expect(try #require(element("managed-allow:\(request.id.uuidString)", in: hosted)).isAccessibilityEnabled?() == false)
        #expect(text(in: hosted).contains("Stopped"))
    }

    @Test func responseCoordinatorRejectsAStoppedRun() async throws {
        let run = run()
        let request = try occurrence(run, kind: .approval, tool: "Bash", summary: "run tests")
        let actions = ManagedAgentActions()
        var sent: [UUID] = []
        actions.update(try snapshot(run, permissions: [request]))
        let ticket = try #require(actions.ticket(for: request))
        actions.update(try snapshot(run, status: .stopped, permissions: [request], canTakeOver: false))
        actions.respond(to: request, ticket: ticket, decision: .allow) { _, id, _ in
            sent.append(id)
            return .submitted
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(sent.isEmpty, "a stopped run must not receive a stale permission response")
    }

    @Test func aResponseInvalidatedBeforeItsCallbackIsNotDispatched() async throws {
        let run = run()
        let request = try occurrence(run, kind: .approval, tool: "Bash", summary: "run tests")
        let actions = ManagedAgentActions()
        var sent: [UUID] = []
        actions.update(try snapshot(run, permissions: [request]))
        let ticket = try #require(actions.ticket(for: request))
        actions.respond(to: request, ticket: ticket, decision: .allow) { _, id, _ in
            sent.append(id)
            return .submitted
        }
        actions.update(try snapshot(run, permissions: []))
        try await Task.sleep(for: .milliseconds(40))
        #expect(sent.isEmpty, "a request removed before dispatch must not reach the callback")
    }

    @Test func stoppedThenResumedDoesNotReviveAnEarlierScheduledResponse() async throws {
        let run = run()
        let request = try occurrence(run, kind: .approval, tool: "Bash", summary: "run tests")
        let actions = ManagedAgentActions()
        var sent: [ManagedTaskUserDecision] = []
        let waiting = try snapshot(run, permissions: [request])
        actions.update(waiting)
        let ticket = try #require(actions.ticket(for: request))
        actions.respond(to: request, ticket: ticket, decision: .allow) { _, _, decision in
            sent.append(decision)
            return .submitted
        }
        actions.update(try snapshot(run, status: .stopped, permissions: [request], canTakeOver: false))
        actions.update(waiting)
        actions.respond(to: request, ticket: ticket, decision: .deny) { _, _, decision in
            sent.append(decision)
            return .submitted
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(sent == [.deny], "only the new explicit action may be sent after the status changes")
    }

    @Test func aDispatchedResponseRetainsItsUnknownOutcomeAcrossAStatusChange() async throws {
        let run = run()
        let request = try occurrence(run, kind: .approval, tool: "Bash", summary: "run tests")
        let waiting = try snapshot(run, permissions: [request])
        let probe = ManagedAgentProbe(waiting)
        probe.holdResponse = true
        let actions = ManagedAgentActions()
        actions.update(waiting)
        let ticket = try #require(actions.ticket(for: request))
        actions.respond(to: request, ticket: ticket, decision: .allow, using: probe.respond)
        try await Task.sleep(for: .milliseconds(40))
        #expect(probe.calls.count == 1)
        actions.update(try snapshot(run, status: .stopped, permissions: [request], canTakeOver: false))
        actions.update(waiting)
        guard let pending = probe.pending else { Issue.record("Response did not reach its callback"); return }
        pending.resume(returning: .unknown)
        probe.pending = nil
        try await Task.sleep(for: .milliseconds(40))
        #expect(!actions.available(request, ticket: ticket))
        #expect(actions.message(for: request.id)?.contains("could not be verified") == true)
        #expect(probe.calls.count == 1)
    }

    private func questions(duplicate: Bool = false) -> JSONValue {
        func option(_ label: String, _ detail: String) -> JSONValue {
            .object(["label": .string(label), "description": .string(detail)])
        }
        return .object(["questions": .array([
            .object(["question": .string("Which database?"), "header": .string("Database"), "multiSelect": .bool(false),
                     "options": .array([option("SQLite", "One file"), option("Postgres", "A server")])]),
            .object(["question": .string(duplicate ? "Which database?" : "Which extras?"), "header": .string("Extras"),
                     "multiSelect": .bool(true), "options": .array([option("Logs", "Log output"), option("Metrics", "Counters")])])
        ])])
    }

    @Test func everyOriginalQuestionNeedsAnExplicitAnswerAndMapsToItsExactKey() async throws {
        let run = run()
        let question = try occurrence(run, kind: .question, tool: "AskUserQuestion", summary: "Database and extras",
                                      input: questions())
        let hosted = try await host(snapshot(run, permissions: [question]))
        defer { hosted.window.close() }
        #expect(text(in: hosted).contains("Which database?") && text(in: hosted).contains("Which extras?"))
        let submitID = "managed-submit:\(question.id.uuidString)"
        #expect(try #require(element(submitID, in: hosted)).isAccessibilityEnabled?() == false)
        let first = try #require(element("managed-option:\(question.id.uuidString):0:0", in: hosted))
        #expect(InkAX.label(first) == "SQLite, Which database?")
        #expect(first.accessibilityPerformPress?() == true)
        try await settle(hosted)
        #expect(try #require(element(submitID, in: hosted)).isAccessibilityEnabled?() == false)
        for option in [0, 1] {
            let button = try #require(element("managed-option:\(question.id.uuidString):1:\(option)", in: hosted))
            #expect(button.accessibilityPerformPress?() == true)
        }
        try await settle(hosted)
        let submit = try #require(element(submitID, in: hosted))
        #expect(submit.isAccessibilityEnabled?() == true && submit.accessibilityPerformPress?() == true)
        try await settle(hosted)
        #expect(hosted.probe.calls == [.init(task: run.taskID, occurrence: question.id,
            decision: .answer(.object(["Which database?": .string("SQLite"), "Which extras?": .string("Logs, Metrics")])) )])
        _ = submit.accessibilityPerformPress?()
        try await settle(hosted)
        #expect(hosted.probe.calls.count == 1)
    }

    @Test func questionDraftDoesNotFollowTheSameOccurrenceIDIntoANewRun() async throws {
        let first = run()
        let replacement = ManagedTaskRun(taskID: first.taskID, sessionID: first.sessionID, runID: UUID(), generation: UUID(),
                                         workingDirectory: first.workingDirectory, requestedChoices: first.requestedChoices)
        let id = UUID()
        let old = try occurrence(first, id: id, kind: .question, tool: "AskUserQuestion", summary: "Database and extras",
                                 input: questions())
        let next = try occurrence(replacement, id: id, kind: .question, tool: "AskUserQuestion", summary: "Database and extras",
                                  input: questions())
        let hosted = try await host(snapshot(first, permissions: [old]))
        defer { hosted.window.close() }
        for (question, option) in [(0, 0), (1, 0)] {
            let button = try #require(element("managed-option:\(id.uuidString):\(question):\(option)", in: hosted))
            #expect(button.accessibilityPerformPress?() == true)
        }
        try await settle(hosted)
        #expect(try #require(element("managed-submit:\(id.uuidString)", in: hosted)).isAccessibilityEnabled?() == true)
        hosted.probe.presentation = try snapshot(replacement, permissions: [next])
        try await settle(hosted)
        #expect(try #require(element("managed-submit:\(id.uuidString)", in: hosted)).isAccessibilityEnabled?() == false)
        #expect(hosted.probe.calls.isEmpty)
    }

    @Test func anExplicitOtherAnswerIsUsedAndOversizedInputIsRejected() async throws {
        let run = run()
        let input = JSONValue.object(["questions": .array([
            .object(["question": .string("What should be checked?"), "options": .array([])])
        ])])
        let question = try occurrence(run, kind: .question, tool: "AskUserQuestion", summary: "A question", input: input)
        let hosted = try await host(snapshot(run, permissions: [question]))
        defer { hosted.window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(hosted.hosting.view)
        let fields = views.compactMap { $0 as? NSTextField }
        let native = try #require(fields.first { $0.placeholderString == "Other answer" } ?? (fields.count == 1 ? fields.first : nil),
                                  "hosted view types: \(views.map { String(describing: type(of: $0)) })")
        let fieldID = "managed-other:\(question.id.uuidString):0"
        let nodes = accessibilityElements(in: hosted.hosting.view)
        let details = nodes.map { "\(String(describing: $0.accessibilityRole?())): \(InkAX.identifier($0)) / \(InkAX.label($0))" }
        let fieldBeforeEditing = try #require(nodes.first { InkAX.identifier($0) == fieldID }, "AX nodes: \(details)")
        #expect(fieldBeforeEditing.accessibilityRole?() == .textField)
        #expect(InkAX.label(fieldBeforeEditing) == "Other answer for What should be checked?")
        #expect(hosted.window.makeFirstResponder(native))
        let editor = try #require(hosted.window.fieldEditor(true, for: native) as? NSTextView)
        func enterText(_ value: String) {
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            editor.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        enterText("Check the tests")
        try await settle(hosted)
        let submitID = "managed-submit:\(question.id.uuidString)"
        #expect(try #require(element(submitID, in: hosted)).isAccessibilityEnabled?() == true)
        enterText(String(repeating: "x", count: 16_385))
        try await settle(hosted)
        #expect(text(in: hosted).contains("too long and was not added"))
        let field = try #require(element(fieldID, in: hosted))
        #expect(editor.string == "Check the tests")
        let preservedAnswer = InkAX.value(field) == "Check the tests"
        #expect(preservedAnswer, "rejected input leaves the existing answer intact")
        #expect(try #require(element(submitID, in: hosted)).isAccessibilityEnabled?() == false)
        enterText("Check the build")
        try await settle(hosted)
        let submit = try #require(element(submitID, in: hosted))
        #expect(submit.accessibilityPerformPress?() == true)
        try await settle(hosted)
        #expect(hosted.probe.calls == [.init(task: run.taskID, occurrence: question.id,
                                             decision: .answer(.object(["What should be checked?": .string("Check the build")])) )])
    }

    @Test func oversizedOtherAnswerIsRejectedWithoutChangingThePreviousValue() {
        var answer = ManagedAnswer()
        answer.editOther("Keep this answer")
        answer.editOther(String(repeating: "x", count: 16_385))
        #expect(answer.other == "Keep this answer" && answer.tooLong)
        answer.editOther("Use this instead")
        #expect(answer.other == "Use this instead" && !answer.tooLong)
    }

    @Test func malformedQuestionsAndPlanApprovalRemainUnavailableHere() async throws {
        let run = run()
        let question = try occurrence(run, kind: .question, tool: "AskUserQuestion", summary: "Duplicate question",
                                      input: questions(duplicate: true))
        let unsupported = try occurrence(run, kind: .question, tool: "OtherInteractive", summary: "Unknown interaction",
                                         input: questions())
        let plan = try occurrence(run, kind: .plan, tool: "ExitPlanMode", summary: "Plan ready",
                                  input: .object(["plan": .string("Inspect the change, then test it.")]))
        let hosted = try await host(snapshot(run, permissions: [question, unsupported, plan]))
        defer { hosted.window.close() }
        let words = text(in: hosted)
        #expect(words.contains("cannot be answered here") && words.contains("Inspect the change, then test it."))
        #expect(element("managed-submit:\(question.id.uuidString)", in: hosted) == nil)
        #expect(element("managed-submit:\(unsupported.id.uuidString)", in: hosted) == nil)
        #expect(element("managed-allow:\(plan.id.uuidString)", in: hosted) == nil)
        let keep = try #require(element("managed-keep-planning:\(plan.id.uuidString)", in: hosted))
        #expect(keep.accessibilityPerformPress?() == true)
        try await settle(hosted)
        #expect(hosted.probe.calls == [.init(task: run.taskID, occurrence: plan.id, decision: .deny)])
    }

    @Test func oversizedQuestionControlsAreNotSilentlyDroppedOrAnswered() async throws {
        let run = run()
        let manyQuestions = JSONValue.object(["questions": .array((0..<9).map { index in
            .object(["question": .string("Question \(index)"), "options": .array([])])
        })])
        let manyOptions = JSONValue.object(["questions": .array([
            .object(["question": .string("Choose one"), "options": .array((0..<17).map { index in
                .object(["label": .string("Option \(index)")])
            })])
        ])])
        let first = try occurrence(run, kind: .question, tool: "AskUserQuestion", summary: "Many questions", input: manyQuestions)
        let hosted = try await host(snapshot(run, permissions: [first]))
        defer { hosted.window.close() }
        for request in [first, try occurrence(run, kind: .question, tool: "AskUserQuestion", summary: "Many options", input: manyOptions)] {
            hosted.probe.presentation = try snapshot(run, permissions: [request])
            try await settle(hosted)
            #expect(text(in: hosted).contains("cannot be answered here"))
            #expect(element("managed-submit:\(request.id.uuidString)", in: hosted) == nil)
            #expect(hosted.probe.calls.isEmpty)
        }
    }

    @Test func takeOverRequiresEligibilityAndKeepsAnErrorVisibleWithoutMountingATerminal() async throws {
        let run = run()
        let request = try occurrence(run, kind: .approval, tool: "Read", summary: "config.yaml")
        let hosted = try await host(snapshot(run, status: .unknown, permissions: [request], canTakeOver: false))
        defer { hosted.window.close() }
        var button = try #require(element("managed-takeover", in: hosted))
        #expect(button.isAccessibilityEnabled?() == false && hosted.probe.takeoverCalls.isEmpty)
        #expect(text(in: hosted).contains("Status unknown"))
        hosted.probe.presentation = try snapshot(run, status: .ready, permissions: [request], canTakeOver: true)
        hosted.probe.takeoverFails = true
        try await settle(hosted)
        #expect(text(in: hosted).contains("Ready") && !text(in: hosted).contains("Finished"))
        button = try #require(element("managed-takeover", in: hosted))
        #expect(button.isAccessibilityEnabled?() == true && button.accessibilityPerformPress?() == true)
        try await settle(hosted)
        #expect(hosted.probe.takeoverCalls == [run])
        #expect(text(in: hosted).contains("The terminal could not be opened."))
        #expect(element("managed-agent-surface", in: hosted) != nil)
        #expect(element("managed-request:\(request.id.uuidString)", in: hosted) != nil)
        #expect(!accessibilityElements(in: hosted.hosting.view).contains { InkAX.identifier($0).contains("terminal-surface") })
    }

    @Test func takeOverDoesNotMoveAReplacementRunThroughAnEarlierButton() async throws {
        let first = run()
        let replacement = ManagedTaskRun(taskID: first.taskID, sessionID: first.sessionID, runID: UUID(), generation: UUID(),
                                         workingDirectory: first.workingDirectory, requestedChoices: first.requestedChoices)
        let hosted = try await host(snapshot(first))
        defer { hosted.window.close() }
        let oldButton = try #require(element("managed-takeover", in: hosted))
        hosted.probe.presentation = try snapshot(replacement)
        try await settle(hosted)
        _ = oldButton.accessibilityPerformPress?()
        try await settle(hosted)
        #expect(hosted.probe.takeoverCalls.isEmpty, "a stale button must not send an old run's transfer")
        let current = try #require(element("managed-takeover", in: hosted))
        #expect(current.accessibilityPerformPress?() == true)
        try await settle(hosted)
        #expect(hosted.probe.takeoverCalls == [replacement])
        #expect(!accessibilityElements(in: hosted.hosting.view).contains { InkAX.identifier($0).contains("terminal-surface") })
    }

    @Test func takeoverCoordinatorRejectsAnEarlierDisplayedRun() async throws {
        let first = run()
        let replacement = ManagedTaskRun(taskID: first.taskID, sessionID: first.sessionID, runID: UUID(), generation: UUID(),
                                         workingDirectory: first.workingDirectory, requestedChoices: first.requestedChoices)
        let before = try snapshot(first), after = try snapshot(replacement)
        let actions = ManagedAgentActions()
        var sent: [ManagedTaskRun] = []
        actions.update(before)
        actions.update(after)
        actions.takeOver(before) { sent.append($0) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(sent.isEmpty, "an old displayed run must not reach the runtime callback")
        actions.takeOver(after) { sent.append($0) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(sent == [replacement])
    }

    @Test func takeoverInvalidatedBeforeItsCallbackIsNotDispatched() async throws {
        let run = run()
        let actions = ManagedAgentActions()
        var sent: [ManagedTaskRun] = []
        let eligible = try snapshot(run, canTakeOver: true)
        actions.update(eligible)
        actions.takeOver(eligible) { sent.append($0) }
        actions.update(try snapshot(run, canTakeOver: false))
        try await Task.sleep(for: .milliseconds(40))
        #expect(sent.isEmpty, "a transfer invalidated before dispatch must not reach the callback")
    }

    @Test func eligibilityReturningDoesNotReviveAnEarlierScheduledTakeOver() async throws {
        let run = run()
        let actions = ManagedAgentActions()
        var sent: [String] = []
        let eligible = try snapshot(run, canTakeOver: true)
        actions.update(eligible)
        actions.takeOver(eligible) { _ in sent.append("old") }
        actions.update(try snapshot(run, canTakeOver: false))
        actions.update(eligible)
        actions.takeOver(eligible) { _ in sent.append("new") }
        try await Task.sleep(for: .milliseconds(40))
        #expect(sent == ["new"], "restored eligibility must not dispatch the earlier action")
    }

    @Test func aDispatchedTakeOverStaysInFlightAcrossAnEligibilityChange() async throws {
        let run = run()
        let eligible = try snapshot(run, canTakeOver: true)
        let probe = ManagedAgentProbe(eligible)
        probe.holdTakeover = true
        let actions = ManagedAgentActions()
        actions.update(eligible)
        actions.takeOver(eligible, using: probe.takeOver)
        try await Task.sleep(for: .milliseconds(40))
        #expect(probe.takeoverCalls == [run])
        actions.update(try snapshot(run, canTakeOver: false))
        actions.update(eligible)
        #expect(!actions.canTakeOver(eligible))
        guard let pending = probe.takeoverPending else { Issue.record("Take Over did not reach its callback"); return }
        pending.resume()
        probe.takeoverPending = nil
        try await Task.sleep(for: .milliseconds(40))
        #expect(!actions.canTakeOver(eligible))
        #expect(actions.takeOverMessage == "Opening the child session…")
        #expect(probe.takeoverCalls == [run])
    }

    @Test func anUnverifiedResponseIsNotReplayedWhileTheOccurrenceRemains() async throws {
        let run = run()
        let request = try occurrence(run, kind: .approval, tool: "Bash", summary: "run tests")
        let hosted = try await host(snapshot(run, permissions: [request]))
        defer { hosted.window.close() }
        hosted.probe.next = .unknown
        let allow = try #require(element("managed-allow:\(request.id.uuidString)", in: hosted))
        #expect(allow.accessibilityPerformPress?() == true)
        try await settle(hosted)
        #expect(text(in: hosted).contains("could not be verified"))
        _ = allow.accessibilityPerformPress?()
        try await settle(hosted)
        #expect(hosted.probe.calls == [.init(task: run.taskID, occurrence: request.id, decision: .allow)])
        #expect(element("managed-request:\(request.id.uuidString)", in: hosted) != nil)
    }

    @Test func emptyUnknownAndStoppedStatesDoNotInventSettingsOrAResult() async throws {
        let run = run(harness: .opencode)
        let hosted = try await host(snapshot(run, status: .notStarted, canTakeOver: false))
        defer { hosted.window.close() }
        for (status, label) in [(SessionTaskNativeStatus.notStarted, "Not started"), (.ready, "Ready"),
                                (.stopped, "Stopped"), (.unknown, "Status unknown")] {
            hosted.probe.presentation = try snapshot(run, status: status, canTakeOver: false)
            try await settle(hosted)
            let words = text(in: hosted)
            #expect(words.contains(label) && words.contains("No progress reported yet."))
            #expect(!words.contains("Model:") && !words.contains("Effort:") && !words.contains("Mode:"))
            #expect(!words.contains("Finished") && !words.contains("Completed"))
        }
    }
}
