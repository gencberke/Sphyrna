# Loom — product contract and development decisions

**Updated:** 19 October 2026\
**Status:** CP1, CP2 and CP5 (terminal engine and first window) closed; CP5 closed on 6 Oct 2026 by user decision on package I. Loom v2 is being built and ships once as 1.5.0 ([D-68](DECISIONS.md)) — see `STATUS.md` and `ROADMAP.md`.

This file is the current starting document for Loom. It combines the user's expectations, the decisions taken in the conversation with Claude, and the subsequent technical evaluation. A behavior being targeted here does not mean that it has been implemented or tested.

## 1. Purpose and priorities

Loom is a lightweight desktop application that hosts Claude Code and Codex CLI sessions with their real terminals and organizes them together. The user must be able to manage sessions while continuing to use the CLIs' own capabilities. The initial working environment is macOS; no scope decision has been taken for other platforms.

The product's core criteria:

- **Low resource consumption:** Abandoned chats must not pile up and accumulate live processes, terminal buffers and continuous background work.
- **Predictable behavior:** The same action must carry the same meaning; viewing, running, closing and deleting a chat must be clearly separated.
- **Accurate status reporting:** The statements started, stopped, delivered and deleted must describe verified outcomes.
- **Fluency and practicality:** Typing, viewing output, switching sessions and using the list must not be made harder by unnecessary waiting or constant confirmations.
- **Clean and modular structure:** UI, process ownership, data storage and provider integrations must be separate responsibilities. Modularity does not mean setting up a separate process or service for each responsibility.
- **Resilience to updates:** Claude and Codex versions must not be pinned on the user's behalf. Changes must be detected; unsupported behaviors must not turn into false success reports.

Loom's reliability is evaluated together with low resource consumption. A session that has only been removed from the screen but keeps running is not considered closed.

## 2. Location of documents and existing resources

| Source | How is it used? |
| --- | --- |
| [`README.md`](README.md) | Overview. |
| [`CLAUDE.md`](CLAUDE.md) / [`AGENTS.md`](AGENTS.md) | Agent workflow. |
| [`STATUS.md`](STATUS.md) | Current position. |
| [`ROADMAP.md`](ROADMAP.md) | Checkpoints toward the first production release. |
| [`DECISIONS.md`](DECISIONS.md) | Dated user decisions and open decisions. |
| `LOOM-PRODUCT-CONTRACT.md` (this file) | Current product decisions, technical limits and development checkpoints. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Code map. |
| [`design/DESIGN.md`](design/DESIGN.md) | Visual contract and design rules. |
| [`design/UI-MAP.md`](design/UI-MAP.md) | UI surfaces in code. |
| [`design/LEGACY-INVENTORY.md`](design/LEGACY-INVENTORY.md) | Herdr Desktop behavior inventory, reference only. The inventory is not a Loom requirement; on conflict, this file prevails. |
| [`DEVELOPMENT.md`](DEVELOPMENT.md) | Build, test, isolation, measurement. |
| `plans/` | Checkpoint plans and history; [`plans/README.md`](plans/README.md) indexes them. |
| [`Vendor/SwiftTerm/LOOM-VENDOR.md`](Vendor/SwiftTerm/LOOM-VENDOR.md) + `patches/` | Vendored terminal engine. |
| [`scripts/README.md`](scripts/README.md) | Scripts. |
| `design/` (other contents) | Reference images, the old Swift UI sources under `legacy-code/`, and the identity proposal (`IDENTITY-PROPOSAL.md`, `identity-preview.html`; direction A chosen). Reusing the old drawing code, terminal engine or architecture as-is is not required. |
| `assets/` | App icon, provider icons, and brand sources with copyright notes under `brand/`. |

The initial research report, the old spec and the Herdr removal record were removed from the repo after being moved into this file and the visual contract.

This document distinguishes **accepted behaviors**, **technical candidates** and **open decisions**. Not every feature proposed in earlier conversations is part of the scope.

## 3. Accepted decisions

| Topic | Decision |
| --- | --- |
| Core experience | The live session is always the user's own unmodified Claude Code CLI in a process Loom owns, in its terminal or in its structured mode, with one owner at a time. One app-wide switch in Settings chooses which; the terminal is always one of the choices. Codex runs in its terminal. (19 October 2026 user decision, [D-69](DECISIONS.md), adopting the v2 concept's wording with the app-wide switch. Before: “The real CLI/terminal experience of Claude Code and Codex will be preserved.”) |
| Visual target | The existing design and icons will be preserved. |
| Minimum macOS | macOS 27 and later (28 September 2026 user decision). |
| First window scope | Claude and Codex; project/projectless chat, activity/project list, search, rename, status indicators, resume/stop and basic terminal operations. Other providers, child task view, Dock/menu bar notifications and deletion are deferred to later (28 September 2026 user decision). (6 Oct 2026) Codex is not part of the first production release; Codex code may remain in development builds, paused since 4 Oct 2026. (19 Oct 2026) 1.5.0 shows Codex's entries but cannot start Codex ([D-69](DECISIONS.md)). |
| Window closing | The red close button and Cmd+W close the window; the app and jobs keep running. Cmd+Q quits the app, stopping owned jobs (28 September 2026 user decision). |
| Full app quit | Jobs belonging to Loom may be stopped. When a normal quit completes, no running process belonging to Loom must remain. |
| Claude Agent View | May be disabled in Claude sessions started by Loom to preserve process ownership. This is an accepted CLI feature exception. |
| Provider versions | Claude or Codex versions will not be pinned. |
| Core language | Swift; the core is written in this repo and checkpoint code becomes the application's core. The terminal engine is a vendored SwiftTerm with Loom's patches, and the UI is SwiftUI and AppKit; both are in use since CP5, which the user closed on 6 October 2026. |
| Experiment isolation | Checkpoint experiments are run in isolated CLI profiles (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). The user's real profiles and sessions are read only to verify that they are not affected. |
| Process ownership guarantee | Each managed run starts in a new resource coalition of a small run helper opened via LaunchServices, and the ownership boundary is this run scope (§6). Loom's own application coalition is not the ownership seed. If the scope cannot be set up, the session is not started normally and a visible error is shown. Coalition and lineage information is read with undocumented `proc_pidinfo` flavors; if it cannot be read or its format has changed, the result is not counted as success (2 October 2026 user decision). |
| Codex server and scope | Each live Codex session runs its own app-server in the same run scope as its TUI; a single session's Stop covers all of that session's work (2 October 2026 user decision). |
| Loom crash | If the Loom connection breaks without an orderly exit, the run helper stops the forked work in its own scope and exits (2 October 2026 user decision). |
| Managed CLI environment | The CLIs opened by Loom receive the environment of the user's terminal. Only variables that could leak from Loom's own parent session are left out, and Loom markers are added. It behaves like a terminal: errors and warnings in shell startup files do not stop the session from opening; they are shown as visible warnings. If the environment cannot be obtained at all, an explicit error is shown and it can be retried without restarting the app. |
| Cross-session communication | Will take place within the user's assignment and the scope the user has authorized. |
| Checkpoint order | Status and resume → first window (terminal engine and UI) → deletion and retention → authorized coordination. The window was moved forward so that Loom can be used early. Coordination was left to the end because it depends on status tracking and is the most uncertain work. |
| Codex working path | Loom-owned app-server + remote TUI (path a), accepted in exchange for seeing session state directly. Its memory cost, with one server per live session (2 October 2026): an idle session measured 156 MiB in two processes, against 119 MiB for the plain TUI with `--no-daemon` and 395 MiB in three processes for Codex's default with its shared daemon and updater ([PERF-4](plans/cp5/PERF.md)). The CP1 sample's figure, about 110 MiB extra for one shared server, predates that decision. |
| New chat commands | After Claude `/clear` or Codex `/new`, the new chat becomes a separate record; the old chat is not lost. |
| Codex cache | The detached thread staying in memory for up to 30 minutes, as described in the conversation, was accepted. With one server per live session (2 October 2026), the server stops with its session, so nothing stays cached for a stopped session (§4.4). This is not permission to leave running work. |
| Stale content preview | Not a requirement of the first release if it is difficult or costly to build. |
| Monthly cleanup target | Eligible `stale` sessions, not `idle`. |
| Usage time | The user viewing a chat refreshes its usage time. |
| Stale viewing | Viewing a stale session does not change its state; the session stays stale. Leaving stale happens only through explicit reactivation. |
| Deletion waiting period | For automatic deletion, the session must have been stale for at least 15 days. (19 Oct 2026: 15 days is the default wait of the cleanup review, which the user can change in Settings → Sessions; automatic deletion stays off, [D-69](DECISIONS.md).) |
| Cleanup exceptions | Pinned chats, worktree states that must be preserved, and chats that are the source or target of an unfinished authorized task are excluded from automatic cleanup. |
| Cleanup after a long break | If the app stayed closed for a long time, no surprise bulk deletion is done at launch; a list and confirmation are shown. |

“Communication under the user's management” does not mean that every message is pasted manually by the user. The user's assignment “hand this work over to the other session and follow its result” also conforms to this principle. For a workflow the user has authorized, the same permission does not need to be requested again at every step.

No decision was taken to ban all application-bound helper processes, to remove MCP from scope, or to limit task handoff to text pasting only.

## 4. Session lifecycle

### 4.1. Main states

| State | Meaning | Resource expectation |
| --- | --- | --- |
| `active` | A session that has had at least one prompt sent and is being worked on. It does not need to be selected on screen. | CLI, terminal and, if needed, provider working resources may exist. |
| `idle` | A session whose running was terminated because it was not used; it can be continued from the same chat with a new prompt. | No live CLI/TUI, terminal buffer or jobs belonging to the session are left. The shared provider cache exception is below. |
| `stale` | A session not used for a long time, to be reactivated by an explicit user action. | There is no live work. Listing or previewing does not start running. |
| `deleted` | A session whose defined deletion scope has been completed and verified. | No runnable chat, pending work or in-scope data remains. |

A terminal to which no prompt has yet been sent is not forced into the `active` definition. In such an initial state too, all opened processes are subject to Loom's ownership and quit rules; the final UI label may be determined during implementation.

`deleted` is not a kind of archive that holds chat content. After a successful deletion, the catalog record carrying content is removed. While deletion is in progress or has failed, the operation record needed for recovery may be kept.

### 4.2. Information separate from the lifecycle

“Working”, “awaiting approval”, “awaiting input”, “errored” and “finished its work” are the agent's momentary states. They must not be modeled as the same field as `active/idle/stale`.

Whether the process is starting/running/stopping/stopped, and whether the session is selected on screen, are also separate pieces of information. An old error or success event must not change the state of a new run.

### 4.3. Transition to idle

The initial target is a transition to idle after about **one hour of non-use**. **User decision, 8 Oct 2026 ([D-38](DECISIONS.md)):** the app does not make this transition automatically; a running session stays running until the user stops it or quits. The transition contract below still describes how such a stop must behave. The time since the last prompt alone is not sufficient: there may be a long-running job, a pending approval, a running subagent or a background command.

Proposed transition contract:

1. Ongoing work and states that block closing are checked.
2. The chat's identity and the records needed for it to be continued are verified.
3. Accepting new work and the closing operation are coordinated; a prompt arriving during closing is not lost and does not start a second process.
4. Running is terminated cleanly; if needed, the defined stop path is applied.
5. It is verified that the session's jobs and terminal resources have been released.
6. Only then is `idle` shown.

If a background job blocks a safe automatic transition, the session is not shown as if it were closed. The user must be able to understand the reason. **Automatic idling and the user's explicit close/quit request are not the same operation policy:** on full quit, ongoing jobs may be stopped.

Continuing with a new prompt may require a new OS process. The chat identity, the working directory and the session-specific settings needed to continue must be preserved; if continuing fails, a new chat must not be created silently.

### 4.4. Codex cache exception

Under certain conditions, Codex app-server does not unload a thread immediately after the last subscription is removed; the research had documented a 30-minute wait. This behavior was accepted. [Codex App Server](https://learn.chatgpt.com/docs/app-server)

Therefore the claim “absolute zero memory” is not used for idle. The closed session's active work and terminal must end; temporary memory held by the shared provider must be measured separately. In CP2 it was verified that the Loom-owned shared server started with the first Codex session, shut down when the last Codex session was released, and did not affect other live sessions. By the 2 October 2026 decision, each live Codex session runs its own server (§3). When the session stops, its server shuts down too; no server cache remains for a stopped session. The server is not written to the catalog as a user chat, but it is subject to the same process ownership and Quit contract.

## 5. Stale and retention policy

The initial target is to classify sessions **unused for about 15 days** as stale. User prompts and the user's deliberate viewing of a chat count toward usage. List refreshes, background scans, or the agent merely producing events do not count as user viewing.

Running a stale session requires explicit reactivation. Viewing a stale session does not take it out of the stale state, does not start the CLI, and does not make the session active. For non-stale sessions, viewing refreshes the usage time and delays the transition to stale. A stale target is not woken silently by a message from another agent; the authorized workflow must make the reactivation requirement visible.

Accepted conditions of automatic cleanup:

- Monthly cleanup targets only eligible stale sessions.
- A session must stay stale for at least the deletion wait before it is deleted: 15 days by default, counted from the later of the stale start and the last view.
- The user's viewing or reuse is taken into account; an old deletion plan is not applied blindly.
- Pinned chats are not cleaned up automatically. Pinning does not mean keeping the live CLI open permanently.
- If there is a worktree state that must be preserved, the related chat is not cleaned up automatically. Unpushed commits and local changes that could be lost are examples of this protection to be checked during implementation.
- A chat that is the source or target of an unfinished authorized task is not cleaned up automatically.
- Bulk deletion after the app has been closed for a long time is not done without showing the user a list and getting confirmation.
- Cleanup also uses the same verification and error rules as manual deletion.

**Policy details in force** (DP-CP4-2's defaults, [D-69](DECISIONS.md)): a review is due 30 days after the last one, not by calendar month; viewing a stale session restarts its wait; 45 days closed counts as a long absence, and more than 10 eligible sessions force a review. The user can change the review interval and the deletion wait in Settings → Sessions, which is in every build and deletes only what the user confirms. Automatic deletion stays off; before it is ever enabled, these rules must be settled as a single calculation ([O-09](DECISIONS.md#open)). The condition “15 days of non-use + at least 15 days stale” does not mean that every chat will be deleted on exactly the 30th day.

A continuously running Loom service for cleanup while the app is closed is not targeted. Infrequent checks at launch and while the app is open are the candidate implementation. A separate timer per record is not needed.

The provider's own retention policy may remove history before Loom does. Such a record must not be shown as runnable; the “provider history not found” state must be explicit. How the retention period of provider files will be aligned with the Loom policy is part of the deletion/retention experiment. [Claude data retention](https://code.claude.com/docs/en/claude-directory)

## 6. Process ownership and quitting the app

The acceptance criterion of a normal Quit: **no running work started and owned by Loom remains; user sessions outside Loom are not touched.** This scope includes the CLI, subagents, background shells, dev servers, session-owned helpers such as MCP/LSP, and the Loom-owned provider server if there is one.

The shutdown sequence must cover blocking new work, stopping owned work, verifying termination, and finishing persistent operations consistently. If shutdown cannot be verified, the app must not present it as success.

Claude Agent View may be disabled only in sessions started by Loom. This option is documented; the global settings of other terminal sessions are not changed. [Claude environment options](https://code.claude.com/docs/en/env-vars)

For Codex, two paths were compared by experiment:

1. A Loom-owned app-server and the real Codex TUI connecting to it.
2. The direct Codex TUI with shared daemon use turned off.

The [Checkpoint 1 experiments](plans/CHECKPOINT-1.md) dated 27 September 2026 verified that codex-cli 0.157.1 starts isolated daemon components on its own in the plain TUI path. The `--no-daemon` and the Loom-owned app-server + remote TUI paths shut down cleanly under the tested active turn/background job conditions. By user decision, the Loom-owned app-server + remote TUI path was chosen (§3) and implemented in the product core in CP2. The experiment of opening an empty `thread/start` result with TUI `resume` before the first turn failed; the identity created by the TUI is taken from the `thread/started` event. Because the event has no PTY/run discriminator, in CP2 new TUI starts on the shared server were queued; with one server per session, each server sees only its own TUI. When a remote TUI started by another client does not publish every turn/item detail, the latest state and response are hydrated with `thread/read`, and background jobs with `thread/backgroundTerminals/list`; state and approval events are watched directly.

A shared Codex server of other applications or of the user's terminal is not considered Loom-owned. For daemon behavior that cannot be prevented or whose ownership is unclear, the “we will kill it at quit anyway” approach is not applied.

Process groups, PID + start time and environment markers are candidates for examination. **These alone do not prove that all processes will be found and shut down.** In the pre-check, the environment marker could be read with `KERN_PROCARGS2` in a non-Apple binary belonging to the same user; it was not visible in Apple platform binaries such as `/bin/sleep`. Therefore marker scanning alone is not sufficient. The death of the parent process does not directly terminate its children; closing the terminal is not a guarantee for all grandchildren either. [POSIX process termination](https://pubs.opengroup.org/onlinepubs/9799919799/functions/_exit.html)

Checkpoint 1 also reproduced the limit that blocks a general ownership guarantee: a `/bin/sleep` that escapes the session before the first snapshot cannot be found when the environment marker cannot be read and it has not entered the ledger. The real provider and combined experiments finishing without leftovers does not close this A5 gap; the checkpoint was not given full acceptance. The run scope below (2 October 2026) replaced marker scanning as the ownership boundary: a process that escapes the session's process group still belongs to the run helper's coalition (§3, “Process ownership guarantee”).

**Run scope (2 October 2026).** The application coalition is not a clean boundary: Apple XPC service instances join every application's coalition later. Loom cannot create a coalition or put its child into another coalition; these operations are privileged in XNU. The AppKit-less run helper opened via LaunchServices, on the other hand, gets a new, single-member coalition at each launch. Coalition membership is inherited on fork and cannot be changed by an unprivileged process. Therefore `setsid`, double fork and reparenting to launchd do not take a process out of the scope.

- **Forked work and launchd members:** The `p_orig_ppidversion` field in the process table preserves the parent at fork time even after exec and reparenting. With this field, forked work is distinguished from members started by launchd (the helper itself, Apple XPC instances opened on demand).
- **Stopping:** Stop/Quit freezes the forked members, re-verifies their identities and stops them. No signal is sent to launchd members. Success requires the scope to be fully emptied.
- **Out of scope (by construction):** Work handed off to LaunchServices or launchd (`open -a`, `launchctl`, `brew services`, Docker daemon jobs); a terminal has the same limit. Processes that have switched to another UID are reported as a failure if they cannot be stopped.
- **Permissions:** Because the run helper is a separate application, managed CLIs' access to protected folders (e.g. Documents) is attributed to the helper on macOS. A stable signature is needed for persistent permission.

Evidence: [run scope research](plans/experiments/cp5-own-run-scope-research.json) and [OWN plan](plans/cp5/OWN.md). The old single-sample application coalition attempt is a historical record in the [CP1 plan](plans/CHECKPOINT-1.md) §12.

Normal Quit, an app crash and Force Quit are separate test scenarios. Cleaning up leftovers at the next launch can be a recovery path; it does not count as a zero-resource guarantee for the time the app stayed closed. Until post-crash behavior is proven, the result of the normal quit test is not generalized to this scenario.

The window close button and Cmd+W only close the window; the app and jobs keep running. Full quit is done with Cmd+Q (§3).

## 7. Cross-session coordination under the user's management

The goal is for Claude and Codex sessions to be able to find each other, pass on tasks and follow the result for work authorized by the user. This goal is not reduced to a copy/paste feature alone. The user confirmed on 12 Oct 2026 that this will be built ([D-43](DECISIONS.md)).

Authorization and task execution are considered separately:

- The user may authorize a single message to a target, or a task flow with a defined scope.
- Without authorization, sessions must not start new work on their own.
- A chain that goes beyond the limits of the task the user gave is not considered automatically authorized.
- An agent message is not an answer, on the user's behalf, to another session's pending tool/operation approval.

Recording the message, forwarding it to the provider, its acceptance by the target and the completion of the task are different stages. A transport response or an agent saying “done” is not by itself proof that operations under Loom's control were actually performed. The source of a result notification must be clear.

On ambiguous delivery, no blind automatic retry must be done; a crash or a reconnection must not run the same work twice. If a queue is used, persistence, cancellation, time/size limits and the behavior of late messages to a deleted target must be defined. Tasks already recorded may be kept while the app is closed; it is not assumed that a closed app will pick up newly arriving work on its own.

### Technical candidates and limits

- **Shared MCP interface:** Both CLIs support it. A candidate for session discovery, task assignment and reading results; it does not by itself solve the delivery of an incoming message to the target.
- **Codex app-server:** A candidate for event and turn control. Concurrent control with the real TUI, which client approvals go to, and resource ownership must be tested. `turn/start` and `turn/steer` are documented; `thread/queue/*`, however, is not on the official app-server page and is seen only in the schema generated from the installed version and in the `codex queue` command. If task handoff relies on the queue, it must be treated as an undocumented interface.
- **Claude cross-session messaging:** A real local communication facility. It must not be made a core dependency until its documented contract for an external Loom integration and its compatibility with user authorization are verified.
- **Claude Channels/hooks:** Alternative integration paths. Preview status, distribution, delivery confirmation and extra process costs are evaluated. Hooks run during a turn or at the end of a turn; for a live session waiting idle at the prompt, the documented candidate is the `asyncRewake` hook, and it requires one waiting process per session. If the process is not running, the chat can be opened with a prompt through the CLI's resume path.
- **Text transfer:** Can be a separate convenience for the user to carry text to the target terminal. Bracketed paste does not prove that the target is in the right prompt field or that it accepted the task.

Claude's cross-session messaging feature is on by default, and Claude may send messages to other local sessions without asking the user when it sees fit. This default conflicts with the authorization rule above; Loom-managed Claude sessions must not be started without this behavior being addressed. The candidate minimum measure is to set `crossSessionInbound: refuse` with a session-specific setting. This setting only blocks incoming messages: a message going from a Loom session to a session outside Loom is a gap that remains open, and it is not equivalent to managing all outgoing communication. Banning the `SendMessage` tool must not be used as the solution, because it also turns off subagent and team messaging; the authorization behavior must be designed separately while preserving subagent functions. [Claude cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging)

Task handoff does not mean translating the whole chat history or the harness's internal state to the other provider. If the necessary task context and the result are sufficient, a second copy of the transcripts must not be kept.

## 8. Permanent deletion contract

Deletion is not hiding a session or putting it into idle. The user's “delete completely” expectation is a product goal; the guarantee to be given technically is offered after the controllable local data scope has been clearly defined and verified.

The deletion operation must cover:

1. Stopping new message, run and restart inputs.
2. Canceling pending jobs and related deliveries bound to the session.
3. Terminating owned live work and verifying it.
4. Cleaning Loom's catalog, cache and session-owned data.
5. Cleaning, within the defined scope, the provider's local data for this chat that can be safely claimed.
6. Verifying that records do not come back through the listing, reopening and resume paths.
7. Showing success only once the scope is complete.

A partial deletion must be visible and retryable. Removing the catalog record early and leaving the remaining provider data ownerless is not acceptable. A recovery record may be kept while deletion is in progress; whether a permanent deleted-ID list is needed after completion will be determined together with late event and message behavior. An ever-growing record is not the default solution.

Claude `rm` is not a single-chat deletion command that removes the transcript; `project purge`, on the other hand, has a broader project scope. Codex `thread/delete` and `codex delete` are usable candidates; the scope of auxiliary data must be checked separately. [Claude sessions](https://code.claude.com/docs/en/sessions), [Codex App Server](https://learn.chatgpt.com/docs/app-server)

**No data loss is created in shared data.** Rewriting a `history.jsonl` file written by other CLI sessions with a size check and atomic replacement is not enough to preserve concurrent appends. This method is not applied until a supported API, shared write coordination or appropriate data ownership is resolved. Until then, the deletion statement presented to the user does not cover the shared prompt history. `CLAUDE_CODE_SKIP_PROMPT_HISTORY` is not a solution, because it also turns off transcript writing and breaks resume. [Claude environment options](https://code.claude.com/docs/en/env-vars)

Explicit limits of the deletion scope:

- Content sent to another session and shared memory are not deleted on the assumption that they are single-chat data.
- Code in the project, user files and worktrees are not an automatic side effect of chat deletion.
- No claim is made that remote provider copies, exports and backups are gone.
- SQLite row deletion, the file shrinking, and cleaning the physical traces of deleted content are different topics. WAL and journal behavior are also part of the data policy.

The exact local data inventory and the deletion statement to be presented to the user are not considered complete until the deletion checkpoint has passed.

## 9. Architecture direction and update strategy

**Direction:** A modular coordinator inside Loom; separate responsibilities for process ownership, catalog, lifecycle, provider adapters and terminal presentation. Swift is the core language (§3). The catalog is a small SQLite database and the UI is SwiftUI and AppKit; both are in use ([ARCHITECTURE](docs/ARCHITECTURE.md)).

Passing every terminal character through a message queue or JSON layer is not mandatory. A continuously running separate Loom daemon was not accepted as an initial need. If an application-bound helper is proven necessary, it is evaluated with its own resource and shutdown cost.

In provider integrations:

- Documented interfaces are preferred; private file and socket formats are not assumed to be unchanging.
- When the CLI path/version changes, the related capability checks are refreshed. An expensive full scan at every launch is not targeted.
- A schema check verifies the existence of the interface; a behavior experiment verifies the related guarantee. One does not replace the other.
- No “work finished”, “approved” or “closed” result is inferred from an unknown event.
- If an optional view feature breaks, that feature may be turned off. If the core ownership/shutdown guarantee breaks, the managed session is not started as if it were normal.
- The user's global CLI settings are not taken over; the Loom integration must be session-specific and removable.
- The real chat identity, the Loom catalog identity and the current run identity are kept separate. Concurrent claiming of the same chat and events coming from an old run are handled.

Session-specific integrations implemented in CP2:

- **Claude:** The new chat identity is given with `--session-id`, and the resume identity only with `--resume`. `--settings` carries only this session's hooks and settings. Because `SessionStart` does not support HTTP hooks, the small `loom-hook` command helper and an authenticated owner-only Unix socket are used as the single transport line. `Stop` provides the presence of the final response, `PermissionRequest`/`Notification` the waiting state, and `SessionStart(clear/fork/resume)` the identity transition. Nothing is written to the user's global settings.
- **Codex:** The typed async app-server client combines the sources `thread/status/changed`, approval/input server requests, `thread/read` and `thread/backgroundTerminals/*`. Old run events are rejected by a sequence/run barrier; `/new` makes no catalog change on an ambiguous match. For deletion, `thread/delete` or `codex delete` is still the subject of the deletion checkpoint.

### Technical lessons carried over from Herdr Desktop

- **Environment inheritance is a real source of bugs:** If Loom is opened from inside a Claude session, parent session variables such as `CLAUDE_CODE_*` (including the session identity, the messaging socket and its token) can leak into the started CLIs. Loom's own session boundary must be set up explicitly; the environment of managed processes must be built deliberately. A narrow allowlist prevents this leak but also drops the environment the CLIs need, such as the SSH agent, proxy, the user's `.zshrc` settings and their own variables. The accepted approach (§3): the environment is taken from the user's shell opened with a cleaned initial environment; this way the terminal's environment is preserved and parent session variables are not carried over.
- **Start and shutdown are a single operation chain:** If a start fails, no ghost live record must remain; quit, deletion and background record writing must not race. Reparenting of the process tree and the opening of a new Unix session must be tested.
- **Hook count is an architectural choice:** Hooks that start a process and write a file per event are an extra cost. Codex may subject each hook registration to a separate trust approval; collecting the registrations in a single file does not merge the approvals. Inferring state from the terminal screen, on the other hand, can break when the CLI interface changes. If a hybrid method is chosen, which state comes from which source, and the conflict rule, must be explicit.
- **Permission UX is part of the product:** Granting trust automatically, bypassing the provider's trust or permission check, or producing multiple approvals not explained to the user is not acceptable.
- **Development and daily use must be separate:** The development build must use a separate bundle identifier and data directory; experiments must not touch real sessions and the catalog. A stable local signature prevents macOS permissions from being requested again at every install. A passing build alone does not count as proof of completion.

## 10. Resource and performance acceptance

Low resource consumption is not only the size of the app package or of the Loom main process. Loom, provider processes, child jobs and the UI/WindowServer impact must be measured separately.

Conditions to measure: empty app, one and multiple running sessions, a large number of idle/stale records, heavy terminal output, fast session switches, visible/hidden window and long-term use. The proposed initial scales are 1, 10 and 50 sessions.

Measurement units must be verified: macOS `proc_pid_rusage` CPU values require Mach tick conversion; 100% CPU is one logical core. The return value of `proc_listchildpids` is a PID count. RSS and physical footprint differ; summing child process memory may double-count shared pages. The cost of the measurement tool itself is recorded separately.

Behaviors to check:

- Invisible terminals must not do unnecessary drawing; output processing and buffer use for live jobs must be bounded.
- The working animation must not refresh the whole UI tree every frame; in a hidden or inactive window, animation and drawing must stop.
- No live terminal must be created for idle/stale records.
- Transcripts, scrollback, logs and queues must not grow without bound.
- The whole history must not be read on every refresh; the view must load only as much data as needed.
- The cost of logging and maintenance operations must also be measured. If SQLite incremental vacuum is chosen, when it runs must also be defined.

The root cause of the old Herdr GPU problem has not been proven. With the same terminal load, a **glass/opaque background × idle/output** experiment must be done under visible and occluded window conditions. If needed, the animation impact is measured in a separate experiment. No GPU conclusion is drawn from CPU observations. [Apple rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)

3 October 2026 user decision: the heavy terminal CPU upper limit is 40%. In the current CP5 synthetic measurement, 100% is one logical core; at a 1 MiB/s load, the average app + fixture + run-scope/host total of each 60 s run is evaluated against this ceiling. The provider/fixture cost and Loom's own overhead are shown separately; meeting this ceiling does not by itself prove that Loom's overhead is minimal. The user asked for Loom's resource load to be minimal and, where possible, for the provider cost to be reduced as well, while preserving the real CLI experience and the ownership guarantee. The cost of native provider processes added by Loom, such as Codex app-server, is also shown separately as integration overhead; the binary merely belonging to the provider does not remove this cost from Loom's evaluation.

Other [numerical proposals](plans/cp5/RESOURCE-BUDGET-PROPOSAL.md) for memory, GPU and latency have not yet been approved. Without an accepted scope and measurement, “lightness verified” is not claimed.

## 11. Development checkpoints

Each checkpoint result is recorded as **verified / failed / not verified**. Synthetic data and Loom-owned test processes are used. User data, the processes of other applications and real chat history are not experiment material.

| Checkpoint | Evidence required for it to be considered finished |
| --- | --- |
| 1 — Ownership and start | Claude Agent View disabled path and comparison of the two Codex paths; correct process/chat ownership; external sessions not affected; no leftovers after a normal Quit. The crash/Force Quit result is reported separately. |
| 2 — Status and resume | The source of identity, turn, error and approval states is clear; safe idle transition and resume from the same chat work; provider cache and live work are kept apart. |
| 3 — Authorized coordination | Two-way delivery and result tracking within the scope of a task the user gave; correct behavior while the target is working, waiting and reconnecting; ambiguous delivery and double execution are handled. Decisive case: delivery to a live Claude TUI waiting idle at the prompt using only documented interfaces. It is also shown that unauthorized cross-session messages are blocked. |
| 4 — Deletion and retention | Local data scope completed; deletion without harming another session's data; recovery from a partial operation; no return via late events; stale/exception/calendar rules correct in sample timelines. |
| 5 — Visual experience and performance | Design/icon target preserved; resource and latency measurements within the accepted budgets; history growth and hidden window behavior verified. The GPU experiment can be run independently of the other checkpoints. |

**28 September 2026 status:** Checkpoint 2 completed. Identity/turn/approval sources, safe idle/stale transitions, resume from the same Claude/Codex chat, no fallback on missing history, and reopening after a Quit during an active turn were verified by the [CP2 result matrix](plans/CHECKPOINT-2.md#19-kabul-matrisi-sonucu). The first window is a consumer of this core contract; lifecycle or provider identity must not be remodeled into UI state.

**CP5 (6 Oct 2026):** terminal engine (vendored SwiftTerm + Loom patches, Core Graphics renderer) and first window implemented; package I verified (CPU40 gate passed, real Claude check 11/11); closed by user decision; budgets beyond CPU40 move to release readiness and Codex-only items to the [Codex backlog](plans/cp5/CODEX-BACKLOG.md).

The numbers are checkpoint identifiers. Implementation order by user decision (§3): 1 → 2 → the terminal engine and first window part of 5 → 4 → 3. The GPU experiment is done together with the window.

First window plan: [Checkpoint 5](plans/CHECKPOINT-5.md). This slice does not mean that all v1 features or all performance acceptance are complete.

Checkpoints are for testing high-risk claims with narrow experiments without building the whole application. Moving to the next step does not mean hiding the unknowns of the previous checkpoint.

## 12. Remaining decisions

The product purpose and core behaviors are largely clear. It is not necessary to choose all technical details before implementation; but the following outcomes must not be left open:

1. **Quit boundary:** Apart from normal Quit, what guarantee can really be given for crash/Force Quit? Window close behavior has been decided (§3), and so has the run helper's part when Loom crashes (§3, “Loom crash”). The rest is [O-09](DECISIONS.md#open), settled at 1.5.0's evaluation ([D-69](DECISIONS.md)).
2. **Communication path:** Which Claude delivery mechanism meets the ownership and update requirements together? (The Codex working path has been decided, §3.)
3. **Data contract:** The exact local scope of safe single-chat deletion, the management of shared files, and alignment with provider retention.
4. **Cleanup calculation:** The monthly calendar, the effect of stale viewing on the counter, and the long-closed threshold.
5. **Measurable budgets:** Accepted resource, scale and interaction limits. The heavy terminal CPU ceiling of 40 % is accepted (§10); the rest is [O-01](DECISIONS.md#open), decided at 1.5.0's evaluation ([D-69](DECISIONS.md)).

These items are not gaps awaiting new product ideas; they are the decision and evidence gates needed to actually deliver the accepted experience.

## 13. Ideas without a scope decision

Ideas the user has expressed before. They do not automatically enter the first release or the implementation order:

- A side chat and right panel opened from the main context, whose exchange is not added to the main chat. (17 Oct 2026: in v2's scope as the inspector and its Side tab, [D-57](DECISIONS.md).)
- More comprehensive tracking of subtasks in the right panel. (17 Oct 2026: in v2's scope as the inspector's Tasks and Agents tabs, [D-57](DECISIONS.md).)
- Showing ChatGPT/Claude usage allowance and remaining limits. (7 Oct 2026: moved into scope as a lightweight usage and cost view, [D-32](DECISIONS.md).)
- Chats within a project keeping a fixed order by creation time, newest first; plus a separate view sorted by latest activity. (12 Oct 2026: moved into scope, [D-39](DECISIONS.md); the activity view sorts by latest activity.)
- Importing pre-existing provider history, and full transcript search.
- Harnesses other than Claude and Codex (OpenCode, Antigravity, etc.).
