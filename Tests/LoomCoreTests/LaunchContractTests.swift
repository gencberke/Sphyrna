import Foundation
import Testing
@testable import LoomCore

/// G2 and G3 of the cost-and-context rule (goal 3 of D-83): what Sphyrna passes to the Claude it starts, on every route the
/// code builds (a new session, a resume, a fork, in the terminal and in the Chat face, with choices, an opening and a side
/// chat's ask rules). A session holds what the same CLI holds in the user's terminal; the settings carry no text for the model,
/// and no flag adds a prompt, an agent or a tool server. A change to these sets is a decision, and changes the lists here.
@Suite struct LaunchContractTests {
    private static let help = "--settings <settings> --session-id <id> -n, --name <name> --effort <level> --permission-mode <mode> "
        + "--model <model> --plugin-dir <path> --fork-session --thinking-display <mode> --forward-subagent-text"
    private static let capabilities = ProviderCapabilities(version: "2.1.300 (Claude Code)", help: help)
    private static let helper = "/Applications/Sphyrna.app/Contents/MacOS/loom-hook"
    private static let hooks = ClaudeHookLaunchConfiguration(
        helperPath: helper, socketPath: "/tmp/h.sock", authenticationToken: "token", controlSocketPath: "/tmp/c.sock",
        pluginDirectory: "/tmp/plugin")

    struct Launch {
        let label: String
        let profile: ProviderLaunchProfile
        let face: ProviderLaunchProfile.ClaudeFace
    }

    /// Every route in both faces, bare and with every kind of input the code takes.
    private static func launches() throws -> [Launch] {
        let fork = UUID().uuidString.lowercased()
        let routes: [(String, ProviderLaunchProfile.ClaudeRoute)] = [
            ("new", .new(UUID())), ("resume", .resume("provider-session")),
            ("fork", .fork(parent: "provider-session", newID: fork)),
        ]
        var result: [Launch] = []
        for face in [ProviderLaunchProfile.ClaudeFace.terminal, .chat] {
            for (name, route) in routes {
                var variants: [(String, ClaudeLaunchChoices, ProviderLaunchProfile.ClaudeOpening?, [String])] = [
                    ("bare", ClaudeLaunchChoices(), nil, []),
                    ("choices", ClaudeLaunchChoices(permissionMode: "plan", model: "haiku", effort: "low"), nil, []),
                    ("ask", ClaudeLaunchChoices(permissionMode: "ask"), nil, []),
                    ("full access", ClaudeLaunchChoices(permissionMode: "bypassPermissions"), nil, []),
                    ("side chat", ClaudeLaunchChoices(permissionMode: "default"), nil, SessionRuntime.sideChatAskRules),
                ]
                if case .new = route {
                    variants.append(("opening", ClaudeLaunchChoices(),
                                     ProviderLaunchProfile.ClaudeOpening(title: "Title", firstMessage: "--add-dir /tmp hello"), []))
                }
                for (variant, choices, opening, askRules) in variants {
                    let profile = try ProviderLaunchProfile.claude(
                        route: route, capabilities: capabilities, config: URL(fileURLWithPath: "/cfg"),
                        environment: ["PATH": "/usr/bin"], hooks: hooks, effort: "high", model: "sonnet", choices: choices,
                        opening: opening, face: face, askRules: askRules)
                    result.append(Launch(label: "\(face) \(name) \(variant)", profile: profile, face: face))
                }
            }
        }
        return result
    }

    private static func settings(of profile: ProviderLaunchProfile) throws -> [String: Any] {
        let at = try #require(profile.arguments.firstIndex(of: "--settings"))
        return try #require(JSONSerialization.jsonObject(with: Data(profile.arguments[at + 1].utf8)) as? [String: Any])
    }

    private static func keys(in value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return Set(object.keys).union(object.values.flatMap { keys(in: $0) })
        }
        if let array = value as? [Any] { return Set(array.flatMap { keys(in: $0) }) }
        return []
    }

    // MARK: G2, the settings

    @Test func theSettingsCarryOnlyTheRefusalTheAskRulesAndTheNineSilentHooks() throws {
        let nine: Set<String> = ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "Notification", "PermissionRequest",
                                 "SessionEnd", "SubagentStart", "SubagentStop"]
        let launches = try Self.launches()
        #expect(launches.count == 2 * (3 * 5 + 1))
        for launch in launches {
            let settings = try Self.settings(of: launch.profile)
            #expect(launch.profile.arguments.filter { $0 == "--settings" }.count == 1, Comment(rawValue: launch.label))
            #expect(Set(settings.keys).isSubset(of: ["crossSessionInbound", "permissions", "hooks"]),
                    "\(launch.label): \(settings.keys.sorted())")
            #expect(settings["crossSessionInbound"] as? String == "refuse", Comment(rawValue: launch.label))
            if let permissions = settings["permissions"] as? [String: Any] {
                #expect(Set(permissions.keys) == ["ask"], "\(launch.label): \(permissions.keys.sorted())")
            }
            let hooks = try #require(settings["hooks"] as? [String: Any], Comment(rawValue: launch.label))
            #expect(Set(hooks.keys) == nine, "\(launch.label): \(hooks.keys.sorted())")
            for (event, groups) in hooks {
                let groups = try #require(groups as? [[String: Any]])
                #expect(groups.count == 1, "\(launch.label) \(event)")
                for group in groups {
                    #expect(Set(group.keys) == ["hooks"], "\(launch.label) \(event): \(group.keys.sorted())")
                    for handler in try #require(group["hooks"] as? [[String: Any]]) {
                        // One command, no arguments, one second; it prints nothing (G4).
                        #expect(handler["type"] as? String == "command", "\(launch.label) \(event)")
                        #expect(handler["command"] as? String == Self.helper, "\(launch.label) \(event)")
                        #expect((handler["args"] as? [Any] ?? []).isEmpty, "\(launch.label) \(event)")
                        #expect((handler["timeout"] as? Int) == 1, "\(launch.label) \(event)")
                        #expect(Set(handler.keys).isSubset(of: ["type", "command", "args", "timeout"]),
                                "\(launch.label) \(event): \(handler.keys.sorted())")
                    }
                }
            }
            // No key anywhere that would hand text to the model.
            let text = Self.keys(in: settings).intersection(["additionalContext", "systemMessage", "outputStyle", "prompt"])
            #expect(text.isEmpty, "\(launch.label): \(text.sorted())")
        }
    }

    // MARK: G3, the flags and the environment

    private static let sharedFlags: Set<String> = [
        "--session-id", "--resume", "--fork-session", "--effort", "--permission-mode", "--model", "--settings", "--plugin-dir", "-n",
    ]
    /// `ProviderLaunchProfile.claudeChatArguments` and the options the Chat face adds where the CLI lists them.
    private static let chatFlags: Set<String> = [
        "-p", "--input-format", "--output-format", "--verbose", "--include-partial-messages", "--replay-user-messages",
        "--permission-prompt-tool", "--allow-dangerously-skip-permissions", "--thinking-display", "--forward-subagent-text",
    ]
    private static let neverFlags = [
        "--append-system-prompt", "--system-prompt", "--agents", "--mcp-config", "--bare", "--add-dir",
        "--append-system-prompt-file", "--system-prompt-file", "--strict-mcp-config", "--tools",
    ]

    @Test func everyFlagIsOneOfTheKnownOnesAndNoFlagAddsAPromptAnAgentOrAToolServer() throws {
        var seen: Set<String> = []
        for launch in try Self.launches() {
            let flags = launch.profile.arguments.filter { $0.hasPrefix("-") }
            let allowed = launch.face == .chat ? Self.sharedFlags.union(Self.chatFlags) : Self.sharedFlags
            seen.formUnion(flags)
            #expect(Set(flags).isSubset(of: allowed), "\(launch.label): \(Set(flags).subtracting(allowed).sorted())")
            for never in Self.neverFlags {
                #expect(!launch.profile.arguments.contains(never), "\(launch.label): \(never)")
                #expect(!launch.profile.trailingArguments.contains(never) || launch.profile.trailingArguments.first == "--",
                        "\(launch.label): \(never) outside the prompt")
            }
            // A first message goes after `--`, or over stdin in the Chat face; it never becomes an option.
            #expect(launch.profile.trailingArguments.isEmpty || launch.profile.trailingArguments.first == "--", Comment(rawValue: launch.label))
            if launch.face == .chat { #expect(launch.profile.trailingArguments.isEmpty, Comment(rawValue: launch.label)) }
            // The plugin is passed once, with the folder Sphyrna wrote.
            let plugin = launch.profile.arguments.indices.filter { launch.profile.arguments[$0] == "--plugin-dir" }
            #expect(plugin.count == 1 && launch.profile.arguments[plugin[0] + 1] == "/tmp/plugin", Comment(rawValue: launch.label))
        }
        // The lists are tight: a flag nothing passes any more is taken out of them.
        #expect(seen == Self.sharedFlags.union(Self.chatFlags), "\(seen.symmetricDifference(Self.sharedFlags.union(Self.chatFlags)).sorted())")
    }

    @Test func theEnvironmentSphyrnaAddsIsTheKnownSetAndHoldsNoText() throws {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/someone"]
        let session = UUID()
        let common: Set<String> = [
            "TERM", "COLORTERM", "LOOM_RUN_ID", "LOOM_SESSION_ID", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_DISABLE_AGENT_VIEW",
            "LOOM_HOOK_SOCKET", "LOOM_HOOK_TOKEN", "LOOM_CLI", "SPHYRNA_CLI", "LOOM_CONTROL_SOCKET",
        ]
        let chatOnly: Set<String> = ["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS", "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"]
        // The supervisor adds LOOM_MANAGED_RUN_ID at the spawn (`ProcessSupervisor.launch`); nothing else is added after this.
        for face in [ProviderLaunchProfile.ClaudeFace.terminal, .chat] {
            for route in [ProviderLaunchProfile.ClaudeRoute.new(session), .resume("provider-session"),
                          .fork(parent: "provider-session", newID: UUID().uuidString.lowercased())] {
                let environment = LaunchEnvironment.make(base: base, runID: UUID(), sessionID: session)
                let profile = try ProviderLaunchProfile.claude(
                    route: route, capabilities: Self.capabilities, config: URL(fileURLWithPath: "/cfg"), environment: environment,
                    hooks: Self.hooks, face: face)
                let added = Set(profile.environment.keys).subtracting(base.keys)
                #expect(added == (face == .chat ? common.union(chatOnly) : common), "\(face) \(route): \(added.sorted())")
                for (key, value) in profile.environment where !base.keys.contains(key) {
                    // Paths, ids and switches: no variable of Sphyrna's carries prose the model would read.
                    #expect(value.count <= 120 && !value.contains("\n"), "\(key)")
                }
            }
        }
    }
}
