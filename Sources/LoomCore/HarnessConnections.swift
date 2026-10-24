import Foundation
import Observation

/// Whether Sphyrna offers, checks and reads usage for each harness: the connect switch (D-98). On is the default, so a person
/// who never opened the switch loses nothing. Off only stops Sphyrna's own use of the harness (its models in the pickers, its
/// probe, its usage reading): it never signs the CLI out and never writes the CLI's config.
///
/// The switch itself is a small value read from any thread (the probe asks it from its own actor, the views from the main
/// one) and observable by the views that show it. Where it is kept is the owner's: `onChange` is told each change, and the
/// app stores it in `UIPreferences`; a harness is connected until a change says otherwise.
@Observable
public final class HarnessConnections: @unchecked Sendable {
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private let onChange: (@Sendable (ManagedSession.Provider, Bool) -> Void)?
    private var disconnected: Set<ManagedSession.Provider>

    /// The harnesses a person can connect or disconnect. A synthetic session (a test fixture) is not one.
    public static let switchable: [ManagedSession.Provider] = [.claude, .codex]

    public init(disconnected: Set<ManagedSession.Provider> = [], onChange: (@Sendable (ManagedSession.Provider, Bool) -> Void)? = nil) {
        self.disconnected = disconnected.intersection(Self.switchable)
        self.onChange = onChange
    }

    /// Whether Sphyrna offers `provider`: its models in the pickers, its probe and its usage. Nothing is offered for a
    /// provider with no switch.
    public func isConnected(_ provider: ManagedSession.Provider) -> Bool {
        guard Self.switchable.contains(provider) else { return false }
        return lock.withLock { !disconnected.contains(provider) }
    }

    public func setConnected(_ provider: ManagedSession.Provider, _ connected: Bool) {
        guard Self.switchable.contains(provider) else { return }
        let changed: Bool = lock.withLock {
            connected ? disconnected.remove(provider) != nil : disconnected.insert(provider).inserted
        }
        if changed { onChange?(provider, connected) }
    }
}
