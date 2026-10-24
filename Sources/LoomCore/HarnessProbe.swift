import Foundation

// A harness's account, limit windows, token totals and model list, in the same neutral types for Claude Code and Codex
// (D-94). Two later packages read them: usage (the limit windows and token totals of each harness) and connections (each
// harness's account and whether it is ready). The composer reads the model list through `ModelCatalog`.
//
// Nothing here starts a thread or a turn or calls a model (SPEC §12.2). Codex is asked through a short-lived
// `codex app-server` in a run scope (`CodexProbeSource`); Claude through the plan-limits child it already has
// (`ClaudeProbeSource`).

/// Who is signed in to a harness. Held in memory only: it is never stored, logged or journaled, and it has no `Codable`
/// conformance on purpose. Its description and reflection leave the email out, so a reading printed by mistake does not carry it.
public enum HarnessAccount: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Read, and nobody is signed in.
    case none
    /// An API key (or a cloud provider's own credentials) stands for the login: no subscription, no email.
    case apiKey
    /// A subscription login. The plan is the CLI's own word (`pro`, `max`, `plus`), lower case as it came.
    case subscription(email: String?, plan: String?)

    public var description: String {
        switch self {
        case .none: "no account"
        case .apiKey: "API key"
        case .subscription: "subscription (details withheld)"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}

/// One rate-limit window of a harness: the five-hour and weekly windows of a Claude plan, a Codex bucket's primary and
/// secondary windows.
public struct HarnessLimitWindow: Equatable, Sendable, Identifiable {
    /// Stable between readings: `five_hour`, `seven_day`; for Codex the bucket's limit id and `primary` or `secondary`.
    public var id: String
    /// "5-hour", "Weekly", or a bucket's own name before the length of the window.
    public var name: String
    /// How long the window runs, from one reset to the next; nil when the harness did not say.
    public var durationMinutes: Int?
    /// Percent of the window used, 0...100.
    public var usedPercent: Int
    /// When the window resets; nil when the harness did not say.
    public var resetsAt: Date?

    public var remainingPercent: Int { 100 - usedPercent }

    public init(id: String, name: String, durationMinutes: Int?, usedPercent: Int, resetsAt: Date?) {
        self.id = id
        self.name = name
        self.durationMinutes = durationMinutes
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
    }

    /// A window whose reset time has passed describes a window that no longer exists.
    public func isCurrent(at now: Date) -> Bool { resetsAt.map { $0 > now } ?? true }

    /// "5-hour", "Weekly", "30-minute", "3-day": a window length in words.
    public static func lengthName(minutes: Int) -> String {
        if minutes == 7 * 1_440 { return "Weekly" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

/// One day's tokens, as the harness counted them. `day` is the harness's own date text (`2026-10-24`).
public struct HarnessTokenDay: Equatable, Sendable {
    public var day: String
    public var tokens: Int64

    public init(day: String, tokens: Int64) {
        self.day = day
        self.tokens = tokens
    }
}

/// One model a harness offers.
public struct HarnessModel: Equatable, Sendable, Identifiable {
    /// What is passed to the CLI to pick it.
    public var id: String
    public var displayName: String
    public var isDefault: Bool
    /// The effort levels it takes, in the order the harness lists them (empty: none, or none said).
    public var efforts: [String]
    public var defaultEffort: String?

    public init(id: String, displayName: String, isDefault: Bool, efforts: [String], defaultEffort: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }
}

/// What one ask of a harness answered. A part that is nil was not read (it failed, or the harness has none to give); an
/// empty part was read and is empty. Only an answer with no part at all is a failure.
public struct HarnessProbeAnswer: Equatable, Sendable {
    public var account: HarnessAccount?
    public var version: String?
    public var windows: [HarnessLimitWindow]?
    public var lifetimeTokens: Int64?
    public var tokenDays: [HarnessTokenDay]?
    public var models: [HarnessModel]?

    public init(account: HarnessAccount? = nil, version: String? = nil, windows: [HarnessLimitWindow]? = nil,
                lifetimeTokens: Int64? = nil, tokenDays: [HarnessTokenDay]? = nil, models: [HarnessModel]? = nil) {
        self.account = account
        self.version = version
        self.windows = windows
        self.lifetimeTokens = lifetimeTokens
        self.tokenDays = tokenDays
        self.models = models
    }

    var isEmpty: Bool {
        account == nil && windows == nil && lifetimeTokens == nil && tokenDays == nil && models == nil
    }
}

/// A harness as the probe last knew it. Claude's reading has no token days and no models (the usage index and the model
/// catalog own those); Codex's has all of it.
public struct HarnessReading: Equatable, Sendable {
    public var provider: ManagedSession.Provider
    /// Nil when no ask has named the account (a failed ask, or a harness that does not say).
    public var account: HarnessAccount?
    public var version: String?
    public var windows: [HarnessLimitWindow]
    public var lifetimeTokens: Int64?
    public var tokenDays: [HarnessTokenDay]
    public var models: [HarnessModel]
    /// When the last ask that read something answered.
    public var readAt: Date

    public init(provider: ManagedSession.Provider, account: HarnessAccount? = nil, version: String? = nil,
                windows: [HarnessLimitWindow] = [], lifetimeTokens: Int64? = nil, tokenDays: [HarnessTokenDay] = [],
                models: [HarnessModel] = [], readAt: Date) {
        self.provider = provider
        self.account = account
        self.version = version
        self.windows = windows
        self.lifetimeTokens = lifetimeTokens
        self.tokenDays = tokenDays
        self.models = models
        self.readAt = readAt
    }

    /// The windows that still exist at `now`.
    public func currentWindows(at now: Date) -> [HarnessLimitWindow] { windows.filter { $0.isCurrent(at: now) } }

    /// This reading updated by a newer `answer`: a part the answer did not read is kept from this one, unless the answer
    /// names another account, whose numbers are not these.
    func updated(by answer: HarnessProbeAnswer, at now: Date) -> HarnessReading {
        let sameAccount = answer.account == nil || account == nil || answer.account == account
        var merged = sameAccount ? self : HarnessReading(provider: provider, readAt: now)
        merged.account = answer.account ?? merged.account
        merged.version = answer.version ?? merged.version
        merged.windows = answer.windows ?? merged.windows
        merged.lifetimeTokens = answer.lifetimeTokens ?? (answer.tokenDays == nil ? merged.lifetimeTokens : nil)
        merged.tokenDays = answer.tokenDays ?? merged.tokenDays
        merged.models = answer.models ?? merged.models
        merged.readAt = now
        return merged
    }
}

/// Where a harness's answer comes from; a fake stands in for it in tests. nil means nothing was read.
public protocol HarnessProbeSource: Sendable {
    func read() async -> HarnessProbeAnswer?
}

/// Asks each connected harness for its account, windows, token totals and models, and remembers the answer.
///
/// - A harness that is switched off (`HarnessConnections`) is never asked, and its remembered reading is dropped.
/// - An answer younger than `floor` is returned as it is unless the caller forces a new one; a failed ask counts as an
///   ask, so a broken CLI is not started again and again. There are no timers: callers decide when to ask.
/// - A failed or partial ask keeps the last good parts of the reading, unless it names another account.
/// - Concurrent asks for one harness share one run.
/// - `onReading` is told each reading an ask updated (the app hands Codex's models to `ModelCatalog` through it).
public actor HarnessProbe {
    /// How long an answer stands without a forced ask.
    public static let defaultFloor: TimeInterval = 5 * 60

    private let connections: HarnessConnections
    private let sources: [ManagedSession.Provider: any HarnessProbeSource]
    private let floor: TimeInterval
    private let clock: @Sendable () -> Date
    private let onReading: (@Sendable (HarnessReading) -> Void)?
    private var readings: [ManagedSession.Provider: HarnessReading] = [:]
    private var lastAsked: [ManagedSession.Provider: Date] = [:]
    private var running: [ManagedSession.Provider: Task<HarnessReading?, Never>] = [:]

    public init(connections: HarnessConnections, sources: [ManagedSession.Provider: any HarnessProbeSource],
                floor: TimeInterval = HarnessProbe.defaultFloor, clock: @escaping @Sendable () -> Date = { Date() },
                onReading: (@Sendable (HarnessReading) -> Void)? = nil) {
        self.onReading = onReading
        self.connections = connections
        self.sources = sources
        self.floor = floor
        self.clock = clock
    }

    /// The harnesses the probe can ask: one private place to say it, for the capability table to replace (`usageLimits`).
    private func asks(_ provider: ManagedSession.Provider) -> Bool {
        (provider == .claude || provider == .codex) && sources[provider] != nil
    }

    /// The reading of `harness`: the last answer when it is younger than the floor, else a new ask (always, with `force`).
    /// nil for a harness that is switched off or has no answer yet.
    @discardableResult
    public func probe(harness: ManagedSession.Provider, force: Bool = false) async -> HarnessReading? {
        guard asks(harness), connections.isConnected(harness) else {
            readings[harness] = nil
            lastAsked[harness] = nil
            return nil
        }
        if let task = running[harness] { return await task.value }
        if !force, let asked = lastAsked[harness], clock().timeIntervalSince(asked) < floor, clock() >= asked {
            return readings[harness]
        }
        guard let source = sources[harness] else { return nil }
        lastAsked[harness] = clock()
        let task = Task { [weak self] () -> HarnessReading? in
            let answer = await source.read()
            return await self?.finish(harness, answer)
        }
        running[harness] = task
        return await task.value
    }

    /// The last reading of `harness`, with no ask; nil when it is switched off.
    public func lastReading(of harness: ManagedSession.Provider) -> HarnessReading? {
        connections.isConnected(harness) ? readings[harness] : nil
    }

    private func finish(_ harness: ManagedSession.Provider, _ answer: HarnessProbeAnswer?) -> HarnessReading? {
        running[harness] = nil
        // Switched off while the ask ran: what it read is not kept.
        guard connections.isConnected(harness) else {
            readings[harness] = nil
            return nil
        }
        guard let answer, !answer.isEmpty else { return readings[harness] }
        let now = clock()
        let base = readings[harness] ?? HarnessReading(provider: harness, readAt: now)
        let updated = base.updated(by: answer, at: now)
        readings[harness] = updated
        onReading?(updated)
        return updated
    }
}
