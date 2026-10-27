# 1.8.0: rules every brief shares

`@user` hands this file over with each brief from [briefs/](briefs/). Where a brief and this file differ, the brief wins for
its own slice. Where either differs from `@user`'s chat, the chat wins.

## 1. Where you work

- **The code** is in the `v2` integration worktree `~/Library/Caches/loom-v2/wt/v2`, local only. Never edit `v2` itself.
  Never edit `~/Documents/github/loom-dev` (the docs mirror) or `~/Documents/github/loom` (the clean release tree).
- **Make your own worktree and branch** from `v2`'s head:
  ```bash
  git -C ~/Library/Caches/loom-v2/wt/v2 worktree add -b slice/r9-<id> ~/Library/Caches/loom-v2/wt/r9-<id> v2
  ```
  `<id>` is the brief's id in lower case (`b0`, `c1`, …). If the branch exists, the slice is being resumed: use the existing
  worktree and do not recreate it.
- **Build scratch:** `~/Library/Caches/loom-v2/build/r9-<id>`. **Evidence and logs:** `~/Library/Caches/loom-v2/evidence/r9/<id>/`.
- `v2`'s uncommitted `Package.resolved` is not yours; leave it.

## 2. Read first

1. `AGENTS.md` §6.2 and §7 (the implementer checklist and the safety rules), in your worktree.
2. `DEVELOPMENT.md` §2 (build and test), §4 (isolation) and §5 (evidence mode), before you build, launch the dev app or touch a
   real CLI.
3. The sections your brief names in `SPEC.md`, `docs/ARCHITECTURE.md` (§11 maps every surface to its files) and
   `design/DESIGN.md`. For any visual slice, also read [DESIGN-V4.md](DESIGN-V4.md) in the loom-dev mirror; once B0 lands, read
   the v4 sections of `design/DESIGN.md` in your worktree instead.
4. The files your brief lists. Read them before you change them.

## 3. Hard rules

- **Git:** never `git stash`, `checkout` (of another branch in a shared tree), `reset`, `clean`, or revert work you did not do.
  Commit on your slice branch only, in English, one or more commits per part. Never push, tag or touch `v2`.
- **Write set:** change only the files your brief's write set names. If the slice needs a change outside it, stop that part, and
  write it under **Needs** in your report.
- **Builds and tests** only through `scripts/check.sh --scratch <your scratch> …`, which holds the shared build slot. Never run
  `swift build` or `swift test` directly. No window tests, no `--full`, no `--release-tree` unless your brief says so: the
  planner runs those at the gate.
- **Theme:**
  - colours, fonts, sizes and radii only in `Sources/LoomCatalogUI/LoomTheme*.swift` (`check-theme-literals.sh`);
  - a tone-dependent surface token is a `static var`, never a `static let`;
  - user-facing text says "session", never "conversation" (`check-user-wording.sh`), and "Sphyrna", never "Loom".
- **Main thread:** never block the `@MainActor` with process waits, file walks, git calls, SQLite or transcript scans.
- **User data is never test material:**
  - the user's harness profiles (`~/.claude`, `~/.codex`, and the config folders of opencode, agy and pi);
  - the installed `/Applications/Loom.app` and its data (`~/Library/Application Support/Loom`, `~/.loom`);
  - the dev app at `~/Library/Application Support/Loom-Dev/app/` and the default dev catalog;
  - the Obsidian vault.

  Use the isolated profiles of DEVELOPMENT §4 and evidence mode's own `--data-root`.
- **Sphyrna never writes a harness's own configuration** (`~/.codex/hooks.json`, `config.toml`, a Claude `settings.json`, …).
  Everything Sphyrna adds to a session comes in on its command line or through files in Sphyrna's own folders (SPEC §3).
- **Contracts that never bend:**
  - Full access is never an agent's choice;
  - `crossSessionInbound: refuse` stays;
  - no model call the user did not cause;
  - the plugin skill's description stays ≤ 300 characters;
  - Chat stays frozen;
  - the bundle id `local.loom.desktop` and the data folder stay.
- **Real CLIs:**
  - only in a working folder under `/private/tmp/loom-real/` (so no ancestor `CLAUDE.md` or `AGENTS.md` is read), with an
    isolated profile;
  - short turns only, and record each turn you spend in your report;
  - never sign in for the user: if an isolated profile needs a login, stop and ask `@user` under **Needs**;
  - `codex`, `opencode`, `agy` and `pi` are used for real only once `@user` has authorized it (FEEDBACK-7 Q13).
- **Screens:** no `screencapture` (it raises a macOS privacy prompt). Screenshots come from evidence mode's `screenshot:<label>`.
  Window tests and measurements run only when `@user` says the Mac is idle.

## 4. Checks

- **During the work:** `scripts/check.sh --scratch ~/Library/Caches/loom-v2/build/r9-<id> --suite <each suite you touch>`.
  Read the log's `✔ Suite …` lines to see that every suite you meant actually ran (DEVELOPMENT §2).
- **Regression tests:** every bug fix and every new rule gets a test that fails without the change. Run it once before the change
  and keep that failing log.
- **Before the report:** run every test target off screen once:
  `scripts/check.sh --scratch ~/Library/Caches/loom-v2/build/r9-<id> --tests`. A failure you caused is yours to fix. A failure
  that was there before your branch is reported, not fixed.
- `check-theme-literals.sh` and `check-user-wording.sh` pass (`check.sh` runs both).

## 5. Docs

Change, in the same commit as the code, the doc lines your slice makes untrue: `SPEC.md`, `docs/ARCHITECTURE.md` (§11's table
for any new surface, file or evidence key), `design/DESIGN.md`, `DEVELOPMENT.md` and `scripts/README.md`. Do not edit
`STATUS.md`, `DECISIONS.md`, `plans/` or `AGENTS.md`: those are the planner's. List what they need under **Doc impact**.

## 6. The report

The last message of your session, in English, short, in this order:
- **Status:** done, partly done, or blocked, for each part of the brief.
- **Commits:** the SHAs on `slice/r9-<id>`, with one line each.
- **What changed:** by file and type, one line each.
- **Evidence:** labelled **verified** or **failed**:
  - the failing-first log;
  - the final passing logs (`~/Library/Caches/loom-check-logs/check-*.log`);
  - the screenshots or evidence files;
  - the real turns spent.
- **Unverified:** what your run could not prove (on-screen looks, VoiceOver, real-CLI behaviour, energy).
- **Deviations:** where you did something other than the brief said, and why.
- **Needs:** decisions for `@user`, changes outside your write set, or follow-ups.
- **Doc impact:** what the planner's docs need.

## 7. When you are stuck

- If something the brief does not settle changes what the user sees or a contract, do not guess. Write it under **Needs**,
  skip that part, and go on with the rest.
- If a check fails for a reason outside your slice, record the log and go on.
- Never weaken a test or a guard to make it pass. If a test pins behaviour your brief changes on purpose, update it and say so
  in the report.
