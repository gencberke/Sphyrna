import Foundation

/// The plugin Sphyrna (Loom in the code) gives the Claude sessions it starts (`--plugin-dir`, D-42): one skill that tells the
/// agent how to ask Sphyrna for another session (`"$LOOM_CLI" open`, D-40) and which other sessions exist (`sessions`, C5a),
/// and the output style of Ask mode. Claude sees only the skill's description until it is used. The files come from this
/// source and are written into Sphyrna's data folder, so they follow the app's version and need nothing from the bundle.
public enum ClaudeLoomPlugin {
    static let manifest = """
        {
          "name": "sphyrna",
          "version": "1.2.0",
          "description": "Sphyrna, the desktop app hosting this session: list its other sessions and open another with a first message.",
          "author": { "name": "Sphyrna" }
        }

        """

    static let skill = """
        ---
        name: open-session
        description: This session runs inside Sphyrna, the desktop app that hosts it. Sphyrna can list the user's other sessions (read-only, no content) and open a new top-level Claude session with a first message the user approves. Use it to find a session, or when work should go on in its own session.
        ---

        # Sessions in Sphyrna

        This session runs inside Sphyrna, the app that hosts it. `"$SPHYRNA_CLI"` is the way between its sessions;
        Claude's own cross-session messages are refused.

        ## List and identify

        `"$SPHYRNA_CLI" sessions` prints the user's other sessions, tab-separated: id, state, harness, face, last
        activity (UTC), project, title, opened by; no session content. It lists this session's project;
        `--project <name|path>`, `--all`, `--limit <n>` and `--json` widen it.

        `"$SPHYRNA_CLI" whoami` prints this session's id, state, project and title, its opener, and the sessions it
        opened. Do not guess an id.

        ## Open another session

        `"$SPHYRNA_CLI" open --help` lists the flags, including `--model`, `--effort` and `--mode`. `open` asks
        Sphyrna to open a new top-level Claude session with a first message; nothing starts until the user approves
        it. Full access is never yours to pick.

        1. Write the first message to a file: the new session sees nothing of this one, so give the goal, context and
           where to start.
        2. Run `"$SPHYRNA_CLI" open --title "<topic>" --message-file <file>` (`--message -` reads stdin); it waits up
           to 85 seconds.
        3. Act on the result: `started <id> "<title>"` (tell the user; do not duplicate it), `pending: ...` (no answer;
           tell the user, do not ask again), `denied` (do not retry), `error: ...` (report it; exit 3 means Sphyrna is
           unreachable).

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
    public static let askStyleName = "sphyrna:Ask"

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
