# Loom agent roles

Shared start, delegation and record rules are in [AGENTS.md](../AGENTS.md). Current work is in [STATUS.md](../STATUS.md); technical working rules are in [DEVELOPMENT.md](../DEVELOPMENT.md).

| Role | Responsibility | Claude Code agent type |
| --- | --- | --- |
| [Planner-reviewer](reviewer.md) | Main agent: plans, delegates, reviews results, keeps the canonical records. | main session |
| [Implementer](implementer.md) | Delivers the Brief's change, runs its checks, reports back. | `implementer` |
| Researcher | Read-only investigation; reports findings with evidence. | `explorer` |
| [Optimizer](optimizer.md) | Before checkpoint closure: structure, maintainability and resource review. `gpt-6-astra` / `high`, or Opus 5.5 / `xhigh` in Claude Code. | `strict-reviewer` with the optimizer Brief |

Claude Code does not load these files; the planner-reviewer restates the needed role rules in each Brief. `reviewer.md` keeps its file name for old links; the role is the planner-reviewer.
