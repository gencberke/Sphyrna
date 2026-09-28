import Foundation
import LoomCore

final class HookRecorder: @unchecked Sendable {
    private struct Entry {
        let runID: UUID
        let eventName: String
    }

    private let lock = NSLock()
    private let outputURL: URL
    private var entries: [Entry] = []

    init(outputURL: URL) {
        self.outputURL = outputURL
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    }

    func receive(_ envelope: ClaudeHookEnvelope) {
        guard let event = try? ClaudeHookEvent(payload: envelope.payload) else { return }
        let receivedAt = Date()
        var record: [String: Any] = [
            "loomSessionID": envelope.sessionID.uuidString,
            "managedRunID": envelope.managedRunID.uuidString,
            "providerSessionID": event.providerSessionID,
            "hookEventName": event.name,
            "sentAt": envelope.sentAt.timeIntervalSince1970,
            "receivedAt": receivedAt.timeIntervalSince1970,
            "transportLatencyMilliseconds": max(
                0, receivedAt.timeIntervalSince(envelope.sentAt) * 1_000
            ),
        ]
        switch event.kind {
        case let .sessionStart(source): record["source"] = source
        case let .permissionRequest(toolName): record["toolName"] = toolName
        case let .notification(type): record["notificationType"] = type
        case let .stop(backgroundTaskCount, scheduledTaskCount):
            record["backgroundTaskCount"] = backgroundTaskCount
            record["scheduledTaskCount"] = scheduledTaskCount
            record["hasLastAssistantMessage"] = event.lastAssistantMessage != nil
        case let .stopFailure(error, details):
            record["error"] = error
            record["hasErrorDetails"] = details != nil
            record["hasLastAssistantMessage"] = event.lastAssistantMessage != nil
        case let .sessionEnd(reason): record["reason"] = reason
        case .userPromptSubmit, .unknown: break
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: record, options: [.sortedKeys]
        ) + Data([10]) else { return }

        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(runID: envelope.managedRunID, eventName: event.name))
        guard let file = try? FileHandle(forWritingTo: outputURL) else { return }
        do {
            try file.seekToEnd()
            try file.write(contentsOf: data)
            try file.close()
        } catch {
            try? file.close()
        }
    }

    func eventNames(runID: UUID) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.lazy.filter { $0.runID == runID }.map(\.eventName))
    }
}
