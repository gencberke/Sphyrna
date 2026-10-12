# Status

- **Updated:** 2026-10-12
- **Stage:** multi-agent run 1 (F, I, U, CP4), branch `swarm/1`; index and protocol [plans/RUN-1.md](plans/RUN-1.md). Stage L done except the deferred L-4 acceptance ([plan](plans/STAGE-L.md), D-31). CP5 is closed.
- **Slice:** feedback round 2 on 0.3.0 ([plans/FEEDBACK-2.md](plans/FEEDBACK-2.md), [D-39, D-40](DECISIONS.md)): footer chip B, card project label fix, newest-first project groups, Mark as Read, subagent tree, approval-gated "session opens session" (P1 core, P2 UI). Uncommitted on `swarm/1`.
- **State:** all six items built and accepted on tests (each new test fails without its change), then accepted on a dev package with real Claude and on screen (5 short turns; [acceptance](plans/FEEDBACK-2.md#acceptance-on-a-package-with-real-claude-12-oct-d-41)). FB2-6 (a subagent's permission prompt left the card on Working) fixed after it, on tests only. Committed and tagged `release/0.3.1` (D-41) for the daily app; the daily app is still 0.3.0 until the install.
- **Next owner:** the planner: promote 0.3.1 and install it once the user has quit the running daily Loom (`build.sh` refuses while it runs; the planner never quits it). Then the planner adds the `$LOOM_CLI open` line to the edd and enmusait vault cards (D-40).
- **Open decisions:** [DECISIONS.md → Open](DECISIONS.md#open) and the DP list in RUN-1.
- **Latest result:** [FEEDBACK-2 acceptance](plans/FEEDBACK-2.md#acceptance-on-a-package-with-real-claude-12-oct-d-41).
- **Blocker:** none.
