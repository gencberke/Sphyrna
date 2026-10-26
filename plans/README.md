# Plans Index

Current position and handoff queue live in [STATUS.md](../STATUS.md). Product and behavioral rules live in [SPEC.md](../SPEC.md). Decisions live in [DECISIONS.md](../DECISIONS.md). Read historical plans under `archive/` only when a task explicitly points to one.

---

## 1. Active Plan & Live Evidence

| File / Directory | Purpose |
| --- | --- |
| [ACTIVE-PLAN.md](ACTIVE-PLAN.md) | **Canonical active execution plan.** §0 holds round 5 (1.6.1, [D-93](../DECISIONS.md)). §0.1 holds 1.6.2 as built, what comes next, and the hand checks on the installed app. The rest is the 1.6.0 record ([D-68](../DECISIONS.md), [D-83](../DECISIONS.md)): founding goals, acceptance criteria, the closed Releases A–C, the slice tables, and the 11-step End Batch Runbook. |
| [FEEDBACK-6.md](FEEDBACK-6.md) | **Round 6 on 1.7.0** (26 Oct 2026): `@user`'s notes after a day of real use, a health check of the logs, the sessions and the processes, what the code says, the proposals (the model and effort panel, the harness catalogue, the sidebar's fill and opacity), the decisions waiting for `@user`, and the plan for 1.7.1 and 1.8.0. |
| [FEEDBACK-5.md](FEEDBACK-5.md) | **Round 5 on 1.6.0** (24 Oct 2026): `@user`'s notes, what the code says, the studies of other apps and of Chat's streaming cost, the decisions ([D-93](../DECISIONS.md) to [D-99](../DECISIONS.md)), and the plan for 1.6.1 and 1.6.2. Its slices move into [ACTIVE-PLAN.md](ACTIVE-PLAN.md) on `@user`'s go. |
| [RELEASE-NOTES-1.6.1.md](RELEASE-NOTES-1.6.1.md) | **Release notes of Sphyrna 1.6.1** (draft, 24 Oct 2026): what the user gets, grouped as Fixes, Drag and drop, Flow, Look and Chat, with one line on going back to 1.6.0, which keeps one draft per project. Written for the GitHub release; the push waits for `@user`. |
| [RELEASE-NOTES-1.6.2.md](RELEASE-NOTES-1.6.2.md) | **Release notes of Sphyrna 1.6.2** (draft, 25 Oct 2026): what the user gets, grouped as Connections, Usage, Models, Flow and Fixes, with one line on going back to 1.6.1, which ignores the two new preferences keys. Written for the GitHub release; the push waits for `@user`. |
| [RESCUE-PLAN.md](RESCUE-PLAN.md) | **The rescue** (25–26 Oct 2026): why the chat was frozen ([D-100](../DECISIONS.md)), what Sphyrna can and cannot do about cost, energy and storage, Phases A–C, and §5's overnight status. It replaced D-93's 1.7.0 line. |
| [RELEASE-NOTES-1.7.1.md](RELEASE-NOTES-1.7.1.md) | **Release notes of Sphyrna 1.7.1** (26 Oct 2026): round 6 ([FEEDBACK-6](FEEDBACK-6.md), D-103): sessions (Ready with "N background", opened sessions with their own choices, `whoami`, the request card), the sidebar (drag, fill and opacity, a line per harness), the Agents view and Overview, Remora, energy and names. |
| [RELEASE-NOTES-1.7.0.md](RELEASE-NOTES-1.7.0.md) | **Release notes of Sphyrna 1.7.0** (draft, 26 Oct 2026): terminal first, storage and usage, sidebar, look and energy, with one line on going back to 1.6.2. Written for the GitHub release; the push waits for `@user`. |
| `~/Library/Caches/loom-v2/evidence/` | Track plans (`ink/PLAN.md`, `core/PLAN.md`), `core/END-BATCH-RUNBOOK.md`, `ink/evening-queue.md`, slice Briefs, resume notes (`ink/l3b-home-resume.md`), `@opencode` logs (`oc/`), and run evidence. |
| [experiments/](experiments/) | Value-free benchmark baselines (`cp5-final-matrix-I-20261006.json`, `run1-F5-launch.json`, `run1-U4-tab-switch.json`, `run1-CP4E-real-deletion.json`), v2 spikes (`v2-spikes/S0`..`S9`), and planning scans (`v2-planning-scans/`). **Kept at `plans/experiments/` because measurement and acceptance scripts reference this path directly.** |

---

## 2. Archived Plans & Research (`plans/archive/`)

All completed checkpoint plans, pre-1.6.0 stage logs, brainstorms, and pre-reorganization document snapshots are preserved in [archive/](archive/):

| Archived Path | Era / Milestone | Notes |
| --- | --- | --- |
| [archive/V2-PLAN.md](archive/V2-PLAN.md), [archive/v2/CHAT-SPEC.md](archive/v2/CHAT-SPEC.md) | Loom v2 Releases A, B, C & 1.6.0 log | Distilled into [ACTIVE-PLAN.md](ACTIVE-PLAN.md) and [SPEC.md](../SPEC.md). |
| [archive/v2-research/](archive/v2-research/) | v2 Concept, Remora brainstorm (`LOMBOT-BRAINSTORM.md`), product studies | Pre-v2 research and brainstorms ([D-57](../DECISIONS.md) to [D-67](../DECISIONS.md)). |
| [archive/CHECKPOINT-1.md](archive/CHECKPOINT-1.md) | CP1 Process ownership & launch | Closed Sep 2026. |
| [archive/CHECKPOINT-2.md](archive/CHECKPOINT-2.md) | CP2 State & resume | Closed Sep 2026. |
| [archive/CHECKPOINT-4.md](archive/CHECKPOINT-4.md), [archive/cp4/](archive/cp4/) | CP4 Deletion & retention (`A.md`–`G.md`) | Built in Run 1 ([D-37](../DECISIONS.md)). |
| [archive/CHECKPOINT-5.md](archive/CHECKPOINT-5.md), [archive/CHECKPOINT-5-HISTORY.md](archive/CHECKPOINT-5-HISTORY.md), [archive/cp5/](archive/cp5/) | CP5 Terminal engine, CPU40, `CODEX-BACKLOG.md`, `RESOURCE-BUDGET-PROPOSAL.md` | Closed 6 Oct 2026 ([D-23](../DECISIONS.md)). |
| [archive/STAGE-L.md](archive/STAGE-L.md) | Stage L Clean `loom` release tree (`0.1.0`) | Closed 7 Oct 2026 ([D-25](../DECISIONS.md)). |
| [archive/RUN-1.md](archive/RUN-1.md), [archive/RC-0.2.0.md](archive/RC-0.2.0.md) | Multi-agent Run 1 (`0.2.0`) | Closed 7–8 Oct 2026 ([D-36](../DECISIONS.md)). |
| [archive/STAGE-F.md](archive/STAGE-F.md), [archive/f/](archive/f/) | Stage F Foundation hardening (`F0`–`F6`, `OPT1`, `OPT2`) | Closed in Run 1. |
| [archive/STAGE-I.md](archive/STAGE-I.md), [archive/i/](archive/i/) | Stage I Identity A (Night Fleece, `I1`–`I4`) | Superseded by Ink v3 ([D-74](../DECISIONS.md)). |
| [archive/STAGE-U.md](archive/STAGE-U.md), [archive/u/](archive/u/) | Stage U Daily-use UI (`U0`–`U5`, `UD`) | Closed in Run 1. |
| [archive/FEEDBACK-1.md](archive/FEEDBACK-1.md) .. [archive/FEEDBACK-4.md](archive/FEEDBACK-4.md), [archive/GLASS-TRIAL.md](archive/GLASS-TRIAL.md), [archive/HARDENING-1.md](archive/HARDENING-1.md) | Releases `0.3.0` to `0.4.4` | Closed 8–14 Oct 2026. |
| [archive/DEVELOPMENT-STARTUP-ISOLATION.md](archive/DEVELOPMENT-STARTUP-ISOLATION.md) | Pre-CP1 startup rc note | Superseded by run scopes. |
| [archive/pre-reorg-20261022/](archive/pre-reorg-20261022/) | Pre-reorganization snapshots | Exact copies of `LOOM-PRODUCT-CONTRACT.md`, `ROADMAP.md`, `design/UI-MAP.md`, and `agents/` before the 22 Oct 2026 documentation consolidation. |
