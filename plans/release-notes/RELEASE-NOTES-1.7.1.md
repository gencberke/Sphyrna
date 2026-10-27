# Sphyrna 1.7.1

26 Oct 2026. `@user` asked for the merge, the version bump, the tag, the promote and the install; the push and the GitHub release still wait for `@user` ([D-16](../../DECISIONS.md), [D-83](../../DECISIONS.md)). The work is [FEEDBACK-6](../FEEDBACK-6.md)'s 1.7.1 list, with every default of [D-103](../../DECISIONS.md).

1.7.1 fixes what 1.7.0's first days showed: a project that would not drag, a session that read Working after it had finished, a brief that was too long, and a few places that still said Loom. It also makes the sessions know where they stand, and spends less energy while you scroll a terminal.

## Sessions

- **A finished turn reads Ready, with "N background".** A session whose turn has ended no longer reads Working because a dev server or a watcher is still running in its terminal. The header, the card and the Overview say "2 background" beside the state. Quitting still asks before it kills those shells, and a session with background work still blocks an idle stop. The "finished" notification and Keep Mac Awake follow the new state.
- **An opened session takes the choices you approved.** The open-session skill accepts `--model`, `--effort` and `--mode`, and the approval card shows them. Without `--mode` the session takes Sphyrna's default mode, as a new session does. Full access is never an agent's to pick, and an opened session's choices are not remembered as the project's last used.
- **A session knows its place.** `sessions` says who opened each session, and the new `whoami` returns the session's own id, title, project and state, its opener and the sessions it opened. A session's id in Sphyrna is its id in Claude Code, so an agent can match the two lists by id even where the names differ. Messages between sessions stay refused, as before.
- **The open request reads as the session it will become.** The box is a pinned card in Ink's look: the requester, the title, one meta line with the harness, model, effort, mode, project and branch, the first three lines of the message with "Show full message", then Deny and Open Session. After an answer it folds to one line.

## Sidebar

- **Projects drag.** The head's name is not a button any more, so the drag starts on it, and the types a drag carries are declared in the app's Info.plist. A project dropped anywhere on another project's block (its head, drafts, cards or "No sessions") takes that block's place: after it from above, before it from below.
- **A drag shows where it will land.** An accent line for a list (the projects, the tab strip), a wash on a place it is dropped onto (the composer's field and chips, a terminal), and no highlight with the dragged row dimmed over a place that refuses it.
- **The footer chip lists each connected harness.** One line for Claude and one for Codex, each with its mark, its tokens and its tightest limit. Codex is asked when the app comes to the front and then once a minute, under the usage probe's five-minute floor.
- **Settings → Theme → Sidebar gets a fill and an opacity.** Fill: Canvas, Raised or Deep. Opacity: Solid, 90 %, 80 % or 65 %. They are plain fills with no blur. A sidebar set to Solid or Transparent before keeps its look.
- **The divider is opaque** and the card's text lines up under the project mark.

## Agents and Overview

- **An agent's words and its Result are Markdown.** The transcript of a subagent shows the agent's text and its final Result as formatted text, tool results as a few lines with "Show N more lines", and a Read as `path (lines a–b)`. An entry over 64 KiB is named, not dropped.
- **The Overview has six sections.** Session, Context, Usage, Worktree, Changes and Agents, divided by hairlines, each with a headline ("2 running" for the agents, the files and lines of the last turn for the changes). The state and the start time share a line, and so do the harness, the model and its effort.
- **A running subagent stands still.** Only a session's own spinner moves; a subagent's mark in the sidebar, the Agents list and the Overview shows its first frame.

## Remora

- **The brief is two short sentences,** in the language you wrote in, and Home's Remora grows with the window: a side column for the brief and the face, and the tiles in up to two columns.
- **Every Claude model is on the list,** with the efforts it supports, in Settings → Remora.
- **Notes that last.** A project's note is kept short (at most 1.5 KiB, five items, 160 characters each), forgets an item after 90 days without a fresh mention, and is written only once Remora has read two sessions of the project or the note already exists.

## Terminal and energy

- **Mouse motion once per cell.** Claude Code in fullscreen asks for the pointer's motion and redraws its whole screen for each report. SwiftTerm sent one for every mouse event, about 120 a second on a trackpad; it now sends one when the pointer enters another cell, as xterm, iTerm2 and Ghostty do.
- **Scrolling the normal buffer costs less.** A terminal parked in its scrollback no longer repaints whole on every output frame, and the overlay scroller no longer makes a timer and draws synchronously for each wheel step.
- **A new terminal starts at the last laid-out size,** not at 95 columns, and a width under 20 columns is never sent to the program. The log keeps one line for each resize (category Lifecycle, debug), so the width history of a session can be read afterwards.
- **Not yet measured.** The energy effect of these three changes has not been measured against Terminal.app; the cells to do it are in the list below.

## Names

- **Sphyrna where you read it.** The plugin is `sphyrna`, the output style `sphyrna:Ask`, the CLI variable `SPHYRNA_CLI` (`LOOM_CLI` stays, so older sessions and saved Bash rules keep working), branches start with `sphyrna/`, the diagnostics folder is `sphyrna-diagnostics-…`, and the harnesses are told the client is `sphyrna`. The wording check now reads lowercase `loom` in user-visible text too.
- **Activity Monitor.** Claude Code's energy is listed under "Sphyrna Run Host", not under Sphyrna; Settings → General says so beside Keep Mac Awake. The executable and the app file keep the name Loom for now, because the signature, the run host's owner requirement and the upgrade hang on them.

## Health

- **Helper runs are named in the log.** A run the app starts for itself, such as the Codex usage probe, reads "Helper run … started (codex app-server, …)" and "Helper run … ended", with no session reference.

## Still to check by hand

- A real drag of a project and of a session in the dev build, the three looks, and a drag that is cancelled.
- The scroll and pointer-over-terminal cells of `scripts/perf/real_energy.py` against Terminal.app, and the same CLI printing a table nested in a list in Terminal.app (is the broken table Claude Code's?).
- Home in full screen, in Ink and Paper; the first paint of an 8 MB agent transcript.
- The plain `CFBundleDisplayName` of the app and the dev app (left as it was, see the review notes).

## Going back to 1.7.0

1.7.0 reads a stored sidebar fill and opacity as it read Solid and Transparent before (an unknown value reads as Solid). The sessions, the catalog and the notes need no change.
