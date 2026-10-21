# Evidence: T3 Code app shell, new-thread flow and user voice, for Loom v2 (17 Oct 2026)

Final report of a read-only researcher (`explorer`) for [plans/V2-PLAN.md](../../V2-PLAN.md). It read the T3 Code clone (`~/Library/Caches/loom-v2-research/repos/t3code`, commit 5c8528f, MIT, Copyright 2026 T3 Tools Inc.) without running anything, plus public pages; long user quotes are paraphrased and linked. Section 0 corrects the earlier [chat UI anatomy study](chat-ui-anatomy-20261017.md). Section 10 maps how T3 drives the Codex app-server, for the Codex planning after v2.

---

# T3 Code app shell around the chat: how it works, what users say, and what Loom should take

I read the clone at commit 5c8528f read-only and ran nothing from it. All `file:line` references are relative to `apps/web/src` (web), `apps/server/src` (server), `packages/` and `docs/`. Facts come from code. Inferences are marked "(inference)". Dates for X posts are decoded from the post ID (snowflake), not read from the page.

## 0. Corrections to the earlier notes

1. **The default sidebar is flat, not grouped by project.** "Sidebar V2" is now the default, and per-project trees are an opt-in "Legacy features" switch.
   - Evidence: `legacySidebarEnabled` defaults to false at `packages/contracts/src/settings.ts:417`, and the switch is at `components/settings/SettingsPanels.tsx:2020`.
   - Projects only appear as a scope filter combobox, a small project label on each row, and the draft heading.
   - Volanea dates the nightly to 2026-07-27, citing Theo's video.
2. **The chat header is only a breadcrumb plus three toggles.**
   - Open-in-editor, Git actions and project scripts are not in the header at the clone's commit. They live in the "Thread details" popover (`components/chat/ThreadDetailsPanel.tsx`, toggled by `mod+shift+b`).
   - The marketing screenshot (`apps/marketing/src/assets/app-desktop.webp`) shows three split buttons in the header. That screenshot is older than the code. `OpenInPicker` still has a `toolbar` mode, but `ChatView.tsx` never renders it there (no `<OpenInPicker` hit).
3. **The context-window ring and plan mode are off by default.**
   - Both are "legacy": `contextWindowMeterEnabled` and `planModeEnabled` default to false (`settings.ts:~411`, `SettingsPanels.tsx:1994-2015`).
   - The ring in the earlier anatomy note is therefore not in a default install.
4. **The default permission mode for new threads is Full access.** `DEFAULT_RUNTIME_MODE = "full-access"` (`packages/contracts/src/providerPolicy.ts:32`). It is not carried from the thread you are leaving (`docs/user/permission-modes.md`). Neither earlier note says this.
5. **Unsent drafts that have content do appear in the sidebar.** `SidebarDraftBlock` (`components/Sidebar.tsx:1345-1420`) lists them with a pen icon and a discard button. An empty draft never appears.
6. **The sidebar card's "+N −M" is stubbed.** `latestRunDiff()` returns null (`Sidebar.tsx:2417-2421`), so no diff stat shows on the card yet.
7. **Notifications, in-app toasts and proactive diff opening are all off by default.** See §8 and §4.

## 1. The new-thread flow

### 1.1 Entry points

| Entry | Behaviour | Evidence |
|---|---|---|
| App start at `/` | No landing page. It auto-creates a draft in the most recently active project, using `replace` navigation. With zero projects it shows `NoProjectsHero` ("What should we work on?", Add project / Start without a project). | `routes/_chat.index.tsx:38-76`, `components/NoProjectsHero.tsx` |
| Sidebar pen icon | With one project group, or Shift-click, it starts in the current project. Otherwise it opens the palette in "New thread in…" mode (a project list). The tooltip says "New thread in current project: Shift+click". | `Sidebar.tsx:4421-4439`, `Sidebar.logic.ts:752` |
| `mod+n` and `mod+shift+o` (`chat.new`) | Project chooser if more than one project group (and not the legacy sidebar). | `packages/shared/src/keybindings.ts:171-172`, `routes/_chat.tsx:124-139` |
| `mod+shift+n` (`chat.newLocal`) | Same project as the active thread or draft, no chooser. | `keybindings.ts:173`, `_chat.tsx:101` |
| `mod+alt+n` (`chat.newWithoutProject`) | Starts a "scratch" thread with no project. | `keybindings.ts:174`, `_chat.tsx:113` |
| Command palette | "New thread in *<project>*", "New thread in…" (submenu with a "No project" entry), "New thread without a project". | `CommandPalette.tsx:1596-1650`, `:1215-1230` |
| Breadcrumb project name | Click starts a new thread in that project. | `chat/ChatHeader.tsx` (project button, `onNewThreadInProject`) |
| Thread menu "New thread on *<branch>*" | Branch is carried. | `threadActionMenu.logic.ts:113-120` |
| Settle-and-advance with no next thread | Falls back to a draft in the same project, else `/`. | `Sidebar.tsx:3125-3135` |
| `mod+enter` in a draft | Sends, runs the thread in the background, and opens a fresh draft. | `keybindings.ts:156-165`, `ChatView.tsx:7016-7040` |
| `t3code://new?prompt=…` link | `/new` route with a `NewThreadLinkView`. | `routes/_chat.new.tsx`, `docs/user/prompt-links.md` |

The project route is not a project page. `/projects/$projectKey` just redirects to `/settings/projects` (`routes/projects.$projectKey.tsx`). Project overview and per-project defaults live in Settings.

### 1.2 What the user sees in the draft ("hero") state

Layout (`ChatView.tsx:8233-8262`):
- The composer overlay is `absolute inset-0 … flex items-center`, so the composer sits vertically centred in the pane.
- A headline sits just above it: `DraftHeroHeadline` (`components/chat/DraftHeroHeadline.tsx:315-370`).

Headline text:
- Normally "What should we build in **[Project ▾]**?". The project name is an inline combobox trigger with a search field ("Search projects…") and an "Add project" item at the bottom.
- With no resolved project it reads "**[Choose a project ▾]** to start" or "Add a project to start".
- Under the heading, a muted link says "or start without a project". With the no-project shortcut `mod+alt+n` it shows as a tooltip.
- In scratch mode the headline is "What should we work on?" and the project picker moves to the line below.

Below the composer is a context strip (`BranchToolbar.tsx:560-813`):
- Left: workspace mode as a menu with **Current checkout / New worktree / Previous worktree**, plus a "Run on" environment picker when there are several machines.
- Middle: the resting model controls, hosted into the strip.
- Right: the branch picker. It can check out a PR and carries a "start from origin" switch.

The composer footer holds the provider/model picker, an effort picker, an access-mode select (`ChatComposer.tsx:1212-1330`), attach, and send. The strip is shown only for Git projects (or when there is an environment indicator). The strip's label text collapses to icons when it is too narrow, with 16 px hysteresis (`BranchToolbar.logic.ts:78-90`).

The header above still shows the breadcrumb ("project / New thread").

**Screenshots.** The clone has no draft-state screenshot, in `docs` or in marketing. `app-desktop.webp` is an existing thread; I read it at full size:
- Left sidebar: "Search" field and a pen icon, then an "All projects ▾" scope row with an add-project icon. Cards follow, each with a small project name, pin, relative time or status, then a bold title, then a branch line with a worktree icon, a `#7723` PR badge and a provider glyph. The selected card is tinted. A collapsed "Settled (143)" shelf sits at the bottom.
- Centre: breadcrumb "t3code-3 / Keep Settled Responses Visible" and three split buttons (old header).
  - A folded "Worked for 3m 43s ›" line, then assistant markdown.
  - An inline card reading "2 changed files +29 −12 Show files | Open diff".
  - A composer with the placeholder "Ask for changes, send follow-ups, or attach images", a model pill "GPT-5.6-Sol ⌄", a "…" compact menu, attach, and a round send button.
  - A strip under the composer: "Worktree | #7723 | branch name ⌄".
- Right: a "Diff" tab with a "Turn 2 ⌄" scope menu, "+29 −12", and layout toggles.
- The other images in `apps/marketing/public/95/` are joke box art and say nothing about the product.

### 1.3 How project, branch/worktree, model and mode are chosen

**Project.**
- Projects are "logical projects". By default all checkouts of the same repository are merged, even across machines (`sidebarProjectGroupingMode` default `"repository"`, `settings.ts:71`).
- The landing project is the one with the newest thread activity, falling back to `updatedAt` (`Sidebar.logic.ts:1204-1219`, `:1323-1353`).
- If you create a thread from a thread or draft, it stays in that project. With no thread or draft it uses the first project in your saved order (`useHandleNewThread.ts:386-423`).

**Draft reuse.**
- There is one draft per logical project (`getDraftSessionByLogicalProjectKey`, `useHandleNewThread.ts:170`).
- An empty stored draft is reused. The current empty draft is reused if it matches the project (`:174-194`, `:296-322`).
- Only if neither applies is a new `draftId`/`threadId` pair allocated locally (`:324-383`). This stops empty drafts piling up.
- The draft carries a pre-allocated server thread ID, held in a persisted zustand store (`composerDraftStore.ts`).

**Workspace mode** (`resolveNewThreadEnvMode`, `packages/shared/src/projectSettings.ts:181-206`):
- Resolution order: project override, then the environment default, then the repo's `t3.json`, then built-in `local`.
- A brand-new project folder directly under `newProjectsRoot` with no threads yet is forced to `local`.
- `startFromOrigin` is true by default (`settings.ts:1147`) and applies only in worktree mode (`chatThreadActions.ts:39-44`).
- A worktree send is blocked unless a base branch is chosen: "Select a base branch before sending in New worktree mode." (`ChatView.tsx:6389-6393`).
- "Previous worktree" reuses the last worktree of the project (`mod+shift+l`, `BranchToolbar.tsx:600-625`).
- The server first creates a temporary branch, then renames it with a generated name (`ThreadLaunchService.ts:329-345`, `:489-505`). The default static prefix is `t3/` (`docs/user/project-settings.md`, "Worktree branch names").

**Model and effort** (`useHandleNewThread.ts:119-140`, `:371-375`; `chatThreadActions.ts:46-56`):
- Precedence: an explicit pick already made in the draft, then the project's `defaultModelSelection`, then the selection carried from the thread you are leaving, then "sticky" state.
- Sticky state is remembered per provider instance: the last model, the options per model, and the active provider (`composerDraftStore.ts:2827-2859`).

**Mode.**
- Permissions come from `defaultRuntimeMode` (project, then environment, then built-in `full-access`). They are not carried from the current thread.
- Interaction mode (plan or default) is carried (`useHandleNewThread.ts:114-118`). Plan is off anyway (§0).
- The user-facing modes are Supervised, Auto-accept edits, Auto and Full access.

**Where the defaults live.** `components/settings/ProjectDefaultsSettings.tsx` holds the model and workspace defaults. Each can be overridden per project, with a "layers" icon showing where a value comes from.

**Known gap.** Issue #6508 (open) asks for per-project last-used model, options and mode. Today the result depends on which entry point you used.

### 1.4 When the thread is created

On the first send, not before.
- `startThreadTurn` is called with `bootstrap: { createThread, prepareWorktree, runSetupScript }` (`ChatView.tsx:6985-7040`). The thread is created atomically with the first turn.
- The title seed is the truncated first message (or a label like "File: x" or "Review: …"), and the server regenerates it afterwards (`ChatView.tsx:6920-6930`, `Orchestrator.ts:4652-4661`).
- `isFirstMessage` is computed at `ChatView.tsx:6383`.
- If the bootstrap fails, the provisional thread is deleted. Issue #4647 (closed) shows this left a stale draft ID once.

### 1.5 How the composer moves after the first send

- `resolveDraftHeroState` is true only for a local draft with no timeline entries, nothing working, and no dock request (`ChatView.logic.ts:287-307`). Having a worktree-setup card forces it false.
- A foreground send calls `shouldDockDraftHeroForSubmission` (`ChatView.logic.ts:226-236`). It then does `flushSync` to capture the composer rect and set `dockedDraftHeroThreadKey` (`ChatView.tsx:6556-6580`).
- `useDraftHeroLayoutTransition` plays a FLIP translate from the centred position to the bottom (`ChatView.tsx:572-632`).
- The motion duration is `panelAnimationDurationMs`, which defaults to 0 (see "Panel motion defaults to zero", `settings.ts:~303`). Out of the box the composer snaps down.
- The same `ChatView` stays mounted when `/draft/$draftId` becomes `/$environmentId/$threadId`. The comment in `routes/_chat.draft.$draftId.tsx` says this on purpose.

### 1.6 What is hidden once the thread starts

- The headline, and the Git context strip (workspace, branch). The strip stays only if you turn on "Composer context" (`persistComposerContextStrip`, default false, `settings.ts:412`; `docs/user/appearance.md` "Composer context").
- Workspace mode is locked for a server thread (`envModeLocked`, `BranchToolbar.tsx:~590`).
- On a thread route, a model strip appears only when the composer is "resting". With `composerCollapseOnScroll` (default true), the composer collapses its controls while you scroll the timeline (`ChatComposer.tsx:4902-4912`).
- Branch and workspace edits move into the thread-details popover.

### 1.7 Loom adaptation (new-thread flow)

Loom's modal sheet has six fields. T3 answers it with no modal, defaults for everything, and one send action.

**What to copy (M overall):**
- Draft-first: ⌘N shows a centred composer with a "What should we build in [Project ▾]?" headline.
- One reusable empty draft per project (S).
- Defaults chain (M): an explicit choice in the draft, then the project default, then the carried value, then last-used per project. Apply last-used per project to model, effort, mode and face. This fixes T3's #6508 gap.
- Landing on the most recently active project. (S)
- Branch/worktree stays as a chip under the composer. It is hidden after the first send and moved to the inspector Overview. (S)
- `⌘Enter` to "start and open another draft". (S)

**What changes for Loom:**
- A Loom session is a real CLI process, so a draft is only local UI state. The session is created on first send, by launching the CLI with the first message as its argument.
- The ticket field should become an optional chip or `#KEY` token in the composer, not a form field.
- "Save as preset" disappears. Per-project last-used plus project defaults replace it (inference).

### 1.8 Design options for Loom's new-session flow

**Option A: draft-first (T3, Codex app).**
- Opens a centred composer with a heading and a project combobox. A chip strip under the composer holds face (Chat or Terminal), mode, model/effort, and branch or worktree. Enter starts the session.
- Trade-offs:
  - Fastest and calm, and one surface instead of a modal.
  - Needs per-project draft persistence and a visible mode chip, since T3's Full-access default surprises people. Loom should choose its own default and always show the chip.
  - Ticket and branch become tokens or chips, which is more to learn than a labelled field.
- Codex's desktop app uses the same pattern, with Local/Worktree, branch, model, effort and permission controls under the composer (`products/codex-app.md` L31, L51).

**Option B: one-field quick palette (Raycast-style, ⌥⌘N from anywhere).**
- A small floating palette with a single field. You type the first message. The project is chosen by Tab or a recents list. Enter starts with last-used settings, and ⌥Enter expands one row of options.
- Trade-offs:
  - Fastest from any app, and consistent with Loom's palette work.
  - Weak discoverability of branch, mode and face. Not a good place to review risky defaults. It is a floating panel again (the user disliked the sheet, so it must stay very small).
  - Best as an add-on to A, not a replacement.

**Option C: empty session row first (Claude Desktop ⌘N, Conductor).**
- ⌘N or "+ New session" creates an idle session row in the sidebar immediately. The chat shows with the composer. Environment, folder, model and permission mode live in the prompt area.
- Claude Desktop documents exactly four controls there: Environment, Project folder, Model and Permission mode, with Enter to start, and a worktree option next to the branch name (`code.claude.com/docs/en/desktop`, "Start a session" and "Work in parallel with sessions").
- Trade-offs:
  - No draft or promotion machinery, and an empty session is trivially resumable.
  - The list fills with empty sessions unless they auto-discard.
  - In Loom, "session with no process" is a new state to explain. It is less calm than A.

Recommendation: A, with B's entry point (⌥⌘N opens A in a floating window) as a later add-on. This is my recommendation, not a measured result.

## 2. Sidebar and thread list

**What the user sees** (`Sidebar.tsx`, `Sidebar.logic.ts`):
- Header: a "Search" field, a project scope combobox, an add-project icon, and the new-thread icon (`components/sidebar/SidebarThreadHeader.tsx:64-137`).
- Body sections, top to bottom: unsent draft rows, then **Pinned**, then **Active** (or Active plus a collapsed **Working** group when the beta fold is on), then a **Snoozed** shelf, then a **Settled** shelf.
  - Settled shows 10 rows first, then pages of 25 (`Sidebar.tsx:292-293`).
  - Active and Pinned threads are "cards". Snoozed and Settled are slim rows (`Sidebar.tsx:4704-4706`).

**Card contents** (`Sidebar.tsx:2200-2415`):
- Row 1: project name, pin, then a status slot that shows the status label with elapsed time or the relative time. On hover it swaps to Discard-draft, Snooze and "✓ Settle" buttons.
- Row 2: title.
- Row 3: branch with a worktree indicator (or a scratch machine label), a running-terminal icon, a PR badge, a remote-machine icon, and a provider stack.
- A hover card appears to the right after 150 ms (`SidebarThreadTooltip`, `ThreadHoverCard`).

**Ordering.**
- Active: manual order, with new threads on top, and activity never reorders. The order is saved on the server. You can also drag between sections.
- Projects are sorted by newest activity (`getProjectSortTimestamp`, `Sidebar.logic.ts:1204`).
- Settled is sorted by settle time.
- With the Working fold on, active threads are sorted by "when it last came back to you", and drag-reorder is off (`docs/user/thread-sidebar.md`, "Fold working threads").
- A user asked for attention-first ordering in #4695 (closed).

**Status** (`resolveSidebarThreadStatus`, `Sidebar.logic.ts:904-930`; labels at `Sidebar.tsx:1600-1650`):

| Status | Meaning | Look |
|---|---|---|
| Approval | pending approval, including a subagent's | amber, shield icon |
| Input | pending question | indigo |
| Working | preparing, queued, starting, running or waiting; shows elapsed time, or "Goal" when `/goal` is active | blue dashed circle |
| Waiting | provider idle | grey dotted circle |
| Failed | | red |
| Limited | usage-limit failure | amber |
| Done | finished and unread | green check |
| Woke | a snoozed thread came back | alarm icon |
| none | ready and read | |

- Unread is computed as `latestRun.completedAt > lastVisitedAt` (`hasUnseenCompletion`, `Sidebar.logic.ts:710-719`). The server is authoritative for `lastVisitedAt`, which allows an explicit "Mark unread". Visits are dispatched at most every 10 s (`ChatView.tsx:568-570`).
- Rows "recede" (dimmer, normal weight) when working, waiting, or ready and read. Input never recedes (`shouldRecedeSidebarThread`, `Sidebar.logic.ts:884-900`).
- A project's indicator rolls up the highest-priority child status (`resolveProjectStatusIndicator`, `Sidebar.logic.ts:1160`). That is a legacy-sidebar concept.

**Row actions** (`threadActionMenu.logic.ts:102-220`):
- Menu items: New thread on branch, Pin, Settle, Snooze (presets plus Custom…), Rename, Regenerate title, Mark unread, Filter by project, Auto-settle behavior, Copy (path, branch, thread ID), Project settings, Archive, Delete.
- Rename: double-click a row or the header title; Enter commits, Escape cancels, an empty title is rejected.
- Delete asks for confirmation by default (`confirmThreadDelete` default true, `settings.ts:352`) and can ask "Delete the worktree too?" (`useThreadActions.ts:449-490`).
- Archive is off by default for confirmation (default false) and is disabled while the thread is running (`isRunning`).
- Archived threads are listed in Settings → Archive.
- Unpin, settle, snooze and archive each show a 5-second Undo toast, and `mod+z` triggers it (`docs/user/thread-sidebar.md`).
- `mod+1..9` jumps to threads (desktop only), `mod+shift+[` and `]` move between them, and a jump-hint overlay shows after 200 ms (`Sidebar.logic.ts:47`).
- Drag a file onto a row to attach it.

**Search.** The sidebar search matches the title and PR terms first, then message content from the server (`searchSidebarThreads`, `Sidebar.logic.ts:989-1020`). The docs say message search starts after two characters (`docs/user/thread-sidebar.md`, "Find and reference work").

**Loom adaptation:**
- Status vocabulary and ordering. Loom's sidebar rows already have a reason line. Add T3's eight states with priority (Approval > Input > Failed/Limited > Working > Waiting > Done), and the "recede" rule for read, idle rows. Loom gets this nearly free from hook-derived state. (M)
- Settle/Done shelf with undo, snooze and lazy auto-settle (a one-shot timer, no tick). Never auto-settle with a pending approval or live process. (M)
- Keep project grouping. T3's flat inbox is a recent, contested choice (see #3697, §11). Instead make a "Needs you" section on top, then project groups. (inference; M)
- Card meta: project, branch with a worktree glyph, PR chip, time, and a hover card. (S–M)
- Do not copy hover-only Settle: keep it keyboard-reachable.

## 3. `ChatHeader` and `OpenInPicker`

**`ChatHeader`** (`chat/ChatHeader.tsx`):
- It is a breadcrumb: `[project favicon + name] / [parent thread title /] thread title`.
- The project name is a button that starts a new thread in that project.
- Clicking the title opens the thread action menu (a native menu on desktop, delayed 500 ms so a double-click can rename; `ChatHeader.tsx:~100-135`). Double-click renames inline. Right-click on the header opens the menu or project settings.
- The parent title collapses to "…" when space is short.

**Top-right toggles** (`chat/PanelLayoutControls.tsx`): thread details (`mod+shift+b`), terminal drawer (`mod+j`), right panel (`mod+alt+b`), and a maximize toggle for the right panel.

**Thread details popover** (`chat/ThreadDetailsPanel.tsx:56-170`) has density levels (full, compact, essential) by available height. It holds:
- "Workspace": run context (environment and workspace mode), **OpenInPicker**, project scripts.
- "Version Control": branch picker and `GitActionsControl`.
- Automations and thread relationships (only for real threads).

**`OpenInPicker`** (`chat/OpenInPicker.tsx:206-457`):
- A split button. The primary half shows "Open in <last editor>", and the chevron lists installed editors.
- The list covers about 20 editors: Cursor, VS Code (and Insiders), VSCodium, Zed, Trae, Kiro, Antigravity, the JetBrains IDEs, plus Finder/file manager.
- The last-used editor persists in localStorage (`t3code:last-editor`, `editorPreferences.ts:44-56`).
- `mod+o` (`editor.openFavorite`) opens the favorite. Over remote connections it builds an SSH editor URL.

**Loom adaptation:**
- Keep the header to project/branch plus one state pill (the earlier note's position).
- Add a split "Open in ▾" with a remembered last editor and `⌘O`. It maps onto Loom's inspector and `NSWorkspace`. (S)
- Rename by double-click on the title. (S)

## 4. Review

**What the user sees:**
- After each assistant turn, an inline card reads "N changed files +X −Y" with a tree of files, "Show files" and "Open diff" (`chat/ChangedFilesTree.tsx:21-60`, screenshot).
- "Open diff" opens the right-panel Diff tab at that turn.
- Diff scope menu (`DiffPanel.tsx:650-690`, `diffPanelStore.ts:7-11`): **Changes** (branch against a base ref, default "Automatic" with a searchable ref picker), **Uncommitted**, **Latest turn**, and **Turn N** (with time). Per-turn diffs exclude files brought in by pull, merge or rebase (`docs/user/source-control.md`, "Review turn changes").
- Layout toggles: stacked or split (default stacked), wrap, whitespace, a find bar (`mod+f`), and a file tree (`diffs/DiffFileTree.tsx`).

**Comments back to the agent:**
- Selecting diff lines opens a small editor with "Comment" and "⌘/Ctrl Enter to send" (`diffs/DiffCommentAnnotation.tsx`).
- The comment becomes a chip in the composer draft (`addReviewComment`, `AnnotatableCodeView.tsx:121-200`). It is sent with the next message as inline context (`reviewCommentContext.ts`).

**Checkpoints and revert:**
- A hidden Git ref per turn (the earlier note covers `CheckpointStore`).
- User-facing revert is only "Edit from here" under a user message. The dialog offers **Revert and keep changes** or **Revert files too**, and the prompt returns to the composer (`ChatView.tsx:8743-8780`).
- There is no per-file discard or stage in the diff panel (no match in `DiffPanel.tsx`). Staging and commit live in `GitActionsControl`.

**Proactive opening:**
- Off by default (`proactivePanelsEnabled` false, `settings.ts:415`).
- When on, the diff panel opens after a completed turn only if the checkpoint is ready, the project is a Git repo, and there are at least 3 files or at least 50 changed lines. It never reopens if the user already chose a panel or the diff is open (`ChatView.logic.ts:166-204`, `hooks/useProactivePanels.ts`).
- It opens on the "Changes" scope, not on the turn.

**Loom adaptation:**
- A per-turn "N files +X −Y" card in the Chat face with "Open diff", plus the same scope menu in the inspector Changes tab. This is Loom's biggest gap, per the earlier notes. (L)
- Use T3's thresholds (3 files or 50 lines) and the "never override the user" rule for auto-opening. (S)
- Review comments as composer chips. (M, later)
- Keep revert as "Edit from here" only. Defer file restore to the CLI's own `/rewind`, as the earlier note recommends.

## 5. Side panels

**Right panel** (`rightPanelStore.ts:13-21`): one tab host with surfaces `diff`, `files`, `file`, `preview` (browser), `device`, `terminal`, `pull-request` and `pull-requests`. State is saved per thread.
- `mod+alt+b` toggles it, `mod+t` adds a tab, `mod+w` closes a tab (`keybindings.ts:128-135`).
- `mod+shift+t` reopens the last closed view of any kind.
- A maximize toggle hides the chat column.
- Opening is by user action, with the proactive exceptions above.

**Terminal:** `mod+j` toggles a bottom drawer (the user's own shell, not the agent). Terminals can also be right-panel tabs. The sidebar shows a running-terminal icon on rows.

**Browser/preview:** `mod+shift+j`. Per the earlier note it caused GPU/CPU leaks (#14730).

**Tasks:** there is no tasks panel. Todos become a composer banner "Tasks <current step> 3/7" with a segmented bar of up to 10 segments, expandable (`chat/ComposerTasksBadge.tsx`). It joins the other composer banners (approval, user input, plan follow-up, queue, usage limit, server update, side chat).

**Panel motion** defaults to 0 ms, up to 400 ms (`docs/user/appearance.md`, "Motion").

**Loom adaptation:**
- Loom's inspector (Overview, Changes, Tasks, Agents, Side) matches this tab host. Keep one panel, tabs per session, and a maximize toggle. (M)
- Copy "Tasks as one composer banner row" over a separate tasks tab.
- Do not copy an embedded browser. Loom's no-web-view rule rules it out, and T3's own history shows the cost.

## 6. Command palette and search

**Palette** (`CommandPalette.tsx`, `CommandPalette.logic.ts`), opened by `mod+k`:
- Placeholder: "Search commands, projects, and threads…" (`CommandPalette.logic.ts:~600`).
- Root groups are Actions and "Recent Threads" (12, `RECENT_THREAD_LIMIT`). Typing hides Recent Threads and adds Projects, Settings and Threads groups, so results come from commands, projects, settings and threads together.
- `>` as the first character shows actions only (`CommandPalette.logic.ts:423-436`).
- Thread search runs server-side across connected environments (`useThreadSearch`, `CommandPalette.tsx:842`). The docs say message search starts after two characters and covers your messages and final agent responses.
- Thread rows show status, project, branch or worktree, provider, a PR number, and the matched snippet.
- Actions include new thread variants, find in thread, copy prompt link, copy thread reference, link PR, Restart agent session, Go to file (`mod+p`), Search project contents (`mod+shift+f`), Change theme, Change appearance, Open usage (`mod+u`), Open settings, and Add project (local folder, clone, new).
- In-thread find is separate (`mod+f`).

**Loom adaptation:** one palette with sessions, projects and actions, `>` for actions only, and recent sessions as the empty state. (M) Message search should wait until Loom's transcript-search measurement fits. T3 uses plain SQL `LIKE`, not FTS (`orchestration-v2/ThreadSearch.ts:98`, per the earlier note).

## 7. Settings

Sections (`components/settings/settingsSearch.ts:74-88`): General, Appearance, Keybindings, SnapShots, Providers, Integrations, Scheduled Tasks, Source Control, Storage, Connections, Archive, Project, plus Diagnostics. There is a search box over all settings.

**Scope.** Every server-stored setting can target All environments or one environment, and All projects or one project, with a "layers" icon showing where a value comes from and a "Mixed" state (`docs/user/project-settings.md`). Device-local settings, like appearance and confirmations, ignore the scope.

**Appearance:**
- Five built-in themes: T3 Chat, Grove, Ocean, Ember, Iris (`packages/shared/src/themePalettes.ts`). You can import VS Code themes (`vscodeThemeImport.ts`) and edit in a theme editor (`mod+alt+shift+t`). Light and dark can use different themes. System, Light or Dark can be cycled with `mod+alt+shift+a`.
- Contrast and glass opacity sliders (40–100 %, `settings.ts`), chat width (comfortable, wide, full), diff colours (red-green, blue-orange), interface, prompt, code and terminal fonts, font smoothing, word wrap, panel animation 0–400 ms.
- There is no density setting. Chat width and fonts are the nearest.

**Behaviour defaults** (`settings.ts:293-440`): send shortcut Enter, follow-up behaviour Queue, response streaming mode, hide whitespace, default diff file state, diff layout stacked, time format "locale", sidebar thread preview count 6, auto-settle after 3 days (1–90).

**Providers:** per machine. Each provider has install/version status, "behind latest" and a compatibility advisory (the earlier note covers `ModelManifest.ts`). You can add provider instances (extra accounts via a config dir), custom models, and a per-project on/off switch.

**Keybindings:** a settings page plus `~/.t3/userdata/keybindings.json`. Rules are `{key, command, when}` with a `when` language (terminalFocus, composerFocus, turnRunning, editableFocus, isDesktop, …). The last matching rule wins. New defaults are merged in on update (`docs/user/keybindings.md`, `packages/shared/src/keybindings.ts:123-210`).

**Usage:** `mod+u`, a full page (tokens, cost, cache savings, by model and speed, limits windows, custom prices). The earlier note covers sources.

**Confirmations:** unpin, archive, delete (default on), and quit (Hold mode).

**Loom adaptation:**
- A settings search field and a `where it comes from` indicator for project overrides. (S–M)
- Themes: a few built-ins plus contrast and glass. Skip the editor and VS Code import. (S)
- Keybinding `when` contexts are overkill. A fixed table with rebinding is enough. (later)
- Panel animations default to 0, as in T3 (S).

## 8. Notifications and attention

- **Modes** (`notificationMode`, `settings.ts:295`, default `off`): Off, Notifications only, Sound only, Notifications with sound (`threadNotifications.ts:10-23`). `inAppNotificationsEnabled` also defaults false.
- **What triggers one** (`components/ThreadNotificationCoordinator.tsx`): a thread newly enters Input, Approval, Failed or Limited ("Input needed", "Approval needed", "Thread failed", "Usage limit reached"), or a run completes ("Thread completed"). Subagent threads are skipped. Archived threads are skipped.
- **Delivery:**
  - Sound plays for kind "completion" or "input" if the mode includes sound.
  - If the window is focused and a different thread is open, and in-app notifications are on, it shows a toast with title, thread title and "Open thread".
  - Otherwise, if the window is not focused, it posts an OS notification, silent, tagged per thread, that focuses the app and opens the thread on click.
- **Badge:** pending notification count on the Dock/taskbar badge (desktop bridge) or favicon. It clears on window focus.
- **In the list:** the status label and "recede" rules from §2, plus the Woke state.
- **Gap:** issue #780 (closed) asked for approval and completion notifications, and the code is the answer. Everything is off by default, so it is invisible to new users (inference).

**Loom adaptation:** Loom's hook state already knows these events. Use T3's trigger set and focus-aware routing (toast if another thread is open, OS notification if not focused, badge, click to open). Default to on for approval and input only. (S–M)

## 9. Orchestrator V2

(`docs/orchestration-v2/README.md`.) V2 is a rewrite of the orchestration model, not the whole app. It stores state as events and projections in SQLite, with idempotent commands and receipts. The core model is `AppThread > Run > ExecutionNode tree`, where a node can be a tool, an approval, a subagent or a provider thread. App IDs are primary and provider IDs are only references.

Its invariants:
- Only root-run completion completes a user-visible turn, and child completion never closes the parent.
- Checkpoints attach to scopes. Rollback is expressed in app run count.
- Forks record lineage first and resolve lazily: native provider fork if the provider matches, else a portable context transfer.
- Missing capabilities are explicit flags, not provider-name checks.
- Replay-backed integration tests use recorded provider traffic. Only the transport is faked.

On top of that sit `delegate_task` child threads, a thread-reading MCP, a provider switch mid-thread, and queue and resume as server objects.

**Relevant to a single-user Mac app:**
- The turn-completion rule. Loom's Working to Idle transition should ignore subagent finishes.
- Capability flags per feature rather than name checks.
- Replay fixtures: record `claude -p` stream-json and replay it in tests.
- Fork lineage, as a visible child row, for Loom's Side session.

**Not relevant:** the event-sourced store, command receipts, provider switching, `delegate_task`, and the MCP server. They serve a multi-device server and agents that start other agents.

## 10. The provider layer

**Claude (Agent SDK, not the CLI directly).**
- `@anthropic-ai/claude-agent-sdk` is declared `^0.3.276` (`apps/server/package.json:32`) and resolved at exactly 0.3.276 (`pnpm-lock.yaml:1975`).
- The thread identity is `resume: nativeThreadId` for an existing session, or `sessionId` for a new one (`orchestration-v2/Adapters/ClaudeAdapterV2.ts:1089-1092`). `resumeSessionAt` is used for rollback (`:1126`).
- Live model change calls `query.setModel(apiModelId)` and `applyFlagSettings(...)` (`:8070-8072`). Live permission change calls `setPermissionMode` (`:8092`).
- The permission-mode mapping is `permissionModeForClaudeRuntimePolicy` (`:1754-1790`). Plan interaction maps to `plan`; Full access to `bypassPermissions`; read-only to `dontAsk`.
- Approvals are answered through the SDK's `canUseTool` callback, not CLI dialogs (see the earlier note).
- The CLI version policy is advisory (`provider/ModelManifest.ts`, `providerCompatibility.ts`). The earlier note already corrected the "hard minimums" claim.

**Codex (app-server JSON-RPC over stdio).** The adapter talks to a `codex app-server` child process through `packages/effect-codex-app-server` (typed client, generated schema). The spawn is built at `CodexAdapterV2.ts:1370-1380`. The probe command is `<binary> app-server` (`provider/CodexProvider.ts:444`). One app-server is shared across threads.

| Purpose | Method | Evidence |
|---|---|---|
| Handshake | `initialize`, then notify `initialized`. "Already initialized" (-32600) is tolerated. | `CodexAdapterV2.ts:1768-1782` |
| New thread | `thread/start` | `:6461` |
| Resume | `thread/resume` (with `excludeTurns`), `thread/unarchive` on "archived" errors | `:6492-6520`, `:2978`, `:7211` |
| Read | `thread/read` | `:1033`, `:7149` |
| Fork | `thread/fork` | `:7258` |
| Compact | `thread/compact/start` | `:6560` |
| Goals | `thread/goal/set/get/clear` | `:6243-6310` |
| Inject history | `thread/inject_items` | `:1727`, `:6585` |
| Turn | `turn/start` (params: `approvalPolicy`, `approvalsReviewer`, `sandboxPolicy`, `collaborationMode`) | `:6211`; params at `:719-801` |
| Steer / interrupt | `turn/steer`, `turn/interrupt` | `:6655`, `:2523`, `:6830-6937` |
| Background shells | `thread/backgroundTerminals/list/terminate` | `:2293-2315` |

**Approvals and questions** arrive as server-to-client requests that the adapter holds open on a `Deferred` until the UI answers:
- `item/commandExecution/requestApproval` (`:5032`), `item/fileChange/requestApproval` (`:5104`), `item/permissions/requestApproval` (`:5173`).
- `mcpServer/elicitation/request` (`:5235`) and `item/tool/requestUserInput` (`:5454`).
- A "for session" allowance is remembered per thread (`:5032-5060`).

**Events** the adapter handles:
- Streaming: `item/agentMessage/delta` (`:4215`), `item/commandExecution/outputDelta` (`:4229`), reasoning deltas (`:4250-4253`), `item/plan/delta` (`:4257`), `turn/plan/updated` (`:4272`).
- State: `turn/started` (`:4391`), `item/started` and `item/completed` (`:4613`, `:4738`).
- Account and context: `account/rateLimits/updated` (`:4310`), `thread/tokenUsage/updated` (`:4340`), `thread/settings/updated` (`:4379`), `model/rerouted` (`:4387`).
- `turn/completed` is the authoritative terminal event (`:5983`, matching the docs: "`turn/completed` is the authoritative turn terminal event"). `turn/diff/updated` is opted out (`:228`).

**Runtime-mode to Codex policy** (`CodexAdapterV2.ts:674-715`):
- Supervised: `untrusted` + `readOnly`.
- Auto-accept edits: `on-request` + `workspaceWrite`.
- Auto: `on-request` + `auto_review` + `workspaceWrite`.
- Full access: `never` + `dangerFullAccess`.

**Loom adaptation:** for the later Codex plan, the typed-protocol package is the part worth studying. Loom would write its own Swift `Codable` models from the app-server schema, with the same hold-open request handling. (L, post v2)

## 11. Praise and complaints

Independent first-hand reports are thinner than the buzz suggests. Most detailed praise of the chat UI is on T3's own curated wall. I could not read YouTube transcripts, X posts beyond search snippets, or the HN thread "Ask HN: What coding agents are you using?" (`news.ycombinator.com/item?id=48485669`, page returned no comments).

### 11.1 First-hand user reports: praise

1. **r/ClaudeAI, unnamed commenter, 2026-10-10.** They use T3 Code for worktree handling: one Claude Code session per thread, each in its own worktree, a normal chat, and cleanup after merge (paraphrased). https://www.reddit.com/r/ClaudeAI/comments/1x2bv3h/whats_your_setup_for_running_multiple_ai_coding/ — praise for worktree-per-thread with a normal chat.
2. **r/PiCodingAgent, u/Upbeat_Big_2963, 2026-08-15.** "Genuinely love its UI — the chat view, the workflows, the whole feel." The same user then dropped their fork for a terminal-wrapping tool because a GUI "pulls away from [Pi's] customization". https://www.reddit.com/r/PiCodingAgent/comments/1voz5cy/ — praise for look and feel, plus the cost of a chat wrapper.
3. **r/ClaudeCode, OP and commenter "fanatic26", 2026-09-07.** T3's remote setup lets them send screenshots to a Linux box and review its diffs on their Mac while the code stays on Linux (paraphrased); persistent sessions without tmux. https://www.reddit.com/r/ClaudeCode/comments/1w9yzkw/ — praise for remote plus diff review.
4. **r/codex, 2026-03-07 (launch week).** "It works well, only complaint is severe lack of contrast with some text." https://www.reddit.com/r/codex/comments/1rn75r5/t3_code_is_out/ — mixed. Contrast is now a setting.
5. **Quentin Rousseau blog, 2026-03-09.** T3 gives "a task-oriented chat UI with full reasoning and tool call visibility"; he still uses Conductor daily. https://blog.quent.in/blog/2026/03/09/from-vs-code-to-agent-orchestrators-how-multi-agent-workflows-changed-everything/ — a blogger's comparison, partly second-hand.

### 11.2 First-hand reports: complaints

6. **r/ClaudeCode, u/SkepticalHuman0, 2026-04-05.** The Claude Code VS Code extension was "noticeably better" for frontend iteration and design refinement than T3. https://www.reddit.com/r/ClaudeCode/comments/1sd2abg/ — a quality gap for design work (inference: a model/harness difference, not a UI one).
7. **GitHub #6508, "ansh", 2026-08-13 (open, 5 comments).** New threads in a project do not preserve the last-used model, options and mode; behaviour depends on the entry point. https://github.com/pingdotgg/t3code/issues/6508 — directly relevant to Loom's defaults design.
8. **GitHub #4668, dhilditch, 2026-07-27 (closed), and #3925, gutierrezje, 2026-07-12 (closed).** Scrolling up while the agent works gets yanked back down. https://github.com/pingdotgg/t3code/issues/4668
9. **GitHub #4695, saphid, 2026-07-28 (closed).** Sidebar V2 keeps creation order, so a finished thread can sit below several still-working ones and be missed. https://github.com/pingdotgg/t3code/issues/4695 — an attention-ordering request.
10. **GitHub #3697, jakeleventhal, 2026-07-05 (closed).** "Grouping primarily by repo is the wrong organizing principle", asking for grouping by worktree "like Conductor". https://github.com/pingdotgg/t3code/issues/3697 — evidence that the flat/grouped split is contested.
11. **GitHub #272, TaylorMerritt, 2026-03-07 (closed, 21 reactions).** The hard-coded `t3code/…` worktree branch prefix leaks the app name into repos. https://github.com/pingdotgg/t3code/issues/272 — a configurable prefix now exists (default `t3/`).
12. **GitHub #695, MatejSkarka, 2026-03-09 (open, 26 comments).** Slower than Codex for the same task (20+ min against about 3.5 min). https://github.com/pingdotgg/t3code/issues/695 — pre-V2; the earlier note says the Claude reports are anecdotal.
13. **GitHub #7766, Xyz3R, 2026-08-21 (open).** "Flickering sidebar makes it unusable" on Fedora, stable and nightly. https://github.com/pingdotgg/t3code/issues/7766
14. **GitHub #737 (paul-bouzian, 2026-03-09, 15 reactions) and #1283 (earlier note, 20 reactions).** Skills and custom prompts missing in the composer. https://github.com/pingdotgg/t3code/issues/737
15. **GitHub #17467 (closed, 14 reactions, per the earlier note).** The default-on Compact chip made Enter run `/compact` first on stale threads. https://github.com/pingdotgg/t3code/issues/17467 — a lesson against smart defaults that change what Enter does.
16. **r/LocalLLaMA thread, 2026-03-10 (hostile; commenters such as awebb78).** "Entirely vibe coded", "couldn't find a test anywhere", and doubt that anyone runs more than 1–2 agents. https://www.reddit.com/r/LocalLLaMA/comments/1rq2ukc/this_guy/ — ideological and dated. The repo now has large test suites.

### 11.3 Third-party reviews (not first-hand usage, treat as commentary)

- Flavio Copes, 2026-08-28: calls T3 a local control plane, warns it is alpha, not a security boundary, not an IDE replacement, and suggests starting in Supervised. https://flaviocopes.com/t3-code/
- EvoMap, 2026-09-01: "the gain is not magic coding quality. It is continuity." https://evomap.ai/blog/t3-code-review-one-control-surface
- Volanea, 2026-07-27: summarises Theo's Sidebar V2 video. https://www.volanea.com/blog/t3-code-sidebar-v2
- Better Stack, 2026-03-09: worktrees, one-click PR and per-turn diff are the practical wins. https://betterstack.com/community/guides/ai/t3-code/

### 11.4 Creator marketing (separate from the above)

- Theo, X, about 2026-03-22: claims T3 Code uses about half the RAM of the Claude Code CLI (350.9 MB against 635.5 MB). https://x.com/theo/status/2035531539581485151 — an unverified claim from the maker.
- Theo, X, about 2026-07-22: the new sidebar "is a VERY different workflow". https://x.com/theo/status/2079892861689254129
- Theo, X, about 2026-08-09: asks a user for their "biggest pain points". https://x.com/theo/status/2086567643436433490
- The t3.codes wall is 21 curated posts in `apps/marketing/src/lib/tweets.ts`. These are real people but selected by T3. Examples:
  - leodev (2026-05-13): "first coding gui that didn't suck performance wise". https://x.com/leodev/status/2054679746353537042
  - developedbyed (2026-03-08): "pretty awesome, really fast too". https://x.com/developedbyed/status/2030627970532921605
  - RhysSullivan (2026-08-18): "a great UX using it on both desktop and mobile". https://x.com/RhysSullivan/status/2089750636686643493
  - ryanrhughes (2026-08-27): "On T3 Code, it felt like LAN" from a plane. https://x.com/ryanrhughes/status/2093051708939059204

### 11.5 What the evidence says

- **Specific chat-experience praise is mostly speed and feel.** The look gets one first-hand mention (#2). Speed shows up only on the curated wall.
- **No independent praise** found for the composer, work log, plan mode, or multi-provider as such. Plan mode usage reportedly fell and the feature went legacy (Skyflo, third-party, not verified).
- **The strongest first-hand praise** is for worktree-per-thread and remote/phone use (#1, #3).
- **Complaints cluster on defaults and attention:** per-project last-used settings (#6508), attention ordering (#4695), auto-scroll (#4668), and surprising defaults (#17467).

## 12. Closing lists

### Inherit (ranked; must / should / later)

1. **Must:** draft-first new session: no modal, centred composer, headline with project picker, Enter creates the session (§1). M.
2. **Must:** per-project defaults chain with last-used memory (project default, then last-used for that project, then carried). Fixes T3's #6508. M.
3. **Must:** entry points: launch on the most recent project, ⌘N in the current project, a chooser variant, and a no-project scratch session. S.
4. **Must:** status vocabulary and "recede" rules on rows, with approval and input never receding. M.
5. **Must:** attention-first list: a "Needs you" section on top (T3's #4695 gap), with the stable manual order inside it. M.
6. **Should:** Done/Settle shelf with 5-second undo, snooze, and lazy auto-settle with exclusions (§2). M.
7. **Should:** per-turn "N files +X −Y · Open diff" card, and diff scopes Changes, Uncommitted, Latest turn, Turn N (§4). L.
8. **Should:** one palette: actions, projects, sessions, `>` for actions only, recents as the empty state (§6). M.
9. **Should:** thread details in the inspector: remembered "Open in ▾", branch, scripts (§3). S–M.
10. **Should:** composer banner stack above the composer (approval, input, queue, tasks) instead of separate panels. M.
11. **Should:** notification routing: toast if another thread is open, OS notification if not focused, badge, click opens (§8). S–M.
12. **Later:** proactive diff opening with T3's thresholds (3 files or 50 lines) and the never-override-the-user rule. S.
13. **Later:** review comments as composer chips. M.
14. **Later:** project-scope filter and hover card on rows. S–M.

### Do not inherit

- **Embedded browser and preview panel.** No web view, and T3's own GPU/CPU leaks (#14730, #13610) prove the cost.
- **Full-access default for new threads.** A surprise for new users; Loom should pick its own default and always show the mode chip.
- **Changing what Enter does** (the Compact chip, #17467).
- **Flat-only sidebar.** Contested (#3697), and Loom already groups by project.
- **Sidebar rows that hide actions until hover.** Keep them reachable by keyboard.
- **A server-side scheduler, event store and receipts, `delegate_task`, T3 Connect, remote pairing.** They solve multi-device problems Loom does not have.
- **The Agent SDK adapter and parity treadmill** (skills, slash commands, plugins). Loom stays on the real CLI.
- **Theme editor and VS Code theme import.** Poor value for Loom.
- **Usage cost estimates as a headline.** They are API-equivalent, not the bill (`docs/user/usage.md`).
- **A settings model with environment x project scope.** Too much for a single-machine app.
- **Notifications off by default for everything.** Make approval and input on by default.

## Status
Done; no blockers.

## Result
The new-thread flow, sidebar, header, review, panels, palette, settings, notifications, Orchestrator V2 and provider layer are mapped with `file:line` evidence; seven corrections to earlier notes are in §0; 16 attributed user points are in §11 (with creator marketing and third-party reviews kept separate); two or three new-session options and ranked inherit and avoid lists are in §1.8 and §12.

## Evidence
Clone at 5c8528f (`apps/web/src/hooks/useHandleNewThread.ts`, `components/chat/DraftHeroHeadline.tsx`, `components/ChatView.tsx`, `components/Sidebar.tsx`, `packages/contracts/src/settings.ts`, `apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts`, `ClaudeAdapterV2.ts`); one marketing screenshot read; public pages cited inline in §11.

## Unverified
- YouTube videos (transcripts not readable) and most X posts beyond search snippets.
- X post dates are decoded from IDs.
- Claude Desktop details come from `code.claude.com/docs/en/desktop` only, not from running the app; Codex-app details come from the earlier note (`products/codex-app.md`).
- #695's current state, the Skyflo plan-mode figure, and whether #5534 was closed by the draft rows.
- No test or run was done in any repo; the sizes (S/M/L) are my estimates.

## Needs
- A decision from you on Loom's default permission mode for a new session, since T3's Full-access default is its most-criticised default (inference from #17467 and the Flavio Copes advice).
- A choice among Options A, B and C for the new-session flow (my pick: A, with B as a later add-on).

Doc impact: none.
