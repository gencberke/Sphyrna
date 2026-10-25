import AppKit
import LoomCore
import Observation

/// What Settings → Connections and Home's "Connect your agents" read: the health of each harness (`HarnessHealthChecker`), the
/// checks that are running, Deep Check's output and the one-time re-check after Install or Sign In. The views and the app's
/// triggers call it; the checking itself runs off the main actor. Nothing here asks on a timer or calls a model (SPEC §12.2).
@MainActor @Observable
public final class HarnessHealthModel {
    /// Deep Check's progress for one harness.
    public enum DeepCheckProgress: Equatable, Sendable {
        case running
        case done(HarnessDeepCheck.Result)
    }

    public let connections: HarnessConnections
    public private(set) var checks: [ManagedSession.Provider: HarnessHealth] = [:]
    public private(set) var checking: Set<ManagedSession.Provider> = []
    public private(set) var deepChecks: [ManagedSession.Provider: DeepCheckProgress] = [:]

    @ObservationIgnored private let checker: HarnessHealthChecker
    @ObservationIgnored private let deepCheckRunner: (@Sendable (ManagedSession.Provider) async -> HarnessDeepCheck.Result)?
    /// The one harness whose Setup button was used since the last activation: the app's next activation checks it again, once,
    /// whatever the floor says (the person went to Terminal and came back).
    @ObservationIgnored private var recheckOnActivation: Set<ManagedSession.Provider> = []
    @ObservationIgnored private var tasks: [ManagedSession.Provider: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation: [ManagedSession.Provider: Int] = [:]
    @ObservationIgnored private var deepTasks: [ManagedSession.Provider: Task<Void, Never>] = [:]
    /// Copy and Open Terminal; a test replaces them.
    @ObservationIgnored var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @ObservationIgnored var openTerminalApp: () -> Bool = { SessionLocationActions.openInTerminal(NSHomeDirectory()) }

    public init(connections: HarnessConnections, checker: HarnessHealthChecker,
                deepCheck: (@Sendable (ManagedSession.Provider) async -> HarnessDeepCheck.Result)? = nil) {
        self.connections = connections
        self.checker = checker
        self.deepCheckRunner = deepCheck
    }

    /// The harnesses Connections lists.
    public static var providers: [ManagedSession.Provider] { HarnessConnections.switchable }

    // MARK: What the views read

    /// Where `provider` stands now: off while its switch is off, checking until the first check answers.
    public func health(of provider: ManagedSession.Provider) -> HarnessHealth {
        guard connections.isConnected(provider) else { return .disabled(provider) }
        return checks[provider] ?? .checking(provider)
    }

    public var healths: [HarnessHealth] { Self.providers.map(health(of:)) }

    public func isChecking(_ provider: ManagedSession.Provider) -> Bool { checking.contains(provider) }

    // MARK: Checks

    /// Checks `provider` (off the main actor); the floor stands unless `force`.
    public func check(_ provider: ManagedSession.Provider, force: Bool = false) {
        guard connections.isConnected(provider) else {
            checks[provider] = nil
            // The checker forgets what it kept of a switched-off harness when it is asked.
            Task { await checker.check(provider) }
            return
        }
        guard tasks[provider] == nil || force else { return }
        checking.insert(provider)
        generation[provider, default: 0] += 1
        let mine = generation[provider]
        // A forced ask while one runs joins that run (the checker shares it); only the newest ask delivers.
        tasks[provider] = Task { [checker] in
            let health = await checker.check(provider, force: force)
            if self.generation[provider] == mine { self.finish(provider, health) }
        }
    }

    private func finish(_ provider: ManagedSession.Provider, _ health: HarnessHealth) {
        tasks[provider] = nil
        checking.remove(provider)
        guard connections.isConnected(provider) else {
            checks[provider] = nil
            return
        }
        if checks[provider] != health { checks[provider] = health }
    }

    /// Every connected harness, each under the floor.
    public func checkAll(force: Bool = false) {
        for provider in Self.providers { check(provider, force: force) }
    }

    /// "Check Again": asks now, whatever the floor says.
    public func checkAgain(_ provider: ManagedSession.Provider) { check(provider, force: true) }

    /// The Connections page opened.
    public func pageOpened() { checkAll() }

    /// The app became active. A harness whose Setup button was used since the last activation is asked again whatever the
    /// floor says, once; the others stand under the floor.
    public func appBecameActive() {
        let forced = recheckOnActivation
        recheckOnActivation = []
        for provider in Self.providers { check(provider, force: forced.contains(provider)) }
    }

    /// A session started or ended.
    public func sessionRunChanged() { checkAll() }

    /// Waits for the checks and Deep Checks that run (a test).
    func settle() async {
        while let task = tasks.values.first ?? deepTasks.values.first { await task.value }
    }

    // MARK: The switch

    /// Turns `provider` on or off. Off, Sphyrna stops offering it, checking it and reading its usage; it never signs the CLI
    /// out and never writes its config. On, it is checked at once.
    public func setConnected(_ provider: ManagedSession.Provider, _ connected: Bool) {
        connections.setConnected(provider, connected)
        check(provider)
    }

    // MARK: Setup

    /// The setup button was used (Copy or Open Terminal): the next activation checks `provider` again.
    func setupStarted(for provider: ManagedSession.Provider) { recheckOnActivation.insert(provider) }

    public var rechecksOnActivation: Set<ManagedSession.Provider> { recheckOnActivation }

    func copy(_ command: HarnessSetupCommand, for provider: ManagedSession.Provider) {
        copyToPasteboard(command.command)
        setupStarted(for: provider)
    }

    /// Opens the Terminal app. Nothing is typed into it and nothing is run.
    func openTerminal(for provider: ManagedSession.Provider) {
        _ = openTerminalApp()
        setupStarted(for: provider)
    }

    // MARK: Account change and Deep Check

    /// The person saw the "Account changed" mark.
    public func acknowledgeAccountChange(_ provider: ManagedSession.Provider) {
        guard checks[provider]?.accountChanged == true else { return }
        checks[provider]?.accountChanged = false
        Task { [checker] in await checker.acknowledgeAccountChange(provider) }
    }

    /// Whether Deep Check is offered at all in this build.
    public var offersDeepCheck: Bool { deepCheckRunner != nil }

    /// Runs the harness's own health command, on the person's request only.
    public func runDeepCheck(_ provider: ManagedSession.Provider) {
        guard let deepCheckRunner, deepChecks[provider] != .running else { return }
        deepChecks[provider] = .running
        deepTasks[provider] = Task {
            let result = await deepCheckRunner(provider)
            self.deepChecks[provider] = .done(result)
            self.deepTasks[provider] = nil
        }
    }
}
