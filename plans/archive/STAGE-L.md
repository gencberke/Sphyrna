# Stage L — clean loom line

Goal: the user's daily `Loom.app` is built only from a clean `loom` tree that receives tested releases from loom-dev ([D-25, D-29](../DECISIONS.md); model in [DEVELOPMENT.md §10](../DEVELOPMENT.md#10-loom-dev-and-the-clean-loom-tree)). First release: **0.1.0** from the CP5 state. Runs before the multi-agent run.

## Design

- **Trees.** loom-dev = this repository, renamed from `~/Documents/github/loom` by the user. loom = new sibling `~/Documents/github/loom`, its own git repository: exactly one commit and one tag `v<version>` per promoted release, the commit message naming the loom-dev tag and commit.
- **Promote** (loom-dev script): take a loom-dev tag `release/<version>`, export an allowlist from the tag with `git archive` (never the working tree), add a generated release-only `Package.swift`, the build script and a short README, replace the loom tree's content, commit and tag there. Refuses if loom has uncommitted changes or the version already exists.
- **Allowlist.** Product targets only: `CLoomPOSIX`, `LoomCore`, `LoomTerminal`, `LoomCatalogUI`, `LoomLaunchOptions`, `loom-app`, `loom-run-host`, `loom-hook`; the vendored SwiftTerm sources as patched plus its license; the assets the app bundles. Nothing else: no `Tests/`, `plans/`, `design/`, experiments, probes, fixtures (`loom-probe`, `loom-test-child`, `loom-fake-provider`, `loom-catalog-fixture`, `CLoomTestSupport`), dev scripts or agent docs.
- **Build** (the one script in loom): release build with scratch outside `~/Documents`, assemble `Loom.app` with the production identity (`local.loom.desktop`, display name Loom, run host `local.loom.desktop.run-host`, owner requirement tied to that identifier and the signing certificate), version from the release, sign with one stable local identity (today `Loom Dev Code Signing`; never ad-hoc, so macOS privacy grants persist and are asked once), verify, then install to `/Applications/Loom.app` by temp-assemble, verify and swap; refuse while Loom is running. The production identity uses its own data (`~/Library/Application Support/Loom`, `~/.loom`), separate from Loom-Dev.
- **Known limits of 0.1.0.** Dev/evidence code is still compiled in (inert without `--evidence`) and Codex menu items still exist (frozen, [D-28](../DECISIONS.md)); both are removed in stage F. Grants stay valid only while the identity, bundle id and install path stay the same.

## Steps

| Step | Owner | State |
| --- | --- | --- |
| L-1 Promote and build scripts, dry-run export to a temp dir, debug build of the exported tree | implementer | accepted 6 Oct ([dry run](experiments/stage-l-dryrun-2026-10-06.md)); planner fix: templates are read from the tag, re-tested in a temp clone |
| L-2 Rename this checkout to `loom-dev` | user, with no agent session open in it | done 7 Oct |
| L-3 Tag `release/0.1.0`, promote into the new `loom`, release build and install `Loom.app` | planner-reviewer in a session started from loom-dev, when the user says the Mac is idle | done 7 Oct: tag on `d772acc`; loom `26b35f4` / `v0.1.0`, 180 files; `Loom.app` 0.1.0 `local.loom.desktop`, signed `Loom Dev Code Signing`, deep-strict verified; run host owner requirement = identifier + certificate leaf (L-A1, L-A2, L-A3 identity/signature part) |
| L-4 Acceptance on the installed `Loom.app` | planner-reviewer + user | deferred by the user on 7 Oct (D-31); run it before relying on Loom.app daily or with the next release |

## Acceptance

- **L-A1** The loom tree holds only the allowlist, the release manifest, the build script and README; its history has one commit and tag per release.
- **L-A2** Promote works only from a tag and refuses a dirty loom tree or an existing version.
- **L-A3** `Loom.app` has the production identity, version 0.1.0, a stable signature (`codesign --verify --deep --strict` passes, not ad-hoc) and uses `~/Library/Application Support/Loom` and `~/.loom`.
- **L-A4** On the installed app: launch, add a project, one real Claude conversation, Stop, Quit with no Loom-owned process left; Loom-Dev data and the installed `Loom Dev.app` unchanged.
- **L-A5** Privacy prompts appear at most once for the first launch and not again after a rebuild of the same identity (user observation).
- **L-A6** DEVELOPMENT.md §10 and scripts/README describe the real scripts.

## Notes

- The first release build fetches the vendored SwiftTerm manifest's unused `swift-png` dependency (network or SwiftPM cache needed); removing it would change the vendor manifest, so it stays for now.
- `build-loom.sh`'s build, signing and install path is first exercised in L-3.
