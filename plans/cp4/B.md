# CP4-B — catalog schema v3 and transactional delete

[Checkpoint 4](../CHECKPOINT-4.md) · wave 2 · protocol: [RUN-1](../RUN-1.md#protocol-for-every-implementer-slice). Depends on F4 (catalog split files).

## Goal

The catalog can record, perform and recover a conversation deletion and can answer the cleanup planner's questions.

## Context ([CP4 scan §1–§2, §6](../experiments/run1-planning-scans/CP4-deletion.md))

- Schema v2 (`SessionCatalog.schemaVersion = 2`): `sessions` (… `lifecycle` CHECK active/idle/stale, `pinned`, `project_id`, `title_is_custom`), `runs` (`initial_session_id REFERENCES sessions(id)`), `run_sessions` (PK `run_id, session_id`), `provider_identity_changes` (`session_id REFERENCES sessions(id)`), `projects`. `foreign_keys=ON`, WAL, `synchronous=NORMAL`, `quick_check` at open. No child-side indexes. `configure()` hard-codes `version == 1 → migrateToVersion2`; an older Loom refuses a newer schema.
- `classifyStale` (`SessionCatalog.swift:~261`) sets `stale` by `last_used_at < cutoff` for non-running rows; `markUsed` (`:~226`) writes `last_used_at`.

## Schema v3 (one transaction, migration chain v1 → v2 → v3, failpoint like `migrateToVersion2`)

- `deletions(session_id TEXT PRIMARY KEY, provider TEXT NOT NULL, provider_ids TEXT NOT NULL /* JSON array */, config_dir TEXT, working_directory TEXT, state TEXT NOT NULL CHECK (state IN ('requested','stopping','provider_data','catalog','verifying')), requested_at REAL NOT NULL, updated_at REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT)` — no FK, no title; errors keep a category and a file basename only.
- `sessions.stale_since REAL` (set by `classifyStale` to `last_used_at + staleAfter`, cleared on reactivation; NULL means unknown → planner derives it).
- `app_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)` (`last_cleanup_at`, `last_launch_at`).
- Child indexes: `run_sessions(session_id)`, `runs(initial_session_id)`, `provider_identity_changes(session_id)`.
- `PRAGMA secure_delete = ON` per connection (check the effective value from the app's own connection in a test).

## API

- `beginDeletion(sessionID:plan:) throws` (insert `deletions`; refuses if already present), `advanceDeletion(sessionID:to:error:)`, `pendingDeletions()`, `finishDeletion(sessionID:)`.
- `deleteSessionRows(sessionID:) throws` — one transaction: delete `provider_identity_changes` and `run_sessions` of S; for `runs` whose `initial_session_id = S`, repoint to the earliest remaining linked session, else delete the run; delete the `sessions` row; then `wal_checkpoint(TRUNCATE)`.
- Fences: `resume`/`markUsed`/`reactivate`/`classifyStale`/paged lists exclude or refuse ids present in `deletions` (`NOT EXISTS`).
- `providerIDs(of:)` (Loom id, `provider_conversation_id`, all `provider_identity_changes` ids), `isProviderIDShared(_:excluding:)`.
- `setPinned(_:for:)`, `stale_since` maintenance, `appState(get/set)`.

## Scope

Write: `Sources/LoomCore/SessionCatalog*.swift` and `CatalogDatabase.swift` (after F4), `Sources/loom-catalog-fixture/main.swift` (v3 seeding, a `deleting` and a `stale_since` option), tests `Tests/LoomCoreTests/SessionCatalogV3Tests.swift`, `docs/ARCHITECTURE.md` §5. Out of scope: runtime orchestration (CP4-C), filesystem deletion (CP4-A), UI.

## Done when

Migration v2 → v3 keeps every row and identity (fixture from v2); interrupted migration (failpoint) reopens cleanly; v3 refused by a v2 build (documented, DP-CP4-4); delete transaction handles the shared-run repoint (`/clear` run) and leaves other sessions intact; failpoints between deletion states persist and reopen; fences refuse pending ids; no title marker bytes in `catalog.sqlite3` or `-wal` after delete + checkpoint (trace test); `quick_check` passes after delete. Existing catalog suites green.

## Checks

`swift build`; `--filter` SessionCatalog (all catalog suites), CatalogScaleTests; `git diff --check`.
