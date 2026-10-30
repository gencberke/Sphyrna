# Cold start

Sphyrna was archived on 30 Oct 2026, right after 1.8.0. Read this first when you pick it up again: it says where everything is,
what state it was left in, how to get a working tree back, and what is open. Then follow [AGENTS.md](AGENTS.md).

## 1. Where things are

| What | Where | State |
| --- | --- | --- |
| Source of truth | branch `v2` in `~/Documents/github/loom-dev` | Local only: `loom-dev` has no remote, so its `.git` is the only copy of `v2`'s history. 1.8.0 is the tag `release/1.8.0` (`9fb92ae4`); `v2` is that commit plus this archive cleanup. |
| `loom-dev`'s own checkout | `~/Documents/github/loom-dev`, branch `swarm/1` | An old branch whose working tree mirrors `v2`'s docs (uncommitted). Never check out `v2` there, never edit or build its `Sources/`; work in a worktree (§3). |
| Release tree | `~/Documents/github/loom`, branch `main` | `fbe98bb` = tag `v1.8.0`. Its `main` is 8 commits ahead of `origin/main` (public `main` is still 0.4.4): 1.6.0 to 1.8.0 were never pushed, and there is no GitHub release. Older promote commits sit on its local `history` branch. |
| Installed app | `/Applications/Loom.app` | Sphyrna 1.8.0, build 10800, `LoomRevision fbe98bb`, signed. Its data is `~/Library/Application Support/Loom` and `~/.loom`: the user's, never test material. |
| Signing | the login keychain's "Loom Dev Code Signing" identity (SHA-1 `223E8AC2…`) and `~/Library/Application Support/Loom-Dev/signing/` | Kept on purpose. Every build must sign with this identity, or macOS forgets the app's privacy grants (DEVELOPMENT §6). |
| Other branches | `main`, `slice/r9-d1`, `slice/r9-f1` | `main` is merged into `v2`. The two slices hold commits whose patches are not in `v2` (1 and 10); look before deleting them. |

## 2. What the archive cleanup removed

- **The disk side.** Every worktree under `~/Library/Caches/loom-v2/wt/`, the build scratches and check logs, the evidence folder
  `~/Library/Caches/loom-v2/evidence/`, the dev app `Loom Dev.app` with its dev catalog, the test packages and the backup zips
  (`Loom-Dev/packages/`, `Loom-Dev/backups/`), the isolated test profiles (`Loom-Dev/probe/`, `~/.loom-dev/codex-home`) and
  `/private/tmp/loom-real/`.
- **The tree side.** `plans/archive/`, `plans/1.8.0/` (the plan, `COMMON.md`, `DESIGN-V4.md`, the briefs), `plans/experiments/`
  (except the perf baseline `compare_baseline.py` reads), `plans/FEEDBACK-6.md`, `plans/FEEDBACK-7.md` and
  `design/pre-reference-preview-pages/`.
- **Links that now point nowhere.** Some docs and code comments still name these files. Read them at the tag, for example
  `git show release/1.8.0:plans/1.8.0/DESIGN-V4.md`. Paths under `evidence/` (in DECISIONS, SPEC and comments) are gone for good;
  the docs keep their conclusions.
- **Rollback.** There is no zip of 1.7.2 any more. To go back, rebuild `v1.7.2` in the loom tree (DEVELOPMENT §10).

## 3. Get a working tree back

```bash
git -C ~/Documents/github/loom-dev worktree add ~/Library/Caches/loom-v2/wt/v2 v2
cd ~/Library/Caches/loom-v2/wt/v2
scripts/check.sh --scratch ~/Library/Caches/loom-v2/build/v2 --suite SidebarStatusTests
```

- **Toolchain.** macOS 27, Xcode selected, Swift 6.4 (DEVELOPMENT §1). The first build from an empty scratch is long and hot.
- **Rules that still hold.** Scratch paths stay outside `~/Documents`. There is one build slot
  (`~/Library/Caches/loom-run1/build-slot.lock`, created on first use). Check `pmset -g therm` before heavy runs.
- **Check tiers.** `--unit`, `--integration`, `--windows --idle` and `--full --idle` (14 steps, idle Mac only),
  in DEVELOPMENT §2–§3.
- **Long runs.** Start `check.sh` with `nohup` into a log and read its tail for PASS or FAIL. A tool timeout then never kills the run.
- **Dev package.** `scripts/package-dev-app.sh <dir>` builds `Loom Dev.app` (bundle id `local.loom.desktop.dev`), the flavor
  with evidence mode. Fake providers and the evidence channel are covered in DEVELOPMENT §5 and §6.
- **Real-model tests.** They need fresh isolated profiles: `CLAUDE_CONFIG_DIR` =
  `~/Library/Application Support/Loom-Dev/probe/claude-config`, which the user logs in to themselves; the Codex home is
  `~/.loom-dev/codex-home`; the work folders go under `/private/tmp/loom-real/` (DEVELOPMENT §4).
- **Release.**
  1. Tag `release/X.Y.Z` on `v2`.
  2. Run `scripts/release/promote.sh X.Y.Z ~/Documents/github/loom`. It refuses a `vX.Y.Z` that already exists.
  3. In the loom tree, run `./build.sh` with the app quit. It swaps `/Applications/Loom.app` in place.

  Push and GitHub release only on the user's word (DEVELOPMENT §10).

## 4. State at the archive

- **Last full gate.** `cb73630`, `--full --idle`, PASS on all 14 steps: T1 1,343 tests, T2 1,292 plus the small targets, T3 37.
  The real Codex acceptance passed on its second attempt; the first finished without asking for approval.
- **Unverified since that gate.** Two commits came after it: the 2 fps spinner (`89ba919`, D-125) and the notes re-cut
  (`9fb92ae4`). Only scoped checks ran on them, and the last edit is unverified. That edit is the stop assertion of
  `SidebarStatusTests.spinnersStepTogetherFromOneClockTwiceASecond`, which now waits for the frame. Its earlier form failed
  once, 83/84, on a stale presentation layer. Run that suite first.
- **Claude live acceptance.** Not run: the isolated profile's login had expired. The daily-use goal (D-112) is not fully proved.
- **Harness scope.** opencode and agy are Coming later (D-120). Pi is deferred (D-113). Remora runs on Claude only (D-122).
  Codex sessions are outside the session channel (D-124).
- **Energy, 30 Oct.** Measured with `scripts/perf/real_energy.py` on a MacBook Air (60 Hz), with 60 s cells, a visible window and
  an idle Mac. CPU is % of one core.

  | Cell | App CPU | App footprint | WindowServer CPU |
  | --- | --- | --- | --- |
  | Home idle | 0.05 | 39 MiB | 1.7 |
  | Typing in the draft, 5 characters/s | 7.58 | 44 MiB | 4.3 |
  | One terminal working, spinner at 12 fps (before D-125) | 0.61 | 75 MiB | 9.1 |
  | The same cell at 4 / 2 fps / spinner still | 1.0 / 0.85 / 0.69 | — | 5.8 / 3.6 / 2.2 |
  | One terminal streaming 1 MiB/s (12 fps; still: WindowServer 3.5) | 14.8 | 75 MiB | 11.8 |
  | Terminal.app, the same 1 MiB/s | 15.2 | 114 MiB | 3.4 |

  D-92's idle and footprint budgets hold. The 2 fps rows come from an experiment build, not from the final one.

## 5. Open follow-ups

1. **Verify.** Re-run `SidebarStatusTests`, then `--windows --idle` once, on the head of `v2`.
2. **Energy of the final build.** Measure the shipped 2 fps build with `real_energy.py`: the working and the streaming cells.
3. **Typing cost.** Typing in the draft costs 7.6 % of a core at five characters a second. Find out why.
4. **Codex in the session channel (D-124).** Route it through its owned app-server. The sandbox blocks the socket today.
5. **Codex deletion limits.**
   - Record the Codex home at run start. Today deletion uses the toolchain's home at request time, so a run with another
     `CODEX_HOME` is not seen.
   - A native delete interrupted halfway may read as absent.
   - The optimizer's N1: a Codex refusal before the record exists leaves no way out, and its wording contradicts the step's.
   - The optimizer's N4: a deletion's own Codex server can start after Quit has taken its server list.
   - The rest of S1: a deletion's locator walks the Codex home more than once.
6. **Codex titles.** Codex has no start-time name; set one with `thread/name/set`. Also make the fake server's `thread/read`
   answer match the real one.
7. **Pinned cards.** Keys pressed before a pinned card draws its focus ring may be lost.
8. **Changes reason.** Changes with the mailbox down gives a generic reason (`SessionRuntime+UserMessages`).
9. **Not yet checked.** The test revision's M7 and M10; VoiceOver; a physical-pointer drag; the intermittent Claude interrupt,
   which has no known root cause; the Claude live cells after the user logs in to the isolated profile.
10. **Renaming `Loom.app` to `Sphyrna.app` (D-123, the user's call).**
    - What carries over: the bundle id, the signer and the data folders stay, so TCC, LaunchServices, notifications and
      defaults carry over. The login item must be registered again.
    - Steps:
      1. Turn off Open at login.
      2. Quit, and check that nothing runs from the bundle.
      3. `mv /Applications/Loom.app /Applications/Sphyrna.app`, in place, so the Dock tile follows.
      4. Check `mdfind "kMDItemCFBundleIdentifier == 'local.loom.desktop'"` lists one copy.
      5. Open the app and turn Open at login back on.
    - `build.sh` still installs `Loom.app`, so change it in the same step.
11. **Pushing.** Push the loom tree (8 commits) and publish GitHub releases, if wanted. Also decide whether `v2` gets a remote.

## 6. Decisions to know first

D-120 to D-125 are the newest decisions. They cover:

- the overnight release authority;
- Codex deletion through `thread/delete` (D-121);
- Remora on Claude (D-122);
- the in-place install (D-123);
- Codex outside the channel (D-124);
- the 2 fps spinner (D-125).

The rest are in [DECISIONS.md](DECISIONS.md).
