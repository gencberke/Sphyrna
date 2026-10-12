# Status

- **Updated:** 2026-10-12
- **Stage:** multi-agent run 1 (F, I, U, CP4), branch `swarm/1`; index and protocol [plans/RUN-1.md](plans/RUN-1.md). Stage L done except the deferred L-4 acceptance ([plan](plans/STAGE-L.md), D-31). CP5 is closed.
- **Slice:** feedback round 2 on 0.3.0 ([plans/FEEDBACK-2.md](plans/FEEDBACK-2.md), [D-39, D-40, D-42](DECISIONS.md)): footer chip B, card project label fix, newest-first project groups, Mark as Read, subagent tree, approval-gated "session opens session", and Loom's own `loom:open-session` skill so agents learn the command without vault lines (D-42).
- **State:** 0.3.1 is the daily app ([record](plans/FEEDBACK-2.md#release-031)). After it: D-42 (Loom's plugin skill via `--plugin-dir`) and FB2-7 (the ticket lookup matched the asking session by its title) built, tested and accepted with real Claude (2 short haiku turns: Claude found the skill on its own, Loom showed an open request, a denial was respected); committed and tagged `release/0.3.2`.
- **Next owner:** the planner: install 0.3.2 once the user has quit the running daily Loom (`build.sh` refuses while it runs; the planner never quits it). No vault change (D-42).
- **Open decisions:** [DECISIONS.md → Open](DECISIONS.md#open) and the DP list in RUN-1.
- **Latest result:** [D-42 and FB2-7](plans/FEEDBACK-2.md#agents-learn-the-command-from-loom-d-42).
- **Blocker:** none.
