import Foundation
import LoomCore

/// Ask, the Chat bar's mode that researches and answers and changes nothing (D-63, spike S9), as the CLI's own settings:
///
/// - the CLI's `dontAsk` mode, which refuses whatever would ask (Bash keeps the CLI's own read-only list);
/// - deny rules for the tools that edit, which hold in every mode (so Full access cannot be Ask's Bash-free twin);
/// - an output style that tells the model how to behave (`ClaudeLoomPlugin.askStyleName`).
///
/// All of it goes through control requests, never on the command line: a rule given at launch cannot be taken back, and
/// `--resume` restores neither the live rules nor the style. The driver sets and clears the three together
/// (`ChatSessionDriver`), so leaving Ask through the mode picker never leaves a session with edits refused and Bash open.
public enum ChatAskMode {
    /// The tools Ask refuses by rule.
    public static let deniedTools = ["Write", "Edit", "NotebookEdit"]
    /// The research tools Ask allows by rule: without it `dontAsk` refuses both web tools (spike S9b).
    public static let allowedTools = ["WebFetch", "WebSearch"]
    /// Tools whose allow rule of the user's is left alone: they read. Any other allow rule that is not Loom's own is
    /// mirrored into `deny` while Ask is on (Bash and MCP tools can change things outside the work folder).
    public static let readOnlyTools: Set<String> = ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "Agent"]

    /// The CLI's mode for Ask.
    public static let mode = PermissionMode(rawValue: ClaudePermissionMode.ask.cliValue)

    /// The `deny` list for the rules the CLI holds now: the edit tools, then the text of every allow rule that is not Loom's
    /// own (`flagSettings`) and is not for a read-only tool. In `dontAsk` a user's allow rule (from user, project, local or
    /// policy settings) is honoured, so a Bash rule would let a command run; a deny rule with the same text beats it (S9b).
    public static func denyList(mirroring rules: [PermissionRuleRow]) -> [String] {
        var deny = deniedTools
        for row in rules where row.behavior == "allow" && row.source != "flagSettings" {
            let tool = row.rule.split(separator: "(", maxSplits: 1).first.map(String.init) ?? row.rule
            guard !readOnlyTools.contains(tool), !deny.contains(row.rule) else { continue }
            deny.append(row.rule)
        }
        return deny
    }

    /// The whole `permissions` object of the live layer. `apply_flag_settings` replaces the object as a whole, so every
    /// call sends it complete, and this is the one place that builds it. Never holds `disableBypassPermissionsMode`: it is
    /// a one-way door (Full access cannot be taken again in that process).
    public static func permissions(mirroring rules: [PermissionRuleRow] = []) -> JSONValue {
        .object(["allow": .array(allowedTools.map(JSONValue.string)),
                 "deny": .array(denyList(mirroring: rules).map(JSONValue.string))])
    }

    /// The live settings that turn Ask's rules and style on.
    public static func enterSettings(mirroring rules: [PermissionRuleRow] = []) -> FlagSettings {
        FlagSettings(["permissions": permissions(mirroring: rules), "outputStyle": .string(ClaudeLoomPlugin.askStyleName)])
    }

    /// The live settings that turn them off: both lists empty (the object is sent complete) and the default style.
    public static let leaveSettings = FlagSettings([
        "permissions": .object(["allow": .array([]), "deny": .array([])]), "outputStyle": .null])

    /// What the CLI says when it refuses a call in `dontAsk` mode.
    public static let refusalMarker = "don't ask mode"

    /// A tool result that is a refusal in Ask: the mode's text, or the rule's ("Permission to use Write has been denied.").
    /// `askIsOn` is the mode the CLI reported at the turn's `system/init`.
    public static func isRefusal(text: String, askIsOn: Bool) -> Bool {
        if text.contains(refusalMarker) { return true }
        return askIsOn && text.hasPrefix("Permission to use ")
    }
}

/// One row of the CLI's `list_permission_rules` answer.
public struct PermissionRuleRow: Sendable, Equatable {
    /// `allow`, `deny` or `ask`.
    public var behavior: String
    /// Where the rule comes from: `flagSettings` (Loom's live layer), `userSettings`, `projectSettings`, `localSettings`,
    /// `policySettings`, …
    public var source: String
    /// The rule's text: `Bash(touch:*)`, `Edit`, `mcp__docs__search`.
    public var rule: String

    public init(behavior: String, source: String, rule: String) {
        self.behavior = behavior
        self.source = source
        self.rule = rule
    }
}
