# Feedback round 7 on 1.7.2 (27 Oct 2026)

This file records round 7: `@user`'s notes after using the installed Sphyrna 1.7.2, the planner's reading of Orca and
T3 Code for them, and the decisions that turn 1.8.0 into one release ([D-105](../DECISIONS.md)). The plan built from it is
[plans/1.8.0/](1.8.0/README.md). [FEEDBACK-6](FEEDBACK-6.md) was round 6.

**Sources.**
- `~/Desktop/gelistirme.md`, section "FEEDBACK 7", with `~/Desktop/assets/image-20261027-121547.png` (a session card) and
  `~/Desktop/WhatsApp Image 2026-10-26 at 23.33.06 (2).jpeg` (Orca 1.4.241 in use). The file's "FEEDBACK 6" section is the
  round already recorded in FEEDBACK-6.
- The chat of 27 Oct: why the round exists (Orca and T3 Code feel solid; Sphyrna must reach their quality and stay simpler and
  lighter), and `@user`'s answers to the planner's first reading.

## Resume here

- **State:** B0, A1 and C1 have run. B0 is approved and C1 is reviewed; A1 is finishing (plans/1.8.0, ACTIVE-PLAN).
- **Next:** B0's look is approved (D-106). B1 brings it into the app, and B0b redraws the rest of the reference in v4. Q7–Q13
  are still open; Q13 is needed before P0 and P1.

## Items

| ID | Area | The user said | Kind | Finding in one line | Slice |
| --- | --- | --- | --- | --- | --- |
| FB7-1 | Sidebar | "session card'ın sol tarafında bıraktığımız boşluk status working olmadığında … saçma gözüküyor" | Design | The empty column is a rule, not a bug: every status surface keeps a 12 pt slot at the row's start (DESIGN §4 "One status column"); the reference card is T3 Code's | B2 |
| FB7-2 | Whole app | "tasarım tarafını orca'nınkine daha yakın tutmayı düşünüyorum … daha clear daha modern"; "tema ve buton stilleri, etkileşime geçebileceğin alanlar" | Design language | Ink is close in tone; the gap is the control family (sizes, fills, the primary button), density, labels, elevation and the missing status bar | B0, B1, B2, B3, B5a–c |
| FB7-3 | Sidebar | "hala projeyi tutup diğer projenin üstüne veya altına yaklaştırdığımda order değişmiyor" (chat) | Bug | The project drag rides the pasteboard with an undeclared type and nothing else, and shows no live movement; both references reorder with a pointer gesture | A1 |
| FB7-4 | Release | "hepsini tek versiyona planlayalım … günlük kullanıma uygun hale getirmek" (chat) | Scope | 1.8.0 holds D-103's parked work, this round and the leftovers | D-105 |

What `@user` reported as fine in daily use of 1.7.2: the Working state, the card's alignment and energy. Only the project drag
is still visibly wrong.

## What the code and the references say

### FB7-1: the card's empty column

- DESIGN §4 "One status column" (`design/DESIGN.md`, "Every status surface draws the same marks in a 12 pt slot at the
  start of the row"). On a card that is Ready, the slot is empty, and the subagent branch leaves from it (22 pt from the row's
  edge, DESIGN §4 "Subagents under a session").
- The card `@user` showed is T3 Code's sidebar thread row in its "Working" shelf (`t3code/apps/web/src/components/Sidebar.tsx:3125`,
  `sidebar/SidebarThreadRow.tsx`). Top line: the project mark and name, then the status as a mark and words with the elapsed time
  ("Working 37s") at the trailing end. Second line: the title. Third line: the branch in mono, then the harness mark. Nothing
  is drawn when there is no status.
- **Proposal:** cards drop the leading status column. The status moves to the top line's trailing end and the subagent branch
  leaves from the mark's column (DESIGN-V4 §5). The one-status-column rule stays for dense one-line rows (tabs, palette, menu bar).

### FB7-2: Orca's design system

Orca documents its system: `orca/docs/STYLEGUIDE.md` and `docs/styleguide/{color,components,ux-rules,ux-review-rubric}.md`. The
values are in `src/renderer/src/assets/main.css`, and the primitives are in `src/renderer/src/components/ui/`, shadcn on Radix.
What makes it read as professional:
- **Monochrome and quiet:** neutral greys carry the chrome, and colour is kept for state. The primary button is a neutral
  near-white fill with dark text in dark mode (`--primary: #e5e5e5`), not a hue.
- **Surface pairs:** each surface has its own foreground (background, card, popover, muted, accent, sidebar). The left sidebar is
  a lifted plane (`--worktree-sidebar: #2a2a2a` over `--background: #0a0a0a`). Hairlines are white at 7 %, and an input's edge is
  white at 15 %.
- **One control family** in sizes 24, 32 and 36 (`button.tsx`: `xs`, `sm`, `default`), radius 8 (`rounded-md`), cards at 14, badges as
  capsules. Six button variants with fixed roles (default, secondary, outline, ghost, link, destructive), and a 3 px focus halo.
- **Three elevations and no fourth:** a hairline, a hairline with a small shadow (outline buttons, embedded cards), and a floating
  shadow for popovers only.
- **Type:** 14 body, 13 sidebar and dense rows, 12 sub-text, 11 caption labels in sans semibold capitals; mono only for
  literal text.
- **UX rules:**
  - feedback matched to duration (none under 100 ms, then disabled only, then a spinner, then stage labels);
  - the back-out path stays quiet (Cancel is never coloured);
  - tooltips only name controls;
  - copy never claims more than the state proves;
  - missing data shows the action that gets it;
  - siblings match.
- **A status bar** 24 high along the window's bottom (`components/status-bar/StatusBarSurface.tsx:116`). One segment per
  provider shows its mark, a 48 × 6 meter and the windows' figures, and opens a 360-wide popover. Other segments: keep awake
  (caffeinate), ports and resources.

Sphyrna already shares the tone (dark neutral canvas, hairlines, colour for state), SF Pro and SF Mono, and the status
language. The proposal for what changes and what stays is [plans/1.8.0/DESIGN-V4.md](1.8.0/DESIGN-V4.md).

### FB7-3: the project drag

What the code does (`v2` `fe72ee2`):
- The head's drag source is `.onDrag { ProjectDrag.beginDrag(id) }` on a plain stack that also carries `.onTapGesture`
  (`SidebarView.swift:461-464`).
- Its item provider registers one representation only, under `local.loom.desktop.project-reference` (`ProjectDrag.swift:24-31`).
  1.7.2 undeclared that type again after 1.7.1's declaration turned the drag into a file promise and locked the window. The log
  says so on every launch: "Type "local.loom.desktop.project-reference" was expected to be declared and exported in the
  Info.plist of Loom.app" (fault, `com.apple.runtime-issues`, 26 Oct 23:34, 27 Oct 12:26).
- A session's drag, which works, also registers the title as plain text (`SessionDrag.swift:33-44`) and sits on a Button.
- The drop delegate and `moveProject` are sound (`ProjectBlockDrop.swift`, `CatalogModel.swift:1474-1505`). The drag logs only at
  debug level, which macOS does not keep, so the installed app cannot say whether the drag started or the drop arrived.
- Nothing moves while the pointer travels: an insertion line is the only feedback, and the order changes on drop.

What the references do: both reorder with a pointer gesture and live displacement, not with the pasteboard. T3 Code uses
`@dnd-kit` `SortableContext` restricted to the vertical axis and the scrollable ancestor (`Sidebar.tsx:23-25, 2936`), and Orca
uses dnd-kit for tabs (`components/tab-bar/use-sortable-tab-rename.ts`).

**Proposal (A1):** reorder projects with an in-sidebar drag gesture.
- The dragged head lifts, the other blocks slide apart to show where it lands, and the order is written on release.
- It works without the pasteboard, so no type declaration is needed and nothing can become a file promise.
- Escape or release outside the list cancels the drag; the list scrolls itself near its edges.
- The pasteboard drag stays for sessions only, which drop on other surfaces (tabs, the composer, a terminal).
- The drag logs its start and end at notice level, ids only.

### Logic read for 1.8.0 (D-104's round, the features 1.8.0 touches)

The verdicts are in [docs/FEATURES.md](../docs/FEATURES.md) under each feature. In short:
- **Harnesses (F13).** T3 Code has one package per provider, each with a `status.ts`; a missing binary reads "… is not installed
  or not on PATH" (`packages/provider-grok/src/server/status.ts:443`). Its provider states are ready, warning ("Limited"), error
  ("Unavailable"), disabled and unauthenticated (`apps/web/src/components/chat/ModelPickerSidebar.tsx:16-23`). Orca keeps one
  hook listener per agent (Claude, Codex, OpenCode, Pi, Antigravity and others, `src/shared/agent-hook-listener*`).
- **Models and effort (F15).** T3's picker is a provider rail beside a searchable model list with Favorites. Unavailable
  providers are dimmed with a reason, and effort sits in a separate traits picker (`chat/ModelPickerContent.tsx`,
  `ModelPickerSidebar.tsx`, `TraitsPicker.tsx`). Orca validates an effort level by its shape, not by a fixed list, so a level a
  newer CLI adds still round-trips (`src/shared/agent-effort-level.ts`). Sphyrna's panel (FB6-7, option B) adds the effort step on
  the same surface.
- **Codex in a terminal (F1, F3, F17).** Codex 0.164.0 (installed) has hooks with Claude's events (SessionStart,
  UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, SubagentStop, Stop). Orca installs them into the real
  `~/.codex/hooks.json` with trust entries in `config.toml` (`src/main/codex/codex-real-home-hook-install.ts`), which Sphyrna must
  not do. 0.164 also has:
  - `--dangerously-bypass-hook-trust`, `-c key=value` overrides, and `--no-daemon` (the TUI uses a shared local app-server
    daemon by default, which matters for process ownership);
  - `codex delete <session>`, a permanent delete;
  - `codex queue --thread <id> --message <text>`, which queues a message for an existing session.

  The P0 spike settles which of these Sphyrna can use.
- **Between sessions (F16).** Orca keeps durable mailboxes. When a message arrives it types a one-line pointer ("You have 1
  orchestration message. Run `orca orchestration check …`") into the target's terminal, only when the agent's last observed
  status is idle. Otherwise it defers to the next idle edge, and the content stays readable by an explicit check
  (`src/main/runtime/orchestration/mailbox-pointer-delivery.ts:42-50, 190-210`).
- **Usage (F14).** Orca's status bar, above.

### State check (27 Oct)

- Installed: Sphyrna 1.7.2 (build 10702). The CLIs on this Mac:
  - Claude Code 2.1.311 (H3's upgrade is done);
  - Codex 0.164.0 (FEEDBACK-6 planned against 0.160.0);
  - opencode 2.1.4, agy 1.4.5 and pi 0.85.1.
- **Worktrees cleaned up** on `@user`'s word ("gereksiz worktree'leri kaldıralım"). 50 worktrees were removed: 35 of the Release A–C era with uncommitted changes, the five `slice/fix-*`, `r7`, `r8`, seven measurement candidates, and `ink`.
  - **Backup:** before removal, every uncommitted change was saved to `~/Library/Caches/loom-v2/evidence/cleanup-20261027/` (a patch and a tarball of untracked files per worktree, with `MANIFEST.md`).
  - **Why they were not needed:** in each Release A–C worktree, 11 to 15 of 15 sampled added lines were already in `v2` (at `88337a2`, `cc54a17` or the head). The one exception is `shc`, Chat-era evidence tooling (an unshipped `EvidenceUIDriveCommands.swift`), which is in the backup.
  - **What is left:** `v2`, `core` (`build-c8.sh` adds worktrees from it) and `loom-dev`. Every branch is kept.

## Decisions (open)

Each has a recommended default. `@user` answers in chat; a silent item takes its default when its slice starts.

**Answered on 27 Oct ([D-106](../DECISIONS.md)):** Q1–Q6 take their defaults ("hepsi okey", on B0's reference). The model and the
effort become two pickers. Q7–Q13 are still open.

| Q | Question | Default |
| --- | --- | --- |
| Q1 | The primary (default) button: Orca's neutral fill (near-white in Ink, near-black in Paper), or Ink's periwinkle fill | Neutral. Periwinkle stays Sphyrna's mark: the focus ring, the current tab and view, a switch that is on, links |
| Q2 | The sidebar: a lifted plane one step lighter than the content (Orca), or one canvas (Ink rule 1) | Lifted, as the default of the existing sidebar fill setting |
| Q3 | The selected session: a neutral raised card with a hairline (Orca), or its project's tint (today) | Neutral raised; the project's tone stays on its mark and its tabs |
| Q4 | Section labels: SF Pro 11 semibold capitals (Orca), or SF Mono 10.5 capitals (Ink) | SF Pro; mono stays for machine text only |
| Q5 | The ultralight display type (Home's sentence, 42; the new-session question, 46) | Kept as Sphyrna's voice on those two pages, at 34 light |
| Q6 | Session tabs: a 36 pt row under the header (today), or tabs in the title bar row (Orca) | The row stays; the tabs take v4's flat style |
| Q7 | A window-wide status bar at the bottom, replacing the sidebar's footer | Yes |
| Q8 | `send`: a one-line pointer typed into the target when it is Ready (Orca), or the message added by the target's next prompt hook (FEEDBACK-6) | The pointer when Ready; every send is approved by `@user` first |
| Q9 | opencode, agy and pi in 1.8.0: shown with "Not found" or Off only, or startable as plain terminal sessions (start, resume, status, stop; no transcript reader) | Startable, last wave; any of them can be cut without holding the release |
| Q10 | Codex status: only session-scoped hooks (never writing `~/.codex`), with the terminal title as the fallback, even if that is weaker | Yes; a write to `~/.codex` would be its own decision |
| Q11 | The closing `@optimizer` review (D-06) before 1.8.0 ships | Yes, on Opus 5.5 `max` or `gpt-6-astra` `xhigh` |
| Q12 | The app file and the executable become `Sphyrna` (D-103 Q4: "with 1.8.0 after a migration check"); the bundle id and the data folder stay | Yes, after the migration check in I1 |
| Q13 | Short real turns of `codex`, `opencode`, `agy` and `pi` for the spikes and the acceptance checks, as short real-Claude turns already are (DEVELOPMENT §4 allows Claude only). Each runs in an isolated profile that `@user` signs in to once; the CLIs' own logins are never handled by an agent | Yes, short turns, counted in each report |

**Q13 resolved, 28 Oct (D-108):** explicitly authorized for this continuation, at most 15 short Codex turns and 5 each for opencode, agy and pi; isolated profiles only, user-owned login, every turn counted. The idle Mac/power-adapter confirmation also permits the planner’s accumulated window/visual/energy pool.
