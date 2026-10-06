# CP4-A — Claude data inventory and safe deleter

[Checkpoint 4](../CHECKPOINT-4.md) · wave 1 · protocol: [RUN-1](../RUN-1.md#protocol-for-every-implementer-slice).

## Goal

A pure filesystem component that, for a set of Claude session ids and a Claude config dir, plans and performs the deletion of exactly those sessions' claimable local files — and nothing else — with a dry-run plan the confirm dialog can show.

## Default scope (DP-CP4-1 — the user's decision; this is the default built meanwhile)

Claimed, for each id (strict 36-char UUID, compared case-insensitively; Loom starts Claude with `--session-id <Loom UUID>` so files may be uppercase):
- `projects/*/<id>.jsonl` in every project folder (scan all `projects/*/` children: `/cd` moves transcripts; folder names are lossy encodings), and set-aside variants `<id>.orphaned-*.jsonl`, `<id>.jsonl.superseded-*`;
- `projects/*/<id>/` (subagents, tool-results);
- `file-history/<id>/`, `session-env/<id>/`, `debug/<id>*`, `tasks/<id>/` (only when named exactly by the id), `image-cache/<id>/`, `uploads/<id>/`, legacy `todos/<id>-agent-*.json`;
- optional tier 2 outside the config dir: `/private/tmp/claude-<uid>/*/<id>/` when present and owned by the user (report separately).

Never touched (listed as "not removed" in the plan): `history.jsonl`, `paste-cache/`, `plans/`, `shell-snapshots/`, `backups/`, `.claude.json`, `projects/*/memory/`, `sessions/`, `jobs/`, `daemon/`, any entry of another id.

## Safety rules

- Config dir: `realpath`, absolute, owned by the current uid, not group/world writable (same stance as `ClaudeRegistryReader`, `ClaudeRegistry.swift:~30-40`).
- A candidate must be a direct child of an allowlisted root with name == `<id>` or starting with `<id>.` or `<id>-` (case-insensitive); a name that merely contains the id elsewhere is not a candidate.
- fd-relative traversal (`openat`/`unlinkat`, `O_NOFOLLOW`); a symlink is removed as a link, never followed; stay on the config dir's device; refuse anything resolving outside the config dir.
- Refuse (no deletion) when `sessions/*.json` shows a live process holding one of the ids.
- Already-absent items count as done; a partial failure returns per-item results; the operation is idempotent (re-run after a crash finishes the rest).

## API

`ClaudeDataInventory.plan(sessionIDs:configDirectory:) throws -> DeletionPlan` (items with kind, relative path, byte size; residual list; tier-2 items) and `ClaudeDataDeleter.execute(plan) -> DeletionResult` (per-item outcome) and `verify(sessionIDs:configDirectory:) -> [leftover]`. `Sendable` value types, no UI, no catalog access.

## Scope

Write: new `Sources/LoomCore/ClaudeDataInventory.swift` (C helpers only if Foundation cannot express `unlinkat`/`O_NOFOLLOW` safely — prefer Darwin calls from Swift), tests `Tests/LoomCoreTests/ClaudeDataInventoryTests.swift`. Out of scope: catalog, runtime, UI. Never touch the real `~/.claude`: tests build trees under a temp dir.

## Done when (tests; each must fail against a naive implementation)

Tree with conversations A and B in one project dir plus every claimed kind for A and B, a mixed-case A file, a name containing A's id as a substring, `<A>.jsonl.superseded-1`, `<A>/subagents/x`, a symlink `<A>.jsonl` pointing outside the config dir, a symlinked `file-history/<A>` pointing at B's data, `history.jsonl`, `.claude.json`, `projects/p/memory/`: after deleting A, every B file and every shared file is byte-identical (hash before/after), the symlink targets are intact, A's items are gone, the plan lists sizes and residuals. Plus: non-UUID id refused; live-session refusal; idempotent re-run; permission failure on one item → partial result, others done.

## Checks

`swift build`; `swift test --filter ClaudeDataInventoryTests`; `git diff --check`.
