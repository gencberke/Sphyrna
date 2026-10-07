# Status

- **Updated:** 2026-10-08
- **Stage:** multi-agent run 1 (F, I, U, CP4), branch `swarm/1`; index and protocol [plans/RUN-1.md](plans/RUN-1.md). Stage L done except the deferred L-4 acceptance ([plan](plans/STAGE-L.md), D-31). CP5 is closed.
- **Slice:** day-one feedback on 0.2.1 ([plans/FEEDBACK-1.md](plans/FEEDBACK-1.md), [D-37](DECISIONS.md)): fixes committed on `swarm/1` (`955b326` resume state and effort, `bd22b90` sidebar/detail and manual delete, `6d487b4` usage and plan limits, `8e9ff0b` activity time, `ed2914c` wording); 0.2.1 is still the installed daily app.
- **State:** feedback fixes verified by tests, the staged release tree and a real-Claude resume check (9/9); not yet tagged, promoted or installed. Earlier: F0–F6, I1–I3, U0, U3, U12, U4, U5, UD, CP4-A–G, OPT1, OPT2 accepted; I4 and the visible-window measurements parked.
- **Next owner:** the user: the open points in [FEEDBACK-1](plans/FEEDBACK-1.md#open-points-for-the-user) (idle auto-stop, plan-limit cadence, sidebar details, screenshot) and the word to tag, promote and install the next version; with an unlocked idle Mac: the full release suite, the visible checks and the eye checks.
- **Open decisions:** [DECISIONS.md → Open](DECISIONS.md#open) and the DP list in RUN-1.
- **Latest result:** real Claude `claude_resume_real.py` 9/9 on `packages/fb1-candidate` (Ready after resume, effort max kept); debug suites 452 + 246 passed; `--release-tree` passes. Installed: `release/0.2.1` → `/Applications/Loom.app` 0.2.1.
- **Blocker:** none.
