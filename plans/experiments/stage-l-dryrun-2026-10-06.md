# Stage L-1 dry run (6 Oct 2026)

Scope: `scripts/release/promote.sh` and `build-loom.sh` against throwaway tags `release/0.0.0-dryrun` and `release/0.0.1-dryrun` on loom-dev HEAD `8a2fa8c` (both deleted afterwards), promoted into `~/Library/Caches/loom-promote-dryrun/loom` (outside `~/Documents`, deleted afterwards). No release build, no signing, no install, nothing written into loom-dev except the two temporary tags.

## Export
- Exported 180 files (loom-dev tracks 481): 70 outside `Vendor/SwiftTerm/Sources/SwiftTerm`, 110 inside it. ~6.6 MB without `.git`.
- Top level: `.gitignore Package.resolved Package.swift README.md VERSION Sources Vendor assets build.sh` (+ `.git`).
- `Sources/`: the eight allowlisted targets only. `Vendor/SwiftTerm/`: `LICENSE Package.swift Plugins Sources swifterm-terminfo`. `assets/`: `Loom.icns`, `harness/harness-claude.png`, `harness/harness-codex.png`.
- No `Tests`, `plans`, `design`, `docs`, `agents`, `patches`, `scripts`, `LOOM-VENDOR.md`, `Documentation.docc`, `loom-probe`, `loom-test-child`, `loom-fake-provider`, `loom-catalog-fixture`, `CLoomTestSupport`, or `*.patch` (checked by the script and by `find`).
- Loom repo after two promotes: two commits `Loom <v> (from loom-dev release/<v> 8a2fa8c)`, tags `v0.0.0-dryrun`, `v0.0.1-dryrun`; second promote replaced content and kept `.git`.

## Build of the exported tree
`swift build --scratch-path ~/Library/Caches/loom-promote-dryrun/build` (debug) on the exported tree: Build complete (26 s wall), products `loom-app`, `loom-hook`, `loom-run-host` present; the tree stayed clean (`git status` empty). SwiftPM checked out `h` and `swift-png` (non-macOS SwiftTerm dependencies pinned in `Package.resolved`).

## Refusals (promote.sh)
| Case | Result |
| --- | --- |
| existing version | exit 1 `version 0.0.0-dryrun already exists in the loom tree (tag v0.0.0-dryrun)` |
| dirty loom tree (untracked file + modified `VERSION`) | exit 1 `the loom tree has uncommitted changes` |
| missing tag `release/9.9.9` | exit 1 |
| bad version `latest` | exit 2 |
| loom path inside loom-dev (`.` and `./sub`) | exit 1 |
| loom path containing loom-dev (parent dir) | exit 1 |
| non-empty directory that is not a git repo | exit 1 |
| path nested inside the loom repo | exit 1 |
| manifest template drift (edited `linkedLibrary("bsm")`) | exit 1 `drifted from the loom-dev Package.swift`, loom tree untouched |

## build-loom.sh (`--check-only`, run from the exported tree as `build.sh`)
Default target `/Applications/Loom.app` (not running): prints `Loom 0.0.1-dryrun (<commit>)`, identity `223E8AC2...4AD (Loom Dev Code Signing)`, scratch `~/Library/Caches/loom-release-build`, stops. Refusals: target under `~/Documents` (exit 2), scratch under `~/Documents` (exit 2), `LOOM_CODESIGN_IDENTITY=-` (exit 1), unknown identity (exit 1), target without `.app` (exit 2), unknown flag (exit 2), dirty tree (exit 1), a process running from `<target>/Contents/` (exit 3, shown with a process whose argv[0] was `/tmp/fakeloom/Loom.app/Contents/MacOS/Loom`, with and without `--check-only`).

## Equivalence with the dev package
The Info.plist heredocs of `package-dev-app.sh` and `build-loom.sh` differ only in bundle ids, names, executable name and the version string (`diff` of the two heredoc blocks). `package-dev-app.sh` was not modified. Not exercised: the build/sign/assemble/swap half of `build-loom.sh` (release build, signing and install are for the idle window).

## Syntax
`zsh -n scripts/release/promote.sh scripts/release/build-loom.sh` passes.
