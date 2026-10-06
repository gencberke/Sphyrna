# Loom development guide

How agents build, test, package, verify and measure Loom without hurting the user's machine or each other. Workflow and roles: [AGENTS.md](AGENTS.md). Product limits: [contract](LOOM-PRODUCT-CONTRACT.md). Structure: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Script index: [scripts/README.md](scripts/README.md). Facts below were checked against the code and scripts on 6 Oct 2026.

## 1. Toolchain

- macOS 27, `xcode-select -p` = `/Applications/Xcode.app/Contents/Developer`, Swift 6.4 (arm64-apple-macosx27.0.0); `xctrace` and Instruments exist. Command Line Tools also exist. Verify again before relying on this; versions of provider CLIs are never pinned.
- Macro plugin workaround: only when `swift test` cannot find the Testing macro plugin, append `-Xswiftc -load-plugin-library -Xswiftc <libTestingMacros.dylib>`. The CLT copy is `/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`; the Xcode copy sits under `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/`. Not expected to be needed with Xcode selected.
- C code (`CLoomPOSIX`, `CLoomTestSupport`) must be clean under `clang -Wall -Wextra -Werror`; after `fork` only async-signal-safe calls.

## 2. Build and test

- Always give your own scratch path and keep it outside `~/Documents`: `scripts/dev-paths.sh` provides `loom_scratch_path` (`$LOOM_SCRATCH_PATH`, default `~/Library/Caches/loom-dev-build`) and `loom_refuse_documents` (exit 2). Release builds run `dsymutil`, which blocks on a Documents consent prompt (TCC); packages, fixtures and scratch under `~/Documents` break run hosts the same way.
- Routine change: `swift build --scratch-path <mine>`, `git diff --check`, and narrow suites: `swift test --scratch-path <mine> --filter <Suite>` (targets: LoomCoreTests, LoomTerminalTests, LoomCatalogUITests, LoomLaunchOptionsTests). Include new untracked files in the diff review. Docs-only: links, consistency, whitespace.
- Full suite (checkpoint close or large combined change; 377 tests on 6 Oct): `swift build -c release --scratch-path <path>` then `swift test -c release --scratch-path <path>` (tests that open a real window fail with a locked screen). The verified 6 Oct run (377/377) used the CLT macro-plugin flag from §1; whether it is still needed with Xcode selected is unverified.
- A regression test must fail without the fix. Test success is not proof of UI or real-provider behavior.
- Evidence of a run: command, result, run id, file path; never tokens, credentials or environment values. Durable evidence lives under `~/Library/Application Support/Loom-Dev/probe/` or value-free `plans/experiments/`.

## 3. Test and heat policy (user decision 6 Oct 2026, renewing 4 Oct)

The Mac is fanless and overheats. Therefore:
- No parallel builds or tests. Exactly one agent owns and runs the full suite for a combined change; separately passing slices prove nothing about integration.
- Implementers run only build, `git diff --check` and short narrow tests.
- Heavy measurements, release suite runs and screen-flashing UI/window tests only when the user says the computer is idle and the Loom window may stay on screen. Screen unlocked, no concurrent build, Terminal windows out of the way, power adapter plugged in.
- 90 s cooldown between heavy cells.

| Without asking | Only when the user says the Mac is idle | Only when the user asks |
| --- | --- | --- |
| `swift build` with your own scratch path, `git diff --check`, short narrow `swift test --filter` on suites that open no window (LoomCatalogUITests and LoomTerminalTests contain window tests: run them only when idle), `py_compile`/`zsh -n`, reading and grep | full release suite, packaging, any `cp5-*`/`perf/*` runner that opens a window or measures, screen-flashing window tests (short real-Claude turns inside these are pre-authorized, D-04) | long or costly model budgets, anything touching user apps or data, commits, pushes, PRs |

Builds are serialized: only the agent whose Brief says it holds the build slot builds at a time; the planner-reviewer hands the slot out. Scripts that use the repo-local `.build` (`cp5-c-observer-smoke.py`) count as builds and need the slot.

## 4. Isolation

- The real `~/.claude`, `~/.codex`, running sessions and ChatGPT.app are read-only and never test data. Use isolated profiles: `CLAUDE_CONFIG_DIR` = `~/Library/Application Support/Loom-Dev/probe/claude-config`; Codex home `~/.loom-dev/codex-home` (Darwin `sun_path` limit).
- Never replace, modify, kill or test with the user's installed `~/Library/Application Support/Loom-Dev/app/Loom Dev.app`, and never run tests while the user's own instance is running. Tests use a dedicated package: the single build owner runs `scripts/package-dev-app.sh ~/Library/Application\ Support/Loom-Dev/packages/<name>` and Briefs name that package; the perf runners require `--app` and refuse the installed app. Never point anything at the default dev catalog `~/Library/Application Support/Loom-Dev/catalog.sqlite3` (size/mtime must stay unchanged; a synthetic-polluted copy is kept as `catalog-backup-20261005-synthetic`). Package experiments into a separate directory, e.g. `Loom-Dev/packages/<name>`.
- Dev data layout, `~/Library/Application Support/Loom-Dev/`: `catalog.sqlite3`, `ui-preferences.json`, `app/`, `packages/` (archived builds), `probe/` (profiles, workspace, `runs/`), `runs/`, `signing/`. `~/.loom-dev/`: `scopes/` (run-host sockets), `h-*.sock` (hook sockets), `codex-home`. Tests must not clean other agents' or earlier evidence.
- Production identity, facts only (no packaging script yet): bundle `local.loom.desktop`, data `~/Library/Application Support/Loom`, sockets `~/.loom`. Dev bundle: `local.loom.desktop.dev` ("Loom Dev").
- Real provider tests: Claude only. Codex is paused and not in the first production release (user decision 6 Oct 2026). Short real-Claude turns for acceptance are pre-authorized (2 Oct decision); large budgets (long autonomous tasks, many repeats, costly models) need the user. Record the number of turns spent.

## 5. Evidence mode

`Loom Dev --evidence <dir>` is acceptance tooling that drives the same model actions as the user and writes JSON state into `<dir>`.
- Data root is always isolated: `--data-root <path>` if given, else `<dir>/data`. `--data-root` without `--evidence`, or a flag without its value, refuses to open the catalog (`LaunchOptions.resolveDataRoot`).
- Evidence-only flags (ignored or absent without `--evidence`): `--fixture <argv…>` (first terminal), `--fake-providers <dir>` (dir with `loom-fake-provider`; unredacted evidence), `--claude-config <dir>`, `--codex-home <dir>`, `--evidence-tokens a,b` (token presence in screen text; real-provider evidence stays redacted and `screenshot` is disabled), `--evidence-transparency glass|opaque`, `--metal` (dev renderer only; product is Core Graphics), `--fake-toolchain-delay <s>`, `--fail-first-quit`. Environment: `LOOM_FORCE_SCOPE_FAILURE=1` (missing run host).
- Command channel, one per instance: distributed notification `local.loom.desktop.dev.command.<first 16 hex of sha256(realpath(dir))>`, object = command string. Send with `source scripts/dev-paths.sh; loom_send_command <dir> '<command>'`; read results from `<dir>/state-<label>.json` etc. Launch through LaunchServices (`open -n -a <app> --args --evidence <dir> …`) for acceptance runs; `cp5-d-measure.py` execs the binary directly unless given `--launch-services`; `perf/run-final-matrix.py` does not pass that flag, so the CP5 matrices were measured with direct exec.

| Command | Effect |
|---|---|
| `snapshot:<label>` | writes `state-<label>.json` (catalog, terminals, runtime) |
| `screenshot:<label>` | `screenshot-<label>.png` (fake providers only) |
| `buttons:<label>` | window button geometry `buttons-<label>.json` |
| `select:<id\|none>`, `search:<t>`, `view-mode:<activity\|projects>`, `toggle-sidebar`, `resize:<w>x<h>` | catalog/window state |
| `add-project:<path>`, `remove-project:<id>`, `rename:<id>:<t>` | catalog edits |
| `start:<claude\|codex>:<project id\|none>`, `resume:<id>`, `stop:<id>` | conversation lifecycle |
| `type:<id>:<text>` | types text plus Return into the session (empty text = Return) |
| `answer:<id>:<accept\|deny>` | answers an approval card |
| `latency:<n>` | input-to-draw latency samples |
| `resource:<pid>:<uuid>:<op…>` | measurement ops (`open`, `openspinner`, `hide`, `latency`, `cycles`, `stop`, `quit`), used by `cp5-d-measure.py` |
| `close-window`, `quit` | close or normal Quit |

Full list: the header of `Sources/loom-app/DevelopmentEvidence.swift` and the `case`s of its command switch (the header omits `buttons:`, `toggle-fullscreen`, `feed`, `double-start` and `resource:`).

## 6. Packaging

`scripts/package-dev-app.sh [output-dir]` (default `Loom-Dev/app`): release-builds the four products with `loom_scratch_path`, assembles `Loom Dev.app` (+ `LoomRunHost.app`) in a temp dir next to the target, signs, verifies (`codesign --verify --deep --strict`, owner requirement), then swaps. Exit 2 if the output is under `~/Documents`; exit 3 if anything runs from the target app (quit it first; never kill the user's app). `CFBundleVersion` is `git rev-parse --short HEAD` and does not reflect uncommitted changes, so identify packages by SHA of the binary.
- Identity: `LOOM_CODESIGN_IDENTITY` (name or SHA-1, `-` = ad-hoc), else local `Loom Dev Code Signing`, else the first `Apple Development`/`Developer ID Application` identity, else ad-hoc. Ad-hoc loses TCC grants (Documents prompts return) and the run host can only check Loom's identifier. The script prints the chosen signing. Do not create certificates per build; the private key stays out of repo and logs. Signing blocks while the screen is locked.
- Changing bundle id, signer or install path invalidates earlier TCC consent ([evidence](plans/experiments/cp5-stable-signing.json)).

## 7. Measurement method

Contract [§10](LOOM-PRODUCT-CONTRACT.md#10-resource-and-performance-acceptance) defines the budgets. Loom, providers and WindowServer are judged separately; CPU says nothing about GPU.
- Load: realistic, repeatable; keep synthetic and real-provider results apart. Record duration, input, warm-up, repetitions, command. Comparative claims need at least five runs, median and spread, in absolute units compared against noise; the 3-run `perf/run-final-matrix.py` is a regression check against the baseline, not a comparative claim.
- CPU: `proc_pid_rusage` (user+system) over the sample window, summed over app, fixture and run-scope hosts (`scripts/cp5-d-measure.py`; an unreadable scope member invalidates the cell). Alternate with a reference package (A/B/A/B), 90 s cooldown, frozen input hashes. Tools: `top -l`, `ps`, `sample`, `vmmap`, `xctrace`.
- Conditions: Loom window visible and not covered (the scripts never raise it), screen unlocked, nothing else building or testing.
- Runners: `scripts/perf/run-final-matrix.py`, `indicator_cost.py`, `claude_real.py` (see scripts/README.md). Output goes to a run dir under `~/Library`.
- Baseline, package I, Core Graphics, CPU % of one core ([data](plans/experiments/cp5-final-matrix-I-20261006.json)): stream1 1 MiB/s visible app 23.8-24.0 (total 25.4-25.6; CPU40 passes), spinner1 12.6-14.7, stream1 hidden 3.5, input-to-draw p95 about 20 ms, working indicator under reduced motion about 0.005 (idle wakeups near 0), idle observer with one real Claude 0.044.

## 8. Swarm rules for the shared tree

- One writer per file: each brief names disjoint write ownership. Preserve other agents' edits; read `git status` first; never `git stash`, `checkout`, `reset` or clean others' work; do not commit unless the user asks.
- Own `--scratch-path` per agent and per experiment dir; builds never run concurrently (§3 build slot).
- Combined checks (full suite, packaging, matrix) belong to one named owner (the planner-reviewer); slices only run narrow checks.
- Plans, checkpoint maps and STATUS are written by the planner-reviewer; implementers propose doc impact in their Report.

## 9. Vendored SwiftTerm

Pinned upstream commit plus local patches only via `patches/*.patch`, each listed in `Vendor/SwiftTerm/LOOM-VENDOR.md`; no second engine or product fork. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §6.

## 10. loom-dev and the clean loom tree

User decision [D-25](DECISIONS.md) (6 Oct 2026). Details marked *proposed* are set up in [ROADMAP](ROADMAP.md) stage L and wait for O-11.

| | loom-dev (this repository) | loom (clean tree) |
| --- | --- | --- |
| Purpose | All development: code, tests, plans, experiments, tooling, dev packages (`Loom Dev.app`, `local.loom.desktop.dev`, data in `Loom-Dev`) | Only the source of the daily-use `Loom.app` (`local.loom.desktop`, data in `~/Library/Application Support/Loom`, sockets in `~/.loom`) |
| May contain | Anything, including messy files | Product sources and assets, the vendored engine as patched, a release-only `Package.swift`, one build script, README. No tests, plans, probes, fixtures, experiment data or dev scripts |
| Who edits | Agents and the user, under AGENTS.md | Nobody by hand; only the promote step writes it |
| Builds | Dev builds and packages for testing | One clean release build of `Loom.app` |

Flow (*proposed*): finish and verify a release in loom-dev (full suite, real-Claude check, perf baseline) → tag it → a loom-dev script exports the allowlisted files **from the tag** (not from the working tree) into the loom tree and commits there with the tag name → build `Loom.app` in loom → install it for daily use. Rolling back means rebuilding an earlier promoted commit in loom.

Rules: the daily `Loom.app` and its data are user data like the installed `Loom Dev.app` — never test material. Dev and evidence code is still compiled into the app target (inert without `--evidence`) until stage F separates it. Build output stays outside `~/Documents` (§2).

Order: first rename this checkout from `loom` to `loom-dev` (a directory move done by the user while no agent session runs in it), then create the clean `loom` tree, so the two never share a path; scripts resolve paths relative to the repo, but the Claude Code project history and any external links keyed on the old path start fresh.
