import CoreFoundation
import Foundation

/// Only the documented, bounded metadata crosses the hook socket. Tool
/// arguments, prompts, error text and native transcript contents never do.
struct AgyHookEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case sessionStart = "SessionStart", preInvocation = "PreInvocation", postInvocation = "PostInvocation"
        case preToolUse = "PreToolUse", postToolUse = "PostToolUse", stop = "Stop"
    }
    let kind: Kind
    let conversationID: UUID
    let workspacePaths: [String]
    let transcriptPath: String
    let artifactDirectoryPath: String
    let modelName: String?
    let invocationNum: Int?
    let initialNumSteps: Int?
    let executionNum: Int?
    let terminationReason: String?
    let fullyIdle: Bool?

    static let maximumPayload = 64 * 1024

    var isWellFormed: Bool {
        guard !workspacePaths.isEmpty, workspacePaths.count <= 16, workspacePaths.allSatisfy(Self.validPath),
              Self.validPath(transcriptPath), Self.validPath(artifactDirectoryPath),
              modelName.map(Self.validToken) ?? true,
              invocationNum.map({ $0 >= 0 }) ?? true, initialNumSteps.map({ $0 >= 0 }) ?? true,
              executionNum.map({ $0 >= 0 }) ?? true,
              terminationReason.map(Self.validToken) ?? true else { return false }
        switch kind {
        case .preInvocation, .postInvocation: return invocationNum != nil && initialNumSteps != nil
        case .stop: return executionNum != nil && terminationReason != nil && fullyIdle != nil
        default: return true
        }
    }

    static func parse(kind: Kind, payload: Data) -> AgyHookEvent? {
        guard !payload.isEmpty, payload.count <= maximumPayload,
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let rawID = object["conversationId"] as? String, let id = UUID(uuidString: rawID),
              let paths = object["workspacePaths"] as? [String], !paths.isEmpty, paths.count <= 16,
              paths.allSatisfy(validPath), let transcript = object["transcriptPath"] as? String, validPath(transcript),
              let artifacts = object["artifactDirectoryPath"] as? String, validPath(artifacts) else { return nil }
        let model = object["modelName"] as? String
        guard object["modelName"] == nil || (model.map(validToken) == true) else { return nil }
        let invocation = number(object["invocationNum"]), initial = number(object["initialNumSteps"])
        let execution = number(object["executionNum"]), reason = object["terminationReason"] as? String
        let idle = bool(object["fullyIdle"])
        switch kind {
        case .preInvocation, .postInvocation:
            guard invocation != nil, initial != nil else { return nil }
        case .preToolUse, .postToolUse:
            guard let tool = object["toolCall"] as? [String: Any],
                  let name = tool["name"] as? String, validToken(name), tool["args"] is [String: Any],
                  number(object["stepIdx"]) != nil else { return nil }
        case .stop:
            guard execution != nil, let reason, validToken(reason), idle != nil else { return nil }
        default: break
        }
        return AgyHookEvent(kind: kind, conversationID: id, workspacePaths: paths, transcriptPath: transcript,
            artifactDirectoryPath: artifacts, modelName: model, invocationNum: invocation,
            initialNumSteps: initial, executionNum: execution, terminationReason: reason, fullyIdle: idle)
    }

    private static func validPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.utf8.contains(0)
    }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func number(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(exactly: number.doubleValue), integer >= 0 else { return nil }
        return integer
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

struct AgyHookWire: Codable, Sendable {
    let token: String
    let sessionID: UUID
    let runID: UUID
    let event: AgyHookEvent
}

/// Native hook stdout is always an inert native decision. Transport failures
/// never grant a tool permission or inject a model instruction.
public enum AgyHookCommand {
    public static func run(event: String, environment: [String: String], payload: Data) -> String {
        let kind = AgyHookEvent.Kind(rawValue: event)
        let output = kind == .preToolUse ? #"{"decision":"allow"}"# : kind == .stop ? #"{"decision":""}"# : "{}"
        guard let kind, let event = AgyHookEvent.parse(kind: kind, payload: payload),
              let socket = environment["LOOM_AGY_SOCKET"], !socket.isEmpty,
              let token = environment["LOOM_AGY_TOKEN"], !token.isEmpty,
              let session = environment["LOOM_SESSION_ID"].flatMap(UUID.init(uuidString:)),
              let run = environment["LOOM_MANAGED_RUN_ID"].flatMap(UUID.init(uuidString:)),
              let wire = try? JSONEncoder().encode(AgyHookWire(token: token, sessionID: session, runID: run, event: event)) else {
            return output
        }
        _ = try? OpenSessionClient.roundTrip(raw: wire, socketPath: socket, connectTimeout: 0.5, replyTimeout: 0.5)
        return output
    }
}
