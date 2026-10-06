# Loom — Claude Code entry

The repo workflow is in [AGENTS.md](AGENTS.md). If it is not already in your context, read it at session start.

Main session: start with [STATUS.md](STATUS.md) → [AGENTS.md](AGENTS.md) → [ROADMAP.md](ROADMAP.md); check [DECISIONS.md](DECISIONS.md) before assuming scope or permissions. Subagent: your Brief is your task; read the docs it names plus DEVELOPMENT.md §2–§4 before building or testing.

Hard rules (details in AGENTS.md and DEVELOPMENT.md):
- Real `~/.claude` / `~/.codex`, the installed `Loom Dev.app`, the default dev catalog and the daily `Loom.app` are never test material; the clean loom tree is written only by the promote step.
- No parallel builds; heavy tests and on-screen measurements only when the user says the computer is idle.
- Keep other agents' changes; never stash, reset, checkout or clean them. No commit, push or PR unless the user asks.
- Only the main session writes STATUS, ROADMAP, DECISIONS and plans (subagents may write evidence files their Brief assigns); subagents report Doc impact.
- Docs and code in English; talk to the user in Turkish.
