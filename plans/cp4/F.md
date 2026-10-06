# CP4-F — cleanup planner (pure)

[Checkpoint 4](../CHECKPOINT-4.md) · wave 1 · protocol: [RUN-1](../RUN-1.md#protocol-for-every-implementer-slice).

## Goal

One pure, testable calculation of which stale conversations are eligible for cleanup and why the others are not, so the arithmetic the user decides (DP-CP4-2) is a parameter change, not a code change.

## Rules

- Decided (contract §3, §5): only `stale` (never `idle`) conversations; at least 15 days stale; exceptions: pinned, protected worktree state, source or target of an unfinished authorized task (input exists but is always empty until CP3), plus running and pending-deletion; after a long absence, review with a list and confirmation instead of a surprise bulk delete; an old plan is never applied blindly (re-plan at confirm time).
- Defaults for the undecided parts (DP-CP4-2): cadence = last completed run + 30 days (elapsed time, not calendar months); viewing a stale row extends the wait: `eligibleAt = max(staleSince ?? lastUsedAt + staleAfter, lastUsedAt) + 15 days`, with a policy flag for "viewing does not count" (`staleSince + 15 days`); long absence = 45 days since last launch → review required; more than 10 eligible → review required; automatic deletion is never allowed by the default policy (`automaticDeletionEnabled = false`), so the planner always returns `reviewRequired` or `notDue`.

## API

`CleanupPolicy` (all parameters, defaults above), `CleanupCandidate` (id, lifecycle, lastUsedAt, staleSince, pinned, isRunning, isDeleting, protection verdict, taskLink), `CleanupPlanner.plan(candidates:now:lastRunAt:lastLaunchAt:policy:) -> CleanupPlan` (`due: notDue(until:) | due`, `mode: automaticAllowed | reviewRequired(reason)`, `eligible: [(id, eligibleSince)]`, `excluded: [(id, reason: pinned | running | deleting | notStale | waitUntil(Date) | worktree(String) | task)]`). No I/O, no clock reads, `Sendable`.

## Scope

Write: new `Sources/LoomCore/CleanupPlanner.swift`, tests `Tests/LoomCoreTests/CleanupPlannerTests.swift`. Out of scope: catalog, UI.

## Done when (sample timelines as tests; days from last use)

Day 15 classified stale; day 29 excluded `waitUntil(day 30)`; day 30 eligible. A stale view on day 20 moves eligibility to day 35 (day 30 with the "views do not count" flag). Resume on day 22 → `notStale`. Pinned always excluded; running, deleting, worktree, task excluded with reasons. Last run day 0, opened day 10 → `notDue(until: day 30)`; opened day 31 → `due`. Last launch day 40, opened day 100 → `reviewRequired(longAbsence)`. 25 eligible → `reviewRequired(bulk)`. Default policy never returns `automaticAllowed`. A calendar-month variant is documented in a test comment only to show the irregular-gap case.

## Checks

`swift build`; `swift test --filter CleanupPlannerTests`; `git diff --check`.
