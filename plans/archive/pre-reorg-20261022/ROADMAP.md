# Roadmap

Path from today to 1.6.0, Loom v2's one release and the first stable one, named Sphyrna ([D-68](DECISIONS.md), [D-77](DECISIONS.md), [D-83](DECISIONS.md)). Checkpoint numbers are identities, not order ([D-02](DECISIONS.md)). Rows marked **proposed** are the main agent's draft and wait for the user; they are not decisions. The current position is only in [STATUS.md](STATUS.md).

## Release target

**1.6.0** ([D-68](DECISIONS.md), [D-83](DECISIONS.md)) is Loom v2 "Studio" (stage V2 below), named Sphyrna ([D-77](DECISIONS.md)), the first stable release; today's code is its 1.5.0 pre-release. It is accepted against three goals: light; sessions, not harnesses, with Sphyrna as their one central place; and a cost the user does not see ([V2-PLAN §14](plans/V2-PLAN.md#14-toward-160)). It keeps the scope set for the first production release before v2:

**First production release (scope set before v2):** a macOS 27 app for one power user on their own Mac, signed with the stable local identity and not notarized ([D-47](DECISIONS.md)), its source and package public on GitHub ([D-56](DECISIONS.md)), that hosts real Claude Code terminals in the accepted design and identity, with verified process ownership, state, resume, Stop and Quit, permanent deletion of a conversation and the CP4 retention rules ([D-26](DECISIONS.md)), inside the agreed resource budgets. Codex is frozen and not included ([D-14, D-28](DECISIONS.md)); CP3 coordination is not included ([D-27](DECISIONS.md)). Other providers, notifications and the ideas in contract §13 are out unless the user adds them; the user added a subagent view under each session ([D-39](DECISIONS.md)), a narrow, approval-gated "session opens session" ([D-40](DECISIONS.md)), a Dock badge ([D-45](DECISIONS.md)), a menu bar item, approval notifications and Open at Login ([D-47, D-49](DECISIONS.md)) and project colours ([D-48](DECISIONS.md)).

## Stages

| Stage | Goal | Done when | State |
| --- | --- | --- | --- |
| CP1 Ownership and launch | Loom owns exactly the processes it starts | [CP1 plan](plans/CHECKPOINT-1.md) acceptance | closed |
| CP2 State and resume | Identity, turn, error and approval sources; safe idle; same-conversation resume | [CP2 matrix](plans/CHECKPOINT-2.md) | closed |
| CP5 Terminal engine and first window | Usable window with real Claude terminals in the preserved design | [CHECKPOINT-5](plans/CHECKPOINT-5.md) acceptance verified; optimizer done | closed 6 Oct ([D-23](DECISIONS.md)); Codex-only items in the [Codex backlog](plans/cp5/CODEX-BACKLOG.md) |
| L Clean loom line | Daily-use `Loom.app` built only from a clean loom tree ([D-25, D-29](DECISIONS.md)) | [Stage L plan](plans/STAGE-L.md) | done 7 Oct (0.1.0); L-4 acceptance deferred ([D-31](DECISIONS.md)) |
| F Foundation hardening (multi-agent run 1) | Make the base safe for parallel feature work and production | [STAGE-F](plans/STAGE-F.md) acceptance | slices done in [run 1](plans/RUN-1.md); [0.2.0](plans/RC-0.2.0.md) accepted for daily use ([D-36](DECISIONS.md)); the visible-window performance check passed against a reference package in [hardening round 1](plans/HARDENING-1.md) |
| I Identity and UI system (multi-agent run 1) | Codify identity direction A ([D-22](DECISIONS.md)) as tokens and rules; settle the navbar | [STAGE-I](plans/STAGE-I.md) acceptance | I1–I3 done in [run 1](plans/RUN-1.md), I4 parked; accepted for daily use with [0.2.0](plans/RC-0.2.0.md) ([D-36](DECISIONS.md)); the transparent header stays (O-03, closed by [D-69](DECISIONS.md)); its look was replaced by Ink on 20 Oct ([D-74](DECISIONS.md)) |
| U Daily-use UI features (multi-agent run 1) | Sidebar footer bar, a real Settings page with a lightweight usage and cost view, conversation tabs ([D-32, D-33](DECISIONS.md)) | [STAGE-U](plans/STAGE-U.md) acceptance | done in [run 1](plans/RUN-1.md); accepted for daily use with [0.2.0](plans/RC-0.2.0.md) ([D-36](DECISIONS.md)) |
| CP4 Deletion and retention (multi-agent run 1) | Contract §5 and §8: permanent deletion first, then stale, retention and cleanup; recovery from half-done deletes | Contract §11 row 4; [CHECKPOINT-4](plans/CHECKPOINT-4.md) | built and verified in [run 1](plans/RUN-1.md) (real-Claude deletion check passed); manual Delete Permanently in every build since 0.3.0 ([D-37](DECISIONS.md)), the cleanup review ships in 1.6.0 with configurable numbers ([D-69](DECISIONS.md) (10)); in first-release scope ([D-26](DECISIONS.md)) |
| CP3 Authorized coordination | Contract §7: delegated hand-off between sessions under user authority | Contract §11 row 3 | **committed, no date** ([D-43](DECISIONS.md), [D-46](DECISIONS.md): the user wants the channel built eventually, not in the next round; Claude finds sessions and opens/follows a Codex session); out of the multi-agent run and the first release ([D-27](DECISIONS.md)), except the narrow slice of [D-40](DECISIONS.md) (a session asks Loom to open a new session; the user approves in Loom; agents learn it from Loom's own skill, [D-42](DECISIONS.md); built in [feedback round 2](plans/FEEDBACK-2.md)); the run toward 1.6.0 adds a session finding the sessions it needs, read only ([D-83](DECISIONS.md)); message delivery into existing sessions stays here |
| H Hardening round 1 | Stability and daily-use polish after 0.3.3 ([D-45](DECISIONS.md)); project colours ([D-48](DECISIONS.md)) | [plans/HARDENING-1.md](plans/HARDENING-1.md) | H1-A to H1-E shipped in **0.4.0** (12 Oct), H1-F (menu bar, notifications, Open at login) in **0.4.1** (13 Oct) |
| R First-class app on the user's Mac ([D-47](DECISIONS.md)) | Loom behaves like an official macOS app on this Mac and meets its guarantees | See below | macOS integration shipped in 0.4.0 and 0.4.1 (H1-A, H1-F); the rest folds into 1.6.0's evaluation ([V2-PLAN §7, §9 item 5](plans/V2-PLAN.md#7-evaluation-per-release)) |
| V2 "Studio" ([D-57–D-59](DECISIONS.md)) | Loom becomes the user's main development app: a native chat over the real Claude Code CLI, chat first, in a fuller and calm app drawn in Ink ([D-74](DECISIONS.md), which replaced Night Fleece 2) | [V2-PLAN](plans/V2-PLAN.md): Releases A (Studio shell and read-only Chat), B (live Chat) and C (review and aside), the Ink revision, the chat-performance slice and Remora (Lombot) are stable, and the build meets D-83's three goals; Loom v2 then ships once as 1.6.0, the first stable release, named Sphyrna ([D-68](DECISIONS.md), [D-70](DECISIONS.md), [D-77](DECISIONS.md), [D-83](DECISIONS.md)) | **building** since 17 Oct on branch `v2` ([D-60](DECISIONS.md)); A, B and C closed; since 21 Oct the run toward 1.6.0, in two tracks ([D-83](DECISIONS.md), [V2-PLAN §14](plans/V2-PLAN.md#14-toward-160)) |
| Codex planning ([D-57](DECISIONS.md)) | Plan Codex's return (frozen by [D-28](DECISIONS.md)) | A Codex plan the user accepts | after v2 |

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

- Direction A from the identity proposal (`design/IDENTITY-PROPOSAL.md`, in git) is chosen; its open sub-decisions are settled, tokens move into one Swift source and the rules into [design/DESIGN.md](design/DESIGN.md).
- Measure the indicator's WindowServer cost (CP5 optimizer R-A) and apply the 10 fps frame-rate hint if it matters.
- The theme rewrite removes the dead `CatalogTheme` constants (CP5 optimizer S-B).
- Navbar layout is decided (O-03) and built.
- Every surface in [design/UI-MAP.md](design/UI-MAP.md) is reviewed against the identity; accessibility pass (contrast, keyboard, Reduce Motion/Transparency).

Done when: the user accepts the result on a package, evidence screenshots match the rules, and indicator and render costs stay at baseline.

### U: Daily-use UI features

- Sidebar footer bar: the bottom `+` and settings icons become one compact footer inside the sidebar, also showing compact Claude usage.
- Settings page: a real Settings window (existing preferences plus usage and cost), lightweight and usage-first, after T3 Code's usage page.
- Usage data without load: read what Claude Code already records locally, incrementally and bounded; no extra CLI processes, no provider polling; cost as a clearly labelled estimate. Codex rows wait for Codex (D-28).
- Conversation tabs above the terminal for quick switching between a few threads.
- All in identity A; previews before building; no left rail, no right sidebar ([D-34](DECISIONS.md)).

Done when: the user accepts the surfaces on a package, the usage numbers match Claude's own records on test data, and idle and render costs stay at baseline.

### CP4: Deletion and retention (multi-agent run)

- Permanent deletion of one conversation first: its local Claude data only, never another conversation's; half-done deletes recover; late events never bring a deleted conversation back (contract §8).
- Then stale handling, retention and cleanup: monthly cleanup of eligible stale conversations, at least 15 days stale, exceptions (pinned, protected worktrees), list-and-confirm after a long absence (contract §3, §5).
- Open inputs: contract §12 item 4, the cleanup arithmetic ([O-09](DECISIONS.md), DP-CP4-2), settled at 1.6.0's evaluation; [D-69](DECISIONS.md) (10) ships the review in the release (1.6.0, [D-83](DECISIONS.md)) with its numbers configurable. Item 3, the deletion data contract, is settled for manual delete by [D-37](DECISIONS.md) (the CP4-A allowlist).

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

L (done 7 Oct, before the multi-agent run) → multi-agent run (authority [D-30](DECISIONS.md); the prompt is kept by the user outside the repo): F, I, U and CP4 in parallel where write areas are disjoint, with UI/UX, architecture/scalability and performance evaluations along the way → R. Each verified state can be promoted to the daily app through L's path. After run 1 and the two feedback rounds: hardening round 1 (H, done in 0.4.0 and 0.4.1), feedback round 3 ([plans/FEEDBACK-3.md](plans/FEEDBACK-3.md), shipped in 0.4.2), feedback round 4 ([plans/FEEDBACK-4.md](plans/FEEDBACK-4.md), shipped in 0.4.3 with its optimizer review), and the public 0.4.4 ([D-56](DECISIONS.md)).

Next comes v2 ([plans/V2-PLAN.md](plans/V2-PLAN.md), D-57):

1. Release A: the Studio shell with the read-only Chat view.
2. Release B: the live Chat.
3. Release C: review and aside. Closed on 21 Oct ([D-83](DECISIONS.md)).
4. The run toward 1.6.0 ([D-83](DECISIONS.md), [V2-PLAN §14](plans/V2-PLAN.md#14-toward-160)), in two tracks that the main session integrates on `v2`:
   - **The Ink build** (v3) ([D-73](DECISIONS.md), [D-74](DECISIONS.md), [D-75](DECISIONS.md), [D-76](DECISIONS.md), [D-77](DECISIONS.md), [D-78](DECISIONS.md), [D-79](DECISIONS.md), [D-80](DECISIONS.md), [D-81](DECISIONS.md), [D-82](DECISIONS.md); [V2-PLAN §13](plans/V2-PLAN.md#13-the-ui-revision-ink)). The design is done: every preview is accepted, and [the Ink reference](design/reference.html) holds every surface as decided, with [a landing page](design/landing.html) drawn from it. The build runs in steps, and the chat comes early so that the chat-performance slice measures the Ink chat.
   - **The structure:** one session service that knows sessions, not harnesses; the cost and context rules, with their guards; and the channel's first step, where a session finds the sessions it needs and asks to open one with the user's approval ([D-40](DECISIONS.md), [D-42](DECISIONS.md)).
5. The chat-performance slice, on the structure's track after the Ink chat: a visible Chat stream costs no more than the terminal for the same output ([D-69](DECISIONS.md), [D-70](DECISIONS.md)).
6. Remora (Lombot until D-77), the Home assistant, as [the reference](design/reference.html#remora) draws it: spike S10 first, now, then its build if its cost fits the third goal ([D-64](DECISIONS.md), [D-65](DECISIONS.md), [D-68](DECISIONS.md), [D-77](DECISIONS.md), [D-80](DECISIONS.md), [D-83](DECISIONS.md)).
7. 1.6.0's evaluation against D-83's goals, with the resource budgets (O-01) and contract §12 (O-09), then the release through the clean loom path at the user's word ([D-68](DECISIONS.md), [D-83](DECISIONS.md)).

Stage R's remaining items fold into 1.6.0's evaluation ([V2-PLAN §9](plans/V2-PLAN.md#9-decision-points-for-the-user) item 5).

After v2, Codex planning is the next step (D-57). It starts from the [Codex backlog](plans/cp5/CODEX-BACKLOG.md) and T3 Code's [app-server study](plans/v2-research/evidence/t3code-shell-20261017.md). The CP3 channel follows when the user schedules it (D-46).
