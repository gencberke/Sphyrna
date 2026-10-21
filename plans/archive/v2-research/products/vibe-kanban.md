# Vibe Kanban (BloopAI)

Research note for the Loom v2 brainstorm ([index](../V2-BRAINSTORM.md)). Written by a research subagent on 2026-10-17 and fact-checked by a second one; the fact-check is at the end and wins over the report where they differ. Raw JSON: `../evidence/deep-dive-20261017.json`.

**In one line:** Open-source (Apache-2.0) local web app plus Rust backend that ran coding agents headlessly, one git worktree per task. It added a kanban board, a diff-review loop with inline comments, and an in-app preview with click-to-component. Its company shut down on 2026-04-10; the repo is now community-maintained and barely moving.

**Category:** chat-first

## Adoption

Repo (BloopAI/vibe-kanban, created 2025-06-14, Apache-2.0): about 28.4k stars, 3.0k forks, 543 open issues, 30 contributors. Show HN on 2025-07-11 reached 195 points and 132 comments.
npm downloads of `vibe-kanban` per month (npm API): Jul 2025 9.6k, Oct 2025 14.6k, Dec 2025 21.5k, Jan 2026 88.8k (peak), Feb 78.7k, Mar 82.6k, Apr 28.0k, May 9.9k, Jul 8.8k, Sep 10.2k, last 30 days to 2026-10-12 10.9k.
So usage was about 80-90k installs a month at the peak and fell about 90% after the shutdown news. The "thousands of engineers every day" in the shutdown post fits this.
Last official release is v0.1.44 (2026-04-24). Community commits continue (HEAD d5cbb53 on 2026-09-19, a bump to 0.1.45), but triage is thin: discussions #3408 "is this project dead?", #3424 and #3416 ask for maintainers who can merge.
Shutdown post (https://www.vibekanban.com/blog/shutdown, 2026-04-10): most users were free and the team found no business model it was excited about. Remote services (kanban issues, comments, projects, orgs) were removed after 30 days; local workspaces keep working.
A maintainer wrote in discussion #3424 that he is not excited by a roadmap of feature catch-up with well-staffed labs, since the lab orchestrators (he named Codex Desktop) improve very fast.
Competitors' comparison pages (Pane, Nimbalyst, Crewly) are biased sources. Pane's page claims about 110 MB memory for one VK server process; this is unverified, and long sessions are reported leaking GBs (see anti_patterns).

## Architecture

Stack: Rust workspace (axum, tokio, SQLx with SQLite, ts-rs for shared types) plus a React/TypeScript web UI (packages/web-core, packages/local-web). Delivered as `npx vibe-kanban`, with an optional Tauri wrapper (crates/tauri-app). There is also a cloud service (crates/remote with Postgres and ElectricSQL) for boards, orgs and relay access.

How it drives the agent. It does NOT host the interactive TUI. For Claude it spawns a headless subprocess (crates/executors/src/executors/claude.rs, `build_command_builder`, `spawn_internal`):
- Base command is `npx -y @anthropic-ai/claude-code@2.1.119` (`base_command`), with `-p --verbose --output-format=stream-json --input-format=stream-json --include-partial-messages --replay-user-messages`.
- If plan or approvals mode is on it adds `--permission-prompt-tool=stdio` and starts in bypassPermissions so plan mode can be exited. Otherwise it disallows AskUserQuestion, and `permission_mode()` returns BypassPermissions.
- A `ProtocolPeer` (claude/protocol.rs) speaks the SDK control protocol over stdin/stdout: initialize with hook callbacks, set_permission_mode, send_user_message, interrupt. Hook callbacks (`PreToolUse`, `Stop`) forward tool approvals to an `Approvals` service (services/approvals.rs) that surfaces them in the UI.
- The Stop hook callback (claude/client.rs, STOP_GIT_CHECK_CALLBACK_ID) blocks the agent from stopping while the worktree has uncommitted changes, and feeds back a commit-reminder prompt.
- Each turn is its own process. A follow-up is a new spawn with `--resume <session_id>` and optionally `--resume-session-at <message uuid>` to truncate history (`spawn_follow_up`). The read loop in protocol.rs breaks on the `Result` message. Exact process exit after a turn is inferred, not traced.
- stdout JSON is re-rendered by a log normalizer (`ClaudeLogProcessor::process_logs`) into its own chat entries, so every tool type needs custom rendering. Unknown variants fall back to `Unknown` (claude/types.rs) rather than failing.
- Slash commands and skills are discovered by scanning `<cwd>/.claude`, `~/.claude` and plugin dirs for frontmatter `description:` (claude/slash_commands.rs, `discover_custom_command_descriptions`).
- All eight other executors are also pinned through `npx -y pkg@version` (codex@0.124.0, gemini-cli@0.29.3, opencode-ai@1.4.7, copilot@1.0.83, and so on), except amp@latest.

Data model (crates/db/migrations). It started as Project -> Task -> TaskAttempt. Migration 20251216142123 renamed task_attempts to `workspaces` and added `sessions` (the executor lives on the session). The chain is now Workspace (branch, container_ref = worktree dir, archived, pinned, name) -> Session (executor, name) -> ExecutionProcess (run_reason is setupscript, codingagent, devserver or cleanupscript; status running, completed, failed or killed) -> coding_agent_turns (agent_session_id, prompt, summary). Per-repo before and after HEAD commits are stored per process (migrations 20250905090000 and 20250910120000). Kanban issues, comments and orgs moved out of the local DB into the remote Postgres service (20251202000000_migrate_to_electric, 20260113144821_remove_shared_tasks). The task_id FK on workspaces was dropped in 20260217120312. Together these explain why the board vanished with the cloud.

Worktrees (crates/worktree-manager/src/worktree_manager.rs). Created with `git worktree add` through the git CLI (`create_worktree_with_retry`) under `<tmp>/vibe-kanban/worktrees` (or a user-set dir, always a `.vibe-kanban-workspaces` subfolder). Per-repo `copy_files`, setup, dev-server and cleanup scripts. Multi-repo workspaces. A background GC removes worktrees one hour after the task is Done or archived (maintainer reply in discussion #2335).

Live diffs (services/diff_stream.rs and filesystem_watcher.rs). A `notify` debouncer with gitignore filtering watches the worktree and streams diffs to the UI over WebSocket. Diff stats are computed against the merge base with the target branch.

Persistence. SQLite plus raw per-process JSONL logs. History is replayed to the UI over WebSocket (`/api/execution-processes/:id/normalized-logs/ws`). Startup `cleanup_orphan_executions` (services/container.rs) marks any process still "running" as failed and records its after-HEAD.

Polling. `PrMonitorService` (services/pr_monitor.rs) polls the git host every 60 seconds.

Queue. `QueuedMessageService` (services/queued_message.rs) is an in-memory DashMap holding one queued follow-up per session, lost on restart.

MCP server (crates/mcp/src/task_server/tools). Tools include list/create/update/delete workspace, `create_session`, a tool that runs a coding-agent turn in a session and returns the execution process, execution status, issue CRUD, repo and script settings, and linking a workspace to an issue. An agent can therefore start other workspaces.

Preview (crates/preview-proxy). A separate proxy port routes `{port}.localhost:{proxy_port}` to `localhost:{port}`. It strips CSP and X-Frame-Options and injects Eruda devtools, a Bippy React-fiber hook and a click-to-component script with React, Vue, Svelte, Astro and plain-HTML adapters. The picked element's component, file and line, and HTML preview are posted to the parent window and attached to the chat.

## Core loop

Loop as documented (docs/index.mdx, docs/workspaces/*, docs/reviewing-code.mdx) and as users describe it:
1. Plan. Write an issue in the board (or skip the board and create a workspace directly). The issue description becomes the first prompt. Pick an agent, a base branch and the repos.
2. Create a workspace. VK makes a worktree and branch (`vk/...`), copies configured files, runs the setup script, then starts the agent headlessly.
3. Walk away. The sidebar groups workspaces into Needs Attention (pending approval), Idle and Running, and sends a desktop notification on completion.
4. Review. Open the Changes panel (file tree plus unified or side-by-side diff). Hover a line and add inline comments. Comments are held in the UI and sent as one batch ("## Review Comments (N)" markdown with file, line and quoted code) with the next chat message. The agent fixes, and the loop repeats.
5. Test. Start the dev server, see it in the preview browser (desktop, mobile and responsive viewports), and use inspect mode to send an element to the agent as context.
6. Ship. Create a PR (AI-written description), rebase, merge. A PR monitor moves the issue to Done. The worktree is garbage-collected later.
Other loop pieces: queue a follow-up while the agent runs, start a new session in the same workspace when the context gauge turns orange, and use Cmd+K for the command bar.
Where it breaks for a heavy CLI user: it hides the real CLI behind its own chat re-rendering, and it only sees sessions it started itself (feature request #3293 asks for external session registration).

## Features

### Workspace = worktree + branch + agent, with setup, copy-files, cleanup and dev-server scripts (parallel-worktrees, confidence high)

- **What the user sees:** Create a workspace and get an isolated branch and folder where the agent works. Setup scripts run first (for example npm install), .env-style files are copied in, and the workspace shows ahead/behind, uncommitted-file counts and conflict state. Several repos can sit in one workspace.
- **How it works:** container.rs `start_workspace` -> `create` (local-deployment) -> worktree_manager `create_worktree_with_retry` (git CLI `worktree add`, with metadata cleanup and retry). Per-repo scripts and `copy_files` live in repos (migrations 20260107000000 and 20250811000000); `copy_project_files` has a 30 s timeout. Setup scripts are chained sequentially or run in parallel before the agent starts. Orphan and expired worktrees are removed by a GC.
- **Reception:** The main reason people used it: it kept parallel agents from clobbering each other. An HN commenter said it adds little beyond terminals plus git worktrees, but is well written. Complaints: the GC removed active worktrees and re-running setup corrupted node_modules (discussion #2335); there was no good branch cleanup; users asked to reuse an existing worktree (#2448).
- **Evidence:** crates/services/src/services/container.rs start_workspace (line ~1047); crates/worktree-manager/src/worktree_manager.rs create_worktree_with_retry (line ~303); docs/workspaces/git-operations.mdx; https://github.com/BloopAI/vibe-kanban/discussions/2335

### Diff review with inline comments sent to the agent as one batch (review-git, confidence high)

- **What the user sees:** A Changes panel with a file tree and a unified or side-by-side diff. Hover a line, click the comment icon, write feedback. Comments pile up as cards and go out together with the next message. Per-turn diff stats appear in the chat.
- **How it works:** Live diff via diff_stream.rs (notify debouncer, gitignore-aware, per-target-branch merge base). Comments are in-memory React state in ReviewProvider.tsx, cleared on workspace change. `generateReviewMarkdown` renders '## Review Comments (N)' with **file** (Line n), the quoted code line, and the comment as a blockquote; SessionChatBoxContainer sends it as the follow-up prompt. There is no server persistence of drafts.
- **Reception:** Bloop says it was first to ship diff commenting; Pane's comparison lists 'inline comments sent to the agent as one batch' as a reason to pick VK. Not heavily criticised.
- **Evidence:** packages/web-core/src/shared/hooks/ReviewProvider.tsx generateReviewMarkdown; docs/reviewing-code.mdx (warning that comments are only sent together with a chat message); crates/services/src/services/diff_stream.rs

### Preview browser with click-to-component and devtools (browser-preview, confidence high)

- **What the user sees:** A built-in browser tab that loads the workspace's dev server automatically (URL parsed from dev-server logs). It has a crosshair 'inspect' mode: click any element and its component name, file, line and HTML snippet land in the chat as context. Also Eruda devtools, a 390x844 phone frame and a responsive drag-resize mode.
- **How it works:** preview-proxy serves the app on `{port}.localhost:{proxy}` and rewrites responses: it strips CSP and X-Frame-Options and injects devtools_script.js, bippy_bundle.js (React fiber hook), click_to_component_script.js (adapters: react, vue, svelte, astro, html-fallback) and eruda_init.js. Results go to the parent through postMessage. The frontend side is usePreviewUrl.ts and PreviewBrowserContainer.tsx.
- **Reception:** Bloop calls click-to-edit a signature feature. Pane's page lists the preview as a VK strength. Issue #3203 reports the preview iframe breaking when VK is remote. Script injection into arbitrary dev servers is brittle by nature.
- **Evidence:** crates/preview-proxy/src/lib.rs (STRIP_RESPONSE_HEADERS, injected scripts); crates/preview-proxy/src/click_to_component_script.js (adapters at lines 183, 331, 426, 536, 616); docs/browser-testing.mdx

### Kanban board of issues linked to workspaces (cloud-backed) (orchestration, confidence high)

- **What the user sees:** Columns To do, In progress, In review and Done (Backlog and Cancelled hidden by default), with priority, assignee and tags. Issue relationships (blocking, related, duplicate). An issue's description becomes the agent prompt, and a workspace links back to its issue. Personal and Team tabs.
- **How it works:** After late 2025 issues lived in the remote service (crates/remote, Postgres plus ElectricSQL), not in the local SQLite. The local `tasks` table is legacy. The workspace-to-issue link and PR state are synced via remote_sync.rs and pr_monitor.rs. After shutdown the remote part was removed, so projects and issues no longer exist in v0.1.44 and the board needs a self-hosted server or the old v0.1.43.
- **Reception:** Loved in the early local-only form (discussion #2726 'old one was better', #2509 'please keep the Kanban board'). Moving it to the cloud and then deprecating it made the tool lose the one thing in its name. Many commenters in #3424 say project management is the part to cut because Linear and similar tools do it and an MCP plus skill can sync tickets; a few want the 'where was I' ledger.
- **Evidence:** docs/issue-management.mdx and docs/cloud/kanban-board.mdx; crates/db/migrations/20251202000000_migrate_to_electric.sql and 20260113144821_remove_shared_tasks.sql; https://github.com/BloopAI/vibe-kanban/issues/3354 (users say 0.1.44 dropped projects); https://runpane.com/compare/vibe-kanban

### Per-turn checkpoints: before/after HEAD, auto-commit, reset to a turn (review-git, confidence high)

- **What the user sees:** After each agent turn the worktree is committed (message from the turn's summary). You can reset the conversation and the files to any earlier turn (the user message has an edit/reset action).
- **How it works:** Each ExecutionProcess records per-repo before_head_commit and after_head_commit (ExecutionProcessRepoState). `try_commit_changes` (local-deployment container.rs ~1554) commits dirty repos after coding-agent and cleanup runs. `reset_session_to_process` (services container.rs ~633) calls `reconcile_worktree_to_commit`, stops processes and drops later processes. For Claude the conversation is rewound with `--resume-session-at <uuid>`. A Stop hook refuses to end a turn with uncommitted files.
- **Reception:** Auto-commit is called one of VK's 'good hook defaults' in #3424. Pane notes there is no manual commit button: VK asks the agent to commit.
- **Evidence:** crates/services/src/services/container.rs reset_session_to_process; crates/local-deployment/src/container.rs try_commit_changes; crates/executors/src/executors/claude.rs spawn_follow_up (--resume-session-at); crates/executors/src/executors/claude/client.rs STOP_GIT_CHECK_CALLBACK_ID

### Message queue and approvals, with a Needs Attention state (attention-status, confidence high)

- **What the user sees:** While the agent runs you can queue a follow-up that is sent when the turn ends. The sidebar marks workspaces that wait on an approval (raised-hand icon) and groups by Needs Attention / Idle / Running. A desktop notification fires on completion or failure, but not when you stopped it yourself.
- **How it works:** The approvals service holds a pending approval with timeout per execution process and streams it to the UI. `finalize_task` (container.rs) sends the completion notification unless the status is Killed. The queue is one in-memory message per session (QueuedMessageService), consumed in the finalization flow.
- **Reception:** The queue is the most complained-about piece in #3416: the queued message often does not fire, the draft is not cleared after it fires, and only one message can be queued. #2953 proposes a FIFO queue. Stuck 'running' ghost processes (#1571) undermine status accuracy.
- **Evidence:** crates/services/src/services/queued_message.rs; crates/services/src/services/approvals.rs; crates/services/src/services/container.rs should_finalize and finalize_task; docs/workspaces/interface.mdx (status indicators)

### MCP server so agents can create workspaces and sessions (orchestration, confidence high)

- **What the user sees:** An agent inside VK (or outside) can list workspaces, create a workspace and start its first session, run another turn in a session, and read execution status. Users also asked for 'a workspace that creates one workspace per planned task'.
- **How it works:** crates/mcp task_server tools (task_attempts.rs create workspace, sessions.rs create_session and run-turn, workspaces.rs, remote_issues.rs, context.rs returning the current project, issue and orchestrator session). Context inside a workspace lets many arguments default.
- **Reception:** Valued by power users ('automation primitives', #3424). Gaps: git ops, tags and PRs are not exposed (#3328), and agents cannot see sibling workspaces (#3308). Nothing in it is gated by an explicit user approval step.
- **Evidence:** crates/mcp/src/task_server/tools/ (sessions.rs line 145 and 256, task_attempts.rs line 94, context.rs); https://github.com/BloopAI/vibe-kanban/discussions/3424 (hugochinchilla asks for workspace fan-out); https://github.com/BloopAI/vibe-kanban/issues/3308

### Multiple sessions per workspace, context gauge, session/agent switching (context-knowledge, confidence medium)

- **What the user sees:** Within one workspace you can run several conversations (even with different agents) that share files but not context. A context gauge turns orange or red as the window fills, and the docs tell you to start a new session then.
- **How it works:** Sessions table keyed to workspace; each session stores executor and name. Claude token usage events feed `TokenUsageInfo` (executors/src/logs/mod.rs) with `model_context_window`.
- **Reception:** Subagents appearing stuck and sessions loading slowly were common reports. Sessions share files, so users still had to coordinate overlapping edits.
- **Evidence:** docs/workspaces/sessions.mdx; crates/executors/src/logs/mod.rs TokenUsageInfo; crates/db/migrations/20251216142123_refactor_task_attempts_to_workspaces_sessions.sql

### PR creation, monitor and remote access (relay/tunnel) (remote-mobile, confidence medium)

- **What the user sees:** Create a PR with an AI-written description, rebase, merge. PR state updates on its own. The UI can be opened from a phone or another machine, and 'Open in VSCode' can use a remote host.
- **How it works:** git_host crate (gh/az CLI wrappers), pr_monitor.rs polling at 60 s, tracked_prs migration 20260311000000. Remote access uses relay crates (relay-client, relay-tunnel, relay-webrtc, trusted-key-auth) or a user tunnel (Cloudflare/Tailscale); the README documents VK_ALLOWED_ORIGINS for proxies.
- **Reception:** Remote and phone access were a genuine draw (JoshuaDietz: 'sometimes even from the phone'). Relay needed Bloop's cloud; issues show relay clock-drift 429s (#3151). Early HN pushback about GitHub OAuth scope and default-on analytics.
- **Evidence:** crates/services/src/services/pr_monitor.rs (Duration::from_secs(60)); README.md remote deployment section; https://news.ycombinator.com/item?id=48241393 (remote support and Open in VS Code called critical)

## UX patterns worth borrowing

- Sidebar of workspaces that can flip to an accordion grouped by Needs Attention, Idle and Running, with pin, archive, change counts and a blue dev-server dot.
- Four-region IDE layout: workspace list, conversation, a switchable context panel (Changes, Logs or Preview) and a right details sidebar (git, terminal, notes). Every region is toggleable from the navbar and from a Cmd+K command bar.
- Diff comments as a staging area: comments stack up as cards, and the whole review goes out as one message. This avoids one round trip per remark.
- Selecting evidence as context: click an element in the preview, or type @ to mention files, and the selection becomes a chat attachment.
- Context gauge in the composer with advice to start a fresh session when it turns orange.
- Queue button next to Send while the agent runs (Cmd+Enter sends).
- Per-repo setup, dev-server, cleanup and archive scripts attached to the repo, so a workspace is reproducible.
- Onboarding explicitly explains git concepts; the audience was broader than power users.

## Anti-patterns

- Pinning agent CLIs through `npx -y pkg@version` (claude-code@2.1.119, codex@0.124.0 and others). Within months the pinned versions were stale (Pane's comparison says each is pinned to an April 2026 version) and users asked for newer agents and models. Loom's 'detect drift, never pin' rule is the right side of this.
- Rebuilding the CLI's interface from headless stream-json. Every tool, slash command and new event type needs custom rendering and discovery; OpenCode events rendered as garbled text (#3123); users report sessions run slower than the direct CLI and long chats load slowly (#3416).
- Depending on headless `claude -p`. Anthropic announced on 2026-05-14 that `claude -p` and the Agent SDK would move to a separate monthly credit from 2026-06-15; it was paused on 2026-06-15 (Help Center note, Digital Applied, aiweekly) and a revised plan was promised with advance notice. VK issue #3417 and #3424 show users were already worried; the interactive TUI was explicitly exempt. Real-PTY hosting avoids this policy risk.
- Default bypassPermissions for Claude when plan and approvals are off (`permission_mode()` in claude.rs), with agents running in a worktree rather than a sandbox.
- Putting the core ledger (the board) behind a cloud service. When the company closed, the local-only users lost the feature and the name (#3354, #2509). Moving to workspaces and deprecating projects 14 days before the sunset (as users describe it) made it worse.
- Forcing a UI migration. Users asked for the old UI, got 'npx vibe-kanban@0.1.8' workarounds (#2726, #2906).
- Unbounded in-memory replay of historical logs: reports of RSS growing to about 15 GB (#3352), 55-60 GB, and 174 GB in 22 minutes (#3218), with reproduction on a 50 MB execution log with 16k output-delta events. A community fix (#3456, 'coalesce replayed stderr chunks') landed in Sep 2026.
- Status that can lie: a cleanup path can remove the worktree while the process row stays 'running' (#1571); 'stuck subagents' and queued messages that never resolve are repeated complaints (#3424, #3416).
- Silent GC of worktrees one hour after Done or archive, even removing active ones in some reports (#2335), with setup re-runs corrupting node_modules.
- Polling (PR monitor every 60 s) and analytics on by default (HN criticism on the Show HN thread); a GitHub OAuth scope that people called too broad.
- Feature breadth over polish: most code untested (#3424 hugochinchilla), and 543 open issues.
- Competing head-on with funded labs on orchestrator features; the maintainer himself called catch-up with labs unexciting (#3424).

## Ideas for Loom

### Review loop for a session's working tree: an on-demand diff view (against the base branch, or against the HEAD recorded at the start of the last turn) with line comments that are staged and then pasted into the live PTY as one prompt. (cost L)

- **Inspired by:** Vibe Kanban diff commenting and batched 'Review Comments (N)' markdown (ReviewProvider.tsx generateReviewMarkdown); Changes panel.
- **Gain:** Review feedback is the step users do most after an agent finishes. One batched message with file, line and quoted code cuts many round trips and avoids typing paths. Fits the user's habit of running many sessions, because review happens inside Loom instead of switching to an editor.
- **Fit:** Fits. Run `git diff` as a bounded read only while the panel is visible, and refresh it from the session's Stop hook event or FSEvents on that cwd, not by polling. Keep comments in a small per-session file so they survive Quit. Delivery must be verified: only send when the registry says the session is idle or waiting for you, and confirm the user message later appears in the transcript, else show 'not delivered'. The terminal stays the CLI's own interface; the diff is a separate pane. Conflict: a diff renderer is new UI weight, so use a plain monospace unified view first and skip syntax highlighting and side-by-side.

### Isolated session = Loom-owned worktree: 'New session in worktree' that creates branch and folder, copies configured files (.env), optionally runs a setup command, launches the CLI there, and verifies removal on delete. (cost M)

- **Inspired by:** Vibe Kanban workspace/worktree model with copy_files and setup/cleanup scripts (worktree_manager.rs, container.rs start_workspace); also its GC failures.
- **Gain:** Parallel sessions on the same project stop colliding, which was the main reason people used VK; the user runs several sessions across few projects, so conflicts are a real cost. Per-project setup removes the manual 'git worktree add, cp .env, npm i' ritual.
- **Fit:** Fits if built as explicit, verified actions. Create and remove are reported as verified outcomes (git state checked after, not assumed). Never auto-GC; instead show 'merged, safe to remove' with a dry run, matching Loom's existing permanent-delete dry run. The worktree is just the session's cwd, so Claude's transcripts (keyed by cwd) stay discoverable. Run scripts inside Loom's run scope so Stop and Quit own them. Avoid VK's hidden temp-dir location: use a visible, configurable folder.

### Verified queued follow-up: type the next message while a session is Working; Loom holds it and delivers it when the session becomes idle, showing queued -> delivered (or 'failed') states. (cost S)

- **Inspired by:** VK message queue (queued_message.rs) and the loudest complaints about it (never fires, draft not cleared, single slot, lost on restart).
- **Gain:** Removes babysitting: the user can line up the next instruction for a long run and move on, and see it actually landed.
- **Fit:** Fits well and matches 'accurate status': trigger from the Stop/idle hook event (no polling), persist the queue (VK's in-memory queue vanishes on restart), allow several ordered messages, and mark delivered only after the transcript shows the user turn. Needs care with approval prompts and a user who types in the terminal at the same time; cancel the queue when the user types directly. A lighter version is one slot with explicit cancel.

### Ticket-keyed work ledger derived from state: group sessions, branches and PRs by ticket key (EDDP-123) into a lightweight 'Work' list whose state is computed (Needs you, Working, In review, Merged) rather than stored on a board. (cost M)

- **Inspired by:** VK kanban (sessions per issue, In progress/In review/Done), plus the #3424 comment 'keep the ledger, drop the runner' and the 'where was I' use case.
- **Gain:** Answers 'which of my N sessions was doing what, and where was I' after a break, per ticket instead of per terminal. Complements Loom's existing ticket de-duplication in loom:open-session.
- **Fit:** Fits only in the light form. No drag-and-drop board and no server: compute columns from session status, branch, `gh pr` state read on demand or on a Stop event, and the ticket key already stored. Do not rebuild issue tracking (Linear/Jira already do it; users in #3424 said to cut that). The cloud dependence that killed VK's board is exactly what to avoid. Risk: the view duplicates the activity view, so only add it if grouping by ticket measurably helps.

### Batch fan-out from a plan: extend loom:open-session so an agent can propose several sessions (title, ticket key, first message, optional worktree) and the user approves them in one sheet. (cost S)

- **Inspired by:** VK MCP server (create workspace and session tools) and the request 'a workspace should create a new workspace for each task in a plan' (#3424).
- **Gain:** Turns a multi-PR plan into parallel sessions in one approval, instead of opening each by hand. Matches the user's multi-agent workflows.
- **Fit:** Fits and is safer than VK's MCP, which has no approval step: every new session still goes through the user's approval over Loom's authenticated socket, with ticket de-duplication. Keep a cap on how many sessions can be proposed at once and show cost implications (each session is a live CLI). Cross-session messaging stays out of scope.

### Per-turn timeline with files changed: record HEAD and changed-file counts at each turn start and Stop (from documented hooks) and show 'what did this turn change' with a one-click diff; expose the CLI's own rewind rather than implementing one. (cost M)

- **Inspired by:** VK per-process before/after HEAD commits and reset_session_to_process; auto-commit per turn.
- **Gain:** Makes long agent runs reviewable in chunks and gives a trustworthy 'what changed since I last looked' marker, without needing the agent to commit.
- **Fit:** Partly. Recording two HEAD hashes and a `git diff --stat` per turn is cheap and event-driven. Do NOT copy VK's auto-commit (it rewrites the user's branch history) or its own reset engine, which depends on CLI flags (`--resume-session-at`) that can drift; link out to the CLI's /rewind instead. Dirty-but-uncommitted work needs a stash-free snapshot approach (for example `git stash create`) which must be tested; unverified.

### Per-session context gauge in the card or header, using token usage already read from transcripts, with an optional 'start fresh session with a handoff note' action. (cost S)

- **Inspired by:** VK context gauge and the docs advice to start a new session when it turns orange (docs/workspaces/sessions.mdx; TokenUsageInfo).
- **Gain:** Prevents the quality drop of overfull contexts and tells you when /compact or a new session is worthwhile, which suits heavy daily use.
- **Fit:** Fits: the usage reader already tails transcripts via FSEvents, so no new polling. Display only; do not auto-act. The model's context window size must come from a documented source, not a hardcoded table (drift risk). The handoff action must be user-triggered.

### Skip the embedded preview browser with script-injecting proxy; if a preview is ever wanted, open the dev server URL in the user's default browser or a lazily created WKWebView that is destroyed when hidden. (cost XL)

- **Inspired by:** VK preview-proxy with click-to-component and Eruda.
- **Gain:** Only high for front-end work. The user is backend-focused, so the payoff is low.
- **Fit:** Conflicts as built: a web view plus an HTTP proxy that strips CSP and injects React/Vue/Svelte adapters is a large, permanently maintained surface and costs memory while open. Lighter variant: detect the dev-server URL from the session and offer 'open in browser' only. Recommend deferring until the user asks for front-end work.

## Fact-check

| Claim | Verdict | Note |
| --- | --- | --- |
| Company (bloop) announced shutdown on 2026-04-10: most users free, no business model; local workspaces keep working; remote kanban issues, comments, projects, orgs removed after 30 days | confirmed | Fetched https://www.vibekanban.com/blog/shutdown (published 2026-04-10). Text matches: 'vast majority are free users', 'couldn't find a business model', 'Remote services will remain available for 30 days', removal list is kanban issues/comments/projects/organisations, 'local workspaces will continue to function'. Post says 'thousands of software engineers use Vibe Kanban every day'. README in the repo also now says 'Vibe Kanban is sunsetting'. |
| VK drives Claude headlessly via `npx -y @anthropic-ai/claude-code@2.1.119` with -p, stream-json in/out, include-partial-messages, replay-user-messages; SDK control protocol (initialize with hooks, set_permission_mode, send_user_message, interrupt); does not host the TUI | confirmed | crates/executors/src/executors/claude.rs: base_command (line 65) = 'npx -y @anthropic-ai/claude-code@2.1.119'; build_command_builder (150-197) adds -p, --verbose, --output-format=stream-json, --input-format=stream-json, --include-partial-messages, --replay-user-messages. spawn_internal (~655-700) calls protocol_peer.initialize(hooks), set_permission_mode, send_user_message. claude/protocol.rs has interrupt(), set_permission_mode(), send_user_message(), initialize(). Local clone is a shallow single-commit checkout at d5cbb53 (2026-09-19). |
| One process per turn; follow-up is a new spawn with --resume <session_id> and optional --resume-session-at <uuid>; read loop breaks on Result | confirmed | spawn_follow_up (claude.rs ~358-381) builds ['--resume', session_id] and pushes '--resume-session-at' when reset_to_message_id is set. protocol.rs read_loop line ~90: Ok(CLIMessage::Result(_)) => break. Process lifecycle after Result is not traced (report already says inferred). Status 'Running/Idle' in VK is derived from the ExecutionProcess row, i.e. process lifetime, not from CLI hooks. |
| Plan/approvals mode adds --permission-prompt-tool=stdio and starts in bypassPermissions; otherwise disallows AskUserQuestion and permission_mode() returns BypassPermissions | confirmed | claude.rs lines 162-176 and permission_mode() lines 199-207. After initialize, spawn_internal calls set_permission_mode(permission_mode), so the default (no plan, no approvals) is effectively bypass. A separate optional dangerously_skip_permissions flag also exists (line 136/176). |
| Hook callbacks (PreToolUse, Stop) forward approvals; Stop hook blocks the agent from stopping while the worktree has uncommitted changes | partly | client.rs on_hook_callback (~323-345): STOP_GIT_CHECK_CALLBACK_ID returns decision 'block' with commit reminder when check_uncommitted_changes is non-empty, approves if stop_hook_active. But get_hooks(commit_reminder) only registers Stop when env.commit_reminder is true; it comes from config.commit_reminder_enabled (config v8, default true), so it is a user-toggleable setting. PreToolUse in default mode only matches AskUserQuestion; approvals mode matches everything except Glob/Grep/NotebookRead/Read/Task/TodoWrite; plan mode matches ExitPlanMode\|AskUserQuestion with auto-approve for the rest. |
| All eight other executors are pinned through npx -y pkg@version (codex@0.124.0, gemini-cli@0.29.3, opencode-ai@1.4.7, copilot@1.0.83), except amp@latest | partly | Confirmed in code: codex.rs 448 @openai/codex@0.124.0; gemini.rs 49 gemini-cli@0.29.3; opencode.rs 92 opencode-ai@1.4.7; copilot.rs 52 @github/copilot@1.0.83; qwen.rs 45 qwen-code@0.9.1; amp.rs 37 @sourcegraph/amp@latest. Executor dir also has cursor and droid (not npx-pinned in a grep) and claude-code-router. README says '10+ coding agents'. Count 'eight' is loose. Missed: command.rs has base_command_override (line 50/183) so the pinned command is user-overridable. The pin is a default, not a hard lock. |
| Data model: Task->TaskAttempt became Workspace->Session->ExecutionProcess (migration 20251216142123); kanban issues moved to remote (20251202000000, 20260113144821); task_id FK dropped (20260217120312) | confirmed | All migration files exist in crates/db/migrations. 20251216142123 does ALTER TABLE task_attempts RENAME TO workspaces, CREATE TABLE sessions, DROP COLUMN executor from workspaces, creates coding_agent_turns, renames attempt_repos to workspace_repos. before/after head migrations 20250905090000 and 20250910120000 and tracked_prs 20260311000000 exist. Did not read the electric migration bodies. |
| Users report v0.1.44 deprecated projects entirely (issue #3354) | confirmed | gh: #3354 'Can we get back the local only projects?' (open, 2026-04-13). Comment by dominikj-cf: 'v0.1.44 has fully deprecated projects - even if you're running everything locally' and 'this is happening 14 days before the actual sunset date' (so the '14 days' phrase in the report is a user comment). Another comment: 'they literally dropped kanban from vibe-kanban'. Confirmed as user reports only. |
| Diff comments are in-memory UI state, cleared on workspace change, sent as one '## Review Comments (N)' markdown follow-up | confirmed | packages/web-core/src/shared/hooks/ReviewProvider.tsx: generateReviewMarkdown builds '## Review Comments (N)' with **file** (Line n), quoted code line, blockquote; useEffect cleanup calls clearComments on workspaceId change (lines 44-46). docs/reviewing-code.mdx line 77-79: Warning 'Comments are not sent individually. They are collected and submitted together when you send a message in the chat.' I did not re-check that SessionChatBoxContainer sends it as the follow-up prompt. |
| Anthropic announced a separate credit pool for claude -p and Agent SDK from 2026-06-15, TUI exempt, paused on 2026-06-15; revised plan promised with advance notice | partly | Primary: Anthropic Help Center https://support.claude.com/en/articles/15036540 states 'Update June 15, 2026: We've paused the previously-announced changes... Claude Agent SDK, claude -p, and third-party app usage still draw from your subscription limits.' Announcement date 2026-05-14 and TUI exemption are from digitalapplied (secondary; it also states the advance-notice promise, quoting Anthropic) and VK issue #3417 (quotes @ClaudeDevs post). BUT the same Help Center page now carries a newer 'Update October 7, 2026': Max and Team plans now include monthly API credits (see missed). So the report's picture of the situation is stale by 4 months. |
| npm downloads: Jan 2026 peak ~88.8k, Apr 28.0k, around 10k/month now; fell ~90% | confirmed | api.npmjs.org range query 2025-07-01 to 2026-10-12: Jul25 9,629; Aug 9,312; Sep 19,113; Oct 14,576; Nov 14,072; Dec 21,472; Jan26 88,774; Feb 78,739; Mar 82,612; Apr 27,995; May 9,946; Jun 7,288; Jul 8,782; Aug 7,701; Sep 10,245. last-month point 2026-09-13..10-12 = 10,858. Peak-to-now drop is ~88%. Report's monthly list matches (Sep 2025 19.1k omitted but not wrong). Note: npm downloads include CI/mirror/npx re-fetches, so not unique users. |
| Repo adoption: ~28.4k stars, 3.0k forks, 543 open issues, 30 contributors, Apache-2.0, created 2025-06-14 | partly | gh api: stars 28,381, forks 3,035, license Apache-2.0, created 2025-06-14. 'open_issues_count' 543 is issues PLUS PRs: search shows 388 open issues and 155 open PRs. Contributors API returns 64 (not 30). The 155 open PRs unreviewed is a stronger sign of absent maintainers than the report's issue count. |
| Last official release v0.1.44 (2026-04-24); community commits continue, HEAD d5cbb53 on 2026-09-19 (bump to 0.1.45) | confirmed | gh releases: v0.1.44-20260424091429 published 2026-04-24. Commit list since 2026-04-25 contains only 10 commits, the latest d5cbb53 (2026-09-19, 'Tanstack router api fix'); 13d81e2 'bump version to 0.1.45' also 2026-09-19. So roughly 10 commits in five months. Version 0.1.45 bump exists in git but there is no GitHub release for it in the top 3 releases. |
| Show HN on 2025-07-11 reached 195 points and 132 comments | confirmed | HN API item 44533004: 'Show HN: Vibe Kanban - Kanban board to manage your AI coding agents', score 195, descendants 132, time 1752246532 (2025-07-11). |
| Discussion #3424: maintainer said he is not excited by a roadmap of feature catch-up with well-staffed labs and named Codex Desktop | confirmed | Discussion 3424 'What would a community edition of Vibe Kanban look like?' (2026-06-02) by stunningpixels (Louis, co-founder). His comment: 'Daily coding agent orchestrators from the labs, especially Codex Desktop, have gotten really good', 'I don't get excited about a roadmap that's essentially: feature catchup with extremely well staffed labs'. He also says they built an unreleased 'orchestrator' agent and links PR #3065 (partial MCP implementation). hugochinchilla says 'most code is untested' and to remove the task management system. The 'keep the ledger, drop the runner' idea is from LearnPrompt (2026-09-11); MartyLake (06-03) wants 'which terminal was doing what / where was I'. |
| Queue is the most complained-about piece in #3416; queued message often does not fire, draft not cleared, only one message can be queued | partly | Discussion 3416 has one top-level comment (dominikj-cf) listing these three queue problems plus slowness vs direct CLI and slow long-chat loading; maintainer mickmister replies that firing 'only occurs when the agent did not make any code changes on the given turn' (his belief). In #3424 JoshuaDietz also says queuing 'does not seem to be reliable (chat getting stuck, message stays queued forever)'. 'Most complained-about' is an overstatement from a very small sample. queued_message.rs is confirmed in-memory DashMap<Uuid, QueuedMessage> (one per key). |
| Unbounded replay memory: RSS ~15 GB (#3352), 55-60 GB and 174 GB in 22 min (#3218), 16k delta events in 50 MB log; fix #3456 in Sep 2026 | confirmed | #3352: RSS ~15 GB, VmData ~38 GB, workspace mode long-lived sessions. #3218 body: ~115 MB to ~174 GB in ~22 min, 55-60 GB OOM on March 20, 50.6 MB log with 16,023 exec_command_output_delta events. CAVEAT: #3218's reproduction is Codex logs (exec_command_output_delta), not Claude stream-json, so it is VK's normalizer, not an inherent consequence of headless Claude. #3456 is a merged PR (e5327c6, 2026-09-17) titled 'Coalesce replayed stderr chunks so stored sessions load in linear time'; it addresses stderr chunk coalescing, which may not close #3218 or #3352 (both still open). |
| Per-turn checkpoints: before/after HEAD per execution process, auto-commit after coding-agent run, reset via reconcile_worktree_to_commit + --resume-session-at | confirmed | local-deployment container.rs try_commit_changes (1554): commits dirty repos for CodingAgent and CleanupScript runs; called (line ~572) only when the process succeeded (exit 0) or cleanup finished, so a killed or failed turn is not committed. services container.rs reset_session_to_process (633) calls git().reconcile_worktree_to_commit (git/src/lib.rs 892). cleanup_orphan_executions (273) marks running rows Failed at startup and records after-HEAD. Commit is unconditional (not a setting), unlike the Stop-hook reminder. |
| Notification on completion/failure but not when killed; sidebar groups Needs Attention / Idle / Running | confirmed | container.rs finalize_task (~240): returns early for Killed; docs/workspaces/interface.mdx lines 76-78 define Running, Idle (waiting for input), Needs Attention (pending approval, raised hand). Status is derived from process/approval state, not from CLI events. |
| Worktrees: git CLI worktree add, default under <tmp>/vibe-kanban/worktrees, custom dir uses .vibe-kanban-workspaces subfolder; copy_files timeout 30 s; GC removes worktrees 1 hour after Done/archived | confirmed | worktree_manager.rs get_worktree_base_dir / get_default_worktree_base_dir (utils::path::get_vibe_kanban_temp_dir()/worktrees); local-deployment container.rs copy_project_files has 30 s timeout; discussion #2335 reply by ggordonhall confirms the one-hour GC and immediate removal on task delete. Another commenter in #2335 reports active worktrees occasionally cleaned and node_modules corruption (single report). |
| PR monitor polls every 60 s; preview proxy strips CSP/X-Frame-Options and injects Eruda, bippy and click-to-component with React/Vue/Svelte/Astro/HTML adapters | confirmed | pr_monitor.rs poll_interval Duration::from_secs(60); preview-proxy lib.rs STRIP_RESPONSE_HEADERS includes content-security-policy, x-frame-options, x-content-type-options; files bippy_bundle.js, eruda_init.js, click_to_component_script.js with reactAdapter, vueAdapter, svelteAdapter, astroAdapter, htmlFallbackAdapter. |
| MCP server lets an agent create workspaces/sessions and run turns | confirmed | crates/mcp/src/task_server/tools/sessions.rs: create_session, list_sessions, update_session, run_session_prompt, get_execution; plus task_attempts.rs, workspaces.rs, remote_issues.rs, context.rs. dominikj-cf confirms in #3424 that it supports 'create a new workspace for each task'. 'Not gated by user approval' not verified. |
| Pane's page claims ~110 MB memory for one VK server process | confirmed | runpane.com/compare/vibe-kanban: 'idle RAM ... vibe kanban 110 MB (one server process)', measured on one PC with npx inside WSL; also says 'each pinned to a version from April 2026' and 'no commit button, it asks the agent to commit'. It is idle server RAM only, excluding agent processes and browser tab, from a competitor. |

### Corrections

- Do not say VK has '543 open issues': that GitHub count is 388 open issues plus 155 open PRs. Contributor count is 64 per the contributors API, not 30.
- The billing story is stale. As of the Anthropic Help Center page (updated 2026-10-07), claude -p and the Agent SDK still draw from subscription limits (June 15 split paused), AND Max/Team plans now also receive separate monthly API credits ($100/$200 per Max tier; Team $20/$100 per seat, pooled, capped $500) that cover Agent SDK/API/Managed Agents but not interactive Claude Code or extra usage. Frame the claude -p risk as 'paused, no timeline guarantee', not as an active policy.
- The '--resume-session-at'/-p dependence is a VK-internal choice; the claim that 'real-PTY hosting avoids policy risk' rests on the TUI-exempt statement from secondary sources (digitalapplied) and the VK issue quoting @ClaudeDevs; the Help Center page I could fetch no longer contains the original announcement text.
- The 174 GB OOM (#3218) was reproduced on Codex logs (exec_command_output_delta), not Claude; #3456 (merged) targets replayed stderr chunks and both memory issues (#3352, #3218) are still open. Do not present memory blow-up as inherent to headless Claude or as fixed.
- The Stop-hook commit enforcement is a config toggle (commit_reminder_enabled, default true), not unconditional. Auto-commit after a turn is unconditional but only on a successful (exit 0) coding-agent run, so killed/failed turns leave uncommitted changes.
- 'Queue is the most complained-about piece in #3416' overstates a one-commenter list; #3416 has a single top-level comment. Treat queue unreliability as a credible but thinly sourced pain point (also mentioned once in #3424).
- Claude pinning is a default: executors support base_command_override (crates/executors/src/command.rs), so users can point VK at another CLI path/version. The anti-pattern is the default pin plus no drift detection, not an impossibility to update.
- The '14 days before sunset' for deprecating projects is one user's comment in #3354, not a maintainer statement.

### Missed by the report

- Anthropic Help Center update of 2026-10-07 (https://support.claude.com/en/articles/15036540 and https://support.claude.com/en/articles/17154008): Max/Team now get monthly API credits (Max 5x $100, Max 20x $200, Team Standard $20/seat, Premium $100/seat, pooled cap $500; Pro/Free/Enterprise not eligible). Credits cover Claude API, Agent SDK, Managed Agents; they do not apply to interactive Claude Code or extra usage, and claude -p / Agent SDK are still usable under subscription limits.
- VK's status model (Running / Idle / Needs Attention) is process-lifecycle plus approvals-service state, not hook- or transcript-derived, which explains ghost-running rows (#1571: ExecutionProcess stays 'running' after worktree removed) and why startup cleanup_orphan_executions force-fails all running rows. Useful contrast for Loom's accurate-status goal.
- Hooks are injected through the SDK control protocol (initialize with hookCallbackIds), not through ~/.claude settings files, so VK's hooks work only for processes VK itself launched; this is why it cannot see external sessions (feature request #3293).
- Alternatives named in VK threads that keep the real CLI: kandev (https://github.com/kdlbs/kandev, 'supports running claude in CLI mode', #3417) and ouijit (https://github.com/ouijit/ouijit, interactive-mode sessions with lifecycle hooks and agent-created tasks, #3417); a user in #3417 notes CLI-wrapper mode loses external orchestration and richer chat visualisation. The repo cache also holds other relevant tools (emdash, superset, herdr, orca, paseo etc.) not covered in this report.
- User-requested diff scope in #3424 (JoshuaDietz): switch diff between 'all on the worktree' and 'since last commit/specific commit', 'see what changed since my feedback'; also a per-worktree 'context brief' injected into each session and alternative way to choose the preview URL. These directly support the report's per-turn diff idea.
- Maintainer-side unreleased orchestrator agent and partial MCP PR #3065 (referenced in #3424): the team itself concluded a 'project management agent might just be a coding agent' and leaned toward using VK with other lab orchestrators.
- Only ~10 commits landed between 2026-04-25 and 2026-09-19 (several are security/lint/version bumps), and 155 PRs are open, so the 'community-maintained' label overstates activity; a fresh-start DB (db.v2.sqlite) importer is already built by a third party (carl-vibe-kanban) per #3424.

## Sources

- https://github.com/BloopAI/vibe-kanban
- https://www.vibekanban.com/blog/shutdown
- https://nimbalyst.com/blog/vibe-kanban-after-bloop-whats-next/
- https://crewlyai.com/en/blog/vibe-kanban-alternative
- https://runpane.com/compare/vibe-kanban
- https://news.ycombinator.com/item?id=44533004
- https://news.ycombinator.com/item?id=48241393
- https://github.com/BloopAI/vibe-kanban/discussions/3424
- https://github.com/BloopAI/vibe-kanban/discussions/3416
- https://github.com/BloopAI/vibe-kanban/discussions/2335
- https://github.com/BloopAI/vibe-kanban/discussions/2726
- https://github.com/BloopAI/vibe-kanban/issues/3354
- https://github.com/BloopAI/vibe-kanban/issues/3408
- https://github.com/BloopAI/vibe-kanban/issues/3417
- https://github.com/BloopAI/vibe-kanban/issues/3352
- https://github.com/BloopAI/vibe-kanban/issues/3218
- https://github.com/BloopAI/vibe-kanban/issues/1571
- https://github.com/BloopAI/vibe-kanban/issues/2509
- https://www.digitalapplied.com/blog/anthropic-claude-credit-overhaul-june-15-2026
- https://aiweekly.co/alerts/anthropic-pauses-claude-agent-sdks-new-token-based-billing
- https://api.npmjs.org/downloads/point/last-month/vibe-kanban
- Code: ~/Library/Caches/loom-v2-research/repos/vibe-kanban (crates/executors/src/executors/claude.rs and claude/{client,protocol,slash_commands,types}.rs; crates/services/src/services/{container,approvals,queued_message,pr_monitor,diff_stream}.rs; crates/local-deployment/src/container.rs; crates/worktree-manager/src/worktree_manager.rs; crates/preview-proxy/src/{lib.rs,click_to_component_script.js}; crates/mcp/src/task_server/tools; crates/db/migrations; packages/web-core/src/shared/hooks/ReviewProvider.tsx; docs/*)
