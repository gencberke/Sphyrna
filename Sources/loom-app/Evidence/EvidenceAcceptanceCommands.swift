#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore

/// Live acceptance commands (r9 acc): the draft's choices, managed child tasks and the Changes tab, driven through the same
/// model and runtime calls the chips, the managed agent's permission card and the Changes footer make. Reports hold ids,
/// counts, settings words and states only, never a message, a result payload, a path or a comment's text.
///
/// - `draft-choice:<project id|none>:<harness>:<model|->:<effort|->:<mode|->`: the draft's model chip (switching harness when
///   the model is another harness's), effort and mode; writes `ack-draft-choice.json` with the choices the draft resolves.
/// - `task-state:<label>`: `task-state-<label>.json`, every task (up to 50): its projection (ids, harness, requested and
///   effective settings, parent and child bindings with the provider-native session id and run id, lifecycle, counters,
///   active/pending round), its rounds (id, ordinal, phase, native turn id, execution kind), its latest events (id, round,
///   kind, native turn id, payload bytes) and the managed child's presentation (status, permission occurrence ids, binding,
///   effective settings, progress row count, Take Over offered).
/// - `task-allow:<child session id>`, `task-deny:<child session id>`: the managed child's oldest permission card, Allow or Deny
///   (`SessionService.respondManagedTask`'s runtime call); writes `ack-task-answer.json` with the outcome.
/// - `changes-scope:<session id>:<lastTurn|wholeSession|branch>`, `changes-comment:<session id>:<file index>:<text>`,
///   `changes-send:<session id>`, `changes-state:<session id>:<label>` (`changes-state-<label>.json`).
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not one of these commands.
    func handleAcceptanceCommand(_ name: String, _ argument: String) async -> Bool {
        guard let app, let model = app.model else { return false }
        func id(_ text: String) -> UUID? { UUID(uuidString: String(text.prefix(36))) }
        func rest(_ text: String) -> String { String(text.dropFirst(37)) }
        func label(_ text: String) -> String { text.filter { $0.isLetter || $0.isNumber || $0 == "-" } }
        switch name {
        case "draft-choice":
            let parts = argument.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5 else { return false }
            let project: UUID? = parts[0] == "none" ? nil : UUID(uuidString: parts[0])
            func value(_ text: String) -> String? { text == "-" || text.isEmpty ? nil : text }
            let choices = model.setDraftChoicesForEvidence(harness: HarnessID(rawValue: parts[1]), model: value(parts[2]),
                effort: value(parts[3]), mode: value(parts[4]), projectID: project)
            write("ack-draft-choice", ["harness": choices.harness.rawValue, "model": choices.model ?? NSNull(),
                                       "effort": choices.effort ?? NSNull(), "mode": choices.mode?.rawValue ?? NSNull()])
        case "task-state":
            let state = await taskEvidence(runtime: app.runtime)
            write("task-state-\(label(argument))", state)
        case "task-allow", "task-deny":
            guard let child = id(argument) else { return false }
            write("ack-task-answer", await answerManagedPermission(child: child, allow: name == "task-allow",
                                                                    runtime: app.runtime))
        case "changes-scope":
            guard let session = id(argument) else { return false }
            write("ack-changes-scope", ["ok": model.setChangesScopeForEvidence(rest(argument), for: session)])
        case "changes-comment":
            guard let session = id(argument) else { return false }
            let tail = rest(argument)
            guard let colon = tail.firstIndex(of: ":"), let index = Int(tail[..<colon]) else { return false }
            let added = model.addChangeCommentForEvidence(fileIndex: index, text: String(tail[tail.index(after: colon)...]),
                                                          in: session)
            write("ack-changes-comment", ["ok": added, "fileIndex": index])
        case "changes-send":
            guard let session = id(argument) else { return false }
            await model.sendChangeCommentsForEvidence(session)
        case "changes-state":
            guard let session = id(argument) else { return false }
            write("changes-state-\(label(rest(argument)))", model.changesStateForEvidence(session))
        default: return false
        }
        return true
    }

    private func answerManagedPermission(child: UUID, allow: Bool, runtime: SessionRuntime?) async -> [String: Any] {
        guard let runtime else { return ["answered": false, "reason": "noRuntime"] }
        do {
            guard let snapshot = try await runtime.managedTaskForChild(sessionID: child),
                  let presentation = snapshot.presentation else { return ["answered": false, "reason": "noPresentation"] }
            guard let occurrence = presentation.permissions.first else { return ["answered": false, "reason": "noPermission"] }
            let run = presentation.run
            let outcome = try await runtime.respondManagedTask(taskID: run.taskID, expectedRunID: run.runID,
                expectedGeneration: run.generation, occurrenceID: occurrence.id, decision: allow ? .allow : .deny)
            return ["answered": true, "occurrenceID": occurrence.id.uuidString, "roundID": occurrence.roundID.uuidString,
                    "outcome": String(describing: outcome)]
        } catch {
            return ["answered": false, "reason": "error", "error": String(describing: error)]
        }
    }

    private func taskEvidence(runtime: SessionRuntime?) async -> [String: Any] {
        guard let runtime else { return ["available": false] }
        do {
            let page = try await runtime.sessionTaskProjections(parentSessionID: nil, after: nil, limit: 50)
            var tasks: [[String: Any]] = []
            for task in page.items {
                var entry = Self.taskEntry(task)
                let rounds = (try? await runtime.sessionTaskRounds(id: task.id)) ?? []
                entry["rounds"] = rounds.map(Self.roundEntry)
                let events = (try? await runtime.sessionTaskLatestEvents(id: task.id, limit: 10)) ?? []
                entry["events"] = events.map(Self.eventEntry)
                let presentation = await runtime.managedTaskPresentation(taskID: task.id)
                entry["presentation"] = presentation.map(Self.presentationEntry) ?? NSNull()
                tasks.append(entry)
            }
            return ["available": true, "tasks": tasks]
        } catch {
            return ["available": false, "error": String(describing: error)]
        }
    }

    private static func optional(_ value: String?) -> Any { value ?? NSNull() }

    private static func bindingEntry(_ value: SessionTaskBinding?) -> Any {
        guard let value else { return NSNull() }
        let entry: [String: Any] = ["sessionID": value.sessionID.uuidString, "nativeSessionID": value.nativeSessionID,
                                    "runID": value.managedRunID.uuidString, "generation": value.generation.uuidString]
        return entry
    }

    /// The reference's kind only (`nativeTurn`, `providerPrompt`, ...), never its value.
    private static func executionKind(_ value: SessionTaskExecutionReference?) -> Any {
        guard let value else { return NSNull() }
        return String(String(describing: value).prefix { $0 != "(" })
    }

    private static func taskEntry(_ task: SessionTaskProjection) -> [String: Any] {
        var entry: [String: Any] = [:]
        entry["id"] = task.id.uuidString
        entry["parent"] = task.parentSessionID.uuidString
        entry["child"] = task.childSessionID.uuidString
        entry["harness"] = task.harness.rawValue
        entry["childNameChars"] = task.childName.count
        let requested: [String: Any] = ["model": optional(task.requestedChoices.model),
            "effort": optional(task.requestedChoices.effort), "mode": optional(task.requestedChoices.mode?.rawValue)]
        entry["requested"] = requested
        let effective: [String: Any] = ["model": optional(task.effectiveModel), "effort": optional(task.effectiveEffort),
                                        "mode": optional(task.effectiveMode?.rawValue)]
        entry["effective"] = effective
        entry["parentBinding"] = bindingEntry(task.parentBinding)
        entry["childBinding"] = bindingEntry(task.childBinding)
        entry["lifecycle"] = task.lifecycle.rawValue
        entry["childInputLimit"] = task.childInputLimit
        entry["childInputsUsed"] = task.childInputsUsed
        entry["parentWakeLimit"] = task.parentWakeLimit
        entry["parentWakesUsed"] = task.parentWakesUsed
        entry["parentWakesConsumed"] = task.parentWakesConsumed
        entry["uncertainChildEffects"] = task.uncertainChildEffects
        entry["uncertainWakeEffects"] = task.uncertainWakeEffects
        entry["activeRoundID"] = optional(task.activeRoundID?.uuidString)
        entry["pendingRoundID"] = optional(task.pendingRoundID?.uuidString)
        entry["revision"] = task.revision
        return entry
    }

    private static func roundEntry(_ round: SessionTaskRound) -> [String: Any] {
        var entry: [String: Any] = [:]
        entry["id"] = round.id.uuidString
        entry["ordinal"] = round.ordinal
        entry["phase"] = round.phase.rawValue
        entry["messageBytes"] = round.message.utf8.count
        entry["nativeTurnID"] = optional(round.nativeTurnID)
        entry["execution"] = executionKind(round.execution)
        entry["binding"] = bindingEntry(round.binding)
        entry["replyTo"] = optional(round.replyToEventID?.uuidString)
        return entry
    }

    private static func eventEntry(_ event: SessionTaskEvent) -> [String: Any] {
        var entry: [String: Any] = [:]
        entry["id"] = event.id.uuidString
        entry["roundID"] = event.roundID.uuidString
        entry["kind"] = event.kind.rawValue
        entry["nativeTurnID"] = optional(event.nativeTurnID)
        entry["execution"] = executionKind(event.observedExecution)
        entry["payloadBytes"] = event.payload.utf8.count
        entry["at"] = event.occurredAt.timeIntervalSince1970
        return entry
    }

    private static func presentationEntry(_ value: ManagedTaskPresentation) -> [String: Any] {
        var entry: [String: Any] = [:]
        entry["status"] = value.status.rawValue
        entry["runID"] = value.run.runID.uuidString
        entry["binding"] = bindingEntry(value.binding)
        let effective: [String: Any] = ["model": optional(value.effectiveSettings?.model),
            "effort": optional(value.effectiveSettings?.effort),
            "permissionMode": optional(value.effectiveSettings?.permissionMode)]
        entry["effective"] = effective
        entry["progressRows"] = value.progress.count
        entry["permissions"] = value.permissions.map { occurrence -> [String: Any] in
            ["id": occurrence.id.uuidString, "roundID": occurrence.roundID.uuidString]
        }
        entry["canTakeOver"] = value.canTakeOver
        return entry
    }
}
#endif
