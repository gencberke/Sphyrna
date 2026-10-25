import Foundation

/// Checks each harness's health: finds its CLI through the toolchain (the supervisor's login-shell PATH, never a second walk),
/// asks the probe for the account and limits, and judges both (`HarnessHealth.evaluate`).
///
/// - A harness that is switched off is not checked and not resolved: its answer is `.disabled`, and what was kept is dropped.
/// - An answer younger than `floor` stands unless the caller forces a new one (Check Again, and the first activation after
///   Install or Sign In). There are no timers: callers decide when to ask, and nothing here calls a model (SPEC §12.2).
/// - Concurrent checks of one harness share one run.
/// - A check that finds another email or plan than the one before marks `accountChanged`, kept until `acknowledgeAccountChange`.
public actor HarnessHealthChecker {
    /// How long a check stands without a forced one.
    public static let defaultFloor: TimeInterval = 5 * 60

    private let connections: HarnessConnections
    private let probe: HarnessProbe
    private let toolchain: @Sendable (ManagedSession.Provider) async throws -> ProviderToolchain
    private let floor: TimeInterval
    private let clock: @Sendable () -> Date
    private var checked: [ManagedSession.Provider: HarnessHealth] = [:]
    /// The last account that named a person (a subscription or an API key), kept in memory to notice a change.
    private var lastAccount: [ManagedSession.Provider: HarnessAccount] = [:]
    private var running: [ManagedSession.Provider: Task<HarnessHealth, Never>] = [:]
    /// Harnesses seen switched off: the probe never heard of it, so its last reading may be old; the next check asks it anew.
    private var staleProbe: Set<ManagedSession.Provider> = []

    public init(connections: HarnessConnections, probe: HarnessProbe,
                toolchain: @escaping @Sendable (ManagedSession.Provider) async throws -> ProviderToolchain,
                floor: TimeInterval = HarnessHealthChecker.defaultFloor, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.connections = connections
        self.probe = probe
        self.toolchain = toolchain
        self.floor = floor
        self.clock = clock
    }

    /// The last check of `provider`, with no ask; nil when none was made or the harness is switched off.
    func lastHealth(of provider: ManagedSession.Provider) -> HarnessHealth? {
        connections.isConnected(provider) ? checked[provider] : nil
    }

    /// Checks `provider`: the last answer while it is younger than the floor, else a new check (always, with `force`).
    @discardableResult
    public func check(_ provider: ManagedSession.Provider, force: Bool = false) async -> HarnessHealth {
        guard connections.isConnected(provider) else {
            forget(provider)
            return .disabled(provider)
        }
        if let task = running[provider] { return await task.value }
        let now = clock()
        if !force, let last = checked[provider], let at = last.checkedAt, now >= at, now.timeIntervalSince(at) < floor {
            return last
        }
        let task = Task { await self.run(provider, force: force) }
        running[provider] = task
        return await task.value
    }

    /// The person has seen the "Account changed" mark: it goes.
    public func acknowledgeAccountChange(_ provider: ManagedSession.Provider) {
        checked[provider]?.accountChanged = false
    }

    private func forget(_ provider: ManagedSession.Provider) {
        checked[provider] = nil
        lastAccount[provider] = nil
        staleProbe.insert(provider)
    }

    private func run(_ provider: ManagedSession.Provider, force: Bool) async -> HarnessHealth {
        defer { running[provider] = nil }
        let force = force || staleProbe.remove(provider) != nil
        var health: HarnessHealth
        do {
            let resolved = try await toolchain(provider)
            if HarnessVersionTable.status(of: resolved.capabilities, provider: provider) == .belowMinimum {
                // A CLI this old is not asked: it may not answer what the probe sends.
                health = .evaluate(provider: provider, toolchain: resolved, reading: nil, at: clock())
            } else {
                let reading = await probe.probe(harness: provider, force: force)
                health = .evaluate(provider: provider, toolchain: resolved, reading: reading, at: clock())
            }
        } catch ProviderToolchainError.executableNotFound {
            health = .notFound(provider, at: clock())
        } catch {
            health = .unreadable(provider, at: clock())
        }
        // Switched off while the check ran: what it read is not kept.
        guard connections.isConnected(provider) else {
            forget(provider)
            return .disabled(provider)
        }
        health.accountChanged = noticeAccount(of: health) || (checked[provider]?.accountChanged ?? false)
        checked[provider] = health
        return health
    }

    /// Whether `health` names another person than the last check that named one; remembers the one it names.
    private func noticeAccount(of health: HarnessHealth) -> Bool {
        switch health.account {
        case .subscription?, .apiKey?:
            guard let account = health.account else { return false }
            defer { lastAccount[health.provider] = account }
            return lastAccount[health.provider].map { $0 != account } ?? false
        default:
            return false
        }
    }
}
