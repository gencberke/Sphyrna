# Paseo (getpaseo/paseo)

Research note for the Loom v2 brainstorm ([index](../V2-BRAINSTORM.md)). Written by a research subagent on 2026-10-17 and fact-checked by a second one; the fact-check is at the end and wins over the report where they differ. Raw JSON: `../evidence/deep-dive-20261017.json`.

**In one line:** Open-source (Apache-2.0 per package.json; license metadata is inconsistent across sources) daemon plus Electron/Expo/CLI clients that run Claude Code, Codex, OpenCode, Pi and ACP agents as structured chat sessions in worktree workspaces. Its edge is full-parity mobile and remote access, and the main cost is a heavy, ever-resident Node daemon.

**Category:** hybrid (chat-first for supported harnesses, with separate terminal tabs). Daemon/client architecture with desktop, mobile, web and CLI clients.

## Adoption

Repo created 2025-10-13. On 2026-10-17 GitHub shows 21,184 stars, 2,521 forks, 1,357 open issues, roughly 200 contributor logins, and a push the same morning (`gh api repos/getpaseo/paseo`).

Release cadence is very fast. v0.7.2 shipped 2026-09-02 (vibecodinghub review), v0.11.4 on 2026-10-15, and v0.12.0-beta.1 on 2026-10-16 (`gh release list`). There were 15.5k stars on 2026-08-31 (codeagentswarm) and about 16.4k in early September, so roughly 5k stars in 6 weeks.

Download counts are unreliable. Summed release-asset downloads are about 14.5M, but that includes electron-updater `latest-*.yml` fetches (`latest-mac.yml` alone has 135,984 hits on v0.11.4 within about 2 days). Real installer downloads are far lower (arm64 dmg 2,183, arm64 zip 8,181 for v0.11.4). Treat the updater hits only as a sign of a large active desktop base (inference).

Community presence:
- Show HN 2026-06-02 reached 92 points (https://news.ycombinator.com/item?id=48377250).
- It is repeatedly recommended in the OpenChamber thread (https://news.ycombinator.com/item?id=49233448).
- It has its own subreddit, r/PaseoAI, and a Discord.
- Sponsors include Hoplite.

## Architecture

**Stack.** A TypeScript monorepo (`/Users/gencberke/Library/Caches/loom-v2-research/repos/paseo`):
- `packages/server` is the Node daemon (WebSocket + HTTP, optional MCP).
- `packages/app` is an Expo/React Native client for iOS, Android and web. The desktop app is an Electron wrapper (`packages/desktop`) around the same web UI.
- `packages/cli` is a Commander CLI that speaks the same WS protocol.
- `packages/protocol` holds wire schemas, `packages/client` the SDK, and `packages/relay` the E2EE relay.
- An Elixir relay service lives in a separate repo.

**How it drives Claude: the Agent SDK, not a PTY.**
- `packages/server/src/server/agent/providers/claude/query.ts` imports `query` from `@anthropic-ai/claude-agent-sdk` (pinned 0.3.246 in `packages/server/package.json`). It overrides `spawnClaudeCodeProcess` to launch the user's installed `claude` binary with stdio pipes.
- `claude/agent.ts` (6,864 lines) `buildOptions` sets `includePartialMessages: true`, `permissionMode`, `canUseTool: this.handlePermissionRequest`, `resume: claudeSessionId`, `settingSources: CLAUDE_SETTING_SOURCES`, `pathToClaudeCodeExecutable` and SDK hooks (`buildSubagentEffortHooks`).
- Codex runs through `codex-app-server-agent.ts` (app-server JSON-RPC). Copilot, Cursor, Kimi and other agents go through ACP (`acp-agent.ts`, `generic-acp-agent.ts`). OpenCode and Pi have their own adapters.
- Paseo's docs claim it "extracts no tokens" (https://paseo.sh/alternatives/conductor). That holds for driving the agent. It does not hold for usage: `plugins/claude-usage-source/server/usage.ts` reads Claude Code's OAuth token from the macOS Keychain item `Claude Code-credentials` (via `security find-generic-password`) or the credentials file. It then calls `https://api.anthropic.com/api/oauth/usage` and `/api/oauth/profile` with `Authorization: Bearer` and an `anthropic-beta` header.

**Billing and policy exposure.** Anthropic announced a separate Agent SDK credit pool in May 2026, paused it on 2026-06-15, and on 2026-10-07 added monthly API credits to Max and Team plans while keeping SDK, `claude -p` and third-party app use on subscription limits (https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan).
- Paseo issue #1029 ("Claude provider roadmap after Agent SDK billing changes") had users propose a PTY/TUI path. One commenter described spawning interactive `claude` under a PTY and tailing `~/.claude/projects/<id>.jsonl` plus a `Stop` hook (pikiloom).
- The maintainer's answer on HN (id 48377250) was that the terminal exists for TUI use.
- Conductor's team said that users of its "Big Terminal Mode" were unaffected (Reddit r/conductorbuild 1tc96ym).

**State detection.**
- Chat agents use the SDK stream (turn events, `canUseTool` for permissions, `system` messages `task_started/task_updated/task_notification/task_progress` for subagents, handled in `claude/subagents/live-source.ts`, plus `sidechain-tracker.ts`). Lifecycle states are `initializing | idle | running | error | closed` (`shared/agent-lifecycle.ts`, `docs/agent-lifecycle.md`).
- Terminal sessions use opt-in hooks. `docs/terminal-activity.md`: with `daemon.enableTerminalAgentHooks` on (default false), Paseo writes marker-tagged hooks into `~/.claude/settings.json`, `~/.codex/hooks.json` and an OpenCode plugin. Claude mapping: `UserPromptSubmit` -> running; `Stop/StopFailure/SessionEnd` -> idle; `Notification(idle_prompt)` -> needs-input. The hook posts to a daemon endpoint through `paseo hooks <agent> <event>` using `PASEO_TERMINAL_ID` and a token. A bare Ctrl-C/Esc while working clears activity, because Claude does not fire `Stop` on interrupt.

**Persistence.**
- Agent records are JSON at `$PASEO_HOME/agents/{cwd-with-dashes}/{id}.json` (`agent-storage.ts`).
- Provider history is the durable transcript, and the timeline is rebuilt on resume. Timeline rows are runtime memory.
- The `closed` state keeps identity and resumes lazily through `ensureAgentLoaded()`.
- Idle agents stay resident indefinitely. Runtime closure happens only on archive, reload, workspace teardown or daemon shutdown (`docs/agent-lifecycle.md`). That means one provider child process per live agent.
- Desktop default `keepRunningAfterQuit: false` (`packages/desktop/src/settings/desktop-settings.ts`), so the daemon stops with the app. Headless `paseo` or Docker keeps the daemon running.
- Terminals are node-pty in a worker with a headless xterm for snapshots (`docs/terminal-performance.md`).

**Streaming and sync.**
- A leading+trailing coalescer batches at 60ms per agent (`agent-stream-coalescer.ts`). The client uses a frame-aligned reducer queue and a paced text reveal (`docs/agent-stream-performance.md`).
- Sync uses sequenced "directory" replicas with cursors, tombstones and a persisted replica cache (`docs/architecture.md`, `docs/timeline-sync.md`). Live streams are for immediacy, and an authoritative paged fetch is the source of truth.
- Mobile pairing is by QR code. The relay uses Curve25519 + NaCl box E2EE (`SECURITY.md`). The daemon can also be reached directly over LAN, Tailscale or SSH.

**Resource notes.** Strongly Node-heavy (daemon heap, plugin host processes, Electron renderer, a webview for the in-app browser). The open issues cited below show OOMs and idle CPU. The daemon logs `ws_runtime_metrics` every 30s including event-loop delay.

## Core loop

1. Open the desktop app. It starts or connects to the daemon. The sidebar shows projects, each with workspaces (local checkout or git worktree), each holding sessions as tabs: agent chats, terminals, diffs, files, browser.
2. Create a workspace (optionally a new worktree from a branch or PR), pick provider/model/mode/thinking (or a saved profile), and write the prompt in the composer. If the agent is busy, messages queue.
3. Glance at the sidebar: buckets are needs_input > failed > attention > running > done. Answer permission or question cards, or follow the subagents track above the composer.
4. When a turn finishes, open the Changes pane. Review the diff, leave line comments, and "Send feedback" to the agent without opening its chat. Run the app via worktree scripts and per-worktree `*.localhost` URLs, and check it in the built-in browser. Then commit, push, open a PR and watch checks from the app.
5. Away from the desk, the same workspace is reachable on the phone through the relay or Tailscale. Steer an agent, answer approvals, dictate by voice, or triage. Cron schedules and heartbeats keep recurring work going.
6. Power users let agents orchestrate: with "Enable Paseo tools" on, an agent calls MCP `create_agent` or `create_workspace`, and gets notified when the child finishes.

## Features

### Daemon/client split with multi-device access (remote-mobile, confidence high)

- **What the user sees:** The same agents, workspaces and terminals appear in the desktop app, the iOS/Android app, a browser (PWA/self-hosted web UI) and the CLI. Desktop starts its own daemon automatically. A headless daemon on a VPS or homelab (`npm i -g @getpaseo/cli; paseo`) shows up as just another host.
- **How it works:** `packages/server/src/server/bootstrap.ts` is the HTTP/WS server. `websocket-server.ts` does the hello handshake and keeps a per-socket application ping lease: clients ping every 10s and the daemon terminates a socket whose lease expires, with an 8 MiB outbound high-water mark. Sessions can hold several physical sockets. Reconnect and resume use sequenced directory replicas (per-entity cursors and tombstones) and paged authoritative timeline fetches (`docs/architecture.md`, `docs/timeline-sync.md`). Relay pairing is a QR code carrying the daemon public key in the URL fragment, then ECDH + NaCl box (`SECURITY.md`). The permission model is semantic grants (`docs/permissions.md`). Direct connection is allowed over TCP, Tailscale or SSH.
- **Reception:** This is the main reason people switch. One user said the mobile app is out and has near feature parity with desktop and that they had been waiting on Superset's mobile app (HN 49234056). Another said only Paseo and OpenChamber handle mobile terminal scrolling well. Complaints: Android CPU burn from the working-indicator animation (~125% of a core, issue #4634), typing slows as more sessions load on mobile (#4809), an Android OOM with many sessions (#4408), and a half-working iOS update flow (r/PaseoAI). The maintainer frames mobile as 'step away without losing the work' (steering, triage on walks), not working all day on the phone (HN 48377250).
- **Evidence:** https://github.com/getpaseo/paseo/blob/main/docs/architecture.md; https://github.com/getpaseo/paseo/blob/main/SECURITY.md; HN https://news.ycombinator.com/item?id=49233448 : a user runs Paseo on a homelab and opens the same sessions from a MacBook and an iPhone; HN https://news.ycombinator.com/item?id=49234056 : switched from Conductor then Superset mainly for the mobile app plus a Hetzner VPS

### Structured chat UI over the Claude Agent SDK (approvals, question cards, plan mode, rewind, import) (chat-input, confidence high)

- **What the user sees:** A native chat timeline with tool-call cards, permission and question cards, mode selector (default/plan/bypass), model/thinking controls, context meter, slash-command autocomplete, rewind of conversation and files, and an 'import session' flow that lists recent Claude/Codex sessions so a session begun in a terminal can continue as a chat.
- **How it works:** `claude/agent.ts` runs `query()` with `canUseTool` -> `handlePermissionRequest` (L4969) feeding `getPendingPermissions/respondToPermission` (`agent-sdk-types.ts`). Rewind: `claude/rewind.ts` uses SDK `forkSession(upToMessageId)` over a custom `SessionStore` rooted at the transcript folder, plus `query.rewindFiles(messageId)` for file checkpoints. Import: `import-sessions.ts` + `listImportableSessions` scan Claude transcripts, and the new agent resumes via `resume: sessionId`. Because the session is Claude's own JSONL, a terminal-run session and a Paseo chat session share storage but are not live-bridged.
- **Reception:** Praised as smooth and 'light and purposeful' (r/PaseoAI 1wv7z99). Fidelity gaps versus the TUI show up as ongoing fixes: question-card answers, blank list items, import titles, context-meter bugs on `[1m]` models. The maintainer admits subscription use goes through programmatic pools in the June thread; this was later paused by Anthropic. A structural risk remains because billing and ToS posture depend on the SDK path (issue #1029). One HN critic found the visual design plain default Tailwind ('beautiful' is overclaimed).
- **Evidence:** /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/agent/providers/claude/agent.ts (buildOptions ~L3501-3570, handlePermissionRequest L4969); /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/agent/providers/claude/rewind.ts; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/agent/import-sessions.ts; Reddit https://www.reddit.com/r/opencodeCLI/comments/1sm6ru4/openchamber_vs_paseo/ : a user says Claude support lacks plan-mode display for imported plan sessions, a step down from the CLI; CHANGELOG 0.12.0-beta.1: option previews on Claude question cards

### Terminals as separate tabs, with opt-in hook-based agent status (the TUI escape hatch) (attention-status, confidence high)

- **What the user sees:** You can open a terminal tab and run `claude` yourself, on desktop, web or mobile. If 'Enable terminal agent hooks' is on, the tab shows a running/needs-input/finished dot and fires 'Terminal finished' notifications like any agent. It is NOT the same session as a chat agent: there is no toggle to flip one live session between chat and terminal views.
- **How it works:** `TerminalActivityTracker` is a per-terminal state machine ({state, changedAt}, null by default) with transitions that carry `previous`. The daemon injects `PASEO_TERMINAL_ID`, `PASEO_ACTIVITY_TOKEN`, `PASEO_TERMINAL_ACTIVITY_URL` and `PASEO_HOOK_CLI`. Marker-tagged hooks installed in `~/.claude/settings.json` run `paseo hooks claude <event>`, which silently POSTs to `/api/terminal-activity`; failures are no-ops so a hook never breaks the user's session. Clients send heartbeats with the focused terminal id so the daemon clears attention only when a visible client has focused it. The terminal pipeline is node-pty in a worker -> headless xterm -> 5ms coalescer -> binary WS frames, with the PTY size owned by the last-interacting client.
- **Reception:** The maintainer points TUI-preferring users here (HN 48377250), but users say it gives up Paseo's best features (orchestration MCP tools and chat UI work only on SDK agents; issue #1029 comments). A Reddit user complains terminal rendering feels sluggish (r/PaseoAI 1wv7z99; xterm.js in a webview), and Conductor users made the same complaint about its terminal (r/conductorbuild 1tc96ym).
- **Evidence:** /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/terminal-activity.md; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/terminal-performance.md; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/public-docs/claude-code.md ('Use Claude Code in the Paseo terminal'); GitHub issue getpaseo/paseo#1029 comments: users suggest the terminal profile as the ToS-safe route; Brief's claim of 'chat vs terminal view switching for the same session' is UNVERIFIED: no such feature found in docs/ or packages/server/src/server/agent/ (searched).

### Sidebar attention buckets with project roll-up (attention-status, confidence high)

- **What the user sees:** Each workspace row shows one of needs_input, failed, attention (finished unseen), running or done. Collapsed project rows show the most urgent child state. Subagent pills above the composer segment by the same states.
- **How it works:** `packages/app/src/utils/sidebar-agent-state.ts` defines `SidebarStateBucket`, with a roll-up priority (`needs_input`, `failed`, `running`, `attention`, `done`) deliberately different from the flat list order (`needs_input`, `failed`, `attention`, `running`, `done`): a collapsed project keeps showing the spinner for actively working children. `deriveAgentStateBucket` in `@getpaseo/protocol/agent-state-bucket` is shared by all clients. Attention is cleared by a focused, visible client's heartbeat.
- **Reception:** Not discussed by users in sources found. The failure mode users do report is a row stuck 'running' (see anti-patterns, issues #5951, #6355, #6547).
- **Evidence:** /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/app/src/utils/sidebar-agent-state.ts; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/terminal-activity.md (focus heartbeat clears attention)

### Orchestration: agents launching agents, subagents track, profiles, CLI mirror (orchestration, confidence high)

- **What the user sees:** With 'Enable Paseo tools' on (default off), an agent can create workspaces and worktrees, launch other agents (any provider), message them, and wait. The children show in a Subagents track by the composer and the parent is notified when they finish or ask for permission. Saved agent profiles carry 'When to use' notes so an orchestrator picks the right model/mode. The CLI mirrors everything (`paseo run/ls/send/attach/wait/permit`).
- **How it works:** Transport-neutral tool catalog in `packages/server/src/server/agent/tools/`, with `mcp-server.ts` as a thin MCP adapter. Agent-scoped `create_agent` always stamps label `paseo.parent-agent-id`; `notifyOnFinish` defaults true. Children are archived with the parent unless they sit in another workspace or are open in a tab (tab-open labels per client), and the user can detach one manually. Provider-native subagents are surfaced the same way (Claude via `task_*` system messages in `claude/subagents/live-source.ts`; Pi/OMP via adapters). Creation is journaled with idempotency keys (`server/creation/`).
- **Reception:** This is a headline differentiator for multi-agent users, and the Reddit poster who runs a Claude orchestrator with Kimi/GLM/MiniMax workers says it 5x'd their workflow (r/PaseoAI 1wv7z99). Costs: stuck 'running' child cards (Pi subagents #6547, phantom Claude subagent row #5749) and wedged cancel paths (#6355).
- **Evidence:** /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/agent-lifecycle.md; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/public-docs/orchestration.md; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/agent/providers/claude/subagents/live-source.ts; CHANGELOG 0.12.0-beta.1: sender's name added to inter-agent messages; parent not told 'finished' when a child was merely stopped

### Diff review that talks back to the agent, plus in-app PR flow and browser (review-git, confidence high)

- **What the user sees:** A Changes pane (uncommitted and committed diffs, staged/discard), line comments, and a 'Send feedback' button that delivers review comments to the agent without opening its chat (added in 0.12.0-beta.1). Commit, push, open PR, watch checks and reviews, and merge from the app (GitHub, GitLab, Gitea, Forgejo). A built-in browser tab has an element picker and agent-callable browser tools.
- **How it works:** Daemon owns git: `checkout_status_update/checkout_diff_update` and a `checkout_*` RPC family, with a limiter and metrics in `ws_runtime_metrics`. The daemon's project Git observer keeps one non-recursive watch per active root on `.git` plus a slow rescan fallback (`docs/architecture.md`), avoiding a recursive watcher. Client: `packages/app/src/review/` (`store.ts`, `feedback/`). The browser is an Electron `<webview>` with a shared persistent session (`docs/architecture.md`, 'In-app browser').
- **Reception:** Many 2026 fixes are in diff correctness (renamed files, quoted filenames, `--` SQL comment lines, custom git diff configs), which shows how much work a diff view costs to get right.
- **Evidence:** /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/CHANGELOG.md (0.12.0-beta.1: 'Send feedback button to the diff pane'); /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/app/src/review/feedback/; HN https://news.ycombinator.com/item?id=49233448 : a reply says Paseo also has Orca's select-element-and-comment browser flow; Issue #6943: parked in-app browser tabs keep rendering and peg the GPU on macOS

### Workspace model: project -> workspace (local or worktree) -> sessions, with per-worktree service URLs (parallel-worktrees, confidence high)

- **What the user sees:** 'Organized around workspaces, not chats.' A workspace holds agent chats, terminals, files and diffs as tabs. Isolation is 'local' (existing checkout) or 'worktree' (managed git worktree removed when its last workspace is archived). `paseo.json` scripts of type service get stable hostnames like `web--fix-auth--my-app.localhost` so parallel dev servers never collide on ports. Background workspaces are hidden by default.
- **How it works:** `docs/service-proxy.md`: a daemon HTTP proxy routes by Host header `<script>--<branch>--<project>.localhost` (63-char label truncation with a hash), with IPv4/IPv6 loopback selection. Workspace identity is daemon-global (opaque workspace ids, not cwd); agent creation reuses the workspace unless a new one is requested. `workspace.background` is a discovery-only flag with separate cursor scopes.
- **Reception:** Cited as reasons to prefer it over Conductor ('everything I wanted from Conductor plus open source', r/conductorbuild 1vvbak0). The 0.12 beta adds a hidden-by-default 'background' tier to tame sidebar clutter, which suggests clutter is a real problem.
- **Evidence:** /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/public-docs/workspaces.md; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/service-proxy.md; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/agent-lifecycle.md (Background workspaces)

### Composer: queued messages, steering, drafts, voice, fullscreen on phones (chat-input, confidence medium)

- **What the user sees:** Type while the agent is running and the message queues (sent when the turn ends) or steers the active turn where the provider supports it. Per-agent drafts, attachments (images, files, forge issues and PRs), a task-list dock, local dictation and realtime voice, and a fullscreen composer on phones.
- **How it works:** `packages/app/src/composer/submit.ts` returns `AgentInputSubmitResult = noop | queued | submitted | failed`; queue state lives in `composer/actions.ts` (`QueuedComposerMessage`, `queueComposerMessage`). Daemon-side `AgentSession.steerActiveTurn?` is an optional provider capability (`agent-sdk-types.ts`). Dictation and voice use local STT/TTS workers by default (the voice process leaked ~5 GB in issue #4774).
- **Reception:** A Reddit user says voice with Parakeet lets them talk to agents while driving (r/PaseoAI 1wv7z99). The client queue is in app memory by agent id (inference from `QueueWriter` using a `Map` keyed by agent id), so queued messages are not daemon-durable; verify before copying.
- **Evidence:** /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/app/src/composer/submit.ts; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/app/src/composer/actions.ts; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/CHANGELOG.md (fullscreen composer, option previews)

### Plan-usage and context meters (Claude, Codex, others) via usage-source plugins (usage-cost, confidence high)

- **What the user sees:** Account quota windows (5-hour/7-day), balances and reset times per provider in a sidebar item and modal, `paseo usage` in the CLI, and a per-session context meter. The maintainer said 5h/7d usage was a 'very requested feature' (HN 48377250).
- **How it works:** A `UsageSourceRegistry` (`packages/server/src/server/plugins/usage-sources/index.ts`) caches reports for 5 minutes (`ttlMs = 300_000`), with a 20s deadline and in-flight de-duplication. Each provider is a plugin (`plugins/claude-usage-source`, `codex-usage-source`, and others). The Claude plugin reads the Keychain/credentials-file OAuth token and calls `api.anthropic.com/api/oauth/usage` itself. The harness owns token refresh. Context usage comes from the SDK stream (`usage_updated` events).
- **Reception:** Wanted by users. The credential read is a policy-risk surface that Loom avoids by using the CLI's own `get_usage` control request; several context-meter bugs (1M vs 200k, proxy-reported input tokens) show how fragile SDK-derived numbers are.
- **Evidence:** /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/plugins/claude-usage-source/server/usage.ts (L306 `security`, L537 oauth/usage fetch); /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/plugins/usage-sources/index.ts; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/CHANGELOG.md (`paseo usage`)

### Fork context (copy a session into a new one) and in-chat search (context-knowledge, confidence high)

- **What the user sees:** A fork menu on an assistant turn: 'Fork in a new tab' or 'Fork in a new workspace'. It starts a NEW agent seeded with a curated copy of the chat history up to that turn (or up to now, mid-run). It is not a side thread and it does not branch the provider session. There is also in-chat find and an outline that jumps between prompts.
- **How it works:** `agent.fork_context` RPC (gated by the host feature `agentForkContext`). `selectForkContextRows` in `packages/server/src/server/agent/activity-curator.ts` projects timeline rows. The history rides along as a `chat_history` composer attachment on the draft (`docs/glossary.md`, 'Fork'). Search runs in `agent/chat-search/index.ts` over assistant and user text only, not tools, reasoning or todos.
- **Reception:** Not found in user discussions. It is the closest thing Paseo has to a side chat, but it copies context and costs a full new session; the user's 'side thread that does not pollute the main thread' wish is NOT met.
- **Evidence:** /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/glossary.md (Fork entry); /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/agent/chat-search/index.ts

### Plugins that add UI and providers across desktop and mobile (other, confidence medium)

- **What the user sees:** `paseo plugin add owner/slug` adds screens, sidebar items, workspace panels, Command Center items, slash commands, composer pills, themes or whole providers, and the same plugin shows on iOS/Android. A registry exists at paseo.sh/plugins and paseo.cafe. Users report writing pgweb, an embedded VS Code and a git GUI plugin (r/PaseoAI).
- **How it works:** Plugins run as daemon-side subprocesses (`packages/server/src/server/plugins/`) with a host-owned IPC transport and the same `PaseoApi` facade as the SDK. Client-side components render in connected clients. Bundled plugins include antigravity-provider, muse-provider and the usage sources.
- **Reception:** Power users love it; it is also where many of the resource complaints sit.
- **Evidence:** /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/plugins.md; /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/plugins/; Issues #5242 (a node and helper process per plugin at launch), #4560 (plugin host memory growth), #7199 (event-loop delay climbs until plugin hook RPCs time out)

## UX patterns worth borrowing

- Workspace-not-chat framing: project -> workspace (local checkout or worktree) -> sessions as tabs. A task's agent, terminal, diff and browser live together.
- One status vocabulary shared by every client (needs_input, failed, attention, running, done), with a roll-up priority for collapsed groups that differs from the flat list order (a project with a running child keeps its spinner).
- Attention is cleared only by a focused, visible client heartbeat, not by merely rendering. This is the right definition of 'viewed' across several devices.
- Subagents track pinned next to the composer, with state-segmented pills, instead of a side panel. On phones, subagents and files open in a closable sheet with 'Open as tab'.
- Diff comments are sent straight to the agent from the review pane (no need to open its chat).
- Fork menu in the assistant-turn footer, sitting beside the copy button, with a mid-run variant.
- Command Center (palette) plus per-tab splits (Cmd+D / Cmd+Shift+D) and workspace jump shortcuts. Shortcut recording is layout-aware (Dvorak/non-Latin fixed in the 0.12 beta).
- Paced text reveal: arrival sets a target and a frame-aligned reveal catches up smoothly. The store keeps the full text so copy and search are exact.
- Mobile phone layout: floating header, New agent / New terminal inside the tab switcher, workspace scripts under the overflow menu, fullscreen composer, tap-feedback fixes. Settings become large tiles grouped into App and Host.
- Archive is soft and global; History view for archived agents. Background workspaces are hidden unless 'Show background' is on.

## Anti-patterns

- Keeping every agent's runtime resident indefinitely plus holding timelines in memory. Issues: daemon OOM at ~880 agents / 162k timeline items (#6669, #6522), renderer keeps every opened agent's timeline in memory and archiving does not release it (#6477), launch spawns many processes and memory before any agent runs (#5242), the stored sidebar order never shrinks (#7060). Loom's 'no live process for idle records' is the opposite of this.
- Reading whole transcripts into memory: listing recent Claude sessions `readFile`s multi-hundred-MB JSONLs and split-lines them (#6669, #5820, #6175). Any Loom transcript reader must stay bounded and streaming.
- A persisted `running` status without a live runtime that survives restarts, cancel that awaits a promise with no timeout, and finalized-turn bookkeeping that drops the real terminal event. Users see rows stuck on 'N running' that can't be stopped, archived or deleted (#5951 on Codex, #6355, #3256, #6547, #5749). Loom's rule that status is a verified outcome is the antidote: reconcile at launch from the registry and check the PID or process.
- A whole-view repaint for a tiny animation (working-indicator drives ~125% of a core on Android, #4634; parked browser tabs peg the GPU, #6943). Nothing drawn when hidden is a real constraint.
- Driving a vendor's SDK for the main chat path makes billing and ToS exposure a recurring crisis (#1029; Anthropic's May announcement and the June pause). Also, the usage plugin reads the vendor's OAuth token from the Keychain and calls an undocumented-style endpoint, which is exactly the thing users fear.
- Feature sprawl on a single Node runtime: voice workers (a ~5 GB leak, #4774), ten provider adapters, plugin host processes per plugin, an Electron webview browser, Docker and web UI. 1,357 open issues and a contribution policy of 'bugs only in Issues' (the bot's reply on #1029) reflect the maintenance load.
- Marketing/licensing drift (docs said AGPL-3.0, package.json and README say Apache-2.0, GitHub reports NOASSERTION), and an HN critic's 'beautiful' vs default Tailwind look. Overclaiming costs trust.
- Terminals in a webview (xterm.js) are felt as sluggish by users (r/PaseoAI 1wv7z99), which is an opening for Loom's native Core Graphics renderer.

## Ideas for Loom

### Chat lens on the real CLI session: a toggle on the same live PTY session that shows a native chat rendering (messages, tool cards, subagent cards, approval boxes) built from the incremental transcript JSONL plus hook events that Loom already reads, with a composer that types into the same PTY. Terminal and chat are two views of one process, which Paseo does not offer. It does not use the Agent SDK, so billing and ToS posture is identical to the plain CLI. (cost XL)

- **Inspired by:** Paseo's SDK-driven chat timeline and its split between chat agents and terminal tabs; issue #1029 (users asking for exactly a PTY-plus-transcript-tail driver); Loom's own read-only subagent transcript panel.
- **Gain:** Faster reading of long sessions (collapsible tool calls, jumpable prompts, search within a session), phone-ready data model later, and a way to answer approvals and questions without the TUI. This answers the user's 'chat-centred UI' openness while keeping the real CLI as the source of truth.
- **Fit:** Fits: documented interfaces (transcript JSONL, hooks), no polling (FSEvents), nothing drawn when the chat lens is hidden, bounded tail reads, process ownership unchanged. Conflicts: the contract rule 'never replace the CLI's interface' (the user said they are open), and drift risk if transcript shapes change, so detect unknown record types and show them raw instead of faking success. Input injection into the PTY must be gated on a verified idle or waiting state, never fire-and-forget. A lighter first step is a read-only chat lens with no composer.
- **Risks:** Transcript format drift; mapping permission prompts to hook events can race with the TUI; users may type in both views; rendering long markdown while streaming costs CPU (copy Paseo's pacing idea only if profiling shows a need).

### Real side chat via fork: 'Side chat' opens a second PTY running `claude --resume <id> --fork-session` (verify the exact flag against the installed CLI help and run drift detection) in a right-hand panel, labelled as a child of the main session, with its own run scope, auto-stopped when the panel closes or the main session ends. Optionally a 'send summary back' action that pastes a one-line result into the main composer on the user's click. (cost M)

- **Inspired by:** Paseo's fork menu in the assistant-turn footer (`agent.fork_context`), which is a copy-into-a-new-session rather than a side thread; the user's long-standing side-chat wish.
- **Gain:** Ask clarifying questions or explore an alternative without polluting the main thread or interrupting a running turn. Paseo cannot do this, so it would be a real differentiator.
- **Fit:** Fits: uses a CLI-native fork feature (documented, version-independent if detected), process ownership through the existing run scope, zero cost when closed (no live process when idle; reuse the ended-screen snapshot). Conflict: a fork re-reads the context (cost, cache warm-up), so show a context-size hint and never auto-open. Fork from a user-chosen turn only after confirming the CLI supports it.
- **Risks:** The CLI flag may change or be absent; two live sessions double usage; the forked session shows up as another record in the registry and must be grouped under its parent, not as a new sibling card.

### Composer with a verified queue: a small input that lets the user write the next instruction while a turn is running and sends it into the PTY exactly when the hooks report Stop / waiting-for-input. The card shows 'queued' then 'delivered' only after Loom sees the prompt in the transcript. Also keep drafts per session. (cost M)

- **Inspired by:** Paseo's `AgentInputSubmitResult = noop | queued | submitted | failed` composer queue (`packages/app/src/composer/submit.ts`).
- **Gain:** Removes the 'wait, then retype' loop for users running 3-5 sessions: queue a follow-up and move on.
- **Fit:** Fits fluency and verified outcomes: 'delivered' is confirmed against the transcript, not assumed. Conflict: Paseo's queue lives only in client memory; Loom should persist it (small file per session) and drop or confirm it when a session is stopped or deleted, so a restart never double-sends. Delivery must stay under the user's authority (no auto-send of prompts written by agents).
- **Risks:** Typing into a TUI that is in a modal state (permission prompt, plan approval) can corrupt input, so only deliver when the registry state is idle or waiting and bracket-paste the text.

### Review-and-send-back: a read-only 'Changes' pane per session or project (git diff on demand, not watched), with line comments that become one structured message queued to the session. No staging, committing or PR UI in the first version. (cost L)

- **Inspired by:** Paseo's Changes pane and 'Send feedback' button (0.12.0-beta.1), and its Git observer that watches only `.git` at the root with a slow rescan.
- **Gain:** This is the biggest gap named in Loom's backlog; the user reviews agent edits constantly and today must leave Loom to do it. Comments that go straight back to the right session close the loop.
- **Fit:** Fits if built on demand (run `git diff` when the pane opens or on a Stop hook, with bounded output and virtualized rendering) and as a lens, not an editor. Conflict: Paseo's long list of diff-correctness fixes (renames, quoting, `--` lines, custom diff configs) shows the parsing is deceptively hard. Use `git diff --no-ext-diff --no-color -z`-style plumbing and cap file sizes, and do not build a watcher.
- **Risks:** Diff rendering cost for huge generated files; scope creep toward commit/PR/CI; keep those as separate later decisions.

### Read-and-approve remote on the same Loom authenticated socket: a minimal web page served by Loom only when enabled and bound to loopback, reached over the user's own Tailscale or SSH tunnel with a paired token. It shows the needs-you list, session state and last message, and has Approve/Deny and 'send one line' buttons. There is no native iOS app, no Loom-run relay, and no daemon that survives Quit. (cost L)

- **Inspired by:** Paseo's phone-as-control-surface workflow (HN 49234056 and 48377250, QR pairing, E2EE relay); the maintainer's 'step away from the desk without losing the work' framing.
- **Gain:** Unblocks a session waiting for approval while away from the Mac, which is the main mobile value users cite. Matches how the user already works with several waiting sessions.
- **Fit:** Partly conflicts. Loom's Quit stops all sessions and the Mac must stay awake and running, so the remote only works while Loom runs, which is acceptable and honest. Cross-session actions only under the user's authority: approvals come from the user's own device after pairing, with a per-action log. Lighter variant: push notifications with the approval text only, plus the web page on demand. The phone path is where Paseo's resource and security surface (relay, passwords, loopback exposure) grows, so start with the smallest authenticated surface.
- **Risks:** Security exposure of a local control surface; keep-awake and battery cost; support burden of the phone UX that Paseo's team spends most of its time on.

### Parent/child links and finish notifications for 'a session opens a session': extend the existing loom:open-session flow so the opened session records its parent, shows nested under it in the sidebar, and (only when the user approved the open) sends one 'child finished / needs you' event back to the parent's card, not a prompt into the parent's PTY. (cost M)

- **Inspired by:** Paseo's `paseo.parent-agent-id` label, `notifyOnFinish`, the Subagents track and detach gesture (`docs/agent-lifecycle.md`).
- **Gain:** Multi-agent workflows (a planner opening workers) become legible: one tree, one attention signal, and cascade-stop when the user chooses.
- **Fit:** Fits: it builds on Loom's authenticated socket and user approval, and the parent notification is a UI signal rather than silent cross-session text injection (cross-session messaging stays 'planned, user-authorized only'). Detach and cascade-stop must be explicit user gestures (Paseo cascades archive by default, which Loom should not copy).
- **Risks:** Stale parent links after deletion; orphan handling; an agent could try to spam open requests, so rate-limit the approval prompt.

### Adopt Paseo's two small attention rules in Loom's sidebar: (1) a collapsed project row shows the roll-up with priority needs-you > failed > working > finished-unviewed (so an active project keeps its animation); (2) 'viewed' is cleared only when the session pane is visible and focused, not merely rendered. Add 'reconcile stale Working at launch from the registry and a PID check' as an explicit test case. (cost S)

- **Inspired by:** `packages/app/src/utils/sidebar-agent-state.ts` roll-up priority and focus-heartbeat attention clearing in `docs/terminal-activity.md`; the stuck-running issues (#5951, #6355).
- **Gain:** Fewer false 'blue' dots and a trustworthy collapsed view when many projects are open.
- **Fit:** Fits fully; it is UI logic on existing state with no new IO. Check what Loom already does before building.
- **Risks:** None significant; verify against Loom's current definition of 'unviewed'.

### Do not copy: always-resident runtimes, in-memory timelines, an Electron-style plugin host, a per-worktree HTTP service proxy and the voice stack. If worktrees come, add them as Loom-owned `git worktree add` plus a project-level 'new session in worktree' action with colours/branch chips (Loom already shows branch), and leave dev-server routing to the user's own tooling. (cost M)

- **Inspired by:** Paseo's workspace model (`public-docs/workspaces.md`) and its heavy-runtime issues (#6669, #6477, #5242, #4560).
- **Gain:** Parallel same-repo sessions without file collisions, which the user's two work projects with ticket keys need, without taking on a daemon-class resource budget.
- **Fit:** Worktree management fits if each worktree is a plain directory tied to a session record and removed only by an explicit verified delete (git is the source of truth). Conflict with 'predictable behavior': Paseo auto-removes a managed worktree when its last workspace archives, and Loom should ask or show a dry run like its permanent-delete flow.
- **Risks:** Orphaned worktrees and branches; deleting an agent's unpushed work. Needs a dry-run listing of uncommitted changes before any removal.

## Fact-check

| Claim | Verdict | Note |
| --- | --- | --- |
| Drives Claude via Agent SDK (query + spawnClaudeCodeProcess override), SDK pinned 0.3.246, not a PTY | confirmed | query.ts line 2 imports query from @anthropic-ai/claude-agent-sdk; applyRuntimeSettingsToClaudeOptions overrides spawnClaudeCodeProcess and spawns with stdio [pipe,pipe,pipe]. packages/server/package.json line 108 pins 0.3.246. agent.ts (6864 lines) base options near L3530-3570 include includePartialMessages:true, canUseTool: this.handlePermissionRequest (handler at L4969), pathToClaudeCodeExecutable, settingSources, enableFileCheckpointing, perTaskStopAffordance, hooks. public-docs/claude-code.md says 'through the official claude CLI using the Claude Agent SDK'. I did not read the SDK internals, so the exact CLI flags (stream-json) are inferred, not verified. |
| No same-session chat/terminal toggle; terminals are separate tabs; hook mapping UserPromptSubmit->running, Stop/StopFailure/SessionEnd->idle, Notification idle_prompt->needs-input; opt-in default false; written to ~/.claude/settings.json | confirmed | docs/terminal-activity.md states each mapping, daemon.enableTerminalAgentHooks defaults false, hook command is '[ -n "$PASEO_TERMINAL_ID" ] && "${PASEO_HOOK_CLI:-paseo}" hooks claude <event>'. Doc also says Claude does not run Stop on interrupt and that Paseo falls back to treating a lone Ctrl-C/Esc as clearing activity (Paseo's own claim about Claude, not independently tested). The no-toggle claim is an absence claim; no counterexample found in docs, code not exhaustively searched. |
| Anthropic Agent SDK billing change paused 2026-06-15; 2026-10-07 Max/Team got monthly API credits; SDK, claude -p and third-party apps still draw subscription limits | confirmed | Fetched support.claude.com/en/articles/15036540 (published 2026-10-07): 'Update October 7, 2026: Max and Team plans now include monthly API credits, which cover the Claude Agent SDK, claude -p, the Claude API, and Claude Managed Agents. You can still use the Claude Agent SDK, claude -p, and third-party apps with your subscription limits.' and 'Update June 15, 2026: paused... nothing has changed'. The May announcement itself is only visible indirectly (issue #1029 body and the maintainer's HN reply). |
| Issue #1029 had users propose PTY/TUI route; pikiloom comment describes PTY + transcript JSONL tail + Stop hook; maintainer HN answer says terminal exists for TUI | confirmed | gh api issues/1029: opened 2026-05-14, closed 2026-07-30 as completed by paseo-bot (redirected to Discussions; 'GitHub Issues are only for bugs'). Comments: maxwhipw suggests forwarding TUI; pppwaw suggests terminal profile; xiaotonng (pikiloom author, a self-promotional comment) describes PTY + ~/.claude/projects/<id>.jsonl tail + Stop hook on 2026-06-15. HN 48377250, maintainer 'boudra': Claude Code via subscription will 'consume a different pool of credits', 'Paseo has a terminal if you want to keep using the TUI inside of it', 'I will keep supporting the Claude Code harness'. Note the pikiloom commenter is promoting his own product, and the m13v comment is a drive-by; weigh as anecdotal. wangfh5 on 2026-06-16 reports Anthropic email that the change was paused. |
| Paseo 'extracts no tokens' holds for driving but not for usage: claude-usage-source reads Keychain item 'Claude Code-credentials' via security, calls api.anthropic.com/api/oauth/usage and /oauth/profile with anthropic-beta header; 5 min cache | confirmed | plugins/claude-usage-source/server/usage.ts: L26 CLAUDE_KEYCHAIN_SERVICE='Claude Code-credentials', L306 execFileAsync('security',...), L350 .credentials.json fallback, L537 fetch oauth/usage with anthropic-beta CLAUDE_OAUTH_BETA, L669 oauth/profile. usage-sources/index.ts: ttlMs=300_000, deadlineMs=20_000. paseo.sh/alternatives/conductor does say 'Neither extracts tokens or proxies model calls' (wording is about the two tools launching CLIs with the user's credentials). The 'undocumented-style endpoint' characterization is the report's inference; I did not check whether the endpoint is documented by Anthropic. |
| Adoption snapshot: 21,184 stars, 2,521 forks, 1,357 open issues, created 2025-10-13; v0.11.4 on 2026-10-15, v0.12.0-beta.1 on 2026-10-16 | confirmed | gh api now: 21,185 stars, 2,522 forks, 1,360 open_issues_count (counts PRs too, see below), created 2025-10-13T12:27:02Z, pushed 2026-10-17T10:55Z, license NOASSERTION. gh release list: v0.12.0-beta.1 2026-10-16T19:57Z, v0.11.4 2026-10-15T18:53Z (Latest). v0.7.2 published 2026-09-02. latest-mac.yml on v0.11.4 shows 137,058 downloads (report said 135,984 earlier, consistent); arm64 dmg 2,193, arm64 zip 8,195. |
| 1,357 open issues is an issues-only count | partly | GitHub's open_issues_count includes open pull requests. The true open-issue count is lower by the number of open PRs; the report uses it as a maintenance-load signal in anti_patterns. Treat as an upper bound. |
| License is Apache-2.0 (package.json) with inconsistent metadata | confirmed | package.json license Apache-2.0; LICENSE file opens 'Portions of this software are licensed as follows: ... Except for third-party components, Paseo is licensed under Apache License 2.0'; GitHub API reports NOASSERTION/Other (due to the preamble). The 'docs said AGPL-3.0' piece is unchecked. |
| Idle agents stay resident indefinitely; one provider child per live agent; closed state resumes via ensureAgentLoaded | confirmed | docs/agent-lifecycle.md: 'Idle agents remain resident indefinitely. Runtime closure happens only through an explicit lifecycle action such as archive, replacement, reload, workspace teardown, or daemon shutdown.' and 'closed' is persisted resumable state resumed through ensureAgentLoaded(). The 'one child per live agent' is consistent with the spawn-per-query design but I did not count processes. Lifecycle states initializing/idle/running/error/closed confirmed in packages/protocol/src/agent-lifecycle.ts (NOT shared/agent-lifecycle.ts as the report cites; that path does not exist). |
| Issue numbers and titles for resource and stuck-running claims (#4634, #5242, #5951, #6355, #6477, #6547, #6669, #6943, #4774, #4809, #4408, #5749, #7060, #5820, #6175, #3256, #6522, #7199, #4560) | confirmed | gh issue view: all exist with titles matching the report's description. States: #5951, #6355, #6477, #6669, #6943, #4774, #4809, #4408, #7060, #5820, #6175, #3256, #6522, #7199, #4560, #4634, #5242 OPEN; #6547 and #5749 CLOSED (the report lists them as pain examples without saying they were fixed). #6669 title: 'Daemon OOM (4 GB heap) shortly after fetch_recent_provider_sessions_request - Claude session listing reads whole transcripts into memory'. The '~880 agents / 162k timeline items' figure was not checked in the issue body. |
| Desktop default keepRunningAfterQuit:false so the daemon stops with the app | partly | keepRunningAfterQuit: false appears in packages/desktop/src/settings/desktop-settings.test.ts (default fixtures); I did not open desktop-settings.ts itself in the final pass, so the default is supported by test fixtures rather than the source definition. |
| Sidebar bucket flat order needs_input > failed > attention > running > done, roll-up order needs_input > failed > running > attention > done | confirmed | packages/app/src/utils/sidebar-agent-state.ts: SidebarStateBucket type and comment at ~L21 'so running outranks attention here. needs_input and failed still win over both'. Matches the report. |
| Fork is copy of curated chat history into a new agent, not a provider-session branch (agent.fork_context, agentForkContext) | confirmed | docs/glossary.md Fork entry: 'the fork does not resume or branch the provider-side session, and the source session keeps running untouched'; two targets (new tab, new workspace), mid-run variant with no boundary. fork_context referenced in websocket-server.ts and use-fork-agent.ts. |
| Composer queue is client-memory only, not daemon-durable | partly | Queue lives in session-store (zustand) as queuedMessages: Map keyed by agent id, initialized as new Map() (session-store.ts L435, L670); the grep found no persist wiring for it, but I did not trace whether the whole session store is persisted elsewhere. The report correctly labels it inference; likely true. |
| Relay E2EE: Curve25519 ECDH + NaCl box; pairing QR carries daemon public key in URL fragment; ping every 10s; 8 MiB outbound high-water mark | confirmed | SECURITY.md lines 22-25 (persistent daemon keypair at $PASEO_HOME/daemon-keypair.json mode 0600, fragment offer URL, e2ee_hello, XSalsa20-Poly1305). docs/architecture.md L266-268 (10 s application ping lease, 8 MiB high-water mark, 4 MiB terminal soft backpressure). |
| HN Show HN reached 92 points on 2026-06-02; maintainer said mobile is 'step away from the desk'; 5h/7d usage 'very requested' | confirmed | HN API: id 48377250 'Show HN: Paseo - Beautiful open-source coding agent interface', score 92, 54 comments, by timhigins (not the maintainer; maintainer boudra said he did not submit it), 2026-06-02. Maintainer quotes match the report. Also in that thread: 'Yes, team of one right now' (June 2026) and business plan 'convenience/team/enterprise layer' later. |
| Subagent tracking via task_started/task_updated/task_notification/task_progress system messages | partly | live-source.ts header documents task_started, task_updated, task_notification and mentions only task_started carries tool_use_id; I saw switch cases for those three. task_progress was not seen in the grep output, so that fourth message type is unconfirmed. |
| Paseo claim that Claude Code use in Paseo costs nothing extra and counts against normal plan limits | confirmed | public-docs/claude-code.md: 'No. Claude Code usage in Paseo counts against your normal Claude plan limits. It does not require a separate pool of Agent SDK credits.' This is Paseo's current posture (post-pause); it is exposed to the policy risk the report describes. |

### Corrections

- Lifecycle state file path is packages/protocol/src/agent-lifecycle.ts, not shared/agent-lifecycle.ts as cited in the report.
- The 1,357 open-issues figure is GitHub's open_issues_count, which includes open PRs (now 1,360). Do not present it as pure issue backlog.
- Issues #6547 and #5749 are CLOSED (fixed); #1029 is CLOSED (bot-closed 2026-07-30 as a non-bug redirect to Discussions). Presenting them as current open problems would be wrong; the open stuck-running examples are #5951, #6355, #3256.
- The pikiloom PTY+transcript-tail comment on #1029 is a self-promotion by the pikiloom author, not independent user evidence. The report's wording 'users proposed a PTY/TUI path' is fine for maxwhipw and pppwaw, but pikiloom's mechanism is unvetted.
- The report says 'the maintainer admits subscription use goes through programmatic pools in the June thread; this was later paused': the statement was on HN 48377250 (2026-06-02) and Anthropic paused on 2026-06-15; Paseo's docs now state no separate pool. The structural risk remains but the report should not imply Paseo currently bills separately.
- task_progress as a fourth Claude subagent system message was not confirmed in live-source.ts.
- 'extracts no tokens' on paseo.sh/alternatives/conductor is phrased about both tools launching official CLIs with user credentials; the usage plugin contradicts it only for the usage feature, as the report says. Do not call the endpoint 'undocumented' without checking.

### Missed by the report

- Paseo's own docs now claim Claude Code in Paseo counts against normal plan limits and needs no separate Agent SDK credits (public-docs/claude-code.md). It still runs through the SDK, so this rests on Anthropic's pause plus the 2026-10-07 'third-party apps still use subscription limits' statement, not on a structural guarantee.
- Installed terminal hooks are left in ~/.claude/settings.json and ~/.codex/hooks.json across daemon shutdown and are inert unless PASEO_TERMINAL_ID is set (docs/terminal-activity.md). A Loom design that coexists with another tool's hooks must handle marker-tagged foreign hooks; Paseo preserves user hooks and removes only its marker-matched ones.
- Codex terminal hook mapping uses PreToolUse/PostToolUse->running and PermissionRequest->needs-input, a richer signal than Claude's hook set that Paseo uses (Notification idle_prompt only). Claude's needs-input in terminals is therefore coarser (only idle_prompt notification) than for SDK chat agents (canUseTool).
- Paseo's agent-lifecycle doc admits a provider runtime that dies between turns leaves the agent looking idle while background work (Bash shells, Monitor, workflows) is gone; they report exits between turns as turn failure. Relevant to Loom's 'status is a verified outcome' rule (docs/agent-lifecycle.md).
- Claude-specific SDK options Paseo relies on: enableFileCheckpointing (rewind files), perTaskStopAffordance (interrupt kills only the main turn, not background subagents, 'like Esc in Claude Code'), forwardSubagentText, SDK forkSession for rewind (agent.ts ~L3530-3570).
- Maintainer context: HN says 'team of one right now' (June 2026) with plans for a business around team/enterprise layer; the contributor count and 'roughly 200 logins' were not independently verified here (gh contributors call failed in my shell).
- Paseo advertises no telemetry, no forced login (README L51), which is a product differentiator relevant to Loom positioning.
- Paseo contribution policy: GitHub Issues are for bugs only; feature requests go to Discussions/Discord (paseo-bot reply on #1029, CONTRIBUTING.md).

## Sources

- https://github.com/getpaseo/paseo (cloned shallow at /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo)
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/architecture.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/agent-lifecycle.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/terminal-activity.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/terminal-performance.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/agent-stream-performance.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/glossary.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/service-proxy.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/docs/permissions.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/SECURITY.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/CHANGELOG.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/public-docs/claude-code.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/public-docs/orchestration.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/public-docs/workspaces.md
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/agent/providers/claude/query.ts
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/agent/providers/claude/agent.ts
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/agent/providers/claude/rewind.ts
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/agent/providers/claude/subagents/live-source.ts
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/agent/import-sessions.ts
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/server/src/server/plugins/usage-sources/index.ts
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/plugins/claude-usage-source/server/usage.ts
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/app/src/utils/sidebar-agent-state.ts
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/app/src/composer/submit.ts
- /Users/gencberke/Library/Caches/loom-v2-research/repos/paseo/packages/desktop/src/settings/desktop-settings.ts
- https://news.ycombinator.com/item?id=48377250 (Show HN, 2026-06-02)
- https://news.ycombinator.com/item?id=49233448 (OpenChamber thread)
- https://news.ycombinator.com/item?id=49234056
- https://www.reddit.com/r/conductorbuild/comments/1vvbak0/love_conductor_but_not_sure_pro_is_worth_it_right/
- https://www.reddit.com/r/conductorbuild/comments/1tc96ym/claude_is_killing_conductor_and_other_agent_sdk/
- https://www.reddit.com/r/PaseoAI/comments/1wv7z99/paseo_is_the_only_multi_harnass_tenant_that/
- https://www.reddit.com/r/opencodeCLI/comments/1sm6ru4/openchamber_vs_paseo/
- https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan
- https://paseo.sh/alternatives/conductor
- https://paseo.sh/alternatives/superset
- https://www.codeagentswarm.com/en/guides/paseo-vs-codeagentswarm
- https://vibecodinghub.org/blog/paseo-review
- GitHub issues getpaseo/paseo #1029, #4634, #5242, #5951, #6355, #6477, #6547, #6669, #6943, #4774, #4809, #4408
