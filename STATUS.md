# Status

- **Updated:** 2026-10-08
- **Stage:** multi-agent run 1 (F, I, U, CP4), branch `swarm/1`; index and protocol [plans/RUN-1.md](plans/RUN-1.md). Stage L done except the deferred L-4 acceptance ([plan](plans/STAGE-L.md), D-31). CP5 is closed.
- **Slice:** day-one feedback on 0.2.1 ([plans/FEEDBACK-1.md](plans/FEEDBACK-1.md), [D-37](DECISIONS.md)): fixes on `swarm/1` (`955b326` resume state and effort, `bd22b90` sidebar/detail and manual delete, `6d487b4` usage and plan limits, `8e9ff0b` activity time, `ed2914c` wording, `b997885` idle stop off (D-38), `ee0fea1` sidebar toggle, `1681f0f` pre-release review fixes), released as **0.3.0**.
- **State:** 0.3.0 installed as the daily app (`release/0.3.0` → `1681f0f`, loom `e392d7c` / `v0.3.0`); verified by tests, a mutation check of the review fixes, the real-Claude resume check (9/9, before the review fixes) and an isolated launch of the installed app; the full release suite was not run (user's choice). Earlier: F0–F6, I1–I3, U0, U3, U12, U4, U5, UD, CP4-A–G, OPT1, OPT2 accepted; I4 and the visible-window measurements parked.
- **Next owner:** the user: daily use of 0.3.0 and the next feedback; open: model-scoped weekly windows in the chip, the project-name screenshot ([FEEDBACK-1](plans/FEEDBACK-1.md#open-points-for-the-user)); with an unlocked idle Mac: the full release suite, the visible checks and the eye checks.
- **Open decisions:** [DECISIONS.md → Open](DECISIONS.md#open) and the DP list in RUN-1.
- **Latest result:** affected suites 47 + 45 passed on `1681f0f`, each new review test fails without its fix; installed `/Applications/Loom.app` 0.3.0: signature ok, no evidence code, isolated launch ok ([record](plans/FEEDBACK-1.md#release-030)).
- **Blocker:** none.
