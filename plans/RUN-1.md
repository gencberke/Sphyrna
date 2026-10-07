# Multi-agent run 1 — index and protocol

Goal: take Loom from the closed CP5 state to "almost release" — more stable, faster and ready for daily use — through stages F, I, U and CP4 ([ROADMAP](../ROADMAP.md), authority [D-30..D-34](../DECISIONS.md)). Owner: the planner-reviewer (main session). Position: [STATUS](../STATUS.md).

**Morning target ([D-35](../DECISIONS.md)):** a release-candidate `Loom.app` with the production identity, built from the staged release tree of the combined `swarm/1` state, signed with the stable local identity, verified (full suite, matrix against package I, real-Claude check), in `~/Library/Application Support/Loom-Dev/packages/run1-rc/`, with the release-candidate note and the exact commands to tag, promote and install it. Installing over `/Applications/Loom.app` and tagging stay with the user (D-30 forbids tags and installing a daily release in this run; the candidate migrates the catalog to schema v3, one way).

Stage plans: [STAGE-F](STAGE-F.md) · [STAGE-I](STAGE-I.md) · [STAGE-U](STAGE-U.md) · [CHECKPOINT-4](CHECKPOINT-4.md). Slice Briefs: `plans/f/`, `plans/i/`, `plans/u/`, `plans/cp4/`. Planning evidence: [run1-planning-scans/](experiments/run1-planning-scans/) (eight read-only scans and a completeness critique, 7 Oct 2026).

## Order and waves

Write areas decide what runs in parallel; hot files (`AppDelegate.swift`, `Package.swift`, `SidebarView.swift`, `DetailView.swift`, `CatalogModel.swift`, the three large actors) have one owner per wave.

| Wave | Slices (parallel inside a wave) | Gate to next wave |
| --- | --- | --- |
| 1 | F0 tooling · F1 build identity / Codex hidden · F2 quit coordinator · F4 actor splits · U0 usage index · CP4-A Claude data inventory · CP4-F cleanup planner · UD design preview | each slice accepted and committed |
| 2 | F3 evidence separation (sole owner of `AppDelegate`, `Package.swift`, `promote.sh`) · F5 launch/sidebar performance (after F3 lands on `AppDelegate`; `CatalogModel`, `GitBranch`, `ProcessSupervisor` parts may start at once) · F6 optimizer items and robustness · I1 theme foundation · CP4-B catalog v3 · U3 tab state | as above |
| 3 | I2 identity values and accent · U1 Settings + usage view · U2 footer bar · CP4-C deletion orchestration · I4 indicator WindowServer cost (exclusive measurement) | as above |
| 4 | U4 tab strip · I3 motion and accessibility · CP4-D delete UI · CP4-G cleanup review flow · U5 daily-use polish | as above |
| 5 | CP4-E real-Claude deletion check · stage-end evaluations · optimizer passes · release-candidate note | stages close |

Critical path: F1 → F3 → I1 → U1/U2/U4 → CP4-D. Off the critical path and started at once: U0, CP4-A, CP4-F, UD.

As run (7 Oct): wave 1 F0, F1, F2, F4, U0, CP4-A, CP4-F, UD; wave 2a I1, U3, F3, I2 (I2 moved up once I1 and F3 were in); wave 2b F5, F6 (S2 and F10 only), CP4-B (also takes F6's undecodable-row item, since it owns the catalog files), U12 (U1 and U2 as one slice to save a wave). Next: CP4-C, U4, I4 (exclusive measurement), then I3, CP4-D, CP4-G, U5, CP4-E.

## Protocol for every implementer slice

- **Worktree.** Each slice works in its own git worktree `~/Library/Caches/loom-run1/wt/<slice>` (outside `~/Documents`) on branch `run1/<slice>`, created by the planner-reviewer from the `swarm/1` commit named in the Brief. The implementer never commits; the planner-reviewer diffs the worktree, applies the accepted change to `swarm/1` with `git apply --3way` and commits it (one commit per accepted slice, English message, Co-Authored-By line). No push, PR, merge, rebase, tag or history rewrite ([D-30](../DECISIONS.md)).
- **Build slot.** Every build, test, package or measurement command runs under `/usr/bin/lockf -k ~/Library/Caches/loom-run1/build-slot.lock <command>` (after F0 lands: `scripts/with-build-slot.sh <command>`). Scratch path per slice: `~/Library/Caches/loom-run1/scratch-<slice>` (never under `~/Documents`).
- **Tests.** Narrow suites for the change (`swift test --scratch-path … --filter …`). The Mac counts as idle for the whole run ([D-30](../DECISIONS.md)), so window tests may run, but only the planner-reviewer's named owner runs the full release suite on the combined tree. A regression test must fail without the fix (show it).
- **User data.** Never the real `~/.claude`, `~/.codex`, installed `Loom.app` / `Loom Dev.app`, `~/Library/Application Support/Loom`, the default dev catalog or `ui-preferences.json` in `~/Library/Application Support/Loom-Dev`. Usage and deletion tests use temp trees or isolated profiles. Packages go under `~/Library/Application Support/Loom-Dev/packages/run1-*`.
- **Design rules.** Only the user changes a design rule; a slice that needs one lists it under Needs.
- **Report:** Status / Result / Evidence (verified, failed, unverified) / Unverified / Needs / Doc impact, plus the worktree path and the exact commands run.

## Acceptance by the planner-reviewer

A slice is accepted only when its diff is reviewed (an adversarial read-only review runs in the wave workflow; the planner-reviewer reads the decisive parts), its checks pass on `swarm/1` after the apply, and its evidence shows the behavior. Three failed acceptance rounds or a pending user decision park the slice with its findings.

## Real-Claude budget

About 40 short turns for the whole run ([D-30](../DECISIONS.md)); isolated profile `~/Library/Application Support/Loom-Dev/probe/claude-config` (model haiku). Planned use: F end 2 (`claude_real.py`), U usage cross-check 2, CP4-E deletion 4, final release candidate 2, reserve 30.

| Date | Use | Turns | Running total |
| --- | --- | --- | --- |
| — | none yet | 0 | 0 |

## Stage-end evaluation recipe

Run by one named evaluation owner on the combined `swarm/1` tree, in this order, 90 s cooldown between heavy cells:

1. Full gate: `scripts/check.sh --full --idle` (release build, full release suite, staged release-tree build after F3).
2. Package: `scripts/package-dev-app.sh ~/Library/Application\ Support/Loom-Dev/packages/run1-<stage>-candidate` plus release-built `loom-fake-provider` and `loom-test-child` copied to `packages/run1-<stage>-fixtures/`.
3. Matrix against the package I reference (`packages/cp5-I-reference`, built 7 Oct from tag `cp5-package-i`): `scripts/perf/run-final-matrix.py --app <candidate> --reference-app <reference>`; judged by paired reference cells and the [package I baseline](experiments/cp5-final-matrix-I-20261006.json); CPU40 must hold.
4. Indicator cost (`scripts/perf/indicator_cost.py`) when the stage touched sidebar, indicator or chrome.
5. Real Claude (`scripts/perf/claude_real.py`, 2 turns) when the stage touched provider, session, terminal, Stop or Quit paths; count the turns above.
6. UI/UX review: evidence screenshots (fake providers) at 1220×780 and 780×500, both list modes, sidebar open/collapsed, plus the stage's new surfaces, judged against [DESIGN](../design/DESIGN.md), [IDENTITY](../design/IDENTITY-PROPOSAL.md) and [UI-MAP](../design/UI-MAP.md); hover, menus, glass and motion stay on the user's eye-check list.
7. Architecture/scalability review (read-only) of the stage diff.
8. Optimizer (`strict-reviewer`, Opus 5.5 / `xhigh`, optimizer Brief) before the stage closes; the planner-reviewer verifies its decisive findings.

## Decision points for the user

Collected from the stage plans; each has a recommendation and the default used meanwhile. Details in the stage plan named in the ID.

| ID | Question | Recommendation (default meanwhile) |
| --- | --- | --- |
| DP-F1 | Release binary launched with `--evidence`: after F3 the flag has no code behind it. Ignore it (data root still isolated by `LaunchOptions`) or refuse to start? | Ignore; keep the isolation rule (default) |
| DP-I1 | Failure mark under macOS "Differentiate without color": keep the dot only, or draw B's diamond only when that setting is on (O-12 item 3) | Diamond only under the setting (default: not built until decided) |
| DP-I2 | Menu and button commands: sentence case per identity §2, or keep macOS Title Case for commands | Title Case for menu/button commands, sentence case for messages (default) |
| DP-I3 | Loom mark in the empty catalog state (O-12 item 9) | Yes (default: not built until decided; needs a packaged asset) |
| DP-U1 | Tab model: pinned tabs plus one transient tab for the selection, auto-pin on start/resume, explicit "Open in Tab", close never stops a run | As recommended (default) |
| DP-U2 | Tab shortcuts | Shift+Cmd+] / [ and Ctrl+Tab / Ctrl+Shift+Tab; Close Tab Opt+Cmd+W (default) |
| DP-U3 | Usage scope: all Claude usage in the active Claude profile, or only Loom-hosted conversations | Whole profile, labelled "this Claude profile" (default) |
| DP-U4 | Plan limits (5-hour / weekly): only reachable through a Claude `statusLine` command or the network, both D-20 behavior changes | Not shown; a labelled local 5-hour activity window instead (default) |
| DP-U5 | Price table: static, dated, shipped with the app; cost shown as "est." and hidden for unknown models | As recommended (default); confirm the table values in [U0](u/U0.md) |
| DP-CP4-1 | Deletion data contract (contract §12.3): exactly which local Claude files a single-conversation delete removes | Allowlist in [CP4-A](cp4/A.md) (default implemented in dev builds only; nothing ships before your decision) |
| DP-CP4-2 | Cleanup arithmetic (contract §12.4): cadence, effect of viewing a stale row, long-absence threshold, bulk guard | Last run + 30 days; viewing extends the wait; 45 days absence; >10 eligible forces review (default; automatic deletion stays off) |
| DP-CP4-3 | Worktree protection rule | Protect linked or Claude-created worktrees that are dirty, unpushed or stashed (default) |
| DP-CP4-4 | Schema v3: Loom 0.1.0 cannot open a v3 catalog (no downgrade) | Accept (default) |
| DP-CP4-5 | Pinned conversations (retention exception) need a Pin action | Small context-menu Pin (default: built in CP4-G) |
| DP-CP4-6 | Usage index and deletion: the usage index keeps token counts of a deleted conversation without its id or file path | As recommended (default) |
| DP-CP4-8 | Which Claude folder a delete targets when `CLAUDE_CONFIG_DIR` is set only in the login shell and no conversation was started in this app run | Today: Loom's own environment, else `~/.claude` (shown in the confirm sheet; no CLI run). Recommended: resolve the login-shell environment once in the background at launch when deletion is enabled |
| DP-CP4-7 | A symlinked or other-device folder under the Claude data folder: today any such folder stops every deletion at "unreachable" (fail closed) | Block only when the folder can hold this conversation's files (its project folder or a top-level data folder); offer "remove from Loom only" after a confirmed failure (default meanwhile: fail closed) |

Open decisions that stay with the user and are not touched by this run: O-01, O-06, O-07, O-08, O-10; O-03 uses the transparent header and O-12 uses A's values meanwhile.

## Incidents

- **7 Oct 2026, about 02:45 — the user's global macOS preferences were wiped.** While probing window placement for U5, an implementer ran `defaults delete NSGlobalDomain` without a key. `~/Library/Preferences/.GlobalPreferences.plist` now holds only `AppleLanguages` and `AppleLocale`; the per-host file (`ByHost/.GlobalPreferences.*.plist`, trackpad gestures) was not touched. The previous contents were never printed and there is no Time Machine destination or local snapshot, so Loom's run cannot restore them, and the planner does not rewrite system settings by guesswork. Likely visible effects: appearance (dark/light, accent and highlight colour), key repeat and delay, scroll direction, scroll bars, text substitutions, keyboard navigation, units and 24-hour time overrides. Restore through System Settings or from a backup (user decision). Prevention: from wave 4 on, every Brief forbids `defaults write/delete` on NSGlobalDomain, `com.apple.*` and Loom bundle domains, and addressing apps by bundle id or name. The same implementer also sent one `osascript quit` to bundle id `local.loom.desktop.dev`; no installed Loom Dev was running.

## Parked

- **I4** (WindowServer cost of the working indicator): needs an unlocked, idle screen; the screen was locked from the user's bedtime. Tooling kept as `~/Library/Caches/loom-run1/patches/I4.patch`. Resume: apply the patch in a fresh worktree and run the Brief's measurement when the user says the Mac is idle and unlocked.
- **Visible-window measurements** (matrix against package I with CPU40, indicator cost): the same lock makes every on-screen cell invalid tonight; see the stage-end evaluation notes.
