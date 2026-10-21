import Foundation
import LoomChat
import LoomCore

/// What a call is for; it sets the deadline.
public enum RemoraKind: Sendable, Equatable {
    case question
    case brief
}

/// One call: the pack (built by the caller, never put on a command line), the model and effort, and the session ids the
/// pack names, which are the only ones the answer's block may cite.
public struct RemoraRequest: Sendable, Equatable {
    public var kind: RemoraKind
    /// `sonnet`, `haiku` or a model id.
    public var model: String
    /// `low` … `max`; anything else runs as `low`.
    public var effort: String
    public var pack: String
    public var knownSessionIDs: Set<String>

    public init(kind: RemoraKind, model: String = "sonnet", effort: String = "low", pack: String,
                knownSessionIDs: Set<String> = []) {
        self.kind = kind
        self.model = model
        self.effort = effort
        self.pack = pack
        self.knownSessionIDs = knownSessionIDs
    }
}

public enum RemoraEvent: Equatable, Sendable {
    /// The next piece of the visible answer, in order (thinking and the closing block never come through here).
    case text(String)
    /// The call ended well: the whole answer with its parts, and the call's usage.
    case finished(RemoraAnswer)
}

/// Why a call has no answer. `detail` is for a diagnostics line and never holds the pack or the model's words except
/// for the CLI's own error line; it is never logged by this module.
public struct RemoraFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// The Claude Code login is missing or expired.
        case notLoggedIn
        /// The plan's limit or the API's rate limit stopped the call.
        case rateLimited
        /// The model refused the pack (S10: `is_error` with `subtype: "success"`, stop reason `refusal`).
        case refused
        /// Claude answered with an error of another kind, or its turn ended abnormally.
        case apiError
        /// No answer by the deadline (60 s for a question, 120 s for a brief).
        case timedOut
        /// The child ended (or its output ended) without a result.
        case endedWithoutAnswer
        /// The child wrote more than the output bound.
        case outputTooLarge
        /// The child could not be started, or Sphyrna was quitting.
        case couldNotStart
    }

    public var kind: Kind
    public var detail: String
    /// What the call used before it failed, when Claude reported it (a refusal is billed).
    public var usage: RemoraTokenUsage?

    public var description: String { detail.isEmpty ? kind.rawValue : "\(kind.rawValue): \(detail)" }
}

/// Remora's call: one `claude -p` child per call with the user's Claude Code login, no tools, no hooks, no MCP, no
/// transcript, the pack on stdin (design/DESIGN.md §20; spike S10 on Claude Code 2.1.300). The child is an owned helper
/// of the supervisor (`ProcessSupervisor.streamHelper`): in the ledger, in a run scope when there is a launcher, one
/// deadline, bounded output, ended by a cancel at once and by Quit.
public struct RemoraCall: Sendable {
    public static let questionTimeout: TimeInterval = 60
    public static let briefTimeout: TimeInterval = 120
    /// More than this on the child's stdout is not an answer.
    public static let outputLimit = 4 * 1024 * 1024

    /// The environment's keys, and the only ones a call's child gets. `CLAUDE_CONFIG_DIR` is set only for a profile that
    /// is not the home default (Claude names its stored login after an explicit config directory, so `~/.claude` is
    /// never passed explicitly, as for the plan-limits child); `USER` is required (without it the CLI says "Not logged in").
    /// `DISABLE_PROMPT_CACHING=1` for every call: a brief runs once a day and is never read back, and two question packs
    /// share only their first ~200–850 tokens (L1b), so the cache's 2× write would cost more than its reads save (L1a's
    /// probe: a Haiku brief $0.0069 with the write, $0.0047 without).
    public static let environmentKeys: Set<String> = [
        "HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL", "TERM", "CLAUDE_CONFIG_DIR",
        "CLAUDE_CODE_DISABLE_AGENT_VIEW", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "DISABLE_PROMPT_CACHING",
    ]

    /// `claude`'s arguments for a model and an effort. No `--input-format` (the pack is plain text on stdin), no plugin
    /// directory, no `--settings` but the hooks switch, no tools, no setting sources (so no user or ancestor `CLAUDE.md`).
    public static func arguments(model: String, effort: String) -> [String] {
        [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", sanitizedModel(model), "--effort", sanitizedEffort(effort),
            "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--no-session-persistence",
            "--tools", "", "--system-prompt", RemoraRules.text, "--setting-sources", "",
        ]
    }

    /// The child's environment out of the one sessions run with (`source`: the resolved toolchain's). Missing basics
    /// get a plain default so the login can be found; nothing else of `source` is passed on.
    public static func environment(from source: [String: String], configDirectory: String?) -> [String: String] {
        var result: [String: String] = [:]
        let user = source["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        result["HOME"] = source["HOME"] ?? NSHomeDirectory()
        result["PATH"] = source["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        result["USER"] = user
        result["LOGNAME"] = source["LOGNAME"] ?? user
        result["TMPDIR"] = source["TMPDIR"] ?? NSTemporaryDirectory()
        result["LANG"] = source["LANG"] ?? "en_US.UTF-8"
        result["SHELL"] = source["SHELL"] ?? "/bin/zsh"
        result["TERM"] = source["TERM"] ?? "xterm-256color"
        if let configDirectory { result["CLAUDE_CONFIG_DIR"] = configDirectory }
        result["CLAUDE_CODE_DISABLE_AGENT_VIEW"] = "1"
        result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        result["DISABLE_PROMPT_CACHING"] = "1"
        return result
    }

    static func sanitizedEffort(_ effort: String) -> String {
        ChatEffort.ordered.contains(effort) ? effort : "low"
    }

    static func sanitizedModel(_ model: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_[]")
        guard !model.isEmpty, !model.hasPrefix("-"), model.unicodeScalars.allSatisfy(allowed.contains) else { return "sonnet" }
        return model
    }

    let supervisor: ProcessSupervisor
    let executable: String
    let environment: [String: String]
    let workingDirectory: URL
    let usage: RemoraUsage?
    let questionDeadline: TimeInterval
    let briefDeadline: TimeInterval
    let terminationGrace: TimeInterval
    /// Test seam: variables added to the child's environment (the fake provider's script). Empty in the app.
    let additionalEnvironment: [String: String]

    /// - Parameters:
    ///   - executable: the resolved Claude toolchain's `claude`.
    ///   - environment: `environment(from:configDirectory:)`'s result.
    ///   - workingDirectory: `<data root>/remora/run`: created when missing and left empty; never a project.
    ///   - usage: the counter the calls are added to.
    public init(supervisor: ProcessSupervisor, executable: String, environment: [String: String], workingDirectory: URL,
                usage: RemoraUsage? = nil) {
        self.init(supervisor: supervisor, executable: executable, environment: environment, workingDirectory: workingDirectory,
                  usage: usage, questionDeadline: Self.questionTimeout, briefDeadline: Self.briefTimeout,
                  terminationGrace: 2, additionalEnvironment: [:])
    }

    init(supervisor: ProcessSupervisor, executable: String, environment: [String: String], workingDirectory: URL,
         usage: RemoraUsage?, questionDeadline: TimeInterval, briefDeadline: TimeInterval, terminationGrace: TimeInterval,
         additionalEnvironment: [String: String]) {
        self.supervisor = supervisor
        self.executable = executable
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.usage = usage
        self.questionDeadline = questionDeadline
        self.briefDeadline = briefDeadline
        self.terminationGrace = terminationGrace
        self.additionalEnvironment = additionalEnvironment
    }

    /// The same, out of the toolchain and profile sessions use.
    public init(supervisor: ProcessSupervisor, toolchain: ProviderToolchain, profile: ClaudeProfileLayout,
                workingDirectory: URL, usage: RemoraUsage? = nil) {
        self.init(
            supervisor: supervisor, executable: toolchain.executable,
            environment: Self.environment(
                from: toolchain.environment,
                configDirectory: profile.source == .homeDefault ? nil : profile.configDirectory.path),
            workingDirectory: workingDirectory, usage: usage)
    }

    /// Runs one call. The stream yields the answer's text as it arrives and ends with `.finished`, or throws a
    /// `RemoraFailure`. Cancelling the consuming task (or dropping the stream) ends the child at once (SIGTERM, SIGKILL
    /// after a short grace) and the stream ends without a further event.
    public func run(_ request: RemoraRequest) -> AsyncThrowingStream<RemoraEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task { await drive(request, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func drive(_ request: RemoraRequest, _ continuation: AsyncThrowingStream<RemoraEvent, any Error>.Continuation) async {
        let clock = ContinuousClock()
        let began = clock.now
        func failure(_ kind: RemoraFailure.Kind, _ detail: String = "", usage: RemoraTokenUsage? = nil) -> RemoraFailure {
            RemoraFailure(kind: kind, detail: detail, usage: usage)
        }
        do {
            try FileManager.default.createDirectory(
                at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            continuation.finish(throwing: failure(.couldNotStart, "The working folder could not be made"))
            return
        }
        var reader = RemoraStreamReader(knownSessionIDs: request.knownSessionIDs)
        var delivered = false
        usage?.recordStart(request.kind)
        let child = supervisor.streamHelper(
            executable, Self.arguments(model: request.model, effort: request.effort),
            environment: environment.merging(additionalEnvironment) { _, extra in extra },
            workingDirectory: workingDirectory.path, input: Data(request.pack.utf8),
            timeout: request.kind == .question ? questionDeadline : briefDeadline,
            terminationGrace: terminationGrace, outputLimit: Self.outputLimit)
        func deliver(_ outcome: RemoraStreamReader.Outcome) {
            delivered = true
            switch outcome {
            case let .answer(answer):
                usage?.recordResult(tokens: answer.usage, costUSD: answer.costUSD)
                var answer = answer
                answer.duration = clock.now - began
                continuation.yield(.finished(answer))
            case let .failure(failed):
                usage?.recordResult(tokens: failed.usage ?? RemoraTokenUsage(), costUSD: reader.costUSD)
                continuation.finish(throwing: failed)
            }
        }
        do {
            for try await chunk in child {
                for piece in reader.feed(chunk) { continuation.yield(.text(piece)) }
                if let outcome = reader.outcome, !delivered {
                    deliver(outcome)
                    if case .failure = outcome { return }
                }
            }
            if !delivered {
                continuation.finish(throwing: failure(.endedWithoutAnswer, "The call ended without a result"))
            } else {
                continuation.finish()
            }
        } catch is CancellationError {
            continuation.finish()
        } catch {
            // After the result nothing else matters (Claude exits 1 after an error result, and may be slow to leave).
            guard !delivered else { continuation.finish(); return }
            if Task.isCancelled { continuation.finish(); return }
            switch error {
            case StreamHelperError.timedOut:
                continuation.finish(throwing: failure(.timedOut, "No answer in time"))
            case let LoomError.outputTooLarge(limit) where limit == Self.outputLimit:
                continuation.finish(throwing: failure(.outputTooLarge, "The output passed its limit"))
            case let LoomError.helperExit(status, detail):
                continuation.finish(throwing: failure(.endedWithoutAnswer, "Claude exited with status \(status)" + (detail.isEmpty ? "" : ": \(detail)")))
            case SessionManagementError.shutdownStarted:
                continuation.finish(throwing: failure(.couldNotStart, "Sphyrna is quitting"))
            default:
                continuation.finish(throwing: failure(.couldNotStart, String(describing: error)))
            }
        }
    }
}
