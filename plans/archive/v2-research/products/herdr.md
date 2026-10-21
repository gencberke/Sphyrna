# herdr (herdrdev/herdr)

Research note for the Loom v2 brainstorm ([index](../V2-BRAINSTORM.md)). Written by a research subagent on 2026-10-17 and fact-checked by a second one; the fact-check is at the end and wins over the report where they differ. Raw JSON: `../evidence/deep-dive-20261017.json`.

**In one line:** Apache-2.0 Rust "agent multiplexer": a background server owns real PTYs, a mouse-first TUI (one client among several) shows every agent's working/blocked/done/idle/unknown state, and a CLI + socket API + agent skill let agents spawn, prompt and wait on each other.

**Category:** terminal-first (utility / runtime layer; the TUI is the bundled client, third parties add web, iOS and Raycast clients)

## Adoption

Facts from the GitHub API on 2026-10-17: github.com/herdrdev/herdr was created 2026-03-27 and has 44,443 stars, 3,526 forks, about 357 open and 2,208 closed issues, and 8,859 downloads of one v0.9.2 release's assets. The latest stable is v0.9.5 (2026-10-14), with preview builds every few days and a CHANGELOG of 1,342 lines.

Author statements and third-party reports, not independently checked:
- The Herdr blog (Aug 2026) says 25k stars and 340k downloads at the YC announcement. The "Connecting the machines" post says more than 700,000 downloads and close to 1,000 plugins. The YC post says 500+ plugins one month after the marketplace opened.
- The YC F26 batch and a $6M seed are shown on herdr.dev/blog (search snippet). The HN "Connecting the machines" thread quotes the $6M figure.
- HN: the 404-point thread "Herdr: One terminal to rule them all" is item 48756578. developersdigest.tech dates it 2026-07-02, which I did not verify on HN. The 166-point thread (item 48714802, 110 comments) is dated 2026-06-29 by the same source. The YC thread is item 49201003, said to be 281 points; I did not check the score.
- License was switched from AGPL to Apache-2.0 (YC post).

Positioning and monetization: the TUI and runtime stay free. The next paid product is Herdr Cloud, a relay that links your own machines under one account with end-to-end encrypted terminal traffic (herdr.dev/cloud, waitlist). HN reaction to an account requirement was negative.

## Architecture

STACK. Rust, one binary, client/server in the same executable (no Electron). Terminal emulation uses a vendored libghostty-vt (crates/ghostty-vt, vendor/libghostty-vt) and a vendored portable-pty (vendor/portable-pty, src/pty/). The wire protocol is bincode/JSON with "endpoint generations" frozen by fixtures (tests/fixtures/endpoint-*-v1.json; AGENTS.md "Stable client endpoint contract"). Code size is about 178k lines under src/.

PROCESS MODEL. `herdr` starts or attaches to a background server (src/server/headless.rs, src/server/client_accept.rs, src/server/client_transport.rs). The server owns PTYs, child processes, pane terminal state, agent state and the session layout. Clients are renderers.
- Since 0.9 the outer UI renders in each client; servers only supply pane views, so one client can aggregate several servers (local plus SSH machines).
- `ctrl+b q` detaches. The server ignores SIGHUP, so closing the shell that launched it does not stop it (0.9.4). `herdr server stop` ends it and every pane.
- Named sessions are separate servers with their own sockets and state. Multiple clients can attach at once, each viewing a different workspace or tab.
- Control surface: a JSON-line Unix socket API with about 100 methods (docs socket-api.mdx; src/api/schema.rs, src/api/server.rs), `herdr api schema`, and CLI wrappers. AGENTS.md "Runtime/client boundary guardrail" says shared behavior must be exposed through the server API, not the private TUI socket.

AGENT STATE DETECTION. Four layered inputs, arbitrated per pane:
1. Process identity. src/detect/mod.rs calls platform::foreground_job and foreground_process_group_id. src/pane/background_agent.rs (AgentJobTracker) pins the agent's pid plus a start token, so pid reuse and ctrl-z/fg do not lose identity. `HERDR_AGENT=<kind>` is a hint for sandbox wrappers.
2. Screen manifests. TOML rules in distribution/agent-detection/*.toml (claude.toml is 2026.10.11.1). Each rule has a state, a priority, a region (`bottom_non_empty_lines(12)`, `after_last_horizontal_rule`, `prompt_box_body`, `osc_title`, `whole_recent`), regex/contains gates, and flags `visible_blocker`, `visible_idle`, `visible_working` and `skip_state_update`. They are evaluated over the live bottom of the terminal buffer, never the user's scrolled viewport (AGENTS.md "Screen detection is evidence-based"). Manifests are fetched from herdr.dev without a restart (src/detect/manifest_update.rs); a local override in ~/.config/herdr/agent-detection/ always wins.
3. Hooks/self-report. `pane.report_agent` and `pane.report_agent_session` carry a monotonic `seq` so stale reports cannot overwrite newer state. Only Pi, OMP, Kimi, OpenCode, Kilo and MastraCode are "full lifecycle hook authority" (src/detect/mod.rs `full_lifecycle_hook_authority`).
4. PTY activity is the normal "working" authority (comment in src/detect/mod.rs).

For Claude Code specifically, the integration installs only a SessionStart hook (src/integration/assets/claude/herdr-agent-state.sh, integration v11). It reports session id and transcript path, and state still comes from screen manifests. Herdr rolled back Codex turn hooks in 0.9.5 because of a "clamping Interrupt hook timeout" warning (CHANGELOG 0.9.5).

POLLING. The per-pane detection task in src/pane.rs (~line 2851) ticks every 300 ms when an agent is identified and 500 ms when not. Pending-idle confirmation rechecks every 100 ms, up to 700 ms (src/pane/agent_detection.rs). Process rechecks run every 5 s (PROCESS_RECHECK_IDENTIFIED). A screen scan is skipped when the detection content_seq is unchanged. This is the opposite of Loom's no-polling rule, but it is bounded and instrumented. AGENTS.md has a "Multiplicative performance paths" rule and `just bench-render-scale` / `bench-release-smoke`.

WAITS. `agent.wait` and `agent.prompt --wait` (src/api/wait.rs) use an EventHub with sequence numbers. They pin the resolved pane occupant, and slow readers get an `events_lost` error. The API thread still loops with a 100 ms sleep (CONNECTION_POLL_INTERVAL), and `pane wait-output` re-reads the pane each loop. So "event-driven" is true for the source of truth but not for the wake-up mechanism.

PERSISTENCE. session.json is written atomically. Up to 48 layout snapshots go in session-snapshots/, at most one per 15 minutes. A failed load copies the original into session-backups/ (the last 3 are kept). On macOS and Windows it saves before the OS shuts down (0.9.4). Pane screen history replay is opt-in because it can contain secrets. After a server restart, processes are gone: layout is restored and agents are resumed by `claude --resume <id>`, staggered 100 ms apart.

RESOURCES. Tuned for many panes: hidden panes still parse output but trigger no presentation work (AGENTS.md). Issue #5289 shows about 11% of a core and about 710 read syscalls/s with a few idle agent panes in default mode on gVisor Linux. A user report says remote sessions get laggy after hours (HN item 49652188).

## Core loop

A typical day:
1. SSH into a box (or open a terminal) and run `herdr`, or `herdr --remote user@host`. Layout and agents are where you left them.
2. One workspace per repo or task; start `claude`, `codex` and so on in panes. Herdr detects them, no setup.
3. Work from the sidebar's agent list: `blocked` and `done` rise to the top, and toasts, terminal or system notifications and sounds fire per state. Click or use Go To (prefix+g) to jump to the pane that needs you.
4. For longer runs, an agent (or you) drives the CLI. The herdr skill makes the agent split a pane, `agent start reviewer --kind codex`, `agent prompt reviewer "..." --wait`, then `agent read` the result. Dev servers and tests go in sibling panes with `pane run` and `pane wait-output`.
5. Parallel branches use `herdr worktree create`, which makes a grouped workspace.
6. Detach with ctrl+b q and walk away. Reattach from a laptop, phone terminal (Termius/Moshi) or a third-party PWA.
7. Gaps are filled by plugins: diff review pane, file viewer, auto-title, a work board that fans tasks out to agents on worktrees, web and iOS clients.

## Features

### Server-owned PTYs with detach/reattach and multi-client attach (other, confidence high)

- **What the user sees:** Close the terminal, lose SSH, or close the lid and agents, shells and dev servers keep running. `herdr` reattaches. Several clients can view different workspaces at once. After a cold server restart the layout returns and supported agents resume their conversation.
- **How it works:** The headless server (src/server/headless.rs, src/server/client_accept.rs) owns portable-pty PTYs and libghostty-vt terminal state; clients attach over a local socket or SSH bridge. tests/detach_reattach.rs and tests/multi_client.rs cover it. Cold restart uses the layout snapshot plus a native resume command. Per docs session-state.mdx, `claude --resume <id>` is used when the SessionStart hook reported a session id, resumed staggered (startup_per_agent_delay_ms, default 100) after a client attaches. Live handoff (`herdr update --handoff`) is experimental and best-effort.
- **Reception:** Praised by remote and phone users and by people who dislike tmux copy/paste. HN skeptics say tmux, zmx or Zellij persist too. Cold restart does not keep processes (flaviocopes.com/herdr-vs-cmux). Open bugs include 'session.json missing after system shutdown, session restores as empty' (#5349) and clients starting duplicate servers (#5231).
- **Evidence:** README.md: 'detach without stopping work... the original processes do not survive' a server or machine restart; docs/next/website/src/content/docs/session-state.mdx (survival table, snapshot restore, native agent session restore table); src/server/headless.rs, tests/detach_reattach.rs, src/pty/; HN 48756578 and 48714802: users describe SSH-in/phone reattach as the real win; skeptics say tmux already does this

### Layered agent status with screen manifests, hooks and an honest-ish unknown (attention-status, confidence high)

- **What the user sees:** Each pane is blocked, working, done (idle and unseen), idle, or unknown. Workspaces and tabs roll up the worst state. No per-agent setup is needed for Claude, Codex and about 20 other CLIs.
- **How it works:** Foreground process identity plus a per-agent TOML manifest evaluated over the live bottom-of-buffer text. Rules have regions, priorities and AND/OR gates; flags `visible_blocker`/`visible_idle`/`visible_working` let a visible dialog override a non-blocked integration state (src/detect/mod.rs AgentDetection doc). Idle-to-working is held through up to 3 rechecks to avoid flicker (src/pane/agent_detection.rs PendingIdleConfirmation). Manifests update remotely from herdr.dev and can be overridden locally. For Claude only SessionStart is hooked, so state is scraped (src/integration/assets/claude/herdr-agent-state.sh).

The 'unknown' state is real but narrow. Unrecognized programs and agent-owned viewers (transcript viewer, model picker, via `skip_state_update`) are unknown. A recognized agent with no matching rule falls back to idle, labeled `default_known_agent_idle_fallback` in explain output; the docs admit new prompts may show as idle instead of blocked (docs agents.mdx 'Blocked state').
- **Reception:** The sidebar glance and notifications are the most-cited reason people use it (HN 48756578, 49104999). Accuracy complaints are constant. An HN user said a waiting shell command shows as idle, which they thought was wrong. The cmux-vs-herdr comparison (blog.debedb.com, 2026-07-26) says 'detection is clever; being told is sturdier' and wants herdr to read state from hooks.
- **Evidence:** distribution/agent-detection/claude.toml (rules live_blocked_form, bash_permission_prompt, legacy_no_prompt_blocker, osc_title_working with a spinner-glyph comment per Claude version); src/pane.rs ~2851 tick constants; src/pane/agent_detection.rs; docs agents.mdx 'How status works', 'Blocked state', 'Detection manifests'; Open issues #5221, #4275, #4668 (Claude prompts reported idle), #4064 (prose reported blocked), #3467 (stale busy title outranks a permission dialog); CHANGELOG 0.9.5: Claude questions in named sessions fixed; 0.9.4: Antigravity/Grok idle while subagents run

### `herdr agent explain` and manifest debugging tools (attention-status, confidence high)

- **What the user sees:** When a pane shows the wrong state, run `herdr agent explain <pane>` (or `--file screen.txt --agent codex --json`) to see the final state, the matched rule, and the evidence that led to it.
- **How it works:** DetectionExplain (src/detect/manifest.rs) carries agent, state, manifest source (bundled, remote or local override), manifest and cached-remote versions, whether a local override shadows the remote one, the matched rule, every evaluated rule with matcher and region evidence, the skipped-update reason for viewers, and the fallback reason. `herdr agent read <pane> --source detection --format text|ansi` dumps exactly the buffer the detector sees. scripts/capture_agent_screen.py records labeled screen captures as fixtures, and scripts/agent_detection_manifest_check.py validates manifests.
- **Reception:** Not discussed much on HN, but it is the workflow the maintainers use to triage the steady stream of detection bugs. Issue #5256 is a bug in explain itself (CRLF mis-slices regions).
- **Evidence:** src/detect/manifest.rs DetectionExplain struct; docs agents.mdx 'Detection manifests'; AGENTS.md: capture with `herdr agent read ... --source detection` before changing manifests; scripts/capture_agent_screen.py

### Wait primitives and fused prompt-and-wait dispatch (orchestration, confidence high)

- **What the user sees:** `herdr agent prompt reviewer "..." --wait --timeout 120000` blocks until the agent has settled. `herdr agent wait x --until blocked` and `herdr pane wait-output p --regex 'passed|failed'` exist. `agent_blocked`, `agent_prompt_stalled` and `timeout` are distinct errors.
- **How it works:** Server-side in src/api/wait.rs. `wait_for_agent` snapshots the EventHub sequence first, then checks current status, then waits on events, which avoids the race. The wait pins the resolved pane occupant so a replacement agent cannot satisfy it. `prompt_agent` refuses with `agent_blocked` if the agent is already at a dialog. It writes text and Enter as one ordered submission honoring bracketed-paste mode, then requires observed `working` or `blocked` within 5 s (AGENT_PROMPT_EFFECT_TIMEOUT_MS) before accepting later idle/done. Agent responses carry `completion_seq` / `state_change_seq` so startup, resume and /new do not count as completed work. Event subscribers that fall behind get `events_lost`. The wake-up loop still sleeps 100 ms (CONNECTION_POLL_INTERVAL), and `pane wait-output` re-reads the pane each loop.
- **Reception:** Experienced multi-agent users call it the most distinctive primitive. The documented failure mode is serious. Because Claude state is scraped, `agent list` showed working while a permission dialog was on screen, and a prompt's Enter approved it (#5263). Lesson: delivery must be gated on verified state, and idle is not authorization.
- **Evidence:** src/api/wait.rs: wait_for_agent, prompt_agent, wait_for_event, AGENT_PROMPT_EFFECT_TIMEOUT_MS; docs agent-automation.mdx (prompt/wait semantics, 'A timeout or agent_prompt_stalled does not prove that no input was sent'); skills/herdr/SKILL.md; blog.debedb.com 2026-07-26: the wait verb is 'the real content' and cmux lacks one (issue cmux #8950); herdrdev/herdr issue #5263 (agent prompt typed Enter into a Claude permission dialog while a PermissionRequest hook ran, approved a tool call, reportedly a production-branch merge)

### Agent skill that teaches agents the CLI (orchestration, confidence high)

- **What the user sees:** An installable skill (skills/herdr/SKILL.md, also docs agent-skill.mdx) so Claude, Codex and others can inspect neighbouring panes, start sibling agents, run dev servers in other panes, and wait on them.
- **How it works:** The description only triggers when the user mentions Herdr explicitly. The skill first checks `test "${HERDR_ENV:-}" = 1` and stops if outside Herdr. It says the installed binary is the authority for syntax ('Start with herdr --help', then run each command group bare). IDs are never predicted: read them from JSON responses; `--current` and `HERDR_PANE_ID` are injected env. It sets defaults for a sibling pane in the same cwd with `--no-focus`, and gives safety rules: do not close what you did not create, never `server stop` from a session, `--trust-repository` only after user verification, do not blindly resubmit a prompt after timeout. It states state semantics, including that idle is not approval and unknown does not prove completion. Pane-side env: HERDR_ENV, HERDR_PANE_ID, HERDR_SOCKET_PATH, HERDR_BIN_PATH, HERDR_WORKSPACE_ID, HERDR_TAB_ID.
- **Reception:** Positive. An HN user says it lets them stop doing the work in each session and orchestrate instead. Concern raised in the same thread: agents driving a multiplexer is a security issue.
- **Evidence:** skills/herdr/SKILL.md (read in full); docs add-herdr-support.mdx (env contract, report-agent, seq, resume command, release); HN 48756578: users value 'a decent CLI and skill for agents'; running dev servers in herdr panes instead of long shell commands

### Plugin system and GitHub-topic marketplace (automation, confidence high)

- **What the user sees:** `herdr plugin install owner/repo`. Plugins add actions (keybind or palette), event hooks (e.g. on `worktree.created`), full-screen or overlay panes, link handlers, and startup hooks. herdr.dev/plugins lists any public repo tagged `herdr-plugin`.
- **How it works:** A plugin is a directory with `herdr-plugin.toml` (id, version, min_herdr_version, [[build]], [[startup]], [[actions]], [[events]], [[panes]], [[link_handlers]]). Commands are argv arrays run as the user with HERDR_* env. The whole CLI is the plugin API, there is no separate SDK, and no sandbox. Install shows a trust preview and builds in a managed directory; `plugin update` is non-disruptive to running panes. The marketplace indexes GitHub topic `herdr-plugin` every 30 minutes and is explicitly unreviewed. Source: docs plugins.mdx, marketplace.mdx; src/cli/plugin.rs, src/plugin_installations.rs.
- **Reception:** The author's stated reason for plugins is to keep the core lean. Community fills real gaps (diff review, file viewing, auto-naming, mobile). Unreviewed arbitrary-code installs are a trust risk the docs flag themselves.
- **Evidence:** docs plugins.mdx, marketplace.mdx; gh search repos --topic herdr-plugin: herdr-reviewr 896 stars (diff review with line comments sent back to the agent), herdr-file-viewer 658, herdr-projects 792 (task board; Coordinator agent; agents on worktrees; second-agent review; draft PR), collie 1,377 (PWA), herdr-web-ui 1,129, Heeler 597 (iOS), zoetrope 1,049; HN 49652188: auto-title is a plugin (kryptamine/herdr-auto-title); herdr.dev/blog/connecting-the-machines: close to 1,000 plugins

### Sidebar attention model, Go To navigator and declarative agent views (navigation-ux, confidence high)

- **What the user sees:** A collapsible sidebar with workspaces and an agent list. blocked and done sort first, and state rolls up to tab and workspace. Prefix+g opens a searchable Go To list of every agent and terminal grouped by workspace, with status and path. Notifications are in-app toasts, outer-terminal notifications that work over SSH, or system ones, plus per-state sounds and per-agent overrides.
- **How it works:** A 'done' state means idle and not yet seen. Seen state is tracked per client, so viewing in one client does not clear another's badge, while the CLI/API uses the server's seen state (docs concepts.mdx). `agent.view.set` installs a transient declarative filter/sort (ops all/any/not/eq/in/exists on status, workspace_id, seen, state_change_seq, or a plugin metadata token) that drives the sidebar, mobile list and next/previous navigation, without changing notifications or counts. Sidebar row layouts and metadata tokens are configurable (configuration.mdx 'Sidebar row layouts'). Plugins can report display-only tokens with `pane report-metadata`.
- **Reception:** Glanceable status plus notifications is the top praise. A limit: cmux's approval 'Feed' (one blocked list across agents) is called more human-oriented than herdr's toast (blog.debedb.com).
- **Evidence:** docs concepts.mdx, agents.mdx 'State rollups', socket-api.mdx 'Agent view queries'; CHANGELOG 0.9.2: Go To shows every agent and terminal as its own row; false done notifications on startup/restore/Pi /new fixed (#3338, #3990, #3916); HN 48756578: 'I can see the status of my Claude Codes just by glancing at the sidebar'; cmux status was per workspace and confused with several agents in one workspace

### Multi-machine client and Herdr Cloud relay (remote-mobile, confidence high)

- **What the user sees:** `herdr machine add <ssh-host>` adds a remote machine's workspaces and agents beside local ones in one window. Independent reconnects, a combined agent list, and machine-scoped navigation. `herdr --machine X agent prompt ...` controls a remote server's agents from a script. Herdr Cloud (waitlist) promises SSH-less linking via an account with end-to-end encrypted traffic.
- **How it works:** Since 0.9 the client renders the outer UI and each server supplies pane views (CHANGELOG 0.9.0; blog 'Connecting the machines'). Over SSH it bridges to a remote herdr and sends row-diff updates (0.9.2). The CLI forwards API methods through a saved profile and never falls back to Local. Transport uses OpenSSH with a generated config and ControlMaster (src/remote/, src/remote/attach.rs). IDs and agent names are server-scoped.
- **Reception:** Valued by people who run agents on a VPS or Mac mini. The cloud/account direction was the main negative reaction in a thread of about 10 comments. One commenter doubts a PTY/SSH abstraction is right for large swarms; sandbox-style harnesses may win (HN 49612818).
- **Evidence:** docs connecting-machines.mdx, persistence-remote.mdx, skills/herdr/SKILL.md --machine section; herdr.dev/blog/connecting-the-machines; herdr.dev/cloud; HN 49612818: several users object to an account, 'the writing is on the wall for enshittification'; others say Tailscale already does this; CHANGELOG 0.9.0, 0.9.1, 0.9.2

### Thin worktree management (parallel-worktrees, confidence high)

- **What the user sees:** `herdr worktree create --branch X` makes a git worktree and opens it as a workspace grouped under the parent repo. `worktree open` and `worktree remove` exist. Lifecycle events (`worktree.created` and so on) can trigger plugin hooks, e.g. a bootstrap script.
- **How it works:** src/worktree.rs shells out to `git worktree add/remove/list --porcelain`. Remove never deletes the branch and needs `--force` for a dirty checkout; `--trust-repository` is request-scoped. Closing a primary workspace with open worktree workspaces needs explicit `--group`. Default path is <worktrees.directory>/<repo>/<branch-slug>. The code has tests and fixes for slow git, missing checkouts and nested duplicates (CHANGELOG 0.9.4).
- **Reception:** Appreciated because it uses plain git rather than private state. HN comments show the demand for a view of agents per worktree plus lifecycle hooks.
- **Evidence:** src/worktree.rs (build_worktree_add_new_branch_command, run_worktree_remove_command_with_recovery, checkout_has_dirty_files); docs cli-reference.mdx 'Worktrees'; HN 48756578: users want a UI that lists worktrees and agents per worktree, and dislike tools that manage worktree state themselves; setup hooks wanted (test DB per worktree)

### Crash-safe session persistence (other, confidence high)

- **What the user sees:** After a reboot the layout and agent sessions come back; failed loads do not silently wipe your layout.
- **How it works:** session.json is replaced atomically. Up to 48 snapshots go in session-snapshots/ (at most one per 15 minutes, interval survives restarts). An unreadable session file is copied to session-backups/ before replacement (3 kept). Saves are triggered before the system starts closing apps on macOS and Windows, and with a logind inhibitor delay on Linux (0.9.4). A pane whose cwd is gone stays as an errored pane instead of disappearing. Pane screen history replay is off by default because it could contain secrets.
- **Reception:** Not a headline feature, but the changelog shows users repeatedly lost layouts on reboot before these fixes.
- **Evidence:** docs session-state.mdx; CHANGELOG 0.9.4 (save before shutdown, atomic writes), 0.9.1 (backup of unreadable saves), 0.9.2 (48 snapshots); src/persist/{snapshot,writer,restore}.rs; Open #5349: session.json missing after system shutdown on Linux 0.9.5

### Chat view over the agent's own transcript (ecosystem pattern) (chat-input, confidence medium)

- **What the user sees:** Third-party herdr-web-ui shows each agent pane as a chat (tool calls folded per turn, approvals and questions as tappable cards, attach a screenshot, voice input) with the real terminal one click away, on desktop or phone.
- **How it works:** It reads the agent's own session store (Claude/Codex/etc. transcripts), using the session id and transcript path that herdr's integration hook reports through pane.report_agent_session (agent_session_path field), and falls back to the live terminal for agents without a readable store. It drives herdr only, over the socket API. Source: README of github.com/devswha/herdr-web-ui; docs/chat-mode-audit.md referenced there (not read).
- **Reception:** Signals that a chat projection plus terminal toggle is where users of a terminal-first tool go when they want mobile and readability; herdr core stays terminal-only. HN 48756578 commenters wished for rendered markdown/mermaid and diffs in the tool.
- **Evidence:** gh api repos/devswha/herdr-web-ui/readme: 'This one reads the agent's own transcript, so a pane is a chat... terminal a click away'; src/integration/assets/claude/herdr-agent-state.sh sends agent_session_path = transcript_path; collie (1,377 stars) and Heeler (597) are other phone clients

## UX patterns worth borrowing

- Everything is clickable, with keyboard as an optional layer. The tmux prefix model is kept for experts, and 'prefix+?' lists every binding. HN users call this the reason they could adopt it without memorizing keys.
- A sidebar that is workspaces on top and a status-sorted agent list below, with state rolling up from pane to tab to workspace so a project can be 'blocked'.
- 'done' is not 'idle': done means finished and unseen, and is cleared by looking, tracked per client. This one distinction drives notifications and sort order.
- A Go To picker that lists every agent and terminal, grouped by workspace, with status and path, searchable, with agent-state filters (prefix+g).
- Declarative sidebar view queries (filter and sort expressions) that plugins can set and clear, and that also drive next/previous agent navigation.
- Responsive layout for narrow screens: sidebar hides, the tab bar becomes a status line (workspace, tab, agent states), the rest goes into a hamburger menu.
- Per-pane right-click passthrough toggle so mouse-reporting apps inside a pane still work, with the frame always opening herdr's menu.
- Notification channel choice (in-app toast, outer-terminal, OS) with per-state and per-agent sounds; popups are suppressed for the active tab.
- Honest errors in automation: distinct codes (agent_blocked, agent_prompt_stalled, agent_not_idle, agent_not_ready, events_lost, workspace_group_close_required) and 'a timeout does not prove nothing was sent'.
- Confirmations only for destructive close of the last pane/tab or a workspace group; `ui.confirm_close = false` turns them off.

## Anti-patterns

- Scraping the screen for approval dialogs and defaulting a known agent to idle when no rule matches. This causes repeated false-idle bugs (#5221, #4275, #4668) and #5263: automation typed Enter into a Claude permission dialog and approved a tool call.
- Treating 'idle' as 'safe to inject input'. The docs themselves warn that idle is not authorization; the product still ships a path where it is.
- Polling detection ticks per pane (300 ms/500 ms, 5 s process rechecks) plus 100 ms API loops. Lag and CPU complaints exist (#5289, HN 'laggy after a couple of hours' on 5 remote machines).
- Installing a hook script that silently does nothing when python3 is missing (#5348): the integration looks installed but resume never works. A Claude background-daemon session was also recorded as another pane's session (#5261).
- Rolling hook-based state back because of CLI warnings (Codex hook timeout, 0.9.5). If a hook can emit CLI warnings or timeouts, it needs a drift check and a fallback story.
- Running a multiplexer inside the user's terminal means key conflicts (Ctrl+B, left/right arrow aliases #5233), mouse/escape sequence leaks (#5251, #5302, #5295), and a long tail of terminal-quirk bugs; about 357 open issues. A native app avoids most of these.
- Marketing that is vague ('designed for agents') and a logo marquee drew HN scepticism; many saw tmux or zellij as enough (HN 49104999, 48756578).
- Pushing an account-gated cloud on a tool people adopted because it is local, lean and has no account. Strong negative reaction in HN 49612818.
- Unreviewed plugin marketplace with no sandbox: every plugin has the full CLI as its API and runs as the user.
- Fast release cadence with preview builds every few days and hotfixes (v0.9.2 to 0.9.3, 0.9.4 to 0.9.5) because regressions land in input handling.

## Ideas for Loom

### Verified cross-session prompt delivery with refusal on approval state. When the user allows one session to message another (the planned channel), the send is a fused, verified operation: refuse if the target is Needs approval, otherwise deliver and confirm a UserPromptSubmit hook / transcript user-turn arrived, and return 'delivered', 'stalled' or 'refused' as distinct outcomes. Never retry blindly. (cost M)

- **Inspired by:** herdr agent.prompt --wait: agent_blocked refusal, 5 s 'must observe working or blocked' gate, agent_prompt_stalled (src/api/wait.rs); and the failure in issue #5263 where Enter approved a Claude permission dialog.
- **Gain:** Safe lead-agent / reviewer-agent workflows without the user babysitting; no silent loss or accidental approvals. This is the part of herdr's orchestration that Loom can do better because it already has hook-driven state and verified outcomes.
- **Fit:** Fits 'verified outcomes', 'accurate status' and 'cross-session actions only under the user's authority'. Per-send user approval (as for loom:open-session) or a user-granted scoped permission is required. The hook-confirmed delivery avoids herdr's screen-observation heuristic. Conflict: none, but it needs a Claude hook that proves delivery (UserPromptSubmit) and a clear rule that Needs approval is never auto-answered.
- **Risks:** The target may be mid-turn, so the message queues rather than starts a turn; the semantics (queued vs started) must be explicit. Hook delivery can drift with CLI versions; detect and report 'delivery unconfirmed' instead of success.

### A `loom` CLI plus skill with event-driven read/wait first. Commands like `loom sessions`, `loom status <session>`, `loom wait <session> --until needs-you|finished|failed --timeout`, and `loom read <session> --last-turn`. Skill pattern copied from herdr: gate on an env var (LOOM_SESSION=1), tell the agent the binary is the authority for syntax, never predict IDs, trigger only on an explicit mention, explicit safety rules. (cost M)

- **Inspired by:** skills/herdr/SKILL.md; agent.wait with occupant pinning and an event sequence snapshot taken before the status check (src/api/wait.rs wait_for_agent).
- **Gain:** Multi-agent workflows (a coordinator that waits for reviewers or for the user's other sessions) without the user polling. The user already runs many sessions with subagents, and a lead agent can wait on a sibling's Finished or Failed instead of sleeping.
- **Fit:** Reads and waits are non-mutating, so they fit 'no polling' if waits are served from Loom's in-memory state change stream (a Unix socket subscription, no timer loop; herdr's 100 ms sleep loop is the thing not to copy). Pin the wait to the session id plus run identity so a resumed or replaced process cannot satisfy it. Writes (prompt/open) stay under the user-authority gate. Loom already has an authenticated socket for loom:open-session, so this extends it.
- **Risks:** Exposes more of the user's session data to agents; keep it read-only and scoped (session list may be limited to the same project unless the user allows more). Scope creep into a full orchestration API; keep the surface to 4-6 verbs.

### 'Why this status?' (explain) for session state. A header-pill popover and `loom status --explain`: the current state, which signal produced it (hook event + time, registry value, watchdog timeout, drift flag), the previous state and when it changed, and unknown/unrecognized values. Plus 'since resume' guards so a resume, /clear or compact never shows as Finished unviewed. (cost S)

- **Inspired by:** herdr agent explain (DetectionExplain in src/detect/manifest.rs) and completion_seq / state_change_seq to separate real completions from startup/restore (CHANGELOG 0.9.2, docs agent-automation.mdx).
- **Gain:** Makes status trustworthy and debuggable in seconds when a CLI update changes behavior. It also turns status bugs into copy-pasteable evidence for the drift detector.
- **Fit:** Very good fit: 'accurate status', 'detect drift, never report false success', no extra resource use (stores the last transition reason, which Loom's state machine already has). It is the same discipline herdr applies but with hook signals instead of regexes. No conflict.
- **Risks:** Surfacing too much internal detail in the main UI; keep it behind a pill click or CLI.

### Chat projection of the same session with the real terminal one click away. For ended, idle or stopped records the detail pane shows the transcript as a readable chat (tool calls folded per turn, approvals as cards) read incrementally via FSEvents, and 'Terminal' brings the live PTY. A composer would send through the PTY (bracketed paste) rather than a second protocol. (cost XL)

- **Inspired by:** herdr-web-ui (github.com/devswha/herdr-web-ui): the agent's own transcript as chat, approvals as cards, terminal a click away, built on session id + transcript path reported by herdr's hook. Also the user's side-chat/right-panel wishes.
- **Gain:** Readable history and cheap browsing of finished sessions, a path to mobile/other clients, and the foundation for a side chat that is a separate thread over the same transcript. The user said they are open to a chat-centred UI; this keeps the real CLI authoritative.
- **Fit:** Strong for 'no live terminal for idle records' (a transcript render costs nothing when the session is stopped) and 'bounded reads'. Reuses the incremental transcript reading Loom already has for usage and subagent panels. Risk to 'resilience to CLI updates': the transcript JSONL is not a documented interface, so every field read needs drift detection and a graceful fallback to the terminal. The composer must report 'delivered' only when the transcript shows the turn.
- **Risks:** Transcript format drift; duplicating CLI UI work (slash commands, permission modes); two input paths confusing the user. A read-only chat first is the lighter variant.

### Thin worktree launcher tied to tickets. 'New session in worktree' for a project/ticket key runs plain `git worktree add` (branch from ticket key, path from a slug), opens the session there, groups it under the parent project, and cleans up with the same safety rules: never delete the branch, refuse a dirty checkout unless forced, and show worktree provenance on the card. (cost M)

- **Inspired by:** herdr src/worktree.rs and `worktree create/open/remove`; HN 48756578 asks for agents-per-worktree and creation hooks, and for tools that call `git worktree` directly rather than keep private state.
- **Gain:** Parallel agents on the same repo without conflicts, one click from a ticket, and git remains the source of truth so the CLI/IDE can keep switching freely.
- **Fit:** Fits 'process ownership' and 'clean modular structure' if kept as a small module around `git worktree` with verified outcomes (created/removed reported only after git returns). It is a gap Loom lists (worktree management). Conflict: avoid becoming a git client; no diff/PR UI in this idea.
- **Risks:** Repo-specific setup (databases, env files) needs a post-create hook; keep that as a user script rather than built-in logic. Dirty-state handling must stay conservative.

### Crash-safe state and session-registry hardening. Save the window/session layout atomically, keep a few rolling snapshots, back up an unreadable state file before overwriting, and persist before the OS shuts down or restarts (NSWorkspace will-power-off) so a reboot keeps resume info. (cost S)

- **Inspired by:** herdr session persistence (docs session-state.mdx; CHANGELOG 0.9.4 'Restarting a Mac keeps your agents' sessions' and atomic writes; 0.9.1 session-backups; 0.9.2 48 snapshots).
- **Gain:** Removes the 'reboot lost my layout / resume info' failure that herdr users hit repeatedly, with almost no ongoing cost.
- **Fit:** Excellent: event-driven (writes on change and on shutdown notification), no polling, bounded disk use, and it matches Loom's 'Quit stops all sessions' by making the next launch resume cleanly. The 15-minute snapshot throttle is cheap. Keep any pane screen history opt-in and out of scope (secrets).
- **Risks:** Low. Make sure resume references written for a session are validated against Claude's own registry on restore, not trusted blindly (herdr bugs #5261, #5348 show stale or missing session references).

### User-defined actions and event hooks (not a marketplace). A small config file where the user binds commands to Loom events (session finished, needs approval, ticket opened, worktree created) and to palette entries, run as plain processes with LOOM_* env and calling the `loom` CLI. No sandbox, no install flow. (cost M)

- **Inspired by:** herdr plugin manifest: [[actions]], [[events]], [[link_handlers]] and 'the whole CLI is the plugin API' (docs plugins.mdx). Community plugins show the real needs: diff pane, file viewer, auto-title, notifications to Telegram.
- **Gain:** Covers a long tail (push to phone, auto-title from the first prompt, custom review launcher) without growing Loom's core, which the user wants kept light.
- **Fit:** A full plugin ecosystem and marketplace conflict with Loom's size and trust principles (herdr's marketplace is unreviewed, runs arbitrary code, and is a growth lever for a funded company). The lighter variant is a personal hooks file: no UI surface, runs only on events already produced, bounded timeouts and output, and failures reported rather than ignored. Depends on the `loom` CLI idea.
- **Risks:** Becomes a second configuration language and support burden; hooks that call back with write verbs must pass the same user-authority gate.

## Fact-check

| Claim | Verdict | Note |
| --- | --- | --- |
| Claude Code state in herdr comes from screen-manifest scraping; Claude integration installs only a SessionStart hook reporting session id and transcript path | confirmed | docs/next/.../integrations.mdx:112 says 'Claude Code state comes from Herdr's screen manifest detection'. src/integration/claude_settings.rs install() calls ensure_command_hook only for SessionStart (with matcher ^(startup\|resume\|clear\|compact\|fork)$). src/integration/assets/claude/herdr-agent-state.sh exits unless hook_event_name == SessionStart and sends agent_session_id plus transcript_path as agent_session_path. Integration version is 11 (src/integration/mod.rs). |
| Only Pi, OMP, Kimi, OpenCode, Kilo and MastraCode are full-lifecycle hook authorities | confirmed | src/detect/mod.rs:330-340 full_lifecycle_hook_authority matches exactly those six (herdr:pi, omp, mastracode, opencode, kilo, kimi). Hermes/Qwen/Letta/Antigravity are 'session identity only' (line 342). |
| Issue #5263: agent prompt typed Enter into a Claude permission dialog while a PermissionRequest hook ran, approved a tool call (reporter says a production-branch merge); opened 2026-10-14 | confirmed | gh issue view 5263: created 2026-10-14T09:32:56Z, state OPEN, 0 comments. Body states agent list showed working while the dialog was visible, prompt exited 0, tool call approved. The production-branch merge is only the reporter's own statement in the Impact section, not independently verified. Reported on integration v10 / claude manifest 2026.09.11.1 (current is v11 / 2026.10.11.1), so it may or may not reproduce on current. No maintainer response yet. |
| Open issues #5221, #4275, #4668 (Claude dialogs shown idle) and #3467 exist | confirmed | All OPEN. #5221 'Teach auto mode about your environment?' dialog reported idle; #4275 claude-in-chrome permission prompts idle; #4668 AskUserQuestion review screen can report idle; #3467 stale busy OSC title outranks blocked rules (created 2026-08-31, so it is long-lived). Also confirmed open: #5261, #5348, #5349, #5231 with titles as the report describes. |
| Detection ticks 300 ms identified / 500 ms unidentified; process recheck every 5 s | confirmed | src/pane.rs:2851-2852 TICK_UNIDENTIFIED 500 ms, TICK_IDENTIFIED 300 ms, plus TICK_PENDING_RELEASE 50 ms (not mentioned in the report). src/pane.rs:413 PROCESS_RECHECK_IDENTIFIED = 5 s. Screen scan skipped when detection_content_seq unchanged (pane.rs ~1157-1178). Pending-idle: 3 confirmations, 100 ms interval, 700 ms cap (src/pane/agent_detection.rs:6-9). |
| API wait threads sleep 100 ms (CONNECTION_POLL_INTERVAL); docs still call agent.wait 'server-owned and event-driven' | confirmed | src/api/server.rs:30 CONNECTION_POLL_INTERVAL = 100 ms; src/api/wait.rs sleeps it at lines 128, 512, 755. The loop drains EventHub events and probes agent_get when needed, so the state source is event-sequenced but wake-up is a 100 ms poll. socket-api.mdx:114 uses the phrase 'server-owned and event-driven'. |
| agent prompt --wait: refuses with agent_blocked, requires observed working/blocked within 5 s, pins occupant | confirmed | src/api/wait.rs:20 AGENT_PROMPT_EFFECT_TIMEOUT_MS = 5000; if no working/blocked is observed it returns agent_prompt_stalled (or timeout if the caller's timeout is shorter). SKILL.md lines 145-147 and socket-api.mdx:114 confirm agent_blocked is returned before any input is sent, only when the server already sees blocked (which is exactly the #5263 hole). The wait compares terminal id/agent name/kind identity (agent_wait_identity_matches). Note SKILL.md says the wait 'tracks lifecycle state, not an individual turn'; if the agent is already working, completion of the active turn may satisfy it. |
| Server-owned PTYs: detach/reattach, processes do not survive server restart, layout restored, claude --resume <id> used; handoff experimental | confirmed | session-state.mdx survival table: server restart -> processes No, layout Yes, conversation only with native agent session restore. Claude Code resume command is 'claude --resume <id>' (table line 95). resume_agents_on_restore defaults to true (src/config/model.rs:278). Update --handoff is 'Best effort'. Server ignoring SIGHUP confirmed in CHANGELOG 0.9.4 (line 25). |
| Skill is a safety document: gate on HERDR_ENV=1, binary authoritative, idle is not approval, etc. | confirmed | skills/herdr/SKILL.md line 3 (description: use only when the user explicitly mentions Herdr; requires HERDR_ENV=1), line 13 test HERDR_ENV=1, line 59 idle/done do not guarantee an unfamiliar approval dialog was recognized; 'unknown' does not prove completion; line 145 'ask the user before answering' a blocked dialog. |
| Adoption: 44,443 stars, 3,526 forks, ~357 open / 2,208 closed issues, 8,859 downloads of v0.9.2, v0.9.5 on 2026-10-14 | confirmed | gh api today: 44,448 stars, 3,526 forks, created 2026-03-27, Apache-2.0. Issues search: 357 open, 2,209 closed issues. v0.9.2 assets 8,860 downloads. Latest release v0.9.5 published 2026-10-14T16:07Z. (repos API open_issues_count=370 includes PRs.) CHANGELOG.md is 1,342 lines. |
| HN: 404-point thread 48756578 dated 2026-07-02; 166-point 48714802 (110 comments) dated 2026-06-29; YC thread 49201003 ~281 points | confirmed | HN Firebase API: 48756578 'Herdr: One terminal to rule them all' 404 pts, 178 comments, 2026-07-02; 48714802 166 pts, 110 comments, 2026-06-29 (links to github.com/ogulcancelik/herdr, the pre-org repo name); 49201003 281 pts, 189 comments, 2026-08-06; 49612818 'Connecting the machines' 93 pts, 35 comments (report says 'a thread of about 10 comments', which understates it); 49652188 is the 'Herdr Studio' Show HN, 45 pts. 49104999 is a comment (loveparade: 'don't understand what it gives me over tmux other than the agent sidebar'), not a thread. |
| Author statements: 25k stars/340k downloads at YC post; 500+ plugins one month after marketplace; 700k+ downloads and close to 1,000 plugins; switched AGPL to Apache-2.0 | confirmed | herdr.dev/blog/herdr-is-joining-y-combinator (2026-08-06): '25k stars and 340k downloads', 'More than 500 plugins, one month after the marketplace released', 'switched it from AGPL to Apache'. The post says Can is 'the only person behind Herdr' at that time. connecting-the-machines (2026-09-07): 'more than 700,000 downloads and close to 1,000 plugins'. CHANGELOG line 359 records the relicense. All are author statements, not independently measurable. |
| $6M seed (YC F26) | confirmed | Primary: herdr.dev/blog/herdr-raised-a-seed (2026-09-08): $6M seed led by Bessemer Venture Partners, with Y Combinator, e2vc, angels Tobi Lutke (Shopify), Dane Knecht (Cloudflare), Gorkem Yurtseven (fal); they are hiring. The report cited only a search snippet and an HN comment (rvz in 49612818 links this post); the YC post itself does not mention the $6M. |
| Herdr Cloud: account-gated relay, E2E-encrypted terminal traffic, waitlist; negative HN reaction | confirmed | connecting-the-machines post: one Herdr account, middleman layer, terminal traffic E2E encrypted, you bring your own machines, waitlist. HN 49612818 has several comments against an account ('enshittification', 'If asked to create an account... decline'), others note Tailscale/SSH already work and the docs say Cloud is unnecessary if SSH works. Reception is mixed rather than uniformly negative (some supportive replies from daily users). |
| Resource numbers: #5289 shows ~11% of a core and ~710 read syscalls/s in default mode on gVisor Linux | partly | Numbers match the issue, but the issue is about HERDR_PROCESS_DETECTION=child-groups (non-default), where CPU scales to 9% -> 45% -> 84% of a core (4,000 -> 15,000 -> 30,600 reads/s) as idle agent panes are added; the 11%/710 reads/s figure is the unset (default) control with the same panes. The report presents only the favorable control and omits the real defect. The gVisor /proc tpgid=0 quirk is the trigger. |
| Claim: HN user says remote sessions get laggy after hours (49652188) | confirmed | rs_rs_rs_rs_rs in the Herdr Studio thread: 'with work done on 5 remote machines herdr just gets laggy after couple of hours and basically becomes almost unsable.' Single anecdote, unreproduced. |
| Codex turn hooks rolled back in 0.9.5 due to 'clamping Interrupt hook timeout' warning | confirmed | CHANGELOG 0.9.5 line 11: Herdr no longer installs Codex turn hooks, Codex status comes from screen detection again (#5246, #5278). |
| Source tree is about 178k lines under src/ | refuted | find src -name '*.rs' \| cat \| wc -l on the clone (commit 143bf5f) gives about 289,500 lines, which includes inline tests. Not decision-relevant but the number is wrong. |
| Third-party plugin/ecosystem facts (herdr-web-ui reads transcripts, star counts, marketplace indexes topic every 30 min) | unverifiable | Not re-checked in depth; plugin docs and marketplace.mdx exist in docs/next (plugins.mdx, marketplace.mdx) and the SessionStart hook does send agent_session_path = transcript_path, which supports the herdr-web-ui mechanism. Star counts of third-party repos and the 30-minute index interval were not checked. |

### Corrections

- Do not present #5289 as a modest 11%-of-a-core baseline. It is a bug report about the non-default HERDR_PROCESS_DETECTION=child-groups mode where server CPU rises to about 84% of a core with three idle agent panes; the 11% / 710 reads/s number is the control with the variable unset (Linux gVisor).
- Source size is about 289k lines under src/ (including inline tests), not about 178k.
- The HN 'Connecting the machines' thread (49612818) has 35 comments, not about 10; reaction to Cloud is mixed-to-negative, not uniform. 49104999 is a single comment, not a thread.
- The $6M seed is not in the YC post. The primary source is herdr.dev/blog/herdr-raised-a-seed (2026-09-08), led by Bessemer with YC, e2vc and named angels; cite that instead of a search snippet.
- The #5263 'production-branch merge' is the reporter's own statement; the repro was on integration v10 / manifest 2026.09.11.1, not the current v11 / 2026.10.11.1, and the issue is still open with no maintainer reply, so current-version behavior is unconfirmed.
- 'agent_blocked' protection only fires when the server already classifies the pane as blocked, so it inherits the screen-scraping blind spots; the prompt-effect gate (5 s observed working/blocked) runs after the input is sent, so it cannot prevent the keystrokes that #5263 describes.

### Missed by the report

- Herdr originally used hook-driven state for Claude Code and then moved away from it. CHANGELOG 0.6.7 (2026-06-03) added 'authoritative hook-driven state reporting'; a later release (line ~712 of CHANGELOG) made Claude Code, Codex, Copilot, Droid, Kimi and Qoder 'report session identity only'; claude_settings.rs HOOK_REMOVALS actively strips old PostToolUse/PostToolUseFailure/SubagentStop/PermissionRequest/UserPromptSubmit/PreToolUse/Stop/SessionEnd herdr hooks from users' ~/.claude settings. CHANGELOG entries around lines 745, 829, 856, 867, 1031 record stale-hook problems (stale blocked after permission prompt, delayed subagent/recap hooks reviving an idle pane, cancellations leaving stale 'working'). This is direct prior art for Loom's hook-driven design: the failure modes are stale state, subagent events being attributed to the parent, and cancellation without a closing event. The report implies hooks were never tried.
- herdr.dev/blog/ten-agents-three-clients-95-percent-less-cpu (2026-08-03): removing the sidebar spinner and skipping renders for hidden panes cut total CPU 89-95%; one working agent went from 1.467% to 0.133% CPU on Linux and 3.280% to 0.265% on macOS. Hidden panes still parse output so detection stays current. This is the product's own resource data and is more relevant than the #5289 numbers.
- A third detection tick, TICK_PENDING_RELEASE = 50 ms, exists in src/pane.rs:2853 alongside 300/500 ms.
- Herdr's Claude SessionStart hook silently exits unless python3, HERDR_ENV=1, HERDR_SOCKET_PATH and HERDR_PANE_ID are present, and skips subagent events (agent_id) and Cursor sessions; installed hook entry uses a matcher for startup|resume|clear|compact|fork. Relevant if Loom compares hook-delivery robustness (the report mentions #5348 but not the mechanism).
- The repo was previously github.com/ogulcancelik/herdr (HN 48714802 links it) and the project is a solo-founder-to-funded-company transition (the YC post: 'the only person behind Herdr' on 2026-08-06; $6M seed with hiring on 2026-09-08). Bus-factor and roadmap risk changed within about a month.
- Blog 'Coding agents are becoming runtimes' (herdr.dev/blog, 2026-06-10) argues for shared contracts for project instructions, lifecycle state and hooks between agent CLIs and terminal runtimes; relevant to Loom's reliance on Claude hooks as a contract. Not read by this check.
- Roadmap statements from the connecting-the-machines post: the agent CLI currently works within one server only (cross-machine agent discovery is future work), and moving agent sessions between machines is an exploratory idea.

## Sources

- https://github.com/herdrdev/herdr (cloned shallow at commit 143bf5f, 2026-10-16, to ~/Library/Caches/loom-v2-research/repos/herdr)
- https://github.com/herdrdev/herdr/blob/master/skills/herdr/SKILL.md
- https://github.com/herdrdev/herdr/blob/master/AGENTS.md
- https://github.com/herdrdev/herdr/blob/master/CHANGELOG.md
- https://github.com/herdrdev/herdr/issues/5263
- https://github.com/herdrdev/herdr/issues/5261
- https://github.com/herdrdev/herdr/issues/5348
- https://github.com/herdrdev/herdr/issues/5289
- https://github.com/herdrdev/herdr/issues/5221
- https://github.com/herdrdev/herdr/issues/4668
- https://github.com/herdrdev/herdr/issues/3467
- https://herdr.dev/docs/session-state/
- https://herdr.dev/docs/agents/
- https://herdr.dev/docs/agent-automation/
- https://herdr.dev/docs/socket-api/
- https://herdr.dev/docs/plugins/
- https://herdr.dev/docs/marketplace/
- https://herdr.dev/blog/herdr-is-joining-y-combinator/
- https://herdr.dev/blog/connecting-the-machines/
- https://herdr.dev/cloud/
- https://news.ycombinator.com/item?id=48756578
- https://news.ycombinator.com/item?id=48714802
- https://news.ycombinator.com/item?id=49104999
- https://news.ycombinator.com/item?id=49201003
- https://news.ycombinator.com/item?id=49612818
- https://news.ycombinator.com/item?id=49652188
- https://blog.debedb.com/2026/07/26/herdr-and-cmux-two-shapes-of-the-same-agent-multiplexer/
- https://flaviocopes.com/herdr-vs-cmux/
- https://www.developersdigest.tech/blog/herdr-deep-dive-agent-terminal-multiplexer
- https://www.reddit.com/r/ClaudeCode/comments/1v8lk76/herdr_cmux_tmux_are_they_really_that_helpful/
- https://github.com/devswha/herdr-web-ui
- https://github.com/persiyanov/herdr-reviewr
- https://github.com/eliasstravik/herdr-projects
