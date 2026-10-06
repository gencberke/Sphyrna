# Checkpoint 4 — deletion and retention

Part of [multi-agent run 1](RUN-1.md). Contract: [§4.1](../LOOM-PRODUCT-CONTRACT.md#4-session-lifecycle) (`deleted`), [§5](../LOOM-PRODUCT-CONTRACT.md#5-stale-and-retention-policy), [§8](../LOOM-PRODUCT-CONTRACT.md#8-permanent-deletion-contract), [§11 row 4](../LOOM-PRODUCT-CONTRACT.md#11-development-checkpoints), [§12 items 3–4](../LOOM-PRODUCT-CONTRACT.md#12-remaining-decisions). Scope decision: [D-26](../DECISIONS.md) (permanent deletion of one conversation is the must-have; stale handling and cleanup may be cut if they stall). Facts: [CP4 scan](experiments/run1-planning-scans/CP4-deletion.md), [architecture scan §2.5–§2.6, §4.7](experiments/run1-planning-scans/arch-scale.md).

## Goal

The user can permanently delete one conversation: Loom stops it if needed, removes its Loom data and its claimable local Claude data, verifies, and only then shows it as gone; a half-done delete is visible, retryable and resumed after a crash; late events never bring it back; no other conversation is touched. Then stale handling and a manual, list-and-confirm cleanup on the same deletion path. Automatic deletion stays off until the user decides the cleanup rules.

## Current state (facts)

- No deletion path: the only `DELETE` is for projects (`SessionCatalog.swift:~583`); no pin setter (`pinned` column always 0), no `stale_since`, no operation-record table; schema v2.
- Resurrection risks are in memory and resume, not in UPDATE paths: `ProcessSupervisor.sessions` holds every catalog row from launch; `adoptConversation(.resume)` inserts a new row when the provider id is not in the catalog (`ProcessSupervisor.swift:~560-600`); hub state, adapter statuses and `CatalogModel` caches keep the id.
- Viewing counts as use: `CatalogModel.updateViewing` → `SessionLifecycleController.markViewed` → `catalog.markUsed` (writes `last_used_at`, lifecycle stays `stale`).
- Claude names per-session data by session id; shared files (`history.jsonl`, `paste-cache`, `plans`, `.claude.json`, project `memory/`) are never touched (contract §8). Claude's own sweep (`cleanupPeriodDays`, default 30) often removes provider data before Loom's eligibility; "already absent" counts as verified.

## Slices

| Slice | Delivers | Write area (summary) | Wave | Depends on | State |
| --- | --- | --- | --- | --- | --- |
| [CP4-A](cp4/A.md) | `ClaudeDataInventory` + safe deleter (pure filesystem; dry-run plan, allowlisted names, no symlink escape) | new `Sources/LoomCore/ClaudeDataInventory.swift`, tests | 1 | — | accepted `9300e2c` |
| [CP4-B](cp4/B.md) | Catalog schema v3: `deletions` operation table, `sessions.stale_since`, `app_state`, child indexes, transactional delete, `secure_delete`, WAL checkpoint, pin setter | `Sources/LoomCore/SessionCatalog*.swift`, `CatalogDatabase.swift`, `loom-catalog-fixture`, tests | 2 | F4 | accepted `3deaffe` |
| [CP4-C](cp4/C.md) | `ConversationDeletion` state machine in the runtime: fencing, stop-and-verify, provider data, catalog, verification, crash recovery, late-event suppression, forget hooks | new `Sources/LoomCore/ConversationDeletion.swift`, thin hooks in `SessionRuntime`, `ProcessSupervisor`, adapters, hub; tests | 3 | A, B, F4 | planned |
| [CP4-D](cp4/D.md) | Delete UI: context menu, confirm dialog with the dry-run summary, row state, failure banner and Retry, selection/tab/usage cleanup, evidence commands | `CatalogModel+Deletion.swift`, `SidebarView`/`DetailView` menu items, `ConversationController`, `AppDelegate` wiring, evidence file, tests | 4 | C, U3, I2 | planned |
| [CP4-E](cp4/E.md) | Real-Claude deletion check and the §11 row 4 acceptance matrix | `scripts/cp4-deletion-real.py`, evidence file | 5 | D | planned |
| [CP4-F](cp4/F.md) | Pure `CleanupPlanner` with sample timelines | new `Sources/LoomCore/CleanupPlanner.swift`, tests | 1 | — | accepted `4c730ce` |
| [CP4-G](cp4/G.md) | Pin action, worktree protection check, manual "Review stale conversations" list-and-confirm on the deletion path; automatic deletion off | new `CleanupCoordinator.swift`, Settings/menu entry, `CatalogModel+Cleanup.swift`, tests | 4 | C, D, F, U1 | planned |

## Decisions taken in planning (routine, technical)

- Operation record (`deletions` row) is written before any destructive step and holds no title or content; it is removed when verification passes. No permanent tombstone list: while a delete is incomplete its `provider_ids` fence `adoptConversation`; after completion an in-memory set (one app run) rejects a `.resume` of a deleted id, and after a restart the transcript is gone.
- Order: fence → stop and verify → provider data → catalog transaction → verify → remove the record. The catalog row is never removed before provider data succeeded (contract §8).
- Recovery: at launch, after `PreviousRunRecovery`, interrupted user-confirmed deletions resume from their persisted state; failures stay visible with Retry; no silent retry loops.
- `PRAGMA secure_delete = ON` and `wal_checkpoint(TRUNCATE)` after each deletion transaction; no incremental vacuum (not chosen, so contract §10 needs no schedule).
- Codex and synthetic rows: delete disabled with a clear reason (D-28).
- Deletion resolves the Claude config dir the same way as launch (`ClaudeProfileLayout`, U0) and stores the resolved path in the operation record; the confirm dialog shows it.

## Decision points (user)

DP-CP4-1 … DP-CP4-6 in [RUN-1](RUN-1.md#decision-points-for-the-user). The deletion data contract (DP-CP4-1) and cleanup arithmetic (DP-CP4-2) are the user's: the defaults are built in dev packages so they can be reviewed; nothing is promoted to the daily app before the user decides. Automatic deletion is not built as a trigger at all.

## Acceptance (checkpoint, contract §8 and §11 row 4)

- **CP4-A1** (§8.1–8.3) A delete fences new input, start, resume and reactivation for the conversation, stops its live run and requires a verified stop; an unverified stop leaves catalog row and provider data untouched.
- **CP4-A2** (§8.4–8.5) Loom data (catalog rows across tables, caches, tabs, usage link, preferences) and the allowlisted Claude files of every provider id of the conversation are removed; shared files and other conversations' files are byte-identical before and after (synthetic tree + real-Claude check).
- **CP4-A3** (§8.6) After deletion the conversation does not come back through listing, reopening, resume, `/resume <id>` in another live Claude, late hook events or a relaunch.
- **CP4-A4** (§8.7, partial) A failure at any step is visible and retryable; a crash at any step (failpoints) recovers to completion at the next launch; success is shown only after verification.
- **CP4-A5** No trace: no title marker bytes in `catalog.sqlite3` or `-wal` after deletion.
- **CP4-A6** (§5) `CleanupPlanner` produces the documented sample timelines; the review flow lists eligible conversations with reasons and exclusions (pinned, running, deleting, protected worktree, not yet eligible) and deletes only confirmed ones through the same path; nothing deletes automatically.
- **CP4-A7** Real-Claude check: a conversation with one short real turn (plus subagent and file edit if the turn budget allows) is deleted; `claude --resume <id>` in the isolated profile reports no conversation; a second conversation in the same project is untouched.

## Evaluation and closure

Stage-end recipe in [RUN-1](RUN-1.md#stage-end-evaluation-recipe) (steps 1–3, 5–8). Optimizer before closing. Closure record: `plans/cp4/CLOSURE.md`.

## Real-Claude turns

Planned 4 (CP4-E). Used: 0.

## Results

- **CP4-A** (`9300e2c`): inventory and deleter; 13 tests over temp trees incl. symlink, substring-name, forged-plan and live-session cases. Open minor follow-ups carried into [CP4-C](cp4/C.md): live-session test with a matching `procStart`, share the `procStart` parser with `ClaudeRegistry`, reject boolean pids, report off-device entries.
- **CP4-B** (`3deaffe`): schema v3 (`deletions`, `stale_since`, `app_state`, child indexes, `secure_delete`), `SessionCatalog+Deletions` (`beginDeletion`, `advanceDeletion`, `pendingDeletions`, `finishDeletion`, `deleteSessionRows` with shared-run repoint and `wal_checkpoint(TRUNCATE)`, `providerIDs(of:)`, `isProviderIDShared`, `setPinned`, `appState`), fences on lists, counts, stale classification, `markUsed` and run starts (`deletionPending`), undecodable rows skipped and counted (from F6). Trace test: no title bytes in the database or WAL after delete (mutations: no checkpoint or `secure_delete = OFF` fail it). `SessionLifecycleController` passes `staleAfter` so `stale_since` is set in production. Notes for CP4-C: `isProviderIDShared` also counts conversations that are themselves being deleted; `sessionCounts` still counts undecodable rows; the v2-refuses-v3 check is simulated with `user_version + 1`.
- **CP4-F** (`4c730ce`): planner with 13 timeline tests; missing `staleSince` falls back to last use + `staleAfter`.
