import Foundation

/// Codex's side of the probe: a short-lived `codex app-server`, started the way a session's server is (the supervisor's
/// internal session, in a run scope when the build has them, SPEC §2), asked for the account, the limit windows, the token
/// totals and the model list, and stopped. It never starts a thread or a turn.
///
/// The whole ask is bounded by `timeout` (about 10 s). When it runs out, the work is cancelled and the server stopped; the
/// server and its scope are reaped on every path (an answer, a failure, a timeout, a cancelled caller), and the socket file
/// is removed. The account, once read, goes to the caller's memory and nowhere else; the log gets error categories only.
public struct CodexProbeSource: HarnessProbeSource {
    private let supervisor: ProcessSupervisor
    private let toolchain: @Sendable () async throws -> ProviderToolchain
    private let workingDirectory: String
    private let socketDirectory: URL
    private let clientVersion: String
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - toolchain: the resolved Codex toolchain sessions are launched with (its profile directory is `CODEX_HOME`).
    ///   - workingDirectory: a Loom-owned folder for the server's internal session, never a project.
    ///   - socketDirectory: where the server's short-named socket lives (created `0700` when missing).
    ///   - timeout: how long the whole ask may take, start to stop request.
    public init(supervisor: ProcessSupervisor, toolchain: @escaping @Sendable () async throws -> ProviderToolchain,
                workingDirectory: String, socketDirectory: URL, clientVersion: String, timeout: TimeInterval = 10) {
        self.supervisor = supervisor
        self.toolchain = toolchain
        self.workingDirectory = workingDirectory
        self.socketDirectory = socketDirectory
        self.clientVersion = clientVersion
        self.timeout = timeout
    }

    public func read() async -> HarnessProbeAnswer? {
        let run = ProbeRun()
        let work = Task { await exchange(run) }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            LoomLog.error(.usage, key: "codex-probe-timeout", "The Codex probe ran out of time")
            work.cancel()
            // The server's start waits on its own task: stopping the server is what makes it give up.
            await run.close(using: supervisor)
        }
        let answer = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        watchdog.cancel()
        await watchdog.value
        await run.close(using: supervisor)
        return answer
    }

    private func exchange(_ run: ProbeRun) async -> HarnessProbeAnswer? {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let resolved = try await toolchain()
            try FileManager.default.createDirectory(
                at: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Unique per ask and short: Unix socket paths are limited to ~100 bytes.
            let socket = socketDirectory.appendingPathComponent("p-\(UUID().uuidString.prefix(8)).sock").path
            await run.keep(socket: socket)
            var scope: RunScope?
            if supervisor.runScopesEnabled {
                scope = try await supervisor.openScope()
                await run.keep(scope: scope)
            }
            try Task.checkCancellation()
            let manager = CodexAppServerManager(
                supervisor: supervisor,
                configuration: CodexAppServerConfiguration(
                    executable: resolved.executable, capabilities: resolved.capabilities,
                    home: resolved.profileDirectory ?? FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".codex", isDirectory: true),
                    baseEnvironment: resolved.environment, workingDirectory: workingDirectory, socketPath: socket,
                    clientVersion: clientVersion, startupTimeout: max(1, timeout - (ProcessInfo.processInfo.systemUptime - started)),
                    scope: scope))
            await run.keep(manager: manager)
            let client = try await manager.start()
            let answer = await Self.ask(client, timeout: max(1, timeout - (ProcessInfo.processInfo.systemUptime - started)))
            return answer.isEmpty ? nil : answer
        } catch {
            LoomLog.error(.usage, key: "codex-probe", "The Codex probe could not read (\(LoomLog.category(of: error)))")
            return nil
        }
    }

    /// The four reads, one after another on the one connection. A read that fails leaves its part nil.
    static func ask(_ client: CodexAppServerClient, timeout: TimeInterval) async -> HarnessProbeAnswer {
        var answer = HarnessProbeAnswer()
        answer.version = await client.serverUserAgent.flatMap(version(fromUserAgent:))
        if let result = try? await client.readAccount(timeout: timeout) { answer.account = account(from: result) }
        if let result = try? await client.readRateLimits(timeout: timeout) { answer.windows = windows(from: result) }
        if let result = try? await client.readTokenUsage(timeout: timeout) {
            let usage = tokenUsage(from: result)
            answer.lifetimeTokens = usage.lifetime
            answer.tokenDays = usage.days
        }
        if let models = try? await client.listModels(timeout: timeout) { answer.models = self.models(from: models) }
        return answer
    }

    // MARK: Reading the answers

    /// "0.160.0" from "codex_cli_rs/0.160.0 (Mac OS 26.0; arm64) ..."; nil when the agent has no such token.
    static func version(fromUserAgent agent: String) -> String? {
        guard let slash = agent.firstIndex(of: "/") else { return nil }
        let token = agent[agent.index(after: slash)...].prefix { !$0.isWhitespace }
        return token.isEmpty ? nil : String(token)
    }

    /// `account/read`'s answer. A null account is signed out; an API key or a cloud provider's credentials are `apiKey`;
    /// a ChatGPT login is a subscription with the email and plan the server named. An account of a type this does not know
    /// is left unknown (nil).
    static func account(from result: JSONValue) -> HarnessAccount? {
        guard let account = result["account"] else { return nil }
        if account.isNull { return HarnessAccount.none }
        switch account["type"]?.string {
        case "apiKey", "amazonBedrock":
            return .apiKey
        case "chatgpt":
            return .subscription(email: account["email"]?.string.flatMap { $0.isEmpty ? nil : $0 }, plan: account["planType"]?.string)
        default:
            return nil
        }
    }

    /// `account/rateLimits/read`'s answer: every bucket of the multi-bucket view (the `codex` bucket first), else the one
    /// single-bucket view; a bucket gives its primary and then its secondary window.
    static func windows(from result: JSONValue) -> [HarnessLimitWindow]? {
        var snapshots: [(id: String, value: JSONValue)] = []
        if let byID = result["rateLimitsByLimitId"]?.object, !byID.isEmpty {
            snapshots = byID.keys.sorted { ($0 == "codex" ? "" : $0) < ($1 == "codex" ? "" : $1) }.map { ($0, byID[$0] ?? .null) }
        } else if let single = result["rateLimits"], single.object != nil {
            snapshots = [(single["limitId"]?.string ?? "codex", single)]
        } else {
            return nil
        }
        var windows: [HarnessLimitWindow] = []
        for (key, snapshot) in snapshots {
            let id = snapshot["limitId"]?.string ?? key
            let bucket = id == "codex" ? nil : (snapshot["limitName"]?.string ?? id)
            for (slot, fallback) in [("primary", "Primary"), ("secondary", "Secondary")] {
                guard let window = snapshot[slot], window.object != nil, let used = window["usedPercent"]?.double else { continue }
                let minutes = window["windowDurationMins"]?.int
                let length = minutes.map(HarnessLimitWindow.lengthName(minutes:)) ?? fallback
                windows.append(HarnessLimitWindow(
                    id: "\(id).\(slot)", name: bucket.map { "\($0) \(length)" } ?? length, durationMinutes: minutes,
                    usedPercent: used.isFinite ? Int(min(max(used, 0), 100).rounded()) : 0,
                    resetsAt: window["resetsAt"]?.int.map(date(fromUnix:))))
            }
        }
        return windows
    }

    /// A reset time as the server gives it: Unix seconds (milliseconds are taken for what they obviously are).
    private static func date(fromUnix value: Int) -> Date {
        Date(timeIntervalSince1970: value > 100_000_000_000 ? Double(value) / 1_000 : Double(value))
    }

    /// `account/usage/read`'s answer: the lifetime total and the daily buckets, oldest first as the server lists them.
    static func tokenUsage(from result: JSONValue) -> (lifetime: Int64?, days: [HarnessTokenDay]?) {
        let lifetime = result["summary"]?["lifetimeTokens"]?.int.map(Int64.init)
        let days = result["dailyUsageBuckets"]?.array?.compactMap { bucket -> HarnessTokenDay? in
            guard let day = bucket["startDate"]?.string, let tokens = bucket["tokens"]?.int else { return nil }
            return HarnessTokenDay(day: day, tokens: Int64(tokens))
        }
        return (lifetime, days)
    }

    /// `model/list`'s models, hidden ones dropped, in the server's order. The slug a session is launched with is `model`
    /// (it is `id` as well, in every list seen).
    static func models(from values: [JSONValue]) -> [HarnessModel] {
        values.compactMap { value -> HarnessModel? in
            guard value["hidden"]?.bool != true, let id = value["model"]?.string ?? value["id"]?.string, !id.isEmpty else { return nil }
            let efforts = (value["supportedReasoningEfforts"]?.array ?? []).compactMap { $0["reasoningEffort"]?.string }
            return HarnessModel(
                id: id, displayName: value["displayName"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                isDefault: value["isDefault"]?.bool ?? false, efforts: efforts)
        }
    }
}

/// What one ask has started, so every path can stop it: the server, its run scope and its socket file. Closing is
/// serialised: a second close waits for the first, and sees whatever was kept since.
actor ProbeRun {
    private var manager: CodexAppServerManager?
    private var scope: RunScope?
    private var socket: String?
    private var closing: Task<Void, Never>?

    func keep(manager: CodexAppServerManager) { self.manager = manager }
    func keep(scope: RunScope?) { self.scope = scope }
    func keep(socket: String) { self.socket = socket }

    func close(using supervisor: ProcessSupervisor) async {
        let manager = self.manager, scope = self.scope, socket = self.socket
        self.manager = nil
        self.scope = nil
        self.socket = nil
        let previous = closing
        let task = Task {
            await previous?.value
            var errors: [String] = []
            if let manager { errors += await manager.stopServer().errors }
            // Normally released by the server run's stop; this covers a server that never started. Never released while a
            // stop could not be verified.
            if errors.isEmpty, let scope { errors += await supervisor.releaseScope(scope) }
            if errors.isEmpty { if let socket { unlink(socket) } }
            else { LoomLog.error(.usage, key: "codex-probe-reap", "The Codex probe's server could not be fully stopped") }
        }
        closing = task
        await task.value
    }
}
