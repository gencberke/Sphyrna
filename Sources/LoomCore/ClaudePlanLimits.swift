import Darwin
import Foundation
import Synchronization

/// One rate-limit window of a Claude plan, as the Claude CLI reports it.
public struct PlanLimitWindow: Equatable, Sendable {
    /// Percent of the window already used, 0...100.
    public var usedPercent: Int
    /// When the window resets; nil when the CLI did not say.
    public var resetsAt: Date?

    public var remainingPercent: Int { 100 - usedPercent }

    public init(usedPercent: Int, resetsAt: Date?) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
    }

    /// A window whose reset time has passed describes a window that no longer exists.
    public func isCurrent(at now: Date) -> Bool { resetsAt.map { $0 > now } ?? true }
}

public enum PlanLimitKind: Equatable, Sendable {
    case fiveHour, weekly
}

/// The plan limits at one moment. Only the two windows the product shows are kept; nothing else
/// the CLI answers (account and spend fields among it) is read.
public struct PlanLimits: Equatable, Sendable {
    public var fiveHour: PlanLimitWindow?
    public var weekly: PlanLimitWindow?
    /// When the CLI answered.
    public var fetchedAt: Date

    public init(fiveHour: PlanLimitWindow?, weekly: PlanLimitWindow?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }

    /// The windows that still exist at `now`, five-hour first.
    public func current(at now: Date) -> [(kind: PlanLimitKind, window: PlanLimitWindow)] {
        var windows: [(kind: PlanLimitKind, window: PlanLimitWindow)] = []
        if let fiveHour, fiveHour.isCurrent(at: now) { windows.append((.fiveHour, fiveHour)) }
        if let weekly, weekly.isCurrent(at: now) { windows.append((.weekly, weekly)) }
        return windows
    }

    /// The window that runs out first: the lowest remaining percent, a tie going to the earlier reset.
    public func bottleneck(at now: Date) -> (kind: PlanLimitKind, window: PlanLimitWindow)? {
        current(at: now).min { left, right in
            if left.window.remainingPercent != right.window.remainingPercent {
                return left.window.remainingPercent < right.window.remainingPercent
            }
            return (left.window.resetsAt ?? .distantFuture) < (right.window.resetsAt ?? .distantFuture)
        }
    }
}

/// Where the usage model gets plan limits; a fake stands in for it in tests. nil means they are
/// not available (no plan limits for this account, no CLI, a timeout): nothing is shown then.
public protocol PlanLimitsFetching: Sendable {
    func fetch() async -> PlanLimits?
}

/// Asks the Claude CLI itself for the plan limits: a short headless `claude -p` process in
/// stream-json mode, one `get_usage` control request, one answer. No model turn happens, no
/// transcript is written, and Loom never touches credentials (the CLI uses its own). The process
/// runs in a Loom-owned folder, with the same executable and Claude profile as usage, and lives
/// for about a second; whatever it answers beyond the two windows is dropped unread and nothing
/// is logged or stored.
/// Without the last three arguments the CLI would run the user's own SessionStart and SessionEnd
/// hooks and start their MCP servers for every ask (seen with Claude Code 2.1.293).
public struct ClaudePlanLimitsFetcher: PlanLimitsFetching {
    public static let arguments = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--no-session-persistence",
    ]

    let toolchain: @Sendable () async throws -> ProviderToolchain
    let profile: ClaudeProfileLayout
    let workingDirectory: URL
    let timeout: TimeInterval
    let grace: TimeInterval
    let clock: @Sendable () -> Date

    /// - Parameters:
    ///   - toolchain: the resolved Claude toolchain sessions are launched with.
    ///   - profile: the Claude profile usage is read from; the child gets the same one.
    ///   - workingDirectory: a Loom-owned folder (created when missing), never a project.
    ///   - timeout: how long to wait for the answer.
    ///   - grace: how long a child may take to exit after its input closed before it is terminated.
    public init(
        toolchain: @escaping @Sendable () async throws -> ProviderToolchain, profile: ClaudeProfileLayout,
        workingDirectory: URL, timeout: TimeInterval = 10, grace: TimeInterval = 3,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.toolchain = toolchain
        self.profile = profile
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.grace = grace
        self.clock = clock
    }

    /// The child's environment: the toolchain's, as sessions get it. For the default profile it is
    /// left alone (sessions keep a `CLAUDE_CONFIG_DIR` from the login shell, so the ask goes to the
    /// account sessions use; Loom never sets `~/.claude` explicitly, since Claude names its stored
    /// login after an explicit config directory). An explicit profile is pinned.
    static func environment(toolchain: ProviderToolchain, profile: ClaudeProfileLayout) -> [String: String] {
        var environment = toolchain.environment
        if profile.source != .homeDefault {
            environment["CLAUDE_CONFIG_DIR"] = profile.configDirectory.path
        }
        return environment
    }

    public func fetch() async -> PlanLimits? {
        guard let resolved = try? await toolchain() else { return nil }
        let exchange = LimitsExchange(
            executable: resolved.executable, environment: Self.environment(toolchain: resolved, profile: profile),
            workingDirectory: workingDirectory, timeout: timeout, grace: grace)
        let cancelled = CancelFlag()
        let outcome = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { exchange.run(cancelled: cancelled) }.value
        } onCancel: {
            cancelled.set()
        }
        guard let outcome, outcome.fiveHour != nil || outcome.weekly != nil else { return nil }
        return PlanLimits(fiveHour: outcome.fiveHour, weekly: outcome.weekly, fetchedAt: clock())
    }
}

/// What a `get_usage` answer says about the two windows.
struct PlanLimitsAnswer: Equatable, Sendable {
    var fiveHour: PlanLimitWindow?
    var weekly: PlanLimitWindow?
}

/// One line of the child's stdout, judged against the request.
enum PlanLimitsLine: Equatable, Sendable {
    /// Not the answer to this request (system, assistant or unrelated lines, garbage).
    case ignored
    /// The answer, but not usable: an error, or limits that do not exist for this account.
    case unavailable
    case answer(PlanLimitsAnswer)
}

enum PlanLimitsWire {
    static func request(id: String) -> Data {
        let object: [String: Any] = ["type": "control_request", "request_id": id, "request": ["subtype": "get_usage"]]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    static func interpret(_ line: some Collection<UInt8>, requestID: String) -> PlanLimitsLine {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["request_id"] as? String == requestID else { return .ignored }
        guard response["subtype"] as? String == "success",
              let payload = response["response"] as? [String: Any] else { return .unavailable }
        let limits = payload["rate_limits"] as? [String: Any]
        if payload["rate_limits_available"] as? Bool == false || limits?["rate_limits_available"] as? Bool == false {
            return .unavailable
        }
        guard let limits else { return .unavailable }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let answer = PlanLimitsAnswer(
            fiveHour: window(limits["five_hour"], parser, plain), weekly: window(limits["seven_day"], parser, plain))
        return answer.fiveHour == nil && answer.weekly == nil ? .unavailable : .answer(answer)
    }

    private static func window(_ value: Any?, _ parser: ISO8601DateFormatter, _ plain: ISO8601DateFormatter) -> PlanLimitWindow? {
        guard let object = value as? [String: Any], let number = object["utilization"] as? NSNumber else { return nil }
        let used = number.doubleValue
        guard used.isFinite else { return nil }
        let clamped = min(max(used, 0), 100)   // before Int(): an absurd value must not trap
        let resets = (object["resets_at"] as? String).flatMap { parser.date(from: $0) ?? plain.date(from: $0) }
        return PlanLimitWindow(usedPercent: Int(clamped.rounded()), resetsAt: resets)
    }
}

private final class CancelFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

/// The blocking part: spawn, one request line, read until the answer, close, make sure it exits.
private struct LimitsExchange: Sendable {
    let executable: String
    let environment: [String: String]
    let workingDirectory: URL
    let timeout: TimeInterval
    let grace: TimeInterval

    /// More than this from the child is not an answer to a one-line request.
    private static let outputLimit = 4 * 1024 * 1024

    func run(cancelled: CancelFlag) -> PlanLimitsAnswer? {
        try? FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ClaudePlanLimitsFetcher.arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Only the child keeps the write end of its stdout, so EOF means it exited.
        try? output.fileHandleForWriting.close()
        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer { finish(process, writer: writer) }

        let requestID = UUID().uuidString
        do { try writer.write(contentsOf: PlanLimitsWire.request(id: requestID)) } catch { return nil }
        return readAnswer(from: output.fileHandleForReading.fileDescriptor, requestID: requestID, cancelled: cancelled)
    }

    private func readAnswer(from descriptor: Int32, requestID: String, cancelled: CancelFlag) -> PlanLimitsAnswer? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pending: [UInt8] = []
        var total = 0
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while !cancelled.isSet {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            // Short steps, so a cancelled fetch is noticed.
            let ready = poll(&poller, 1, Int32(min(remaining * 1_000, 200)))
            if ready < 0 { if errno == EINTR { continue } else { return nil } }
            if ready == 0 { continue }
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 { if errno == EINTR { continue } else { return nil } }
            if count == 0 { return nil } // the child ended without answering
            total += count
            guard total <= Self.outputLimit else { return nil }
            pending.append(contentsOf: chunk[..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                let judged = PlanLimitsWire.interpret(line, requestID: requestID)
                pending.removeSubrange(...newline)
                switch judged {
                case .ignored: continue
                case .unavailable: return nil
                case let .answer(answer): return answer
                }
            }
            // A line that never ends is not JSON worth waiting for.
            if pending.count > 1_048_576 { pending.removeAll() }
        }
        return nil
    }

    /// Closes the child's input, gives it `grace` to leave, then terminates it by its pid.
    private func finish(_ process: Process, writer: FileHandle) {
        try? writer.close()
        waitForExit(process, seconds: grace)
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGTERM)
        waitForExit(process, seconds: 1)
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        waitForExit(process, seconds: 2)
    }

    private func waitForExit(_ process: Process, seconds: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
    }
}
