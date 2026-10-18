import Foundation
import LoomCore

/// One message of Claude Code's stream-json output (or one control line), typed as far as Loom needs it. A type or
/// subtype that is not listed is `.unknown` and keeps its whole JSON: the set grows, and a new one is never an error.
public enum StreamMessage: Sendable, Equatable {
    case systemInit(SystemInit)
    case streamEvent(StreamEvent)
    case assistant(AssistantMessage)
    case user(UserMessage)
    case result(TurnResult)
    case rateLimit(RateLimitEvent)
    case apiRetry(APIRetry)
    case status(SystemStatus)
    case compactBoundary(CompactBoundary)
    case sessionState(SessionStateChange)
    case conversationReset(ConversationReset)
    case commandLifecycle(CommandLifecycle)
    case taskStarted(TaskStarted)
    case controlRequest(IncomingControlRequest)
    case controlResponse(ControlResponse)
    case controlCancel(requestID: String)
    /// `system/control_request_progress{request_id, status}`: a request Loom sent is under way (a `side_question`
    /// says `started` once before its answer; spike S6). Known, never drift.
    case controlProgress(requestID: String, status: String?)
    /// `{"type":"keep_alive"}`: liveness only.
    case keepAlive
    case unknown(UnknownMessage)

    /// Reads one JSON object. Never fails: what is not understood becomes `.unknown`.
    public init(json: JSONValue) {
        let type = json["type"]?.string
        switch type {
        case "system":
            switch json["subtype"]?.string {
            case "init": self = .systemInit(SystemInit(json: json))
            case "status": self = .status(SystemStatus(json: json))
            case "api_retry": self = .apiRetry(APIRetry(json: json))
            case "compact_boundary": self = .compactBoundary(CompactBoundary(json: json))
            case "session_state_changed": self = .sessionState(SessionStateChange(json: json))
            case "control_request_progress":
                if let id = json["request_id"]?.string {
                    self = .controlProgress(requestID: id, status: json["status"]?.string)
                } else {
                    self = .unknown(UnknownMessage(type: type, subtype: "control_request_progress", raw: json))
                }
            case "task_started":
                if let started = TaskStarted(json: json) {
                    self = .taskStarted(started)
                } else {
                    self = .unknown(UnknownMessage(type: type, subtype: "task_started", raw: json))
                }
            default: self = .unknown(UnknownMessage(type: type, subtype: json["subtype"]?.string, raw: json))
            }
        case "stream_event": self = .streamEvent(StreamEvent(json: json))
        case "assistant": self = .assistant(AssistantMessage(json: json))
        case "user": self = .user(UserMessage(json: json))
        case "result": self = .result(TurnResult(json: json))
        case "rate_limit_event": self = .rateLimit(RateLimitEvent(json: json))
        case "conversation_reset": self = .conversationReset(ConversationReset(json: json))
        case "command_lifecycle":
            if let lifecycle = CommandLifecycle(json: json) {
                self = .commandLifecycle(lifecycle)
            } else {
                self = .unknown(UnknownMessage(type: type, subtype: nil, raw: json))
            }
        case "keep_alive": self = .keepAlive
        case "control_request":
            if let request = IncomingControlRequest(json: json) {
                self = .controlRequest(request)
            } else {
                self = .unknown(UnknownMessage(type: type, subtype: nil, raw: json))
            }
        case "control_response":
            if let response = ControlResponse(json: json) {
                self = .controlResponse(response)
            } else {
                self = .unknown(UnknownMessage(type: type, subtype: nil, raw: json))
            }
        case "control_cancel_request":
            if let id = json["request_id"]?.string {
                self = .controlCancel(requestID: id)
            } else {
                self = .unknown(UnknownMessage(type: type, subtype: nil, raw: json))
            }
        default:
            self = .unknown(UnknownMessage(type: type, subtype: json["subtype"]?.string, raw: json))
        }
    }

    /// Parses one line (without its newline).
    public init(line: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: line)
        guard value.object != nil else { throw StreamJSONError.notAnObject }
        self.init(json: value)
    }
}

public enum StreamJSONError: Error, Equatable, Sendable {
    case notAnObject
}
