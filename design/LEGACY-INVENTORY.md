# Herdr Desktop behavior inventory (legacy)

**Reference only, not a Loom requirement. The [product contract](../LOOM-PRODUCT-CONTRACT.md) wins on any conflict.** What Loom actually ships is in [UI-MAP.md](UI-MAP.md) and the visual rules are in [DESIGN.md](DESIGN.md).

This inventory lists the behavior of the previous app (Herdr Desktop, now removed). Its purpose is to explain what the elements in the reference screenshots are for and to help scope Loom. Every row needs its own scoping decision before it can become a Loom feature. Several rows are known to differ from Loom today: the search field is always visible (not only above 8 conversations), the sidebar width is persisted (not reset to 300 pt), Settings has no provider install status yet, and there is no Dock/menu-bar list, child-task view, deletion or Performance menu. The translation below is otherwise unchanged from the former `DESIGN.md` §4.

| Area | Existing behavior | Limit / important distinction |
| --- | --- | --- |
| Providers | Claude Code, Codex, OpenCode, Antigravity and a plain shell | Uses the local CLI installs and their existing logins; does not manage a model backend or API keys. |
| Projects | Add folder, collapse/expand, reorder by dragging, remove an empty project | A project that has conversations must be emptied first. Removing a project does not delete project files. |
| Work without a project | Start a new session in the home directory; `Sessions` group | The group can be hidden while empty. |
| New session | Start inside a project or without one, choosing the provider | A missing CLI is shown disabled; a launch error is reported. |
| View selection | Group by project, or day groups by last activity | The in-project list is stable by creation time; selecting a row does not move it up. The activity view sorts by last activity. |
| Card metadata | Title, provider, project, branch, relative time | The time is derived from the last run start; it is not a token or working-time measurement. |
| Branch | Branch info from `.git/HEAD` and the worktree gitdir | Runs no git subprocess. Refreshed on session events and when the app comes to the front. |
| Search | Search in title, provider and related child tasks | In the old code the search box showed only with more than 8 conversations. Not a full transcript search. |
| Switching sessions | Show the live terminal; normal input, output, resize, scroll and selection | Every live session carries its own PTY/terminal buffer. |
| Resume from history | Open a conversation with a known native ID using the provider's resume command | No process is started automatically at app launch. Clicking a past main conversation may start a resume; without an ID it cannot continue. A shell opens as a new process. |
| Identity change | After `/new`, keep the old conversation in history and record the new native ID separately | The terminal's run identity differs from the provider's conversation identity. |
| Rename | Assign a custom title; do not overwrite it with a later automatic title | Current text limit is 160 characters. |
| Status | Working, waiting for input/approval, idle/finished, ended/history | The existing hook coverage does not guarantee every provider transition. Status, process liveness and unread state are not the same thing. |
| Attention marks | Working animation, orange waiting mark, blue dot for a finish nobody looked at | A selected, visible conversation counts as read. An error is a separate app message. |
| Dock / menu bar | Count of sessions needing attention and a list to switch to a session | The list shows the first 12 entries. No model call. |
| Claude child tasks | Show a new `claude -p` task started from the app under its parent conversation; count and expand/collapse | Not a general subagent system across providers. A running task does not move out of the process that holds it. |
| Child transcript | Read the local Claude transcript; `Resume in Terminal` when finished | The view reads a bounded tail (800 KB / last 120 entries); it does not load unbounded files. |
| File drop | Add several file/folder paths from Finder to the prompt, quoted | Does not press Enter; not a file upload service. |
| Conversation path | Drag a Claude/Codex row into the terminal, double-click, or copy its history path from the menu | Needs a native ID and an existing local file; does not insert content into the prompt automatically. |
| Text/image paste | Multi-line bracketed paste; if only an image is on the clipboard, forward Cmd+V as Ctrl+V | Reading the image depends on the CLI. |
| Links | Open HTTP(S) and existing local file links | Does not run arbitrary URL schemes. |
| Stop | Stop the terminal and its related children, verify it closed | Checked by PID birth identity; TERM, then a bounded wait, then KILL if needed. Runaway children that open their own Unix session are a risk. |
| Delete from list | Stop the session and its sub-tasks and remove it from the catalog | Not the same as deleting the provider's chat files. |
| Permanent delete | Delete the local files of supported Claude conversations and sub-tasks | The shared `history.jsonl` and cloud copies remain. Not offered for Codex/OpenCode because propagation of deletion is unclear; Antigravity is pointed to its own delete screen. |
| Closing the window | The window closes; the app and its jobs keep running | Different from Quit. |
| Quitting the app | Stop owned terminals/children, finish pending catalog operations, save | Reports an error if shutdown cannot be verified; must not kill other apps' processes. |
| Catalog | Persist projects, titles, provider/native IDs, order, the selected record and settings | A corrupt catalog is not overwritten. The providers' whole history is not imported automatically. |
| Settings | Terminal font 11-20 pt; provider install status | No account/usage management. The sidebar width reset to 300 pt on relaunch in that code. |
| Accessibility | Native window, keyboard shortcuts, meaningful control labels, motion/transparency preferences | A full accessibility audit is not claimed. |
| Diagnostics | Last-added Performance menu: CPU/memory display, 5 s sampling, JSONL, manual issue marker, on/off, 20 MiB rotation | This app is also being removed. Does not measure GPU; misses short processes and spikes. Not an accepted Loom diagnostics design. |

Shortcuts: Cmd+O add project; Cmd+N new conversation; Ctrl+Cmd+S sidebar; Cmd+, settings; Cmd+W window; Cmd+Q quit; standard macOS copy/paste/select-all and full-screen shortcuts.

Legacy source for size and behavior reference: [legacy-code/](legacy-code/) (not production code to port).
