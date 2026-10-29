import CoreFoundation
import Darwin
import Foundation

/// The authenticated failing hook and the exact native session/prompt it belongs to.
public struct ClaudeLimitResetContext: Sendable {
    public let sessionID: UUID
    /// The exact recorded spelling of the native UUID, including filename case.
    public let nativeSessionID: String
    public let runID: UUID
    public let promptID: UUID
    public let runStartedAt: Date
    public let failedAt: Date
    public let configDirectory: URL
    public let workingDirectory: String

    public init(sessionID: UUID, nativeSessionID: String, runID: UUID, promptID: UUID, runStartedAt: Date,
                failedAt: Date, configDirectory: URL, workingDirectory: String) {
        self.sessionID = sessionID
        self.nativeSessionID = nativeSessionID
        self.runID = runID
        self.promptID = promptID
        self.runStartedAt = runStartedAt
        self.failedAt = failedAt
        self.configDirectory = configDirectory
        self.workingDirectory = workingDirectory
    }
}

/// A structured usage-limit refusal, bound to the verified hook's session, run and prompt.
public struct ClaudeLimitResetSignal: Equatable, Sendable {
    public static let provider = ManagedSession.Provider.claude
    public let sessionID: UUID
    public let nativeSessionID: String
    public let runID: UUID
    public let promptID: UUID
    public let windowID: String
    public let resetsAt: Date

    init(sessionID: UUID, nativeSessionID: String, runID: UUID, promptID: UUID, windowID: String, resetsAt: Date) {
        self.sessionID = sessionID
        self.nativeSessionID = nativeSessionID
        self.runID = runID
        self.promptID = promptID
        self.windowID = windowID
        self.resetsAt = resetsAt
    }
}

/// Reads only an exact session's recent transcript tail after an authenticated failing hook.
public enum ClaudeLimitResetSignalReader {
    public static let maximumTailBytes = 128 * 1024
    public static let maximumLineBytes = 64 * 1024
    private static let maximumFailureDelay: TimeInterval = 60

    public static func read(_ context: ClaudeLimitResetContext) async -> ClaudeLimitResetSignal? {
        let task = Task.detached(priority: .utility) { readTail(context) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private static func readTail(_ context: ClaudeLimitResetContext) -> ClaudeLimitResetSignal? {
        guard !Task.isCancelled, context.runStartedAt <= context.failedAt,
              let nativeID = UUID(uuidString: context.nativeSessionID),
              context.workingDirectory.hasPrefix("/"), context.configDirectory.isFileURL else { return nil }
        let projects = context.configDirectory.appendingPathComponent("projects", isDirectory: true)
        let candidate = projects.appendingPathComponent(
            ClaudeTranscriptLocator.folderName(forWorkingDirectory: context.workingDirectory), isDirectory: true)
            .appendingPathComponent(context.nativeSessionID + ".jsonl")
        // Check the named file itself before the locator resolves its path; a final symlink is never followed.
        var named = stat()
        guard lstat(candidate.path, &named) == 0, named.st_mode & S_IFMT == S_IFREG, named.st_uid == getuid(),
              let file = ClaudeTranscriptLocator.locate(sessionID: context.nativeSessionID,
                                                         projectsDirectory: projects, onlyIn: context.workingDirectory),
              let fd = openOwnRegularFile(file.path) else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == named.st_dev, info.st_ino == named.st_ino, info.st_size > 0 else { return nil }
        let count = Int(min(info.st_size, off_t(maximumTailBytes)))
        var bytes = [UInt8](repeating: 0, count: count)
        let offset = info.st_size - off_t(count)
        let got = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
        guard got == count, !Task.isCancelled, bytes.last == 0x0A else { return nil }
        var tail = bytes[...]
        if offset > 0 {
            // The first line may start outside the bound. Discard it rather than looking farther back.
            guard let newline = tail.firstIndex(of: 0x0A) else { return nil }
            tail = tail[tail.index(after: newline)...]
        }
        let lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return formatter.date(from: text) ?? plain.date(from: text)
        }
        func boolean(_ value: Any?) -> Bool? {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        func native(_ row: [String: Any]) -> Bool {
            guard let text = row["sessionId"] as? String, let id = UUID(uuidString: text), id == nativeID,
                  let uuid = row["uuid"] as? String, UUID(uuidString: uuid) != nil,
                  boolean(row["isSidechain"]) == false else { return false }
            if let agent = row["agentId"], !(agent is NSNull) {
                guard let name = agent as? String, name.isEmpty else { return false }
            }
            return true
        }
        var found: (window: String, reset: Date, time: Date)?
        for line in lines.reversed() {
            guard !Task.isCancelled, line.count <= maximumLineBytes,
                  let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = row["type"] as? String else { return nil }
            switch type {
            case "assistant":
                guard native(row) else { return nil }
                // The latest assistant entry must be the refusal; a later answer makes the old error obsolete.
                if found != nil { continue }
                guard boolean(row["isApiErrorMessage"]) == true,
                      row["apiError"] as? String == "usage_limit_reached",
                      let time = date(row["timestamp"]), time >= context.runStartedAt, time <= context.failedAt,
                      context.failedAt.timeIntervalSince(time) <= maximumFailureDelay,
                      let parameters = row["apiErrorParams"] as? [String: Any],
                      let rate = parameters["rate_limit_info"] as? [String: Any],
                      rate["status"] as? String == "rejected", boolean(rate["isUsingOverage"]) == false,
                      let id = rate["rateLimitType"] as? String,
                      ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"].contains(id),
                      let value = rate["resetsAt"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, value.doubleValue.rounded(.towardZero) == value.doubleValue,
                      value.doubleValue > context.failedAt.timeIntervalSince1970 else { return nil }
                found = (id, Date(timeIntervalSince1970: value.doubleValue), time)
            case "user":
                guard native(row), let found, let promptText = row["promptId"] as? String,
                      UUID(uuidString: promptText) == context.promptID,
                      let time = date(row["timestamp"]), time >= context.runStartedAt, time <= found.time else { return nil }
                return ClaudeLimitResetSignal(sessionID: context.sessionID, nativeSessionID: context.nativeSessionID,
                    runID: context.runID, promptID: context.promptID, windowID: found.window, resetsAt: found.reset)
            default:
                continue
            }
        }
        return nil
    }
}
