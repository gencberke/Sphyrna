import Foundation

/// One harness as a value: everything a gate needs to know about it, with no behaviour. The facts that used to sit in
/// per-provider switches (`HarnessHealth.command`, the profile variable, `HarnessSetup`'s install and sign-in lines,
/// `HarnessDeepCheck`'s arguments) live here beside the capability row (optimizer 6 and 11, FB6-13).
///
/// `capabilities` is the harness's row with nothing startable (`HarnessCapabilities.intrinsic(of:)`); `startable` is the
/// build's separate answer. A production build still narrows the set through `BuildIdentity.startableProviders`.
public struct HarnessDescriptor: Equatable, Sendable, Identifiable {
    /// How the public mark is interpreted, without coupling the catalogue to a UI framework.
    public enum MarkRendering: Equatable, Sendable {
        case image, template, luminanceMask, boxedText(String)
    }

    public let id: HarnessID
    /// The name the user reads ("Claude", "Codex", "opencode").
    public let displayName: String
    /// The executable's name on the terminal environment's PATH.
    public let command: String
    /// The mark's asset or logical key; a boxed-text rendering needs no file.
    public let mark: String
    /// A second mark file to draw when the first is not in the bundle (Codex's template image).
    public let markFallback: String?
    public let markRendering: MarkRendering
    /// The built-in onboarding entries remain visible when missing; optional harnesses appear only when found.
    public let showsOnboardingWhenMissing: Bool
    /// The vendor's install command, shown and never run. Nil when it is not known yet (agy: P1's spike).
    public let install: HarnessSetupCommand?
    /// The vendor's sign-in command, shown and never run.
    public let signIn: HarnessSetupCommand?
    /// The CLI's own health command's arguments ("doctor"), nil when it has none.
    public let doctorArguments: [String]?
    /// The vendor's documentation, for the person setting the CLI up.
    public let docs: URL?
    /// The verified variable that moves the CLI's profile folder (for isolation), if known.
    public let profileVariable: String?
    /// The folder under the home directory the CLI keeps its profile in, when `profileVariable` is unset.
    public let profileFolder: String
    /// The oldest and recommended versions; nil until they are known (opencode, agy and pi: P1's spike).
    public let versions: HarnessVersionTable?
    /// Codex: a CLI whose `app-server --help` lacks `--listen` counts as below the minimum.
    public let requiresAppServerListen: Bool
    /// Whether Deep Check pins the default profile folder too. Codex names its login after `CODEX_HOME`, so it is always
    /// pinned; Claude names its stored login after an explicit folder, so only a profile of the toolchain's own is pinned.
    public let pinsDefaultProfile: Bool
    /// What the harness may do, with nothing startable.
    public let capabilities: HarnessCapabilities
    /// Whether the switch is on for a harness the person has not chosen yet: Claude and Codex yes, the others no (FB6-13).
    public let onWhenFound: Bool
    /// Whether this build has a start path for the harness at all (production narrows it further).
    public let startable: Bool
    /// The stored provider this build runs the harness with; nil for a harness that has none yet.
    public let provider: ManagedSession.Provider?
    /// Product modes whose mapping has been established for this harness, and its safe fallback.
    public let modes: [HarnessMode]
    public let agentModes: [HarnessMode]
    public let defaultMode: HarnessMode?
    /// Whether same-named modes may carry between this harness and another compatible one.
    public let sharesCrossHarnessModes: Bool
    /// Effort levels known for the harness's own default model when no model was named.
    public let defaultEfforts: [String]

    public init(
        id: HarnessID, displayName: String, command: String, mark: String, markFallback: String? = nil,
        install: HarnessSetupCommand? = nil, signIn: HarnessSetupCommand? = nil, doctorArguments: [String]? = nil,
        docs: URL? = nil, profileVariable: String? = nil, profileFolder: String,
        versions: HarnessVersionTable? = nil, requiresAppServerListen: Bool = false, pinsDefaultProfile: Bool = false,
        capabilities: HarnessCapabilities, onWhenFound: Bool, startable: Bool, provider: ManagedSession.Provider? = nil,
        markRendering: MarkRendering = .image, showsOnboardingWhenMissing: Bool = false,
        modes: [HarnessMode] = [], agentModes: [HarnessMode] = [], defaultMode: HarnessMode? = nil,
        defaultEfforts: [String] = [], sharesCrossHarnessModes: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.command = command
        self.mark = mark
        self.markFallback = markFallback
        self.markRendering = markRendering
        self.showsOnboardingWhenMissing = showsOnboardingWhenMissing
        self.install = install
        self.signIn = signIn
        self.doctorArguments = doctorArguments
        self.docs = docs
        self.profileVariable = profileVariable
        self.profileFolder = profileFolder
        self.versions = versions
        self.requiresAppServerListen = requiresAppServerListen
        self.pinsDefaultProfile = pinsDefaultProfile
        self.capabilities = capabilities
        self.onWhenFound = onWhenFound
        self.startable = startable
        self.provider = provider
        self.modes = modes
        self.agentModes = agentModes
        self.defaultMode = defaultMode
        self.defaultEfforts = defaultEfforts
        self.sharesCrossHarnessModes = sharesCrossHarnessModes
    }

    /// The doctor command as a person reads it ("claude doctor"), nil when the CLI has none.
    public var doctorCommand: String? {
        doctorArguments.map { ([command] + $0).joined(separator: " ") }
    }

    /// Where the CLI keeps its profile under the home directory.
    public var defaultProfileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(profileFolder, isDirectory: true)
    }
}
