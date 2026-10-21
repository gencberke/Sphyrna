#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore

/// Live Chat face commands (V16): the model's live-chat actions, for runs on the fake provider (or a real Claude
/// under an isolated profile). Nothing written holds content: `chat-state` records phases, counts and kinds.
///
/// - `live-chat:<on|off>`: Settings → "Sessions run in" (Chat on, Terminal off; Chat is the default since V19).
/// - `continue-in:<session id>:<chat|terminal>` and `cancel-handover:<session id>`: the move the policy banner makes (no menu offers
///   it since D-69) and the way to end its wait.
/// - `chat-start:<project id|none>[:<first message>]`: what the draft's send does (a new Claude session in the face "Sessions run in"
///   names, selected, with the choices the draft resolves for the project); ends when the start has (the card exists or it failed).
/// - `chat-send:<session id>:<text>` and `chat-send-after:<session id>:<text>`: ↵ and ⌘↵.
/// - `chat-interrupt:<session id>`; `chat-stop:<session id>` and `chat-resume:<session id>` are the session's Stop and Resume (the
///   service's), and end when it has released the session's busy state.
/// - `chat-allow:<session id>` and `chat-deny:<session id>`: the oldest waiting request.
/// - `chat-read-now:<session id>`: "Read now" on the newest message the CLI holds unread.
/// - `card:<session id>:<action>`: one action on the session's pinned card, as a click does it (`allow-once`,
///   `allow-session`, `deny[:note]`, `deny-stop[:note]`, `approve-plan:<mode>`, `keep-planning[:feedback]`, `pick:<n>`,
///   `next`, `back`, `submit`, `step:<+1|-1>`, `note:<text>`, `resume`, `open-held`, `expire-folded`); writes `card-ack.json`.
/// - `card-state:<session id>:<label>`: writes `card-state-<label>.json` (counts and kinds, no text).
/// - `chat-view:<session id>:<label>`: writes `chat-view-<label>.json`, the live chat view of that session (counts and
///   kinds of its rows, the live row's label and quiet seconds, notices; no text).
/// - `chat-state:<label>`: writes `chat-state-<label>.json` for the newest Chat session (or the selected one).
/// - `composer-focus|type|clear|attach|paste|mode|model|effort|ring|popover:<session id>[:<text, path or KB>]` and `composer-state:<session id>:<label>`:
///   the session's composer as the user drives it (V17); `composer-state` writes `composer-<label>.json` (kinds and counts).
/// - `side-ask:<session id>:<text>`: the Side tab's composer sends the text (a question to the open side chat, a fork when none is open).
/// - `side-new:<session id>`: the Side tab's "+" (the next question forks again).
/// - `side-state:<session id>:<label>`: writes `side-state-<label>.json`: `{open, busy, notice, closeFailed, chats: [{id,
///   phase, live, waiting, settled, asked}]}`, ids, booleans and the phase word only, no text.
/// Failures are written as `chat-error-<command>.json` with the error's category only.
@MainActor
extension DevelopmentEvidence {
    private static var newestChatSession: UUID?

    /// Waits (at most a minute) for the session's busy state to be released: the end of the service's Stop or resume.
    private static func untilIdle(_ session: UUID, in model: CatalogModel) async {
        let deadline = ContinuousClock.now + .seconds(60)
        while model.busy[session] != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Returns false when `name` is not a Chat command.
    func handleChatCommand(_ name: String, _ argument: String) async -> Bool {
        guard let model = app?.model else { return false }
        func id(_ text: String) -> UUID? { UUID(uuidString: String(text.prefix(36))) }
        func rest(_ text: String) -> String { String(text.dropFirst(37)) }
        func run(_ body: () async throws -> Void) async {
            do { try await body() } catch {
                write("chat-error-\(name)", ["error": LoomLog.category(of: error)])
            }
        }
        switch name {
        case "live-chat": model.setNewSessionFace(argument == "on" ? .chat : .terminal)
        case "continue-in":
            guard let session = id(argument), let target = SessionFace(rawValue: rest(argument)) else { return true }
            // Only the move to the terminal is left (the Chat side of the handover); to Chat is refused.
            guard target == .terminal else {
                write("chat-error-\(name)", ["error": "unsupported"])
                return true
            }
            model.continueIn(.terminal, sessionID: session)
        case "cancel-handover": if let session = id(argument) { model.cancelHandover(sessionID: session) }
        case "chat-start":
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let project = parts.first == "none" ? nil : parts.first.flatMap { UUID(uuidString: $0) }
            guard let intents = model.intents as? any NewSessionIntents else {
                write("chat-error-\(name)", ["error": "unavailable"])
                return true
            }
            // The draft page's send: the face follows Settings → "Sessions run in", and the choices are the ones the draft
            // resolves for the project (with no remembered mode, the explicit `default`). The command ends with the start.
            let launch = NewSessionLaunch(firstMessage: parts.count > 1 ? parts[1] : "",
                                          choices: model.draftStartChoices(projectID: project))
            let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<NewSessionOutcome, Never>) in
                intents.startSession(projectID: project, launch: launch, focus: .session) { continuation.resume(returning: $0) }
            }
            switch outcome {
            case let .started(session): Self.newestChatSession = session
            // The service's failure handler has the error (it is on the banner); the outcome carries none.
            case .failed: write("chat-error-\(name)", ["error": "startFailed"])
            }
        case "chat-send", "chat-send-after":
            guard let session = id(argument) else { return true }
            await run { _ = try await model.sendChatMessage(rest(argument), to: session, afterTurn: name == "chat-send-after") }
        case "chat-interrupt": if let session = id(argument) { await run { try await model.interruptChat(session) } }
        case "chat-stop":
            // The service's Stop, as the session's Stop button asks it; the command ends when the Stop has (busy released).
            guard let session = id(argument) else { return true }
            model.stopConversation(session)
            await Self.untilIdle(session, in: model)
        case "chat-resume":
            guard let session = id(argument) else { return true }
            model.resumeConversation(session)
            await Self.untilIdle(session, in: model)
        case "chat-allow", "chat-deny":
            if let session = id(argument) {
                await run { try await model.answerFirstChatRequest(session, allow: name == "chat-allow") }
            }
        case "chat-read-now": if let session = id(argument) { await run { try await model.readNowChat(session) } }
        case "card":
            guard let session = id(argument) else { return true }
            let done = await model.pinnedCardAction(session, rest(argument))
            write("card-ack", ["done": done])
        case "card-state":
            guard let session = id(argument) else { return true }
            let label = rest(argument).filter { $0.isLetter || $0.isNumber || $0 == "-" }
            write("card-state-\(label)", model.pinnedCardsSummary(session))
        case "chat-view":
            guard let session = id(argument) else { return true }
            let label = rest(argument).filter { $0.isLetter || $0.isNumber || $0 == "-" }
            write("chat-view-\(label)", await model.liveChatViewSummary(session))
        case "chat-state":
            let label = argument.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            guard let session = Self.newestChatSession ?? model.selectedSessionID else {
                write("chat-state-\(label)", ["driver": false])
                return true
            }
            var state = await model.chatSummary(session)
            state["sessionID"] = session.uuidString
            state["route"] = model.detailRouteKind
            write("chat-state-\(label)", state)
        case "side-ask":
            // The field's text, then the composer's send: a question to the open side chat, or a fork when none is open.
            guard let parent = id(argument) else { return true }
            model.setSideComposerText(rest(argument), in: parent)
            await model.submitSideQuestion(in: parent)
        case "side-new": if let parent = id(argument) { model.startNewSideChat(in: parent) }
        case "side-state":
            guard let parent = id(argument) else { return true }
            let label = rest(argument).filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let state = await model.sideTabState(for: parent)
            guard let data = try? JSONEncoder().encode(state),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return true }
            write("side-state-\(label)", object)
        case "composer-focus", "composer-type", "composer-clear", "composer-attach", "composer-paste", "composer-state",
             "composer-mode", "composer-model", "composer-effort", "composer-ring", "composer-folder", "composer-popover":
            // `composer-<command>:<session id>:<label or argument>`; `composer-state` writes `composer-<label>.json`.
            guard let session = id(argument) else { return true }
            let command = String(name.dropFirst("composer-".count))
            let tail = rest(argument)
            let label = command == "state" ? tail.filter { $0.isLetter || $0.isNumber || $0 == "-" } : ""
            var summary = await model.composerEvidence(session: session, command: command, argument: tail)
            if command == "state" {
                if app?.redactsContent == true { summary["menuTitles"] = nil }
                write("composer-\(label)", summary)
            } else {
                write("composer-last-\(command)", summary)
            }
        default: return false
        }
        return true
    }
}
#endif
