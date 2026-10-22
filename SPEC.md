# Sphyrna (Loom) Product & Behavioral Specification (`SPEC.md`)

**Updated:** 22 October 2026 · **Target Release:** **Sphyrna 1.6.0** ([D-77](DECISIONS.md), [D-83](DECISIONS.md))

This document is the single authoritative specification of what Sphyrna (internal code name **Loom**) must provide: its product guarantees, process ownership boundaries, session lifecycle, deletion and retention contract, Studio shell, Native Chat face, Pinned Request Cards, Inspector review & aside surfaces, Cross-Session Channel, Remora assistant, macOS system integration, and resource/context budgets.
- Visual tokens, colours, typography, and geometry live in [`design/DESIGN.md`](design/DESIGN.md) and [`design/reference.html`](design/reference.html).
- Code targets, runtime actors, UI surface-to-code mappings, and technical gotchas live in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## 1. Identity, Founding Goals & Core Experience

### 1.1 Three Founding Goals ([D-83](DECISIONS.md))
1. **Light:** RAM, CPU, disk, and energy never tire the user, while every capability remains intact. Abandoned or ended sessions must never accumulate live processes, terminal buffers, or background polling.
2. **Sessions, not harnesses:** Sphyrna is the central place that manages every session regardless of its underlying harness, so work can pass between Claude and Codex, and sessions can discover (`"$LOOM_CLI" sessions`) or request opening (`"$LOOM_CLI" open`) other sessions under the user's authority.
3. **Cost out of sight:** Subscription quota and context cost stay invisible. Nothing enters a session's context beyond the project's own instructions except the ≤ 300-character Sphyrna plugin skill description (and `loom:Ask` output style when in Ask mode).

### 1.2 Core Experience & Scope ([D-01](DECISIONS.md), [D-57](DECISIONS.md), [D-69](DECISIONS.md), [D-77](DECISIONS.md), [D-83](DECISIONS.md))
- **Core experience contract:** *The live session is always the user's own unmodified Claude Code CLI in a process Sphyrna owns, in its terminal or in its structured mode, with one owner at a time. One app-wide switch in Settings chooses which; the terminal is always one of the choices. Codex runs in its terminal.*
- **Platform:** Native macOS 27 and later (`Swift 6`, `SwiftUI` + `AppKit`, vendored `SwiftTerm` with local patches, `SQLite` catalog).
- **Name & bundle identity (`D-77`, `D-83`):** User-facing app name is **Sphyrna**; assistant name is **Remora**. To preserve macOS TCC permissions and user data, the production bundle ID remains `local.loom.desktop` (`~/Library/Application Support/Loom`, sockets in `~/.loom`), and the development bundle ID remains `local.loom.desktop.dev` (`~/Library/Application Support/Loom-Dev`, sockets in `~/.loom-dev`).
- **Harnesses in 1.6.0 (`D-08`, `D-28`, `D-69 (5)`):** Claude Code is active in both faces. Codex code remains in the tree and its UI entries stay visible on first-run Home and in new-session model menus (`"Codex comes in a later version"`), but Codex is **frozen and non-startable** in 1.6.0 (`BuildIdentity.startableProviders = [.claude]`).
- **Unpinned provider CLIs:** Claude and Codex CLI versions are never pinned on the user's behalf. Capability flags (`--help`, `--version`, `system/init`) are probed and refreshed when the executable stamp changes; unsupported features degrade explicitly without false success reports.
- **Truthful outcomes:** The words *started*, *stopped*, *delivered*, and *deleted* always describe verified outcomes. User-facing text always says **"session"**, never **"conversation"** (`scripts/check-user-wording.sh`).

---

## 2. Process Ownership, Run Scopes & App Quit

### 2.1 Exclusive Run Scope Guarantee ([D-05](DECISIONS.md))
- **Why application coalitions are insufficient:** Apple XPC services join the main app's coalition dynamically, and `KERN_PROCARGS2` environment markers are unreadable on Apple platform binaries (e.g. `/bin/sleep`) and can be escaped via `setsid` / double-fork before a snapshot.
- **Per-run `LoomRunHost` coalition:** Every managed run (`SPAWN_PTY` for terminal or `SPAWN_STDIO` for pipe/Chat/Remora) is spawned by a dedicated instance of the bundled AppKit-less helper `Contents/Helpers/LoomRunHost.app` launched via LaunchServices (`open -n -g -j`). Each launch receives a new, exclusive XNU resource coalition inherited across `fork`/`exec`/`setsid`/double-fork.
- **Distinguishing forked children from `launchd` XPC members:** `p_orig_ppidversion` in the kernel process table preserves the parent at `fork` time even after `exec` and reparenting to `launchd`, allowing Sphyrna and `LoomRunHost` to target only forked descendants while never signalling `launchd`-spawned XPC services.
- **Refusal on broken scope:** Coalition and lineage data are read via `proc_pidinfo`. If a run scope cannot be established or verified, the session is **not** started and an explicit error banner is shown.
- **Out of scope by construction:** Work handed off to external daemons via LaunchServices or `launchd` (`open -a`, `launchctl`, `brew services`, Docker daemon jobs), or processes that switched to another UID (reported as a stop failure if they cannot be terminated).
- **Codex server scope (`D-05`):** When Codex is active, each live Codex session runs its own `codex app-server` inside the same run scope as its TUI so stopping the session stops its server (`0` cached server state left behind).

### 2.2 Stop, Window Close, Normal Quit & Crash Recovery ([D-03](DECISIONS.md), [D-45](DECISIONS.md))
- **Window close (`Cmd+W` or red close button):** Closes the window only; the app and all running sessions continue running (`applicationShouldTerminateAfterLastWindowClosed` is `false`).
- **Session Stop (`Cmd+.` or header Stop square):**
  - Blocks new input (`TerminalInputGate`), runs the graceful leave sequence (in Chat: sends `interrupt`, waits up to 2 s for `result`, closes stdin, waits for exit), freezes forked coalition members, re-verifies identities (`loom_signal_if_matches`), escalates (`SIGHUP` → `SIGTERM` → `SIGKILL` for PTY; `SIGTERM` → `SIGKILL` for pipe), and verifies that the run scope is completely empty before reporting stopped.
  - Verified Stop closes the stopped session's tab unless the user navigated elsewhere while Stop was verifying.
- **Normal Quit (`Cmd+Q`):**
  - **Acceptance criterion:** Zero running processes started and owned by Sphyrna remain; external user terminal sessions are untouched.
  - **Confirmation (`D-45`):** When user-initiated and any session is Working or Waiting for approval, Quit shows a confirmation alert with `Cancel` as the filled default (`Return`). System logout, restart, and shutdown (`keyAEQuitReason`) skip confirmation so Sphyrna never blocks macOS shutdown.
  - **Unverified stop alert:** If any scope cannot be verified empty on a user-initiated Quit, Sphyrna presents a 3-button vertical alert (`Try Again` default, `Keep Sphyrna Open`, and destructive `Quit Anyway`).
- **Loom crash / Force Quit (`D-05`, `O-09`):** If the control socket between Sphyrna and `LoomRunHost` breaks without an orderly `EXIT` frame, `LoomRunHost` immediately stops all forked processes in its coalition and exits. On next launch, `PreviousRunRecovery` and `StaleSocketSweep` clean up any abandoned run scopes and sockets and surface interrupted sessions in Home's `Continue` card.

---

## 3. Managed CLI Environment & Session Integration

- **Clean login-shell environment inheritance (`DP-CP4-8`):** Managed CLIs inherit the user's login shell environment (`.zshrc`, `PATH`, SSH agent, proxy, user env vars) captured once at app launch from an initial environment stripped of parent `CLAUDE_CODE_*` variables (preventing session ID, socket, or token leaks if Sphyrna itself was launched from a terminal). Shell startup warnings/errors do not block session start and are surfaced as non-fatal notices; if the environment cannot be resolved at all, a retryable error is shown.
- **Claude Agent View disabled:** Sphyrna sets `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` on managed Claude sessions so all subagents stay inside the managed session boundary.
- **Session-specific Claude hooks & settings (`--settings`, `--plugin-dir`):**
  - New sessions pass `--session-id <uuid>`; resumed sessions pass `--resume <id>`.
  - Every spawn passes `--model`, `--effort`, and `--permission-mode` explicitly from the session's catalog record so neither face loses the user's choices across Resume or handover (`ClaudeDefaultModel` omits `--model` on resume only when the transcript model matches the user's configured default without `[1m]`, preserving 1M context windows).
  - `--settings` injects session-only hooks (`loom-hook` over an authenticated `0600` Unix socket `LOOM_HOOK_SOCKET`) and `crossSessionInbound: refuse` (blocking unauthorized inbound cross-session messages without disabling the `SendMessage` tool needed by subagents). The user's global `~/.claude/settings.json` is never modified.
  - `/clear` in Claude (and `/new` in Codex) creates a new session card for the cleared conversation while preserving the old session card and its transcript.

---

## 4. Session Lifecycle & State Model

### 4.1 Lifecycle States vs. Momentary Agent Work States
Lifecycle state (`active`, `idle`, `stale`, `deleted`) and momentary agent work state are strictly orthogonal:

| Lifecycle State | Meaning | Resource Expectation |
| --- | --- | --- |
| **`active`** | Running session (terminal or pipe run alive). Need not be selected on screen. | Managed CLI, run scope, and bounded output buffers exist. |
| **`idle`** | Stopped session that is not stale; can be resumed in the same session at any time. | **Zero live processes or PTYs.** Terminal face keeps only a static `TerminalScreenSnapshot` (≤ 400 rows / 1 MiB, `D-54`). |
| **`stale`** | Stopped session unused (no prompt and no deliberate user view) for **15 days**. | Zero live processes. Viewing a stale session does **not** clear `stale` or start a process; only explicit `"Reactivate and Resume"` reactivates it. |
| **`deleted`** | Session whose permanent deletion contract (§5) has completed and been verified. | Catalog row, caches, and claimable local provider files are gone. |

- **No automatic idle stop (`D-38`):** Running sessions are **never** stopped automatically after 60 minutes of inactivity; they run until the user stops them or quits.
- **Refreshing usage time:** Sending a prompt or deliberately selecting/viewing a non-stale session refreshes its usage timestamp and delays `stale`. Background list refreshes, usage scans, or hook events do not count as user viewing.

### 4.2 Status Derivation Priority & Signals
Every status surface (sidebar row, activity card, tab, header state pill, Home, palette, menu bar) derives a single status from `SessionIndicator` in this priority order:
1. **`stopUnverified` / `failed` / `problem`** (Failure dot `#F2615C` / `#C8322C`, or `7 pt` diamond under macOS `"Differentiate without color"`, `D-69 (11)`).
2. **`identityUnclear`** (Hollow attention ring).
3. **`waitingForApproval` / `waitingForInput`** (`"Needs approval"` / `"Waiting for you"`, `7 pt` attention dot `#FF9E0A` / `#C46A00`; includes pending agent `"$LOOM_CLI" open` requests).
4. **`working`** (`12 fps` 10-frame `BrailleSpinner` `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`; stays `working` after a main-thread `result` while background tasks `background_tasks_changed` / `task_*` are still running).
5. **`unviewedCompletion`** (`"Finished"`, `7 pt` unviewed blue dot `#5C8CFF` / `#2557CC`; cleared by viewing the session or clicking `"Mark as Read"`, `D-39`).
6. **`ready` / `idle` / `stale` / `ended`** (No mark in lists/tabs; `ended` shows no header state pill; `stale` dims the title to secondary).
- **Hook watchdog:** If the Claude session registry marks a session `"busy"` with zero hook events for `3 s` (`hookSilenceGrace`), Sphyrna raises a `hookSilenceIssue` notice and journals `hook_silence` until a hook arrives.

---

## 5. Permanent Deletion & Session Retention (`Settings → Sessions`)

### 5.1 Seven-Step Permanent Deletion Contract ([D-26](DECISIONS.md), [D-37](DECISIONS.md))
Deletion is an end-to-end state machine persisted in the `deletions` table (`requested` → `stopping` → `provider_data` → `catalog` → `verifying`) so an interrupted deletion resumes at next launch:
1. Close input gates and refuse new messages, starts, or resumes.
2. Cancel pending jobs, handovers, and queued deliveries bound to the session (and first delete any child side chats through the same verified path).
3. Stop owned live processes and verify the run scope is empty.
4. Remove claimable local Claude files for all provider session IDs of the session using the **CP4-A allowlist** (`ClaudeDataInventory`, descriptor-relative with `O_NOFOLLOW`, same-device `st_dev`, never following symlinks):
   - `<profile>/projects/<folder>/<id>.jsonl` (transcript), `<id>.orphaned-*.jsonl`, `<id>.jsonl.superseded-*`, and `<id>/` (conversation folder including subagents);
   - `<profile>/file-history/<id>`, `session-env/<id>`, `debug/<id>*`, `tasks/<id>`, `image-cache/<id>`, `uploads/<id>`, `todos/<id>-agent-*.json`;
   - Tier-2 temporary output directory matching `<id>`.
5. Delete catalog rows (`DELETE` with `PRAGMA secure_delete = ON` + `wal_checkpoint(TRUNCATE)` so zero bytes of deleted titles remain in `catalog.sqlite3` or `-wal`), purge **all** catalog backups and `.damaged` copies before taking a fresh backup, and fence the deleted provider IDs in `ProcessSupervisor`.
6. Run all registered `ConversationForgetting` hooks (`ChatSessionHost` queues/drafts/rewinds, `ClaudeUsageIndex`, `RemoraMemoryForgetter` stripping cited lines from day/week journals, project notes, and `day-brief.json`, plus in-flight call fences) and verify that `ClaudeDataDeleter.verify` finds zero remaining claimable files.
7. Report deletion complete only after verification succeeds.

- **Shared data & explicit boundaries:** Shared `~/.claude/history.jsonl` is **never** rewritten (concurrent CLI appends could be lost) and `CLAUDE_CODE_SKIP_PROMPT_HISTORY` is **never** set (it disables transcript writing and breaks `--resume`). Project source code, git worktrees, and remote provider copies are never deleted by session deletion.
- **`"Remove from Loom Only"` (`DP-CP4-7`, `D-69 (10)`):** When a deletion is blocked by an unreachable folder or fails verification, the user can choose `"Remove from Loom Only"`, which stops the run and removes all Sphyrna catalog rows, caches, and Remora memory entries while leaving Claude's files on disk.

### 5.2 Retention & Cleanup Review (`Settings → Sessions`, [D-69 (10)](DECISIONS.md))
- Ships in every build; **nothing is ever deleted without user confirmation** (automatic silent deletion is off).
- **Default policy (`DP-CP4-2`):** Targets only `stale` sessions (unused ≥ 15 days) that have waited at least the **deletion wait** (default **15 days**, configurable in `Settings → Sessions`) since the later of becoming stale and last being viewed.
- **Review triggers:** A cleanup review is due **30 days** after the last review (configurable), or immediately when the app reopens after a **≥ 45-day absence** or when **> 10 eligible sessions** accumulate.
- **Protected exceptions (never selected for automatic cleanup):** Pinned sessions, sessions whose git worktree has uncommitted changes or unpushed commits (`CleanupWorktreeProtection`), and sessions involved in an unfinished authorized cross-session task.

---

## 6. Faces, Studio Shell, Sidebar & Navigation

### 6.1 App-Wide Face Switch & Handover ([D-57](DECISIONS.md), [D-69 (1)](DECISIONS.md), `R1`)
- **App-wide switch:** `Settings → General → Sessions run in` chooses **`Chat`** (default) or **`Terminal`**.
- **Start & Resume (`FacePolicy`):** Starting or resuming a Claude session uses the current Settings switch. A running session keeps its current face until it stops. While the switch is `Chat`, a stopped Claude session displays its interactive Chat view (keeping its composer so sending a message resumes it in place). Codex always uses the terminal face.
- **One-way Chat → Terminal handover (`V19`, `R1`):** Per-session face switches in the header, `⋯` menu, and `/` menu are gone, and Terminal → Chat handover is removed (`R1`). Only the Chat policy banner's **`"Switch to Terminal"`** action performs a live handover: it sets Settings to `Terminal`, waits for any active turn to finish (refusing if a request card or background task waits), stops the pipe run after a point of no return (pausing any queued messages with `"Queue paused because the session moved to the terminal"`), and resumes the session in `TerminalSurface`.

### 6.2 Window Chrome & Sidebar (`V04`, [D-74](DECISIONS.md), [D-75](DECISIONS.md), [D-81](DECISIONS.md))
- **One window (`1220×780` initial, `780×500` min):** Sidebar (`300 pt` default, `220–520 pt` draggable, collapsible via `⌃⌘S`) beside the main detail pane (`≥ 480 pt`).
- **Top rows:**
  1. **`Search`** door (`28 pt`): clicking it (or pressing `⌘K` / `⌘F`) opens the Command Palette (there is no inline sidebar filter).
  2. **`Home`** (`⌃⌘H`): shows a numeric badge of sessions that need the user (matching the Dock badge).
  3. **`New session`** (`⌘N`): opens the Draft Session page in the most recently used project (`D-63`).
- **List heading (`projects · activity`):** Switches between **Projects** (`⌘2`) and **Activity** (`⌘1`).
  - **Projects view:** Collapsible project headers (`16 pt` letter mark in project tone, name, trailing status dot: failure > attention > unviewed; hover reveals `+` New Claude session and `⋯` project menu with 7 colour swatches), followed by any non-empty draft row (`"Draft"` + `Discard`) and sessions newest-first (`D-39`), plus a `No project` group when projectless sessions exist. Each session row (`28 pt`) shows the `12 pt` status slot, `12 pt` harness mark, title, and relative age, followed by its subagent tree (`§4.2` / `DESIGN §4`).
  - **Activity view:** `Drafts` (when non-empty), then **`Active`** (live working turns, waiting approvals/requests, unread finished/failed turns, plus the currently selected session held until selection changes, `D-54`), then day buckets (`Today`, `Yesterday`, earlier dates). Activity cards (`radius 10`) show status + harness mark + title + time, then the 1-line **reason** in Active (`"Running pytest -q"`, `"Edit PaymentService.swift"`, etc.), then a fixed bottom row with branch and project mark/name (`D-69 (7)`).
- **Sidebar footer (`46 pt`):** Left holds the **Usage chip** (`<tokens> today` + bottleneck `5h`/`Wk` window with `40×4 pt` meter, turning orange below 20 %, clicking opens `Settings → Usage`, `D-32`, `D-39`); right holds `+` (`New Claude Session`, `New Codex Session` disabled, `Add Project…`) and the gear button (`Settings`, `⌘,`).

### 6.3 Detail Header & Session Tabs ([D-33](DECISIONS.md), [D-53](DECISIONS.md), [D-74](DECISIONS.md))
- **Detail header (`52 pt`, shown on sessions only; Home and Project page have no header row):**
  - Left: sidebar toggle (when collapsed), `13 pt` harness mark, session title (double-click or `⋯ → Rename` opens Rename sheet), and `22 pt` **State Pill** immediately after the title (`D-74`).
  - Right: model segment (on terminal/record routes), tinted **Project + Branch chip** (clicking opens Project page), Inspector toggle (`⌥⌘B`), and the **`Stop` + `⋯` control group** (ended sessions show `⋯` only).
- **Session tab strip (`36 pt`, shown when `≥ 2` tabs are open):** Clicking a session opens a transient tab; double-clicking or `Pin Tab` pins it; `⌥⌘W` closes the active tab; verified Stop closes the stopped session's tab (`D-54`).

### 6.4 Command Palette (`⌘K` / `⌘F`, `V06`)
- **Empty query:** Lists `Needs you`, `Recent` sessions, and `Actions`.
- **Typed query:** Ranks matches by T3 bands (exact, prefix, word-start, substring, fuzzy with length penalty) across `Needs you`, `Sessions`, `Projects`, `Actions`, and—for queries `≥ 3` characters when `Settings → General → Search inside session transcripts` is on (default on)—**`"In session text"`**, which scans the user's and assistant's text in up to 400 Claude transcripts from the last 14 days (capped at `512 MiB` / `2 s`, with `"Search older sessions"` expanding to 30 days / `4 GiB` / `8 s`).
- When the typed text reads as a question and Remora is on, **`Ask Remora`** heads the list (`§10.5`).

### 6.5 Draft Session Page (`N1`, `V07`, [D-59](DECISIONS.md), [D-76](DECISIONS.md))
- **Zero-process draft:** Opening `⌘N` or `"New session"` spawns no process and runs no git check. It displays `"What should we work on in [project ▾]?"` with the session's composer (`680 pt`), a **branch strip** (`Stay on <branch>`, `New branch`, `New worktree` in `<repo>/.claude/worktrees/<slug>`), project **Presets** (`Save current choices…`), and Remora's **`Draft Brief`** row (`§10.5`).
- **Harness & mode selection:** On the draft page, both Claude and Codex model groups are shown in the model popover, and picking a model sets the session's harness (`D-75`, `D-76`; Codex models are disabled in 1.6.0). Starting mode follows: (1) draft pick, (2) fixed mode in `Settings → General → Mode of new sessions`, (3) last mode used in that project (never storing `Full access`), (4) `Ask before edits` (`default`).
- **First send (`↵` starts & selects; `⌘↵` starts in background and opens a fresh draft):** Validates the profile and `128 KiB` first-message cap *before* running `GitWorkspace.begin` (30 s bounded git child; rolls back via `GitWorkspace.undo` with `core.hooksPath=/dev/null` if session start fails before `Ready`). Non-empty unsent drafts persist per project in the sidebar with `Discard`.

### 6.6 Home (`V05`) & Project Page (`V08`)
- **Home (`⌃⌘H`):** Starts nothing by itself (except Remora's 1/day automatic morning brief when enabled and due, `§10`). Shows the top status band (or Remora's brief), then two columns (`≥ 820 pt`): left holds **`Continue`** (sessions cut short by a quit/crash, shown first), **`Needs you`** (always shown; empty state explains what appears here), and **`Finished, not read`**; right holds **`Plan limits`** (`5-hour` and `7-day` pace meters with ahead/behind pace ticks) and **`Today`** (tokens, sessions, messages, models).
- **Project Page:** Opens on clicking a project header or header project chip. Starts nothing by itself; reads catalog, usage index, git refs, and `<project>/CLAUDE.md` (first `32 KB` + `Open in Editor`) once on open and releases on close. Has three view tabs: **`Sessions`** (flat rows with last transcript/reason line, branch, age + side column with **`Presets`** and **`Past 7 days`**), **`Branches`** (local branches + `.claude/worktrees` with `New session`), and **`Instructions`**.

---

## 7. Native Chat Face (`LoomChat`)

### 7.1 Stream-JSON Protocol, Turn Model & Cold Open (`V12`, `V15`, `V16`)
- **Wire framing (`StreamJSONDecoder`):** Reads NDJSON over `SPAWN_STDIO` pipes in arbitrary chunk sizes with a `64 MiB` line limit (oversized or unknown records become visible raw/marker frames, never fatal crashes).
- **Chronological entries & turns (`TurnModel`):** User messages, assistant prose, thinking blocks, in-place tool calls (`tool_use` + `tool_result`), subagent cards (`--forward-subagent-text`), plan cards, settled request lines, and hairline markers. Every row has a stable ID (`message uuid + block index` or `tool_use_id`) so streaming deltas update only the active row. A turn runs from a user prompt to the main thread's `result` (subagent completion never ends the parent turn).
- **Cold open & paging (`TranscriptLens`):** Opens the newest **10 user turns** (capped at ~`1.5 MiB` from the tail, always cut at a human prompt or first record of an API message, never splitting a tool call from its result). Scrolling within 1 viewport of the top loads the next **20 user turns** while holding the scroll anchor. Tool outputs keep head+tail (`64 KiB`); `"Show All"` reads up to `1 MiB` / `10,000` lines from the transcript file.

### 7.2 Stream Presentation, Folding, Live Row & Scroll Latch (`V13`, `C7`)
- **User messages:** Right-aligned bubbles; collapse when `> 600` chars or `> 8` lines to `~7` lines (`"Show full message"`). Hover footer offers time, `Copy`, and (on delivered prompts at the prompt) `Rewind Files to Before This Message`.
- **Assistant prose & C7 streaming split:** Rendered on canvas at `50 ms` frame coalescing. While streaming, `ChatContent.streamingBlocks` splits prose into an `Equatable` settled head (`ChatSettledBlocksView`) and an open tail so `ChatRowMeasurer` measures only the open tail block.
- **Work rows & group summaries:** Consecutive tools fold into a summary naming the top two categories by rank (`Rank 0:` commands, edits, agents; `Rank 1:` reads, searches, web; `Rank 2:` other; e.g. `"Changed 3 files, ran 2 commands and 4 other actions"`). `TodoWrite` is hidden from the stream and updates the `Tasks` line.
- **Success is quiet; failure is loud:** Only `is_error`, denied (`non_execution_kind`), or interrupted tools fail (`grep`/`diff` exit code 1 is not an error). Failed commands auto-expand their last 12 lines with a failure-edged box.
- **Turn fold:** When a turn settles cleanly (not live, no waiting card, not failed or interrupted), all intermediate work between the user prompt and the final answer folds into one row (`"Worked for 4m 12s · changed 5 files and ran 3 commands"`). Plan cards stay visible outside the fold. Starting a new turn closes the previous turn's manually opened fold.
- **Live row & thinking:** Fixed-ID row at the bottom of a running turn showing the current tool or `"Thinking"` / `"Compacting"` / `"Waiting for you"` + elapsed timer (persisted from send timestamp; paused when window is hidden; switches to `"No activity for 40s"` after 40 s of silence). Above it sits the 4-line italic thought summary (`--thinking-display summarized`).
- **Views (`⌃O`):** Cycles **`Normal`**, **`Thinking`** (keeps thinking blocks visible after turn), and **`Verbose`** (expands all folds and tool groups).
- **Scroll latch (`ChatScrollLatch`):** Two states—`Following` (within `40 pt` of true bottom, measured in `NSScrollView` minus composer inset) and `Free` (entered immediately on upward wheel/trackpad, scroller drag, or `Page Up`/`Home`/`↑`). Sending a message animates it to `24 pt` below the top without spacer views; `Jump to Latest` appears `150 ms` after leaving bottom and hides instantly on return.

### 7.3 Composer, Keys, Queue & Delivery (`V17`, `V24`)
- **Key bindings:**
  - `↵`: Sends message (starts turn when idle; when working, sends **`Send Now`** with `priority: "next"` so the running tool finishes without being cancelled). Never fires during IME composition (`hasMarkedText`) or key repeat.
  - `⌘↵`: Queues message in Sphyrna's **Queue** (`"After this turn"`). Text-only (refuses attachments).
  - `⇧↵` / `⌥↵`: Inserts newline.
  - `Esc`: Closes open menu or cancels queue edit first; otherwise sends **`Interrupt`** if working and no request card waits (keeps CLI process alive and pauses queue).
  - `↑` / `↓`: Recalls up to 200 earlier sent text prompts of the session when caret is on line 1 of an empty or unedited recall composer.
  - `⌘⇧V`: Pastes as plain inline text (bypassing the `≥ 32 KiB` pasted-text chip).
  - **Type-to-focus:** Typing a printable key while the stream has focus moves focus into the composer through the input method (supporting Option-typed characters).
- **Read Now:** While a `priority: "next"` message waits on a long tool step, clicking `Read Now` cancels the async message (`cancel_async_message`) and resends with `priority: "now"` (moving a running Bash command to the background).
- **Sphyrna-owned Queue (`<data root>/chat-queues/<id>.json`, max 100 items / 1 MiB):** Collapsible drawer above the composer (`Edit`, `Send Now`, `Remove`, drag or `⌥↑`/`⌥↓` reorder). Releases one item at a time when a turn settles with no waiting card. Pauses automatically on user Interrupt, failed turn, app relaunch, or Chat → Terminal handover.
- **Crash-safe drafts & delivery (`ChatDraftStore`, `command_lifecycle`):** Drafts save 300 ms after edits, on blur, on send, and on Quit. Messages sent during a running turn stay in `held` until Claude reads them (`isReplay` / `started`), returning to the composer on interrupt/crash/stop, or showing `"Not delivered · Retry · Copy"` if the process exits before `queued`.
- **`/` and `@` menus & Attachments:**
  - `/` at message start lists user-invocable skills/commands from `system/init` plus `Ask on the side` (terminal-only commands point to Settings).
  - `@` lists up to 80 files/folders (120 ms debounce; **never** walks `$HOME`, `/`, an ancestor of home, or a volume root; caps scan at 2,000 entries/folder, 20,000 total, depth 8, 0.5 s) and other sessions.
  - Images scale to `≤ 2000 px` long side; files `> 40 MB` are refused; pastes `≥ 32 KiB` become a chip.

### 7.4 Composer Bar, Permission Modes, Model Popover & Context Ring ([D-58](DECISIONS.md), [D-62](DECISIONS.md), [D-63](DECISIONS.md), [D-75](DECISIONS.md))
- **Permission modes (live via `set_permission_mode`):**
  1. **`Ask`** (teal `bubble.left`, **Chat face only**): `dontAsk` + live `permissions` (allowing `WebFetch`/`WebSearch`, denying `Write`/`Edit`/`NotebookEdit` and non-read user allow rules) + `loom:Ask` output style (`--plugin-dir`). Refused while a tool approval waits. On any terminal spawn, `Ask` automatically falls back to `Ask before edits` with a notice.
  2. **`Ask before edits`** (`default`, accent `shield`).
  3. **`Accept edits`** (`acceptEdits`, green `pencil.line`).
  4. **`Auto`** (`auto`, yellow `bolt`).
  5. **`Full access`** (`bypassPermissions`, orange `exclamationmark.circle`; selectable live because Chat spawns pass `--allow-dangerously-skip-permissions`, `D-62`, but never auto-selected by Sphyrna).
- **Unified Model + Effort chip & 332 pt popover (`D-75`):** Groups models by harness (session's harness active, other harness dimmed `"in a new session"`), with an effort slider (`low`, `medium`, `high`, `xhigh`, `max` per `supportedEffortLevels`) and `Reset` at the bottom. Changes apply live via `set_model` and `apply_flag_settings`.
- **Context ring:** Computes `input + cache_creation + cache_read + output` tokens of the latest main-thread assistant message (or post-compaction count), turning red above `90 %`. Hover popover (150 ms) shows `"Context · 120k of 1M (12%)"` and `Compact Now` (sends `/compact` when idle).

---

## 8. Pinned Request Cards & Inspector Surfaces

### 8.1 Pinned Request Cards (`V18`, `V23`, [D-75](DECISIONS.md))
- **Safety invariants:**
  1. **Zero self-answers:** `ChatSessionDriver` never answers a `can_use_tool` request on its own in any mode (except policy-enforced denials in `Ask` and `SideChat`).
  2. **`1.5 s` typing guard:** A request arriving within `1.5 s` of user keystrokes in the composer stays collapsed as `"1 request waiting"` until typing pauses for `1.5 s`, focus leaves, or the message is sent—preventing a prompt meant for Claude from accidentally submitting as a denial note.
  3. **Keyboard safety:** **`↵` never approves and `Esc` never denies.** `Tab`/`Shift+Tab` moves focus to the card (starting with no button ring so an immediate `Space` presses nothing), `←`/`→` moves between buttons, and `Space` activates the focused button. While a card is open, `↵` and `⌘↵` in the composer are disabled unless the user typed text that acts as the card's note (`Deny with note`, `Answer`, or `Keep planning`).
  4. **Subagent attribution (`V23`):** Requests carrying `agent_id` display the subagent's type and description (joined from `system/task_started` or the `PermissionRequest` hook) and highlight that subagent in the sidebar tree and Inspector `Agents` tab (`"Show the request"`).
  5. **Cut-off card:** If Claude stops while a card waits, the card remains pinned with `"Claude stopped before you answered"` and `Resume`. Answered cards fold to a 1-line summary for `4 s` and leave a permanent 1-line audit record in the stream (`"Allowed once: …"`, `"Denied: …"`).
- **Three card kinds:**
  - **Tool Approvals:** Shows tool kind, 5-line scrolling mono command/diff, `description`, and `decision_reason`. Buttons: **`Allow Once`**, **`Allow for This Session`** (rewrites suggestions to `destination: "session"`, never touching settings files; omitted for commands with file redirections `>` or here-docs), **`Deny`** (uses composer text as note if non-empty), and **`⋯ → Deny and Stop`** (`interrupt: true`, pausing the queue).
  - **User Questions (`AskUserQuestion`):** Renders markdown question and options (`1–9` digit shortcuts when focused; single-select advances after `200 ms`; multi-select toggles with `Submit`; typing in composer selects `"Other"`). Cannot be dismissed without answering or stopping the turn.
  - **Plan Review (`ExitPlanMode`):** Renders plan document card in stream and a pinned decision card offering **`Approve`** with a build-mode picker (`Ask before edits` preselected, `Accept edits`, `Auto`—or `"Stays in Ask"` when in Ask mode—passed via `updatedPermissions` `setMode` so the turn continues without restarting) and **`Keep Planning`** (`deny` with composer feedback).

### 8.2 Inspector: `Overview` & `Changes` Tabs (`I2c`, `V20`, [D-78](DECISIONS.md))
- **Inspector container (`⌥⌘B`):** `328 pt` wide on `Overview` and `Agents` list, `392 pt` on `Side`, `556 pt` on `Changes` and `Agents` transcript. Docks as a column while main content keeps `≥ 480 pt`, otherwise overlays on `Popover` surface; width transitions are **instant (`0 ms`)** so terminal PTYs resize at most once.
- **`Overview` tab (`I2c`):** Five sections—`Session` (harness, model, effort, mode, CLI version, ID), `Context` (`30 pt` ring, token breakdown, session total), `Worktree` (project, branch, path, base branch), `Changes · last turn` (`+A −R` summary + up to 5 files linking to `Changes`), and `Agents · N running` (linking to `Agents`).
- **`Changes` tab (`V20`, `556 pt`):** Read-only review across three scopes:
  1. **`Last turn`** and **`Whole session`:** Derived without git by scanning the main transcript backward (up to `64 MiB`) for `structuredPatch` records of `Write`, `Edit`, `MultiEdit`, and `NotebookEdit`.
  2. **`Branch`:** Runs bounded git (`-c core.fsmonitor=false --no-optional-locks`, `10 s` list / `15 s` diff timeout, `1 MiB` / `2,000` line cap) against the merge-base with `origin/HEAD` / `main` / `master`.
  - Shows a file list with status letters (`M`, `A`, `D`, `R` with `old → new`), unified diff cards with tertiary old/new line numbers and wrapping lines, and **`+` gutter inline comments** stored per session and scope. The footer's **`Send to Claude`** bundles all comments (`path:line`, quoted diff line, comment) into one message sent as `next` (or resuming a stopped Chat session).

### 8.3 Rewind Files (`V21`, [D-72 (2)](DECISIONS.md), [D-78](DECISIONS.md))
- Available from a delivered user message's hover footer (`"Rewind Files to Before This Message"`) when the Chat session is at the prompt (`ready`, no turn/request/handover). Requires `CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true` from the session's first turn.
- Opens a `480 pt` sheet showing the CLI dry-run file list and flagging any file modified `> 2 s` after Claude's last edit (`"Changed since Claude's last edit"`).
- Before executing `rewind_files`, `ChatRewindStore` creates **APFS clone safety copies** (`≤ 64 MiB`/file, `≤ 256 MiB`/rewind, verified by streaming SHA-256; refuses rewind if copies cannot be made).
- Inserts a stream marker `"Files rewound to before “…” · HH:MM"` with **`Undo`**. Safety copies exist on disk **only while Undo is open** (`D-72`: deleted on next send, newer rewind, Undo completion, session deletion, or app launch). Undo restores files atomically and moves post-rewind new files to the macOS Trash (never plain `unlink`).

### 8.4 Inspector: `Agents` Tab (`V09`, `V23`, [D-78](DECISIONS.md))
- Lists running and finished subagents in a card (`12.5 pt` spinner or `7 pt` waiting dot, type, description, elapsed time). Clicking a subagent widens the inspector to `556 pt` and opens its live or historical subagent transcript in two voices (prose in SF Pro, tool calls and `⎿` results in SF Mono, ending in `"Result"` or `"Waiting for you"` with `"Show the request"`).

### 8.5 Quick Question (`⌘;`, `V22a`)
- Available on a running Chat-face session (`⌘;` or Command Palette `"Ask a quick question"`). Opens a floating popover card above the composer and sends Claude's `side_question` control request over the parent's cached context (`120 s` timeout, no tools, zero writes to transcript, history, queue, or usage index). `↵` asks, `Esc` closes and discards.

### 8.6 Inspector: `Side` Tab (`V22b`, `V22c`, [D-72 (1)](DECISIONS.md))
- Opens at `392 pt` on any Claude session that has a provider conversation ID (in either face; never on Codex or nested on a side chat).
- **Cache-preserving fork:** First question spawns `claude --resume <parent> --fork-session --session-id <new> --permission-mode default` with the parent's model, effort, and thinking, plus `--settings` injecting `permissions.ask` for `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, and `Bash` (preserving a ~99.99 % prompt cache hit).
- **Read-only by default:** `SideChatPolicy` auto-allows only provably read-only Bash commands (`ReadOnlyCommand`) and refuses edits and non-read commands unless the user toggles **`"Allow edits"`** on for that side chat (`"Allow edits"` resets to **off** on every start/resume).
- **Single-process retirement (`D-72`):** At most one side-chat process runs per parent session—only while it is the open side chat in the `Side` tab. Switching to an earlier side chat or clicking `+` (`New side chat`) stops the previous one immediately if idle, or when its turn/request settles. When the parent session's run ends (except during handover), all of its side chats are retired. Closing the inspector or selecting another main session keeps the open side chat alive.
- **Hidden catalog records:** Side chats are stored in `sessions` with `parent_session_id`, `forked_at`, and `side_first_uuid`, hidden from all sidebar lists, Home, search, Dock badges, and notifications (waiting requests show only as a `7 pt` attention dot on the `Side` tab), tagged with bit 16 in `ClaudeUsageIndex` so parent messages are never double-counted, and deleted automatically when the parent is deleted. **`"Send to Main as a Note"`** quotes the question and answer into the parent Chat session.

---

## 9. Cross-Session Coordination & Sphyrna Plugin ([D-40](DECISIONS.md), [D-42](DECISIONS.md), [D-83 (b)](DECISIONS.md), [D-85](DECISIONS.md))

- **Plugin delivery (`ClaudeLoomPlugin`):** Written to `<data root>/claude-plugin` and passed via `--plugin-dir` to every Claude session started with the control socket (`LOOM_CONTROL_SOCKET`, `LOOM_CLI`). Contains one skill (`loom:open-session`, description ≤ 300 characters opening with `"This session runs inside Sphyrna, the desktop app that hosts it."`, `D-85`) and the `loom:Ask` output style.
- **Verb 1 — Read-only session directory (`"$LOOM_CLI" sessions`, `C5a`):**
  - Returns up to **100 sessions** (max `60,000` bytes) from `SessionDirectory`: `id`, `harness`, `title`, `project`, `state` (`SessionStateWord`, pinned to match `SessionIndicator`), `face`, and `lastActivity`.
  - Exposes **zero** transcript content, file paths, or prompts, and requires **no user approval**.
- **Verb 2 — Approval-gated session opening (`"$LOOM_CLI" open`, `D-40`, `C5b`):**
  - Lets an agent request opening a new Claude session in a project with a title and first message.
  - Sphyrna displays an approval callout/card showing the requesting session, target project, title, and message preview (`Return` never approves).
  - Only after the user clicks **`Approve and Start`** does Sphyrna start the session in the face named by `Settings → General → Sessions run in` (`C5b`), passing the request's title (skipping `generate_session_title`) and first message, and recording `opened_by` (`"from <session>"`).

---

## 10. Remora (Home Assistant, `LoomRemora`)

### 10.1 Role & Hard Boundaries ([D-64](DECISIONS.md), [D-77](DECISIONS.md), [D-80](DECISIONS.md))
- **Strictly read-only:** Remora reads session transcripts and catalog metadata to brief the user on `"Where you left off"`, answer questions across sessions in the question's language, cite sessions as clickable chips, and draft unsent next steps (`Put in Draft` / `Draft Brief`).
- **Never acts:** Remora **never** sends a message to a session, starts or stops a session, runs a tool or shell command, reads git directly, or answers an approval/question/plan request. `Put in Draft` places unsent text into an empty Chat composer—or copies it to the clipboard if the composer already has text or the session runs in the terminal.
- **Seven excluded places (`DESIGN §20 Left out`):** Remora never appears on (1) the Project page, (2) inside a live session (Quick Question `⌘;` and Side Chat already have the full session context), (3) on a request card, (4) in the Changes tab, (5) on failure banners, (6) in system notifications or the menu bar, or (7) in session cleanup.

### 10.2 Call Isolation, Schedule & Guardrails (`L1a`–`L3a2`)
- **Process isolation (`RemoraCall`):** One `claude -p` child per brief or question via `ProcessSupervisor.streamHelper`, in an empty working directory (`<data root>/remora/run`), with `--output-format stream-json --verbose --include-partial-messages --model <model> --effort <effort> --settings {"disableAllHooks":true} --strict-mcp-config --no-session-persistence --tools "" --setting-sources ""`, `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`, and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.
- **Defaults & deadlines:** Defaults to **Sonnet 5.5** (`sonnet`) at **low** effort (`D-64`). Hard deadlines: **`60 s`** for a question or a draft (Draft Brief's call is question-kind), **`120 s`** for a brief (`SIGTERM` then `SIGKILL`). At most one call in flight at a time (`RemoraHost`), whichever door started it.
- **Morning brief schedule (`RemoraSchedule`):**
  - Day boundary is **`04:00` local time**.
  - In `Automatic` mode (default), runs at most **once per day**, triggered only when Home is actually shown on screen, online, and at least one non-excluded session has moved since the last brief (`L3b Home`: `HomeRemoraCalls.homeShown` + `NetworkReach`).
  - **Plan-limit guard:** Pauses the automatic brief while the 5-hour plan window has less than **`10 %`** remaining (configurable stepper in `Settings → Remora`; questions still run with a warning line, and `Catch Me Up Anyway` is offered).
  - **Slot retention:** Once a brief call reaches the model, it consumes that day's automatic slot even if stopped or errored (unless Claude was not logged in or the process could not spawn), and the result is persisted in `<data root>/remora/day-brief.json` (`0600`) until the next `04:00` boundary.

### 10.3 Two-Part Memory & Deletion Forgetting (`L2`, `L3a2`)
1. **Working memory (`<data root>/remora/`, `0700` dirs / `0600` files):**
   - **Journal (`journal/YYYY-MM-DD.md` & `journal/YYYY-Www.md`):** Mechanical 1-line records of questions and briefs kept by day for **14 days**, then folded into ISO weekly summaries for **12 weeks**. Any line can be deleted (`×`) in the Memory sheet.
   - **Project notes (`projects/<project id>.md`):** Up to **`2 KiB`** of dated bullet items per project, rewritten on morning briefs. Users can `Edit` in place or `Remove` (each removal with its own Undo, `L3a3`) in the Memory sheet. Excluding a project in `Settings → Remora` deletes its note and excludes its sessions from all packs.
2. **Durable note (`Remora.md`, default `<data root>/remora/Remora.md` or user-chosen path in Obsidian vault, `≤ 8,000` bytes):**
   - Remora writes **only** under its `## Remembered` heading—either when the user clicks **`Save`** on a brief's `"Remember this?"` proposal, or **immediately with zero model call** when a question starts with `"Remember …"` / `"Hatırla …"` (without `?`), always offering `Undo`.
   - In the Memory sheet (`560 pt`), `Open in Obsidian` is shown only when `Remora.md` sits inside a folder with `.obsidian`; otherwise `Open` opens the default editor (`28635fb`).
3. **Session deletion forgetting (`RemoraMemoryForgetter`):** Deleting a session strips all lines/items citing it from day/week journals, project notes, and `day-brief.json`, and records the deleted ID in an in-flight fence so a concurrent Remora call can never write it back (`L3a2`).

### 10.4 Pack Layout, Token Budgets & Mixed Prompt Cache TTL ([D-84](DECISIONS.md), [D-85](DECISIONS.md), [D-86](DECISIONS.md))
- **Token caps & secret masking:** Question pack **`≤ 14,000` tokens**; brief pack **`≤ 30,000` tokens** (`RemoraMemoryShare` capped at `3,000` tokens: `≤ 8 KiB` stable + `≤ 6 KiB` recent journal; reads up to 8 sessions, 6 backward pages of `128 KiB`, ~`6 KiB` excerpt per session off `@MainActor`). Secrets (`sk-ant-*`, bearer tokens, API keys) and XML tags are masked/defused before packing.
- **Mixed cache TTL layout (`D-85`, `D-86`):**
  - **System prompt file (`--system-prompt-file`, `CLAUDE_CODE_PROMPT_CACHE_TTL=1h`):** Holds `RemoraRules` + `stablePrefix` (`<memory>` durable note & project notes + `<self>` + `<sessions>` directory sorted by session ID without volatile timestamps or state words).
  - **Stdin user message (`CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL=5m`):** Holds dynamic per-call blocks (`<excerpt>`s by last activity, today's `<journal>`, `<previous>` exchange, `<activity>` state/timestamps, `<now>`, and `<question>` / `<request>` with optional 1-line language directive from `Settings → Remora → Brief language` or `NLLanguageRecognizer`).

### 10.5 Home UI & Two External Doors (`L3b`, `L3c`, [D-80](DECISIONS.md))
- **On Home:** Shows `"Where you left off"`, up to 3 ranked project tiles (`Put in Draft`, `Open`), further/quiet project lines, `"Remember this?"` bar, the `Ask Remora` field (`All projects` or single-project scope), 1 streamed answer with session chips + 1 folded `Earlier` line, and the `Sources` footer. Once an entry is opened, the brief folds into a single line with a `72 pt` resting remora.
- **Door 1 — `⌘K` Command Palette:** When the query reads as a question, `Ask Remora` appears at the top (`All projects` default; `⇥` narrows to current project or current ended/terminal session; `↵` streams the answer inside the palette; `⌘↵` opens it on Home). "Reads as a question" is a fixed rule with no model call (`PaletteRemoraQuestion`): the text ends in `?`, `？` or `؟` or a Chinese, Japanese or Korean question ending, holds a CJK question word, has a Turkish question particle after its first word, or has three words or more and starts with an interrogative in English, German, French, Spanish, Italian, Portuguese, Dutch or Turkish; a plain search term ("login flow") stays a search. Nothing is called while typing; an excluded project is never offered as a scope; Esc, or any close of the palette, stops the call it started; `⌘↵`, once the answer has ended, hands the question to Home's field as its `Earlier` line. Busy with another call, the row says so and `↵` does nothing.
- **Door 2 — Draft Session Page:** Under the preset chips, `Draft Brief` makes one call on click and writes an unsent brief (goal, current state, next step, key files, watch-outs) into the draft composer. The call (`draftRemoraBrief`, `L3c`) reads the project the way a question about it does, with the same cached stable prefix; it runs only with Remora on, for a project that has a session and is not excluded, and while no other Remora call runs. Usage counts it as a draft and the journal marks its line `for=draft`. The row shows the call's states (reading with Stop; drafted, with the call's time and Draft Again; copied, when the composer had text; failed; stopped; busy while another call runs), and a line above the composer says where the text came from, with Sources and Clear. Nothing is ever sent (`D-64`).

---

## 11. macOS System Integration ([D-45](DECISIONS.md), [D-49](DECISIONS.md), [D-52](DECISIONS.md), [D-79](DECISIONS.md))

- **Dock badge:** Counts the exact set of sessions that need the user (`AttentionOrder`: failed unread, waiting for approval/input/open-request, and finished unread)—matching the sidebar `Home` badge and the menu bar's count.
- **Menu bar item (`Settings → General → Show in menu bar`, default on):** Displays the `20 pt` `Front` hammerhead mark (`D-77`) with a lower-right badge slot where the strongest status dot (failure > attention > unviewed) wins over the working braille spinner. Clicking opens a menu with **`Needs you`** (up to 5 rows, failures first, then `"and N more…"`), **`Working`** (up to 5 rows with static first spinner frame), `New Claude Session`, `Open Sphyrna`, `Settings…`, and `Quit Sphyrna`. When nothing is working or waiting, shows disabled `"Nothing is working or waiting."`
- **Approval notifications (`Settings → General → Notify when a session needs approval`, default on):** Fires a silent macOS notification (no sound, no action buttons; title = session title, body = project + reason) **only** when a session transitions into waiting for an approval, question, or plan while Sphyrna is not the active app. Clicking brings Sphyrna forward on that session; the notification is removed immediately when the session stops waiting, at quit, and at launch.
- **Open at Login (`Settings → General → Open at login`, default off):** Managed via `SMAppService.mainApp`.

---

## 12. Resource, Performance, Subscription & Context Budgets ([D-07](DECISIONS.md), [D-83 (c)](DECISIONS.md))

### 12.1 Resource & Performance Guarantees
- **CPU40 ceiling (`D-07`, `D-19`):** At 1 MiB/s visible terminal output over 60 s, total CPU across Sphyrna app + fixture + run-scope hosts must not exceed **40 % of one logical core** (Package I baseline: app `23.8–24.0 %`, total `25.4–25.6 %`; hidden stream `3.5 %`; input-to-draw p95 `~20 ms`; reduced-motion indicator `~0.005 %`; idle observer with 1 real Claude `0.044 %`).
- **Visible Chat stream parity (`C7`, `D-70`, `D-83`):** A visible Chat stream at `600` and `6,000` chars/s must cost no more CPU than the terminal face for the same output.
- **Zero hidden/idle waste:**
  - Hidden, occluded, or unselected terminals suspend rendering (`suspendsRenderingWhenNotVisible = true`) and retain dirty signals without waking `@MainActor` (SwiftTerm Patch 11).
  - The working braille spinner and ASCII shark animations stop all timers and wakeups when the window is hidden, inactive, or off-screen.
  - Stopped/idle/stale sessions hold **zero** live `TerminalSurface` or CLI processes; unused `LiveChatFeed` instances are trimmed to an LRU of **4**.
  - Scrollback (`2,000` lines), inline terminal images (`8 MiB` / `1,024` per screen), pipe unread stdout (`16 MiB`), hook ingress (`1,024` frames), diagnostic journals (`2 × 512 KB`), and transcript reads are strictly bounded.

### 12.2 Subscription Model-Call & Agent Context Guards (`C3`, [D-83 (c)](DECISIONS.md))
- **Allowed model calls on the user's subscription:** Sphyrna makes a model call **only** when the user explicitly sends, asks, or approves (prompt, Quick Question, Side Chat question, Compact, diff comment / side note sent to main, approved session opening, or explicit Remora question / `Draft Brief` / `Catch Me Up`), plus **at most two background calls**:
  1. **Chat session title (`generate_session_title`):** At most **once per session** (max 3 tries), passing at most **`2,000` characters** of the first user message (matching the terminal CLI's own title call; skipped for approved `"$LOOM_CLI" open` sessions and side chats).
  2. **Remora's automatic morning brief:** At most **once per day** after `04:00` local time when Home is shown on screen, online, Remora is on + `Automatic`, a session moved, and ≥ 10 % of the 5-hour limit remains.
  - Nothing else ever calls a model in the background (no timers, watchers, or per-turn summaries; `get_usage` plan-limit reads do not call a model).
- **Session context additions:** A session started by Sphyrna receives zero injected system prompts, zero written instruction files, and zero hook stdout. Its context differs from a plain terminal session only by the `loom:open-session` skill description (**≤ 300 characters**) and, while in `Ask` mode, the `loom:Ask` output style.
- **Enforced by failing-first guard tests:** `PluginContractTests`, `LaunchContractTests`, `HookSilenceTests`, `ChatModelCallTests`, `RemoraCallTests`, `RemoraPackBuilderTests`, and `RemoraReachTests`.
