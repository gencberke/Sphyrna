# Happy (slopus/happy; app "Happy: Codex & Claude Code App"; CLI on npm as `happy`, formerly `happy-coder`)

Research note for the Loom v2 brainstorm ([index](../V2-BRAINSTORM.md)). Written by a research subagent on 2026-10-17 and fact-checked by a second one; the fact-check is at the end and wins over the report where they differ. Raw JSON: `../evidence/deep-dive-20261017.json`.

**In one line:** Open-source (MIT) mobile/web/desktop client plus E2E-encrypted relay for steering Claude Code and Codex sessions that run on your own computer. It is now pivoting from "wrap the real CLI" to its own multi-provider desktop harness, and the original wrapper CLI is in maintenance mode.

**Category:** chat-first (mobile chat UI over a wrapped CLI; now moving to its own desktop harness)

## Adoption

GitHub slopus/happy: 24.1k stars, 2.1k forks, 2,565 commits, about 1,070 open issues, pushed 2026-10-17 (gh api, fetched today). Repo created 2025-07-18. The HN launch was 2025-08-14 (only 30 points).
npm downloads (api.npmjs.org, fetched today): `happy` had about 40.5k downloads in 2026-09-13..10-12 (monthly: Apr 20.8k, Jul 19.6k, Aug 26.5k, Sep 35.8k). The old `happy-coder` package still gets about 2k a month; its Jan-Mar 2026 peak was 19-25k a month. Latest `happy` is 1.2.5, with 1.2.6-beta.1 on 2026-10-09.
App Store: 4.86 average from 1,026 ratings, v1.8.0 released 2026-10-07 (itunes lookup API). Google Play: 3.23K reviews, 10K+ downloads, updated 2026-10-03. The README badges claim 4.9 from 1,000+ and 5.0 from 3.1k+.
Alternatives that exist because of it: HAPI (tiann/hapi), a stripped-down no-E2EE local variant whose author said hosted Happy "kept going down", and others (Omnara, Vicoa, Nimbalyst, Paseo).
Users on Reddit and the App Store praise the seamless phone/desktop handoff. Complaints are about polish ("vibe coded and lacks polish"), breaking changes, and slow loading of long chats ("opening an old chat takes minutes to catch up").
One third-party listing (not Happy's own) calls Remote Control and Happy two different bets; the Apple review I read says Remote Control "is not close to this. At least not yet."

## Architecture

Monorepo (pnpm). Packages: happy-app (Expo/React Native for iOS, Android, web and Tauri), happy-cli (Node/TS), happy-server (Fastify + Socket.IO + Prisma/Postgres, optional Redis and MinIO, PGlite for standalone self-host), happy-wire (shared protocol), happy-agent, happy-ios (native UIKit port, not shipped), happy-android (native Kotlin). The desktop app is in slopus/happy-desktop (created 2026-07-11, 94 stars). The Happy Agent runtime is in slopus/happy-agent (created 2026-07-04, 32 stars). It is built on "Pi" foundations and re-implements the Codex, Claude Code and Grok Build harnesses.

How the original CLI drives Claude Code (read in code, packages/happy-cli/src/claude/):
- It has two mutually exclusive modes, switched in loop.ts (`loop`).
  - LOCAL: claudeLocal.ts spawns `node scripts/claude_local_launcher.cjs` with `stdio: ['inherit','inherit','inherit','pipe']`. There is no PTY and no embedding; the user's own terminal runs the real Claude TUI.
    - The launcher monkey-patches `global.fetch` and writes fetch-start and fetch-end events to fd 3. `onThinkingChange` uses these as the "working" signal, with a 500 ms debounce.
    - A temporary `--settings` file registers a single SessionStart hook, via session_hook_forwarder.cjs, that POSTs to a local HTTP server (utils/startHookServer.ts, utils/generateHookSettings.ts). This is only used to learn the session id.
    - The conversation is mirrored to the phone by tailing Claude's transcript JSONL (utils/sessionScanner.ts: file watcher plus `setInterval(...,3000)`; it re-reads and re-parses whole files).
  - REMOTE: claudeRemote.ts uses the official `@anthropic-ai/claude-agent-sdk` `query()` (sdk/query.ts) in stream-json mode with `canUseTool` for permission prompts (utils/permissionHandler.ts).
    - Approvals, AskUserQuestion, plan-mode exit, model, effort and permission-mode changes all go through it.
    - It sets `CLAUDE_CODE_ENTRYPOINT` so that sessions stay visible in `claude --resume` (issue #1202).
- Mode switch: claudeLocalLauncher.ts registers `session.queue.setOnMessage(... doSwitch)`. The first message from the phone aborts the local Claude process (SIGTERM) and the CLI drops into remote mode (an Ink screen, ui/ink/RemoteModeDisplay.tsx). Double-space returns to local, per the HAPI author. Because the TUI is killed and the SDK takes over, the real interface is lost while the phone drives.
- Push notifications are only emitted from remote-mode code paths: claudeRemoteLauncher.ts:164 (AskUserQuestion), :438 (done), utils/permissionHandler.ts:259 (permission). In local mode the phone gets no approval or "needs you" signal.
- Relay (packages/happy-server): the CLI and app connect outbound over Socket.IO and HTTP and the server stores encrypted blobs (Postgres). That store-and-forward design gives history and catch-up on a flaky phone connection.
  - Crypto: tweetnacl (XSalsa20-Poly1305, legacy) and AES-256-GCM "dataKey" variant (docs/encryption.md). The master secret lives on the phone.
  - Pairing: the CLI shows a QR with a one-time public key; the phone replies with its account key sealed to it. Per-session random data keys are wrapped with the account public key.
  - Auth: challenge-signature with no email or password.
  - Push goes through the server, which calls Expo's push API (app/push/pushDispatch.ts, pushSend.ts). It suppresses a push only when a UI socket proves `app-state: active` (focusTracker, eventRouter.hasActiveUiClient). Dead tokens are pruned on DeviceNotRegistered. The push title/body is plaintext session summary (see issue #1833).
- Daemon (src/daemon/run.ts, controlServer.ts, mac/): a background process that registers the machine, spawns sessions on request from the phone (detached or in tmux), and resumes sessions. It carries env such as `HAPPY_SIDE_CHAT=1`, `HAPPY_FORK_CLAUDE_SESSION_ID`, `HAPPY_RECONNECT_*`. It reconnects only if the network is up and the lid is open or an external display is attached (issue #1817).
- Persistence: ~/.happy (settings.json, access.key, daemon.state.json, logs). Server history is encrypted in Postgres. Claude's own JSONL stays the source of truth on disk.
- Resource notes (from user issues, not measured by me): SESSION_SCANNER re-reads whole transcripts every 3 s. Issue #1841 reports a day-long idle session at 20-41% CPU of a node process, watching four transcripts totalling about 17 MB. Issue #1902 (2026-10-16) reports 40% CPU, 1.3 GB RSS at idle, and heartbeat starvation that makes healthy sessions show as inactive. A 105 MB debug log was reported in #1841.
- Strategic shift: README now leads with "Orchestrate Claude, Codex and Grok in one app". The `happy` npm CLI is "in maintenance mode: critical fixes only; new features ship in the Happy desktop app" (happy.engineering/docs/quick-start). The mobile app works with both.

## Core loop

Typical Happy day (from docs, store listing and Reddit threads):
1. At the desk, run `happy claude` (or the desktop app) instead of `claude`. Sessions show up on the phone.
2. Away from the desk, the phone pings for three reasons: a permission request, a clarifying question, or "It's ready!".
3. On the phone the user does one of four things: approve or deny (or choose "yes for session" / Auto mode), type a short answer, send a follow-up (often just "continue"), or use voice. They glance at a diff via "View changes".
4. Back at the desk they carry on in the same Claude session.
Evidence of real use: Reddit commenters say they use it on the sofa to check progress, tell it to "continue", and approve things. One said it was more seamless than Termius+tmux. Heavy use of voice is a niche (one commenter loves it); the project's own known-issues page says the voice agent cost about $8/hour while a prototype. The Google Play review that tops the page says it is "the best thing ever made for developers, or the absolute worst" because coding downtime is gone.
Skeptics on Reddit ask whether mobile dev is "theater"; most answers say mobile is for unblocking and kicking off tasks, not for real editing. Happy's own FAQ says the same: plan, answer, approve on mobile; review code and make precise edits at the desk.

## Features

### Local/remote dual-mode wrapping of the real CLI with phone takeover (remote-mobile, confidence high)

- **What the user sees:** Run `happy` in the terminal and get the normal Claude TUI. Send a message from the phone and the terminal turns into a Happy status screen while the phone drives. Switch back with a key in the terminal.
- **How it works:** packages/happy-cli/src/claude/loop.ts (`loop`) alternates claudeLocalLauncher.ts and claudeRemoteLauncher.ts. Local mode spawns Claude with inherited stdio (claudeLocal.ts, via scripts/claude_local_launcher.cjs) and mirrors the transcript by tailing the JSONL. A phone message triggers `doSwitch`, which aborts the local process. Remote mode runs the same session through the Agent SDK `query()` (claude/sdk/query.ts) with `resume:` set to the session id.
- **Reception:** This is the root of most complaints. Issue #1859: Claude's own `--remote-control` is ignored under stream-json, so a session disappears from Anthropic Remote Control while the phone drives. Issue #1894: sandbox is applied only in local mode, so a phone-driven session runs unsandboxed with permission prompts skipped. Issue #875: resumed sessions do not sync to the phone, and a phone message starts a brand new session. Issue #1861: messages added with `claude --resume` do not show in the app. Issue #1847: stale session ids stay resumable and every message dies with "No conversation found". Several stdin/TTY garbling bugs after remote-to-local switching (#301 family, a comment in claudeLocal.ts).
- **Evidence:** packages/happy-cli/src/claude/loop.ts; packages/happy-cli/src/claude/claudeLocalLauncher.ts (session.queue.setOnMessage -> doSwitch); packages/happy-cli/src/claude/claudeLocal.ts (stdio inherit, setBlocking comment); https://github.com/slopus/happy/issues/1859; https://github.com/slopus/happy/issues/1894; https://github.com/slopus/happy/issues/875

### E2E-encrypted relay with QR pairing and self-hosting (remote-mobile, confidence high)

- **What the user sees:** Install the CLI, run `happy`, scan a QR code on the phone, and the sessions appear. No email or password account. A history of past sessions is visible later. Messages sent while offline are queued and delivered. You can point both app and CLI at your own server.
- **How it works:** packages/happy-server (Fastify, Socket.IO, Prisma/Postgres, Redis adapter, MinIO for attachments, PGlite for standalone). The CLI (src/api/api.ts, apiSession.ts, apiMachine.ts) and the app both connect outbound. Content is encrypted client-side (docs/encryption.md: tweetnacl XSalsa20-Poly1305 legacy, AES-256-GCM dataKey variant) so the server stores opaque blobs. Auth is a challenge-signature with no password (docs: happy.engineering/docs/how-it-works).
- **Reception:** Praised: privacy, no lock-in, open source, "no signup". Criticised: hosted-server reliability (an 8-hour outage on 2026-10-05, issues #1866 and #1870, left existing sessions blank on the phone while push notifications still arrived), self-hosting is hard (a Reddit author could not get it running and built HAPI instead), and a September 2026 security audit of the repo (issues #1829-#1833) found a pairing token mint from the public QR key, bearer tokens that never expire and cannot be revoked, a daemon control server that authenticates no peer, a world-readable access.key, and PRIVACY.md claims that do not match the code.
- **Evidence:** https://happy.engineering/docs/how-it-works/; https://happy.engineering/docs/security/; packages/happy-server/package.json; docs/encryption.md; https://github.com/slopus/happy/issues/1829; https://github.com/slopus/happy/issues/1831; https://github.com/slopus/happy/issues/1870

### Push notifications for permission / question / done (attention-status, confidence high)

- **What the user sees:** Phone alerts titled "Permission request", "Clarification needed" or "It's ready!", with the session title as body. Tapping opens the session. The alert is suppressed if the app is open and active on a device.
- **How it works:** CLI calls session.api.push().sendSessionNotification (src/api/pushNotifications.ts). The server routes it through dispatchSessionEventPush (happy-server/sources/app/push/pushDispatch.ts) to Expo push tokens stored per account. It suppresses only when an active UI socket is proven ("a missed push is far more costly than a redundant one"). Notifications are sent to all registered devices; smart routing is only on the roadmap (docs/roadmap.md). Pushes come from remote-mode code only (claudeRemoteLauncher.ts:164, :438; permissionHandler.ts:259); a session running in local mode produces none.
- **Reception:** Core reason people install it. Complaints: push tap on Android stacks duplicate screens or strands the composer (#1900, #1901); after the October outage pushes arrived with blank content (#1870); payload content passes through the relay as plaintext, contradicting the privacy text (#1833). The code comment in pushDispatch.ts also admits that per-message pushes were removed because they buzzed every 10 s during a turn.
- **Evidence:** packages/happy-server/sources/app/push/pushDispatch.ts; packages/happy-cli/src/api/pushNotifications.ts; packages/happy-cli/src/claude/claudeRemoteLauncher.ts:164,438; docs/roadmap.md (Push Notification Routing); https://github.com/slopus/happy/issues/1833

### Approve / deny / answer from the phone, with permission modes (remote-mobile, confidence high)

- **What the user sees:** A permission card in the chat with allow, allow for session, and deny. A mode picker in the composer (Default, Accept edits, Plan, read-only, safe-yolo, yolo; new sessions default to Auto). AskUserQuestion shows as tappable choices. The App Store reviewer also mentions auto-suggested clickable replies.
- **How it works:** utils/permissionHandler.ts implements `canUseTool` for the Agent SDK. It re-implements part of Claude's own policy: allowed Bash literals/prefixes, an acceptEdits check by tool descriptor, an always-ask list for AskUserQuestion and ExitPlanMode, and a bypass-equivalent mode. Mode mapping is in utils/permissionMode.ts and docs/permission-resolution.md (yolo -> bypassPermissions, safe-yolo/read-only -> default).
- **Reception:** Works well in the happy path, but because Happy re-implements policy it drifts from the CLI: #1819 (picking Default cannot leave a bypassing session), #1820 (queued messages with different modes all run under the first one), #1894 (sandbox on -> approvals skipped in remote mode), #1830 ("sandbox disables approval"). A Codex user in the App Store reviews reported the approval buttons being non-responsive in a terminal session.
- **Evidence:** packages/happy-cli/src/claude/utils/permissionHandler.ts; docs/permission-resolution.md; https://github.com/slopus/happy/issues/1819; https://github.com/slopus/happy/issues/1820; https://github.com/slopus/happy/issues/1894

### Queued follow-ups and a proposed Steer-vs-Queue choice (chat-input, confidence medium)

- **What the user sees:** Messages sent while the agent works wait in a queue and run next turn. A pending proposal (issue #1867, 2026-10-06) adds a Steer / Queue choice so a follow-up can guide the active turn without stopping the agent. Drafts follow you between phone and desktop. The model and effort pickers sit beside the send button.
- **How it works:** CLI message queue (src/utils/MessageQueue2.ts, runClaude.ts `messageQueue.push(...)`) carries per-message mode metadata. The Steer proposal would forward into Claude's streaming-input query or Codex `turn/steer`. Voice sits in the send button when the composer is empty (changelog).
- **Reception:** Queue is the status quo; steering is requested by users. Open bug: image attachments are dropped when their message triggers a query restart (#1821).
- **Evidence:** https://github.com/slopus/happy/issues/1867; https://github.com/slopus/happy/issues/1820; https://github.com/slopus/happy/issues/1821; packages/happy-app/sources/changelog/changelog.json

### Side chat (forked child session next to the main one) (context-knowledge, confidence high)

- **What the user sees:** A right-hand panel with tabs of side chats. Each starts empty in the UI but the model has the parent's full context. It never shows in the top-level session list. A parent can have several. Added in the app changelog just before 2026-10 ("Side chats - fork a parallel conversation right next to your session").
- **How it works:** The app calls the daemon's spawn RPC (src/api/apiMachine.ts) with parentSessionId and isSideChat. The CLI copies the parent's Claude JSONL under a new UUID (claude/utils/claudeSessionFork.ts `forkSession`, a plain copyFile), spawns a Happy session with HAPPY_SIDE_CHAT=1, resumes the copy through the SDK, and deliberately does not replay history to the UI (runClaude.ts around line 319, `if (!isSideChat)`). Metadata flag `isSideChat` hides it from lists (app sources/sync/storage.ts:408, 666). The UI is components/SideChatPanel.tsx, which embeds the same SessionViewLoaded used for main chats.
- **Reception:** Very new, so little feedback. By design a snapshot: the side chat does not see later main-thread work, and each side chat leaves another JSONL in the user's own Claude project folder. Note the CLI now has `/btw` natively (Claude docs, interactive-mode: no tools, single response, does not enter history, runs while Claude is working, press f to fork into a background subagent).
- **Evidence:** packages/happy-app/sources/components/SideChatPanel.tsx; packages/happy-cli/src/claude/utils/claudeSessionFork.ts; packages/happy-cli/src/claude/runClaude.ts:130,153,319; packages/happy-cli/src/daemon/run.ts:360; https://code.claude.com/docs/en/interactive-mode (Side questions with /btw)

### Fork / duplicate a session from a chosen message (rewind point) (context-knowledge, confidence high)

- **What the user sees:** Session menu has a Fork action and a duplicate sheet that lists your earlier prompts so you can start a new session from that point.
- **How it works:** claudeSessionFork.ts `forkAndTruncateSession` stream-copies the JSONL up to and including the chosen turn and drops the next user prompt, then renames atomically. It hard-fails with `ForkTruncateUuidNotFoundError` rather than silently returning a full copy. `listClaudeRewindPoints` reads the JSONL for non-sidechain string-content user messages. Registered in apiMachine.ts and used by the app's useSessionQuickActions.ts `forkSession`.
- **Reception:** Marked as a roadmap table-stakes item (docs/roadmap.md: forking a session). No complaints found. The design depends on Claude's private JSONL format.
- **Evidence:** packages/happy-cli/src/claude/utils/claudeSessionFork.ts; packages/happy-app/sources/hooks/useSessionQuickActions.ts:320; docs/roadmap.md

### Review changes on the phone (diff view) (review-git, confidence medium)

- **What the user sees:** Session info -> View changes: a file list, colored diffs, the full set of changes on a branch, before/after images, expandable context, whitespace filter, tap a file to open it full-screen. Project rows show live +/- branch change counts.
- **How it works:** Diff data comes from the machine via RPC (session file/diff handlers in src/modules/common/registerCommonHandlers.ts and the app's mobile-diff-highlighting design, docs/mobile-diff-highlighting.md). I did not trace the exact git commands.
- **Reception:** Listed in the App Store description as a headline feature. Happy's own FAQ still tells people to review code on the desktop. Issue #1832 shows file RPCs follow symlinks out of the workspace.
- **Evidence:** https://apps.apple.com/us/app/happy-codex-claude-code-app/id6748571505; packages/happy-app/sources/changelog/changelog.json; https://github.com/slopus/happy/issues/1832; docs/mobile-diff-highlighting.md

### Voice control via ElevenLabs realtime agent (remote-mobile, confidence high)

- **What the user sees:** Mic button in the composer. You talk to a voice assistant that relays prompts to Claude Code, reads back summaries and can approve permissions by voice. Free tier of 20 minutes per 30 days, then paid.
- **How it works:** docs/voice-architecture.md: ElevenLabs conversational SDK in the app (RealtimeVoiceSession.tsx), WebRTC via LiveKit. Client tools `messageClaudeCode` and `processPermissionRequest` route to a module-level `currentSessionId`. App events are fed to the agent as silent context or as queued prompts that wait until nobody is speaking. Server route voiceRoutes.ts checks usage via the ElevenLabs API (docs/paid-voice.md). Cost to the project is about $0.01 per minute measured.
- **Reception:** One Reddit user loves hands-free use; the project's known-issues page admits the agent loses context after long conversations. Not mentioned by skeptics as a reason to use Happy. It is a hosted dependency and the main source of Happy's only revenue (subscription).
- **Evidence:** docs/voice-architecture.md; docs/paid-voice.md; https://happy.engineering/docs/versions/known-issues/; https://www.reddit.com/r/ClaudeCode/comments/1qg4c0w/using_claude_code_anytime_anywhere/

### Start and resume sessions on a machine from the phone (daemon) (remote-mobile, confidence high)

- **What the user sees:** From the phone, pick a machine and folder, choose agent, model, effort and permission mode, and start a session. Sessions are grouped by project with each checkout's chats as tabs. Resume previous ones.
- **How it works:** Daemon (src/daemon/run.ts `spawnSession`, controlServer.ts) registers the machine over Socket.IO and spawns a CLI per session, optionally inside tmux. It pre-flights environment variables and token injection (CLAUDE_CODE_OAUTH_TOKEN for Claude). There are macOS launchd helpers in src/daemon/mac.
- **Reception:** Valuable but fragile. Daemon does not reconnect while the lid is closed even when the Mac is kept awake (#1817). A resumed session shows offline for a minute after stop (#1852). Control server authenticates no peer (#1830). Needs the machine awake; that is the same limitation as Anthropic's Remote Control.
- **Evidence:** packages/happy-cli/src/daemon/run.ts; packages/happy-cli/src/daemon/controlServer.ts; https://github.com/slopus/happy/issues/1817; https://github.com/slopus/happy/issues/1830

### Transcript mirroring and subagent rendering (navigation-ux, confidence high)

- **What the user sees:** The phone shows the whole conversation, including tool calls as one-line rows you can expand, and subagents rendered live in chat. A status bar shows branch, model, effort and context.
- **How it works:** Local-mode text comes from the JSONL scanner (utils/sessionScanner.ts) and utils/sessionProtocolMapper.ts turns raw lines into the session-protocol turn/message envelopes (docs/session-protocol-claude.md). Remote-mode text comes from SDK messages (utils/sdkToLogConverter.ts). Nested subagent messages can lose their nesting when a session is loaded from history (issue #1873).
- **Reception:** Praised for fidelity, but the polling implementation is the project's worst resource problem (issues #1841, #1902) and long chats are slow to open on the phone (App Store review).
- **Evidence:** packages/happy-cli/src/claude/utils/sessionScanner.ts:149 (setInterval 3000); https://github.com/slopus/happy/issues/1841; https://github.com/slopus/happy/issues/1902; https://github.com/slopus/happy/issues/1873

### Plan-limit usage in the app (usage-cost, confidence medium)

- **What the user sees:** Plan rate-limit windows with utilization and reset times next to the session. A per-session spend cap is only a feature request (#1893).
- **How it works:** claudeRemote.ts consumes the SDK `rate_limit_event` and the `get_usage` control request, normalised in utils/usageLimits.ts (`windowsFromGetUsage`) and merged into agent state. This is the same `get_usage` approach Loom already uses.
- **Reception:** No community feedback found. Only works while a session is in remote (SDK) mode.
- **Evidence:** packages/happy-cli/src/claude/utils/usageLimits.ts; packages/happy-cli/src/claude/claudeRemote.ts:208,324; https://github.com/slopus/happy/issues/1893

### Pivot to a multi-provider desktop harness with multiplayer (orchestration, confidence medium)

- **What the user sees:** Happy Desktop (macOS/Windows/Linux) running Claude, Codex and Grok in one app with model switching mid-task. Sessions started there appear on the phone. A second person can join a session and both can steer it.
- **How it works:** slopus/happy-desktop talks to the headless slopus/happy-agent daemon through `@slopus/happy-agent-client`. Happy Agent re-implements the prompts and tools of Codex, Claude Code and Grok Build on top of Pi. I read only the READMEs; the code was not cloned.
- **Reception:** Too new to judge (repos created July 2026, 94 and 32 stars). Strategically it shows that the wrapper approach hit a ceiling: the same team chose to leave the real CLI interface behind. For Loom, whose rule is to host the real CLI, this is both a caution and a differentiator.
- **Evidence:** https://github.com/slopus/happy; https://github.com/slopus/happy-desktop; https://github.com/slopus/happy-agent; https://happy.engineering/docs/quick-start/ (maintenance mode note)

## UX patterns worth borrowing

- Phone-sized triage loop: notification -> open directly on the session -> one of approve/deny, tap a suggested reply, short text, or mic. Pushes are restricted to three kinds (permission, question, done); per-message pushes were removed because they buzzed every 10 s.
- Suppress pushes only when the device is provably in use (active UI socket), otherwise send: missed pushes are judged worse than extra ones. Claude's own Remote Control has the same idea via a presence file (CLAUDE_CLIENT_PRESENCE_FILE).
- Composer carries model, effort and permission mode right next to the send button, with the mic in the same button when the field is empty; drafts follow you between devices.
- Side chats as tabs in a right panel, each an embedded copy of the normal session view, hidden from the main list (`metadata.isSideChat`).
- One list with active sessions on top plus a Group-by-Project toggle (project row shows avatar, live +/- change counts, status dot; checkouts' chats as tabs).
- Tool calls collapse to one-line rows that expand; 'Compact Tool Calls' setting; status bar with branch/model/effort/context that opens the pickers.
- Fork from a chosen earlier prompt (list of rewind points read from the transcript) with a hard failure if the marker is missing, instead of silently producing a full copy.
- Permission grants with a durable 'don't ask again' that sticks; Auto as the default mode for new sessions.

## Anti-patterns

- Two runtimes for one session (inherited-stdio terminal CLI vs. SDK stream-json). Every feature then exists in two places (sandbox, Remote Control, permissions, resume), and state diverges (issues #1859, #1894, #875, #1861).
- Re-implementing the CLI's own permission policy in the wrapper (permissionHandler.ts). It drifted from Claude within months (#1819, #1820, #1894).
- Detecting 'working' by monkey-patching Claude's global fetch through a launcher script (claude_local_launcher.cjs). It is version-fragile and outside any documented interface; Loom's hooks plus session registry is the better source.
- Polling and full re-parse of transcripts every 3 s (SESSION_SCANNER). Reported 20-40% CPU on idle long sessions, 1.3 GB memory, and heartbeat starvation that marks live sessions inactive (#1841, #1902). Incremental reads by (inode, offset) are the fix users proposed.
- A hosted relay that is a single point of failure: an 8-hour outage (2026-10-05) left old sessions blank on phones; a Reddit user also said the server 'kept going down'. Self-hosting is hard.
- Push payloads with plaintext summaries sent through the relay while privacy docs claim device-to-device (#1833); tokens that never expire (#1831); unauthenticated local control server (#1830).
- Rapid, breaking mobile releases (App Store review: 'frequent breaking changes ... navigation bugs'; 'lacks polish'; Android notification-tap bugs).
- Doing nothing about wrapper limits in the docs: the known-issues page admits there is no indication in the app when Claude auto-compacts.
- Gating on lid state (ioreg AppleClamshellState) to decide whether to reconnect, which breaks a Mac kept awake on purpose (#1817).

## Ideas for Loom

### Phone path = Claude's own Remote Control, hosted and made visible by Loom (no Loom relay). A per-session 'Reachable from phone' toggle launches (or later sends `/remote-control` into) the real PTY session with `--remote-control "<title>"`, and shows an RC badge on the card. Optionally mention `remoteControlAtStartup` as the user's own global choice, not something Loom writes. (cost S)

- **Inspired by:** Happy's whole relay/E2EE/daemon stack (what it costs to build and run) versus the official docs at https://code.claude.com/docs/en/remote-control, which already give approvals, AskUserQuestion, push ("Push when actions required"), a diff pane, subagent and model/effort control, image upload and auto-reconnect for an interactive CLI session. Happy's own issue #1859 shows the wrapper approach breaks exactly this.
- **Gain:** Approve, answer, nudge and check diffs from the phone for the sessions that already run in Loom PTYs, with zero new server, auth or crypto code to write or secure. Loom keeps the real TUI, so nothing is lost on takeover, unlike Happy's local/remote switch.
- **Fit:** Fits 'prefer documented interfaces' and 'resilience to CLI updates' (it is a documented flag), and costs nothing when idle. Status accuracy: Loom can only claim 'requested', not 'connected', unless the CLI exposes RC state to hooks/registry; I could not confirm that (unverified). A drift check on the flag is consistent with Loom's existing drift detection. Conflicts: needs a claude.ai login (no API keys, Bedrock/Vertex, or ANTHROPIC_BASE_URL), transcripts are stored on Anthropic servers while connected (docs), one remote session per interactive process, and the Mac must stay awake. Lighter variant: just add the flag to the 'new session' options and show a read-only badge.
- **Risks:** The RC state is unobservable from outside unless the registry or hooks expose it; if Loom shows 'connected' without proof it breaks the accurate-status rule. Quit-stops-all-sessions means the phone loses access when Loom quits. Data-retention implications for work projects (ZDR/HIPAA orgs cannot enable it). Behavior may differ across CLI versions (docs cite minimum versions per feature).

### Presence marker for the phone pushes: write/delete the file named by CLAUDE_CLIENT_PRESENCE_FILE when the Mac screen locks/unlocks (event-driven via NSDistributedNotificationCenter / session-active notifications), so Claude's own phone pushes are skipped whenever the user is at the Mac and only arrive when away. (cost S)

- **Inspired by:** Happy's focusTracker/'proven active UI client' push suppression (happy-server push/pushDispatch.ts) and the docs section 'Mobile push notifications' in the Remote Control page.
- **Gain:** Prevents double notifications (Mac plus phone) and makes phone pushes mean 'you are away and this needs you'. No settings UI needed.
- **Fit:** No polling: lock/unlock is an event. Tiny code and no state beyond one file. Predictable. Works only if the sessions run with RC, so ship it together with the toggle. Process ownership is unaffected; the env var must be passed at launch (so it only applies to sessions started by Loom after the change).
- **Risks:** Env var is read at CLI start, so existing sessions are unaffected until restarted; documented only on the RC page, so keep it behind drift tolerance (ignore if the CLI stops honoring it).

### Side chat without a second runtime: expose `/btw` as a first-class composer action (a small panel that shows the no-tools, no-history answer and the 'fork into a background subagent' step), and add a heavier 'Side thread' that starts a hidden child session via the CLI's documented resume+fork options (unverified here: check `claude --help` for `--fork-session`) in its own Loom run scope, shown as a tab in the detail pane and as a child under the parent card, never in the main list. (cost M)

- **Inspired by:** Happy's SideChatPanel.tsx and its fork implementation (claudeSessionFork.ts `forkSession` copying the JSONL, runClaude.ts `isSideChat` suppressing history replay), plus the CLI's native `/btw` documented at https://code.claude.com/docs/en/interactive-mode.
- **Gain:** Directly serves the user's long-standing wish for a side thread that does not pollute the main context; /btw is already cheap (warm prompt cache) and runs while the main turn is working.
- **Fit:** A child that is only a record when idle costs nothing, matching 'sessions that cost nothing when idle'. Use the CLI's own fork option rather than copying private JSONL (Happy's copyFile approach breaks if the transcript format or location changes, against 'never pin versions'). The child is a normal Loom-owned process so Stop/Quit stay verifiable. Variant if no fork flag exists: only /btw (S), skip the heavier thread.
- **Risks:** A fork is a snapshot, not live-linked to the parent. Each side thread creates another Claude session record the user may want to clean up (Loom's delete feature covers it). Embedding a second live terminal costs resources; keep it as a read-only transcript view plus a composer.

### A tiny 'phone-grade' action set inside Loom itself: from the Needs-approval box and the menu bar item allow Approve / Deny / 'Allow for session' / pick option / one-line follow-up without opening the terminal. This is the same four actions Happy users actually use, now on the Mac, and the same component can later back a phone view. (cost M)

- **Inspired by:** Happy's permission card and 'tap a suggested reply' flow, and the Reddit evidence that approve, 'continue' and short answers are the real remote actions (r/ClaudeCode threads, 2025-2026).
- **Gain:** Less context switching between several sessions: answer the blocked session from the sidebar card or notification and move on.
- **Fit:** Uses Loom's existing hook-based status and approval boxes; no new infrastructure. Do not re-implement Claude's permission policy (Happy's drift lesson): relay the CLI's own PermissionRequest/approval prompt and send the key sequence or documented hook response, then verify the state change before reporting success. Keystroke injection into the PTY is fragile; prefer the documented hook decision path where it exists.
- **Risks:** If answers are injected as keystrokes they depend on the TUI layout and can misfire; a verified-outcome check (hook shows the tool ran) is needed. Cross-session actions stay user-initiated only.

### Optional 'away' pager: when a session enters Needs-approval/Finished and Loom's window is not frontmost and the screen is locked for N minutes, send a content-free push through a user-chosen channel (their own ntfy topic or Apple Shortcuts/iMessage-to-self), 'Session <title> needs you', with no code or summary text. (cost S)

- **Inspired by:** Happy's three push kinds and its suppression-only-when-proven-active rule; its plaintext-summary push is the cautionary example (issue #1833).
- **Gain:** Get the attention signal even for sessions not running with Remote Control or when the user did not enable it, without any hosted relay of Loom's own.
- **Fit:** Event-driven off existing status transitions, no polling. Against 'privacy': keep payload to a fixed string plus project colour name, off by default, user-configured endpoint only. Likely redundant if the Remote Control path (idea 1) works for the user; recommend skipping unless RC proves unreliable.
- **Risks:** Third-party delivery service is a new network dependency; ntfy topics are guessable unless unguessable names/tokens are used; adds a settings surface. Prefer to skip.

### Fork-from-here: list the user's earlier prompts of a session (Loom already reads transcripts incrementally) and start a new session from the chosen point, hard-failing when the marker cannot be found. Use a documented CLI option for resume/fork if available; otherwise do not copy Claude's JSONL. (cost M)

- **Inspired by:** Happy's `listClaudeRewindPoints` and `forkAndTruncateSession` (claudeSessionFork.ts) and its 'fail rather than fake the cut' rule; roadmap item 'forking a session'.
- **Gain:** Triage-then-fan-out pattern (explore once, branch into several focused sessions) and a cheap alternative to a checkpoint/rewind UI.
- **Fit:** Matches 'never report false success' (Happy throws ForkTruncateUuidNotFoundError). Conflicts with 'never pin CLI versions' if implemented by copying the private JSONL, so only build it if the CLI offers a documented fork/rewind interface; otherwise skip.
- **Risks:** The CLI may change transcript structure; a copied transcript can diverge from Claude's index. New sessions appear in the user's real Claude data and need the deletion flow.

### Regression guard for Loom's own transcript reader: assert in a test that reading is incremental by byte offset plus inode (never re-parsing a whole file on a timer) and that idle sessions generate zero reads, citing Happy's SESSION_SCANNER failure mode. (cost S)

- **Inspired by:** Happy issues #1841 and #1902 (3 s full re-read; 20-40% CPU idle; heartbeat starvation).
- **Gain:** Protects the 'sessions cost nothing when idle' and <=40% core budget as transcripts grow (long multi-agent sessions reach tens of MB).
- **Fit:** Direct fit with 'no polling, bounded reads'. I did not read Loom's code, so whether this is already covered is unknown; treat as a check, not a build item.
- **Risks:** None beyond test maintenance.

### Skip: building a Loom relay, E2E crypto, push service, native phone app or voice agent. If a phone view for non-Remote-Control cases is ever wanted, the lightest version is a read-only status page on the user's own network/Tailscale served only while Loom runs (no stored data), not a relay. (cost S)

- **Inspired by:** Happy's server and security issues (#1829-#1833, #1866/#1870 outage) and the maintenance burden implied by moving the whole product to a desktop harness.
- **Gain:** Saves months of work and an entire attack surface; keeps Loom a Mac app whose process ownership is verifiable.
- **Fit:** A relay needs a running daemon that survives Quit and constant connections, which conflicts with 'Quit stops all sessions', 'very low resource use' and 'cross-session actions only under user authority'. Voice costs about $0.01/min through ElevenLabs and needs a hosted dependency; macOS system dictation in the composer is the free alternative if voice is wanted.
- **Risks:** The user gets no phone path if Remote Control is unavailable for their account (API-key or gateway setups).

## Fact-check

| Claim | Verdict | Note |
| --- | --- | --- |
| Original CLI is in maintenance mode; new features ship in the desktop app; desktop runs own multi-provider harness (happy-agent) | confirmed | README leads with 'Orchestrate Claude, Codex and Grok in one app'. Search snippets of happy.engineering/docs/how-it-works/ and /docs/features/ say 'maintenance mode: it keeps working and still gets critical fixes, but new features ship in...'. The /docs/quick-start/ page, which the report cites, does NOT contain that sentence (it is titled 'Original Happy CLI Docs' and points to the Desktop quick start). So the source is misattributed, the fact holds. happy-desktop (94 stars, created 2026-07-11) and happy-agent (32 stars, 2026-07-04) match gh api. welcome page confirms Claude gets 'Claude Code's prompts and tools' in the Happy runtime. |
| Local mode spawns Claude with inherited stdio (no PTY), mirrors transcript; remote mode uses Agent SDK query() stream-json; phone message aborts local and switches | confirmed | Clone at HEAD 55ab69f: claudeLocal.ts:316 stdio ['inherit','inherit','inherit','pipe'] via crossSpawn of node claude_local_launcher.cjs; claudeLocalLauncher.ts:86 session.queue.setOnMessage(... void doSwitch()) plus an RPC 'switch' handler at :85; claude/sdk/query.ts wraps the official SDK; package.json depends on @anthropic-ai/claude-agent-sdk ^0.3.295; claudeRemote.ts:174 calls query(). Issue #1859 shows the remote child is 'claude --output-format stream-json --input-format stream-json --permission-prompt-tool stdio'. |
| Push notifications only emitted from remote-mode code (claudeRemoteLauncher.ts:164, :438; permissionHandler.ts:259); only hook registered is SessionStart | confirmed | grep of src shows sendSessionNotification only at those three Claude sites (plus gemini/codex runners and a generic sendToAllDevices in index.ts:862, a manual 'notify' command). Line numbers match exactly (kinds question, done, permission). generateHookSettings.ts registers only SessionStart (matcher '*') pointing at session_hook_forwarder.cjs. Consequence for local mode is inferred (no push call exists in the local launcher), which is sound. |
| Working state in local mode is detected by monkey-patching global fetch in claude_local_launcher.cjs and sending fetch-start/fetch-end over fd 3 (500 ms debounce) | confirmed | scripts/claude_local_launcher.cjs lines 16-68 replace global.fetch and emit fetch-start/fetch-end; claudeLocal.ts:326-367 reads fd 3 via readline, tracks activeFetches, and debounces stop with setTimeout 500. |
| SESSION_SCANNER re-reads and re-parses whole transcript files every 3000 ms (sessionScanner.ts:149); issues #1841 and #1902 report 20-41% CPU and 1.3 GB idle | confirmed | sessionScanner.ts:149 setInterval(...,3000) and readSessionEntries does readFile of the whole file and JSON.parse of every line (dedup only by key afterwards). #1841 (opened 2026-09-24): ~1d19h session, 4 transcripts 10.1+4.1+2.3+0.9 MB, avg ~20% / peak ~41% CPU, 105 MB debug log. #1902 (2026-10-16): one 182 MB / 40,063-line transcript, 39.6% CPU, 1.28 GB RSS, heartbeat starvation shows sessions inactive. Nuance: the 40%/1.3 GB figure is for a single 182 MB transcript, not typical sessions. Both issues are open and self-reported. |
| Claude Remote Control is ignored under stream-json so Happy remote mode loses it (#1859, upstream anthropics/claude-code#99364) | confirmed | #1859 (open, 2026-10-04) states this with versions happy 1.2.5 / Claude Code 2.1.285 and cites upstream. anthropics/claude-code#99364 exists, titled '--remote-control is silently ignored in print/stream-json mode (session never registers)'. Note the #1859 claim comes from one user's repro, but upstream issue corroborates. |
| Official Remote Control docs: interactive session with --remote-control or /remote-control gives phone approvals, push, diff pane, model/effort control, auto-reconnect; needs claude.ai login (not API keys, Bedrock, Vertex, ANTHROPIC_BASE_URL); transcript stored on Anthropic servers while connected; one remote session per interactive process | partly | Fetched https://code.claude.com/docs/en/remote-control today. Confirmed: --remote-control / --rc / /remote-control; diff pane; /model and /effort from device (effort control needs v2.1.234+); auto-reconnect after sleep or network drop; API keys unsupported, Bedrock/Google/Microsoft Foundry and non-Anthropic ANTHROPIC_BASE_URL excluded; transcript stored on Anthropic servers while connected; ZDR/HIPAA orgs cannot enable; push settings 'Push when Claude decides' and 'Push when actions required'; Team/Enterprise needs owner toggle. 'One remote session per interactive process' is stated for the auto-connect setting (each process registers one remote session; use server mode for multiple per process), fine. Gaps: the report says docs mention a Mac must stay awake; docs actually say it reconnects when the machine comes back, and a 3-min 403 retry, ~30 min heartbeat failure disconnect, and forwarded non-permission dialogs expire after 5 min (dialogExpiry). |
| Usage numbers: npm happy ~40.5k downloads 2026-09-13..10-12, happy-coder ~2k; 24.1k stars; App Store 4.86 from 1,026 ratings; Google Play 3.23K reviews, 10K+ downloads | confirmed | Re-fetched: api.npmjs.org happy 40502, happy-coder 2065 for that range; registry dist-tags latest 1.2.5, beta 1.2.6-beta.1. gh api: 24183 stars, 2069 forks, 1072 open issues (includes PRs), MIT, created 2025-07-18, pushed 2026-10-17T08:03Z. iTunes lookup: 4.86452 / 1026 / v1.8.0 / 2026-10-07. Play page: 3.23K reviews, 10K+ downloads, updated Oct 3 2026. HN item 44904039 'Show HN: Happy Coder' 30 points 2025-08-14. Caveat: the 10K+ install bucket is Play's lower bound and makes the 3.23K review count look large; 'open issues' includes PRs. |
| Side chat implemented by copying parent JSONL (forkSession copyFile) and resuming as hidden child (HAPPY_SIDE_CHAT=1, runClaude.ts:130/319, isSideChat filter); CLI now has /btw | confirmed | claudeSessionFork.ts:65-71 forkSession uses copyFile; runClaude.ts:130 reads HAPPY_SIDE_CHAT, :153 sets isSideChat metadata, :319 `if (!isSideChat)` skips history backfill (comment confirms deliberate). /btw confirmed in https://code.claude.com/docs/en/interactive-mode: no tool access, not added to history, available while Claude is working. 'press f to fork into a background subagent' not re-checked. Also: the report left `--fork-session` unverified; the Claude CLI reference does list a `--fork-session` flag (fetched code.claude.com/docs/en/cli-reference, string present twice), so a documented fork path exists. |
| Hosted-relay risk: 8-hour outage 2026-10-05 (#1866, #1870); audit 2026-09-23 (#1829-#1833) with non-expiring tokens, QR-key token mint, plaintext push, unauthenticated control server | confirmed | #1866: api.cluster-fluster.com 404 on all paths from ~07:50 UTC; maintainer comment 2026-10-05T20:17Z says outage lasted ~8 hrs. #1870 (post-outage blank content while push arrives) confirmed. #1829 (pairing public key treated as authenticator, permanent account token), #1830 (sandbox disables approval, control server authenticates no peer, access.key world-readable), #1831 (tokens never expire, revocation no-op), #1833 (PRIVACY.md vs code, push content) all created 2026-09-23 by one author 'ethicnology-agent', i.e. a single (apparently agent-generated) audit, all still open. Note #1866 is closed; the report does not say so. |
| Issue numbers cited as reception evidence (#875, #1817, #1894) | partly | #1817 and #1894 confirmed as titled and open. #875 is a closed feature request (closed 2026-04-14 as completed, maintainer: 'tracking in #685 ... bigger spawning/forking design effort'), so using it as a current complaint overstates it. #1866 also closed. |

### Corrections

- The 'maintenance mode' sentence is not on https://happy.engineering/docs/quick-start/ (that page is just titled 'Original Happy CLI Docs' and links to the Desktop quick start). Cite /docs/how-it-works/ or /docs/features/ instead.
- Issue #875 (resumed sessions not synced to phone) is closed/completed (2026-04-14, folded into #685); do not present it as a live defect. #1866 (outage) is also closed.
- The 40% CPU / 1.3 GB RSS figure in #1902 is for one 182 MB, 40k-line transcript; the #1841 figure (20-41%) is a 17 MB watch set over ~1.8 days. Treat them as worst-case-grows-with-size reports by individual users, not typical load. Both are open, self-reported, unverified by maintainers.
- The September audit (#1829-#1833) was filed within seconds by one account named 'ethicnology-agent', so it is probably automated analysis; findings are plausible and consistent with the code the report read, but treat as single-source, not a maintainer-acknowledged audit.
- 'Mac must stay awake' for Remote Control is not what the docs say; they say a sleeping laptop or dropped network reconnects automatically when it comes back online (interactive sessions retry indefinitely; server mode gives up after ~10 min). Only the machine being off/asleep means no phone access during that time.
- Report states Loom 'can only claim requested, not connected' for RC. The docs describe an `/rc active` indicator in the TUI and a status panel, but whether it is available to hooks/registry remains unverified; do not assert either way.

### Missed by the report

- Root cause of the 2026-10-05 outage per the maintainer (comment on #1866, 2026-10-05T20:17Z): the hosted DB grew to 2.5 TB; two co-founders asleep; ~8 hrs. Shows the relay is a tiny-team single point of failure, stronger evidence than the report gives.
- Billing/policy: Happy Agent 're-implements' Claude Code prompts/tools and 'picks up the Claude ... sign-ins on the machine' (happy.engineering/welcome/, README 'Reuse your subscriptions'). That means it drives the user's Claude subscription credentials from a non-Anthropic harness; whether Anthropic's terms allow this is not addressed in the report and is not verified here. A Loom design that wants to stay on documented, supported interfaces should note Happy's new direction is the opposite and carries policy risk. Voice is the only paid feature (20 free min / 30 days) per happy.engineering/welcome/.
- Happy's remote mode passes CLAUDE_CODE_ENTRYPOINT (happyEntrypoint.ts, sdk/query.ts:61-67) to keep sessions out of the 'sdk-*' filter so they show in `claude --resume`; this is a concrete example of Happy relying on an undocumented picker filter.
- Local-mode sandbox, SessionStart hook and thinking detection each rely on private/undocumented things: the launcher script replaces global.fetch in Claude's Node process (version-fragile) and filters fetch hosts; the report notes this but not that Happy also writes a temp --settings file under ~/.happy/tmp/hooks/ per pid.
- #1870 additional finding (comment 2026-10-06): when the relay drops mid-push, SESSION_SCANNER still marks the in-flight message as sent, so messages can be silently lost on the phone; a delivery-accounting bug relevant to any 'mirror transcript' design.
- Happy Agent/Desktop details from https://happy.engineering/welcome/: durable sessions across restarts, Git worktree per parallel workspace, Auto mode with OS sandbox and automatic review of boundary-crossing actions, and 'Chief of Staff' setup bot. These indicate where the product is heading (own harness, own permission model) and are not covered by the report beyond a one-liner.

## Sources

- https://github.com/slopus/happy
- https://github.com/slopus/happy-desktop
- https://github.com/slopus/happy-agent
- https://happy.engineering/docs/how-it-works/
- https://happy.engineering/docs/security/
- https://happy.engineering/docs/features/
- https://happy.engineering/docs/faq/
- https://happy.engineering/docs/comparisons/alternatives/
- https://happy.engineering/docs/quick-start/
- https://happy.engineering/docs/versions/known-issues/
- https://apps.apple.com/us/app/happy-codex-claude-code-app/id6748571505
- https://play.google.com/store/apps/details?id=com.ex3ndr.happy
- https://api.npmjs.org/downloads/point/last-month/happy
- https://news.ycombinator.com/item?id=44904039
- https://www.reddit.com/r/ClaudeCode/comments/1o32vzg/someone_convince_me_mobile_dev_isnt_just_theater/
- https://www.reddit.com/r/ClaudeCode/comments/1qg4c0w/using_claude_code_anytime_anywhere/
- https://github.com/slopus/happy/issues/1841
- https://github.com/slopus/happy/issues/1902
- https://github.com/slopus/happy/issues/1859
- https://github.com/slopus/happy/issues/1894
- https://github.com/slopus/happy/issues/1867
- https://github.com/slopus/happy/issues/1870
- https://github.com/slopus/happy/issues/1817
- https://github.com/slopus/happy/issues/1829
- https://github.com/slopus/happy/issues/1830
- https://github.com/slopus/happy/issues/1831
- https://github.com/slopus/happy/issues/1833
- https://github.com/slopus/happy/issues/875
- https://code.claude.com/docs/en/remote-control
- https://code.claude.com/docs/en/interactive-mode
- local clone: ~/Library/Caches/loom-v2-research/repos/happy (packages/happy-cli/src/claude/*, packages/happy-cli/src/daemon/run.ts, packages/happy-cli/scripts/claude_local_launcher.cjs, packages/happy-server/sources/app/push/pushDispatch.ts, packages/happy-app/sources/components/SideChatPanel.tsx, docs/roadmap.md, docs/permission-resolution.md, docs/voice-architecture.md, docs/encryption.md)
