# Sourced by scripts/release/promote.sh and scripts/check.sh: the one definition of what the clean loom tree
# contains. Not executable on its own.

# The only paths exported from the loom-dev tag (promote) or the checked-out tree (check.sh --release-tree).
release_allow=(
  Package.resolved THIRD-PARTY-NOTICES.md
  Sources/CLoomPOSIX Sources/LoomCore Sources/LoomTerminal Sources/LoomCatalogUI Sources/LoomChat Sources/LoomRemora
  Sources/LoomLaunchOptions Sources/loom-app Sources/loom-run-host Sources/loom-hook
  # Vendored SwiftTerm as patched: library, build-info generator + plugin, the
  # terminfo entry the generator reads, its manifest and license. Tests, samples,
  # LOOM-VENDOR.md and Sources/SwiftTerm/Documentation.docc (excluded in
  # release_exclude below) are not needed by the build.
  Vendor/SwiftTerm/Package.swift Vendor/SwiftTerm/LICENSE
  Vendor/SwiftTerm/Sources Vendor/SwiftTerm/Plugins Vendor/SwiftTerm/swifterm-terminfo
  # Assets the app bundles (icon, provider marks), and the pictures of the README (not bundled).
  assets/Loom.icns assets/harness/harness-claude.png assets/harness/harness-codex.png assets/harness/harness-codex-template.png assets/readme
)

# Git pathspecs removed from the export. Sources/loom-app/Evidence is the development-only acceptance
# tooling (LOOM_EVIDENCE flavor); the release flavor never contains it.
release_exclude=(
  ':(exclude)Vendor/SwiftTerm/Sources/SwiftTerm/Documentation.docc'
  ':(exclude)Sources/loom-app/Evidence'
)

# Top-level entries the finished tree may contain.
release_allowed_top=(.git .gitignore Package.swift Package.resolved README.md LICENSE THIRD-PARTY-NOTICES.md VERSION build.sh Sources Vendor assets)

# loom_stage_release_tree <dest> [rev]: exports the allowlist into <dest>, from the git revision <rev> (git archive,
# like promote) or, without <rev>, from the checked-out tree (tracked and untracked files that are not ignored, so a
# check sees uncommitted work; identical to HEAD when the tree is clean). Run inside the repository root.
loom_stage_release_tree() {
  local dest=$1 rev=${2:-}
  if [[ -n $rev ]]; then
    git archive --format=tar "$rev" -- $release_allow $release_exclude | tar -x -C "$dest"
    return
  fi
  local files=(${(0)"$(git ls-files -z --cached --others --exclude-standard --deduplicate -- $release_allow $release_exclude)"})
  local existing=() f
  for f in $files; do [[ -e $f ]] && existing+=($f); done
  print -rN -- $existing | tar -c --null -T - -f - | tar -x -C "$dest"
}
