import Foundation

/// The plugin Sphyrna (Loom in the code) gives the Claude sessions it starts (`--plugin-dir`, D-42): one skill that tells the
/// agent how to ask Sphyrna for another session (`"$LOOM_CLI" open`, D-40) and which other sessions exist (`sessions`, C5a),
/// and the output style of Ask mode. Claude sees only the skill's description until it is used. The files come from this
/// source and are written into Sphyrna's data folder, so they follow the app's version and need nothing from the bundle.
public enum ClaudeLoomPlugin {
    static let manifest = """
        {
          "name": "loom",
          "version": "1.1.0",
          "description": "Sphyrna, the desktop app hosting this session: list its other sessions and open another with a first message.",
          "author": { "name": "Sphyrna" }
        }

        """

    static let skill = """
        ---
        name: open-session
        description: List the user's other Sphyrna sessions (read-only, no content) or open another top-level Claude session with a first message that the user approves in Sphyrna. Use when work should continue in its own session, or you need to find one. Only inside Sphyrna, where $LOOM_CLI is set.
        ---

        # Sessions in Sphyrna

        This session runs inside Sphyrna, the desktop app that hosts it. `"$LOOM_CLI"` has two commands.

        ## List sessions

        `"$LOOM_CLI" sessions` prints the user's other sessions, newest first, tab-separated: id, state, harness,
        face, last activity (UTC), project, title. It holds no session content. It lists this session's project;
        `--project <name|path>` picks another, `--all` every project, `--limit <n>` (default 20) sets the count,
        `--json` prints JSON. Do not guess an id.

        ## Open another session

        `"$LOOM_CLI" open` asks Sphyrna to open a new top-level Claude session with a first message. Nothing starts
        until the user approves it in Sphyrna.

        1. Write the first message to a file. The new session sees nothing of this one: give the goal, the
           context, and where to start.
        2. Run it (it waits up to 85 seconds for the user's answer):

           ```bash
           "$LOOM_CLI" open --title "<short topic>" --message-file <file>
           ```

           `--project <name|path>` picks another Sphyrna project; `--message -` reads standard input.
        3. Act on the result line:
           - `started <id> "<title>"`: it runs. Tell the user; do not also do that work here.
           - `pending: ...`: no answer yet; the request stays in Sphyrna. Tell the user; do not ask again.
           - `denied`: the user said no. Do not retry.
           - `error: ...`: report it. Exit code 3 means Sphyrna cannot be reached from here.

        `open` always starts a new session; to reuse one, find it with `sessions` and ask the user first.

        """

    /// The output style of Ask mode (D-63, spike S9): the model-facing half of Ask, switched live with `outputStyle`. It lives
    /// in this plugin because a style set from a plugin needs nothing in the user's own `~/.claude`.
    static let askStyle = """
        ---
        name: Ask
        description: Research and answer; explain more; change nothing
        keep-coding-instructions: true
        ---
        # Ask mode
        You are in Ask mode. The user wants answers, not changes. Research with read-only tools (Read, Grep, Glob, read-only shell commands, web search) and answer. Never create, edit, delete, move or format files and never run a command that writes. If the user asks for a change, do not attempt it: explain what the change would be and why, and say that Ask mode is read-only. Explain more than usual: give the reasoning and context, point to file paths and line numbers.

        """

    /// The name `outputStyle` takes for `askStyle`: `<plugin>:<style>`.
    public static let askStyleName = "loom:Ask"

    /// Writes the plugin into `directory` (created when missing); a file that already has this content is left
    /// alone. Returns the folder to pass as `--plugin-dir`.
    @discardableResult
    public static func install(in directory: URL) throws -> URL {
        let files = [
            (".claude-plugin/plugin.json", manifest),
            ("skills/open-session/SKILL.md", skill),
            ("output-styles/ask.md", askStyle),
        ]
        for (path, content) in files {
            let url = directory.appendingPathComponent(path)
            let data = Data(content.utf8)
            if (try? Data(contentsOf: url)) == data { continue }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return directory
    }
}
