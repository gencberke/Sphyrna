# Status (Live Relay Board)

- **Updated:** 2026-10-30, 21:30 +03.
- **State:** `paused (archived)`. Sphyrna 1.8.0 is released locally and installed at `/Applications/Loom.app` (build 10800,
  loom tree `fbe98bb`, tag `release/1.8.0` on `9fb92ae4`). `@user` archived the project for a while; the worktrees, caches,
  evidence, dev packages and backups were removed. Nothing is running.
- **Resume:** [COLD-START.md](COLD-START.md) has where everything is, how to get a working tree back, the state at the archive
  and the open follow-ups.
- **Worktrees:** none. Recreate `v2`'s with COLD-START §3.
- **File locks:** none.

## Next actions by role

- **@planner:** read COLD-START.md, recreate the `v2` worktree, re-run `SidebarStatusTests` (unverified since D-125), then plan
  from COLD-START §5 with `@user`.
- **@implementer-core / @implementer-ink / @optimizer:** nothing queued.
- **@user:** whether to push the loom tree and publish 1.6.0–1.8.0; the rename to `Sphyrna.app`
  (D-123).
