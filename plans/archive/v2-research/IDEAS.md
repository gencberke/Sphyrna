# Loom v2 idea catalog

Appendix of [V2-BRAINSTORM.md](V2-BRAINSTORM.md). 44 canonical ideas clustered from about 170 proposals in the 23 research notes, each tested against Loom's code and principles by its own read-only critic (17 Oct 2026). Verdicts are research recommendations, not decisions. **adopt**: build as described; **adopt-light**: build a smaller version; **spike-first**: run the named experiment before committing; **later**: not now; **skip**: do not build. Value is 1-5 for this user. Raw JSON: `evidence/synthesis-20261017.json`.

## Index

| ID | Idea | Area | Sources | Verdict | Cost | Value |
| --- | --- | --- | --- | --- | --- | --- |
| [I-01](#i-01) | Verified send-to-session primitive | Input and composer | 12 | spike-first | M | 4 |
| [I-02](#i-02) | Per-session prompt queue with verified delivery | Input and composer | 7 | spike-first | M | 4 |
| [I-03](#i-03) | Native composer overlay with per-session drafts and delivery receipt | Input and composer | 3 | spike-first | M | 3 |
| [I-04](#i-04) | Input fidelity audit (image paste, drag-drop paths, dictation) | Input and composer | 2 | adopt-light | S | 3 |
| [I-05](#i-05) | Read-only conversation view of the SAME session (chat-looking transcript, no new engine) | Conversation and chat | 11 | adopt-light | L | 4 |
| [I-06](#i-06) | Chat lens with composer over the live PTY (terminal and chat as two views of one process) | Conversation and chat | 8 | spike-first | XL | 4 |
| [I-07](#i-07) | Optional 'Chat mode': Loom-owned stream-json child per session (no Node, SDK or ACP) | Conversation and chat | 1 | spike-first | XL | 3 |
| [I-08](#i-08) | /btw side-question shortcut (lightest side chat) | Side chat and panels | 6 | adopt-light | S | 3 |
| [I-09](#i-09) | Side chat as a forked real CLI session (the user's ChatGPT-style side thread) | Side chat and panels | 14 | spike-first | L | 5 |
| [I-10](#i-10) | Right-hand context panel (subagents, side chat, changes, notes) | Side chat and panels | 6 | spike-first | L | 4 |
| [I-11](#i-11) | Subagent tree upgrades (who is asking, per-subagent cost, no stuck 'running') | Attention and status | 4 | adopt-light | M | 3 |
| [I-12](#i-12) | Status accuracy hardening and 'Why this status?' | Attention and status | 9 | adopt-light | S | 3 |
| [I-13](#i-13) | Receive OSC 7501 (Program Status Protocol) as a second in-band state source | Attention and status | 1 | spike-first | M | 2 |
| [I-14](#i-14) | Richer card content: what it is asking / last said, peek, agent note, title precedence, notification text | Attention and status | 6 | adopt-light | M | 4 |
| [I-15](#i-15) | Answer approvals from Loom's own surfaces via the documented hook decision | Attention and status | 6 | spike-first | M | 3 |
| [I-16](#i-16) | Rich approval content: real preview, question card, plan review panel | Attention and status | 5 | spike-first | L | 4 |
| [I-17](#i-17) | Attention-routing polish (ordering, roll-up, read/unread, Dock/menu bar, quit dialog, presence policy) | Navigation and launch | 7 | adopt-light | M | 3 |
| [I-18](#i-18) | Park / snooze / In-work: user-owned lifecycle flags for sessions | Persistence and lifecycle | 2 | adopt-light | M | 4 |
| [I-19](#i-19) | Idle auto-park (hibernate): stop the process, keep the card, resume on open | Persistence and lifecycle | 5 | spike-first | M | 3 |
| [I-20](#i-20) | Keep the Mac awake while a session is Working | Persistence and lifecycle | 5 | adopt-light | S | 4 |
| [I-21](#i-21) | Crash-safe state and 'Resume interrupted' after Quit or crash | Persistence and lifecycle | 2 | adopt-light | M | 3 |
| [I-22](#i-22) | Claude supervisor integration: 'Background' visibility lane, then optional 'Run detached' | Persistence and lifecycle | 3 | later | XL | 2 |
| [I-23](#i-23) | Per-session context meter on cards and header | Context and usage | 5 | adopt-light | M | 3 |
| [I-24](#i-24) | statusLine bridge for 'official numbers' (context %, cache, cost, effort, PR state) | Context and usage | 2 | spike-first | M | 3 |
| [I-25](#i-25) | Usage honesty: plan pace, provenance, cache-cold hint, limit-hit actions | Context and usage | 5 | adopt-light | M | 4 |
| [I-26](#i-26) | Usage rollups per project, per ticket and by source | Context and usage | 3 | adopt-light | M | 3 |
| [I-27](#i-27) | Multiple Claude accounts via user-managed config dirs | Context and usage | 2 | later | M | 2 |
| [I-28](#i-28) | Read-only diff / Changes pane per session | Review and git | 14 | adopt-light | M | 3 |
| [I-29](#i-29) | Review comments batched back into the session | Review and git | 10 | adopt-light | L | 4 |
| [I-30](#i-30) | Per-turn checkpoints and last-turn change chip | Review and git | 8 | spike-first | L | 3 |
| [I-31](#i-31) | PR / CI chip and canned git actions | Review and git | 7 | adopt-light | M | 3 |
| [I-32](#i-32) | Worktree-backed sessions (parallel agents on one repo) | Worktrees and parallel work | 10 | adopt-light | M | 3 |
| [I-33](#i-33) | Fast launch surface: new-session sheet, presets, loom:// URLs, recipes, skills launcher | Navigation and launch | 5 | adopt-light | M | 4 |
| [I-34](#i-34) | Ticket-centred sessions (new session from ticket, ticket chip/grouping, derived work ledger) | Tickets and tasks | 3 | adopt-light | M | 3 |
| [I-35](#i-35) | Extend 'a session opens a session' (parent/child, batch fan-out, narrow always-allow, ceilings) | Orchestration and the cross-session channel | 5 | adopt-light | M | 3 |
| [I-36](#i-36) | `loom` CLI + read-only verbs + wait + event hooks (the read side of multi-agent work) | Orchestration and the cross-session channel | 7 | adopt-light | M | 3 |
| [I-37](#i-37) | Cross-session message channel as a user-authority broker (the wanted D-43/D-46 channel) | Orchestration and the cross-session channel | 9 | adopt-light | L | 4 |
| [I-38](#i-38) | Handoff and session reference (bounded digest, fresh session, fresh reviewer) | Orchestration and the cross-session channel | 5 | adopt-light | M | 3 |
| [I-39](#i-39) | User-armed Goal mode driven by the Stop hook | Automation | 1 | adopt-light | M | 3 |
| [I-40](#i-40) | Scheduled runs with a triage inbox (later) | Automation | 4 | later | XL | 2 |
| [I-41](#i-41) | Cross-session transcript search | Search and history | 4 | adopt-light | M | 3 |
| [I-42](#i-42) | Away from the Mac: Remote Control toggle, presence file, optional content-free push | Remote and mobile | 7 | spike-first | M | 3 |
| [I-43](#i-43) | Process-tree view: listening ports / dev-server pill and on-demand resource inspector | Browser and preview | 5 | adopt-light | M | 3 |
| [I-44](#i-44) | Engineering guardrails: performance budgets, reader regression, contract fixtures, compat advisories | Platform reliability | 7 | adopt-light | S | 3 |

## Input and composer

### I-01

**Verified send-to-session primitive** · verdict **spike-first** · cost M · value 4/5 · proposed by 12 reports · [full card](ideas/I-01.md)

> Worth building as a small LoomCore primitive (hook-gated, draft-only by default, hook-confirmed 'delivered', never retried), but the safety claim 'never press Enter into a dialog' is not documented anywhere, so a one-day real-Claude spike (send matrix + modal visibility) must decide the constants and whether 'submit' ships at all.

- **What the user gets:** One safe path that puts text into a running Claude session only when Loom knows it is at an idle prompt, and reports the true outcome (queued, pasted, delivered, outcome unknown). It is the shared foundation for queued prompts, the composer, review comments, canned PR/CI actions, side-answer hand-back and any later cross-session send, and it removes the 'switch to the terminal, paste, hope it was not a permission dialog' step.
- **Why this value:** For a heavy multi-session, multi-agent user it removes the manual switch-paste-hope step and is the common substrate for a queued-prompt list, a composer, review-comment hand-back and side-answer hand-back, and its hook-verified outcomes are something competitors (Superset #6243, Warp, Orca's note path) do not have. Standalone it is nearly invisible (value ~2) until a consumer exists, and the 'submit' half carries real risk, so I rate the foundation 4, not 5. Honest cost: M covers primitive + draft tracker + one popover consumer + tests; the queue/composer/review features built on it are separate (L together).
- **Depends on:** Spike E1/E2 results (this idea's own); Later consumers: queued prompts, composer, review-comment hand-back, side-answer hand-back; D-43 cross-session channel (adds a second origin and per-target approval; needs a documented-interface path to satisfy contract §11 CP3); Optional: mods spike E4 for the dialog-safe upgrade

### I-02

**Per-session prompt queue with verified delivery** · verdict **spike-first** · cost M · value 4/5 · proposed by 7 reports · [full card](ideas/I-02.md)

> Worth building as a small Loom-held "after this turn" queue (a different semantic from the CLI's mid-turn queue), but only after a one-day spike proves that pasting and submitting into the real CLI and matching the UserPromptSubmit prompt really works, since "verified delivery" is the whole premise and the shared I-01 primitive carries all the risk.

- **What the user gets:** Line up the next instruction(s) for a session you are not looking at (or that is still working) in a small strip above the terminal; edit, reorder, 'send now'; Loom delivers when the hooks say the session is Ready and shows queued -> delivered -> failed. Also a global quick-capture hotkey that picks a session and queues text. Removes the wait-then-retype loop across 3-5 sessions, and is the safe user-authorized core of any later cross-session send.
- **Why this value:** The user runs 3-5 sessions and several workflows; "when this finishes, do X" for a session they are not looking at is a recurring, real need, and the CLI's own queue cannot give next-turn semantics (it delivers mid-turn) or offscreen composing. Not a 5: when the session is focused the CLI queue already covers most of it, a persisted queue mostly dies at Quit, and the value depends on the delivery spike.
- **Depends on:** I-01 (the verified send primitive: readiness check, bracketed paste plus submit, UserPromptSubmit digest verification). I-02 is the queue on top of it and should not build its own second copy.; Small core additions that I-01 also needs: a prompt digest on ClaudeHookEvent and a typing/programmatic distinction in TerminalSurface.; Optional: the right panel (D-34) if the user later wants the queue there instead of above the terminal.

### I-03

**Native composer overlay with per-session drafts and delivery receipt** · verdict **spike-first** · cost M · value 3/5 · proposed by 3 reports · [full card](ideas/I-03.md)

> Worth building only as a small, optional helper on a verified send path (paste with a bracketed-paste gate, separate Enter, a UserPromptSubmit receipt), and two real-CLI spikes must first decide the shape: Claude's documented Ctrl+G external-editor hook that nobody in the research saw, versus direct PTY injection. Drop @file, images, persisted drafts and auto-open.

- **What the user gets:** A native multi-line editor (shortcut) for long structured prompts: @file completion from the session cwd, pasted images saved to a file and referenced by path, a draft per session, optional auto-open when a session finishes. The card says 'submitted' only when the hook arrives, else 'not submitted yet, press Enter' with the draft kept.
- **Why this value:** Real but modest for this user. They write long ticket prompts across several sessions, and a multi-line editor with per-session drafts is a comfort gain. But the CLI already offers Ctrl+G, multi-line paste, Ctrl+V images and message queueing, so the new value is mostly Loom-side (a draft that survives a session switch, and a verified receipt). The receipt matters more as foundation for non-focused sends (queue, cross-session, side-chat or diff comments) than for a focused overlay where the user sees the TUI react. If v2 becomes chat-centred, the composer is rebuilt as the main input, so the reusable asset is the send primitive plus receipt, not the overlay. Not on the user's stated wish list; the research's "wish list" claim in warp.md is the researcher's inference.
- **Depends on:** I-01: the shared send primitive (bracketed paste, separate Enter, readiness gate); this idea should not carry its own copy; UserPromptSubmit digest receipt (small hook and hub change owned by this idea or I-01); optional: the compose-bridge helper subcommand if spike 1 passes

### I-04

**Input fidelity audit (image paste, drag-drop paths, dictation)** · verdict **adopt-light** · cost S · value 3/5 · proposed by 2 reports · [full card](ideas/I-04.md)

> Most of this is already built (Ctrl+V on an image-only clipboard, quoted-path drops via bracketed paste, a text-input client for dictation), so adopt only a one-time hands-on checklist plus the small fixes it finds, and treat /voice microphone attribution as the one real unknown.

- **What the user gets:** Invisible correctness work: screenshots and files dropped or pasted into a Loom terminal reach Claude correctly; macOS system dictation works in the terminal and composer; no voice stack needed.
- **Why this value:** Screenshots into Claude are a daily habit for a heavy agentic developer (UI bugs, error dialogs, ticket screenshots), so a silent text-instead-of-image failure would be costly, but the common case (image-only screenshot clipboard, Finder drag) is already handled and tested; the remaining payoff is edge cases plus a possible /voice unlock, and the user's notes mention neither voice nor image paste as a wish. Value is correctness insurance, not a new capability.

## Conversation and chat

### I-05

**Read-only conversation view of the SAME session (chat-looking transcript, no new engine)** · verdict **adopt-light** · cost L · value 4/5 · proposed by 11 reports · [full card](ideas/I-05.md)

> Build it as a read-only transcript view that reuses the subagent panel's tail/feed/model machinery, shipped first for sessions with no terminal (stopped, stale, after relaunch) and then live, with no composer, no cross-session search and no hook-text dependency. The plumbing is mostly there; the real cost is a faithful main-session decoder, markdown/diff rendering and backward paging, so L stays honest.

- **What the user gets:** A 'Conversation' tab or panel that renders Claude's own transcript as readable turns (markdown, tool calls folded per turn with expandable rows, diffs, questions), next to the terminal. Ended, stopped and idle records become readable and searchable without a live terminal or process, replacing the static ended-screen snapshot; it is the first safe step toward a chat-centred UI and the base for side chat, right panel and search.
- **Why this value:** The user runs several sessions and many subagents, and the real gaps are catching up on what a long run did ("Finished while away"), reading long markdown answers, and reading any stopped session. Today, after a relaunch, a stopped session shows only a facts grid. The ended screen is a memory-only screenshot of at most 16 sessions and 4 MiB, and the terminal scrollback is 2,000 lines. A transcript view fixes that at zero idle cost, fits the stated openness to a chat-centred UI without breaking the contract (it is a view), and is the shared base for side chat (render a forked session's file), the right panel and a later FTS search. It is not a 5 because input, approvals and slash commands stay in the terminal, so the user still lives in the terminal while working, and the biggest chat-UI payoff (composer plus approvals) is explicitly out of the light version.
- **Depends on:** Soft: spike results on CLI 2.1.300 main-session JSONL (record types, line sizes, branches, resume semantics); Soft: user decision to relax the wording 'No chat UI' in design/UI-MAP.md and DESIGN.md section 2.6 to 'the live session is always the real terminal'; Enables, does not require: side chat (fork file rendered by the same view), right panel, FTS5 cross-session search, ended-record composer; No hard dependency on other v2 ideas

### I-06

**Chat lens with composer over the live PTY (terminal and chat as two views of one process)** · verdict **spike-first** · cost XL · value 4/5 · proposed by 8 reports · [full card](ideas/I-06.md)

> The read-only half (a Chat lens over the main session's transcript) fits Loom and is adopt-light via I-05, but the composer-over-PTY and hook-approval half rests on unverified TUI behaviour (a stray Enter can approve a dialog; Loom's "Waiting for you" cannot tell a prompt from a question dialog), so prove the write path in three isolated spikes before committing to the XL whole.

- **What the user gets:** Toggle Terminal <-> Chat on the same live session: rendered markdown, collapsed tool calls, approvals as cards, a real multi-line composer, history, Esc to interrupt; the real CLI (slash commands, skills, MCP, hooks, subagents, resume) stays authoritative and one click away. Gives the chat-centred feel the user is now open to without an SDK.
- **Why this value:** High for the reading half: a heavy multi-session, multi-subagent user gets rendered markdown, folded tool noise, catch-up on finished sessions and, for idle/ended records, real history that costs no process and survives relaunch (the static ended screen does not). It is also the foundation the user's side chat and right panel need, with no SDK or billing exposure. The composer adds less (multi-line editing, native IME/Turkish-layout input that the terminal handled badly in D-36) while carrying the only real hazards, so the value drops to about 3 if the user is happy typing in the terminal; the approval cards overlap what I-15/I-16 notifications already give.
- **Depends on:** I-05 (read-only structured transcript of the main session; this idea is I-05 plus a write path); I-01 (verified send primitive: bracketed paste, gated on state, confirmed by UserPromptSubmit); I-15 / I-16 (documented-hook approvals and questions; Stage 3 only); Tracker change: keep Notification type and the UserPromptSubmit prompt digest; User decision recorded in DECISIONS.md amending DESIGN section 2.6 and UI-MAP 'No chat UI'; Optional synergy: side chat (SC2 fork in a right panel) reuses the lens and composer

### I-07

**Optional 'Chat mode': Loom-owned stream-json child per session (no Node, SDK or ACP)** · verdict **spike-first** · cost XL · value 3/5 · proposed by 1 reports · [full card](ideas/I-07.md)

> Technically the right engine for a chat-centred Loom and it fits the run-scope and ownership model better than the research assumes, but it is an unbounded XL build with a headless-billing exposure and an unanswered replace-vs-convenience question, so run a recorded capture spike and gate the build on I-05 proving use.

- **What the user gets:** A true structured chat session with typed events, authoritative state, tool/permission cards and side questions, chosen per session as an explicit mode, with the PTY as default and fallback. Mode switch = stop plus --resume; exactly one process owns a session id.
- **Why this value:** It is the only path to the chat-centred, typed, tool-card and side-question UI the user asked about, and Loom's ownership layer makes it safer here than in Conductor/T3/Zed. But the user's real workflow (many sessions, subagents and multi-agent workflows, skills, MCP, TUI dialogs) is best served today by the PTY, most of the near-term wins (readable ended sessions, side chat, approvals in the panel) can come from lighter ideas, and the value jumps to 4-5 only if the user decides Chat mode replaces the terminal, which also makes the unbounded parity work and the billing exposure the price.
- **Depends on:** I-05 (read-only structured transcript from JSONL, per the idea text: build it first and see whether the user actually reads Loom's chat view instead of the terminal); I-09 (per the idea text, the lighter alternative: if a one-shot/ephemeral side-chat child covers the side-chat wish, Chat mode loses its strongest justification); User decision on replace vs convenience view; Contract amendment to allow a non-terminal per-session mode

## Side chat and panels

### I-08

**/btw side-question shortcut (lightest side chat)** · verdict **adopt-light** · cost S · value 3/5 · proposed by 6 reports · [full card](ideas/I-08.md)

> Adopt a menu item plus one key that types '/btw ' into the live terminal (real CLI, nothing new owned), guarded by a short isolated hook/registry observation; it is cheap and fits every principle, but it only saves about five keystrokes and does not deliver the persistent side chat the user wants.

- **What the user gets:** One key (e.g. Cmd+;) that focuses the composer and inserts the CLI's own /btw flow: a one-shot question with the full conversation as context, no tools, nothing written to the main thread, works while the main turn is running, cache-cheap.
- **Why this value:** Real for this user: long multi-agent turns are exactly where a no-tools, cache-cheap question while the main turn runs helps, it needs no new process, and it ships the first slice of a long-standing wish for almost nothing. But the keystroke saving is tiny (typing '/btw ' is five keys), the answer is single-response, in-memory, tool-less and unreachable by Loom, so the wished-for persistent ChatGPT-style side thread in a right panel is not served. The real value is discoverability and a consistent menu entry; it should not be mistaken for, or delay, a Loom-owned side thread decision.
- **Depends on:** Independent of every other idea; the optional fork-to-subagent step ('f') relies on the existing subagent tree and transcript panel (SubagentLedger, SubagentTranscript*) and needs nothing new; Feeds the later decision on a Loom-owned side thread (chat-ui-paths candidates, a --fork-session PTY or stream-json child): a month of using /btw shows whether single-answer is enough

### I-09

**Side chat as a forked real CLI session (the user's ChatGPT-style side thread)** · verdict **spike-first** · cost L · value 5/5 · proposed by 14 reports · [full card](ideas/I-09.md)

> Build it as a hidden child card whose run is `claude --resume <parent> --fork-session` in a plan-mode PTY (the only mechanism that keeps the real CLI, has no billing exposure and reuses Loom's start, stop and verified-delete machinery), but run a one-day isolated-profile spike first, because the card-identity, cache and mid-turn-fork behaviour of the flag are unverified and decide the design.

- **What the user gets:** Ask about the current work without polluting or blocking the main thread: a child of the parent card (nested like subagents, hidden from the normal list), seeded with the parent's context, multi-turn, with 'promote to normal session', 'bring the answer back' (a user click pastes a summary into the main prompt) and 'discard' (verified deletion). Closed = nothing running.
- **Why this value:** It is the user's longest-standing wish and the top-converging idea (14 sources); a heavy agentic user running multi-hour agents on EDDP-style tickets repeatedly needs 'why did you do that?' / 'what does this file do?' without derailing or blocking the main run, and today's alternatives (type /btw, which is single-answer, tool-less and ephemeral, or open a new session and re-explain) are worse. A PTY fork is not the ChatGPT-style chat look, which costs it a little, but it is multi-turn, can read files, persists, and arrives with no renderer work.
- **Depends on:** None hard for the PTY child (mechanism 1). Reuses: D-40 trailing-prompt launch slot, D-39 subagent tree row, FB4-3 ended screens, CP4-C verified deletion.; I-05/I-07 (structured renderer) only for the later headless variant (mechanism 2) or a chat-style view of the side transcript.; Mechanism 3 (undocumented side_question) needs a Chat-mode process, not this design; skip until then.

### I-10

**Right-hand context panel (subagents, side chat, changes, notes)** · verdict **spike-first** · cost L · value 4/5 · proposed by 6 reports · [full card](ideas/I-10.md)

> Build only a one-tenant right pane for a real forked side session (not a generic tabbed panel), but first run a CLI fork/hook/cache/resize spike, because the pane is the cheap part and the child-session plumbing is the risk.

- **What the user gets:** A collapsible right panel (the user's long-standing wish) that hosts the secondary threads of the selected session: subagents/subtasks, the side chat, later Changes and an agent note. Nothing is drawn or watched when it is collapsed; closing a tab stops what it owns.
- **Why this value:** The side chat is the user's oldest wish and fits a heavy multi-agent workflow (ask "why did you do that" without derailing a long turn, with tools and a persistent thread, which native /btw lacks), but the generic panel with subagents, changes and notes tabs adds little: subagents are already served by the sidebar tree and transcript panel, and the others are separate ideas, so the whole of I-10 as written is about a 3 and the side-chat core is a 4.
- **Depends on:** D-34 must be lifted by the user (right pane allowed); contract section 13 moved into scope; Loom 0.4.4 existing parts: startConversation(opening:) start path, SessionEventHub hook state, ConversationDeletion, SubagentTranscriptView (only if a subagent-beside tenant is added); Optional later pairing: a usage-by-source line so side chats appear in the Usage page

## Attention and status

### I-11

**Subagent tree upgrades (who is asking, per-subagent cost, no stuck 'running')** · verdict **adopt-light** · cost M · value 3/5 · proposed by 4 reports · [full card](ideas/I-11.md)

> Adopt the verified half now (name the subagent that asked, using the agent_id Loom already receives, plus deterministic closure rules so no record stays 'running'); defer live per-subagent cost/context, which needs the subagentStatusLine bridge (I-24) and a tick-rate spike.

- **What the user gets:** Attribute a 'waiting for you' state and its approval box to the specific subagent that asked, show per-subagent tokens/tool counts/context, and guarantee finished subagents never stay 'running'.
- **Why this value:** The user runs many sessions and many background workflows, so knowing which subagent blocks on approval saves a hunt through the terminal, and a stuck 'Running 2h' row erodes trust in every other indicator. But session-level Needs approval plus Cmd+J already gets them to the right terminal, so the gain is triage speed, not a new capability. Per-subagent cost and context is a nice-to-have next to the usage chip and Settings Usage page they already have.
- **Depends on:** I-24 (statusline bridge) only for Tier 3 (live context %, status ground truth); Tier 1 and Tier 2 have no dependency; loom-fake-provider scripted subagent events (already exists) for fixtures

### I-12

**Status accuracy hardening and 'Why this status?'** · verdict **adopt-light** · cost S · value 3/5 · proposed by 9 reports · [full card](ideas/I-12.md)

> Most of the idea is already in Loom (background_tasks/session_crons, run+session binding, child-agent drop, interrupt via registry, no stale Working across launches); the real gaps are a sticky Failed, pinned regression sequences, unknown-value drift evidence and a pull-based 'why' readout, so build that small slice and drop the timer-based Interrupted state and the `loom status --explain` flag.

- **What the user gets:** Fewer wrong dots on the cards the user trusts all day: a session with background work or running subagents never shows Finished/Idle; Failed is not silently downgraded; resume, /clear and compaction never show Finished unviewed; an interrupt does not leave Working stuck; and a pill popover (and `loom status --explain`) says which signal produced the state, when, and what it replaced.
- **Why this value:** Status trust is the base of a many-session, subagent-heavy workflow, but the audit shows the headline cases are already handled and tested, so the visible gain is small: one Failed that no longer turns into 'Waiting for you', regression coverage, and a debugging readout that mostly helps the author when a CLI update shifts behaviour. D-54 already accepts that cron/background sessions stay Working in Active.
- **Depends on:** none for (1)-(3); UI choice for (4); cross-session channel (D-43/D-46) before any `loom status --explain`

### I-13

**Receive OSC 7501 (Program Status Protocol) as a second in-band state source** · verdict **spike-first** · cost M · value 2/5 · proposed by 1 reports · [full card](ideas/I-13.md)

> Receiving OSC 7501 fits Loom's principles as a passive, hooks-subordinate cross-check, but most of the promised user gain (reason and message text) is already available from hook fields Loom drops, so run a half-day wire-capture spike first and adopt only a light version if Claude emits 7501 in states hooks miss.

- **What the user gets:** Faster, more truthful 'which session needs me' with the reason (auth / question / permission) and message text on the card, plus coverage for cases hooks miss (auth expiry, hooks disabled or silent), with no scraping.
- **Why this value:** Hooks plus the registry already give this user Working, Needs approval, Waiting for you, Failed and Finished unviewed, and a hook fires at the same moment as the 7501 report (the spawn latency of loom-hook is tens of milliseconds, not perceptible). The reason text can come from hook fields at near-zero cost. What 7501 adds uniquely is coverage of states with no hook (startup folder-trust or login dialogs, hooks disabled or lost), drift evidence, and a documented replacement path for the private registry file. For a user with 5 to 10 parallel sessions in two projects these are rare edge cases, though they get more valuable if v2 moves toward a chat-centred UI that wants a precise 'needs you because' line, because 7501 is UI-agnostic. Honest re-estimate: cost S holds for the passive receiver (patch, parser, surface hook, journal), but the proposed card reason and disagreement logic make it M.
- **Depends on:** Prerequisite: hooks and the registry stay authoritative (D-45 hook-silence and drift work, already shipped in 0.4.x); Independent, cheaper sibling worth doing first: show Notification.message and PermissionRequest tool_name from the existing hooks as the reason; Soft link to any v2 'needs you' surface (menu bar rows, header pill, a future chat-centred view) that would display the reason

### I-14

**Richer card content: what it is asking / last said, peek, agent note, title precedence, notification text** · verdict **adopt-light** · cost M · value 4/5 · proposed by 6 reports · [full card](ideas/I-14.md)

> Adopt a small version: show Stop's last_assistant_message and PermissionRequest's tool_name/tool_input (already in the hook payloads Loom receives) as a bounded, memory-only line that is shown only while the matching state holds, on attention cards (or as a tooltip first), plus a richer approval banner; defer the agent-set note, and treat title precedence as already satisfied.

- **What the user gets:** The sidebar and notifications answer 'does this need me, and for what' without opening the session: a one-line 'asking / last said' under the title, a peek popover (last message, question or final summary), an optional agent-reported note ('reproduced bug; testing fix'), a stable human title, and notifications whose body is the outcome or approval summary plus branch.
- **Why this value:** With 3 or more sessions across two EDDP projects, the real cost is deciding which session to open and why. Today the card says only "Waiting for you" or "Needs approval", and the banner is the fixed text "Claude is waiting for your approval". The data is already in the hooks Loom receives and part of it is already parsed, so most of the benefit costs only plumbing. It scores 4 rather than 5 for two reasons. The fact-check says auto mode is now the default starting mode, so approvals are rarer (the banner part matters less than the last-message part). Selecting a live session in Loom is also cheap, since its terminal is already running. The agent note (c) alone would be about 2, so it is not worth its protocol and token cost.

### I-15

**Answer approvals from Loom's own surfaces via the documented hook decision** · verdict **spike-first** · cost M · value 3/5 · proposed by 6 reports · [full card](ideas/I-15.md)

> Loom is already 80% wired for it (per-session `--settings` PermissionRequest hook, authenticated sockets, a Codex-era approval box), but the one fact that decides safety (does the CLI dialog wait for or race the hook, and does a terminal answer cancel it) is unmeasured, so run a half-day hook-race spike, then build a small first slice (box + banner buttons + menu rows, no hotkey, no Always/Bypass).

- **What the user gets:** Allow / Deny (and later pick-an-option) directly from the approval box, the menu-bar popover, the notification buttons or a hotkey, without switching to the session: one fewer context switch per approval with 3-6 parallel sessions. Verified outcome = the CLI continues.
- **Why this value:** Real but frequency-bound: auto mode is the starting mode from 2.1.283 (installed CLI is 2.1.300), so the prompts that remain are the risky or unusual ones, where blind one-click approval is least wise, and the 93% rubber-stamp figure describes the older default. It pays most for this user because of parallel sessions and many subagents (a subagent prompt today forces leaving the transcript panel to answer in the terminal), and approvals while Loom is in the background. The cheaper stage 0, putting the tool and command from the payload Loom already receives into the banner body and card line (no hook blocking, no race risk), captures much of the benefit and should ship regardless.
- **Depends on:** Spike E1 (hook/dialog race) must pass first; Shares work with: card line 'what it is asking' (stage 0, S), AskUserQuestion/ExitPlanMode card ideas, presence-aware notification policy; Needs a DECISIONS.md entry before building: the PermissionRequest hook stops being decision-free (amends the comment in ProviderLaunchProfile.claudeSettings and the CP2 integration text in the product contract); Watch Channels permission relay as the long-term replacement for the hook path

### I-16

**Rich approval content: real preview, question card, plan review panel** · verdict **spike-first** · cost L · value 4/5 · proposed by 5 reports · [full card](ideas/I-16.md)

> Worth building for the AskUserQuestion card and the plan panel (the structured interactions that stall unattended sessions, and the first honest step toward a chat-centred UI), but only after a live spike pins the hook form and the plan-approval semantics; the Bash/Edit/Write diff preview alone is a cheap, separable add-on whose value is mostly triage in notifications and the menu bar.

- **What the user gets:** Approve confidently without opening files or scrolling: the full Bash command, Edit/MultiEdit as a unified diff from old/new strings, Write as head + size, MCP as server + args; a card for AskUserQuestion (1-4 questions, single/multi-select, free text); and a rendered plan with Approve / Revise-with-feedback for ExitPlanMode. Always with 'answer in the terminal' as fallback.
- **Why this value:** For this user (several sessions, spec/interview loops with ticket keys, plan-first habits) AskUserQuestion and ExitPlanMode are where unattended sessions stall and where a human decision matters most, and answering from a rendered card is a real fluency win plus the first reusable piece of a chat-centred UI. Discounts: auto mode is now the default starting mode (v2.1.283+, per the power-user fact-check), so ordinary Bash/Edit approvals are rarer and the plain diff preview is the weakest part (the CLI dialog already shows a better diff for the selected session); only one closed product ships plan review, so reception is unproven; and the hook-held dialog trade-off needs the user's buy-in.
- **Depends on:** I-15 (request/response decision channel): not a hard prerequisite, because the existing control socket and a coordinator pattern already hold requests, but Stage 1 should be built as the first user of whatever generalised channel I-15 defines, not as a parallel one; Stage 0 (content line) is independent of I-15 and of any blocking hook; A Markdown renderer for the plan panel (new; shared with any later chat-centred/transcript view)

## Navigation and launch

### I-17

**Attention-routing polish (ordering, roll-up, read/unread, Dock/menu bar, quit dialog, presence policy)** · verdict **adopt-light** · cost M · value 3/5 · proposed by 7 reports · [full card](ideas/I-17.md)

> Most of I-17 already ships (severity Cmd+J, Dock badge, menu-bar Needs-you list, quit question, project roll-up dot, viewed-only-when-key); adopt only the real gaps (away-aware viewed and banners, opt-in finish/failure banner, quit sheet naming sessions, Dock menu, Mark Unread), and skip severity re-sorting of Active, quiet hours, per-turn lists and a mailbox.

- **What the user gets:** Triage rather than hunting: a severity-ordered Active section, a roll-up on collapsed projects, a trustworthy unread model, a Dock menu and menu-bar list of what needs you, a Quit dialog that lists Working sessions (Quit stops all of them), and notifications that stay quiet when you are already looking.
- **Why this value:** The original S/high-value framing overstates it for Loom because the Dock badge, menu-bar Needs-you list, severity Cmd+J, quit question, project roll-up dot and strict viewed rule already exist; the remaining pieces are polish. For a multi-session, long-run user the genuinely useful parts are away-aware viewed/banners and an opt-in finish/failure banner (the 'slow part was me noticing which one stopped' problem); the Dock menu, quit list and Mark Unread are small conveniences. Cost: each piece is S, but with pure-type tests, evidence and UI-MAP/DECISIONS updates the useful set is about M.
- **Depends on:** Spike S-1 (lock/screensaver occlusion) before A; Optionally shares the 'right sidebar / notification' decisions of D-52 (banners were scoped to approvals only); No dependency on other v2 ideas

### I-33

**Fast launch surface: new-session sheet, presets, loom:// URLs, recipes, skills launcher** · verdict **adopt-light** · cost M · value 4/5 · proposed by 5 reports · [full card](ideas/I-33.md)

> Build the new-session sheet, JSON presets/recipes and a prefill-only URL on Loom's existing launch path, show the permission mode from the documented hook field, and drop the skills browser, hotkey and Loom-side worktree creation (worktrees wait for I-32).

- **What the user gets:** Starting the third parallel task takes seconds: a palette-style sheet (project, branch or worktree, plan/permission mode, effort, first message) with an empty state listing the two work projects and recent ticket keys; saved presets (and 'Save this session as preset') reachable from a '+' menu, from Raycast or scripts via loom://preset/<name>; reusable prompt recipes; a launcher for the user's skills and commands.
- **Why this value:** The user already runs about three parallel sessions across two ticket-keyed work projects, and today each start is a bare click followed by retyping the same plan-mode preamble or ticket prompt. The sheet's ticket de-dup, plan mode, effort and first message remove that, and Raycast/URL starts help a backend dev who works across apps. The gain is real but bounded: the instant Cmd+N already exists, plan mode can be reached with Shift+Tab, and the heaviest pieces of the original idea (worktrees, skills browser) are deferred or dropped.
- **Depends on:** I-32 (worktree lifecycle) for any worktree field; until then only an optional absolute directory in a preset; Reuses D-40/D-42 start path and the ticket de-dup in SessionCatalog.session(projectID:ticket:); Optional: the permission_mode hook-field chip is an independent slice that other ideas (plan-mode awareness) can share

## Persistence and lifecycle

### I-18

**Park / snooze / In-work: user-owned lifecycle flags for sessions** · verdict **adopt-light** · cost M · value 4/5 · proposed by 2 reports · [full card](ideas/I-18.md)

> Adopt only the "In work" half (one persisted per-session flag, opened by the user's own prompt, closed only by one-key Done, 15-day stale falloff, no model call), and drop the Park shelf, timed snooze and auto-settle timers, because Loom's Active section is live-only and forgets everything at Quit, while Mark as Read and the stale lifecycle already cover most of what Park would do.

- **What the user gets:** A cheap, reversible 'I am done with this for now' (Park, optionally snooze until a time or until the plan limit resets) and an explicit 'In work' list of sessions you are still responsible for, so the Active list equals 'things that need or may need me'. 5-second Undo toast; 'park and go to the next session needing me'.
- **Why this value:** For someone running several sessions over two work projects with ticket keys, a persisted "what am I in the middle of" list directly fixes the empty-Active-after-restart gap, and it costs no resources. The full Park/snooze half scores about 2: Mark as Read and viewing already clear the noisy states, and hiding approval or working sessions conflicts with accurate attention counts.
- **Depends on:** I-31 (PR state) only for a later PR-merge auto-close; not needed for the light version; usage-limit actions idea (Continue/Snooze at reset) for snooze-until-limit, kept separate

### I-19

**Idle auto-park (hibernate): stop the process, keep the card, resume on open** · verdict **spike-first** · cost M · value 3/5 · proposed by 5 reports · [full card](ideas/I-19.md)

> Most of the machinery already exists in Loom (SessionLifecycleController idle path, verified stopForIdle, ended screen, --resume), but the user switched exactly this off in D-38, so a half-day spike on resume fidelity and on whether the hook signals are trustworthy must precede a strictly opt-in, visible re-enable.

- **What the user gets:** Directly serves the wish 'sessions that cost nothing when idle': after N minutes of true idleness a session's process is verifiably stopped while the card, ended-screen snapshot and resume handle stay; opening it resumes the same conversation. Ten open sessions stop being ten live Claude processes.
- **Why this value:** It serves a stated wish ("idle sessions cost nothing") and the memory is real (200-330 MB per live Claude on a 16 GB machine that also runs Claude Desktop, Xcode and builds), but today the user keeps about three sessions live, so the gain is moderate, Stop plus Resume already gives a manual version, and the user turned the automatic version off once after being surprised. Value rises if the user routinely keeps 8-15 sessions open or the Mac is under memory pressure.
- **Depends on:** D-38 amendment (user decision; contract 4.3 says the idle transition is not automatic); Hook signal fixes inside this idea: idle_prompt versus real question in the waitingForInput blocker; required presence of Stop.background_tasks and session_crons; Optional later: the cache-cold hint idea (usage-tools, cost S) can share the static 'probably cold' text; Optional later: statusLine bridge idea if the exact cache tier or session-local settings (model, permission mode) are wanted

### I-20

**Keep the Mac awake while a session is Working** · verdict **adopt-light** · cost S · value 4/5 · proposed by 5 reports · [full card](ideas/I-20.md)

> Adopt a trimmed version: one on/off setting "Keep the Mac awake while sessions work", one idle-system-sleep assertion driven by the existing live-state fan-out (the same path as the menu bar item), with background tasks counted, scheduled crons excluded, a one-shot cap and a visible indicator. Drop "Always" and the "tied to the watchdog" claim, because Loom's Working is already registry-corrected and the watchdog only covers a run with zero hooks.

- **What the user gets:** Long runs (tests, multi-agent workflows) survive idle sleep and screen lock without a side-terminal `caffeinate`; Off / While working / Always, with a small indicator and release on the last Finished.
- **Why this value:** This user runs several long agentic sessions and multi-agent workflows and often walks away. A run that sleeps silently mid-turn, or a background test that freezes after Claude ends its turn, costs real time and tokens. The feature is small, invisible when working and removes a manual caffeinate habit. The ceiling is limited: lid-close still sleeps, and it does not give 'sessions run while the Mac is closed', which is the cloud or Remote Control domain. A student laptop on battery makes the default and Low Power Mode behaviour matter. Docs note Desktop sessions survive sleep only while the process survives, and it helps quota auto-resume, which waits for Enter if the Mac slept more than about 30 minutes across the reset.
- **Depends on:** none (standalone); Optional pairing: the 'interrupted sessions / Resume interrupted' idea in persistence-remote-orchestration option A, which covers Quit or crash rather than sleep; Optional pairing: a quota or usage surface, since a quota wait may show as Working

### I-21

**Crash-safe state and 'Resume interrupted' after Quit or crash** · verdict **adopt-light** · cost M · value 3/5 · proposed by 2 reports · [full card](ideas/I-21.md)

> Most of the 'crash-safe state' half already exists in Loom (SQLite catalog with WAL, daily backups, damaged-catalog prompt, atomic prefs, system-quit handling, abandoned-run closing), so adopt only the missing half: a launch-time, derived 'Reopen what was running' offer (with an optional 'was mid-turn' tag), no snapshots and no new write path.

- **What the user gets:** A reboot, crash or update never loses the layout or the resume handles; after a Quit or crash a one-click 'Resume interrupted' (or resume-all) reopens the sessions that were mid-work.
- **Why this value:** The user installs and restarts Loom often (0.4.x cadence, plus macOS restarts) and runs several live sessions across projects; after any Quit the sidebar cannot tell which cards were running, so restoring that set in one click is real but occasional value. The headline 'never lose layout or resume handles' is already true (transactional catalog, atomic prefs, backups, system-quit path), so the rest of I-21 adds nothing. Value rises to 4 only if the spike shows the CLI continues an interrupted turn on resume.
- **Depends on:** Existing resume path (SessionRuntime.resumeConversation / CatalogModel.resumeConversation); no dependency on other v2 ideas; Optional pairing with any stay-awake/power-assertion idea from the same theme (separate, not required)

### I-22

**Claude supervisor integration: 'Background' visibility lane, then optional 'Run detached'** · verdict **later** · cost XL · value 2/5 · proposed by 3 reports · [full card](ideas/I-22.md)

> Do not build now: the read-only lane is low-value for someone whose sessions live in Loom and carries an unmeasured side effect (`claude agents --json` may start Anthropic's supervisor outside Loom's scope), and 'Run detached' breaks Loom's hook-status channel across a Quit and contradicts D-40, while a small resume-interrupted feature gives most of the benefit.

- **What the user gets:** Sessions started elsewhere (terminal, Desktop, agent view) become visible in Loom's list and openable; later, an explicit per-session 'Run detached' so a long turn survives a Loom Quit and costs nothing when idle, using Anthropic's supervisor instead of a Loom daemon.
- **Why this value:** Lane: the user wants Loom to be the main development app, so sessions started elsewhere shrink over time, interactive external sessions are not openable, and Loom already surfaces what matters for its own sessions. Detached: the only unique gain is a turn surviving a Loom Quit (the idle-costs-nothing goal is already met by the ended screen plus resume; sleep does not stop Loom sessions either), and a machine restart still ends the supervisor sessions. A Quit confirmation already exists for working sessions (D-45). Value becomes 4 only if the user routinely runs `claude --bg`/agent view or wants overnight unattended runs, which this brief does not show. Cost-benefit is poor: roughly XL plus a contract change for a narrow gain.
- **Depends on:** Persistence note option A (power assertion plus 'interrupted' marker plus one-click Resume interrupted) as the cheap first answer to 'survive Quit'; Agent view leaving research preview and #87891/#65051/#87984/#98872/#102949 closing, before any detached class; User decision on contract §6 and D-40 amendments (detached class, Quit semantics); D-43/D-46 cross-session channel (a detached session would also need to appear there)

## Context and usage

### I-23

**Per-session context meter on cards and header** · verdict **adopt-light** · cost M · value 3/5 · proposed by 5 reports · [full card](ideas/I-23.md)

> Build a tokens-first, live-sessions-only context figure that rides the existing transcript watcher and usage index and resets on a documented compaction hook; add percent and amber/red only where the window is known, because current models run 1M by default, so the transcript route cannot give a trustworthy percent for the common case.

- **What the user gets:** See which of five sessions is near its context limit (and about to compact) without switching to it and typing /context; a thin bar or number that only appears from about 50% and turns amber at 70, red at 85; optional 'compact' or 'new session from summary' hint (user-triggered, never automatic).
- **Why this value:** The user runs several sessions with subagents and hands off by hygiene, and the token figure also feeds the cache-cold and resume-cost decision. So a glanceable per-session size is useful and there is demand evidence (the Oct 2026 Desktop context-ring outcry; Anthropic's mods docs use a context-fill chart as the example). But current models run 1M natively, so "about to compact" at 967K is rare. The real value is a size/cost awareness figure, not a compaction alarm. That is why it is 3 and not 4-5, and why a percent scale would oversell it. The value rises if the same figure also drives a "cache cold, resume re-reads about 400K" hint on return to an idle card.
- **Depends on:** Existing Loom pieces only for the light version: UsageTranscriptWatcher, ClaudeUsageIndex and UsageModel (D-32/H1-D1), the SessionStart hook path; I-24 (statusLine bridge) only for the exact variant: true window size and used_percentage. Optional and later; it conflicts with D-32/D-20 as scoped; A sibling idea on the cache-cold hint on return to a session can reuse ContextSample.timestamp and tokens

### I-24

**statusLine bridge for 'official numbers' (context %, cache, cost, effort, PR state)** · verdict **spike-first** · cost M · value 3/5 · proposed by 2 reports · [full card](ideas/I-24.md)

> The data is documented and event-driven and the spawn cost is small (about 4 ms CPU per loom-hook spawn, measured), so the real risk is the footer hints and the user's own status line; run a half-day spike on those before committing, and ship only an opt-in, no-chaining light version first.

- **What the user gets:** Exact per-session figures the CLI itself shows: context percentage, prompt-cache warm-until, per-session cost, effort/fast mode, worktree and branch, and pr.number / pr.review_state for a PR chip, plus rate_limits and per-subagent stats, without heuristics or extra git/gh calls.
- **Why this value:** Per-session context % across several live sessions is genuinely valuable for this heavy multi-session, multi-agent user. But Loom can already get an approximate figure from transcripts (the context-meter idea, zero CLI change). Branch is already read from git, effort is already read from the transcript, cost is the same list-price estimate Loom computes, and plan limits already come from get_usage. The unique gains are exact context and window size, cache TTL, and the PR chip. The PR chip only helps if the work repos are on GitHub or GitLab, which I could not confirm from the notes. Against that sit a visible CLI change (hints) and a possible conflict with the user's own status line.
- **Depends on:** I-23 (transcript-derived context meter, measure its error against /context first; this idea only calibrates or replaces it); A Settings toggle pattern in UIPreferences (exists); Decision note amending D-32 wording and the contract §258 line on --settings contents

### I-25

**Usage honesty: plan pace, provenance, cache-cold hint, limit-hit actions** · verdict **adopt-light** · cost M · value 4/5 · proposed by 5 reports · [full card](ideas/I-25.md)

> Adopt the pure-function core (plan pace on the existing chip, a stale/unknown marker, an honest "usage limit reached" state) as an S job; drop Loom's own "Continue at reset" because Claude Code 2.1.234+ already waits and continues by itself, and make the cache-cold hint a separate spike because the transcript can probably give the TTL tier but nobody has checked.

- **What the user gets:** Turn the raw plan-window percentage into a decision and make every number trustworthy: 'at this pace the 5-hour window runs out in 1h 40m, reset in 2h 10m' (only when it matters), a tag on each figure (official / estimate / stale), a 'cache likely cold, next message re-reads about 143k tokens' hint before you resume an idle session, and 'Continue at reset' for a session stopped on the limit. (Remaining usage for ChatGPT is a later wish; Codex is frozen.)
- **Why this value:** This user runs several sessions plus subagent workflows and reaches the 5-hour window sooner than a single-session user, so "do I slow down?" is a daily decision and the chip already carries the data. The honest limit state also removes a misleading red "Failed" on a session that is just waiting for a reset. The cache-cold hint is a nice-to-have decision aid for resuming large sessions, not essential. The original Continue-at-reset adds little, because Claude Code does it by itself.
- **Depends on:** I-24 (statusline bridge) is optional, only if exact TTL, context size or live rate_limits are wanted later; not needed for the light version; I-18 (Park / Snooze) for 'Snooze until reset'; A Settings switch if the pace notification is ever added (existing Notify switch pattern from D-52)

### I-26

**Usage rollups per project, per ticket and by source** · verdict **adopt-light** · cost M · value 3/5 · proposed by 3 reports · [full card](ideas/I-26.md)

> Adopt a smaller version: the existing usage index already has the dedupe, the sidechain flag and a delete rule, so build only a by-session query, "By project / By source / By ticket" cards in the Usage page, and a Usage fact in the idle session's record view; drop the separate rollup file and the "unusually large" alert.

- **What the user gets:** Answers 'what did EDDP-1234 cost across five sessions and two subagent workflows' and 'which project eats my quota', plus attribution of tokens to main thread vs subagents vs side chats (and later scheduled runs), per session and per day, with an 'unusually large share' hint.
- **Why this value:** Real but periodic value: the user has two ticket-based work projects, a quota ceiling and heavy subagent/workflow use, so "which project and which source eats my quota" and "what did this ticket cost" are useful decisions about workflow style and effort reporting. But the daily flow is not changed, the totals/model/plan-limit views already exist, ticket attribution is only as good as the titles, and the figure is an API-equivalent estimate, not quota. Low risk and cheap because the ledger, dedupe and delete rule are already built, which is why it is worth doing small rather than skipping.
- **Depends on:** Existing ClaudeUsageIndex, UsageModel and Usage page (shipped in 0.4.x); Side-chat idea (for the third source; not required for v1); Scheduled-runs idea (later source; not required); Ticket-centred sessions idea (would make ticket keys reliable instead of title-derived)

### I-27

**Multiple Claude accounts via user-managed config dirs** · verdict **later** · cost M · value 2/5 · proposed by 2 reports · [full card](ideas/I-27.md)

> Technically feasible and safe if kept to "per-project account, new launches only, per-profile plan meters", but nothing in the user's notes says they have two Claude accounts, and the real cost is the per-session profile plumbing (resume, delete, usage, subagent reads), not the env var, so build it only once the user confirms two plans.

- **What the user gets:** A label and a CLAUDE_CONFIG_DIR per account: new sessions (and 'restart on account B when idle') launch with that env, and the new-session picker/footer shows each account's limit headroom, so two-plan users stop logging out and in and can start the long run on the account with room.
- **Why this value:** The user's notes ask for remaining usage on (singular) Claude, which Loom already ships (footer chip, Plan limits card). The demand evidence is a Reddit user with two Max 20 plans; there is no sign this user has two accounts. If they do (work vs personal, or two plans), value jumps to 4: the work projects bind to a work account once and logout/login disappears. A second dir also starts without their agents, CLAUDE.md, skills and MCP, which is a recurring setup cost for a heavy-config user.
- **Depends on:** User confirms they have, or will soon have, two Claude accounts; Per-session profile persistence (catalog schema 4) is a prerequisite for any account feature and also fixes the long-standing 'config dir not stored per conversation' gap noted in plans/experiments/run1-planning-scans/CP4-deletion.md; Footer/Usage plan-limits surface (exists) for the per-account meter rows

## Review and git

### I-28

**Read-only diff / Changes pane per session** · verdict **adopt-light** · cost M · value 3/5 · proposed by 14 reports · [full card](ideas/I-28.md)

> Build the cheap half now (an owned, bounded `git` read that gives a '+N -M, K files' chip on the card and header plus Copy patch / Open in editor), and keep the full in-app Changes pane behind an experiment, because Claude's own /diff already overlaps it and the chip is where Loom's unique triage value is.

- **What the user gets:** See what the agent changed without leaving Loom: a Changes pane for the session's cwd/branch (Unstaged, Staged, Branch vs base, Last turn), '+N -M in K files' on the card so you triage which finished session to open first, and 'Open in editor' / 'Copy patch'. No accept/reject, no editing.
- **Why this value:** The research calls it the field's most-proposed capability, but this user's own long-standing wishes (side chat, right panel, usage, deletion, idle cost) do not include a diff viewer, they review in an IDE and GitLab MRs, and Anthropic ships a /diff pane plus a Desktop diff view; the power-user note argues review capacity, not tooling, is the bottleneck. The part with real, unique value for several concurrent sessions is the cross-session triage cue ('+N -M in K files' on the card of a finished session) and one-click Copy patch / open in editor, both cheap. The full pane is worth about 2, so the blend is 3. Honest cost: chip + exports M (runner, parsers with temp-repo tests for rename, quoting, binary, unborn HEAD, worktree, submodule; cache and triggers; card/header wiring with render-probe tests; DESIGN and UI-MAP updates); read-only pane L; adding a live watcher or per-turn snapshots makes it XL.
- **Depends on:** No hard dependency. Soft: the user's answer on worktrees vs shared folders (decides whether a folder-level chip is misleading).; An owned plain-Process git runner is new shared plumbing; it could also replace the per-call run scope that the cleanup worktree check pays today.; If the user later wants line comments sent back to the agent: the 'send primitive' / verified prompt delivery ideas (a separate idea with its own authority questions).; If a right panel is built (D-34 later), Changes should become a tab of it; the view model is written placement-agnostic for that.

### I-29

**Review comments batched back into the session** · verdict **adopt-light** · cost L · value 4/5 · proposed by 10 reports · [full card](ideas/I-29.md)

> Adopt a light version: comments stored in Loom's catalog and staged as a draft (bracketed paste, no Enter) in the pane's own session, with delivery confirmed by a marker in the UserPromptSubmit hook. Auto-send, the skill pull and the mod path are left out. It only exists on top of a Changes pane that Loom does not have today.

- **What the user gets:** Select lines in the Changes pane, write comments, and send them as ONE structured prompt to the right session (or keep them pending until the turn ends). Review feedback is the step done most after an agent finishes; one batched message with file, line and quoted code cuts round trips.
- **Why this value:** 
The user runs several sessions and many subagents and reviews agent output constantly. Review is the step done most after a turn ends, and it is Loom's biggest gap relative to Claude Desktop, Conductor, Codex, Warp and Orca, all of which ship this loop.
 - Loom's catalog and hook knowledge give it a verified delivery state that none of the PTY-based competitors have.
 - The value is conditional. It only exists if the Changes pane is good enough that the user actually reviews in Loom instead of their IDE.
 - The pane has no syntax highlighting in v1 and is a bigger build than the comment layer.
 - Claude Code's own /diff panel (2.1.287+, with `ask`) already covers viewing diffs, so Loom's differentiator is the comment loop plus the cross-session overview.
 - The draft-only default costs one Return key, so it is slightly less automatic than Desktop's Cmd+Enter.
 - Score 4 only if the Changes pane is built; as a standalone idea it is worth 0.

- **Depends on:** The Changes/diff pane idea in the review-git area (git runner, file list, diff text, caps). I-29 cannot ship without it, so the two should be decided together.; I-01 (verified 'send to session' primitive) is optional and later. It would add an explicit 'Send now' (gated Enter) on top of the same store and format; v1 does not need it.; SessionCatalog schema addition and deletion coverage (contract section 8, ConversationDeletion).

### I-30

**Per-turn checkpoints and last-turn change chip** · verdict **spike-first** · cost L · value 3/5 · proposed by 8 reports · [full card](ideas/I-30.md)

> Worth building as a thin, view-only, event-driven layer (a chip plus a per-turn changed-file list, no restore, no diff renderer), but only after a spike settles four unknowns: where the snapshots live, git cost per hook on the user's real repos, the hook race at prompt time, and the cost of a run scope per git call.

- **What the user gets:** 'What did this turn change' per prompt, correct regardless of which tool the agent used: a chip on the card, a per-turn file list/diff in the detail pane, and a trustworthy 'since I last looked' marker. Restore is deferred.
- **Why this value:** The unique value is cross-session triage that Claude's own /diff (fullscreen TUI, per-turn T1/T2 from Claude's file-edit checkpoints, misses Bash) cannot give: with several sessions and subagent workflows, a card chip says which finished session actually changed code and how much, and 'since you last looked' makes the blue Finished dot more meaningful. The per-turn file list itself is a convenience, since the user can already press /diff or run git. Without a diff view (a separate idea) it is a data layer with a thin view, so the daily payoff is moderate; with that view it becomes the core of a review loop.
- **Depends on:** a review/diff pane idea (the chip is useful alone, but 'Copy patch' and 'Open in editor' are the only drill-down without it); Settings switch plumbing (UIPreferences) for 'Track changes per turn'; a shared-scope option in ProcessSupervisor+EnvironmentJobs if the per-call scope launch proves too slow

### I-31

**PR / CI chip and canned git actions** · verdict **adopt-light** · cost M · value 3/5 · proposed by 7 reports · [full card](ideas/I-31.md)

> Adopt a read-only, GitHub-only PR/checks chip fed by one bounded `gh pr list --json` call at the events Loom already has (turn end, window activation, manual refresh), and leave the canned Create PR / Fix CI / Resolve conflicts actions, ETag, merge-tree and "CI failure becomes needs-you" out, because the chip pays for itself only if the work repos are on GitHub and the actions only make sense once the I-01 send primitive exists.

- **What the user gets:** PR number, merge state and check state on the card ('CI failing' next to the branch, surfacing in the Active list), and one-keystroke Create PR / Fix CI / Resolve conflicts as short prompts to the session; fits the ticket-key workflow.
- **Why this value:** It removes a real context switch at the end of every agentic task (push, PR, wait for CI) for GitHub repos, and fits the ticket-key workflow because branch and PR title carry EDDP-*, but it is only informational: Claude Code already shows its own PR badge in the terminal footer, the user types prompts fluently so canned actions save little ('fix CI' is a few words and the agent runs `gh pr checks` itself), and the research notes say the user's backend work flows through GitLab/IntelliJ review, which a gh chip does not cover (glab is not even installed here). Value is 3 if the work repos are on GitHub, about 2 if they are GitLab.
- **Depends on:** I-01 (verified send-to-session primitive): required only for the canned Create PR / Fix CI / Resolve conflicts actions, not for the chip; I-24 (statusLine bridge): only for the no-gh alternative; not recommended as the source (weakest-fit idea in the usage digest, gives number and review_state only, no CI); Settings > General switch plumbing (UIPreferences) for the default-off opt-in; Existing BranchCache / refreshBranches triggers in CatalogModel (reuse, not a prerequisite to build)

## Worktrees and parallel work

### I-32

**Worktree-backed sessions (parallel agents on one repo)** · verdict **adopt-light** · cost M · value 3/5 · proposed by 10 reports · [full card](ideas/I-32.md)

> Build a thin Loom-owned "New session in worktree" (one plain `git worktree add -b <ticket key>`, session opens with cwd = worktree, glyph on the card) plus a dry-run-guarded "Remove worktree", reusing the catalog's per-session working_directory and the existing CP4-G worktree check; do not delegate to `claude -w`, and skip the pool, registry, storage list, setup scripts and port ranges for now.

- **What the user gets:** 'New session in worktree' for a project or ticket: branch named from the ticket key, the session opens there with worktree provenance on the card, environment files copied, and cleanup is a verified action, so two agents on the same repo stop colliding.
- **Why this value:** It removes a real ritual for the EDDP ticket-per-session flow (git worktree add, copy .env, Add Project, later clean up) and keeps the user inside Loom, which a "main app" needs, and Loom's existing per-session cwd, ticket de-dup and worktree check make it cheap. But it is not daily: the field data says realistic interactive parallelism is 2-3 sessions across projects, review is the bottleneck, worktrees do not isolate ports/DBs/.env state, Claude Desktop and `claude -w` already cover the basic case, and the same-repo collision frequency for this user is unknown, so 3 rather than 4.

## Tickets and tasks

### I-34

**Ticket-centred sessions (new session from ticket, ticket chip/grouping, derived work ledger)** · verdict **adopt-light** · cost M · value 3/5 · proposed by 3 reports · [full card](ideas/I-34.md)

> Adopt only the cheap half (ticket chip, search by key, a user-side 'New session from ticket' sheet using variant (b), reusing the shipped de-dup); defer the Work ledger and tracker write-back, because Loom has no per-session branch or PR state to derive them from yet.

- **What the user gets:** Group sessions, branches and PRs by ticket key (EDDP-123); 'New session from ticket' with the ticket context in a delimited block the user can edit before sending; a computed Work list (Needs you / Working / In review / Merged) answering 'where was I'; optional, user-confirmed suggestions to move the ticket or archive the session when the PR merges.
- **Why this value:** Fits the user's two ticketed work projects and the HN-style session-per-ticket workflow in power-user-workflows.md, and de-dup is already built. But the user can already type the prompt or use their own skill, ticket text fetching depends on their MCP, and the high-value half (PR/merge-derived Work list) is blocked on I-31 and worktree identity; the research itself says the ledger duplicates the activity view and that the ceiling is 2-3 parallel sessions, so a ticket board is low leverage for one person.
- **Depends on:** I-31 (PR/MR state, glab for GitLab) for any In review / Merged column or merge suggestion; A per-session branch identity (worktree-per-ticket convention or storing the hook payload cwd) for ticket-to-branch derivation; Making SessionOpening.openedBy optional and extracting the shared validate/de-dup/start function from OpenSessionCoordinator

## Orchestration and the cross-session channel

### I-35

**Extend 'a session opens a session' (parent/child, batch fan-out, narrow always-allow, ceilings)** · verdict **adopt-light** · cost M · value 3/5 · proposed by 5 reports · [full card](ideas/I-35.md)

> Adopt a smaller version (a click-through roll-up row of opened sessions under the parent card, a capped batch open with one approval, and a deny cool-down); put per-project always-allow, the permission ceiling and the worktree field behind a spike or later, because they are the only parts that widen standing authority and need CLI facts Loom does not read today.

- **What the user gets:** The shipped open-session flow becomes legible and quicker: the opened session nests under its parent with one 'child finished / needs you' signal on the parent card; an agent can propose several sessions and the user approves them in one sheet; trusted cases ask once per project; results return to the asking agent as session id + verified outcome.
- **Why this value:** The user runs several sessions and ticket-keyed multi-agent flows, which is exactly why D-40 was built, so a legible parent-to-children view and one approval for a multi-ticket plan are real wins. But the single-session flow already approves in one click with a literal box, the 'from <parent>' origin already exists, and the finish/needs-you of any child already reaches Active, the Dock badge, the menu bar and Cmd+J. The remaining gain is mostly the batch and the glanceable roll-up; the high-risk part (always-allow) buys one saved click on a rare action. Unknown: how often the user's agents actually call open-session today (no usage data in the repo).
- **Depends on:** D-40/D-42 shipped open-session flow (no dependency on new work); Piece 5 (worktree field) depends on the separate 'new session in worktree' idea; Loom has no worktree code; 'child finished returned to the asking agent' (a wait verb) belongs to the separate read-only orchestration verbs idea (T3-style) and needs its own approval model; Piece 4 needs a user decision to amend D-40 and contract §7 before any build

### I-36

**`loom` CLI + read-only verbs + wait + event hooks (the read side of multi-agent work)** · verdict **adopt-light** · cost M · value 3/5 · proposed by 7 reports · [full card](ideas/I-36.md)

> Build only the in-session read side (sessions, status, wait) as new verbs on the existing authenticated control socket, served from the SessionEventHub with no new UI; leave outside-shell scripting, event hooks, `read` and `--explain` for later, because they are either redundant, unsafe to expose, or have no precedent that fits Loom.

- **What the user gets:** Agents and the user's own shell/Raycast scripts can address 'this session' and query siblings without polling: `loom sessions --json`, `loom status <id> [--explain]`, `loom wait <id> --until needs-you|finished|failed --timeout`, `loom read <id> --last-turn`; plus a small personal hooks file that runs commands on Loom events (session finished, needs approval, ticket opened, worktree created).
- **Why this value:** It is the "follow the child" half of D-43 and the user's ticket-session workflow (a session opens an EDDP-* session through loom open and then needs to know when it finished or is blocked, without the user relaying), and it costs nothing at idle. But it only pays when a coordinator agent actually runs several top-level sessions, which is a narrow part of daily use, the human already gets the same signals from Cmd+J, the menu bar and notifications, and the outside-shell, event-hook and read parts that would widen the audience are the weakest or riskiest. Score rises to 4 if the user confirms they run coordinator-style workflows weekly.
- **Depends on:** D-46 timing lifted by the user (the channel is wanted but undated); A new DECISIONS row amending D-40/contract §7 to allow read verbs; Moving SessionIndicator's derivation into LoomCore; Existing loom:open-session socket and plugin (D-40, D-42)

### I-37

**Cross-session message channel as a user-authority broker (the wanted D-43/D-46 channel)** · verdict **adopt-light** · cost L · value 4/5 · proposed by 9 reports · [full card](ideas/I-37.md)

> Build the user-authority hand-off in two thin slices on machinery Loom already has (user-initiated send with hook-verified delivery first, then an agent `send` that reuses the open-session approval card), and do not build the full broker or govern the CLI's native channel, because native hold/accept cannot be made observable or user-authorized.

- **What the user gets:** One session can hand a short result or question to another (planner to implementer, reviewer back to author) under the user's control and with verified outcomes, instead of copy-paste between cards; or the user can send between sessions themselves.
- **Why this value:** The user is a heavy multi-session user with ticket-keyed sessions and a standing wish (D-43) for exactly this, and today every hand-off is copy-paste between cards. Slice 1 alone (send a session's last answer to another session, with an honest delivered/stalled result) is a large, cheap win and also the base of the side-chat and queue ideas. Slice 2 adds the planner-to-implementer and reviewer-back flows but carries injection and fatigue risk, so it is a 3 on its own; the full broker (grants, caps, read verb, native governance) is not worth its cost for one user and is where the 'L' of the original estimate sits.
- **Depends on:** I-02 (queue/send to a session), the in-memory delivery record and write path are shared; I-01 (user-initiated send entry points); I-38 (session reference: file digest for text above the inline cap); D-40/D-42 machinery already shipped (control socket, token, authorize, RequestList box, Needs approval attribution); A tracker change to separate prompt-safe from other waitingForInput causes (needed by I-02 too); Contract §7 acknowledgement for PTY text transfer as the delivery path, or the S3 result

### I-38

**Handoff and session reference (bounded digest, fresh session, fresh reviewer)** · verdict **adopt-light** · cost M · value 3/5 · proposed by 5 reports · [full card](ideas/I-38.md)

> Build a token-free, user-initiated, bounded session digest (snapshot file in a Loom-owned cache, pasted unsent into a live prompt or used to seed a fresh handoff/reviewer session) and skip the agent-driven /handoff automation and any live or agent-initiated reading, because the digest layer is cheap and fits every principle while the automation adds state machines for little gain over the user's own skill.

- **What the user gets:** Feed one session's work into another without a messaging channel: drag a card into another session or use 'Reference session' to paste a small bounded reference (transcript path plus a generated markdown digest of title, last N turns, truncated tool bodies, files touched); a 'start fresh session with a handoff note' action when context is heavy (via the user's own skill / Obsidian); a user-initiated fresh reviewer (second-opinion) session. Costs no tokens until the agent reads it.
- **Why this value:** Real but second-order for this user. Multi-session, multi-project work with ticket keys makes planner-to-implementer and writer-to-reviewer handoffs common, the official Writer/Reviewer pattern is endorsed in the research, and drag-a-card is a delightful, token-free gesture that also becomes the seed of the CP3 channel (D-43/D-46). But a mechanical digest (last N turns, truncated tools) is a worse handoff than the note the user's own skill and Obsidian vault already produce ("things not to redo", decisions), loom:open-session already covers agent-initiated handoff with user approval, and a fresh reviewer is about three clicks today (New session, type the skill). The unique value is the zero-typing reference/seed and the lineage line, not the digest quality. The compaction-threshold advice in the research varies (35-40%, 50%, 100-120k, 500k, 700k), so no threshold-based nudging is encoded here.
- **Depends on:** none hard; I-23 (context meter) only for an optional 'start fresh' hint on a heavy session; keep it out of this idea and show information only, never act; D-43/D-46 cross-session channel: this is its safest first slice; a later `$LOOM_CLI read <ref>` verb on the existing control socket would use the same digest builder with a per-grant user approval; Loom's existing session origin line (D-39 S2) for lineage of fresh sessions

## Automation

### I-39

**User-armed Goal mode driven by the Stop hook** · verdict **adopt-light** · cost M · value 3/5 · proposed by 1 reports · [full card](ideas/I-39.md)

> Skip the idea as written: Claude Code already ships `/goal` (documented, CLI 2.1.300 here) as a session-scoped prompt Stop hook with a Haiku evaluator, so Loom should not build its own checker and Stop-hook loop. Adopt only a light layer that makes Loom aware of a native goal: a card marker, no false "Finished" between goal turns, and one real end signal.

- **What the user gets:** Arm a goal (objective, token budget, turn cap default 20) and walk away: Loom answers each Stop with a block+reason that continues the work until an independent check says done / needs-you / budget / cap. The blue 'finished unviewed' then fires once at the end. Stop always wins and pauses the goal.
- **Why this value:** The walk-away loop the user wants already exists in the CLI and costs Loom nothing. What Loom adds is trust: a visible marker, no false blue between goal turns (which also protects the Dock badge, menu bar and Cmd+J across several parallel sessions), and one real end signal. That matters most for a heavy multi-session user who walks away. The arming sheet is mere convenience. The idea as written, a Loom-owned checker and loop, would add high cost and risk for little over the CLI feature. HN-style "works most of the time, not always" caveats apply to the CLI evaluator and are out of Loom's hands. These are my estimates; the user has not said whether they use /goal today.

### I-40

**Scheduled runs with a triage inbox (later)** · verdict **later** · cost XL · value 2/5 · proposed by 4 reports · [full card](ideas/I-40.md)

> Technically a clean fit if cut down to read-only recipes plus one armed timer that runs only while Loom is open, but for this user it mostly duplicates Claude skills and /loop, the unique unattended value costs plan budget, and the full version (worktrees, budgets, return-to-session) is XL, not L, so park it behind the worktree and usage-by-source work.

- **What the user gets:** A Scheduled section whose runs (daily repo brief, CI-failure triage, stale-docs sweep) arrive as ordinary sessions in the existing Active/Finished-unviewed machinery, with 'nothing to report' runs auto-marked viewed.
- **Why this value:** The user's stated wishes are side chat, right panel, usage, reliable deletion and free idle sessions; scheduling is not among them. Reusable prompts are already Claude skills or slash commands (a brief is Cmd+N plus a skill), in-session repeats are /loop, and the only unique value is unattended timing, which spends the plan window the user watches and runs only while Loom is open and the Mac awake. Read-only brief/triage runs on two work projects are pleasant but not a productivity step change; the high-value form (editing runs in worktrees with budgets) is the XL part.
- **Depends on:** Worktree-backed sessions (digest 'idea 5'; needed only for edit-capable recipes, not for read-only ones); Usage by source / per-session token query over ClaudeUsageIndex (needed for token budgets and the 'scheduled' attribution line); Persisted unread-result flag for ended sessions (new, part of this idea's own cost); Cross-session channel decision (D-43/D-46) so the 'agents cannot create schedules' rule is designed once with the rest of the authority model

## Search and history

### I-41

**Cross-session transcript search** · verdict **adopt-light** · cost M · value 3/5 · proposed by 4 reports · [full card](ideas/I-41.md)

> Build the no-index, on-demand, budgeted transcript scan as a second stage of the existing sidebar search; skip the FTS5 index, the Cmd-K palette and in-panel Cmd+F for v2 unless a half-day measurement of the user's real corpus says the scan is too slow.

- **What the user gets:** 'Which session did I solve X in / which touched EDDP-123' becomes a keystroke: content hits in the existing sidebar search (and a Cmd-K palette), ranked above loose title matches, showing the matching line and opening at the right place; Cmd+F inside a session's transcript panel.
- **Why this value:** The pain is real for someone with several sessions across two projects and EDDP-* tickets, and the answer is often just a snippet plus Resume. But the user's own wish list (side chat, right panel, usage, deletion, idle cost) never names transcript search; with 2-3 live sessions, the 30-day default retention and a notes vault the recall window is short; and Claude's own `--resume` picker takes a search term. Useful and cheap in V1, not transformative. The M estimate holds only for V1 (about 700-900 lines in LoomCore plus model, sidebar section, design preview, tests, evidence). The FTS5 variant is L (the reference size is `ClaudeUsageIndex` at 1,318 lines plus forgetters, eviction, schema, settings and diagnostics), and the hit reader is another M-L. Orca's L was the honest figure for the index.
- **Depends on:** No hard dependency for V1.; Optional: the read-only main-session transcript view / conversation-view idea (needed for 'open at the hit'; V1 deliberately does not need it).; Optional: a command palette idea, if one exists, would reuse the same searcher.; A new DECISIONS entry (contract §13 lists 'full transcript search' as an unscoped idea).

## Remote and mobile

### I-42

**Away from the Mac: Remote Control toggle, presence file, optional content-free push** · verdict **spike-first** · cost M · value 3/5 · proposed by 7 reports · [full card](ideas/I-42.md)

> Keep only the launch flag, the presence file and a hook-proven badge, and cut the push and the preflight process; run one throwaway-profile spike first, because Loom's verified-Stop promise and its CLAUDE_CODE_DISABLE_AGENT_VIEW=1 launch env are untested against `--remote-control`.

- **What the user gets:** For sessions that already run in Loom PTYs, a 'Reachable from phone' toggle (and a Settings default) so approvals, answers and nudges can be done from the phone, with an RC badge on the card; Claude's own phone pushes are suppressed while you are at the Mac; optionally a content-free 'session X needs you' push. No Loom server, relay or app.
- **Why this value:** The use is real. Several long multi-agent runs blocked on approval, with the user away from the Mac, is exactly the case RC serves, and Anthropic's own pushes and approval UI already exist. But the user's own wish list (side chat, right panel, usage, reliable delete, idle cost) never mentions a phone, and the bare benefit is already available for free through `remoteControlAtStartup` or typing `/remote-control`. Loom's increment is convenience, the quiet-push presence file and an honest badge. Reliability caveats (open silent-disconnect and approval-not-reaching-host issues, a Mac that sleeps while a session waits for approval, server-side transcript storage) cap the value until the user confirms they want it.
- **Depends on:** Spike S1 to S4 below; Optional: the persistence idea's stay-awake option, which decides whether phone approval works while the Mac idles; None of the other v2 ideas is required; it reuses the existing hook, hub and SystemServices seams

## Browser and preview

### I-43

**Process-tree view: listening ports / dev-server pill and on-demand resource inspector** · verdict **adopt-light** · cost M · value 3/5 · proposed by 5 reports · [full card](ideas/I-43.md)

> Adopt a light version: an event-driven "what is this session running and listening on" popover and a conditional port segment, read from the run scope Loom already owns; skip the embedded WKWebView and the LOOM_PORT range.

- **What the user gets:** An 'Open localhost:PORT' pill on a card when its own process tree is listening (default browser; an embedded WKWebView only on request), and an on-demand popover with per-session process-tree memory/CPU and the top 3 child processes, so a leaked dev server or runaway test run is visible and feeds the park decision.
- **Why this value:** Real but not a daily driver. Several concurrent sessions with JVM or node plus test runs make 'which session holds the RAM / who owns :8080' a genuine question, and it feeds the manual Stop decision (Loom has no auto-park; D-38 turned idle stop off). But the user is backend-focused, so an 'Open localhost' browser pill has low payoff (APIs, and Docker-hosted databases are invisible by construction); the useful backend case is port-conflict and leaked-process visibility, which the popover covers. The big productivity levers in the research (side chat, verified send, hibernate, transcript search) are worth more; this is a cheap, safe secondary feature that reuses existing primitives.
- **Depends on:** none hard. Soft: an idle-hibernate/park idea (this feeds that decision); a verified 'End this process' action would build on it; LOOM_PORT belongs with any worktree/env-injection idea.

## Platform reliability

### I-44

**Engineering guardrails: performance budgets, reader regression, contract fixtures, compat advisories** · verdict **adopt-light** · cost S · value 3/5 · proposed by 7 reports · [full card](ideas/I-44.md)

> Loom already ships most of this (per-row equality-guarded sidebar with a body-count harness, offset+inode transcript tailing, visibility-gated work, session-scoped 1 s hooks, drift detection), so adopt only the missing slice: a parametrised 1/10/100 render-budget test table that every v2 per-card or per-panel datum must join, value-free hook-payload shape fixtures re-captured on CLI change, and a drift explanation string, with no bundled bad-version JSON and no network fetch.

- **What the user gets:** Protects the properties that make Loom usable all day (CPU gate, no beachballs with 30+ sessions, accurate status) as v2 adds per-card data, and turns CLI-update surprises into actionable messages.
- **Why this value:** It is protective, not a feature. A v2 chat-centred UI, right panel and richer cards are where the daily-use properties (no beachball with 30+ sessions, accurate status, low idle CPU) are most likely to regress, and the shape fixtures plus the table give early warning at low cost. It is not a 4 because Loom already has the hard parts (O(1) card patching, incremental readers, hidden gating), so what remains is mostly discipline and a test table, not new capability. It rises to 4 if the chat-centred UI renders transcripts in SwiftUI, which is the largest new CPU risk.
- **Depends on:** Any v2 feature that adds per-card data, a right panel, or a transcript-rendering chat view (each adds one row to the budget table); D-04 pre-authorization of short real-Claude turns, and the idle-Mac rule, for the shape capture and the perf scenario

## Do not build

The research's explicit advice against building these, with reasons. Sources in brackets.

| What | Why |
| --- | --- |
| A Loom-owned PTY daemon or multiplexer that keeps sessions alive after Quit (zmx/tmux style) | Daemon-owned PTYs are the biggest pain source in the field: Superset pty-master fd leak exhausting kern.tty.ptmx_max and CPU/lsof issues, Orca daemon generations (#9138: 8 sessions shown vs about 46 live Claude processes, filed on v1.4.143, still open), Anthropic's own supervisor leaks (#87891, #65051), Happy's relay stack. Breaks 'Quit stops all', process ownership, verified stop and idle cost. Ended screen + --resume + idle-park (I-19) already give most of the value. If ever wanted: per-session user-chosen 'detach on Quit' hosted via Claude's supervisor (I-22) with a spike first. A user may still miss survive-Quit (Supacode's most praised feature). (superset, supacode, orca, herdr, persistence-remote-orchestration, happy) |
| Driving Claude through the Agent SDK, ACP (claude-agent-acp) or an embedded Node/Bun helper for the main session | Replaces the real CLI interface, adds Node 22+ and a several-hundred-MB adapter tree, feature lag (hidden slash commands, #3126), pinned or bundled CLI versions against 'never pin', and exposure to Anthropic's SDK billing policy that changed four times in ten months. If a structured engine is ever wanted, I-07 reaches the same protocol without a runtime; revisit ACP only if multi-provider (Codex/Gemini/OpenCode) returns. Swift ACP SDKs are thin and low-activity (32/7/11 stars). (zed, chat-ui-paths, emdash, conductor, t3code, paseo) |
| Screen-scraping the TUI for dialogs, input state or status (Ghostex-style) and herdr-style regex detectors | About 5.2k lines of Rust for Claude alone, comments pinned to CLI versions, violates update resilience and 'never report false success' because a paste cannot be verified. Hooks, registry and OSC 7501 are the stable base. (chat-ui-paths, herdr, review-git-loop) |
| Notch overlay, mascots, sentiment analysis, haptics, AppleScript/Accessibility terminal-jumping, SSH hook bridging, Watch relay, and managing hooks in the user's global settings.json | The category's own authors spent releases fixing idle CPU and jump bugs these create (CodeIsland idled about 5.3% CPU even after gating mascot animation); jumping is moot because Loom owns the tabs; global hook management causes duplicate/stale hooks. Use menu bar, notifications and per-session --settings instead. (attention-surfaces) |
| A Loom-owned remote surface: relay, E2E crypto, push service, native phone app, web terminal, voice agent | Needs a process surviving Quit and constant connections, huge support surface (Happy's relay audit and outage; Paseo spends most effort on phone UX), conflicts with local-only data and low resource use; Claude's Remote Control (I-42) already does outbound-only mobile access. The only acceptable heavier variants are a loopback read-and-approve page over the user's own Tailscale/SSH while Loom runs, or a content-free push; cloud-style Remote Control and Warp-style shared sessions are out. (happy, persistence-remote-orchestration, warp, paseo, attention-surfaces, cursor) |
| Reading the CLI's Keychain OAuth token or calling the undocumented /api/oauth/usage endpoint for plan limits (Orca, CodeIsland, Notchi, OpenChamber do this) | Reverse-engineered interface using the user's subscription token; Anthropic's legal page says third parties may not collect, store or intermediate Claude.ai credentials. Keep the documented get_usage control request and statusLine rate_limits. (orca, attention-surfaces, openchamber, claude-official) |
| Embedded browser panel, script-injecting preview proxy, element/region annotation, agent-driven browsing (design mode) | A browser engine is the heaviest component Loom could own and costs memory while open (cmux and Superset pay); a CSP-stripping proxy with injected framework adapters is a permanent surface; the user is backend-focused. Lighter: open the dev-server URL in the default browser (I-43) or a lazily created WKWebView destroyed when hidden, and a screenshot-region-to-prompt capture if ever wanted. (vibe-kanban, openchamber, cursor, superset, orca) |
| An automatic reviewer/guardian agent or a classifier that decides a session 'looks done' | Hidden model spend (Codex Guardian helper agent about 35% of tokens in one report; OpenChamber's classifier is a model call per turn) conflicts with low resource use and cost transparency. A per-turn approvals counter (I-15) is the cheap substitute. (codex-app, openchamber) |
| Kanban board / task runner / ticket auto-trigger from webhooks | Vibe Kanban's board died with its cloud; users said keep the ledger, drop the runner; webhook-triggered sessions need a daemon and break 'Quit stops all'. Keep derived ticket grouping (I-34) instead. (vibe-kanban, emdash, power-user-workflows) |
| Plugin marketplace or Electron-style plugin host; a worktree pre-warm pool | Marketplace/hosts conflict with Loom's size and trust principles (herdr's is unreviewed arbitrary code); Emdash itself removed its worktree pool (commit 4193beb) because spare worktrees are state nobody asked for. A personal hooks file (I-36) covers the long tail. (herdr, emdash, paseo) |
| Auto-commit per turn, Loom's own rewind/reset engine, in-app accept/reject hunks or editor, stage/revert UI | Auto-commit rewrites the user's branch history; reset depends on drifting CLI flags (--resume-session-at); accept/reject needs an editor holding buffers and duplicates the user's IDE. Link out to Claude's /rewind and keep the diff read-only (I-28/I-30). (vibe-kanban, zed, cursor, codex-app) |
| Per-repo or per-workspace polling and watchers (PR dashboards, git status timers, lsof port scanners, 15-45 s session-list reloads) | The loudest CPU/rate-limit failures in the field: Superset (10 s/30 s PR polling, per-workspace GitWatcher, git fan-out), Emdash (250 ms scan, per-repo polling), Supacode (GraphQL storms #830/#844), OpenChamber #5023, Happy's 3 s transcript re-read. Event-driven and visible-only (I-28, I-31, I-43, I-44). (superset, emdash, supacode, openchamber, happy, review-git-loop) |
| Orchestrator/swarm UI, a custom composer that replaces the CLI prompt, a full diff/PR/CI stack and a worktree manager as the v2 headline | Position of power-user-workflows: they duplicate what Anthropic Desktop/agent view ships, scale the part users cannot absorb (realistic ceiling 2-3 sessions, plan quota the second ceiling), and trigger wrapper failure modes. Note this DISAGREES with the 10-14 product reports that propose diff and worktrees, so treat I-28/I-32 as a user decision, not a given. (power-user-workflows) |
| Making Claude's mods the base transport (watch-list only), plus Channels, asyncRewake waiters and the CLI's inbox socket as the review transport | Mods are two weeks old with API churn nearly every release 2.1.295-2.1.301 (the exact count is unverified), run unsandboxed with full user permissions, are blockable by managed policy (sec-default mod, allowManagedModsOnly) and the sec-default mod shows Anthropic treats them as a security surface. Keep hooks + statusline + OSC 7501 as the stable base; revisit after a few release cycles (I-01 option 3). (claude-official, review-git-loop) |
| Orca-style blind write after a delivery timeout, hidden --prefill dependence, and pasting without readiness gating (Superset) | Reports 'delivered' without proof; --prefill is undocumented. Use I-01's gated, verified, 'outcome unknown' semantics. (orca, superset, review-git-loop) |
| Compact-on-Enter defaults, countdown tickers, always-on animation or live timers in the sidebar | Changes what Enter means (predictability) and costs idle CPU; schedule one wake at the deadline instead. (t3code, orca, attention-surfaces) |
| Adopting Claude agent teams as a Loom concept; copying Paseo's cascade-archive default; copying OpenChamber's on-by-default agent tool | Agent teams are experimental and token-heavy; cascade and no-approval tools break cross-session actions under the user's authority. (persistence-remote-orchestration, paseo, openchamber) |
| Changes Walkthrough (one-shot claude -p over the diff, cached) for now | Needs the large prerequisite diff view (I-28) and a model call with usage accounting; presents confident output that can be wrong if anchoring fails. Revisit only after the plain diff view proves use. (openchamber) |

## Cross-cutting lessons

- Resource failures are the loudest competitor complaint, and native does not guarantee lightness: cmux (native Swift) had a 100% CPU SwiftUI sidebar layout loop, leaked openThread loops and a large memory report; Electron peers (Superset git subprocess fan-out and lsof scanner, Orca daemon generations, Paseo resident daemon, OpenChamber 45 s list polling and unvirtualized rows, Emdash 250 ms scans) are worse. Common causes: watchers/polling per workspace, whole-file transcript re-reads (Happy 3 s rescan 20-40% CPU), animated overlays (CodeIsland 5.3% idle even after gating), mounting all history. Cure that worked: herdr cut 89-95% CPU by dropping the sidebar spinner and skipping hidden-pane renders. Many figures are single-user anecdotes or on nightlies; treat them as failure classes, not baselines.
- CLI-update fragility is the second theme: T3 treats Claude 2.1.111-2.1.280 as graceful and warns by advisory; herdr abandoned hook-driven state for Claude then removed its hooks from users' settings after stale-state bugs; Orca's docs disagree with its code (uses a keychain token, OSC titles); Vibe Kanban pins a default CLI; Conductor bundles the CLI (about 1 day behind) and lags at SDK/feature level; mods API churn nearly every release; JSONL is declared CLI-internal in the SDK typings; updatedInput is validated from 2.1.300 (unknown keys dropped); statusline and OSC fields are version-gated; hook timeouts differ per event. Design rule: documented interfaces first (hooks, --settings, statusline, OSC 7501, claude agents --json, get_usage), capability detection and drift evidence for everything else, unknown renders as 'unknown' or raw, never pin.
- Delivery verification is Loom's real edge and every competitor lacks it: Warp, Superset, Orca (on the diff-note path), Emdash and Vibe Kanban write to the PTY without proof; Loom's UserPromptSubmit hook sees the submitted prompt. Caveats from fact-checks: the hook prompt has pastes expanded or wrapped in <pasted_content>, invisible Unicode is stripped on Enter, Claude wants a typed lead before a paste, slash commands get swallowed by autocomplete, long bursts truncate, so 'exact hash match' is overstated (normalize or use a marker), a single writer per session is needed, and the honest outcome vocabulary is queued / delivered / outcome unknown with no auto-retry. Refuse to write in Needs approval or any modal.
- Status truth rests on documented-but-subtle hook semantics: Stop carries background_tasks and session_crons and last_assistant_message; Stop does NOT fire on interrupt and there is no interrupt event; permission_prompt Notification waits about 6 s while PermissionRequest is immediate; idle_prompt (about 60 s after finishing) is not 'needs you'; SubagentStop also fires for internal agents (prompt suggestions, /btw); transcript_path writes lag; agent_needs_input/agent_completed fire only while agent view is open. Emdash's regex-on-message-text workaround is obsolete (notification_type is documented). Competitor bug classes to turn into tests: finished-with-background-work, foreign sessions inheriting env, Failed downgraded by a later Notification, resume/compact counted as completion.
- Billing/policy: the real CLI in a PTY is on the safe side. Anthropic's support article (updated 2026-10-07) says Agent SDK, claude -p and third-party apps still draw from subscription limits, the May 13 metering change was paused June 15 'for now', the April 4 policy hit third-party harnesses, the legal page says SDK-based products should use API keys and allows the unmodified binary with the user's own login, forbids collecting or intermediating Claude.ai credentials, and the Oct 7 monthly credits are API credits that do not cover interactive Claude Code. Conductor/T3/Paseo/Zed users were hit by the uncertainty. Any headless/stream-json feature (I-07, headless side chat) should be an isolated, killable opt-in, and the support article re-read before each release.
- Anthropic absorbs breadth: Desktop ships diff view with batched comments, side chat (Cmd+;), preview, PR/CI monitor, scheduled tasks and Routines; the CLI ships agent view, Remote Control, /btw, /diff (a mod), cross-session messaging, --worktree, idle compaction. Loom should compete on what a light native host does better: attention routing, status accuracy, multi-project/multi-session workspace, usage/context health, subagent tree, ticket-centred organisation, user-authorized cross-session actions, and cheap lifecycle (park, keep-awake). Warp and Zed 'Terminal Threads' show that keeping the real CLI is a shipped, viable design; chat-first re-renderings are criticised for hiding what the CLI does while terminal tools are criticised as tab managers, which is why a lens over the real session (I-05/I-06) is the favoured middle.
- The bottleneck is the human, not generation: review, attention and plan quota. Practitioner ceiling is about 2-3 interactive sessions (3-5 with strong separation); Hashimoto vs Cherny on notifications is single-agent vs multi-agent regimes, not doctrine; Auto mode (2.1.283+) makes approvals rarer than older statistics suggest. So v2 value is triage (what needs me and why), review aids and context/quota health rather than more agents; features that raise parallelism (worktrees, orchestration UI) are contested (power-user-workflows skips them, ten product reports want worktrees).
- Persistence converges on hibernate-and-resume, not daemons: Orca hibernation (30 min default, experimental), Claude's supervisor (idle unattached stop after about an hour), Supacode (on by default, Beta), cmux (only above 12 live terminals), Conductor (idle shutdown + --resume). Loom already has the hard parts (run scope, verified Stop, resume, ended screen). Hazards: killing background tasks/monitors/wakeups, cold-resume cache cost and idle compaction, resume failing after CLI updates, stale resume references (herdr), and the supervisor's own open leak bugs.
- Fork-style features share costs and cleanup duties: a fork re-reads the whole context (tokens, cache), shares the working tree (read-only is guidance or tool limits, Codex enforces only at prompt level), pollutes the registry and `claude --resume` lists, double-counts usage, and only sees flushed turns (fork from the last completed turn). Verified deletion must cover forks and any search index rows, and transcript cleanup (cleanupPeriodDays, default 30, configurable) must be considered for rollups.
- Cross-session authority: competitors differ mainly in approvals. Safe patterns: scoped, short-lived per-session credentials revoked on stop; delegation only while the parent works; privilege ceilings; refusal into blocked sessions; explicit delivery states; text-only size-capped messages with provenance labels; idempotency keys; narrow revocable always-allow. Anti-patterns: OpenChamber's on-by-default tool, Vibe Kanban's MCP with no approval, Supacode's global always-allow flip, T3's 30-day all-project grants, herdr's blocked check that only works when its scraper is right. Claude's native cross-session messaging exists (2.1.224+) but its default is not user-authorized-only and its wire format is undocumented.
- Hook hygiene: scope hooks per Loom-started session with `claude --settings` (never the user's global settings.json), keep them tiny and a no-op outside Loom, fail open, bind decisions to (session id, request id, kind), cancel pending cards on PostToolUse/Stop/SessionEnd/PID exit, hand back rather than decide on timeout, and avoid statusLine takeover (Vibe Island #137 / Open Island class, hides CLI footer hints) unless chaining the user's own. Orca's managed statusLine install respects an existing user statusLine.
- Evidence discipline: fact-checks repeatedly corrected citations (open_issues_count includes PRs; many cited issues are closed/fixed or single-reporter; star counts are inflated; competitor comparison pages and some reports are interested parties; Steinberger is a Codex user; Warp's Ctrl-C synthesis is only the viewer path; cmux hibernation is not an idle timer; DISABLE_TELEMETRY no longer blocks Remote Control; crossSessionInbound hold has no dialog). The product-note fact-check section wins over report text, and several mechanisms remain explicitly unverified (PermissionRequest hook vs TUI dialog race, fork behaviour mid-turn, side_question shape, RC daemon behaviour on macOS, window-size/TTL tier in transcripts, agent ids in hooks).
- The user's own long-standing wishes map to: side chat -> I-08 (free shortcut) then I-09 (forked PTY child), with I-05/I-07 only if a chat look is wanted; right panel -> I-10 (needs D-34 revisited; subagent tree already opens in place of the terminal); remaining usage -> shipped plus I-25/I-26/I-27 (ChatGPT later, Codex frozen); reliable deletion -> already shipped, extended to forks, search index and rollups; idle sessions cost nothing -> I-19 plus I-05 ended-session view; a user-authorized cross-session channel -> I-02/I-38 then I-37.
- Suggested sequencing signals from the evidence (not a decision): cheap, high-convergence, low-risk first (I-20 keep-awake, I-12 status hardening, I-23 context meter, I-17 attention polish, I-08 /btw shortcut, I-14 card content), then the shared foundations (I-01 send primitive, I-05 read-only conversation view), then the features that depend on them (I-02 queue, I-09 side chat, I-28/I-29 review loop, I-15/I-16 approvals), and last the contested or large decisions that need the user (I-32 worktrees, I-07 Chat mode, I-22 supervisor, I-24 statusLine bridge, I-37 channel, D-34 right panel).
