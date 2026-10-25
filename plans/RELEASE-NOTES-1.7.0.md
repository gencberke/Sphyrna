# Sphyrna 1.7.0

Draft of 26 Oct 2026, for `@user`'s release (the push and the GitHub release wait for `@user`, [D-16](../DECISIONS.md), [D-83](../DECISIONS.md)). The work is the rescue ([RESCUE-PLAN](RESCUE-PLAN.md)): [D-100](../DECISIONS.md), [D-101](../DECISIONS.md) and [D-102](../DECISIONS.md).

1.7.0 makes Sphyrna a terminal-first session manager. Every Claude session runs in Claude Code's own terminal, and Sphyrna looks after the sessions: where they are, what they cost and what they keep on disk. The Chat face is frozen. The session channel and Codex sessions, planned for 1.7.0 before, wait.

## Terminal first

- **Every Claude session runs in its terminal.** New sessions, resumes and approved openings all open the real Claude Code terminal. A stopped session shows its kept screen, and Resume continues it in the terminal.
- **The Chat face is frozen.** The "Sessions run in" switch, Quick Question, Show Chat and the read-only chat are gone from the menus and Settings. Their code stays in the app until a later decision.
- **Full model names.** The new-session composer names the model the CLI reports, such as "Opus 5.5", instead of "Opus".
- **Unknown records stay quiet.** Usage and the session readers skip record types they do not know, such as the `permission_check_status` records Claude Code sends in auto mode.

## Storage and usage

- **Settings → Sessions → Storage** lists what each session keeps on disk: its transcript, subagents, tool results and file history, grouped by project with the largest first, and a project filter. Pick sessions and Delete Sessions removes them through the same verified deletion as before. A running session cannot be deleted.
- **Claude's retention** shows how many days Claude Code keeps its transcripts (30 by default). Change… sets another number after you confirm. It is the only key Sphyrna ever writes to Claude's `settings.json`, and it writes it atomically.
- **Usage per session.** The inspector's Overview shows the session's tokens, split into the main thread and its subagents, with the API-equivalent cost for comparison. It reads when the Overview shows and when the session stops working.

## Sidebar

- **One heading.** The view's title shows once, with its own actions next to it: Add Project… in Projects, New Session in Activity. A right-click on the list's empty space offers both.
- **Session cards in three layers:** the harness and the model, the title, then the project and the branch, in both views.
- **Projects reorder by drag.** A project dropped on another project's heading takes its place.
- **Transparent instead of Glass.** Settings → Theme → Sidebar is Solid or Transparent. Transparent is a plain see-through fill with no blur. A sidebar set to Glass before shows as Transparent.

## Look

- **No art.** The ASCII sharks are gone from every page, Home included, and Settings → Theme has no Animated art row. Remora stays.

## Energy

Measured with `scripts/perf/real_energy.py` on fake sessions, as the energy score Activity Monitor shows (1.6.2 → 1.7.0):

- **At rest, Sphyrna costs nothing:** Home and the new-session page read 0.0 (were 3.1 and 6.2), and their memory is 39 to 44 MB (was 53 to 111 MB).
- **Typing on the new-session page** reads 6.4 (was 9.0).
- **A terminal streaming 1 MiB/s** reads about 15, as Terminal.app does with the same output (14.6).
- **The menu bar's working mark stands still.** Its animation kept WindowServer at about 8 for as long as any session worked, even with Sphyrna in the background; now it reads 1.9 there.
- **Still open:** while Sphyrna is in front and a session works, WindowServer reads about 8 because of the window's spinners. Claude Code's own spinner in a visible terminal costs the same. With a customized pointer colour (Accessibility → Display → Pointer), macOS redraws the pointer on every layout, which is about a third of the typing cost. The 118 seen on 25 Oct could not be reproduced.

## Going back to 1.6.2

1.6.2 reads a Transparent sidebar as Solid, and offers the Chat face again with the setting it had before. Claude's retention stays as you set it, because it lives in Claude Code's own settings.
