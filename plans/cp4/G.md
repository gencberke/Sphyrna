# CP4-G — pin, worktree protection and the review flow

[Checkpoint 4](../CHECKPOINT-4.md) · wave 4 · protocol: [RUN-1](../RUN-1.md#protocol-for-every-implementer-slice). Depends on CP4-C, CP4-D, CP4-F, U1 (Settings page). May be cut if it stalls (D-26).

## Goal

The user can pin conversations (retention exception), and can review stale conversations that are eligible for cleanup and delete the confirmed ones through the normal deletion path. Nothing is deleted automatically.

## Design

- **Pin** (DP-CP4-5 default): card context menu "Pin" / "Unpin" (writes `sessions.pinned`); a pinned card shows a small pin glyph in its second row (secondary color, SF Symbol `pin.fill` 10 pt) — a new, minimal card element; list it in UI-MAP. (Pinned conversations ≠ pinned tabs; say so in the menu help text.)
- **Worktree protection** (DP-CP4-3 default): only for conversations whose working directory is a linked worktree (`.git` is a file, as `GitBranch` detects) — read-only `git --no-optional-locks status --porcelain=v2 --branch`, `git rev-list --count --branches --not --remotes`, `git stash list` through `ProcessSupervisor.captureHelper` (owned, timed out); any change, unpushed commit, stash, timeout or error → protected (fail closed).
- **Review flow**: Settings gets a "Conversations" section (or a menu item "Review Stale Conversations…" until U1 lands) that runs the planner at open and again at confirm, lists eligible conversations (title, project, stale since, size from the CP4-A dry run) with checkboxes and the excluded ones with reasons, and a "Delete N Conversations" button that runs manual deletions one by one, showing per-row results. `last_cleanup_at` is recorded when the user confirms or dismisses a due review.
- Launch: record `last_launch_at`; when the planner says `due`, show a quiet info line in Settings → Conversations (no modal, no automatic deletion).

## Scope

Write: new `Sources/LoomCore/CleanupCoordinator.swift` (gathers candidates from the catalog, protection verdicts, calls the planner), new `Sources/LoomCatalogUI/CatalogModel+Cleanup.swift`, new `Sources/LoomCatalogUI/CleanupReviewView.swift`, the Settings section hook (one line in `SettingsView.swift`), card menu items and pin glyph in `SidebarView.swift`, tests, `design/UI-MAP.md`. Out of scope: automatic trigger, CP3 task links.

## Done when

Tests: pin persists and excludes; worktree verdicts on temp git repos (clean linked worktree → not protected; dirty/unpushed/stash → protected; git error → protected); review flow re-plans at confirm; only confirmed rows are deleted; per-row failure shown. Evidence screenshots of the review section with a seeded catalog (stale rows with `stale_since` in the past).

## Checks

`swift build`; LoomCoreTests and LoomCatalogUITests filters for the new suites; evidence run; `git diff --check`.
