import Foundation
import Observation

/// Whether Sphyrna offers, checks and reads usage for each harness: the connect switch (D-98). A harness is on when the
/// person has not chosen otherwise and its descriptor says `onWhenFound` (Claude and Codex on, opencode, agy and pi off,
/// FB6-13). Off only stops Sphyrna's own use of the harness (its models in the pickers, its probe, its usage reading): it
/// never signs the CLI out and never writes the CLI's config.
///
/// The switch itself is a small value read from any thread (the probe asks it from its own actor, the views from the main
/// one) and observable by the views that show it. Where it is kept is the owner's: `onChange` is told each change, and the
/// app stores it in `UIPreferences`; a harness is connected until a change says otherwise. An explicit choice is kept for
/// every harness the catalogue describes, including one that is not on the PATH yet: the page disables that switch, but
/// the choice made before the CLI moved is not lost.
@Observable
public final class HarnessConnections: @unchecked Sendable {
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private let onChange: (@Sendable (HarnessID, Bool) -> Void)?
    /// The person's explicit choices; a harness with no entry takes its descriptor's `onWhenFound`.
    private var choices: [HarnessID: Bool]

    /// The harnesses a person can connect or disconnect, in Connections' order: every harness the catalogue describes. A
    /// synthetic session (a test fixture) is not one.
    public static var harnesses: [HarnessID] { HarnessCatalogue.ids }

    /// The providers this build can switch, for the code that still speaks in providers; C2 moves those callers to
    /// `harnesses`.
    public static var switchable: [ManagedSession.Provider] { harnesses.compactMap(\.provider) }

    /// The old spelling: the providers switched off, as `UIPreferences.disconnectedHarnesses` gives them.
    public init(disconnected: Set<ManagedSession.Provider> = [],
                onChange: (@Sendable (ManagedSession.Provider, Bool) -> Void)? = nil) {
        var choices: [HarnessID: Bool] = [:]
        for provider in disconnected {
            let id = HarnessID(provider)
            if id.isKnown { choices[id] = false }
        }
        self.choices = choices
        if let onChange {
            self.onChange = { id, connected in
                guard let provider = id.provider, HarnessID(provider) == id else { return }
                onChange(provider, connected)
            }
        } else {
            self.onChange = nil
        }
    }

    /// The new spelling: the explicit choices by harness id, for `UIPreferences.harnessConnections`.
    public init(choices: [HarnessID: Bool], onChange: (@Sendable (HarnessID, Bool) -> Void)? = nil) {
        self.choices = choices.filter { $0.key.isKnown }
        self.onChange = onChange
    }

    /// Whether Sphyrna offers `id`: its models in the pickers, its probe and its usage. False for an id this build does
    /// not describe.
    public func isOn(_ id: HarnessID) -> Bool {
        guard let descriptor = HarnessCatalogue.descriptor(for: id) else { return false }
        return lock.withLock { choices[id] ?? descriptor.onWhenFound }
    }

    /// Turns `id` on or off. A choice that equals the descriptor's `onWhenFound` is written as the file's absence of it, so
    /// an older file keeps meaning what it meant (Claude and Codex on) and a choice the person made for a harness that is
    /// off by default is kept.
    public func setOn(_ id: HarnessID, _ on: Bool) {
        guard let descriptor = HarnessCatalogue.descriptor(for: id) else { return }
        let changed: Bool = lock.withLock {
            guard (choices[id] ?? descriptor.onWhenFound) != on else { return false }
            if on == descriptor.onWhenFound { choices[id] = nil } else { choices[id] = on }
            return true
        }
        if changed { onChange?(id, on) }
    }

    /// The explicit choices, for `UIPreferences.harnessConnections`: only the harnesses the person has chosen against
    /// their descriptor's default.
    public var explicitChoices: [String: Bool] {
        lock.withLock { Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value) }) }
    }

    // MARK: Providers (C2 moves these callers to the harness ids)

    public func isConnected(_ provider: ManagedSession.Provider) -> Bool {
        guard provider != .synthetic else { return false }
        return isOn(HarnessID(provider))
    }

    public func setConnected(_ provider: ManagedSession.Provider, _ connected: Bool) {
        guard provider != .synthetic else { return }
        setOn(HarnessID(provider), connected)
    }
}
