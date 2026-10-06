# CP4-E — real-Claude deletion check

[Checkpoint 4](../CHECKPOINT-4.md) · wave 5 · protocol: [RUN-1](../RUN-1.md#protocol-for-every-implementer-slice). Depends on CP4-D. Real-Claude budget: 4 short turns.

## Goal

Prove contract §11 row 4 on real Claude data in the isolated profile.

## Steps

1. Package the combined tree (`run1-CP4E-candidate`). Evidence run with `--claude-config "~/Library/Application Support/Loom-Dev/probe/claude-config"`, isolated `--data-root`, workspace `probe/workspace`.
2. Conversation A: one short turn that also creates a subagent and a file edit if possible within the budget ("Use a subagent to create a file named loom-cp4-a.txt containing OK, then reply DONE" — model haiku; if subagents are not created, record it). Conversation B in the same project: one short turn.
3. Hash every file of B and every shared file (`history.jsonl`, `.claude.json`, `projects/*/memory`) — names and hashes only, never contents into evidence.
4. Delete A through the evidence `delete:` command; wait for completion.
5. Verify: `find <config> -iname '*<A id>*'` empty (except the documented residuals), B and shared hashes unchanged except files Claude itself rewrote (`.claude.json`, `history.jsonl` appends — compare B's lines are still present by count), `CLAUDE_CONFIG_DIR=<probe> claude --resume <A id> --print` or the interactive equivalent reports no conversation without a model call, catalog has no A rows, relaunch shows no A.
6. Write `plans/experiments/run1-CP4E-real-deletion.json` (value-free) and update the turn ledger in `plans/RUN-1.md` via your Report (the planner-reviewer writes the ledger).

## Scope

Write: `scripts/cp4-deletion-real.py` (style of `scripts/perf/claude_real.py`: `--app` required, refuses the installed app and `~/Documents`), the evidence file. Out of scope: code changes (report bugs instead).
