import Foundation

/// Where a harness stands before any check of the CLI itself: found or not on the terminal environment's PATH, and the
/// person's switch (FB6-13 steps 2–4). The three states the Connections page shows.
public enum HarnessAvailabilityState: String, Equatable, Sendable {
    /// Found on the PATH and switched on.
    case on
    /// Found on the PATH and switched off: Sphyrna does not probe, check or read it.
    case off
    /// Not on the PATH: the harness is Off and its switch is disabled, with "Not found on this Mac" under its name.
    case notFound
}

/// One harness's availability at one moment. A value: `HarnessAvailability.all(in:isOn:)` judges it from a PATH lookup and
/// the switch, with no process started and no `--version` run.
public struct HarnessAvailability: Equatable, Sendable {
    public let id: HarnessID
    public let state: HarnessAvailabilityState
    /// The executable found on the PATH, nil when it was not.
    public let executable: String?
    /// How many folders the PATH lookup searched.
    public let searchedFolders: Int

    public init(id: HarnessID, state: HarnessAvailabilityState, executable: String? = nil, searchedFolders: Int = 0) {
        self.id = id
        self.state = state
        self.executable = executable
        self.searchedFolders = searchedFolders
    }

    public var isFound: Bool { executable != nil }
    /// Whether the switch can be used: never for a harness that is not found (FB6-13 step 3).
    public var canSwitch: Bool { state != .notFound }
    public var isOn: Bool { state == .on }

    /// The availability of one harness: found by a PATH lookup on `environment`, and On or Off by `isOn`. A harness that is
    /// not found is Not found whatever the switch says, so a missing CLI can never read On.
    public static func of(_ descriptor: HarnessDescriptor, in environment: [String: String], isOn: Bool) -> HarnessAvailability {
        let found = ProviderToolchainProbe.find(descriptor.command, in: environment)
        let searched = found?.searched ?? (environment["PATH"] ?? "").split(separator: ":").count
        let state: HarnessAvailabilityState = found == nil ? .notFound : (isOn ? .on : .off)
        return HarnessAvailability(id: descriptor.id, state: state, executable: found?.path, searchedFolders: searched)
    }

    /// Every harness the catalogue describes, in its order, judged from one PATH and the switch.
    public static func all(in environment: [String: String], isOn: (HarnessID) -> Bool) -> [HarnessAvailability] {
        HarnessCatalogue.all.map { of($0, in: environment, isOn: isOn($0.id)) }
    }

    /// Every harness the catalogue describes, judged from the connect switch's own choices.
    public static func all(in environment: [String: String], connections: HarnessConnections) -> [HarnessAvailability] {
        all(in: environment, isOn: { connections.isOn($0) })
    }
}

/// Reads the catalogue's availability from the terminal environment the toolchain resolver already holds (one login shell,
/// cached after it succeeds): a PATH lookup per harness, no CLI run.
public struct HarnessAvailabilityReader: Sendable {
    private let environment: @Sendable () async throws -> [String: String]

    public init(environment: @escaping @Sendable () async throws -> [String: String]) {
        self.environment = environment
    }

    /// The app's reader: `SystemProviderToolchains.terminalEnvironment()`, the same cached environment sessions resolve
    /// their toolchain in, so a harness installed somewhere the login shell knows is found without a second shell.
    public init(toolchains: SystemProviderToolchains) {
        self.init(environment: { try await toolchains.terminalEnvironment().environment })
    }

    public func read(_ connections: HarnessConnections) async throws -> [HarnessAvailability] {
        HarnessAvailability.all(in: try await environment(), connections: connections)
    }
}
