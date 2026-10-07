# Loom development guide

How agents build, test, package, verify and measure Loom without hurting the user's machine or each other. Workflow and roles: [AGENTS.md](AGENTS.md). Product limits: [contract](LOOM-PRODUCT-CONTRACT.md). Structure: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Script index: [scripts/README.md](scripts/README.md). Facts below were checked against the code and scripts on 6 Oct 2026.

## 1. Toolchain

- macOS 27, `xcode-select -p` = `/Applications/Xcode.app/Contents/Developer`, Swift 6.4 (arm64-apple-macosx27.0.0); `xctrace` and Instruments exist. Command Line Tools also exist. Verify again before relying on this; versions of provider CLIs are never pinned.
- Macro plugin workaround: not needed with Xcode selected (7 Oct 2026, `scripts/check.sh --suite LoomLaunchOptionsTests`, a plain `swift test --filter` without the flag, 5/5 passed). Only if `swift test` cannot find the Testing macro plugin (for example with only the Command Line Tools selected), pass `scripts/check.sh --macro-plugin <libTestingMacros.dylib>` (it appends `-Xswiftc -load-plugin-library -Xswiftc <dylib>`). The CLT copy is `/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib`; the Xcode copy sits under `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/`.
- C code (`CLoomPOSIX`, `CLoomTestSupport`) must be clean under `clang -Wall -Wextra -Werror`; after `fork` only async-signal-safe calls.

## 2. Build and test

- Always give your own scratch path and keep it outside `~/Documents`: `scripts/dev-paths.sh` provides `loom_scratch_path` (`$LOOM_SCRATCH_PATH`, default `~/Library/Caches/loom-dev-build`) and `loom_refuse_documents` (exit 2). Release builds run `dsymutil`, which blocks on a Documents consent prompt (TCC); packages, fixtures and scratch under `~/Documents` break run hosts the same way.
- Routine change: `scripts/check.sh [--suite <Suite>…] [--scratch <mine>]` (or `LOOM_SCRATCH_PATH`; there is no CI). Default: `git diff --check`, `git diff --cached --check`, trailing whitespace in untracked files (which `git diff --check` skips), `zsh -n` on `scripts/**/*.sh`, `py_compile` on `scripts/**/*.py` (bytecode goes to a temp dir), `clang -Wall -Wextra -Werror -fsyntax-only` on the C sources, then `swift build --scratch-path <mine>`. `--suite <Name>…` adds `swift test --filter` per name (targets: LoomCoreTests, LoomTerminalTests, LoomCatalogUITests, LoomLaunchOptionsTests, or any suite or test name); `--tests` runs every target. The four window tests (`byteQuotaCoversRasterRounding`, `layerBackingStorePreservesPixelsOutsideTheDirtyRect`, `hostedWorkingIndicatorRunsOnlyWhenTheEnvironmentAllowsIt`, `realSidebarRunsAWorkingRowOnlyForAnActiveWindowAndExpandedSidebar`) are skipped unless `--windows --idle`. It prints one line per check, the "N tests passed" line and a verdict, logs to `~/Library/Caches/loom-check-logs/`, and exits 0 pass, 1 a check failed, 2 usage or refusal, 3 build slot timeout. Docs-only: links, consistency, whitespace (`scripts/check.sh` covers the whitespace).
- Build slot: every swift build, test, package and measurement runs as `scripts/with-build-slot.sh <command…>` (`check.sh` does this itself): one `lockf -k` lock (`LOOM_BUILD_LOCK`, default `~/Library/Caches/loom-run1/build-slot.lock`, never under `~/Documents`), waits up to `LOOM_SLOT_TIMEOUT` seconds (3600), exit 3 when the slot stayed busy, `<lock>.holder` names the current holder.
- Full suite (checkpoint close or large combined change; 377 tests on 6 Oct): `scripts/check.sh --full --idle` (the checks above plus `swift build -c release`, the staged release-tree build and `swift test -c release --scratch-path <path>`, window tests included; without `--idle` it exits 2).
- Release flavor: `scripts/check.sh --release-tree` exports the promote allowlist from the checked-out tree into `<scratch>-release-stage` with `Package.release.swift` as the manifest, builds it with `swift build -c release`, and fails when the `loom-app` binary carries development-evidence symbols or strings (`LOOM_EVIDENCE` code, §5). `--full` includes it. Tests that open a real window fail with a locked screen. The verified 6 Oct run (377/377) used the CLT macro-plugin flag from §1, which is no longer needed.
- A regression test must fail without the fix. Test success is not proof of UI or real-provider behavior.
- Evidence of a run: command, result, run id, file path; never tokens, credentials or environment values. Durable evidence lives under `~/Library/Application Support/Loom-Dev/probe/` or value-free `plans/experiments/`.

## 3. Test and heat policy (user decision 6 Oct 2026, renewing 4 Oct)

The Mac is fanless and overheats. Therefore:
- No parallel builds or tests. Exactly one agent owns and runs the full suite for a combined change; separately passing slices prove nothing about integration.
- Implementers run only `scripts/check.sh` (build and whitespace/syntax checks) and short narrow tests (`--suite`).
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

`Loom Dev --evidence <dir>` is acceptance tooling that drives the same model actions as the user and writes JSON state into `<dir>`. It exists only in the development flavor: `Sources/loom-app/Evidence/` is compiled when the dev manifest's `LOOM_EVIDENCE` define is set (`loom-app` in `Package.swift`); the release flavor (clean loom tree, built from `Package.release.swift`) contains none of it, and `--evidence` there does nothing beyond the data-root isolation rule below.
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
| `open-settings[:general\|usage\|about]`, `close-settings`, `screenshot-settings:<label>`, `usage-select:<24h\|7d\|30d\|90d>`, `usage-refresh[:<label>]` | Settings window and usage view (snapshot gains `settings{…}` and `usage{…}`) |
| `tab-pin:<id>`, `tab-unpin:<id>`, `tab-select:<id\|next\|prev>`, `tab-close:<id>`, `tab-key:<next\|prev\|ctrl-next\|ctrl-prev\|close>` | conversation tabs (U4): Open in Tab, unpin, click or Next/Previous, close button, and a key equivalent sent through the real main menu (writes `ack-tab-key-<arg>.json`: handled, enabled); snapshot gains `tabs{ids, pinned, selected, transient, stripVisible, rows, attachedTerminals, …}` and `catalog.preferences.openTabs`. Driver: `scripts/perf/tab_strip.py scenario\|shots\|latency` (fake provider `/stream <seconds>` produces about 1 MiB/s of output) |
| `sidebar-width:<pt>` | sidebar width |
| `close-window`, `quit` | close or normal Quit |

Full list: the header of `Sources/loom-app/Evidence/DevelopmentEvidence.swift` and the `case`s of its command switch plus `Sources/loom-app/Evidence/EvidenceCatalogCommands.swift` (the header omits `buttons:`, `toggle-fullscreen`, `feed`, `double-start` and `resource:`).

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
- Judging a matrix run: `scripts/perf/compare_baseline.py <run-dir> [--baseline <json>]` pairs the reference and candidate cells and exits 1 on a regression gate (stream1 total >= 40 %, candidate stream1 app median above the reference median + 1.5 points or, without a reference, above the baseline max + 1.5, spinner1 median above the baseline max + 2.5, hidden stream1 app above the baseline + 1.0, latency p95 median above 25 ms, any invalid cell). The thresholds are this run's regression gates, not product budgets (O-01 is open). `--self-test` checks it on synthetic runs built from the baseline JSON.
- Baseline, package I, Core Graphics, CPU % of one core ([data](plans/experiments/cp5-final-matrix-I-20261006.json)): stream1 1 MiB/s visible app 23.8-24.0 (total 25.4-25.6; CPU40 passes), spinner1 12.6-14.7, stream1 hidden 3.5, input-to-draw p95 about 20 ms, working indicator under reduced motion about 0.005 (idle wakeups near 0), idle observer with one real Claude 0.044.

## 8. Swarm rules for the shared tree

- One writer per file: each brief names disjoint write ownership. Preserve other agents' edits; read `git status` first; never `git stash`, `checkout`, `reset` or clean others' work; do not commit unless the user asks.
- Own `--scratch-path` per agent and per experiment dir; builds never run concurrently (§2 build slot).
- Combined checks (full suite, packaging, matrix) belong to one named owner (the planner-reviewer); slices only run narrow checks.
- Plans, checkpoint maps and STATUS are written by the planner-reviewer; implementers propose doc impact in their Report.

## 9. Vendored SwiftTerm

Pinned upstream commit plus local patches only via `patches/*.patch`, each listed in `Vendor/SwiftTerm/LOOM-VENDOR.md`; no second engine or product fork. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §6.

## 10. loom-dev and the clean loom tree

User decision [D-25](DECISIONS.md) (6 Oct 2026); plan and acceptance in [plans/STAGE-L.md](plans/STAGE-L.md).

| | loom-dev (this repository) | loom (clean tree) |
| --- | --- | --- |
| Purpose | All development: code, tests, plans, experiments, tooling, dev packages (`Loom Dev.app`, `local.loom.desktop.dev`, data in `Loom-Dev`) | Only the source of the daily-use `Loom.app` (`local.loom.desktop`, data in `~/Library/Application Support/Loom`, sockets in `~/.loom`) |
| May contain | Anything, including messy files | Product sources and assets, the vendored engine as patched, a release-only `Package.swift`, one build script, README. No tests, plans, probes, fixtures, experiment data or dev scripts |
| Who edits | Agents and the user, under AGENTS.md | Nobody by hand; only the promote step writes it |
| Builds | Dev builds and packages for testing | One clean release build of `Loom.app` |

Flow: finish and verify a release in loom-dev (full suite, real-Claude check, perf baseline), tag it `release/<version>`, then run `scripts/release/promote.sh <version> <loom-tree-path>`. Rolling back means rebuilding an earlier `v<version>` in loom.

- **Promote** (`scripts/release/promote.sh`, light: no build): exports a fixed allowlist (`scripts/release/allowlist.sh`, shared with `check.sh`; it excludes `Sources/loom-app/Evidence`) from the tag with `git archive` (never the working tree) into a temp dir, generates the release `Package.swift` (from `scripts/release/Package.release.swift`; promote fails if its target declarations differ from the tagged dev manifest; the one dev-only setting, `.define("LOOM_EVIDENCE")` on `loom-app`, is stripped before the comparison), `build.sh` (a copy of `scripts/release/build-loom.sh`), `README.md`, `VERSION` and `.gitignore`, rejects any path outside the allowlist, then replaces the loom tree's content (keeping `.git`), commits `Loom <version> (from loom-dev release/<version> <short-sha>)` and tags `v<version>`. Allowlist: `Package.resolved`; `Sources/{CLoomPOSIX,LoomCore,LoomTerminal,LoomCatalogUI,LoomLaunchOptions,loom-app,loom-run-host,loom-hook}`; `Vendor/SwiftTerm/{Package.swift,LICENSE,Sources,Plugins,swifterm-terminfo}` without `Sources/SwiftTerm/Documentation.docc`; `assets/Loom.icns`, `assets/harness/harness-{claude,codex}.png`. Refuses (exit 1, nothing written): missing tag; a loom path equal to, inside or containing loom-dev, or nested in another git repository; a non-empty directory that is not a git repository; uncommitted changes in loom; an existing tag `v<version>`. The build script and manifest template come from the loom-dev working tree at promote time, so commit them before tagging a release if the tag should reproduce them.
- **Build** (`build.sh` in the loom tree, heavy: release build and signing, run only when the user says the Mac is idle): release-builds `loom-app`, `loom-hook`, `loom-run-host` into `~/Library/Caches/loom-release-build` (`LOOM_SCRATCH_PATH`), assembles `Loom.app` (`local.loom.desktop`, executable `Loom`, `CFBundleShortVersionString` from `VERSION`, `CFBundleVersion` the loom commit, `loom-hook` beside the executable, `LoomRunHost.app` as `local.loom.desktop.run-host` with a `LoomOwnerRequirement` of identifier plus signing-certificate leaf; no `loom-test-child`), signs with `LOOM_CODESIGN_IDENTITY` or the local `Loom Dev Code Signing` identity (ad-hoc refused), runs `codesign --verify --deep --strict`, and swaps the bundle into `/Applications/Loom.app` (`--target <path>` or `LOOM_INSTALL_PATH` for tests). Exit 2 for a target or scratch under `~/Documents` or bad arguments; exit 3 while Loom runs from the target; it also refuses a dirty tree. `./build.sh --check-only` validates arguments, tree, identity and the running check without building. It duplicates the assembly of `scripts/package-dev-app.sh` (standalone by design); keep the Info.plist layout of the two in step.

Rules: the daily `Loom.app` and its data are user data like the installed `Loom Dev.app` — never test material. Evidence code is compiled only into the development flavor of `loom-app` (`LOOM_EVIDENCE`, directory `Sources/loom-app/Evidence/`); `scripts/check.sh --release-tree` (part of `--full`) exports the allowlist from the checked-out tree, builds it with `Package.release.swift` and fails when the binary carries `DevelopmentEvidence`, `EvidenceResourcePool` or the evidence-only flags, so the release flavor keeps building. Inert library-side seams (`TerminalPresentationLog`, `IndicatorEvidence`, `ConversationController` evidence members) stay in both flavors. Build output stays outside `~/Documents` (§2).

Order: first rename this checkout from `loom` to `loom-dev` (a directory move done by the user while no agent session runs in it), then create the clean `loom` tree, so the two never share a path; scripts resolve paths relative to the repo, but the Claude Code project history and any external links keyed on the old path start fresh.
