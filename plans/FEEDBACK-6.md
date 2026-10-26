# Feedback round 6 on 1.7.0 (26 Oct 2026)

This file records the round that started from `@user`'s notes after a day of real use of the installed Sphyrna 1.7.0:
- `~/Desktop/gelistirme.md` of 26 Oct, with screenshots in `~/Desktop/assets/image-20261026-*.png`;
- a chat message the same afternoon asking for more sidebar colour and transparency options, after the Claude desktop app's sidebar.

`@user` used 1.7.0 for 5 to 6 hours in two Claude sessions and called the rescue a success. They asked for every note to be
fixed and for a general health check of the logs and the sessions beyond the notes ("bu feedback ile sınırlı kalma").

It covers what the code says about each note (`v2` at `b18543b`), the health check, the proposals, the decisions `@user` has to
make and the release line. [FEEDBACK-5](FEEDBACK-5.md) was round 5; [RESCUE-PLAN](RESCUE-PLAN.md) built 1.7.0.

## Resume here

- **State before the go:** the causes are traced by five read-only explorers, and the planner checked the decisive lines and the real data
  (the two sessions' transcripts and subagent files, the unified log since 09:00, Remora's files, the live processes).
  Nothing was built before the go.
- **The go (26 Oct, evening):** `@user` accepted the plan and every default ("her şey oky … böyle kaydedelim"), added FB6-24, and
  asked for 1.7.1 to be built in a separate session on Sonnet at high effort with narrow tests, coming back to the planner for the
  final review (D-103).
- **Next:** the implementer session follows [the brief](#171-implementation-brief) on `slice/r8-171` in `wt/r8`; then the planner
  reviews, runs the gate, and releases on `@user`'s word.

## Release line (D-103)

| Release | What it holds |
| --- | --- |
| **1.7.1** | Every fix and every change that stands on today's two harnesses: the sidebar (FB6-1 to FB6-6), the terminal and state bugs (FB6-9, FB6-10), the energy work that is ours (FB6-11), the open-session skill and session awareness (FB6-15, FB6-16 part 1), the Sphyrna name where the user sees it (FB6-17), the Agents view and Overview (FB6-18, FB6-19), Remora's brief, layout and memory (FB6-20, FB6-21, FB6-23), and the health items. |
| **1.8.0** | Every harness first-class: the harness catalogue and Connections with "not found" (FB6-13), the model and effort panel over a harness-neutral draft (FB6-7, FB6-8), Codex sessions started and resumed with the draft, then read (FB6-14), Remora on any connected harness (FB6-22), and the message between sessions if `@user` wants it (FB6-16 part 2). opencode, agy and pi get rows and marks there; each becomes startable through its own descriptor. |

The push and the GitHub release still wait for `@user` (D-16, D-83); 1.7.0 is not pushed yet.

## Items

| ID | Area | The user said | Kind | Finding in one line | Release |
| --- | --- | --- | --- | --- | --- |
| FB6-1 | Sidebar | "ince bir çizgi var arkayı gösteriyor" | Bug | The split view's divider is a translucent hairline over a clear window; nothing opaque is under it | 1.7.1 |
| FB6-2 | Sidebar | "session card'ı içindeki elementler oriented değil" | Design | The title is indented to the project name (37 pt), 17 pt right of the project mark | 1.7.1 |
| FB6-3 | Sidebar | "desteklenen … harness'ların usage bilgilerini listeleyelim … ufak harness iconlarıyla" | Feature | The footer chip is Claude's tokens and Claude's tightest limit; Codex is only in the tooltip | 1.7.1 |
| FB6-4 | Sidebar | "hala daha projeyi tutup sürükleyip … order'ı ayarlayamıyorum" | Bug | The head is buttons that likely take the mouse-down; the drag types are not declared in the bundle; the target is only the 28 pt head | 1.7.1 |
| FB6-5 | Whole app | "sürüklerken … ne olacağını hover efekti gibi bir efektle bilincinde olabilmeliyim" | Design | Feedback differs per target; several targets show only the cursor | 1.7.1 |
| FB6-6 | Sidebar | "sidebar renk-saydamlık konusunda bir iki seçenek daha" | Feature | Two styles today: Solid and Transparent (canvas at 0.8) | 1.7.1 |
| FB6-7 | Composer | "connection aware … daha clear bir segmentation … farklı bir yapı" | Feature | The picker is a 332 pt popover with a live Claude group and a dimmed Codex group | 1.8.0 |
| FB6-8 | Composer | "önce model seçimi ardından effort seçimi" | Feature | Effort is a fixed five-level table, though both CLIs report each model's own levels | 1.8.0 |
| FB6-9 | Terminal | "claude'un bastığı bir tablonun görünümü bozulmuş" | Bug, most likely Claude Code's | The table sat inside a list item; Claude Code drew it as a plain pipe table at its natural width (about 310 columns) while it wrapped the prose around it to the real width | 1.7.1 (check and our part) |
| FB6-10 | State | "bitmiş bir turn olmasına rağmen working'te takılı kaldı" | Bug | By design today: a finished turn with a running background shell reads Working | 1.7.1 |
| FB6-11 | Energy | 27 to 33 while a session works, a working terminal 38, scrolling 70 to 90 | Performance | `@user` runs Claude Code in fullscreen (`tui: fullscreen`): every wheel step and every pointer move is a report to Claude, which redraws the whole screen; SwiftTerm sends a motion report for every mouse event, not once per cell | 1.7.1 |
| FB6-12 | Energy | "LoomRunHost … ram cpu tüketmese bile enerji harcayabildiğini gördüm" | Explained | The `claude` processes are the run host's children, so Activity Monitor files their energy under it | 1.7.1 (copy only) |
| FB6-13 | Connections | "sistemde bulunamıyor mesajı vermek gerekli"; opencode, agy, pi "off durumda … ama gözükmesi gerekli" | Feature | The harness list is several `switch provider` tables; a missing CLI is On with "Not found" | 1.8.0 |
| FB6-14 | Whole app | "codex ve claude … ikiside birincil sınıf deneyim olmalı" | Feature | Codex sessions are off in production by one build gate; the Codex path has no draft, reader or deletion | 1.8.0 |
| FB6-15 | Skill | "effort ve model ayarlayamaması saçma … skill'in adı hala loom" | Bug and feature | `open` has no model, effort or mode; an opened session also skips Sphyrna's default mode | 1.7.1 |
| FB6-16 | Sessions | "sessionların kendilerinin ve etrafındaki sessionların farkında olması gerekmez mi" | Feature and explained | The session found its opener; Sphyrna's `crossSessionInbound: refuse` refused the message | 1.7.1 (part 1), 1.8.0 (part 2) |
| FB6-17 | Identity | "loom marka adının uygulamanın her yerinde sphyrna'ya geçişini sağlamalıyız" | Chore | The plugin, the CLI variable, the branch prefix, the executable and the bundle's plain name still say Loom | 1.7.1 |
| FB6-18 | Agents | "sadece ajanın kullandığı tool'ları ve süreleri görebiliyorum" | Feature and bug | The agents wrote almost no text between tools; tool results show one line; the Result is plain text cut at 4 KiB | 1.7.1 |
| FB6-19 | Overview | "overview'ı daha okunaklı, segmentation'ı daha clear" | Design | Six sections of equal weight with a bare 20 pt gap; a 4 × 6 usage grid | 1.7.1 |
| FB6-20 | Remora | "ilk metin sadece bir session olmasına rağmen fazla uzun" | Bug | Length is only "Keep it short"; the brief also came out in English with Turkish set, and named a raw project id | 1.7.1 |
| FB6-21 | Remora | "home ekranı full screen'e responsive değil … remora icon'unu üstteki başlığın yanına alabiliriz" | Bug and design | Fixed widths (1,000, 316, 780); the face sits in its own 136 pt column | 1.7.1 |
| FB6-22 | Remora | "bağlı olan connectionların sunduğu herhangi bir modeli remora'nın arkasına koyabilmeliyim" | Feature | Remora's call is welded to `claude -p`; the picker is Sonnet and Haiku | 1.7.1 (all Claude models), 1.8.0 (other harnesses) |
| FB6-23 | Remora | "gereksiz tutulan bilgiler var … generic bilgiler olmalı" | Design | The note rule demands a session per item, so the model writes events; one chat wrote 7 items | 1.7.1 |
| FB6-24 | Open request | "session açma bildiriminin … kartımsı şeyi daha güzel gösterebilir miyiz? bu tasarım loom'dan gelen bir tasarım" (chat, 26 Oct) | Design | The box predates Ink: a yellow wash, an SF Symbol, a label column and a system Deny button; it does not even follow DESIGN's own callout rule | 1.7.1 |

## Health check (26 Oct, 09:13 to 16:40)

**Sessions.**
- The catalog holds two sessions, both live for the whole check:
  - `9D5B8F60` "Edd-backend son PR, AL testi": opened at 09:55 with Opus, high effort and Full access. Claude's own name for it is `edd-fe-2f`.
  - `A81B6F58` "EDDP-20626 AL personalized test FE implementation": opened at 13:22 by `9D5B8F60` through the skill. It has no model, effort or mode in the catalog, and its `claude` has no `--model`, `--effort` or `--permission-mode` (FB6-15).
- Both transcripts are healthy: every turn of `A81B6F58` ended with a Stop hook that `loom-hook` answered in 10 to 41 ms with no error. The stuck Working of 14:15 is FB6-10, not a lost event.
- `A81B6F58`'s transcript is 35 MB after 3 hours. The first session's five subagents wrote 12.6 MB, one file 8 MB with 13 lines over 128 KiB (FB6-18).

**Log.** 109 lines since 09:00, all default level; no error and no fault.
- About 25 runs of 2 seconds each ("terminal, new", a fresh session id, "reason requested") are the Codex usage probe: a short `codex app-server` in the supervisor's internal session (`HarnessProbeCodex.swift`, `CodexAppServerManager.startServer`). `HarnessProbe` asks at most every 5 minutes (`defaultFloor`), when the usage model asks. Their cost is small, but the log line reads like a user session: **H1** names helper runs as such ("Codex probe run … started").
- Hook events and state changes are debug-level and not kept, so the log could not show FB6-10. **H2** logs each state change of a session at notice level, one line per change (`s:… working → ready (stop, 2 background)`).
- Remora's brief at 10:06 ran on Haiku at effort xhigh, as Settings say: 33.8 s and 7,589 output tokens for one session (FB6-20).

**Processes and energy.**
- With Sphyrna in the background: Loom 0.0, each `loom-run-host` 0.0, the two idle `claude` processes 0.7 to 5 (Claude Code's own idle work).
- `claude` is the child of `LoomRunHost.app`, so Activity Monitor's Energy tab lists Claude Code's energy under LoomRunHost (FB6-12).
- No crash report for Loom, the run host, `claude` or `codex`. The catalog passes `integrity_check`; Sphyrna's data folder is 13 MB. No socket is left in `~/.loom/scopes`.

**Versions.** Claude Code 2.1.308 is out (the journal's "Update available"); the sessions run Homebrew's 2.1.300. **H3:** once
`@user` upgrades (`brew upgrade claude-code@latest` is theirs), the planner reads 2.1.308's known options before 1.7.1 ships.

## What the code says

### FB6-1: the divider shows the desktop

- The window is non-opaque and clear (`AppDelegate.swift:299-300`). `CanvasSplitView` (`LoomTheme+Shell.swift:172-182`) returns
  `ShellChrome.dividerColor`, the hairline tone: white at 7.5 % in Ink, ink at 8.5 % in Paper.
- The split view draws its thin divider in the 1 pt gap between the panes, and neither pane paints under it, so the hairline
  composites onto the clear window. Solid shows it too. Increase Contrast's 30 % hairline is not used here.

### FB6-2: the card's lines do not share an edge

- Line 1 is the state mark, the project mark in a 9 pt slot, then the name: the mark starts at 20, the name at 37
  (`SidebarView.swift:763-775`).
- Lines 2 and 3 are padded by `cardTextIndent` = 37 (`LoomTheme+Sidebar.swift:106-110`), so the title aligns with the name, 17 pt
  right of the mark. DESIGN §2 item 4 prescribes it and `SidebarInkTests.swift:101,145-146` pin it.
- The 12 pt card mark overflows its 9 pt slot by 3 pt, so the visible gap before the name is 5 pt, not 8.

### FB6-3: the footer chip is Claude's

- `UsageChipContent.make` (`UsageChipContent.swift:47-110`) shows Claude's tokens today and Claude's tightest limit; Codex only
  in the tooltip (`:94-103`).
- Codex is asked only while Settings → Usage is visible (D-99; `UsageModel.swift:354,399,421`), so a Codex line in the footer
  would be stale unless that cadence changes.

### FB6-4: the project drag

Read, not reproduced. Ranked:
1. **The head's buttons take the mouse-down.** The name is a full-width `Button` (`SidebarView.swift:413`) and the chevron, `+`
   and `⋯` are buttons; `.onDrag` sits on the same head (`:465`). The tab strip's working drag has no `Button` inside its drag
   container (`ConversationTabStrip.swift:313-315`).
2. **The types are undeclared.** `ProjectDrag.contentType` and `SessionDrag.contentType` are `UTType(exportedAs:)`
   (`ProjectDrag.swift:10`, `SessionDrag.swift:14`), and the installed 1.7.0's `Info.plist` has no `UTExportedTypeDeclarations`
   (checked). Neither `build-loom.sh` nor `package-dev-app.sh` writes one.
3. **The target is small.** Only the 28 pt heads accept; dropping on a project's cards does nothing. `ProjectDrag.current` is
   never cleared when a drag is cancelled.

1.7.0's change (`7c7100a`) was a model-level fix of the gap; no real gesture was ever verified.

### FB6-5: drag feedback

| Target | Feedback today |
| --- | --- |
| Tab strip | Insertion mark and row reveal |
| Project heads | Insertion line under the head, projects only |
| Composer chip row and text view | Cursor only |
| Terminal | `.copy` cursor only |
| Queue rows | None |

There is no "session onto a project" operation; a session's folder is tied to its project.

### FB6-6: the sidebar's colour

- `SidebarStyle` is `solid | transparent` (`UIPreferences.swift:52`); `SidebarBackground` draws the tone's canvas at 1.0 or 0.8
  (`LoomTheme.Surface.sidebarTintOpacity`), no material and no blur. 1.7.0 measured Transparent at 0.0 extra energy.
- The Claude desktop app's sidebar is one step lighter and warmer than its main pane and slightly see-through. Ink already has
  that step: `Surface.raised1`, whose text contrast is covered by `HighlightTests`.

### FB6-7 and FB6-8: the model picker and effort

- `ComposerModelPicker.groups()` (`ComposerModelPopover.swift:62-84`) hard-codes a live "Claude Code" group and a Codex group
  with `isLive: false`. DESIGN §11 says both groups are live on the new-session page; the code does not.
- The draft reads `ModelCatalog.shared.claudeModels` (`NewSessionComposer.swift:157`), which skips the connect switch, and the
  fixed `NewSessionModels.effortLevels` (`NewSessionDefaults.swift:60-64`).
- Per-model levels already arrive and stop at `ModelCatalog`: Claude's `supportedEffortLevels` (`ClaudePlanLimits.swift:336-350`)
  and Codex's `supportedReasoningEfforts` (`HarnessProbeCodex.swift:168-177`) land in `HarnessModel.efforts`; `entry(of:)` drops
  them (`ModelCatalog.swift:138-140`).
- The draft's types are Claude's: `ClaudeLaunchChoices`, `ClaudePermissionMode`, and `SessionService.startSession` hard-codes
  `.claude` (`SessionService.swift:108-117`).
- The CLIs on this Mac: `agy` 1.4.5 (`agy models`, `--model`, `--effort low..max`), `pi` 0.85.1 (`--list-models`,
  `--model provider/id[:thinking]`), `opencode` 2.1.2 (`opencode models`, no effort flag in its top-level help).

### FB6-9: a table drawn broken in the terminal

**What the screenshot and the transcript show (10:22, session `9D5B8F60`).**
- The model wrote the table inside a list item, indented by two spaces (`- **…durumu:**\n\n  | Bileşen | AL için |\n  |---|---|…`);
  its longest line is 547 characters.
- On screen the prose around it is wrapped by Claude to the grid's real width (about 123 columns) with hanging indents, but the
  table is a plain `|` table padded to its natural width, about 310 columns, with no wrapping inside cells. The terminal wrapped
  each row, which left the `|` ends and the dashes on lines of their own.
- No width this display could have had fits 310 columns, so the table was never fitted to any width. Claude Code 2.1.300 does fit
  and wrap its normal bordered tables ("wrapped rows", 2.1.299); the plain padded form points to its path for a table nested in a
  list.
- `@user` runs Claude Code in fullscreen (`tui: fullscreen` in `~/.claude/settings.json`; "Jump to bottom (click)" on screen). That
  is the alternate screen, which SwiftTerm does not reflow, and Claude redraws it at the new size on every resize.

**What is ours.**
- The PTY size always comes from the emulator's grid: `TerminalSurface.sizeChanged` → `requestResize` → `TIOCSWINSZ`
  (`TerminalSurface.swift:290, 344-355`; `EventDrivenPTYProcess.swift:176-191`). The run host plays no part.
- A new terminal starts at the 800 × 500 frame of a view that was never laid out (`ConversationController.swift:382-386`,
  `TerminalSurface.swift:160-163`), about 95 × 29, and is corrected on the first layout.
- In a wide pane the inspector is a real column (328, 392 or 556 pt), so opening it changes the grid by 39 to 66 columns, and the
  animated sidebar collapse can deliver several sizes. In the normal buffer SwiftTerm reflows the scrollback on every column change
  (`Buffer.swift:957, 1401, 1532`), which breaks any wide line printed before. That is not what happened here, but it will happen
  to a session not in fullscreen.
- No resize is logged, so the width history of a session cannot be read afterwards.

### FB6-10: Working after a finished turn

- `SessionDisplay.swift:66`: a `.turnComplete` session with `pendingProviderWorkCount > 0` reads Working. The count is the Stop
  payload's `background_tasks` plus `session_crons` that are still running (`StatusReason.swift:27-50`). The same rule is in the
  `sessions` word (`SessionDirectory.swift:57`), the hub's phase (`SessionEventHub.swift:516`) and SPEC.md:89.
- Claude's footer said "2 shells still running" at 14:15, and the Stop at 14:13:28 carried them. The next turn's Stop carried
  them again, so the state stayed Working. The rule was built on S0's `sleep 45`, which ends and starts an automatic turn; a dev
  server or a watcher never ends.
- The same rule withholds the "finished" notification, keeps Keep Mac Awake on, and runs the menu bar's working state.
- Claude's registry says `idle` for both sessions now; `busy` covers a running turn and running background subagents.

### FB6-11: energy in front

**Fullscreen Claude moves the cost onto the pointer.**
- In fullscreen Claude Code turns on mouse reporting with motion (it underlines the link under the pointer). Then a wheel step is
  not a scroll of Sphyrna's scrollback: it is a report to Claude, which redraws the whole alternate screen, which SwiftTerm parses
  and paints whole on the main thread.
- SwiftTerm sends a motion report on **every** `mouseMoved` (`MacTerminalView.swift:4009-4015`, `Terminal.sendMotion`), and runs a
  link match for the hover on every one (`updateHoverLink`, `:4007`). xterm, iTerm2 and Ghostty send motion only when the pointer
  enters another cell. A trackpad delivers about 120 events a second, so a pointer resting on a moving hand makes Claude render
  continuously. On macOS 26 and later the window also takes every mouse-moved event (`acceptsMouseMovedEvents`, `:126-196`).
- This Mac's pointer is customized (`cursorIsCustomized = 1`), so each `NSCursor set` costs about 9 ms (RESCUE-PLAN §5);
  `cursorUpdate` sets the I-beam (`:1700`). Whether the scroll path calls it per event is not established.
- That fits `@user`'s pattern: 70 to 90 while scrolling, 38 with the pointer over a working terminal, and fine when Sphyrna is not in
  front, where it gets no mouse events.

**Scrolling the normal buffer** (sessions not in fullscreen) repaints the whole view per scrolled line, and keeps repainting the
whole view on every output frame while parked in scrollback (`TerminalRenderOwner.swift:~551`, `TerminalSnapshot.swift:541`). Each
wheel event also updates the overlay scroller twice, with a new `Timer` and a synchronous `displayIfNeeded()`
(`MacTerminalView.swift:1614-1632`, `AppleTerminalView.swift:4497`).

**A working session in front** (27 to 33, image 095722): one session with three subagents put eight braille spinners on screen (the
header, the card, three subagent rows in the sidebar, three agent cards in the inspector), and Claude's own spinner and per-agent
timers redraw the terminal every second. 1.7.0 measured about 7 in WindowServer for the window's spinners while Sphyrna is in front;
each animated layer is composited on its own.

**Not explained yet:** 230 MB against 149 MB measured with two idle terminals.

### FB6-12: LoomRunHost's energy

`loom-run-host` itself read 0.0 in every sample. The two `claude` processes are its children (`ps`: parent 16784 and 21250), and
Activity Monitor's Energy tab groups a process under the app responsible for it, so Claude Code's own work (its TUI, its idle
timers, Remote Control) is listed as LoomRunHost's.

### FB6-13: Connections and the harness list

- The harness is `ManagedSession.Provider` (`claude | codex | synthetic`), stored as text in the catalog. Its facts are spread
  over separate exhaustive switches: capabilities (`HarnessCapabilities.swift:62-92`), `HarnessRegistry` (`Harness.swift:59-77`),
  `HarnessConnections.switchable` (`:18`), `HarnessVersionTable` (`HarnessHealth.swift:43-49`), install and sign-in commands
  (`HarnessSetup.swift:24-60`), the toolchain (`ProviderToolchain.swift:166-171`), the marks (`ProviderIcon.swift:12-19`).
- Silent fallbacks would treat a third harness as Claude: `HarnessHealth.command` (`provider == .codex ? "codex" : "claude"`,
  `:135-137`), the profile variable (`:142-145`), `HarnessDeepCheck` (`HarnessSetup.swift:58-75`).
- The connect switch is On by default and stores only what is switched off (`UIPreferences.swift:213-222`), so a missing CLI is
  On with "Not found". `@user` wants the opposite.
- Consumers that do not follow the connected list: the model chip, the footer chip, Home's plan limits (with "Claude did not
  report plan limits"), Home's Today, the Usage page, the new-session entries (`SidebarView.swift:899-914`,
  `HomeEmptyStates.swift:88-105`, the File menu).
- `assets/harness/` has `harness-agy.png` and `harness-opencode.png`, nothing for pi, and nothing wires them.

### FB6-14: Claude-leaning places

- **One gate:** `BuildIdentity.startableProviders` is `["claude"]` in production (`BuildIdentity.swift:28-31`). The Codex
  terminal start and resume exist (`CodexHarness.swift:12-44`, `SessionRuntime+Codex.swift`) and run in the dev build against
  the fake server only; real Codex 0.160 with its shared daemon is untested.
- Missing for parity: the draft (prompt, model, effort, mode) on a Codex start; workspace setup (branch or worktree); a Codex
  rollout reader (last lines, palette, context, edits, mentions); deletion; `codex resume <id>` as the resume command.
- Copy that says Claude on a Codex page or ignores Codex: `ChangesTab.swift:124,146,147,312`, `InspectorOverviewView.swift:146,216`,
  `DraftWords.swift:36`, `HomeEmptyStates.swift:12,88`, `PaletteItem.swift:23`, the deletion flow, `UsageFormat.swift:9-15`,
  `SessionMenuItems.swift:106`.

### FB6-15: the open-session skill

- The plugin is `loom` (`ClaudeLoomPlugin.swift:10`), so the skill is `loom:open-session`. The command is
  `"$LOOM_CLI" open --title … [--project …] (--message-file | --message -)` (`OpenSessionCommand.swift:167`); no model, effort or
  mode. The agent told `@user` to run `/model` and `/effort` for that reason.
- An opened session passes no choices at all: `draft?.choices ?? ClaudeLaunchChoices()` (`SessionRuntime.swift:496`). A draft
  always passes the mode (Ask before edits, or the Settings value, D-63), so an opened session also skips Sphyrna's default mode.
- The launch profile already handles the three flags (`ProviderLaunchProfile.swift:231-257`).
- `recordLaunchChoices` writes the project's "last used" (`SessionCatalog+Launch.swift:46-51`); an agent's pick must not.
- The skill's budgets are pinned by `PluginContractTests`: description 283 of 300 characters, body 1,487 of 1,500.

### FB6-16: what a session knows about the others

- What happened: the second session listed sessions, picked `edd-fe-2f`, which is Claude's name for its opener `9D5B8F60`, and
  sent through Claude Code's own cross-session messaging. Sphyrna launches every session with
  `--settings {"crossSessionInbound":"refuse"}` (`ProviderLaunchProfile.swift:332`, SPEC §3), so the opener refused it. The
  sending agent then said it could not tell which session was its opener, because nothing tells it.
- `"$LOOM_CLI" sessions` lists id, state, harness, last activity, project and title, excluding the caller
  (`OpenSessionListCommand.swift:8-22`). The catalog keeps `opened_by` (`SessionRuntime.swift:513`; the sidebar shows "from X"),
  but `SessionSummary` has no such field and there is no `whoami`.
- Sphyrna's titles do not reach Claude's own session names for sessions started from a draft (`edd-fe-2f` against "Edd-backend
  son PR, AL testi"), so the two lists disagree.
- The channel (CP3) waits since D-93 and RESCUE-PLAN §3.

### FB6-17: where "Loom" still shows

- The plugin and skill namespace (`loom:open-session`, `loom:Ask`), `$LOOM_CLI` and `loom-hook` in Claude's prompts and `/hooks`.
- The default branch prefix `loom/<words>` and `loom/session-<date>` (`NewSessionDraft.swift:80,84`).
- The diagnostics export folder `loom-diagnostics-<stamp>` (`DiagnosticsExport.swift:144`).
- The bundle: executable `Loom` (Activity Monitor, `ps`), plain `CFBundleDisplayName` "Loom" (only `en.lproj` says Sphyrna), the
  file `Loom.app`, the zip `Loom-<ver>.zip` (`scripts/release/build-loom.sh:117-167`), and the client names sent to the harnesses
  (`clientVersion "loom-<build>"`, Codex `originator "loom"`).
- `scripts/check-user-wording.sh` only catches the capitalised word in Swift literals under six folders.
- Kept on purpose (D-77, D-83): the bundle id `local.loom.desktop`, `~/Library/Application Support/Loom`, the module names.

### FB6-18: the subagent view

- The parser reads text, tool calls, thinking (duration only) and tool results (first line plus a count)
  (`SubagentTranscriptParser.swift:59-84`), and the view draws text after `⏺` with the last as Result
  (`SubagentTranscriptView.swift:87-90`). Every line is `Text(verbatim:)` (`:254`), as DESIGN §4 says: no Markdown.
- **Real data:** the agent in the screenshot ("Trace backend AL test flow") wrote one text of 49 characters between 33 thinking
  blocks, whose text Claude does not write, and a final report of 23,609 characters. The other four agents are alike. So Claude
  Code's own view is readable mostly because it shows each tool's input and a few lines of its output, not because of text.
- The parser cuts every string at 4 KiB (`SubagentTranscriptParser.swift:25`), so the 23.6 KB report is cut.
- A cold open reads the last 512 KiB (`SubagentTranscriptTail.swift:112`), and a line over 128 KiB is skipped silently (`:93`);
  the 8 MB agent file has 13 such lines.

### FB6-19: the Overview

Six sections (Session, Context, Usage, Worktree, Changes, Agents; DESIGN still says five), each a 10.5 pt tertiary label over facts
of equal weight with a 72 pt label column, 20 pt apart (`InspectorOverviewView.swift:59-74, 251-316`). The Usage block is a 4 × 6
grid at about 296 pt (`:361-398`).

### FB6-20: the brief's length and language

- The brief's request asks for what moved, who needs `@user` and where to pick up, then "Keep it short"
  (`RemoraPackLayout.swift:241-244`); `RemoraRules.text` says "be brief" (`:24-25`). Nothing sets a number, and the app does not
  cut a streamed brief.
- Today's brief: 1,050 characters for one session, at effort xhigh (7,589 output tokens, mostly thinking).
- It came out in English although Settings say Turkish (`language: tr`); the 23 Oct brief on Sonnet was Turkish. Its draft line
  was Turkish. It also named a raw project id ("project 47C1A54A").

### FB6-21: Home's Remora layout

- The column is capped at 1,000 and centred (`LoomTheme+Home.swift:12-13`); the side column is 316, the sentence 780 and the
  answer 820; the tiles are always three columns (`HomeRemoraTileViews.swift:36`).
- The heading row has no face. The brief block puts the face in its own 136 pt column (`R.placeWidth`), trailing-aligned, and
  the sentence starts at x = 150 while the heading starts at 0 (`HomeRemoraSection.swift:93-136`).

### FB6-22: Remora's model

- The call is `claude -p --output-format stream-json … --tools "" --strict-mcp-config` with Claude's environment
  (`RemoraCall.swift:102-120`), read by a Claude stream-json reader (`RemoraStreamReader.swift`). The host takes a `makeCall`
  closure (`RemoraHost.swift:33,61-64`), which is a clean seam.
- Settings offer Sonnet and Haiku (`SettingsRemoraText.swift:70`); `RemoraPreferences.model` is a plain string.
- Codex 0.160 has `codex exec --json --ephemeral --ignore-user-config -s read-only`, but no `--system-prompt` and no way found to
  switch its tools off. Remora's no-tools contract (D-64, SPEC §10.2) holds for Claude only.

### FB6-23: Remora's project notes

- Only the morning brief writes notes; the rule asks for up to 8 items, each resting on the sessions it came from, and drops an
  item with no session (`RemoraRules.swift:55-59`, `RemoraBlock.swift:120`). That pushes the model to write events.
- Today's note from one session holds 7 items, all events: a PR number and a commit, a 401 from Bitbucket, a response body.
  Caps: 2 KiB, 8 items, 300 characters (`RemoraProjectNote.swift:6-9`).
- The Home tile's "Next:" line is the newest note item that names the session (`HomeRemoraModel.swift:181-197`), so generic
  notes need "Next" to move.

### FB6-24: the open request's box

- `OpenRequestBox` (`OpenRequestViews.swift`) draws the attention colour as a fill at `Status.tintOpacity` with no edge, an SF
  Symbol (`plus.square.on.square`), a 13 medium heading, label and value lines in a fixed label column
  (`LoomTheme.Layout.requestLabelWidth`), the message's first lines, and a system-styled Deny beside an accent Open Session.
- DESIGN §6 Controls' callout says otherwise: the attention wash at 13 % with a 1 pt edge at 32 %, radius 12, the dot and a 13
  semibold heading, the meta in mono. Ink's nearest card is §12's pinned card: raised 2, neutral, a 1 pt attention edge at 34 %,
  the dot before the heading and the kind in mono.
- Several requests stack as separate boxes; after an answer the box just goes.

## Proposals

### FB6-1 (1.7.1)

`CanvasSplitView.drawDivider(in:)` fills the rect with the opaque canvas, then the hairline; Increase Contrast uses its 30 %;
`applyTheme()` marks the split view for display. A test renders the divider and expects alpha 1.

### FB6-2 (1.7.1)

One leading edge after the state mark: `cardTextIndent` = indicator slot + spacing = 20, so the title, the reason line and the
branch start under the project (or harness) mark. The name keeps its place after the mark; the mark's slot becomes 12. DESIGN §2
item 4 and the two pinned assertions change. Text under the state mark is rejected: the subagent trunk runs at x ≈ 6.

### FB6-3 (1.7.1)

- The chip holds one line per connected harness that reports usage: `[mark 12] 168M  Wk ▬ 15%` in mono 11. Order follows
  Connections. A harness not signed in shows `—`.
- Two lines fit today's 46 pt footer. With a third harness (1.8.0) the footer grows by one line, at most three, and the rest go to
  the tooltip.
- Codex is asked on activation and on the minute tick, under the probe's 5-minute floor (amends D-99's "when the page opens").
- The click still opens Settings → Usage; the tooltip and the accessibility label list every harness.

### FB6-4 and FB6-5 (1.7.1)

1. First, three log lines (`beginDrag`, `validateDrop`, `performDrop`) and one real drag in a dev build split the hypotheses.
2. The head becomes a plain row with `.onTapGesture` and the button trait; only the chevron, `+` and `⋯` stay buttons; `.onDrag`
   is on the row.
3. Both build scripts declare the two types under `UTExportedTypeDeclarations`.
4. A project's whole block (head, drafts, cards, note) is the target; the insertion line goes before or after the block.
5. One model-level `activeDrag` (kind and id), set at drag start and cleared on mouse-up, so every target can show one of three
   looks:
   - **insertion line**, 2 pt accent, for ordered lists (projects, tabs, queue rows);
   - **target wash**, the accent at 13 % with a 1 pt edge at 32 %, for "drop onto this" (composer, terminal);
   - **refusal**, no highlight and the dragged source dimmed.
   The AppKit terminal and text view get a small overlay from `draggingEntered` and `draggingExited`.
6. A real drag is the gate (hand check by `@user`, plus the evidence command).

### FB6-6 (1.7.1)

Settings → Theme → Sidebar gets two rows, with a small preview:
- **Fill:** Canvas (today), Raised (`raised1`, one step lighter, as the Claude desktop app), Deep (one step darker than the canvas).
- **Opacity:** Solid, 90 %, 80 % (today's Transparent), 65 %.

Plain fills, no blur, so the energy cost stays 0.0 (1.7.0 measured Transparent). Reduce Transparency draws Solid. A stored
`solid` reads Canvas and Solid; `transparent` and `glass` read Canvas and 80 %. The text contrast test runs on every fill at its
lowest opacity over white and black. Going back to 1.7.0 reads an unknown value as Solid.

### FB6-7 and FB6-8 (1.8.0): the model and effort panel

| Option | For | Against |
| --- | --- | --- |
| A. The popover, with harness tabs, search and an effort step | Smallest | 332 pt is too narrow for four or five harnesses; search in a popover is clumsy |
| **B. A panel in the palette's layer (recommended)** | Scales; two panes; reuses the palette's overlay and keys | A new surface for DESIGN |
| C. A sheet | Familiar | Sheets are for confirmations; it blocks the window |
| D. A popover of recent models with "All models…" opening B | Fast common case | Two surfaces; later, on top of B |

**B, the flow:**
- The chip opens a panel over the window (the palette's scrim, about 620 wide) with the cursor on the current model.
- **Left, the harness rail:** mark, name, model count, a status dot. A harness switched off or not found is dimmed with "Connect…",
  which opens Settings → Connections.
- **Right, the models:** a Recent section first, then the harness's models; typing filters across harnesses.
- **The effort step on the same surface:** ↵ on a model with levels slides to that model's own levels, with its default selected;
  ↵ again confirms and closes. A model without levels closes at once. ⌫ goes back a step, Esc closes.
- The chip shows the harness mark, the model and the effort.

Beneath it (FB6-8 and the draft): `ModelCatalogEntry` carries `efforts` and the default effort for every harness and is gated by
the connect switch; `SessionDraft` gets a harness; `HarnessLaunchChoices` replaces `ClaudeLaunchChoices` in the draft, the last-used
store and presets; each harness has its own list of modes; picking another harness's model switches the draft's harness.

### FB6-9 (1.7.1)

1. **The check:** the same CLI in Terminal.app, fullscreen, at about 123 columns, printing a table nested in a list. If Terminal.app
   breaks it the same way, it is Claude Code's, and an upstream report goes out only on `@user`'s word (it is public). If not, the
   difference is ours and gets its own slice.
2. **Ours regardless:** one debug line per resize (source, columns, rows) in `TerminalSurface`, so a width history can be read next
   time; a new terminal starts at the last laid-out terminal frame instead of 800 × 500; sizes under 20 columns are ignored.
3. **The inspector in a wide pane** keeps changing the grid. Choices: keep the column (today; Claude in fullscreen redraws cleanly,
   the normal buffer reflows), or let the inspector overlay the terminal face (no resize, but it covers the right 328 to 556 pt,
   Claude's prompt box included). Default: keep the column.

### FB6-10 (1.7.1)

- Working means a turn is running: UserPromptSubmit to Stop, an automatic turn, or Claude's registry saying `busy` (which covers
  background subagents).
- A finished turn with background shells or crons reads Ready (or Finished while unviewed), with "2 background" in the header's
  state pill, the card's line and the Overview.
- The pending count stays for Quit's confirmation (quitting kills those shells) and for the idle-stop blockers.
- The "finished" notification and Keep Mac Awake follow the new state.
- SPEC.md:89 and ARCHITECTURE.md:702 change; ARCHITECTURE.md:213 still calls `"shell"` unknown and is fixed with it.

### FB6-11 (1.7.1)

1. **Measure first, in `@user`'s setting:** a scroll cell and a pointer-over-terminal cell in `scripts/perf/real_energy.py`, with
   Claude in fullscreen and in the normal buffer, the pointer customized and not, against Terminal.app and Ghostty with the same
   output. A `sample` of the main thread during each. The `@optimizer` pass `@user` offered reads that profile (Q11).
2. **Motion once per cell** (vendored SwiftTerm patch): send a motion report and run the hover link match only when the pointer's
   cell changes, as xterm does (pixel mode: when the pixel changes, at most once per frame).
3. **The cursor:** set the I-beam on entry and on mode changes, not per event.
4. **Normal buffer:** the region follows the changed rows while parked in scrollback (drop the `yDisp != yBase` full redraw); one
   overlay-scroller update per event, a moved `fireDate` instead of a new `Timer`, no synchronous `displayIfNeeded()`.
5. **Fewer spinners:** subagent rows in the sidebar and the inspector's agent cards show a still "running" mark; the session's own
   spinner (card and header) stays. A window then animates at most one spinner per working session in view.
6. **The gate:** the cells of step 1 before and after; scrolling and the working terminal no worse than Terminal.app with the same
   output; Home and a resting terminal stay at 0.0.

The renderer itself (Core Graphics on the main thread) stays; moving production to Metal (O-07) is a separate decision.

### FB6-12 (1.7.1)

Copy only: Settings → General's helper line and the release notes explain that Activity Monitor lists Claude Code's energy under
"Sphyrna Run Host", and the run host's display name says Sphyrna (FB6-17).

### FB6-13 (1.8.0): the harness catalogue

1. **`HarnessDescriptor`** in LoomCore: id, name, command, mark, install, sign-in and doctor commands, profile variable and folder,
   version table, capabilities, a default for "on when found", the launch spec (model, effort and mode flags, how a first message
   goes, resume), a probe source, a model source and a limits shape. `HarnessCatalogue.all` is the order Connections shows.
2. **Found or not, cheaply:** `HarnessAvailability` looks the command up on the terminal environment's PATH
   (`ProviderToolchainProbe.find`, cached environment); no `--version` run.
3. **Three states:** On, Off, Not found. Not found is Off with the switch disabled and "Not found on this Mac" under the name;
   a found harness can be switched on. Preferences store an explicit map.
4. **Identity:** `HarnessID`, a string-backed struct with static members. An unknown value from a newer build reads as an unknown
   harness instead of failing, which keeps going back a version safe.
5. **Everything iterates the connected catalogue:** `ModelCatalog`, the probe sources, usage and limits, Home, the chip, the
   new-session entries and menus, the palette, Connections.
6. **The guard** forbids `provider == .<any>` and `? "codex" : "claude"` outside the descriptor files.
7. opencode, agy and pi get descriptors with `startable` off and marks (pi needs one), so they show as Off or Not found. Each
   becomes startable through its own slice; agy is the cheapest (its flags match Claude's).

### FB6-14 (1.8.0): Codex first-class

1. **Spike:** the dev build against real `codex 0.160.0`: start, resume, status, stop, with a throwaway profile. Its breakages gate
   the rest.
2. **Start and resume with the draft:** the production gate opens; the Codex launch profile carries the first message, `-m`,
   effort through `-c model_reasoning_effort=…`, and the mode through `-a`/`-s`; workspace setup (branch or worktree) is shared;
   the catalog records Codex's choices; "Copy Resume Command" gives `codex resume <id>`.
3. **The rollout reader** (`~/.codex/sessions/…`): last lines, project usage, palette search, context, edits, mentions; until it
   lands those surfaces say "Not read for Codex yet".
4. **Deletion** through the harness, with the existing checks.
5. **The copy sweep:** the strings above take the harness's name or a neutral word.

### FB6-15 (1.7.1)

- `open` accepts `--model`, `--effort` and `--mode`; `OpenSessionInput.validated` checks them (effort among the model's levels, the
  model a safe token, the mode one of Ask before edits, Accept edits, Plan, Auto). **Full access is never an agent's to pick.**
- With no `--mode`, an opened session takes Sphyrna's default mode, as a draft does.
- The approval box shows Model, Effort and Mode, so `@user` sees what they approve.
- An opened session's choices are not remembered as the project's last used.
- The plugin becomes `sphyrna` (`sphyrna:open-session`); the body points to `"$SPHYRNA_CLI" open --help` for the flags, so it stays
  under its budget.
- Optional wire fields keep older helpers working.

### FB6-16 (1.7.1 part 1; 1.8.0 part 2)

**Part 1, awareness, no new consent surface:**
- `sessions` and `--json` gain `openedBy`; a new `whoami` returns this session's id, title, project, state, its opener (id, title,
  state) and the sessions it opened.
- A session started from a draft passes its Sphyrna title to Claude as the session's name, so Claude's own list and Sphyrna's agree.
- The skill tells the agent that Sphyrna is the way between its sessions, and that Claude's own cross-session messages are refused.
- `crossSessionInbound: refuse` stays (SPEC §3): an agent must not reach another session without `@user`.

**Part 2, `send`, if `@user` wants it:**
- `"$SPHYRNA_CLI" send <id> --message-file …` asks for approval in the sender's card (the open request's box), with sender, target
  and full text, bounded size and a rate limit.
- Delivery is pull: the message waits in the target's inbox with a badge on its card, and the target's next UserPromptSubmit hook
  adds it as context; `inbox` reads it on demand. Typing into the target's terminal is left out (it can land in a permission
  prompt or a half-typed message).

### FB6-17 (1.7.1)

Where the user sees it:
- the plugin `sphyrna`, the output style `sphyrna:Ask`;
- `SPHYRNA_CLI` exported beside `LOOM_CLI` (older sessions and saved Bash rules keep working);
- the branch prefix `sphyrna/…` (existing branches untouched);
- the diagnostics folder `sphyrna-diagnostics-…`;
- the plain `CFBundleDisplayName`, the run host's display name;
- the client names sent to the harnesses.

A question for `@user`: the executable and the app file (`Loom` → `Sphyrna`, `Loom.app` → `Sphyrna.app`). They show in Activity
Monitor and Finder, but the signature, the run host's owner requirement, the login item and the upgrade all hang on them; the
bundle id and the data folder stay (D-83). The wording guard widens to lowercase `loom` in user-visible strings, scripts and the
plugin's files, with an allow-list.

### FB6-18 (1.7.1)

1. **Tool calls read like Claude Code's:** each shows its input in one line (the command, the file and range, the pattern) and its
   result's first lines (three by default, the rest behind a click), not one line plus a count.
2. **Text and the Result in Markdown:** the Chat Markdown blocks (`ChatMarkdown.parse`, `ChatMarkdownView`, cached by text) with the
   transcript's type scale injected; links open for http, https and mailto, as in Chat.
3. **The 4 KiB cut** stays for tool inputs and results and goes to 64 KiB for text, so a report is whole.
4. **A line over 128 KiB** shows as "(an entry too long to show)" instead of disappearing.
5. Thinking stays a duration: Claude writes no thinking text.

Cost: rows are lazy and parsed once per text; the feed reads at most every 200 ms. The gate is the first paint of the 8 MB agent
file, measured before and after.

### FB6-19 (1.7.1)

- A hairline between sections, 16 above and below; section labels in secondary; a headline on the right of each head (Context
  "38 %", Usage "$1.23", Changes "4 files +120 −8", Agents "2 running").
- Usage: three rows (Main, Subagents, Total) with tokens and cost; the token kinds behind "Details".
- Session: the state and start time on one line; "Claude Code 2.1.300 · Opus 5.5 · high" on one; Mode on its own.
- DESIGN's Overview names six sections.

### FB6-20 (1.7.1)

- The brief's request sets a number: two short sentences, at most about 35 words; only what moved, what needs `@user` and the next
  step; no history, no ids, no PR or ticket numbers. Per-session detail goes to the chips and the drafts.
- The language goes into the request as an instruction, not only into the pack, and a test pins it.
- Remora's default effort becomes low for briefs; Settings keep the choice.
- A real call checks it (D-101's gate is the real scenario).

### FB6-21 (1.7.1)

- Remora's face moves into the heading row, before the title, at the fold's 36 pt; the date and time follow the title; the sentence
  is the body, full width under the heading, with a maximum measure.
- The column grows with the pane up to about 1,280; the side column scales between 316 and 400; the tiles take one, two or three
  columns by width (below 560, below 840, above).
- The gate: screenshots at 1280 × 800 and in full screen (`toggle-fullscreen`).

### FB6-22 (1.7.1 and 1.8.0)

- **1.7.1:** Remora's model list is every Claude model `ModelCatalog` knows (Opus included), with that model's own efforts.
- **1.8.0:** `RemoraBackend` with the Claude call as it is and a Codex backend on `codex exec --json`, after a half-day spike. A
  harness ships only with a verified way to run it without tools; otherwise it is not offered for Remora (D-64 stands).

### FB6-23 (1.7.1)

- A note holds only what stays true for about a month and beyond one session: how the project is built, tested and released;
  conventions and standing decisions with their reason; recurring pitfalls; where key things live. Never events (merged PRs,
  ticket numbers, errors, status codes, "today"). The model merges into an item instead of adding one, and returns the note
  unchanged when nothing durable was learned.
- **Caps:** 1.5 KiB, 5 items, 160 characters.
- **Gate:** a note is written only for a project with at least two sessions read, or one that already has a note.
- **Expiry:** an item re-confirmed by the model takes today's date; an item not re-confirmed for 90 days leaves the share.
- **Citations stay:** deleting a session still strips the items that cite it (SPEC §10.3).
- **"Next" moves** into the brief block as a per-chip `next` line kept in `day-brief.json`, so tiles stop reading notes.
- The first brief after the update rewrites today's note under the new rule; no migration code.

### FB6-24 (1.7.1)

The request reads as the session card it will become, on Ink's pinned-card look:
- **The card:** raised 2, radius 12, 16 inside, a 1 pt attention edge at 34 %, no wash.
- **The head:** the attention dot, "Open a new session?" in 13 semibold, and on the trailing side the requester in mono ("from
  edd-fe-2f") and "1 of 3" when several wait. Several requests are one card with the counter, oldest first.
- **The session it will be:** the title in the card's title type; under it one mono meta line in the sidebar card's order: the
  harness mark, the model, the effort and the mode (FB6-15), then the project's mark and name, then the branch or "new worktree".
  The project uses its own tone, as on the sidebar.
- **The message:** its first three lines at 12.5 primary on a raised 1 inset (radius 8, 10 × 12 inside); "Show full message" as a
  ghost button opens a bounded scroll area.
- **The buttons**, at the trailing end, DESIGN §6 sizes: Deny as a secondary button, Open Session as the one accent button. Neither
  is the default; Return stays with the terminal, as today.
- **States:** opening shows the session spinner on the button's place; a failure keeps the card with the failure text and Dismiss;
  after an answer the card folds to one line for 4 s ("Opened: <title>", with Go to Session, or "Denied: <title>") and goes.
- DESIGN §4 "A session that opens a session" and §6's callout rule are rewritten to this card; the accessibility label stays.

## Decisions

Each has a recommended default. `@user` accepted every default on 26 Oct (D-103).

| Q | Question | Default |
| --- | --- | --- |
| Q1 | The release line: 1.7.1 for the fixes now, 1.8.0 for every harness first-class | Yes |
| Q2 | FB6-10: Working ends at Stop even with background shells, crons or subagents (the registry's `busy` covers subagents) | Yes |
| Q3 | FB6-15: agents may set model, effort and mode, never Full access; an opened session takes the default mode | Yes |
| Q4 | FB6-17: the executable and the app file become Sphyrna too (`Sphyrna.app`) | No for 1.7.1; with 1.8.0 after a migration check |
| Q5 | FB6-16: part 1 (`whoami`, `openedBy`, titles) in 1.7.1; `send` with approval and pull delivery in 1.8.0 | Yes |
| Q6 | FB6-3: Codex is asked on activation and each minute under the 5-minute floor, so the footer stays current | Yes |
| Q7 | FB6-7: the picker is B, the panel | B |
| Q8 | FB6-13: a newly found harness: Claude and Codex on when found, opencode, agy and pi off until switched on | Yes |
| Q9 | FB6-22: a harness serves Remora only with a verified no-tools run | Yes |
| Q10 | FB6-23: the gate (two sessions or a prior note), 90-day expiry, caps 1.5 KiB, 5 items, 160 characters | Yes |
| Q11 | FB6-11: an `@optimizer` pass on the profile of S4's measurements, as `@user` offered (D-101 leaves it to `@user`) | Yes |
| Q12 | FB6-11: subagents show a still "running" mark; only a session's own spinner animates | Yes |
| Q13 | FB6-9: the inspector stays a column in a wide pane (not an overlay on the terminal) | Yes |

## Release 1.7.1: slices

One implementer at a time (D-101); the gate is the installed app in `@user`'s scenarios. Slices with disjoint files may run side
by side when the planner says so.

| # | Slice | Items | Gate |
| --- | --- | --- | --- |
| S1 | Sidebar shell: divider, card edge, colour and opacity | FB6-1, FB6-2, FB6-6 | Render tests; screenshots in Ink and Paper, Solid and 65 % |
| S2 | Drag: the log check, the head, the declared types, the block target, `activeDrag` and the three looks | FB6-4, FB6-5 | A real drag in the dev build; `@user`'s hand check |
| S3 | State: Working ends at Stop, "N background", notifications and Keep Awake | FB6-10, H2 | Hook-fixture tests with a never-ending shell |
| S4 | Terminal and energy: the table check, resize log and launch size; the measurement and `@optimizer` pass; motion once per cell, the cursor, the scrollback region, the scroller; still marks for subagents | FB6-9, FB6-11 | `real_energy.py`'s new cells before and after, against Terminal.app; Home and a resting terminal at 0.0 |
| S5 | Skill and awareness: `open` flags, default mode, `sphyrna` plugin, `whoami`, `openedBy`, titles to Claude; the request card | FB6-15, FB6-16 part 1, FB6-24 | A real opened session with Opus and medium; `whoami` from it; screenshots of the card waiting, failed and folded |
| S6 | Names: what the user sees, the wider guard | FB6-17, FB6-12 | The guard; Activity Monitor names |
| S7 | Agents view and Overview | FB6-18, FB6-19 | First paint of the 8 MB agent file; screenshots |
| S8 | Remora: brief length and language, Home layout, every Claude model, notes | FB6-20, FB6-21, FB6-22 (1.7.1), FB6-23 | A real brief in Turkish; full-screen screenshots |
| S9 | Footer per harness, with Codex asked on activation | FB6-3 | Screenshots with Claude and Codex; the energy of Home idle stays 0.0 |
| S10 | Health: helper runs named in the log | H1 | Log lines |

## 1.7.1 implementation brief

For one implementer session (`@user`, 26 Oct: Sonnet at high effort, the whole batch at once, narrow tests, then back to the
planner for the final review). This section is the whole assignment; read the rest of this file only for the items it names.

**Goal.** Build 1.7.1's slices (the table above) as this file's Proposals describe them, with every default of the
[decisions](#decisions) (D-103). Stop before the release: no version bump, tag, promote, install, push or GitHub release.

**Where.**
- Read first: `AGENTS.md` §1, §6.2 and §7; `DEVELOPMENT.md` before building, running evidence mode or measuring; then, per slice,
  this file's "What the code says" and "Proposals" for its items.
- Work in a new worktree on a new branch from `v2`:
  `git -C ~/Library/Caches/loom-v2/wt/v2 worktree add -b slice/r8-171 ~/Library/Caches/loom-v2/wt/r8 v2`.
- Commit each slice there (English messages, one or more commits per slice). Never commit to `v2`, never edit
  `~/Documents/github/loom-dev` or `~/Documents/github/loom`; the planner mirrors the docs and integrates.
- `v2`'s uncommitted `Package.resolved` is not yours; leave it.

**Order.** S3, S1, S5, S8, S7, S9, S6, S10, S2, S4. S2's real drag and S4's measurements need the screen and an idle Mac: build and
test them off-screen; run their on-screen parts only if `@user` says the Mac is free, otherwise list them under "Needs".

**Per slice.**
- Change the code and, in the same commit, the doc lines the slice owns ("Docs to amend": SPEC, DESIGN, ARCHITECTURE).
- Tests stay narrow: `scripts/check.sh --scratch <path outside ~/Documents> --suite <the suites the slice touches>`. Update the
  tests a change breaks on purpose; add a regression test only where it guards the slice's point:
  - S3: a Stop that lists a never-ending shell reads Ready with "1 background", in the indicator and the `sessions` word;
  - S1: the divider's rect is opaque;
  - S5: `open --mode bypassPermissions` is refused, and an opened session without `--mode` gets the default mode;
  - S8: the brief's request carries the length rule and the language; a project with one session read gets no note;
  - S4: a run of mouse moves inside one cell sends one motion report.
- No window tests, no `--full` gate, no `--release-tree` run: the planner runs the gate in the review.
- Theme literals only in `LoomTheme*.swift`; `check-theme-literals.sh` and `check-user-wording.sh` pass.

**Real checks, one each, at least cost.**
- S5: one real opened session (Opus, medium) from a throwaway Claude session in `/private/tmp/loom-real/…`, in the dev app with
  its own data root; then `whoami` from it.
- S8: one real brief in Turkish in the dev app, reading the screenshot of Home in full screen.
- Never the installed `/Applications/Loom.app`, its data, `~/.loom`, the real `~/.claude` or `~/.codex` as test material.
- Screenshots through the evidence command only (`screenshot:`). Its terminal can look white although the real one is dark;
  do not use `screencapture` (it raises a macOS privacy prompt).
- S4's `@optimizer` pass (Q11) is the implementer's own `sample` of the main thread during the new cells, to spend less of
  `@user`'s weekly usage; no separate agent.

**Hold the line on contracts.** Full access is never an agent's pick; `crossSessionInbound: refuse` stays; Remora runs without
tools; Chat stays frozen (D-100); the bundle id, the data folder and the module names stay (D-77, D-83). A change these need goes
under "Needs", not into the code.

**When a slice blocks** (a decision this file does not settle, or a change outside AGENTS §7's areas such as `Package.swift`),
note it, skip that part and go on with the next slice.

**The report** at the end, in this session's last message, in English, short:
- per slice: the commit SHAs, what changed, the checks run with their results;
- what was not verified and why; deviations from this file;
- "Needs": decisions for `@user` and on-screen checks left (S2's real drag, S4's cells, FB6-9's Terminal.app check, the
  full-screen Home);
- a draft `plans/RELEASE-NOTES-1.7.1.md` committed on the branch.

## Release 1.8.0: outline

| # | Slice | Items |
| --- | --- | --- |
| P0 | Real-Codex spike | FB6-14 |
| P1 | Harness catalogue, `HarnessID`, the widened guard, descriptors for opencode, agy, pi | FB6-13 |
| P2 | Availability, the three states, Connections, Home's connect cards | FB6-13 |
| P3 | Consumers from the catalogue: models with efforts, usage, limits, Home, menus | FB6-13, FB6-3 |
| P4 | The harness-neutral draft and the panel | FB6-7, FB6-8 |
| P5 | Codex start and resume with the draft; copy sweep | FB6-14 |
| P6 | Codex rollout reader; Codex deletion | FB6-14 |
| P7 | Remora backends | FB6-22 |
| P8 | `send` between sessions | FB6-16 part 2 |

## Docs to amend

- DECISIONS: one entry for this round's line and the answers to Q1 to Q13 (D-103 onward).
- SPEC: §3 (opened sessions' choices, `whoami`), §6 (state: Working ends at Stop; SPEC.md:89), §10 (Remora's notes, brief length,
  model list), §12.2 (Codex asked on activation).
- DESIGN: §2 item 4 (the card edge), §2 item 2 (fill and opacity), §4 and §6 (the open request's card), §4 (the subagent transcript in Markdown, tool rows), the
  Overview, §9 and §20 (Home's Remora), §11 (the panel, in 1.8.0), the drag looks.
- ARCHITECTURE: :213 and :702 (the registry's `shell`, the state rule).
- STATUS and ACTIVE-PLAN after the go.
