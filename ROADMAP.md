# Roadmap

Path from today to Loom's first production release. Checkpoint numbers are identities, not order ([D-02](DECISIONS.md)). Rows marked **proposed** are the main agent's draft and wait for the user; they are not decisions. The current position is only in [STATUS.md](STATUS.md).

## Release target

**First production release:** a macOS 27 app for one power user on their own Mac, signed with the stable local identity and not notarized ([D-47](DECISIONS.md)), its source and package public on GitHub ([D-56](DECISIONS.md)), that hosts real Claude Code terminals in the accepted design and identity, with verified process ownership, state, resume, Stop and Quit, permanent deletion of a conversation and the CP4 retention rules ([D-26](DECISIONS.md)), inside the agreed resource budgets. Codex is frozen and not included ([D-14, D-28](DECISIONS.md)); CP3 coordination is not included ([D-27](DECISIONS.md)). Other providers, notifications and the ideas in contract §13 are out unless the user adds them; the user added a subagent view under each session ([D-39](DECISIONS.md)), a narrow, approval-gated "session opens session" ([D-40](DECISIONS.md)), a Dock badge ([D-45](DECISIONS.md)), a menu bar item, approval notifications and Open at Login ([D-47, D-49](DECISIONS.md)) and project colours ([D-48](DECISIONS.md)).

## Stages

| Stage | Goal | Done when | State |
| --- | --- | --- | --- |
| CP1 Ownership and launch | Loom owns exactly the processes it starts | [CP1 plan](plans/CHECKPOINT-1.md) acceptance | closed |
| CP2 State and resume | Identity, turn, error and approval sources; safe idle; same-conversation resume | [CP2 matrix](plans/CHECKPOINT-2.md) | closed |
| CP5 Terminal engine and first window | Usable window with real Claude terminals in the preserved design | [CHECKPOINT-5](plans/CHECKPOINT-5.md) acceptance verified; optimizer done | closed 6 Oct ([D-23](DECISIONS.md)); Codex-only items in the [Codex backlog](plans/cp5/CODEX-BACKLOG.md) |
| L Clean loom line | Daily-use `Loom.app` built only from a clean loom tree ([D-25, D-29](DECISIONS.md)) | [Stage L plan](plans/STAGE-L.md) | done 7 Oct (0.1.0); L-4 acceptance deferred ([D-31](DECISIONS.md)) |
| F Foundation hardening (multi-agent run 1) | Make the base safe for parallel feature work and production | [STAGE-F](plans/STAGE-F.md) acceptance | slices done in [run 1](plans/RUN-1.md); [0.2.0](plans/RC-0.2.0.md) accepted for daily use ([D-36](DECISIONS.md)); the visible-window performance check passed against a reference package in [hardening round 1](plans/HARDENING-1.md) |
| I Identity and UI system (multi-agent run 1) | Codify identity direction A ([D-22](DECISIONS.md)) as tokens and rules; settle the navbar | [STAGE-I](plans/STAGE-I.md) acceptance | I1–I3 done in [run 1](plans/RUN-1.md), I4 parked; accepted for daily use with [0.2.0](plans/RC-0.2.0.md) ([D-36](DECISIONS.md)); navbar keeps the transparent header until O-03 |
| U Daily-use UI features (multi-agent run 1) | Sidebar footer bar, a real Settings page with a lightweight usage and cost view, conversation tabs ([D-32, D-33](DECISIONS.md)) | [STAGE-U](plans/STAGE-U.md) acceptance | done in [run 1](plans/RUN-1.md); accepted for daily use with [0.2.0](plans/RC-0.2.0.md) ([D-36](DECISIONS.md)) |
| CP4 Deletion and retention (multi-agent run 1) | Contract §5 and §8: permanent deletion first, then stale, retention and cleanup; recovery from half-done deletes | Contract §11 row 4; [CHECKPOINT-4](plans/CHECKPOINT-4.md) | built and verified in [run 1](plans/RUN-1.md) (real-Claude deletion check passed); manual Delete Permanently in every build since 0.3.0 ([D-37](DECISIONS.md)), the cleanup review development-only until DP-CP4-2; in first-release scope ([D-26](DECISIONS.md)) |
| CP3 Authorized coordination | Contract §7: delegated hand-off between sessions under user authority | Contract §11 row 3 | **committed, no date** ([D-43](DECISIONS.md), [D-46](DECISIONS.md): the user wants the channel built eventually, not in the next round; Claude finds sessions and opens/follows a Codex session); out of the multi-agent run and the first release ([D-27](DECISIONS.md)), except the narrow slice of [D-40](DECISIONS.md) (a session asks Loom to open a new session; the user approves in Loom; agents learn it from Loom's own skill, [D-42](DECISIONS.md); built in [feedback round 2](plans/FEEDBACK-2.md)); message delivery into existing sessions stays here |
| H Hardening round 1 | Stability and daily-use polish after 0.3.3 ([D-45](DECISIONS.md)); project colours ([D-48](DECISIONS.md)) | [plans/HARDENING-1.md](plans/HARDENING-1.md) | H1-A to H1-E shipped in **0.4.0** (12 Oct), H1-F (menu bar, notifications, Open at login) in **0.4.1** (13 Oct) |
| R First-class app on the user's Mac ([D-47](DECISIONS.md)) | Loom behaves like an official macOS app on this Mac and meets its guarantees | See below | macOS integration shipped in 0.4.0 and 0.4.1 (H1-A, H1-F); rest proposed |

### L: Clean loom line

Model and rules: [DEVELOPMENT.md §10](DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree); plan and acceptance: [plans/STAGE-L.md](plans/STAGE-L.md). Ran before the multi-agent run so that every later release has a clean daily build path.

### F: Foundation hardening

Facts behind it are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (hotspots) and the [CP5 optimizer passes](plans/cp5/CLOSURE.md).

- Production build excludes Codex surfaces (menu items, context menus, `--codex-home`), keeping the code paused behind one switch.
- Quit and shutdown no longer route through the CP5-A synthetic `TerminalRunController`.
- Evidence and fixture code is separated from production paths without losing the evidence tooling.
- Large actors (`ProcessSupervisor`, `SessionRuntime`, `SessionCatalog`) are split where a change would otherwise touch unrelated responsibilities, with no behavior change.
- One local command runs the required checks (no CI exists); perf scripts in `scripts/perf/` reproduce the CP5 matrix.
- Deferred optimizer items (F6, F8–F10, S2, S4, S-C) are taken or explicitly dropped.

Done when: behavior is unchanged (full release suite plus a real-Claude check), the CP5 performance baseline holds, and the architecture doc matches the code.

### I: Identity and UI system

- Direction A from [the identity proposal](design/IDENTITY-PROPOSAL.md) is chosen; its open sub-decisions are settled, tokens move into one Swift source and the rules into [design/DESIGN.md](design/DESIGN.md).
- Measure the indicator's WindowServer cost (CP5 optimizer R-A) and apply the 10 fps frame-rate hint if it matters.
- The theme rewrite removes the dead `CatalogTheme` constants (CP5 optimizer S-B).
- Navbar layout is decided (O-03) and built.
- Every surface in [design/UI-MAP.md](design/UI-MAP.md) is reviewed against the identity; accessibility pass (contrast, keyboard, Reduce Motion/Transparency).

Done when: the user accepts the result on a package, evidence screenshots match the rules, and indicator and render costs stay at baseline.

### U: Daily-use UI features

- Sidebar footer bar: the bottom `+` and settings icons become one compact footer inside the sidebar, also showing compact Claude usage.
- Settings page: a real Settings window (existing preferences plus usage and cost), lightweight and usage-first ([reference](design/references/t3-code-usage-reference.png)).
- Usage data without load: read what Claude Code already records locally, incrementally and bounded; no extra CLI processes, no provider polling; cost as a clearly labelled estimate. Codex rows wait for Codex (D-28).
- Conversation tabs above the terminal for quick switching between a few threads ([layout reference](design/references/layout-guidance.jpg)).
- All in identity A; previews before building; no left rail, no right sidebar ([D-34](DECISIONS.md)).

Done when: the user accepts the surfaces on a package, the usage numbers match Claude's own records on test data, and idle and render costs stay at baseline.

### CP4: Deletion and retention (multi-agent run)

- Permanent deletion of one conversation first: its local Claude data only, never another conversation's; half-done deletes recover; late events never bring a deleted conversation back (contract §8).
- Then stale handling, retention and cleanup: monthly cleanup of eligible stale conversations, at least 15 days stale, exceptions (pinned, protected worktrees), list-and-confirm after a long absence (contract §3, §5).
- Open inputs: contract §12 item 4, the cleanup arithmetic ([O-09](DECISIONS.md), DP-CP4-2). Item 3, the deletion data contract, is settled for manual delete by [D-37](DECISIONS.md) (the CP4-A allowlist).

Done when: contract §11 row 4 evidence passes on synthetic data and a real-Claude deletion check, with no harm to other conversations.

### R: First-class app on the user's Mac

Loom stays a personal app (D-47): no Developer ID, notarization or update mechanism; releases keep the promote path into the clean loom tree, which is public on GitHub from 0.4.4 on (D-56).

- macOS integration, shipped in hardening round 1: the Dock badge (H1-A, 0.4.0); a menu bar item, approval notifications, Open at Login, an app category and numeric versions from the release (H1-F, 0.4.1, [D-49](DECISIONS.md)). Whether Loom now shows up in Screen Time is for the user to check ([HARDENING-1](plans/HARDENING-1.md)).
- First-run experience: provider CLI detection, missing-CLI and launch errors, empty states.
- Crash and Force Quit guarantees stated and tested (contract §12.1).
- Resource budgets (O-01) enforced by a repeatable measurement.
- Release checklist: full suite, real-Claude check, perf matrix, a short smoke run on a production-faithful package before each tag.

Done when: the checklist passes on the release candidate and the user accepts it.

## Order

L (done 7 Oct, before the multi-agent run) → multi-agent run (authority [D-30](DECISIONS.md); the prompt is kept by the user outside the repo): F, I, U and CP4 in parallel where write areas are disjoint, with UI/UX, architecture/scalability and performance evaluations along the way → R. Each verified state can be promoted to the daily app through L's path. After run 1 and the two feedback rounds: hardening round 1 (H, done in 0.4.0 and 0.4.1), feedback round 3 ([plans/FEEDBACK-3.md](plans/FEEDBACK-3.md), shipped in 0.4.2), feedback round 4 ([plans/FEEDBACK-4.md](plans/FEEDBACK-4.md), shipped in 0.4.3 with its optimizer review), then R. Codex returns after the first release, starting from the [Codex backlog](plans/cp5/CODEX-BACKLOG.md); the CP3 channel follows when the user schedules it (D-46).
