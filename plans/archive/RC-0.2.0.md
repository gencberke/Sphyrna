# Release candidate 0.2.0 — note for the user's decision

Multi-agent run 1 ([RUN-1](RUN-1.md), [D-35](../DECISIONS.md)). Written overnight as the decision input; the user accepted it on 7 Oct ([D-36](../DECISIONS.md)).

**Superseded on 8 Oct by 0.3.0** ([FEEDBACK-1](FEEDBACK-1.md#release-030)). **0.2.1** (installed 7 Oct 09:40, `release/0.2.1` → `c57342f`, loom `70903a8` / `v0.2.1`; [hotfix below](#021-hotfix-option-keys)), same checks as 0.2.0 plus the Option tests. **0.2.0 installed 7 Oct 2026, 09:05:** tag `release/0.2.0` → `da413c7`; promoted into loom as `d154ebf` / `v0.2.0` (223 files, identical to the verified candidate tree); `/Applications/Loom.app` 0.2.0 (`d154ebf`) built by the loom tree's `build.sh`, deep-strict signature verified, same file layout as the candidate, no evidence code; an isolated launch smoke of the installed binary (own data root, empty Claude profile) created catalog v3, exited cleanly and left no process, preferences file, `~/.loom` or data folder behind. The commands below are the record of what ran.

## The candidate

- **Bundle:** `~/Library/Application Support/Loom-Dev/packages/run1-rc/Loom.app` — `local.loom.desktop`, version 0.2.0, signed with `Loom Dev Code Signing`.
- **Source:** loom-dev `swarm/1` at `da413c7` (later commits on `swarm/1` change only docs), exported through the real promote path (`scripts/release/promote.sh`) in a throwaway clone (`~/Library/Caches/loom-run1/rc/`), then the loom tree's `build.sh --target`. The tag existed only in that clone; loom-dev and `~/Documents/github/loom` are unchanged.
- **Why not install this bundle directly:** its `CFBundleVersion` names the throwaway loom commit. The daily app should come from your loom tree (D-25, D-29); the commands below rebuild the same sources there.

## What 0.2.0 contains (since 0.1.0)

Production app (`local.loom.desktop`):

- **Claude only.** Codex is gone from menus, starts and resume (D-14, D-28); a Codex record says why it cannot be resumed.
- **Identity A (Night Fleece).** Dark appearance, accent colour and voice from [DESIGN §6](../design/DESIGN.md#6-identity-a--night-fleece); errors read as sentences.
- **Settings window** (Cmd+,; General · Usage · About) with a **usage and cost view** for the active Claude profile: 24 h / 7 d / 30 d / 90 d totals, bars, per-model table, five-hour activity cells, cost marked "est." from a dated price table. Read locally and incrementally from Claude's own transcripts into `usage-index.sqlite3` in Loom's data folder; no CLI runs, no network.
- **Sidebar footer** with the usage chip, New Conversation and Settings.
- **Conversation tabs** above the terminal: pinned tabs plus one transient tab, Open in Tab, double click pins; Shift+Cmd+] / [ and Ctrl+Tab / Ctrl+Shift+Tab, Close Tab Opt+Cmd+W (closing a tab never stops a run).
- **Daily-use polish:** relative times and day headings tick while the window is active; the window frame is remembered (`ui-preferences.json`, not NSUserDefaults); "Preparing Claude…" while a start resolves.
- **Keyboard and accessibility:** Cmd+F focuses search, Esc returns to the terminal; Return no longer approves a request above a live terminal; VoiceOver headings and buttons; Increase Contrast and Reduce Motion respected for selection and banners (opacity only); the working indicator keeps running under Reduce Motion (user decision, 6 Oct).
- **Pin / Unpin** a conversation (card menu).
- **Speed and robustness:** launch to first page at 10k rows 196 → 164 ms; git branch reads off the main thread; quit no longer goes through the old synthetic terminal controller; single-process reads; idle environment scopes are released; undecodable catalog rows are skipped instead of failing the list.
- **Catalog schema v3** (one-way migration on first launch; 0.1.0 cannot open the migrated catalog — DP-CP4-4).

Present in the code, **off in production** until you decide DP-CP4-1 (deletion data contract): permanent deletion of a conversation (confirm sheet, progress, failure banner, Try Again, recovery after a crash) and the stale-conversation cleanup review. Development builds (`Loom Dev`) offer both. Nothing deletes automatically in any build.

Not in 0.2.0: Codex, CP3, the navbar decision (O-03; transparent header kept), plan limits (DP-U4), the I4 indicator frame-rate change (parked).

## Verification

All on 7 Oct 2026 with the screen locked (the user's bedtime), so nothing that needs a visible window was measured.

| Check | Where | Result |
| --- | --- | --- |
| Full release suite (`swift test -c release`, the 4 window tests skipped) | combined tree `f34667d` | 654 tests in 4 targets; 1 failure: `SessionRuntimeCodexRecoveryTests.resumingTheOldCardAfterNewKeepsTheMovedRunsServer(scoped: true)` (a Codex server count read right after Stop, under full-suite load); 3/3 green alone; Codex only (hidden in production) |
| After OPT2 and the CP4-E fix | `da413c7` | `LoomCatalogUITests` 208, `LoomLaunchOptionsTests` 8, `SessionCatalogV3Tests` + `ConversationDeletionTests` 37 (debug); staged release tree builds with no evidence code; theme guard and `git diff --check` clean |
| Bundle | `run1-rc/Loom.app` | `codesign --verify --deep --strict` passes; `local.loom.desktop` 0.2.0, hardened runtime, `Loom Dev Code Signing`; run host requirement = identifier + certificate leaf; no evidence, test-child or `--codex-home` strings; 19 MB |
| Launch smoke | `run1-rc/Loom.app`, isolated `--data-root` and an empty `CLAUDE_CONFIG_DIR` | starts and stays up; creates catalog schema v3 and `usage-index.sqlite3` in the isolated folder; exits on SIGTERM with no process left; no `local.loom.desktop` preferences file, `~/.loom` or `~/Library/Application Support/Loom` created |
| Real Claude (`claude_real.py`, 2 turns) | dev package `run1-final-candidate` (same sources plus the evidence tooling) | 11/11: reply, working and turn-done indicators, truecolor, approval on the card, background reply, background job inside the run scope, Stop empties the scope, Quit, outsider untouched; one idle Claude in the active window 0.92 % CPU, 69.5 MiB |
| Real-Claude deletion (`cp4-deletion-real.py`, 2 turns) | same package | 33/33, including no id bytes in the catalog files after the deletion ([evidence](experiments/run1-final-CP4E-rerun.json)) |
| CPU, hidden window, stream1, against package I | same package and `cp5-I-reference` | app CPU 3.42 / 3.47 % against 3.34 / 3.38 % (total Loom 4.89 / 4.96 against 4.93 / 4.84), alternating cells with 90 s cooldowns: equal within noise; package I baseline 3.52 / 5.16 ([evidence](experiments/run1-final-evaluation.json)) |

Real-Claude turns in the whole run: 8 of about 40 ([ledger](RUN-1.md#real-claude-budget)).

Not verified (needs you, an unlocked screen or an idle Mac):

- The visible-window matrix with CPU40 (`scripts/perf/run-final-matrix.py --app <run1-final-candidate> --reference-app <cp5-I-reference>`), the indicator cost and I4 (parked).
- The 4 window tests and `DefaultActionTests` (`scripts/check.sh --full --idle`).
- Eye checks: hover, menus, glass and motion; the production menu bar; "Preparing Claude…" in the header row; tab strip with VoiceOver; Approve and the rename sheet; dark alerts and open panels; the terminal panel colour in a real window capture (evidence screenshots draw it white).

## Known limits and open points

- **Deletion is off in production** until DP-CP4-1; the cleanup review too. To use deletion now, use a development package.
- **Data:** the installed 0.1.0 has never been started on this Mac (`~/Library/Application Support/Loom` does not exist), so 0.2.0's first launch creates a fresh v3 catalog; there is nothing to migrate today. Any later 0.1.0 catalog would migrate one way (DP-CP4-4).
- **Usage view:** reads the profile in Loom's own environment (`CLAUDE_CONFIG_DIR`, else `~/.claude`); a `CLAUDE_CONFIG_DIR` set only in your login shell is not seen by a Finder-launched Loom (DP-CP4-8 has the same root). A profile with no transcripts shows "Indexing…" briefly on each launch. Raw usage rows are not pruned (~106 bytes per message).
- **Keyboard:** on a Turkish layout macOS shows the bracket tab shortcuts as ü / ğ; Ctrl+Tab works on every layout.
- **Day one in the production identity** (found by the post-install verification): macOS asks once for folder access for both "Loom" and "Loom Run Host" (the helper that runs the shell and Claude); an unanswered prompt makes the first start time out after 30 s, retry after answering. Cmd+Q stops every running conversation without asking (Cmd+W only closes the window); a conversation nobody views or types into for 60 minutes is stopped automatically and resumes with Cmd+R. Nothing can be removed in the production app yet (deletion is off), so use a throwaway project for experiments. AppKit may write `~/Library/Preferences/local.loom.desktop.plist` (open-panel state) and saved state for the Settings window; Loom's own settings stay in `ui-preferences.json`.
- **0.2.0 only: Option keys.** Option was always Meta in the terminal, so on the Turkish Q layout `@ [ ] { } \ | ~ €` and the dead keys (backtick, accents) could not be typed (Option+Q sent ESC q). Workaround in 0.2.0: Cmd+Option+O in a terminal turns Meta off for that terminal. Fixed in [0.2.1](#021-hotfix-option-keys).
- **Tests:** one Codex-only test is load-sensitive in the full suite (above).
- **Not in this run's control:** your global macOS preferences were wiped by an agent at about 02:45 ([RUN-1 → Incidents](RUN-1.md#incidents)); restore them in System Settings. Loom 0.2.0 forces the dark appearance for itself, so its look does not depend on them.

Decisions waiting for you are in [RUN-1 → decision points](RUN-1.md#decision-points-for-the-user); the defaults listed there are what 0.2.0 does. The ones that change what ships: DP-CP4-1 (turn deletion on in production), DP-CP4-2 (cleanup arithmetic), DP-CP4-7 (symlinked folders), DP-CP4-8 (login-shell profile), DP-I2 (menu case), DP-U4 (plan limits).

## Commands (run on 7 Oct at the user's request)

Tag the verified commit in loom-dev (lightweight, like `release/0.1.0`):

```bash
git -C ~/Documents/github/loom-dev tag release/0.2.0 da413c7
```

Promote into your loom tree (run from a clean loom-dev checkout: `build.sh` and the release manifest come from the working tree at promote time):

```bash
cd ~/Documents/github/loom-dev && zsh scripts/release/promote.sh 0.2.0 ~/Documents/github/loom
```

Build and install (quit Loom first; replaces `/Applications/Loom.app`; migrates `~/Library/Application Support/Loom` to catalog v3 on first launch):

```bash
cd ~/Documents/github/loom && ./build.sh
```

To try the candidate without installing: open `~/Library/Application Support/Loom-Dev/packages/run1-rc/Loom.app` while the installed Loom is not running. It uses the same data folder (`~/Library/Application Support/Loom`) and sockets (`~/.loom`) as the installed app.

## 0.2.1 hotfix: Option keys

Found the same morning by the post-install verification (three read-only verifiers of the installed 0.2.0): SwiftTerm treats Option as Meta by default and Loom never changed that, so on the user's Turkish Q layout Option+Q sent ESC q instead of `@` (in Claude Code a bare ESC clears the prompt or interrupts a turn), and the same for `[ ] { } \ | ~ €` and the Option dead keys (backtick, accents).

- **Rule now:** Option is the layout's character layer first, Meta second. A combination that types a character or starts a dead key goes to the input system as typing; everything else stays Meta: Option+Return (newline in Claude Code), Option+Backspace, Option+arrows, Option+Space. Trade-off: Meta letter shortcuts (Alt+B/F, Option+P/T in Claude Code) type their symbol on layouts that have one, as in Terminal.app, iTerm2 and kitty by default; use `/model`, `/config`, Option+arrows or `~/.claude/keybindings.json` instead. Cmd+Option+O still turns Meta off for a terminal (not remembered).
- **Change:** `LoomTerminalView.keyDown` (Sources/LoomTerminal/TerminalSurface.swift); SwiftTerm's macOS `keyDown` made `open` (`patches/swiftterm-open-keydown.patch`, LOOM-VENDOR item 13).
- **Checks:** `TerminalOptionKeyTests` (legacy input and kitty flags 1 and 11: `@ [ €` typed, no release bytes; dead key not sent as ESC; Option+Return/Backspace/Left/Space unchanged; Option+P types π; Cmd+Option+O toggle) failed on 0.2.0 for the characters and the dead key (mutation-checked); full release suite 680 tests, 0 failures (window tests skipped); staged release tree clean. Reviewed by two independent read-only reviewers (key paths: ship; product impact: the dead-key and Option+Space points, both taken).
- **Unverified (needs your keyboard):** a real dead key (Option+\ then Space for a backtick) and Caps Lock with Option letters; synthetic events cannot carry the layout's dead-key state.
