import Foundation

/// The plugin Sphyrna (Loom in the code) gives the Claude sessions it starts (`--plugin-dir`, D-42): one skill that tells the
/// agent how to list and open sessions and use the terminal task channel, and the output style of Ask mode. Claude sees
/// only the skill's description until it is used. The files come from this
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
        description: This session runs inside Sphyrna. List sessions, ask to open another, or, in a terminal session, delegate tasks to a reusable child with the user's approval.
        ---

        # Sessions in Sphyrna

        `"$SPHYRNA_CLI"` connects Sphyrna sessions; Claude's own cross-session messages are refused.

        ## List and identify

        `"$SPHYRNA_CLI" sessions` lists session metadata, no session content. It defaults to this project;
        `--project <name|path>`, `--all`, `--limit <n>` and `--json` adjust the list.

        `"$SPHYRNA_CLI" whoami` identifies this session, its opener and sessions it opened. Do not guess an id.

        ## Open another session

        `"$SPHYRNA_CLI" open --help` lists choices. `"$SPHYRNA_CLI" open --title "<topic>" --message-file <file>`
        (`--message -` reads stdin) asks to start a new session; provide its goal and context. It waits up to 85 seconds.
        Tell the user `started <id>`, `pending: ...`, `denied` or `error: ...`; do not duplicate or retry a denial.
        Full access is never yours to pick. `open` always starts a new session; to reuse an ordinary session, ask the user first.

        ## Delegate a task (terminal sessions)

        Run `"$SPHYRNA_CLI" task --help` for approved child tasks, replies, status and event-driven wait. The user approves
        the child and its bounded follow-ups. Reuse printed task and operation IDs on retry; never guess another run's ID.
        A child reads its exact input using the supplied pointer and reports completed, failed, or needsParentInput; after
        needsParentInput, finish the current turn so the parent can reply. Native tool approvals belong to the user.

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
