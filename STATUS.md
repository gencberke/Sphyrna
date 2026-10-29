# Status (Live Relay Board)

- **Updated:** 2026-10-29,05:21 +03.
- **State:** `waiting for implementation`. Active overnight goal D-112: a daily-use-ready, trustworthy local1.8.0 by morning. The planner is the main technical authority. Pi is deferred (D-113). Acceptance order/evidence: [plans/1.8.0/ACCEPTANCE.md](plans/1.8.0/ACCEPTANCE.md).
- **Power/window:** @user is asleep, Mac idle and left on; AC is now verified80%, attached/not charging. Earlier current-continuation battery exception remains recorded; thermal checks,90s heavy-cell cooldowns and one build slot still apply.
- **Current work:** F0 foundation/provenance is integrated0c9b2a8; D2 reader source is integratedbe3e17a; resolved-profile/account-revision wiring and optional native counter fixes pass19 connected tests +3 revision consumer checks. D1 real T10 now reaches exact native identity and command approval; its strict test validator rejects additional native metadata before approving anything. Owned process/socket cleanup independently verified. F1 core and agent UI run in separate trees; parent owns their combined acceptance.
- **Installed/public:** daily app1.7.2 build10702; public release0.4.4. The local1.8 goal adds no public GitHub publication instruction. The clean loom tree is written only through the release flow.

## Current checkpoints

- `v2` X1 code26088a1: X1 compact reference cards/whole child surface/icons/pin;65 integrated tests PASS.  B3b one bottom barf3d4f01 plus deferred Help fixf0d9117. Slice93 tests, integrated scoped/window29, then fix14 pass. Actual signedf0d9117 PID19564 passed Help AX open/Escape with sidebar open, collapsed and after native fullscreen enter/exit; calls return0.5–0.7s. It quit normally; process absent/default Dev metadata unchanged. Evidence `evidence/r9/b3b/`.
- D1 source4cda375 +opt-in test67e5896: neutral Codex first-message/settings, same-native safe resume and exact owned socket cleanup. Hostile native reviewer/network/roots were a real gap;10 zero-turn disposable-profile cells support invocation-only hardening.114 affected tests pass, cleanup fix4 pass; original220-Core combined verdict remains FAIL with scoped fixes. Real first-prompt and exact-leader acceptance remain unverified. T8 failed before identity (one input conservatively unknown); Z1–Z8 sent zero user inputs. The remote TUI rejects the CLI roots override; removing only that pair reaches native folder trust/terminal queries. No trust/config bypass. Original opt-out SKIP is preserved. Evidence `d1/startup-zero/REPORT.md`.
- A1bf8adc58:50 connected tests +actual Ink/Paper distinct draft-row/selection PASS; tree/scratch removed. B4 native picker fix0c8a0b2:47 tests +actual signed window/keyboard PASS. B5ae618124:117 connected PASS; B5b339929d:156 connected PASS. Its strict first-screen/RSS equivalence remains unproved (about5.6–6.0MB higher RSS); energy still required.
- Earlier offscreen pool3560 tests had3 failures; affected112 later pass. Preserve the pool's FAIL and scoped evidence; do not relabel it. Earlier broader UI collision/fixture/native failures remain in their reports.
- P0:7 submitted Codex inputs +1 auxiliary held conservatively. D-112 now authorizes short cheap turns as needed; reservations and per-turn/usage accounting remain. T8/T9 are closed failed/unknown, with at most one input held each; T10 reached native approval but no action was accepted and closed with verified cleanup. Its exact owned rollout confirms one reserved input plus native environment context (not a second user turn). No active model-input reservation. Ledger `evidence/r9/REAL-TURN-BUDGET.md`.
- T3/Orca source/multi-round reports are complete. Stable child vs fresh round, repeated notifications and explicit cancellation scope are checked. F0 source seam map is complete. P1 OpenCode2.2 metadata and exact owned loopback server/provider/model endpoints pass with zero model inputs; no system/MDM source exists. Preliminary process-group cleanup is proved, detached containment still pending E1. AGY sandbox metadata fixture aborted even its positive canary and proves no usable isolation; no AGY model input. No Pi execution/integration.

## Worktrees and locks

| Tree | Branch/HEAD | Owner and state |
| --- | --- | --- |
| `~/Library/Caches/loom-v2/wt/v2` | `v2`,be3e17a | planner; D2 reader integrated; parent profile/revision fixes verified, checkpoint being recorded |
| `wt/r9-d1` | `slice/r9-d1`,8de841a | parent; real T10 reached approval, validator metadata follow-up before rerun; no active model reservation |
| `wt/r9-d2-reader` | `slice/r9-d2-reader`,d49212d | immutable accepted reader source, integratedbe3e17a; recovery cleanup pending |
| `wt/r9-f1-ui` | `slice/r9-f1-ui`,2838d74 plus edits | warmb3_ink; task metadata rows/detail, sidebar/Agents/Overview leaves only |
| `wt/r9-f1` | `slice/r9-f1`,b987b77 plus edits | warmc4_core; runtime/CLI, exact input proof, ingress/write fences and existing terminal-sink launch; fake-only checks |
| `wt/r9-f0` | `slice/r9-f0`,0e466de | immutable integrated foundation/provenance source; recovery cleanup pending |
| `r9-b3b`, `r9-x1` | removed after source equivalence/recovery verification | recovery bundles/manifests in each evidence folder |
| `~/Documents/github/loom-dev` | `swarm/1` | guarded canonical/reference mirror only, never Sources/build/commit |
| `~/Documents/github/loom` | `main` | separate clean release repository, no test material |

At most2 implementation slices. Every build/test/package/measurement uses the shared slot with timeout600 or the normal longer default; no parallel build. Each active tree has its own scratch outside Documents. Parent owns canonical/reference files, real-turn ledger, acceptance runs and integration. The earlier unflagged CUA auto-relaunch touched default Dev WAL/SHM metadata; contents are **unverified**, not rolled back or declared unchanged. Later guarded runs do not erase that incident.

## Next actions by role

- **@planner:** finish real D1 approval schema validation and first-message/settings/Stop→same-native Resume→Quit acceptance, then integrate. Finish D2 production resolved-profile/revision wiring and its affected checks. Review F1 core/UI together and prove real three-round cross-harness behavior. Continue E1/E2, deletion, F2/G1/H1/I1 and the complete acceptance matrix; no unsupported feature is considered done.
- **@implementer-ink warmb3_ink:** F1-UI self-contained Brief in chat, r9-f1-ui only. Name/harness/model branches, exact child UUID selection using existing terminal preference, bounded explicit results/attention. No Chat lifecycle handover, core/runtime, canonical or other consumer writes.
- **@implementer-core warmc4_core:** F1 core self-contained Brief in chat, r9-f1 only. Native fake three-round task flow, per-run authority and input provenance, ingress/write-boundary admission fences, terminal-owned children using the existing SessionService real sink. No real models or shown windows.
- **@researcher warmorca_cross_agents:** read-only pinned Codex0.164 command-approval metadata/authority investigation for parent validator. OpenCode2.2 local one-shot wire fixture preparation is complete; parent owns native execution. Pi deferred.
- **@optimizer:** once complete candidate exists, gpt-6-astra/xhigh or Opus5.5/max; all code through1.8.0 is in scope, including earlier code. Then planner fixes findings, checks docs and briefs the existing open Claude session for independent final planner-reviewer/optimizer critique. Preserve that session's permissions/effort and consider Claude usage; its delegated subagents at least Opus5.5 high.
- **@user:** no repeated routine permission request. Login remains user-owned if a genuine isolated-profile sign-in is needed. Cheap turns are now authorized as needed; Codex full reset may be used at3–4% remaining. Baseline at goal creation55% used/45% remaining, reset1available.

The complete slice table is in [plans/ACTIVE-PLAN.md](plans/ACTIVE-PLAN.md); individual reports and failures live in `~/Library/Caches/loom-v2/evidence/r9/`, not in this relay.
