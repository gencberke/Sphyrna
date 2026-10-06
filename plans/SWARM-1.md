# Multi-agent run 1 — prompt and authority

The prompt below starts the first multi-agent run from a fresh session in loom-dev, after stage L (the clean `Loom.app` 0.1.0) is done. Authority for the run comes from the user's decisions of 6 Oct 2026 ([D-30](../DECISIONS.md)). Paste the block as the first message of the session.

```text
ultracode

You are the planner-reviewer (main agent) of Loom in this repository (loom-dev). Start as CLAUDE.md says: STATUS → AGENTS → ROADMAP → DECISIONS. This is multi-agent run 1 (plans/SWARM-1.md): take Loom from the closed CP5 state to "almost release": plan and implement the next stages, and evaluate UI/UX, architecture/scalability and performance along the way.

PRECONDITION
- Stage L must be done (Loom.app 0.1.0 built from the clean loom tree, installed and accepted; plans/STAGE-L.md). If it is not, stop and do L with me first.

SCOPE (ROADMAP.md is the source; in this order of planning, parallel where write areas are disjoint)
1. Plan first: write plans/STAGE-F.md, plans/STAGE-I.md and plans/CHECKPOINT-4.md (+ slice files) with goals, slices, acceptance criteria, dependencies and write areas. Then execute.
2. F — foundation hardening (ROADMAP F): Codex surfaces out of the production build, quit path off TerminalRunController, evidence/fixture code separated from production paths, large actors split only where it reduces coupling, one local check command, deferred optimizer items taken or dropped. No behavior change.
3. I — identity and UI system (ROADMAP I): identity direction A (D-22) into one token source and design/DESIGN.md, the indicator WindowServer cost (R-A), every surface in design/UI-MAP.md reviewed against the identity, accessibility pass.
4. CP4 — deletion and retention (D-26): permanent deletion of one conversation first (contract §8), then stale handling, retention and cleanup (contract §3, §5); recovery from half-done deletes; nothing ever harms another conversation.
5. Evaluations at every stage end: UI/UX review against DESIGN/IDENTITY/UI-MAP with evidence screenshots, architecture/scalability review, performance regression against the package I baseline (DEVELOPMENT.md §7; CPU40 must hold). The optimizer (Opus 5.5 / xhigh, AGENTS.md) runs before any stage or checkpoint closes.

OUT OF SCOPE
- Codex (frozen, D-28), CP3 (D-27), other providers, distribution/notarization (stage R), contract §13 ideas.

AUTHORITY FOR THIS RUN (D-30)
- The Mac is idle for the whole run: full suites, window tests, packaging and measurements may run without asking. Builds stay strictly serialized (one build slot), each agent with its own scratch path outside ~/Documents; 90 s cooldown between heavy measurement cells.
- Commits: create branch swarm/1 from the current branch; commit each slice when you accept it (one commit per accepted slice, English message, Co-Authored-By line). No push, PR, merge, rebase, tag or history rewrite. Never commit unaccepted work.
- Real Claude: short acceptance turns only, about 40 in total for the whole run; keep a running count in the plan files; when it is used up, stop real-model checks and list what remains.
- Improvements: make clear UI/UX, code and performance improvements inside the scope without asking.
- Do NOT decide for me: anything in DECISIONS.md "Open", contract §3 changes, design-rule changes, and product choices CP4 needs (e.g. contract §12 items 3–4: deletion data contract, cleanup arithmetic). Record each as a decision point with a recommendation in the stage plan, continue with other work, and use the documented defaults meanwhile (A's values for O-12; transparent header for O-03; no automatic deletion until cleanup rules are decided).
- Never touch my installed Loom.app, Loom Dev.app, their data, the default dev catalog, ~/.claude or ~/.codex. Test with packages under ~/Library/Application Support/Loom-Dev/packages/. Do not promote or install a new daily release; at the end prepare a release candidate note (what would go into 0.2.0) for me to decide.

HOW TO RUN
- Orchestrate each phase with workflows; stay in the loop between phases and review the combined result yourself. Disjoint write areas per agent; you alone write STATUS, ROADMAP, DECISIONS and plans; subagents report Doc impact and you keep docs/ARCHITECTURE.md, design/* and DEVELOPMENT.md true.
- Verify behavior, not reports: a slice is accepted only with passing checks and evidence (DEVELOPMENT.md); regression tests must fail without the fix.
- Do not loop: if a slice fails acceptance three times or is blocked on a decision, park it with its findings and move on.
- Update STATUS.md at every phase boundary so a new session can resume from it.

FINISH
- Stop when every planned slice is accepted or parked. Then give me a short Turkish summary: what was done and accepted (with commits), measurements against the baseline, parked items and why, the decisions I need to make (with your recommendation), and the 0.2.0 release-candidate note.
```
