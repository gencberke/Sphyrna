# Rescue Plan (25 Oct 2026)

Why this file exists: on 25 Oct `@user` reported that a short Chat session used 6 % of the Max plan, that Sphyrna's
Energy Impact read 118 on the new-session page and up to 310 in a chat, and that the chat showed raw "Unrecognised
record" rows. `@user` decided to freeze the chat and turn Sphyrna into a terminal-first session manager
([D-100](../DECISIONS.md)), and to run a lighter process ([D-101](../DECISIONS.md)). This plan replaces the 1.7.0 line
of [ACTIVE-PLAN §0.1](ACTIVE-PLAN.md#01-roadmap-after-161-25-oct) until `@user` says otherwise.

Facts are marked with their evidence. Proposals that still need `@user`'s word say so.

---

## 1. What the investigation found

| Question | Finding | Evidence |
| --- | --- | --- |
| Did Sphyrna spend the 6 %? | **No.** The session made 96 model requests in about 8 active minutes: 28 on Opus 5.5 (xhigh) and 68 by two Sonnet `explorer` subagents. The subagents processed about 75 % of the tokens (6.0 M of 8.0 M cache reads). Every request came from the session's own loop; Sphyrna added no call. | `~/.claude/projects/-Users-gencberke-Documents-github-edd-fe/EF766157-….jsonl` and its `subagents/`; `/private/tmp/sphyrna-diag/{analyze,rate}.py` |
| Is the Chat face's mode more expensive? | **No.** Its rate was $0.81 per active minute (API-equivalent at assumed list prices, for comparison only). `@user`'s terminal sessions ran at $0.57–0.76, and subagent-heavy terminal or Desktop sessions at $2.05–2.28. Same permission mode (auto, with the server-side classifier) and the same 1-hour prompt cache as the terminal sessions. Anthropic's support article (updated 7 Oct 2026) says `claude -p` and Agent SDK use draw from the plan exactly like the terminal. | `rate.py` over all transcripts since 27 Sep; `support.claude.com/en/articles/15036540` |
| Did Remora or a background call run? | **No.** Remora's last call was on 23 Oct; no other Claude Code activity is in the transcripts for 22:00–22:42. claude.ai chats are not visible from here. | `~/Library/Application Support/Loom/remora/`, `window.py` |
| Why is a 334-line transcript 7.3 MB? | Claude Code writes it, not Sphyrna. Tool results are stored in full (4.4 MB), and since 2.1.299 every request is also stored as `api-request-*` records (2.4 MB) so resume and fork can rebuild it exactly. Every mode writes them: `@user`'s terminal sessions reach 34 MB and Desktop sessions 209 MB. There is no switch to turn them off. | record sizes in `analyze.py`; `fleet.py`; the CLI binary's transcript reader |
| How big is Claude's storage? | `~/.claude` is 4.7 GB: 1,201 transcripts, 16 of them over 50 MB. **4.2 GB of it is Sphyrna's own development sessions** (`loom-dev`). Claude's 30-day retention works (no transcript is older than 30 days). Sphyrna's own data is about 12 MB. | `du` on 25 Oct |
| Energy | The chat's cost was measured and failed its own rule. At 600 chars/s it used 22 % CPU against the terminal's 6 %, with a peak above 400 MiB against 115 (SPEC §12.1 parity). [D-92](../DECISIONS.md) shipped it anyway. The new-session page at 118 had no Claude process yet (the session started at 22:28), so that number is Sphyrna's own. **Its cause is unknown**: the art measured 3–4 % on screen, which does not explain it. During a chat, Activity Monitor's row also counts Claude Code, its subagents and their commands. | `evidence/core/budgets/BUDGETS-1b974c4.md`; `diagnostics/journal.jsonl` |
| "6 records … raw rows" | Claude Code 2.1.300 sends `system/permission_check_status` in auto mode. Sphyrna's chat drew every unknown record as a row and a banner. Real-CLI checks ran in isolated profiles without auto mode, so they never saw it. | `ChatSessionDriver.noteDrift`, `ChatRowViews.swift:550` |
| Model picker says "Opus" | The CLI's own `initialize` list already carries `resolvedModel` (`claude-opus-5-5`). The chip prints `displayName` instead. T3 Code also keeps a `model-manifest.json` in its repository, fetched hourly with a disk cache and a bundled fallback. That only matters for harnesses without such a list. | `ComposerBarText.swift:55-65`; T3 `apps/server/src/provider/ModelManifest.ts` |
| Size and speed | 117k lines of Swift; **+92k lines in `Sources` since 15 Oct**. Chat is about 28k lines, Remora about 10k, the art about 1.8k. | `git log --shortstat` on `v2` |

**Why the tests missed it:** they tested our code against our own fake provider and fixtures. A new record from the real
CLI, the user's real auto mode and the new-session page's energy were outside what they could see. The one real
measurement that failed (chat parity) was deferred instead of blocking.

## 2. What we can and cannot do

| Sphyrna can | Sphyrna cannot |
| --- | --- |
| Add no model call and no context of its own (SPEC §12.2; held for this session) | Make a Claude session cheaper: the model, effort, subagents and instruction files decide its tokens. Sphyrna can only show where they went. |
| Freeze the chat behind one capability flag, so every session runs in the real terminal | Keep a chat UI in step with every Claude Code release without constant patching. Orca and T3 Code ship almost daily with teams. |
| Measure and fix its own CPU and energy (rendering, art, glass, watchers) | Lower Claude Code's own CPU while it works. It counts under Sphyrna's row in Activity Monitor, and under Terminal's when it runs there. |
| Show each session's disk use and token use, delete with the verified seven-step deletion, and offer Claude's retention setting with consent | Shrink or rewrite Claude's transcripts: editing them breaks resume and fork. |
| Show full model names from the CLI's own list | Promise an energy number before measuring it. |

## 3. Action plan

One planner, one implementer, one slice at a time ([D-101](../DECISIONS.md)). Each slice has narrow checks; the
release gate is Phase B's real measurement on the installed app.

### Phase A: freeze and stop the bleeding (about 1 day)

- **A1. Chat frozen (D-100).** Claude's `structuredFace` is false in `HarnessCapabilities`, so starts, resumes and
  approved openings use the terminal (`FacePolicy`). `readOnlyChatEnabled` is false, so a stopped session shows its
  kept screen or record, and Resume continues it in the terminal. Settings' "Sessions run in" switch is removed. The
  chat-only surfaces (Side, Quick Question, Rewind, pinned request cards, the live composer) become unreachable.
  - The code stays in the tree; deleting it is a later decision.
  - **Done when:** every route of a Claude session lands on the terminal, the kept screen or the record. A test fails
    if a Claude start picks the pipe face.
- **A2. Full model names** in the new-session composer ("Opus 5.5"), from `resolvedModel`.
- **A3. Readers stay tolerant.** The usage index, the subagent tree and the inspector ignore unknown record types
  silently. **Done when:** a fixture carrying `permission_check_status` and an unknown type reads with no error and no
  visible row.
- **A4. Proposed, needs `@user`'s word:** the animated art is off by default (energy), and Remora is off by default (it
  makes its own daily model call on the plan).

### Phase B: real-scenario energy check (half a day; needs `@user`'s word and an idle Mac)

- **B1.** `scripts/perf/real_energy.sh` samples `top -stats pid,command,cpu,idlew,power` every 5 s for Sphyrna, each
  child and WindowServer. `power` is the score Activity Monitor shows.
- **B2.** Scenarios, two minutes each, on the installed app with `@user`'s real profile:
  1. Home, idle.
  2. The new-session page, idle, then while typing. Repeat with the art off.
  3. Sidebar glass, solid and plain transparency.
  4. One terminal session replaying a long output, against the same output in Terminal.app.
  5. Idle while another Claude session writes its transcript.
- **B3.** Any hot scenario gets `sample <pid> 10`, a fix, and the same scenario again.
- **Proposed gate:**
  - idle pages average ≤ 1;
  - typing on the new-session page ≤ 5;
  - Sphyrna's own process ≤ Terminal.app's for the same terminal output.
  - The numbers are `@user`'s to accept.

### Phase C: terminal-first session manager, after Orca's stance (1–2 weeks)

- **C1. Storage you never have to think about.**
  - Each session's and project's size: transcript, subagents, tool results and file history, sortable.
  - Delete through the existing seven-step deletion (SPEC §5).
  - Settings → Sessions shows Claude's retention (30 days by default) and changes it only with consent.
- **C2. Usage per session**, split into the main thread and its subagents, from the existing usage index. The next
  "6 %" then names its own cause.
- **C3. Sidebar** (`@user`'s 25 Oct notes):
  - the header split from the view switch, with each view's own actions (Add Project visible);
  - the session card in three layers: harness, model or project / title / branch;
  - project drag reorder fixed;
  - plain transparency instead of glass.
- **C4. Status truth.** Check what Sphyrna already does against Orca's "silent for N min" state before adding anything.

Each slice: one implementer, its narrow suite, then `@user`'s hand check on a package. If a slice touches rendering,
Phase B's script runs again.

### Frozen (not now)

- Chat, live and read-only.
- 1.7.0: the session channel and Codex's binding.
- New Remora features and new art.
- New evidence suites and optimizer rounds.

## 4. Open questions for `@user`

1. A4: should the art and Remora be off by default, or removed?
2. Is it acceptable that old sessions are read by resuming them in the terminal, with no separate reader?
3. Are Phase B's gate numbers acceptable?
4. Is Phase B approved on the installed app, and when is the Mac idle?
