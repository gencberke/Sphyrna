import Foundation

/// The plugin Loom gives the Claude sessions it starts (`--plugin-dir`, D-42): one skill that tells the agent
/// how to ask Loom for another session (`"$LOOM_CLI" open`, D-40). Claude sees only the skill's description
/// until it is used. The files come from this source and are written into Loom's data folder, so they follow
/// the app's version and need nothing from the bundle.
public enum ClaudeLoomPlugin {
    static let manifest = """
        {
          "name": "loom",
          "version": "1.0.0",
          "description": "Loom, the desktop app hosting this session: open another session with a first message.",
          "author": { "name": "Loom" }
        }

        """

    static let skill = """
        ---
        name: open-session
        description: Open another top-level Claude session in Loom with a first message; the user approves it in Loom first. Use when work should continue in its own separate session, for example a ticket session that the project's rules ask for, rather than in a subagent. Only inside Loom, where $LOOM_CLI is set.
        ---

        # Open another session in Loom

        This session runs inside Loom, the desktop app that hosts it. `"$LOOM_CLI" open` asks Loom to open a new
        top-level Claude session with a first message. Loom shows the request to the user; nothing starts until
        they approve it there.

        1. Write the first message to a file. The new session sees nothing of this one, so the message must stand
           on its own: the goal, the context it needs, and where to start.
        2. Run it (the command waits up to 85 seconds for the user's answer):

           ```bash
           "$LOOM_CLI" open --title "<KEY> - <short topic>" --ticket <KEY> --message-file <file>
           ```

           - `--ticket <key>` is optional (letters, digits, `-`, `_`, `.`). With it, Loom reports a session the
             project already has for that ticket instead of opening another.
           - `--project <name|path>` opens it in another Loom project; the default is this session's project.
           - `--message -` reads the message from standard input instead of a file.
        3. Act on the result line:
           - `started <id> "<title>"`: the new session runs with the message. Tell the user; do not also do that
             work here.
           - `exists <id> "<title>" running|stopped`: the ticket already has a session. Tell the user to continue
             there; nothing new was opened.
           - `pending: ...`: the user has not answered yet and the request stays in Loom. Tell the user; do not ask
             again.
           - `denied`: the user said no. Do not retry.
           - `error: ...`: report it. Exit code 3 means Loom cannot be reached from this session.

        `"$LOOM_CLI" open --help` prints the full usage.

        """

    /// Writes the plugin into `directory` (created when missing); a file that already has this content is left
    /// alone. Returns the folder to pass as `--plugin-dir`.
    @discardableResult
    public static func install(in directory: URL) throws -> URL {
        let files = [
            (".claude-plugin/plugin.json", manifest),
            ("skills/open-session/SKILL.md", skill),
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
