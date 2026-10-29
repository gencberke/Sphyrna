import CoreFoundation
import Darwin
import Foundation
import Synchronization

/// Remembers why the last plan-limits ask failed (and forgets it when one succeeds), so the UI can
/// say "Plan limits unavailable" and the diagnostics export can say why. Shared by copies of the
/// fetcher.
public final class PlanLimitsStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: PlanLimitsFailure?
    public init() {}
    /// The most recent ask's failure; nil when it succeeded or none was made.
    public var lastFailure: PlanLimitsFailure? { lock.withLock { failure } }
    func record(_ value: PlanLimitsFailure?) { lock.withLock { failure = value } }
}

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

    /// How long the window runs, from one reset to the next.
    public var duration: TimeInterval {
        switch self {
        case .fiveHour: 5 * 3_600
        case .weekly: 7 * 86_400
        }
    }
}

/// Whether the use of a limit window keeps in step with the time that has passed in it: the plan
/// pace line. Pure arithmetic over one window and the clock; nothing is read or asked.
public struct PlanPace: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Too little of the window has passed for a rate to mean anything: how much is used can be
        /// shown, but there is no verdict (not "it lasts", not "it runs out").
        case tooEarly
        /// Less is used than the time passed would allow.
        case underPace
        /// Within `tolerance` of the time passed.
        case onPace
        /// More is used than the time passed allows: at this rate the window runs out before it resets.
        case overPace
    }

    /// How far use may differ from elapsed time and still count as on pace (5 points of the window).
    public static let tolerance = 0.05
    /// Before this share of the window had passed (when the answer was read), a rate says nothing: the
    /// status is `tooEarly` and there is no projection. A window already used up is over pace at any time.
    public static let minimumElapsedFraction = 0.05

    public let kind: PlanLimitKind
    /// Used share of the window, 0...1.
    public let usedFraction: Double
    /// Elapsed share of the window when the answer was read, 0...1: where an even pace stood then.
    public let elapsedFraction: Double
    public let status: Status
    public let resetsAt: Date
    /// When the window would run out at the rate so far; only while over pace (nil otherwise, and
    /// early in the window). Never before `now`: a window used up already says now.
    public let runsOutAt: Date?

    /// The pace of `window` at `now`; nil when the window has ended or its reset time is unknown
    /// (nothing can be said about a window whose length of time left is not known).
    /// `measuredAt` is when the used share was read (`PlanLimits.fetchedAt`): the elapsed time is
    /// measured there, so the two belong to the same moment and an old answer does not drift towards
    /// "it lasts". It is taken as `now` when absent, and never later than `now`.
    public init?(kind: PlanLimitKind, window: PlanLimitWindow, at now: Date, measuredAt: Date? = nil) {
        guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        let measured = min(measuredAt ?? now, now)
        let duration = kind.duration
        // A reset further away than one window (a clock out of step) has not started yet.
        let elapsed = min(max(duration - resetsAt.timeIntervalSince(measured), 0), duration)
        let used = Double(window.usedPercent) / 100
        let elapsedFraction = elapsed / duration
        self.kind = kind
        self.usedFraction = used
        self.elapsedFraction = elapsedFraction
        self.resetsAt = resetsAt
        if used >= 1 {
            status = .overPace
            runsOutAt = now
        } else if elapsedFraction < Self.minimumElapsedFraction {
            status = .tooEarly
            runsOutAt = nil
        } else if used > elapsedFraction + Self.tolerance {
            status = .overPace
            // The window started `elapsed` before `measured`; at that rate it is full after elapsed / used.
            let projected = measured.addingTimeInterval(-elapsed).addingTimeInterval(elapsed / used)
            runsOutAt = max(projected, now)
        } else {
            status = used < elapsedFraction - Self.tolerance ? .underPace : .onPace
            runsOutAt = nil
        }
    }
}

/// A model-scoped weekly window. `id` is a presentation key; for server-labelled rows it is not a provider ID.
public struct PlanModelLimitWindow: Equatable, Sendable {
    public let id: String
    public let label: String
    public let window: PlanLimitWindow

    public init(id: String, label: String, window: PlanLimitWindow) {
        self.id = id
        self.label = label
        self.window = window
    }
}

/// The plan limits at one moment; the account is held separately and spend is dropped.
public struct PlanLimits: Equatable, Sendable {
    public var fiveHour: PlanLimitWindow?
    public var weekly: PlanLimitWindow?
    public var modelWindows: [PlanModelLimitWindow]
    /// False if the CLI did not provide its model-window list, or some rows exceeded the read bound or were malformed.
    public var modelWindowsComplete: Bool
    /// When the CLI answered.
    public var fetchedAt: Date

    public init(fiveHour: PlanLimitWindow?, weekly: PlanLimitWindow?, fetchedAt: Date,
                modelWindows: [PlanModelLimitWindow] = [], modelWindowsComplete: Bool = true) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
        self.modelWindows = modelWindows
        self.modelWindowsComplete = modelWindowsComplete
    }

    /// The windows that still exist at `now`, five-hour first.
    public func current(at now: Date) -> [(kind: PlanLimitKind, window: PlanLimitWindow)] {
        var windows: [(kind: PlanLimitKind, window: PlanLimitWindow)] = []
        if let fiveHour, fiveHour.isCurrent(at: now) { windows.append((.fiveHour, fiveHour)) }
        if let weekly, weekly.isCurrent(at: now) { windows.append((.weekly, weekly)) }
        return windows
    }

    /// The pace of each window that still exists at `now`, five-hour first, each measured at `fetchedAt`.
    public func paces(at now: Date) -> [PlanPace] {
        current(at: now).compactMap { PlanPace(kind: $0.kind, window: $0.window, at: now, measuredAt: fetchedAt) }
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
    /// The same ask, with the account the CLI named in the same exchange (in memory only: see `HarnessAccount`). A source
    /// that does not see the account keeps the default.
    func fetchReading() async -> PlanLimitsReading
    /// Why the last ask failed and when; nil when it succeeded or none failed. A source that
    /// does not track it keeps the default (nil).
    var lastFailure: PlanLimitsFailure? { get }
}

public extension PlanLimitsFetching {
    var lastFailure: PlanLimitsFailure? { nil }
    /// A source that does not see the account: its limits, and when there are none, the failure it records (so the probe
    /// reports the same reason as the fetcher does).
    func fetchReading() async -> PlanLimitsReading {
        let limits = await fetch()
        return PlanLimitsReading(limits: limits, account: nil, failure: limits == nil ? lastFailure : nil)
    }
}

/// What one plan-limits ask gave: the windows (nil when the ask failed) and, beside them, the account the CLI answered
/// `initialize` or `get_usage` with. The account lives in memory for the length of a reading; it is never part of
/// `PlanLimits`, which is what the usage model keeps and the diagnostics describe.
public struct PlanLimitsReading: Equatable, Sendable {
    public var limits: PlanLimits?
    public var account: HarnessAccount?
    /// The models the same `initialize` answer listed (aliases with the release each resolves to); empty when it listed none.
    public var models: [HarnessModel]
    /// Why the ask failed, when it did (the same failure `ClaudePlanLimitsFetcher.lastFailure` records); nil when it succeeded.
    public var failure: PlanLimitsFailure?

    public init(limits: PlanLimits?, account: HarnessAccount?, models: [HarnessModel] = [], failure: PlanLimitsFailure? = nil) {
        self.limits = limits
        self.account = account
        self.models = models
        self.failure = failure
    }
}

/// Asks the Claude CLI itself for the plan limits: a short headless `claude -p` process in
/// stream-json mode, one `get_usage` control request, one answer. No model turn happens, no
/// transcript is written, and Loom never touches credentials (the CLI uses its own). The process
/// runs in a Loom-owned folder, with the same executable and Claude profile as usage, and lives
/// for about a second. It sends `initialize` before `get_usage`, only so the answer names the account
/// (`PlanLimitsReading.account`, in memory) and lists the models (`PlanLimitsReading.models`: aliases and the releases
/// they resolve to, for the model names). Other fields besides the reported windows are dropped
/// unread, and nothing is logged or stored.
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
    /// The category and time of the last failed ask (`lastFailure`).
    public let status: PlanLimitsStatus
    public var lastFailure: PlanLimitsFailure? { status.lastFailure }

    /// - Parameters:
    ///   - toolchain: the resolved Claude toolchain sessions are launched with.
    ///   - profile: the Claude profile usage is read from; the child gets the same one.
    ///   - workingDirectory: a Loom-owned folder (created when missing), never a project.
    ///   - timeout: how long to wait for the answer.
    ///   - grace: how long a child may take to exit after its input closed before it is terminated.
    public init(
        toolchain: @escaping @Sendable () async throws -> ProviderToolchain, profile: ClaudeProfileLayout,
        workingDirectory: URL, timeout: TimeInterval = 10, grace: TimeInterval = 3,
        clock: @escaping @Sendable () -> Date = { Date() },
        status: PlanLimitsStatus = PlanLimitsStatus()
    ) {
        self.toolchain = toolchain
        self.profile = profile
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.grace = grace
        self.clock = clock
        self.status = status
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

    public func fetch() async -> PlanLimits? { await fetchReading().limits }

    public func fetchReading() async -> PlanLimitsReading {
        let resolved: ProviderToolchain
        do { resolved = try await toolchain() } catch {
            return fail(.noToolchain)
        }
        let exchange = LimitsExchange(
            executable: resolved.executable, environment: Self.environment(toolchain: resolved, profile: profile),
            workingDirectory: workingDirectory, timeout: timeout, grace: grace)
        let cancelled = CancelFlag()
        let run: LimitsRun = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { exchange.run(cancelled: cancelled) }.value
        } onCancel: {
            cancelled.set()
        }
        switch run.outcome {
        case let .failure(category): return fail(category, account: run.account, models: run.models)
        case let .answer(answer):
            guard answer.fiveHour != nil || answer.weekly != nil || !answer.modelWindows.isEmpty else {
                return fail(.notAvailable, account: run.account, models: run.models)
            }
            status.record(nil)
            return PlanLimitsReading(
                limits: PlanLimits(fiveHour: answer.fiveHour, weekly: answer.weekly, fetchedAt: clock(),
                                   modelWindows: answer.modelWindows, modelWindowsComplete: answer.modelWindowsComplete),
                account: run.account,
                models: run.models)
        }
    }

    private func fail(_ category: PlanLimitsFailure.Category, account: HarnessAccount? = nil,
                      models: [HarnessModel] = []) -> PlanLimitsReading {
        let failure = PlanLimitsFailure(category: category, at: clock())
        status.record(failure)
        LoomLog.error(.usage, key: "plan-limits", "Plan limits could not be read (\(category.rawValue))")
        return PlanLimitsReading(limits: nil, account: account, models: models, failure: failure)
    }
}

/// What a `get_usage` answer says about its plan windows.
struct PlanLimitsAnswer: Equatable, Sendable {
    var fiveHour: PlanLimitWindow?
    var weekly: PlanLimitWindow?
    var modelWindows: [PlanModelLimitWindow] = []
    var modelWindowsComplete = true
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
    /// The first request of a Chat child, as `OutgoingControlRequest.initialize` sends it: no fields. Its answer names the
    /// account; nothing else of it is read here.
    static func initializeRequest(id: String) -> Data {
        let object: [String: Any] = ["type": "control_request", "request_id": id, "request": ["subtype": "initialize"]]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Whether `line` is the control response (success or error) to `requestID`.
    static func answers(_ line: some Collection<UInt8>, requestID: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any] else { return false }
        return response["request_id"] as? String == requestID
    }

    /// What a successful answer to one of `requestIDs` says about the account; nil for any other line, an error, or an answer
    /// that names none. The email and plan are returned to the caller's memory and go nowhere else.
    static func account(_ line: some Collection<UInt8>, requestIDs: Set<String>) -> HarnessAccount? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              let id = response["request_id"] as? String, requestIDs.contains(id),
              response["subtype"] as? String == "success",
              let payload = response["response"] as? [String: Any],
              let account = payload["account"] as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            (account[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        // A login through another provider (Bedrock, Vertex, Foundry) has no subscription: the provider's own credentials stand
        // for it.
        if let provider = text("apiProvider"), provider != "firstParty" { return .apiKey }
        let email = text("email"), plan = text("subscriptionType")
        // An account with neither is not one this code knows how to name: it is left unknown, not guessed.
        return email == nil && plan == nil ? nil : .subscription(email: email, plan: plan)
    }

    /// The models a successful answer to one of `requestIDs` lists (`initialize`'s `models`: `value`, `displayName`,
    /// `resolvedModel`, `supportedEffortLevels`); nil for any other line or an answer that lists none. An entry it cannot
    /// read is skipped.
    static func models(_ line: some Collection<UInt8>, requestIDs: Set<String>) -> [HarnessModel]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              let id = response["request_id"] as? String, requestIDs.contains(id),
              response["subtype"] as? String == "success",
              let payload = response["response"] as? [String: Any],
              let list = payload["models"] as? [[String: Any]] else { return nil }
        let models = list.compactMap { entry -> HarnessModel? in
            guard let value = entry["value"] as? String, !value.isEmpty else { return nil }
            let resolved = (entry["resolvedModel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let about = (entry["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // Effort levels by shape only (`HarnessEffort`): a level a newer CLI adds passes, a malformed one is dropped.
            return HarnessModel(id: value, displayName: entry["displayName"] as? String ?? value, isDefault: value == "default",
                                efforts: HarnessEffort.tokens(entry["supportedEffortLevels"] as? [String] ?? []),
                                resolvedModel: resolved, description: about)
        }
        return models.isEmpty ? nil : models
    }

    static func request(id: String) -> Data {
        // Without `skip_behaviors` the CLI reads every transcript touched in the last seven days to build
        // its behavior statistics, on every ask; Loom reads only the limits.
        let request: [String: Any] = ["subtype": "get_usage", "skip_behaviors": true]
        let object: [String: Any] = ["type": "control_request", "request_id": id, "request": request]
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
        var modelWindows: [PlanModelLimitWindow] = []
        var complete = true
        for (key, label) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            if let value = window(limits[key], parser, plain) {
                modelWindows.append(PlanModelLimitWindow(id: key, label: label, window: value))
            } else if let value = limits[key], !(value is NSNull) {
                complete = false
            }
        }
        // 2.1.311 reports these labels as an array, without a separate bucket ID. Limit the work and retain
        // distinct same-named rows without confusing them with the older named fields.
        var labelCounts: [String: Int] = [:]
        if let scoped = limits["model_scoped"] as? [Any] {
            if scoped.count > 32 - modelWindows.count { complete = false }
            for item in scoped.prefix(32 - modelWindows.count) {
                guard let entry = item as? [String: Any], let raw = entry["display_name"] as? String else {
                    complete = false
                    continue
                }
                let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, label.utf8.count <= 80,
                      label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                      let value = window(entry, parser, plain) else {
                    complete = false
                    continue
                }
                let count = labelCounts[label, default: 0] + 1
                labelCounts[label] = count
                let encoded = label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? label
                let id = "display:\(encoded)" + (count > 1 ? ":\(count)" : "")
                modelWindows.append(PlanModelLimitWindow(id: id, label: label, window: value))
            }
        } else {
            complete = false
        }
        let answer = PlanLimitsAnswer(fiveHour: window(limits["five_hour"], parser, plain),
                                      weekly: window(limits["seven_day"], parser, plain), modelWindows: modelWindows,
                                      modelWindowsComplete: complete)
        return answer.fiveHour == nil && answer.weekly == nil && answer.modelWindows.isEmpty ? .unavailable : .answer(answer)
    }

    private static func window(_ value: Any?, _ parser: ISO8601DateFormatter, _ plain: ISO8601DateFormatter) -> PlanLimitWindow? {
        guard let object = value as? [String: Any], let number = object["utilization"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
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

enum LimitsOutcome: Equatable, Sendable {
    case answer(PlanLimitsAnswer)
    case failure(PlanLimitsFailure.Category)
}

/// An exchange's outcome and the account its answers named (known even when the limits are not available).
struct LimitsRun: Sendable {
    var outcome: LimitsOutcome
    var account: HarnessAccount?
    /// The models `initialize` listed; empty when it did not answer or listed none.
    var models: [HarnessModel] = []
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

    func run(cancelled: CancelFlag) -> LimitsRun {
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
        do { try process.run() } catch { return LimitsRun(outcome: .failure(.spawnFailed)) }
        // Only the child keeps the write end of its stdout, so EOF means it exited.
        try? output.fileHandleForWriting.close()
        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer { finish(process, writer: writer) }

        let requestID = UUID().uuidString, initializeID = UUID().uuidString
        do {
            try writer.write(contentsOf: PlanLimitsWire.initializeRequest(id: initializeID))
            try writer.write(contentsOf: PlanLimitsWire.request(id: requestID))
        } catch { return LimitsRun(outcome: .failure(.writeFailed)) }
        return readAnswer(
            from: output.fileHandleForReading.fileDescriptor, requestID: requestID, initializeID: initializeID,
            cancelled: cancelled)
    }

    /// How long to keep reading for the account once the limits are settled and `initialize` has not answered.
    private static let accountGrace: TimeInterval = 1

    private func readAnswer(from descriptor: Int32, requestID: String, initializeID: String, cancelled: CancelFlag) -> LimitsRun {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pending: [UInt8] = []
        var total = 0
        var chunk = [UInt8](repeating: 0, count: 16_384)
        var settled: LimitsOutcome?
        var settledAt = deadline
        var account: HarnessAccount?
        var models: [HarnessModel] = []
        var initializeAnswered = false
        func finished(_ outcome: LimitsOutcome) -> LimitsRun { LimitsRun(outcome: outcome, account: account, models: models) }
        while !cancelled.isSet {
            let now = ProcessInfo.processInfo.systemUptime
            // The limits are in; `initialize` normally answered before them, and gets a moment more if it did not.
            if let settled, initializeAnswered || now >= settledAt { return finished(settled) }
            let remaining = deadline - now
            guard remaining > 0 else { return finished(settled ?? .failure(.timedOut)) }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            // Short steps, so a cancelled fetch is noticed.
            let ready = poll(&poller, 1, Int32(min(remaining * 1_000, 200)))
            if ready < 0 { if errno == EINTR { continue } else { return finished(settled ?? .failure(.endedWithoutAnswer)) } }
            if ready == 0 { continue }
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0 { if errno == EINTR { continue } else { return finished(settled ?? .failure(.endedWithoutAnswer)) } }
            if count == 0 { return finished(settled ?? .failure(.endedWithoutAnswer)) } // the child ended without answering
            total += count
            guard total <= Self.outputLimit else { return finished(settled ?? .failure(.outputTooLarge)) }
            pending.append(contentsOf: chunk[..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                // `initialize` names the account in full; `get_usage` only backs it up when `initialize` did not.
                if let named = PlanLimitsWire.account(line, requestIDs: [initializeID]) { account = named }
                else if account == nil, let named = PlanLimitsWire.account(line, requestIDs: [requestID]) { account = named }
                // The same answer lists the models with the release each alias resolves to (the draft's full names).
                if let listed = PlanLimitsWire.models(line, requestIDs: [initializeID]) { models = listed }
                if settled == nil {
                    switch PlanLimitsWire.interpret(line, requestID: requestID) {
                    case .ignored: break
                    case .unavailable: settled = .failure(.notAvailable); settledAt = now + Self.accountGrace
                    case let .answer(answer): settled = .answer(answer); settledAt = now + Self.accountGrace
                    }
                }
                if PlanLimitsWire.answers(line, requestID: initializeID) { initializeAnswered = true }
                pending.removeSubrange(...newline)
            }
            // A line that never ends is not JSON worth waiting for.
            if pending.count > 1_048_576 { pending.removeAll() }
        }
        return finished(.failure(.cancelled))
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
