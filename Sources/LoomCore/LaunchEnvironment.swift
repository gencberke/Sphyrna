import Darwin
import Foundation

public enum LaunchEnvironment {
    public enum LaunchOrigin { case launchServices, development }

    /// LaunchServices identity alone does not prove a clean environment: `open` can
    /// forward its caller's variables. Conservatively reject known shell/agent contexts.
    public static func origin(parent: [String: String], bundleIdentifier: String?, parentPID: Int32) -> LaunchOrigin {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty, parentPID == 1,
              parent["XPC_SERVICE_NAME"]?.hasPrefix("application.\(bundleIdentifier).") == true else {
            return .development
        }
        let agentKeys: Set<String> = ["CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_APP_TOOLS_PIPE_PATH",
                                      "CLAUDECODE", "CLAUDE_CODE_SESSION_ID"]
        if parent.keys.contains(where: {
            agentKeys.contains($0) || $0.hasPrefix("CLAUDE_CODE_MESSAGING_")
                || $0.hasPrefix("TERM_PROGRAM") || $0 == "TERM_SESSION_ID"
        }) { return .development }
        if let level = parent["SHLVL"], Int(level) == nil || (Int(level) ?? 0) > 0 {
            return .development
        }
        return .launchServices
    }

    public struct Resolution: Codable, Sendable, Equatable {
        public let environment: [String: String]
        /// At most 16 warnings, each at most 2,048 characters.
        public let warnings: [String]

        public init(environment: [String: String], warnings: [String] = []) {
            self.environment = environment
            self.warnings = warnings.prefix(16).map { String($0.prefix(2048)) }
        }
    }

    @MainActor private static var caches: [UUID: TerminalEnvironmentCache] = [:]

    /// Successful resolution and its warnings are cached; a failed call can be retried.
    /// The caller establishes launch origin from its app identity and parent process.
    @MainActor public static func terminal(origin: LaunchOrigin, runID: UUID,
                                           onSpawn: @escaping (pid_t) throws -> Void,
                                           onPoll: @escaping () throws -> Void) throws -> Resolution {
        let cache = caches[runID] ?? TerminalEnvironmentCache()
        caches[runID] = cache
        return try cache.value {
            let parent = ProcessInfo.processInfo.environment
            let session = sessionEnvironment(origin: origin, parent: parent)
            let resolved = try resolve(parent: parent, session: session.environment, runID: runID,
                                       onSpawn: onSpawn, onPoll: onPoll)
            return Resolution(environment: resolved.environment, warnings: session.warnings + resolved.warnings)
        }
    }

    @MainActor static func forget(runID: UUID) { caches[runID] = nil }

    /// Keep the user's complete resolved environment; only terminal identity is added here.
    public static func make(base: [String: String], runID: UUID, sessionID: UUID) -> [String: String] {
        var result = base
        result["TERM"] = "xterm-256color"
        result["LOOM_RUN_ID"] = runID.uuidString
        result["LOOM_SESSION_ID"] = sessionID.uuidString
        return result
    }

    /// Sanitized bootstrap for synthetic process tests, not a user's terminal environment.
    public static func make(
        parent: [String: String] = ProcessInfo.processInfo.environment,
        path: String, runID: UUID, sessionID: UUID
    ) -> [String: String] {
        var base = bootstrap(parent: parent)
        base["PATH"] = path
        return make(base: base, runID: runID, sessionID: sessionID)
    }

    static func bootstrap(parent: [String: String]) -> [String: String] {
        let allowed = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ"]
        var result = parent.filter { allowed.contains($0.key) }
        result["HOME"] = result["HOME"] ?? NSHomeDirectory()
        result["USER"] = result["USER"] ?? NSUserName()
        result["LOGNAME"] = result["LOGNAME"] ?? result["USER"]
        result["SHELL"] = result["SHELL"] ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        result["TMPDIR"] = result["TMPDIR"] ?? NSTemporaryDirectory()
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return result
    }

    /// Loom's locale policy, matched against this host's Terminal capture. The fallback
    /// preserves native OS enumeration order; it is not a claim about Terminal internals.
    static func localeLanguage(currentIdentifier: String, availableNames: [String]) -> (language: String?, warnings: [String]) {
        let identifier = Locale.identifier(.icu, from: currentIdentifier)
        let available = Set(availableNames)
        if let stem = identifier.split(separator: "@", maxSplits: 1).first,
           available.contains(String(stem) + ".UTF-8") {
            return (String(stem) + ".UTF-8", [])
        }
        if let language = Locale(identifier: currentIdentifier).language.languageCode?.identifier {
            for name in availableNames {
                guard let candidateStem = name.split(separator: ".", maxSplits: 1).first else { continue }
                let candidate = String(candidateStem)
                if candidate.hasPrefix(language + "_"), available.contains(candidate + ".UTF-8") {
                    return (candidate + ".UTF-8", [])
                }
            }
        }
        if available.contains("en_US.UTF-8") {
            return ("en_US.UTF-8", ["No installed UTF-8 locale matches macOS locale; using en_US.UTF-8"])
        }
        return (nil, ["No compatible UTF-8 locale is installed; leaving LANG unset"])
    }

    /// Internal injection points keep synthetic rc files and locale fixtures out of production.
    static func resolve(parent: [String: String], session: [String: String],
                        testZDOTDIR: URL? = nil, timeout: TimeInterval = 30,
                        currentLocale: String = Locale.current.identifier,
                        availableLocales: [String]? = nil, runID: UUID? = nil,
                        onSpawn: ((pid_t) throws -> Void)? = nil,
                        onPoll: (() throws -> Void)? = nil) throws -> Resolution {
        var base = bootstrap(parent: parent)
        var warnings: [String] = []
        if session["LANG"] == nil {
            let names: [String]
            if let availableLocales { names = availableLocales }
            else {
                do { names = try FileManager.default.contentsOfDirectory(atPath: "/usr/share/locale") }
                catch { names = []; warnings.append("Could not enumerate installed locales") }
            }
            let locale = localeLanguage(currentIdentifier: currentLocale, availableNames: names)
            base["LANG"] = locale.language
            warnings += locale.warnings
        }
        base.merge(session) { _, launchd in launchd }
        if let testZDOTDIR { base["ZDOTDIR"] = testZDOTDIR.path }
        // Mark before rc execution so daemonized startup helpers belong to this run.
        if let runID { base["LOOM_RUN_ID"] = runID.uuidString }
        let shell = base["SHELL"] ?? "/bin/zsh"
        guard URL(fileURLWithPath: shell).resolvingSymlinksInPath().path == "/bin/zsh" else {
            throw LoomError.message("Terminal environment resolution currently supports macOS /bin/zsh; unsupported shell: \(shell)")
        }
        let token = "LOOM-\(UUID().uuidString)"
        let start = Data(("\u{1e}" + token + "\0").utf8)
        let end = Data(("\u{1f}" + token + "\0").utf8)
        let statusPrefix = "\u{1e}\(token)-status:"
        let framed = "builtin printf '\\036\(token)-status:%s\\037' \"$?\"; builtin printf '\\036\(token)\\000'; /usr/bin/env -0 || exit $?; builtin printf '\\037\(token)\\000'"
        // Natural login + interactive startup. +m keeps startup jobs in the isolated
        // process group while stdin is EOF, allowing bounded failure cleanup.
        let output = try capture(shell, ["+m", "-l", "-i", "-c", framed],
                                 environment: base, directory: base["HOME"], timeout: timeout,
                                 onSpawn: onSpawn, onPoll: onPoll)
        var complete = false
        defer {
            if !complete { kill(-output.pid, SIGKILL) }
            reap(output.pid)
        }
        guard let first = output.stdout.range(of: start),
              let last = output.stdout.range(of: end, in: first.upperBound..<output.stdout.endIndex) else {
            throw LoomError.message("Terminal shell did not return a complete environment (status \(output.status)); check shell startup files")
        }
        let payload = output.stdout[first.upperBound..<last.lowerBound]
        var result: [String: String] = [:]
        for entry in payload.split(separator: 0) {
            guard let string = String(data: Data(entry), encoding: .utf8),
                  let equal = string.firstIndex(of: "="), equal != string.startIndex else {
                throw LoomError.message("Terminal shell returned an invalid environment entry")
            }
            result[String(string[..<equal])] = String(string[string.index(after: equal)...])
        }
        guard let path = result["PATH"], !path.isEmpty else {
            throw LoomError.message("Terminal shell returned an empty PATH")
        }
        if let prefix = output.stdout.range(of: Data(statusPrefix.utf8)),
           let end = output.stdout[prefix.upperBound...].firstIndex(of: 0x1f),
           let status = Int(String(decoding: output.stdout[prefix.upperBound..<end], as: UTF8.self)), status != 0 {
            warnings.append("Shell startup returned status \(status)")
        }
        if !output.stderr.isEmpty { warnings.append("Shell startup stderr: " + diagnostic(output.stderr)) }
        if output.status != 0 { warnings.append("Shell exited with wait status \(output.status) after returning the environment") }
        complete = true
        return Resolution(environment: result, warnings: warnings)
    }

    static func sessionEnvironment(origin: LaunchOrigin, parent: [String: String],
                                   lookup: ((String) throws -> String?)? = nil) -> Resolution {
        switch origin {
        case .launchServices:
            let launcherKeys: Set<String> = ["__CFBundleIdentifier", "OSLogRateLimit", "COMMAND_MODE", "__CF_USER_TEXT_ENCODING"]
            return Resolution(environment: parent.filter {
                !launcherKeys.contains($0.key) && !$0.key.hasPrefix("XPC_")
                    && !$0.key.hasPrefix("LOOM_") && !$0.key.hasPrefix("TERM_PROGRAM")
            })
        case .development:
            var environment: [String: String] = [:]
            var warnings: [String] = []
            for key in ["SSH_AUTH_SOCK", "LANG", "LC_ALL", "LC_CTYPE"] {
                do {
                    let value: String?
                    if let lookup { value = try lookup(key) }
                    else {
                        let output = try capture("/bin/launchctl", ["getenv", key],
                                                 environment: bootstrap(parent: parent), timeout: 3)
                        defer { reap(output.pid) }
                        if output.status == 0, var text = String(data: output.stdout, encoding: .utf8) {
                            if text.hasSuffix("\n") { text.removeLast() }
                            value = text.isEmpty ? nil : text
                        } else { value = nil }
                    }
                    if let value { environment[key] = value }
                    else if key == "SSH_AUTH_SOCK" { warnings.append("launchd session variable \(key) is unavailable") }
                } catch {
                    warnings.append("Could not read launchd session variable \(key)")
                }
            }
            return Resolution(environment: environment, warnings: warnings)
        }
    }

    private static func diagnostic(_ data: Data) -> String {
        String(decoding: data.prefix(2048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func reap(_ pid: pid_t) {
        while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
    }

    // Successful capture transfers an exited, unreaped child to the caller. Keeping
    // its PID reserved lets validation clean up its process group without PID reuse.
    private static func capture(_ executable: String, _ arguments: [String], environment: [String: String],
                                directory: String? = nil, timeout: TimeInterval,
                                onSpawn: ((pid_t) throws -> Void)? = nil,
                                onPoll: (() throws -> Void)? = nil) throws -> (stdout: Data, stderr: Data, status: Int32, pid: pid_t) {
        var output: [Int32] = [0, 0]
        var errors: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { throw LoomError.system("Environment pipe", errno) }
        defer { output.forEach { Darwin.close($0) } }
        guard pipe(&errors) == 0 else { throw LoomError.system("Environment error pipe", errno) }
        defer { errors.forEach { Darwin.close($0) } }
        for fd in output + errors {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw LoomError.system("Environment pipe flags", errno) }
        }
        for fd in [output[0], errors[0]] {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw LoomError.system("Environment pipe mode", errno) }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ error: Int32) throws {
            guard error == 0 else { throw LoomError.system("Environment spawn setup", error) }
        }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO))
        for fd in output + errors { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        if let directory {
            if #available(macOS 26, *) { try check(posix_spawn_file_actions_addchdir(&actions, directory)) }
            else { try check(posix_spawn_file_actions_addchdir_np(&actions, directory)) }
        }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnError = (argv + [nil]).withUnsafeBufferPointer { args in
            (envp + [nil]).withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard spawnError == 0 else { throw LoomError.system("Terminal environment launch", spawnError) }
        var transferred = false
        defer {
            if !transferred {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
            }
        }
        try onSpawn?(pid)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var nextObservation = ProcessInfo.processInfo.systemUptime
        var stdout = Data(), stderr = Data()
        func readAvailable(_ fd: Int32, into destination: inout Data, final: Bool = false) throws {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            for _ in 0..<(final ? 257 : 16) {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count > 0 {
                    destination.append(contentsOf: bytes.prefix(count))
                    guard destination.count <= 4 * 1024 * 1024 else {
                        throw LoomError.message("Terminal startup output exceeded 4 MiB")
                    }
                } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
                else if errno != EINTR { throw LoomError.system("Terminal startup read", errno) }
            }
        }
        while true {
            if ProcessInfo.processInfo.systemUptime >= nextObservation {
                try onPoll?()
                nextObservation = ProcessInfo.processInfo.systemUptime + 0.02
            }
            try readAvailable(output[0], into: &stdout)
            try readAvailable(errors[0], into: &stderr)
            var information = siginfo_t()
            let waited = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
            if waited == 0, information.si_pid == pid {
                try onPoll?()
                try readAvailable(output[0], into: &stdout, final: true)
                try readAvailable(errors[0], into: &stderr, final: true)
                let status = information.si_code == CLD_EXITED ? information.si_status << 8 : information.si_status
                transferred = true
                return (stdout, stderr, status, pid)
            }
            if waited < 0 && errno != EINTR { throw LoomError.system("Terminal startup wait", errno) }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw LoomError.message("Terminal shell startup timed out; check startup files for hangs or input prompts")
            }
            usleep(5_000)
        }
    }
}

@MainActor
final class TerminalEnvironmentCache {
    private var cached: LaunchEnvironment.Resolution?

    func value(resolve: () throws -> LaunchEnvironment.Resolution) throws -> LaunchEnvironment.Resolution {
        if let cached { return cached }
        let result = try resolve()
        cached = result
        return result
    }
}

public enum LoomError: Error, CustomStringConvertible {
    case system(String, Int32)
    case message(String)

    public var description: String {
        switch self {
        case let .system(operation, code): "\(operation): \(String(cString: strerror(code))) (\(code))"
        case let .message(message): message
        }
    }
}
