# CP4-C — deletion orchestration, recovery and fencing

[Checkpoint 4](../CHECKPOINT-4.md) · wave 3 · protocol: [RUN-1](../RUN-1.md#protocol-for-every-implementer-slice). Depends on CP4-A, CP4-B, F4.

## Goal

`SessionRuntime` can delete one conversation end to end per contract §8, recover interrupted deletions at launch, and guarantee late events cannot bring it back.

## State machine (each step idempotent, persisted before it runs)

1. **requested** — refuse if the conversation is starting/resuming (`startingSessions`), not Claude (Codex/synthetic disabled, D-28), or a provider id is shared with another row; resolve the Claude config dir (`ClaudeProfileLayout`, same rule as launch) and build the CP4-A plan; `beginDeletion`. From here every start/resume/reactivate/markViewed/input for the id is refused (contract §8.1).
2. **stopping** — if a run is owned by the card, `stopConversation`; require `report.succeeded`; failed stop keeps state and surfaces the error (§8.2–8.3). A run that moved to another card (`/clear`) needs no stop.
3. **provider_data** — execute the CP4-A plan; all items gone or absent → next; partial → stay, report.
4. **catalog** — `deleteSessionRows` (+ checkpoint).
5. **verifying** — catalog has no rows for S; supervisor and hub have no entry (`ProcessSupervisor.discardSession`, `ClaudeSessionAdapter.forget`, `SessionEventHub.forget` after any final `.runEnded`); CP4-A `verify` finds no leftovers; registered forget hooks ran (tabs U3, usage U0, `CatalogModel` caches via the hub frame); then `finishDeletion` and publish the removal (§8.6–8.7).

## Fencing and late events

- `adoptConversation(.resume)` (`ProcessSupervisor.swift:~560-600`) must not create a row for a provider id that is in a pending `deletions` row or in the in-memory `deletedProviderIDs` set (supervisor lifetime); log-free refusal (`.staleRun`-like outcome).
- `ProcessSupervisor.launch(sessionID:)` and `lifecycle.resume` must not use a discarded in-memory session.
- Late hook envelopes for a stopped run already return `.staleRun` (`ProviderSessionAdapters.swift:~115`); keep it and test it.

## Recovery

At launch, after `PreviousRunRecovery`, `SessionRuntime` resumes every `deletions` row from its state (no run can exist then, so `stopping` resolves); failures stay visible (a `deletionFailures` list the UI can show) with manual retry only.

## Carried from CP4-A review

- Add a live-session refusal test where the session file's `procStart` matches the running process (today only the no-`procStart` case is tested).
- Share the `procStart` parser with `ClaudeRegistry.swift` instead of the second copy in `ClaudeDataInventory.swift`; reject boolean `pid` values as the registry reader does.
- Surface off-device entries in the plan (refusal or listed item) instead of skipping them silently.

## Scope

Write: new `Sources/LoomCore/ConversationDeletion.swift`; thin hooks in `SessionRuntime*.swift` (public `deleteConversation(id:)`, `retryDeletion(id:)`, `pendingDeletions`, recovery call in `start`), `ProcessSupervisor*.swift` (`discardSession`, `deletedProviderIDs`, adopt guard), `ProviderSessionAdapters.swift` (`forget`), `SessionEventHub.swift` (use existing `forget`), a `ConversationForgetting` registration point (protocol + list) for U0/U3 hooks; tests `Tests/LoomCoreTests/ConversationDeletionTests.swift` (fake provider and `loom-test-child`), `docs/ARCHITECTURE.md` §3 (new flow) and §5. Out of scope: UI (CP4-D), cleanup (CP4-G).

## Done when (tests must fail without the fix where they test a guard)

Happy path with a live fake run; unverified stop leaves row and files (fails if the row is removed early); failpoint at each state → new runtime instance recovers to completion; late Stop/SessionEnd/SessionStart(resume of the deleted id) envelopes after delete → no row, no supervisor or hub entry; resume/start of a pending id refused; shared provider id refused; two conversations in the same project: B untouched (files and rows).

## Checks

`swift build`; `--filter` ConversationDeletionTests, SessionRuntimeTests, ProcessSupervisorTests, ClaudeHookTests, SessionCatalog suites; `git diff --check`.
