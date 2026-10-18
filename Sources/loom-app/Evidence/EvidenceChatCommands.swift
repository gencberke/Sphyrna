#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore

/// Live Chat face commands (V16): the model's live-chat actions, for runs on the fake provider (or a real Claude
/// under an isolated profile). Nothing written holds content: `chat-state` records phases, counts and kinds.
///
/// - `live-chat:<on|off>`: the Loom-wide switch (`SessionFaces.liveChatEnabled`, off until V19).
/// - `chat-start:<project id|none>[:<first message>]`: a new Claude session in the Chat face, selected.
/// - `chat-send:<session id>:<text>` and `chat-send-after:<session id>:<text>`: ↵ and ⌘↵.
/// - `chat-interrupt:<session id>`, `chat-stop:<session id>`, `chat-resume:<session id>`.
/// - `chat-allow:<session id>` and `chat-deny:<session id>`: the oldest waiting request.
/// - `chat-read-now:<session id>`: "Read now" on the newest message the CLI holds unread.
/// - `chat-view:<session id>:<label>`: writes `chat-view-<label>.json`, the live chat view of that session (counts and
///   kinds of its rows, the live row's label and quiet seconds, notices; no text).
/// - `chat-state:<label>`: writes `chat-state-<label>.json` for the newest Chat session (or the selected one).
/// Failures are written as `chat-error-<command>.json` with the error's category only.
@MainActor
extension DevelopmentEvidence {
    private static var newestChatSession: UUID?

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
        case "live-chat": model.liveChatEnabled = argument == "on"
        case "chat-start":
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            let project = parts.first == "none" ? nil : parts.first.flatMap { UUID(uuidString: $0) }
            await run { Self.newestChatSession = try await model.startChatSession(
                projectID: project, firstMessage: parts.count > 1 ? parts[1] : "") }
        case "chat-send", "chat-send-after":
            guard let session = id(argument) else { return true }
            await run { _ = try await model.sendChatMessage(rest(argument), to: session, afterTurn: name == "chat-send-after") }
        case "chat-interrupt": if let session = id(argument) { await run { try await model.interruptChat(session) } }
        case "chat-stop": if let session = id(argument) { await run { try await model.stopChat(session) } }
        case "chat-resume": if let session = id(argument) { await run { try await model.resumeChat(session) } }
        case "chat-allow", "chat-deny":
            if let session = id(argument) {
                await run { try await model.answerFirstChatRequest(session, allow: name == "chat-allow") }
            }
        case "chat-read-now": if let session = id(argument) { await run { try await model.readNowChat(session) } }
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
        default: return false
        }
        return true
    }
}
#endif
