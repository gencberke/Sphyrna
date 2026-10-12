import Foundation
import os

/// The categories of Loom's unified logging under `LoomSignposts.subsystem` (`local.loom.desktop`).
/// Retention belongs to unified logging; Loom keeps no log files of its own for these.
///
/// Rules every call site follows:
/// - notice and error levels are for state transitions and failures only; per-event detail is
///   `debug` (free unless somebody streams it);
/// - never a prompt, a message, a title or transcript text: ids, counts, durations and error
///   categories are `.public`, a user path goes through `path:` and stays `.private`;
/// - an error that can repeat (a failing write on every event) goes through `error(_:key:_:)`,
///   which emits it at most once per minute per key.
///
/// Read them with
/// `/usr/bin/log show --last 1h --info --debug --predicate 'subsystem == "local.loom.desktop" && category == "Catalog"'`.
public enum LoomLogCategory: String, CaseIterable, Sendable {
    case lifecycle = "Lifecycle"
    case catalog = "Catalog"
    case claudeHooks = "ClaudeHooks"
    case registry = "Registry"
    case toolchain = "Toolchain"
    case scope = "Scope"
    case usage = "Usage"
    case recovery = "Recovery"
    case quit = "Quit"
    case diagnostics = "Diagnostics"
    /// The `loom-hook` helper process (a short-lived process of its own, same subsystem).
    case hookClient = "HookClient"
}

/// Lets an identical message through at most once per interval per key, counting what it held back.
public final class LogRateLimiter: @unchecked Sendable {
    private let interval: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var entries: [String: (last: TimeInterval, suppressed: Int)] = [:]
    private static let maximumKeys = 256

    public init(interval: TimeInterval = 60,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.interval = interval
        self.clock = clock
    }

    /// nil: held back. Otherwise how many identical messages were held back since the last emit.
    public func admit(_ key: String) -> Int? {
        let now = clock()
        return lock.withLock {
            if let entry = entries[key], now - entry.last < interval {
                entries[key] = (entry.last, entry.suppressed + 1)
                return nil
            }
            let suppressed = entries[key]?.suppressed ?? 0
            if entries.count >= Self.maximumKeys, entries[key] == nil,
               let oldest = entries.min(by: { $0.value.last < $1.value.last })?.key {
                entries[oldest] = nil
            }
            entries[key] = (now, 0)
            return suppressed
        }
    }
}

public enum LoomLog {
    static let limiter = LogRateLimiter()

    public static func logger(_ category: LoomLogCategory) -> Logger {
        Logger(subsystem: LoomSignposts.subsystem, category: category.rawValue)
    }

    /// Per-event detail. The message closure runs only when somebody is streaming debug output.
    public static func debug(_ category: LoomLogCategory, _ message: @autoclosure @escaping () -> String) {
        logger(category).debug("\(message(), privacy: .public)")
    }

    public static func notice(_ category: LoomLogCategory, _ message: @autoclosure @escaping () -> String,
                              path: @autoclosure @escaping () -> String? = nil) {
        let log = logger(category)
        if let path = path() {
            log.notice("\(message(), privacy: .public) \(path, privacy: .private)")
        } else {
            log.notice("\(message(), privacy: .public)")
        }
    }

    public static func error(_ category: LoomLogCategory, _ message: @autoclosure @escaping () -> String,
                             path: @autoclosure @escaping () -> String? = nil) {
        let log = logger(category)
        if let path = path() {
            log.error("\(message(), privacy: .public) \(path, privacy: .private)")
        } else {
            log.error("\(message(), privacy: .public)")
        }
    }

    /// An error that may repeat: emitted at most once per minute for `key`, with the count held back.
    public static func error(_ category: LoomLogCategory, key: String,
                             _ message: @autoclosure @escaping () -> String,
                             path: @autoclosure @escaping () -> String? = nil,
                             limiter: LogRateLimiter? = nil) {
        guard let suppressed = (limiter ?? Self.limiter).admit("\(category.rawValue)|\(key)") else { return }
        if suppressed > 0 {
            error(category, "\(message()) (\(suppressed) more since the last report)", path: path())
        } else {
            error(category, message(), path: path())
        }
    }

    /// A short, content-free name for an error: its type and case label, never its payload (a
    /// payload can carry a path, a title or provider text).
    public static func category(of error: any Error) -> String {
        if case let SessionCatalogError.sqlite(operation, code, _) = error { return "sqlite \(operation) \(code)" }
        if let error = error as? ProviderToolchainError {
            switch error {
            case .executableNotFound: return "ProviderToolchainError.executableNotFound"
            case .capabilityProbeFailed: return "ProviderToolchainError.capabilityProbeFailed"
            case .unsupported: return "ProviderToolchainError.unsupported"
            }
        }
        let type = String(describing: Swift.type(of: error))
        // The case label of an enum error, read by reflection: `description` of an error is
        // free text that may carry a path, a title or provider output.
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum, let label = mirror.children.first?.label { return "\(type).\(label)" }
        return type
    }
}
