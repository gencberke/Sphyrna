# Loom v2 research and brainstorm

> **Second pass (17 Oct 2026):** the user found this pass too timid and asked for a fuller, chat-centred app. [V2-CONCEPT.md](V2-CONCEPT.md) and its [prototype](../../design/v2-studio-preview.html) replace the planner's recommendation and the decisions below ([mapping](V2-CONCEPT.md#11-the-first-passs-decisions-mapped)). The research, the idea catalog and the findings about today's Loom stay valid.

**Date:** 17 Oct 2026 · **Kind:** research round, ideas only · **State:** waiting for the user's reading and decisions. Nothing here is a decision. [DECISIONS.md](../../DECISIONS.md) and the [product contract](../../LOOM-PRODUCT-CONTRACT.md) are unchanged.

**The user's ask (17 Oct, in Turkish, paraphrased):** Loom gets a v2-scale upgrade, and the main goal is to make it the user's main development app. Add features while keeping Loom's lightness principles. Borrow a lot from widely used open-source and commercial agent-harness wrappers that are each good in their own area (T3 Code, Orca, Conductor and others), choosing products with thousands of real users and frequent discussion over small repos. The round may go as far as widening the design patterns, even moving from the "Claude Code terminal" look toward a chat interface. Search the web and read the code. This round collects data and ideas only.

## How to read this

| File | What it holds |
| --- | --- |
| This file | The summary, the landscape, what it means for Loom, the planner's recommended path, the spikes and the decisions for the user |
| [IDEAS.md](IDEAS.md) | The 44 canonical ideas with verdict, cost and value. Each links to a full card in [ideas/](ideas/) (design in Loom terms, principle check, experiments, questions) |
| [DIRECTIONS.md](DIRECTIONS.md) | Three complete v2 directions (Cockpit, Conversation-centred, Lean), the judge's scores and the completeness critic's findings |
| [products/](products/) | 19 product notes and 4 theme notes, each with a fact-check section that wins over the report text |
| [evidence/](evidence/) | Raw JSON of every agent result and the two digests used for synthesis |

## Method

1. **Scout** (4 parallel sweeps: GitHub, community threads, official and commercial apps, terminal-native and mobile tools): 73 candidates, each with popularity evidence (stars, HN points and comments, npm downloads, store ratings, funding, user claims).
2. **Select:** 19 products or clusters that real people use and discuss, plus 4 cross-cutting themes.
3. **Deep dive:** one researcher per product read the docs, changelogs and community threads. For open or source-available products, the researcher also shallow-cloned the repo (outside the repo, read only, nothing run) and traced the code paths that matter: how the product drives the agent, how it detects state, what it persists and what it costs. Each report was then **fact-checked by a second, skeptical agent** (509 claims checked: 350 confirmed, 131 partly, 14 refuted, 14 unverifiable).
4. **Synthesis:** about 170 ideas were clustered into 44 canonical ideas. One critic per idea then read Loom's own code and docs and judged it against Loom's principles. After that, three designers built competing v2 directions, a judge scored them, and a completeness critic looked for gaps.
5. **Planner check:** the planner read the decisive reports and fact-checks and spot-checked the claims everything else rests on: OSC 7501 in the official docs, the installed CLI version (2.1.300), the billing pause, and the code findings in [Today's Loom](#findings-about-todays-loom).

About 100 agents, 17 Oct 2026. Caveats: GitHub stars in this category are inflated (Orca's 94.8k stars against a 21-point Show HN is the extreme), so the reports weight HN/Reddit discussion, npm downloads and store ratings more. Several competitor failure numbers are single-user reports and are treated as failure classes, not baselines. Vendor-written comparison pages were not used as evidence.

## Summary

1. **The category converged.** Nearly every popular app now ships the same core: a sidebar of many sessions with hook-driven working / needs-you / done status, worktree-per-task, a diff pane whose line comments go back to the agent, PR/CI chips, notifications with "jump to next unread", a CLI or socket that agents can drive, a phone companion and a usage bar. They differ in second-order ideas.
2. **Two camps:** *real CLI in a terminal* (cmux, herdr, Warp, Supacode, Orca's core, Loom) and *chat UI over an SDK or ACP engine* (T3 Code, Conductor, Paseo, Zed's structured threads, Claude Desktop, Codex app). The chat camp keeps paying for it in three ways. It always trails the CLI's features. It pins or bundles CLI versions. And it is exposed to Anthropic's billing policy for headless/SDK use, which moved four times in ten months (announced separate credits from 15 June, then paused the same day). **The winning hybrids render the real session instead of replacing it.**
3. **The loudest complaint about every competitor is weight.** That includes the native one: cmux's SwiftUI sidebar hit 100% of a core and GBs of memory. Electron peers report 400 MB to 1 GB with two sessions, 11 GB of disk, polling storms and PTY-daemon leaks. **Loom's lightness is a validated, rare differentiator. Keep it as the product's identity, not a constraint to trade away.**
4. **Anthropic is absorbing breadth.** Claude Desktop already has diff and batched comments, a side chat (Cmd+;), PR/CI monitoring and preview. The CLI has Agent View (`claude agents`, with project filter, Ready for review group and PR labels), Remote Control, `/btw`, `/diff`, cross-session messaging and `--worktree`. A light personal host cannot win on breadth. It wins on **status truth, verified outcomes, sessions that cost nothing when idle, the subagent tree, a native fast window, and fit to this user's day** (tickets, projects, vault).
5. **The bottleneck is the human, not generation.** Measured studies and practitioner reports agree: review and attention limit throughput. The practical ceiling is about 2-3 interactive sessions (3-5 with strong separation), and plan quota is the second ceiling. So v2 should make *knowing and acting* cheaper (who needs me and why, what changed, what it costs), not run more agents.
6. **The Claude CLI now offers documented surfaces a host can build on.** These include OSC 7501 status in-band (2.1.295+), statusline JSON (context %, rate limits, cost), richer hooks (PermissionRequest decisions, Stop with `last_assistant_message` and `background_tasks`, StopFailure reasons, `http` handlers), `/btw`, `--fork-session`, `--remote-control`, `claude agents --json` and mods. Much of what competitors built themselves, Loom can surface.
7. **The user's chat-centred wish has a safe shape:** a **Conversation view of the same real session**, rendered from Claude's transcript the way Loom's subagent panel already works. Read-only first, then an optional live toggle. An optional stream-json "Chat mode" stays a gated, opt-in experiment because of the billing policy and roughly 230+ MB per idle child.
8. **The user's side chat wish has a native mechanism:** a forked real session (`claude --resume <id> --fork-session`) shown beside its parent, with `/btw` as the zero-cost first step. Together with the subagent transcript it makes a strong case for **one right panel** (D-34).
9. **Writing into a live session is the riskiest new capability,** and every competitor does it without proof. Loom is the only one positioned to verify delivery: it owns the PTY, and the UserPromptSubmit hook sees the submitted prompt. Until a send-matrix spike passes, any write path is *draft-only* and labelled "sent, unconfirmed".
10. **Three cheap findings about today's Loom** came out of the research (below): background tasks of any kind keep a session "under way", Claude's idle notice turns orange, and the outbound cross-session gap is open.

## The landscape

### Products studied

Adoption figures are from 17 Oct 2026 unless noted. Full notes and fact-checks are in [products/](products/).

| Product | Kind | Adoption signal | What users love | Main complaint | Best lesson for Loom |
| --- | --- | --- | --- | --- | --- |
| [Orca](products/orca.md) | Electron "ADE", MIT; real CLI in PTYs, optional chat UI, PTY daemon | 94.8k stars (inflated), near-daily releases, "Orca ADE is incredible" threads | Status sidebar across many worktrees, always-visible usage bar, mobile, diff annotate | 400 MB-1 GB with 2 sessions, an 11 GB disk report, daemon generations leaking | Hook status with an honest "unverifiable" state; status-gated send |
| [herdr](products/herdr.md) | Rust TUI multiplexer; a server owns the PTYs | 44.4k stars, HN 404 pts, YC | Seeing which agent needs you; agents spawn and `wait` on each other | Screen-scraped status gives false idles; it dropped hooks after stale-hook bugs | Read/wait verbs for agents; "explain this status" |
| [cmux](products/cmux.md) | Native Swift + libghostty terminal | 28.2k stars, Show HN 198 pts | Notification rings, jump to latest unread, branch/PR/ports in the sidebar | SwiftUI sidebar layout loop at 100% CPU, GBs of RSS | A sidebar performance budget as tests; context in notifications |
| [T3 Code](products/t3code.md) | Chat-first over the Agent SDK; Electron, web, mobile | 28k stars, 7.5k forks, Theo's audience | Chat UX, Orchestrator V2 delegated tasks, mobile | Slower than native Codex, breaking V1→V2, pinned CLI minimums, SDK parity treadmill | Park/snooze/pin lifecycle; per-turn checkpoint refs |
| [Conductor](products/conductor.md) | Closed Tauri Mac app; worktree workspaces; SDK chat | "100k+ builders" (self-reported), $22M Series A, HN 228 pts | Deepest diff-to-merge loop, setup/run scripts, "does not hide what it does" | Chat trails the CLI, bundled pinned CLI, billing exposure | Lazy diff with comments pasted, never auto-submitted; PR chip at turn end |
| [Claude official](products/claude-official.md) | Desktop Code tab (SDK host) + the CLI | Claude Code 151k stars; >$2.5B run rate | Desktop diff + comments, side chat, PR/CI monitor; CLI Agent View, Remote Control, `/btw` | Sidebar reshuffles on attention; Electron weight (anecdotal) | Build on documented surfaces instead of parallel machinery |
| [Codex app](products/codex-app.md) | Electron over `codex app-server`, now inside ChatGPT desktop | 1M downloads in week one; 5M+ weekly users (June) | Threads by project, side chat, scheduled runs into a triage inbox | Side chats lost on close; resource use | A side chat must be durable; "mark unread"; usage by source |
| [Superset](products/superset.md) | Electron, source-available (ELv2) | 15.3k stars, HN 96 pts / 90 comments | Worktree + terminal + ports per task, Cmd+I prompt editor, review pane | git subprocess fan-out, input lag, global hooks | Composer with drafts and receipt; filter background tasks by type |
| [Paseo](products/paseo.md) | Daemon + Electron/Expo; chat-first with terminal tabs | 21.2k stars; users switched from Conductor | Full mobile parity, polish | Always-resident runtime, OOM at scale | Parent/child links with finish notices; project roll-up dot |
| [Warp](products/warp.md) | Rust GPU terminal running third-party CLIs in PTYs | 65.5k stars, ~1M devs (vendor) | Vertical tabs with status, notification centre via plugin, review comments pushed into the CLI | Memory bloat issues | Notification content and lifecycle rules; title precedence |
| [Zed](products/zed.md) | Rust editor; ACP threads + terminal threads | 91.8k stars; 1.0 in April | Parallel threads sidebar; terminal threads as the escape hatch | Only one visible conversation | Keep-awake while working; context meter; do not adopt ACP for Claude |
| [Cursor 3](products/cursor.md) | Agents Window on an IDE | >$2B ARR (press) | Multi-repo sidebar, tiled chats, review tab, Dock unread list | The forced Agents Window | Dock menu of unread; a fast new-session sheet |
| [Emdash](products/emdash.md) | Electron ADE with ticket intake | 6k stars, HN 206 pts | Ticket → task from about 12 trackers; diff/commit/PR/CI | A worktree pool it later removed | New session from ticket; event-driven PR strip |
| [OpenChamber](products/openchamber.md) | Chat front end for OpenCode | 11.7k stars, HN ~200 pts | Goal loop, message queue, mobile | Resource creep, list polling | Goal mode via the Stop hook; a user-owned "In work" block |
| [Vibe Kanban](products/vibe-kanban.md) | Kanban runner; company shut down 10 Apr 2026 | 28.4k stars; npm peak 88.8k/month | Board + diff comments + preview | Pinned CLI versions, a cloud that died | Derive the ticket ledger, do not run a board |
| [Supacode](products/supacode.md) | Native Swift/TCA + libghostty + zmx daemon | 2.4k stars, fast-rising | "Needs you" hoisted, sessions survive Quit | gh/git polling storms with many repos | Severity-ordered hoist; keep-awake |
| [Happy](products/happy.md) | Phone client + E2E relay | 24k stars, 40.5k npm/month, store 4.9/5.0 | Approving from the phone | Two runtimes per session, relay outages | Use Claude's Remote Control instead of a relay; presence file |
| [Usage tools](products/usage-tools.md) | ccusage, CodexBar, claude-hud, ccstatusline | ccusage 877k npm/month; claude-hud 28.6k | Pace, reset countdown, context % | Process spawn per statusline update | Context meter, plan pace, provenance on every number |
| [Attention surfaces](products/attention-surfaces.md) | Notch/menu-bar approval overlays | CodeIsland and peers ~2.5k stars each | Approve, deny and answer questions from an overlay | Global settings.json edits, idle CPU | Rich approval preview; actionable notifications (gated) |

Themes: [chat UI paths](products/chat-ui-paths.md), [power-user workflows](products/power-user-workflows.md), [review and git loop](products/review-git-loop.md), [persistence, remote and orchestration](products/persistence-remote-orchestration.md).

### What the field teaches, in one table

| Pattern | Who does it well | Verdict for Loom |
| --- | --- | --- |
| Hook-driven status with an honest "unknown" | Orca (unverifiable), herdr (unknown + explain) | Loom already leads here. Harden it and explain it (I-12) |
| Context on the card and in the notification: what it asks, last line | cmux, Warp, Supacode | Cheap and high-value (I-14) |
| Diff pane → line comments → one batched prompt | Conductor, Claude Desktop, Orca, Warp | Wanted, but Desktop/`/diff` already cover it. Start with a "+N −M" chip and a read-only pane (I-28), then comments (I-29) |
| Worktree per task with setup scripts | Conductor, Superset, Orca, Emdash | Contested: ports, DBs and `.env` are not isolated. Lean on `claude --worktree` when wanted (I-32) |
| Chat UI over an SDK | T3, Conductor, Paseo | Do not use it for the main path. Render the real session instead (I-05/I-06) |
| Side chat | Claude Desktop (Cmd+;), Codex (`/side`), Cursor | The user's oldest wish. `/btw` now, a forked real session next (I-08/I-09) |
| PTY daemon so sessions survive Quit | herdr, Orca, Supacode, Superset | Skip. It is the field's largest pain source. Use hibernate-and-resume instead (I-19, I-21) |
| Phone companion with own relay | Happy, Orca, Paseo, T3 | Skip the relay. Claude's Remote Control is the light path (I-42) |
| Agents drive the app through a CLI/socket | herdr, cmux, Orca | Extend Loom's authenticated socket: read and wait verbs first (I-36) |
| Usage pace and context % | ccusage, claude-hud, CodexBar, Orca | Loom has usage already. Add pace, provenance and context (I-23, I-25) |
| Kanban runner | Vibe Kanban (dead) | Skip. Derive a ticket view from facts (I-34) |
| Embedded browser / design mode | Orca, cmux, Superset | Skip for a backend-focused user. Show a dev-server pill that opens the default browser (I-43) |

## What it means for Loom

**Validated as right:** the real CLI in a PTY (policy-safe and update-resilient; Warp's and Zed's terminal threads show it is a shipped design), hook-driven status with drift detection, verified Stop and Quit, the ended screen and resume instead of a daemon, event-driven usage, per-session `--settings` hooks instead of editing the user's global settings (competitors who edit the global file collect bug reports), and the subagent tree.

**Exposed:** today Loom answers "does it need me" well but not "why", "what changed" or "what does it cost". It has no way to read a stopped session except its last screen, no side thread, no review aid, and no safe way to put text into a session. And Agent View now covers basic triage inside the CLI itself.

**Where Loom can win:** be the *honest, light cockpit over the real Claude Code CLI*. Show truth (status, reason, context, pace) on one screen across projects. Offer read-only views of the same session (the Conversation view, the subagent panel). Give side threads that are real sessions. Keep every action verified and every idle session at zero cost. That identity is distinct from Orca/Conductor (workspace owners), cmux (a multiplexer), T3 Code (a chat engine) and Claude Desktop (the vendor's broad client).

## The Claude Code platform Loom can build on

Installed CLI: 2.1.300. "Documented" means on code.claude.com; versions are from the docs or changelog.

| Surface | Since | Status | What Loom can do with it |
| --- | --- | --- | --- |
| Hooks: PermissionRequest (allow/deny with `updatedInput`), Notification types (`permission_prompt` ~6 s, `idle_prompt` ~60 s after a finish), StopFailure reasons, Stop with `last_assistant_message`, `background_tasks`, `session_crons` | 2026 | documented | Reason lines, sticky failure, better background handling; answering approvals only after a race spike (I-12, I-14, I-15) |
| `http` hook handler, `onFailure: "block"` | 2.1.295 | documented | Replace the per-event `loom-hook` spawn with a POST to Loom's local endpoint (the critic's missed idea) |
| statusLine JSON (context %, `rate_limits`, cost, worktree) | earlier, extended in 2026 | documented | Official context and pace numbers via a bridge that chains the user's own script (I-24, spike) |
| OSC 7501 Program Status Protocol | 2.1.295 | documented, new (spec 0.4) | A second, in-band state source in SwiftTerm as a cross-check (I-13). Cheap to capture during the recording day |
| `/btw` side questions; Desktop side chat (Cmd+;) | 2026 | documented | Zero-cost side chat shortcut (I-08) |
| `--fork-session`, `/branch` | earlier | documented | Side chat as a forked real session (I-09) |
| `--remote-control`, `claude remote-control` server, push notifications, `CLAUDE_CLIENT_PRESENCE_FILE` | out of preview Aug 2026 | documented | Per-session "reachable from phone" toggle, no relay (I-42). Open question: Loom sets `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`, which the docs say disables the on-demand supervisor |
| `claude agents --json`, `--bg`, `attach` (supervisor) | 2.1.1xx-2.1.2xx | documented; state files unstable | A documented cross-check for state; an optional "detached" mode much later (I-22) |
| Cross-session messaging (ListAgents/SendMessage), `crossSessionInbound` accept/hold/refuse | 2.1.224 | documented; wire format not | Loom sets `refuse`, so nothing comes in, but **outbound sends to non-Loom sessions are not covered**. Build the D-43 channel as an authority broker on Loom's socket (I-37) |
| Mods (in-process plugins, `$.prompt.submit`) | 2.1.287 | documented, young, API churn, unsandboxed | Watch list only |
| stream-json control protocol (`claude -p`), `session_state_changed` | SDK typings | typed, opt-in env var; billing-sensitive | Optional Chat mode, gated (I-07) |
| Auto mode as the default permission mode | 2.1.283 | documented | Approvals are rarer than the old statistics suggest, so Loom-side approval UIs matter less |
| `/rewind` checkpoints | earlier | documented | Covers only Claude's own file edits (not Bash or subagents). Link to it, do not rebuild it |
| `idleCompaction` setting | 2.1.290 | documented | Explains hidden token spend on idle long contexts; worth a usage hint |

**Policy note.** As of the 7 Oct support text, the Agent SDK, `claude -p` and third-party apps still draw from subscription limits. The metering change announced for 15 June was paused "for now". The legal page asks SDK-based products to use API keys and allows the unmodified binary with the user's own login. Hosting the interactive CLI in a PTY, as Loom does, is the safe side. Any headless or stream-json feature must be an isolated, killable opt-in, and the support article must be re-read before each release.

## The idea catalog in brief

Full list with links: [IDEAS.md](IDEAS.md). Value is for this user (1-5); "sources" counts the research reports that proposed the idea independently.

| Area | Strongest ideas (sources, verdict, cost) |
| --- | --- |
| Attention and status | **I-14** reason on attention cards and in banners: what it asks, last line, notification text (6, adopt-light, M, value 4) · **I-12** status hardening + "Why this status?" (9, adopt-light, S) · **I-17** attention-routing polish (7, adopt-light, M) · **I-16** rich approval preview, question card, plan review (5, spike-first, L) · **I-15** answer approvals from Loom (6, spike-first, M) · **I-11** subagent tree upgrades (4, adopt-light, M) · **I-13** OSC 7501 receiver (1, spike-first, M) |
| Conversation and chat | **I-05** read-only Conversation view of the same session (11, adopt-light, L, value 4) · **I-06** chat lens with composer over the live PTY (8, spike-first, XL) · **I-07** opt-in stream-json Chat mode (1, spike-first, XL) |
| Side chat and panels | **I-09** side chat as a forked real session (14, spike-first, L, **value 5**, the highest in the catalog) · **I-08** `/btw` shortcut (6, adopt-light, S) · **I-10** right-hand panel (6, spike-first, L) |
| Input | **I-01** verified send-to-session primitive (12, spike-first, M) · **I-02** per-session prompt queue (7, spike-first, M) · **I-03** composer overlay (3, spike-first, M) · **I-04** input fidelity audit (2, adopt-light, S) |
| Review and git | **I-28** read-only Changes pane / "+N −M" chip (14, adopt-light, M) · **I-29** review comments batched back (10, adopt-light, L) · **I-31** PR/CI chip and canned actions (7, adopt-light, M) · **I-30** per-turn checkpoints (8, spike-first, L) |
| Worktrees, tickets, launch | **I-32** worktree-backed sessions (10, adopt-light, M) · **I-33** fast new-session sheet, presets, `loom://` URLs (5, adopt-light, M, value 4) · **I-34** ticket-centred sessions (3, adopt-light, M) |
| Context and usage | **I-25** plan pace, provenance, cache-cold hint, limit actions (5, adopt-light, M, value 4) · **I-23** per-session context meter (5, adopt-light, M) · **I-26** rollups by project, ticket and source (3, adopt-light, M) · **I-24** statusLine bridge (2, spike-first, M) · **I-27** multiple accounts (2, later) |
| Lifecycle | **I-20** keep the Mac awake while working (5, adopt-light, S, value 4) · **I-18** park / snooze / in-work flags (2, adopt-light, M, value 4) · **I-21** "Resume interrupted" after Quit or crash (2, adopt-light, M) · **I-19** idle auto-park (5, spike-first, M) · **I-22** supervisor integration (3, later, XL) |
| Orchestration | **I-37** cross-session channel as a user-authority broker (9, adopt-light, L, value 4) · **I-36** `loom` CLI read/wait verbs and event hooks (7, adopt-light, M) · **I-35** extend "a session opens a session" (5, adopt-light, M) · **I-38** handoff digest and fresh reviewer (5, adopt-light, M) · **I-39** goal mode via the Stop hook (1, adopt-light, M) |
| Other | **I-41** cross-session transcript search (4, adopt-light, M) · **I-42** Remote Control toggle and presence file (7, spike-first, M) · **I-43** dev-server pill and process inspector (5, adopt-light, M) · **I-44** engineering guardrails: render budgets, fixtures (7, adopt-light, S) · **I-40** scheduled runs (4, later, XL) |

The research also gives a clear [do-not-build list](IDEAS.md#do-not-build): a Loom PTY daemon, an SDK/ACP/Node engine for the main session, TUI screen-scraping, notch overlays and mascots, a Loom relay or phone app, reading the CLI's OAuth token for usage, an embedded browser, an automatic reviewer agent, a kanban runner, a plugin marketplace, per-repo polling, auto-commit or a rewind engine, and blind writes into the PTY.

## Three directions and the judge

Details: [DIRECTIONS.md](DIRECTIONS.md).

| Direction | Thesis | Productivity | Lightness | Risk (5 = low) | Effort (5 = least) | Identity | Total |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Cockpit** | Terminal stays the centre; Loom is the best attention, context and review instrument around it; ~3.5-4.5 months | 4 | 5 | 4 | 3 | 4 | 20 |
| **Conversation-centred** | The conversation is the front door, the terminal the engine room; a lens over the same CLI, with composer and right panel; XL | 4 | 3 | 2 | 2 | 5 | 16 |
| **Lean** | Smallest high-leverage set in three gated releases (0.5 Trust the dot, 0.6 Read it without the terminal, 0.7 Ask aside); ~9-12 weeks | 3 | 5 | 5 | 4 | 4 | 21 |

The judge recommended "Lean Cockpit with a Conversation view". It takes Lean's three gated releases as the spine, adds Cockpit's evidence week and card reason line, and takes the Lens source-agnostic transcript model and send rules. It defers the right panel, the submit path, Allow/Deny from Loom, Chat mode, the Changes pane with comments, worktrees and cross-session send.

## The planner's recommendation

I agree with the judge's spine and gates, with three changes the completeness critic and the user's own goal argue for:

1. **The side chat and the right panel are not gated on demand, only on mechanism.** The user has asked for a ChatGPT-style side thread and a right panel since Herdr Desktop. A week of `/btw` (one answer, no tools, in memory) cannot show that a persistent, tool-enabled side thread is unnecessary. And a side chat swapped into the place of the main terminal defeats its purpose: seeing both at once. So the fork spike decides *how*, and the third release ships the side chat **in a collapsed-by-default right panel**. That panel also takes the subagent transcript, which today replaces the terminal. This lifts D-34 for one panel, which needs the user's decision.
2. **A cheap review aid comes early.** The measured bottleneck is review, so a "+N −M, K files" chip computed at Stop (bounded `git diff --shortstat`, event-driven), with "Open in editor" / "Copy patch", belongs in the second release. The full diff pane with comments stays later.
3. **Today's status findings are fixed first** (next section). They are small, and they are exactly the "truth" the product promises.

**Product rule (proposed contract wording, user decision):** *The live session is always the real Claude Code CLI in a PTY that Loom owns. Loom adds truth (status, reason, context, cost), read-only views of the same session, and actions whose outcome it verifies.*

| Release | Goal | Contents | Size |
| --- | --- | --- | --- |
| **v2.0 "Trust"** | Every card and banner says what is going on and why, at no new cost | Fixes below; I-44 render budgets and hook fixtures; I-12 (sticky failure handled with synthetic continuations, "Why this status?" in the ⋯ menu); I-14-light (reason line on attention cards only after a design preview; banner details behind a privacy switch); I-20 keep-awake while working (off by default); I-25-light plan pace; I-17-light (quit sheet names working sessions, Dock menu of "needs you"); I-08 `/btw` shortcut; I-04 input audit | ~2-3 weeks plus one recording day |
| **v2.1 "Read"** | Any session is readable and resumable without a live terminal | I-05 slice A: Conversation view for stopped, stale and relaunched sessions, reusing the subagent transcript machinery, unknown records shown raw, oversized lines marked rather than dropped; I-21 "Resume interrupted"; I-23 context figure; I-11 tier 1 (which subagent asks, no stuck "running"); "+N −M" changes chip; I-41 stage 1 search if the corpus measurement fits | ~4-5 weeks |
| **v2.2 "Aside"** | The side thread and the right panel the user has wanted | I-09 side chat as a forked real session (plan mode by default, promote to edit, verified Discard through the existing deletion path, nested under the parent); I-10 right panel (collapsed by default; Side chat and Subagents tabs; PTY resize measured); I-01 draft-only "Place in prompt" labelled "sent, unconfirmed" | ~4-5 weeks after the fork spike |

**After v2.2: tracks the user picks by need, each behind its own spike.**

| Track | Contents | Gate |
| --- | --- | --- |
| Act | I-01 Send, I-02 prompt queue, I-03 composer, I-15/I-16 approvals and question cards from Loom | Send matrix 20/20 with 0 stray Enter into a dialog; hook/dialog race spike; the user feels typing pain |
| Work | I-33 new-session sheet and presets, I-34 tickets, I-31 PR/CI chip, I-32 worktrees, I-28/I-29 full review pane with comments | User facts: GitHub or GitLab, worktree habits, tracker |
| Together | I-36 read/wait verbs, I-35 parent/child and batch open, I-37 channel as authority broker, I-38 handoff | D-46 dated by the user; I-01 proven |
| Chat | I-05 slice B live toggle → I-06 chat lens with composer → I-07 stream-json Chat mode | A few weeks of v2.1 use show the user reading mostly in the Conversation view; billing policy re-read |
| Away | I-42 Remote Control toggle, presence file, content-free push | Remote Control works with Loom's environment |
| Lifecycle | I-18 park/snooze/In work, I-19 manual Sleep then opt-in auto-park | Resume-fidelity spike; D-38 amendment for auto-park only |

## Findings about today's Loom

These came out of the research and were checked in the code by the planner. They are candidates for v2.0, not defects confirmed in use.

| Finding | Evidence | Effect | Suggested fix |
| --- | --- | --- | --- |
| Every `background_tasks` entry, whatever its type, plus `session_crons`, counts as pending provider work | `ClaudeHook.swift:461` (`collectionCount`), `ProviderSessionAdapters.swift:84,301`, `SessionEventHub.swift:338` (`.turnComplete where pendingProviderWorkCount > 0 → .underWay`) | A background dev server, monitor shell or cron could keep a session in Active "under way" indefinitely, and would hold a keep-awake assertion if I-20 is built naively | Count only subagent and workflow tasks as work (Superset's fix, PR #8114); show other background work as "waiting on background work" (I-12, recording day) |
| Claude's `idle_prompt` notice (about 60 s after a finished turn) maps to "Waiting for you" (orange) | `ClaudeHook.swift:791` | The Active section ignores it after a read turn (by design), but cards, the Dock badge, the menu bar and Cmd+J may still count an orange state for a turn the user already read; the critic calls this decisive for badge trust | Decide its meaning: a reminder, not "needs you", for completed turns (cmux maps it that way); verify on the recording day |
| `crossSessionInbound: "refuse"` blocks only incoming messages | `ProviderLaunchProfile.swift:181`; contract §7 | A Loom session can still SendMessage to non-Loom sessions, and `refuse` also turns off native `notify_when_idle` | Name the gap in v2 and decide it with the channel (I-37) |
| `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` is set for every session | `ProviderLaunchProfile.swift:147` | The docs say it also disables the on-demand supervisor; whether Remote Control still works is untested | Test with the I-42 spike before offering a phone toggle |
| SubagentStop also fires for Claude's internal agents (prompt suggestions, `/btw`) | Claude hooks docs (claude-official fact-check) | Once `/btw` is promoted (I-08), the subagent tree might show or count internal agents | Record on the recording day; filter by type if needed |

## Spikes before building

All real-Claude work runs in an **isolated `CLAUDE_CONFIG_DIR`**, never the real `~/.claude`. Logging that profile in is the user's own action. Budget: about 100-150 short turns (D-04 needs the user for large budgets). Window and CPU checks wait until the user says the Mac is idle.

| Spike | Decides | When |
| --- | --- | --- |
| **Recording day** with loom-probe's hook recorder: Stop and `background_tasks` types, `idle_prompt` timing, PermissionRequest payloads (Bash, Edit, MCP, AskUserQuestion, ExitPlanMode), `last_assistant_message`, subagent closure on Esc, `/btw` side effects, usage-limit wait sequence, OSC 7501 wire capture | Scope of I-11, I-12, I-14, I-16, I-25, I-13 and the I-44 fixtures | Before v2.0 |
| Main-session transcript fixtures and a 50-100 MB synthetic transcript (record types, line sizes, resume/compact/rewind ids, cold open ≤ ~1.5 MiB) | I-05 go and the turn-builder design | Before v2.1 |
| Fork spike: `--resume --fork-session` with `--session-id`, mid-turn fork, plan mode holding, cache reuse, residue and deletion coverage, `--resume` picker pollution | I-09 mechanism | Before v2.2 |
| Right-panel resize: PTY reflow cost and Claude redraw when the terminal narrows | I-10 layout | Before v2.2 |
| Send matrix: bracketed paste + separate Enter, delays, sizes, leading `/ ! @ #`, behaviour in permission, question, plan, trust and picker states | Whether any write path goes beyond draft-only | Before the Act track |
| Hook/dialog race: a held PermissionRequest hook vs the TUI dialog | Whether Allow/Deny from Loom exists at all | Before the Act track |
| Remote Control with Loom's environment | I-42 | Before the Away track |

## Decisions for the user

Each has options; the first is the planner's recommendation.

1. **Product rule and contract wording.** (a) "The live session is always the real CLI; Loom adds truth, read-only views and verified actions" (recommended); (b) the same plus the right to a composer-led live view later, after data; (c) keep "the terminal is never replaced by a custom chat UI" and skip the Conversation view.
2. **Chat-centred look, how far now.** (a) Read-only Conversation view first (v2.1), live toggle only after use (recommended); (b) plan the live chat lens with composer as v2's headline (the Conversation-centred direction, XL, higher risk); (c) no chat look.
3. **Right panel (D-34).** (a) Lift D-34 for one collapsed-by-default right panel holding side chat and subagent transcripts, in v2.2 (recommended); (b) keep it deferred and swap the side chat into the terminal's place; (c) never.
4. **Side chat shape.** (a) A forked real session, plan mode by default with "promote to edit", persistent until Discard, nested under its parent (recommended); (b) `/btw` only; (c) ephemeral and deleted on close. Also: should it go inactive (stop its process) after a while, as in the user's ChatGPT description? The planner suggests yes, through the ended screen and resume, never by deleting.
5. **Stopped sessions' default view.** (a) The Conversation view replaces the ended-screen snapshot once transcripts resolve reliably, with the snapshot kept as a fallback (recommended); (b) keep the snapshot.
6. **Writing into sessions.** (a) Draft-only "Place in prompt", the user presses Return, until the send matrix passes (recommended); (b) a gated Send if it passes; (c) no write path. Also: is the pain *typing* into sessions, or mostly *reading and catching up*?
7. **Approvals.** Which permission mode do you normally run (auto, acceptEdits, manual)? (a) Approve in the CLI; Loom shows what is asked (recommended); (b) Allow/Deny from Loom, only if the race spike passes.
8. **Card density and privacy.** (a) A third line on attention-state cards only, after a design preview; banner details behind an off-by-default switch (recommended); (b) tooltip and banner only; (c) exactly two rows.
9. **Facts only you have.** Are the work repos on GitHub or GitLab? One worktree per ticket, or several sessions in one folder? Which tracker and key prefixes? Do you run your own statusLine? These decide the Work track.
10. **Cross-session channel (D-43/D-46).** (a) Keep it undated until the send primitive is proven, then start with read/wait verbs (recommended); (b) date the read side now. Should the outbound gap (Loom session → non-Loom session) be closed now?
11. **Spike budget and access.** Approve ~100-150 short real-Claude turns in isolated profiles, log in the isolated profile yourself, and say when the Mac is idle for the render and CPU gates.
12. **Naming.** The view's label ("Conversation", "Chat" or "Transcript") against the rule that user text says "session"; a shortcut that works on the Turkish Q layout.

## Evidence index

- Product and theme notes: [products/](products/) (19 + 4).
- Scout results: [evidence/landscape-scout-20261017.json](evidence/landscape-scout-20261017.json).
- Deep dives and fact-checks: [evidence/deep-dive-20261017.json](evidence/deep-dive-20261017.json).
- Catalog, feasibility, directions, judge, critic: [evidence/synthesis-20261017.json](evidence/synthesis-20261017.json).
- Digests used by the synthesis agents: [evidence/digest-ideas.md](evidence/digest-ideas.md), [evidence/digest-patterns.md](evidence/digest-patterns.md).
- Shallow clones read during the research are outside the repo in `~/Library/Caches/loom-v2-research/repos/` (31 repos, about 4 GB; safe to delete).
