# Sphyrna Features & Reference Map (`docs/FEATURES.md`)

**Updated:** 27 October 2026 · **Decisions:** [D-104](../DECISIONS.md), [D-105](../DECISIONS.md)

This file lists Sphyrna's main features, one heading each, and gives every feature a place to record how **Orca** and
**T3 Code** build the same thing. Since D-104 these two apps are Sphyrna's final references: for how a feature works
first, and case by case for how it looks.
- What a feature must do stays in [SPEC.md](../SPEC.md), how it looks in [design/DESIGN.md](../design/DESIGN.md), and
  where it lives in code in [ARCHITECTURE.md](ARCHITECTURE.md). This file links to them; it does not repeat them.
- The reference round fills the slots below (see [How the reference round works](#how-the-reference-round-works)). On 27 Oct
  the planner read the features 1.8.0 touches (F1, F3, F5, F13–F17); their verdicts point to the slices of
  [plans/1.8.0](../plans/1.8.0/README.md). The design system itself is read in [FEEDBACK-7](../plans/FEEDBACK-7.md) FB7-2.

---

## The references

| | Orca | T3 Code |
| --- | --- | --- |
| **What it is** | "The AI Orchestrator": agents side by side, each in its own worktree, with terminals, review, browser, GitHub/Linear, SSH and a mobile companion | "An agent harness control surface": desktop, web and mobile apps over a local server that drives the agents |
| **Installed app** | `/Applications/Orca.app` (1.4.241, `com.stablyai.orca`) | `/Applications/T3 Code (Nightly).app` (0.1.3-nightly.20261027, `com.t3tools.t3code`) |
| **Source** | `~/Documents/github/orca` (`stablyai/orca`, `1df8501`, 26 Oct) | `~/Documents/github/t3code` (`pingdotgg/t3code`, `a9b513b`, 26 Oct) |
| **Stack** | Electron, TypeScript (`src/main`, `src/renderer`), pnpm | TypeScript monorepo: `apps/{desktop,server,web,mobile}`, `packages/provider-*`, `packages/source-control-*` |
| **Harnesses** | Claude Code, Codex, OpenCode, Pi, Gemini, Cursor, Copilot, Droid and others | Claude, Codex, Cursor, Grok Build, OpenCode, Antigravity |
| **License** | MIT (Lovecast Inc.) | MIT (T3 Tools Inc.) |
| **Already used** | D-100 took Orca's stance: the real CLI in a terminal, status from hooks | D-98 (Connections) and D-99 (Usage) follow T3 Code's pages; the palette ranks matches by T3's bands (SPEC §6.4); RESCUE-PLAN §1 read T3's model manifest |

**Where Sphyrna stands (D-104).** Sphyrna is simpler than both and native to macOS. It takes their logic and, where it
fits, their look. It does not take their breadth. "Lighter" is still a claim to measure: the real-scenario energy check
(RESCUE-PLAN Phase B, `real_energy.sh`) runs the same scenarios on all three installed apps before anyone says it.

---

## Index

| # | Feature | Area | Status | Spec |
| --- | --- | --- | --- | --- |
| F1 | The real CLI in an owned terminal | Sessions & terminal | Live (Claude) | §1.2, §3 |
| F2 | Process ownership & verified stop | Sessions & terminal | Live | §2 |
| F3 | Session lifecycle & status | Sessions & terminal | Live | §4 |
| F4 | Stopped sessions: kept screen & record | Sessions & terminal | Live | §1.2, §4.1 |
| F5 | Sidebar: Projects & Activity | Workspace & navigation | Live | §6.2 |
| F6 | Tabs, header & session menu | Workspace & navigation | Live | §6.3 |
| F7 | Command palette & transcript search | Workspace & navigation | Live | §6.4 |
| F8 | New-session draft | Workspace & navigation | Live (Claude) | §6.5 |
| F9 | Home & Project page | Workspace & navigation | Live | §6.6 |
| F10 | Inspector: Overview & usage | Review & insight | Live | §8.2 |
| F11 | Changes: diff review & comments | Review & insight | Partial | §8.2 |
| F12 | Agents: subagent tree & transcripts | Review & insight | Live | §4.2, §8.4 |
| F13 | Harnesses & Connections | Harnesses & usage | Live (Codex read only) | §6.7 |
| F14 | Usage & plan limits | Harnesses & usage | Live | §6.2, §6.6, §6.7 |
| F15 | Models | Harnesses & usage | Live | §6.7 |
| F16 | Session channel between sessions | Coordination | Live (no `send` yet) | §9 |
| F17 | Verified permanent deletion | Data & storage | Live | §5.1 |
| F18 | Retention review & Storage | Data & storage | Live | §5.2, §5.3 |
| F19 | Remora | Assistant | Live | §10 |
| F20 | macOS integration | System | Live | §11 |
| F21 | Light: resource budgets | Guarantees | Live as budgets | §1.1, §12.1 |
| F22 | Cost out of sight | Guarantees | Live | §1.1, §12.2 |

Frozen features (Chat and what belongs to it) are listed at the [end](#frozen-not-in-the-reference-round).

---

## How the reference round works

For each feature, in this order:
1. **Find it in both apps:** the code paths in each source tree, and the screen in each installed app.
2. **Read its logic before its looks:** the states and their transitions, who owns which process and file, what
   happens on failure, cancellation and restart, and how their tests pin it (real-CLI tests included).
3. **Record it in the feature's slots** below: a few lines per app with `path:line` references, not copied code.
4. **Write the verdict:** what Sphyrna takes (logic, design, both or nothing) and why, in one or two sentences.
5. **Decide:** a verdict that changes what the user sees or how a contract behaves goes to `@user` and gets its own
   `D-xx` before any slice is planned. A verdict that only hardens internal logic is the planner's (`D-11`).

Notes for the round:
- Both apps are MIT. Their patterns are taken in Swift. When a piece of code is ported closely, its notice goes into
  [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).
- Features that only Orca or T3 Code have (a mobile app, remote hosts over SSH, a web app, an embedded browser, issue
  trackers) are noted when met. They are not adopted without a decision.
- The study reads the source trees and the installed apps only. It starts no agent session in them and signs in to
  nothing.

The slots use one template:
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

---

## Sessions & the terminal

### F1. The real CLI in an owned terminal
Every Claude session is the user's own unmodified Claude Code, running in a terminal Sphyrna owns (vendored SwiftTerm
with local patches). Session-only hooks, settings and the Sphyrna plugin come in through `--settings` and
`--plugin-dir`. The user's global Claude settings are never written, with one exception: the retention key in F18.
Codex has its app-wide infrastructure (F13, F14), but its sessions cannot be started yet.
- **Spec:** [SPEC §1.2, §3](../SPEC.md) · **Status:** Live (Claude)
- **Orca:** Each agent runs its own CLI in a terminal pane. Agent status comes from each vendor's hooks, with terminal (OSC) titles as the fallback (`src/shared/agent-hook-listener*.ts`, `agent-detection.ts`). For Codex it writes its hooks into the real `~/.codex/hooks.json` with trust entries in `config.toml` (`src/main/codex/codex-real-home-hook-install.ts`).
- **T3 Code:** One package per provider (`packages/provider-*`), driven by a local server; Codex through its app server (`packages/effect-codex-app-server`).
- **Sphyrna takes:** Orca's terminal-first stance (D-100). Not its writes into `~/.codex`: Sphyrna's additions stay session-scoped (FEEDBACK-7 Q10). P0 and P1 find each CLI's session-scoped route; D1 and E1–E3 build on them (plans/1.8.0).

### F2. Process ownership & verified stop
Each run lives in its own `LoomRunHost` coalition. Stop, window close and Quit follow fixed rules. A stop counts only
when the run scope is verified empty, and nothing escapes Quit. A crash or Force Quit is cleaned up by the host at
once, and the next launch recovers what is left and offers it under Continue.
- **Spec:** [SPEC §2](../SPEC.md) · **Status:** Live
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

### F3. Session lifecycle & status
Lifecycle (`active`, `idle`, `stale`, `deleted`) is kept apart from momentary work. Every surface shows one status, read
from hooks and the CLI's registry in a fixed order: failure, unclear identity, waiting for the user, working,
finished unread, ready. Other parts: a hook watchdog, and a count of background work left after a turn.
- **Spec:** [SPEC §4](../SPEC.md) · **Status:** Live
- **Orca:** Status from hook events per agent (SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, SubagentStop, Stop for Codex, `src/main/codex/codex-hook-definition.ts:23-30`), with title keywords as a fallback (`agent-title-status.ts`).
- **T3 Code:** Thread shelves in the sidebar: Working, Snoozed, Settled (`apps/web/src/components/Sidebar.tsx:3119-3140`).
- **Sphyrna takes:** The same hook-first rule for every harness, the title as fallback (D1, E1–E3). T3's status words at the card's trailing end (FB7-1, B2).

### F4. Stopped sessions: kept screen & record
A stopped session runs no process. It shows its kept terminal screen (at most 400 rows or 1 MiB) or its record, and
Resume continues it in the terminal.
- **Spec:** [SPEC §1.2, §4.1](../SPEC.md) · **Status:** Live
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

---

## Workspace & navigation

### F5. Sidebar: Projects & Activity
The sidebar has two views:
- **Projects:** sessions grouped by project, with drag reordering.
- **Activity:** Drafts, Active (with a one-line reason) and day buckets.

Each card shows its harness, model, branch and subagent tree, and Peek shows the last ask and answer on hover.
Settings and Help remain at the sidebar's bottom; the window-wide status bar carries the cached limits (B3, integrated on `v2`).
- **Spec:** [SPEC §6.2](../SPEC.md) · **Status:** Live
- **Orca:** A lifted sidebar plane (`--worktree-sidebar`), search and nav rows with counts, project groups of worktree cards with their agents (status, harness, title, last action, model, time). Tabs reorder with dnd-kit (`components/tab-bar/use-sortable-tab-rename.ts`).
- **T3 Code:** Thread rows with the project mark and name, the status and elapsed time at the trailing end, the title, then the branch and harness mark (`sidebar/SidebarThreadRow.tsx`). Projects reorder with `@dnd-kit` sortable, vertical axis, inside the scroll view (`Sidebar.tsx:23-25, 2936`).
- **Sphyrna takes:** Both: the card without a leading status column (FB7-1, B2), the lifted plane and nav rows (DESIGN-V4), and reordering by a pointer gesture with live displacement instead of the pasteboard (FB7-3, A1).

### F6. Tabs, header & session menu
Session tabs are transient or pinned (at most 8). They can be dragged, and Reopen Closed Tab brings one back. The detail
header holds the state pill, the project and branch chip, the inspector toggle and Stop. The session menu can reveal
the folder, open it in an editor or in Terminal, and copy the session ID, the resume command or the transcript path.
- **Spec:** [SPEC §6.3](../SPEC.md) · **Status:** Live
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

### F7. Command palette & transcript search
`⌘K` searches sessions, projects and actions by ranked match bands. It can also search the text inside recent
transcripts, within fixed read limits, and it offers Ask Remora when the query reads as a question.
- **Spec:** [SPEC §6.4](../SPEC.md) · **Status:** Live
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

### F8. New-session draft
A draft starts no process. A project can hold several drafts. The branch strip offers stay, new branch or new worktree,
and there are project presets and the model and mode pick. The git work on first send is bounded and rolls back if the
start fails.
- **Spec:** [SPEC §6.5](../SPEC.md) · **Status:** Live (Claude); C4 neutral choices, per-harness memory and compatible files implemented on `v2`. B4 supplies the two-picker UI; other first-message engines remain D1/E work.
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

### F9. Home & Project page
**Home** shows Continue, Needs you and Finished-not-read, with plan limits and Today beside them. Its first-run card
is "Connect your agents". The **Project page** has three tabs: Sessions, Branches and worktrees, and Instructions.
Neither page starts anything by itself.
- **Spec:** [SPEC §6.6](../SPEC.md) · **Status:** Live
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

---

## Review & insight

### F10. Inspector: Overview & usage
The Overview shows the session's facts, its context ring, its worktree, the last turn's changes and its running agents.
Token usage is split into Main, Subagents and Total, with an API equivalent. The inspector is resizable, with a
remembered width for each width class.
- **Spec:** [SPEC §8.2](../SPEC.md) · **Status:** Live
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

### F11. Changes: diff review & comments
Read-only diffs for the last turn, the whole session (from the transcript, without git) or the branch (bounded git).
Inline comments can be added, and a changed file drags out only as `@path` text.
- **Gap since D-100:** `Send to Claude` needs the Chat face (`changesSendAvailability` returns `.notChat` when the
  harness has no structured face, `CatalogModel+Changes.swift:265`). Comments can be written today but cannot reach a
  terminal session. Orca's "Annotate AI Diffs" sends diff comments back to an agent and is the first reference to read
  here.
- **Spec:** [SPEC §8.2](../SPEC.md) · **Status:** Partial
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

### F12. Agents: subagent tree & transcripts
Running and finished subagents appear in the sidebar tree and in the Agents tab. Each one's live or historical
transcript reads in two voices.
- **Spec:** [SPEC §4.2, §8.4](../SPEC.md) · **Status:** Live
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

---

## Harnesses, accounts & usage

### F13. Harnesses & Connections
One capability table says what each harness may do, and every gate asks it. Settings → Connections shows each
harness's health in six states, its version advice, the vendor's install and sign-in commands (the user runs them) and
Deep Check. Sphyrna never handles a credential. Codex is read but not started.
- **Spec:** [SPEC §6.7](../SPEC.md) · **Status:** Live (Codex read only) · **Already after T3 Code:** D-98
- **Orca:** One hook listener per agent; an installation-problem model (`src/shared/agent-cli-installation-problem.ts`).
- **T3 Code:** One `status.ts` per provider package; a missing binary reads "… is not installed or not on PATH" (`packages/provider-grok/src/server/status.ts:443`); provider states ready, warning ("Limited"), error ("Unavailable"), disabled, unauthenticated (`apps/web/src/components/chat/ModelPickerSidebar.tsx:16-23`).
- **Sphyrna takes:** A descriptor per harness in one catalogue, availability by PATH, On / Off / Not found (C1), every list from the catalogue (C2), Connections and Home with Not found (C3).

### F14. Usage & plan limits
Limits appear in three places, each read with no model call and no credential:
- the window-wide status bar's cached line per connected harness, with a details popover and explicit per-harness refresh (B3, integrated on `v2`);
- Settings → Usage (Limits and Tokens, filtered by harness);
- Home's plan limits, with pace ticks.
- **Spec:** [SPEC §6.2, §6.6, §6.7](../SPEC.md) · **Status:** Live · **Already after T3 Code:** D-99
- **Orca:** A 24 pt status bar along the window's bottom: one segment per provider (mark, 48 × 6 meter, windows' figures), a 360-wide popover with details and refresh, plus keep-awake, ports and resource segments (`components/status-bar/StatusBarSurface.tsx:116`, `StatusBarProviderSegment.tsx`, `InlineProviderUsage.tsx`).
- **T3 Code:** Settings' usage page (already Sphyrna's model, D-99).
- **Sphyrna takes:** Orca's status bar replaces the sidebar footer (FEEDBACK-7 Q7, B3; implemented on `v2`); model-scoped windows and the reset notification remain H1.

### F15. Models
One model catalog feeds the draft's picker, the popover and the header. Models are shown by their full release names,
taken from the CLI's own list.
- **Spec:** [SPEC §6.7](../SPEC.md) · **Status:** Live
- **Orca:** An effort level is valid by its shape, not by a fixed list, so a level a newer CLI adds still round-trips (`src/shared/agent-effort-level.ts`). The composer's chip reads "Opus 5.5 High".
- **T3 Code:** A model picker with a provider rail, Favorites, search and rows with disabled reasons (`chat/ModelPickerContent.tsx`, `ModelPickerSidebar.tsx`, `ModelListRow.tsx`); effort in a separate traits picker (`TraitsPicker.tsx`).
- **Sphyrna takes:** T3's model picker (rail and search) and its separate effort picker: two chips, the effort menu listing only the chosen model's levels (D-106, B4); Orca's shape rule for effort tokens (C2).

---

## Coordination between sessions

### F16. Session channel
Through the Sphyrna plugin and its control socket, an agent can do three things:
- list sessions with `sessions`, read only;
- learn where it stands with `whoami`;
- ask to open a new session with `open`, which waits for the user's approval on a card.

No transcript content crosses the channel. Sending into an existing session waits for 1.8.0 (parked).
- **Spec:** [SPEC §9](../SPEC.md) · **Status:** Live (no `send` yet)
- **Orca:** Durable mailboxes per run and dispatch. On arrival it types a one-line pointer ("You have 1 orchestration message. Run `orca orchestration check …`") into the target's terminal only when its last observed status is idle; otherwise it waits for the next idle edge, and an explicit check reads the mail (`src/main/runtime/orchestration/mailbox-pointer-delivery.ts:42-50, 190-210`, `mailbox-notification-coordinator.ts`).
- **T3 Code:** _not studied_
- **Sphyrna takes:** Orca's delivery with `@user`'s approval of every send: the mailbox, the pointer on Ready, `inbox` (FEEDBACK-7 Q8, F1); Changes' comments through it (F2). Codex 0.164's `codex queue --thread … --message …` is checked by P0 as a Codex route.

---

## Data, storage & deletion

### F17. Verified permanent deletion
Deletion is a persisted seven-step state machine that resumes after a crash. It covers the session's process, its
Claude files (from an allowlist), the catalog (secure delete), and Remora's memory. "Deleted" is said only after
verification.
- **Spec:** [SPEC §5.1](../SPEC.md) · **Status:** Live
- **Orca:** _not studied_
- **T3 Code:** _not studied_
- **Sphyrna takes:** Codex 0.164 has `codex delete <session>`, a permanent delete; D2 runs it as the harness's step inside the verified state machine, after P0 lists what it removes.

### F18. Retention review & Storage
The cleanup review proposes only stale sessions and always asks first. Storage lists each session's size on disk.
Claude's own retention setting can be changed with consent; it is the single key Sphyrna ever writes in a Claude
profile.
- **Spec:** [SPEC §5.2, §5.3](../SPEC.md) · **Status:** Live
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

---

## Assistant

### F19. Remora
A read-only assistant on Home. It writes the morning brief ("Where you left off") and answers questions across
sessions with session chips. It also offers Draft Brief on the draft page, and keeps a two-part memory that forgets
deleted sessions. Each call is an isolated `claude -p` child with fixed budgets and deadlines. Remora never acts.
- **Spec:** [SPEC §10](../SPEC.md) · **Status:** Live
- **Orca:** _to study_ (a direct counterpart may not exist)
- **T3 Code:** _to study_ (a direct counterpart may not exist)
- **Sphyrna takes:** _open_

---

## System

### F20. macOS integration
The Dock badge and Dock menu, the menu bar item, silent approval notifications, long-turn notifications, Keep Mac awake
while a session works, and Open at Login.
- **Spec:** [SPEC §11](../SPEC.md) · **Status:** Live
- **Orca:** _to study_
- **T3 Code:** _to study_
- **Sphyrna takes:** _open_

---

## Guarantees across features

### F21. Light: resource budgets
- The CPU ceiling for terminal output is CPU40.
- Hidden or idle surfaces do no work.
- Stopped sessions hold zero processes.
- Every buffer, cache and read has a bound.

The comparison with Orca and T3 Code is not measured yet (see [The references](#the-references)).
- **Spec:** [SPEC §1.1, §12.1](../SPEC.md) · **Status:** Live as budgets
- **Orca:** _to study_ (its memory and energy, under the same scenarios)
- **T3 Code:** _to study_ (its memory and energy, under the same scenarios)
- **Sphyrna takes:** _open_

### F22. Cost out of sight
Sphyrna calls a model only when the user sends, asks or approves. At most two background calls are allowed: a
session's title and Remora's daily brief. A session's context differs from a plain terminal session only by the plugin skill's
description (≤ 300 characters). Failing-first guard tests pin both rules.
- **Spec:** [SPEC §1.1, §12.2](../SPEC.md) · **Status:** Live
- **Orca:** _to study_ (what it adds to a session's context and settings)
- **T3 Code:** _to study_ (what it adds to a session's context and settings)
- **Sphyrna takes:** _open_

---

## Frozen: not in the reference round

These stay in the tree, unreachable in the product, since [D-100](../DECISIONS.md):
- the Chat face (SPEC §7);
- pinned request cards (§8.1);
- Rewind Files (§8.3);
- Quick Question (§8.5);
- side chats (§8.6).

Both Orca and T3 Code have a structured chat for Claude. If Chat ever comes back, which needs a new decision with
measured gates, their chat is its reference and this list moves into the index.
