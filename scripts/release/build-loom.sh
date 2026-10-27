#!/bin/zsh
# Builds the daily-use Loom.app (local.loom.desktop), named Sphyrna, from this tree and installs it.
# In loom-dev this file is scripts/release/build-loom.sh; promote.sh copies it
# into the clean loom tree as ./build.sh. It must stay standalone: it reads only
# files of the tree it sits in (Package.swift, VERSION, assets/) and git.
#
# Usage: ./build.sh [--target <path/to/Loom.app>] [--check-only]
#   --target      install location (default /Applications/Loom.app, or LOOM_INSTALL_PATH)
#   --check-only  validate arguments, tree, signing identity and the running-app
#                 refusal, print the plan, then stop before building or touching
#                 the target (heat-free; used for dry runs)
# LOOM_SCRATCH_PATH moves build products (default ~/Library/Caches/loom-release-build).
# LOOM_CODESIGN_IDENTITY selects the certificate (exact name or SHA-1 hash);
# default is the local "Loom Dev Code Signing" identity. Ad-hoc signing is refused:
# macOS privacy grants persist only while the stable identity, bundle id and
# install path stay the same.
# Exit codes: 1 error, 2 path under ~/Documents or bad arguments, 3 Sphyrna is running.
set -euo pipefail

root=${0:A:h}
target=${LOOM_INSTALL_PATH:-/Applications/Loom.app}
check_only=0
while (( $# > 0 )); do
  case $1 in
    --target) (( $# >= 2 )) || { echo "--target needs a path" >&2; exit 2; }; target=$2; shift 2 ;;
    --check-only) check_only=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

# Packages and build scratch must live outside ~/Documents: every run host is its
# own TCC-responsible app and blocks on a Documents consent prompt there.
refuse_documents() { # <label> <path>
  local resolved=${2:A} documents=${HOME:A}/Documents
  if [[ $resolved == $documents || $resolved == $documents/* ]]; then
    echo "$1 '$2' is under ~/Documents. Run hosts are separate TCC-responsible apps and block on a Documents consent prompt there." >&2
    exit 2
  fi
}
[[ $target == *.app ]] || { echo "Target must be a .app path: $target" >&2; exit 2; }
refuse_documents "Install target" "$target"
scratch=${LOOM_SCRATCH_PATH:-$HOME/Library/Caches/loom-release-build}
refuse_documents "LOOM_SCRATCH_PATH" "$scratch"
final_app=${target:A}
given_app=${target:a}
install_dir=${final_app:h}

[[ -f "$root/VERSION" && -f "$root/Package.swift" && -f "$root/assets/icon/Assets.car" && -f "$root/assets/icon/Sphyrna.icns" \
   && -f "$root/THIRD-PARTY-NOTICES.md" ]] \
  || { echo "This is not a promoted loom tree (VERSION, Package.swift, assets/icon/Assets.car, assets/icon/Sphyrna.icns or THIRD-PARTY-NOTICES.md missing): $root" >&2; exit 1; }
version=$(<"$root/VERSION")
version=${version//[[:space:]]/}
version_re='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'
[[ $version =~ $version_re ]] || { echo "VERSION is not a version number: '$version'" >&2; exit 1; }
git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1 || { echo "$root is not a git tree with a commit; build only from the promoted commit." >&2; exit 1; }
if [[ -n $(git -C "$root" status --porcelain) ]]; then
  echo "The loom tree has uncommitted changes; this tree is generated and must be built exactly as promoted." >&2
  exit 1
fi
revision=$(git -C "$root" rev-parse --short HEAD)
# CFBundleVersion must be numeric: LaunchServices compares it to pick the newest copy of a bundle
# id. It comes from VERSION (major * 10000 + minor * 100 + patch, so 0.4.4 is 404), which grows with
# every release whatever the tree's history; the commit itself is LoomRevision.
parts=(${(s:.:)${version%%[-+]*}})
(( parts[2] < 100 && parts[3] < 100 )) || { echo "VERSION $version: minor and patch must stay below 100 for the build number" >&2; exit 1; }
build_number=$(( parts[1] * 10000 + parts[2] * 100 + parts[3] ))

# Any process executing from the target bundle (app, helpers, run hosts).
running_from_target() {
  # Match both the resolved path and the path as given (symlinked parents).
  ps -axo command= | awk -v a="$final_app/Contents/" -v b="$given_app/Contents/" \
    'index($0, a) == 1 || index($0, b) == 1 { found = 1 } END { exit !found }'
}
refuse_if_running() {
  if running_from_target; then
    echo "Refusing to replace '$final_app': Sphyrna is running. Quit it first." >&2
    exit 3
  fi
}
refuse_if_running

# Resolve once, before building: signing and the run host's owner requirement
# must use the very same certificate.
requested=${LOOM_CODESIGN_IDENTITY:-Loom Dev Code Signing}
if [[ $requested == - ]]; then
  echo "Ad-hoc signing is refused: it would lose macOS privacy grants on every build. Use a stable identity (LOOM_CODESIGN_IDENTITY)." >&2
  exit 1
fi
identities=$(security find-identity -v -p codesigning)
match_text=$(print -r -- "$identities" | awk -F'"' -v requested="$requested" '
  { split($1, fields, " "); hash = fields[2] }
  length(hash) == 40 && ($2 == requested || toupper(hash) == toupper(requested)) && !seen[hash]++ { print hash }
')
matches=(${(f)match_text})
(( ${#matches} == 1 )) || { echo "Code-signing identity must match exactly one valid certificate: $requested (found ${#matches})" >&2; exit 1; }
identity=$matches[1]

echo "Sphyrna $version (build $build_number, $revision) -> $final_app"
echo "Signing identity: $identity ($requested)"
echo "Build scratch: $scratch"
if (( check_only )); then
  echo "--check-only: stopping before the build; nothing was built or changed."
  exit 0
fi
[[ -d $install_dir && -w $install_dir ]] || { echo "Cannot write to $install_dir (needs an existing, writable directory)." >&2; exit 1; }

cd "$root"
build=(swift build -c release --scratch-path "$scratch")
"${build[@]}" --product loom-app
"${build[@]}" --product loom-hook
"${build[@]}" --product loom-run-host
bin=$("${build[@]}" --show-bin-path)

stage=$(mktemp -d "$install_dir/.loom-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Loom.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/loom-app" "$app/Contents/MacOS/Loom"
# Helpers sit beside the main executable; the app resolves them there only.
cp "$bin/loom-hook" "$app/Contents/MacOS/"
# The icon, Rising: the compiled icon and its flattened copy (made in loom-dev, so no Xcode is needed here).
cp assets/icon/Assets.car assets/icon/Sphyrna.icns "$app/Contents/Resources/"
# The name people read is Sphyrna (D-83) while the file stays Loom.app. Finder takes a localized name only while
# the plain CFBundleDisplayName is the file's name, so the plain one says "Loom" and en.lproj (the one
# localization, so every language reads it) says Sphyrna for Finder, the Dock and the menu bar.
mkdir -p "$app/Contents/Resources/en.lproj"
cat > "$app/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
"CFBundleName" = "Sphyrna";
"CFBundleDisplayName" = "Sphyrna";
STRINGS
# Run scopes: LaunchServices starts one host instance per run, each in a fresh
# resource coalition. It is its own TCC-responsible app.
host="$app/Contents/Helpers/LoomRunHost.app"
mkdir -p "$host/Contents/MacOS"
cp "$bin/loom-run-host" "$host/Contents/MacOS/loom-run-host"
cat > "$host/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.loom.desktop.run-host</string>
  <key>CFBundleName</key><string>Sphyrna Run Host</string>
  <key>CFBundleDisplayName</key><string>Sphyrna Run Host</string>
  <key>CFBundleExecutable</key><string>loom-run-host</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSBackgroundOnly</key><true/>
  <key>LSMultipleInstancesProhibited</key><false/>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
</dict>
</plist>
PLIST
# Provider marks shown on conversation cards.
cp assets/harness/harness-claude.png assets/harness/harness-codex.png assets/harness/harness-codex-template.png "$app/Contents/Resources/"
# Third-party licenses (T3 Code MIT text; SwiftTerm is named there) ship inside the app.
cp THIRD-PARTY-NOTICES.md "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.loom.desktop</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleName</key><string>Sphyrna</string>
  <key>CFBundleDisplayName</key><string>Loom</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleExecutable</key><string>Loom</string>
  <key>CFBundleIconFile</key><string>Sphyrna</string>
  <key>CFBundleIconName</key><string>Sphyrna</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LoomRevision</key><string>$revision</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- No UTExportedTypeDeclarations for the in-app drag type (session-reference): declared as
       public.data, AppKit turns a SwiftUI drag into a file promise and NSFilePromiseReceiver raises during the drag,
       which leaves the window refusing clicks (1.7.1, FEEDBACK-6 FB6-4). Undeclared, it stays in-app data. Projects
       reorder with a live gesture, not a pasteboard type (A1). -->
</dict>
</plist>
PLIST

codesign --force --options runtime --sign "$identity" "$app/Contents/MacOS/loom-hook"
# The host serves only its owner: seal Loom's code requirement (identifier and
# signing certificate) into the host's Info.plist before signing it.
owner="identifier \"local.loom.desktop\" and certificate leaf = H\"$identity\""
plutil -insert LoomOwnerRequirement -string "$owner" "$host/Contents/Info.plist"
codesign --force --options runtime --sign "$identity" "$host"
codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
codesign --verify --strict -R="$owner" "$app"

# Swap only now, when the new bundle is complete and verified. The previous
# bundle is removed only after the new one is in place.
refuse_if_running
if [[ -e "$final_app" ]]; then
  mv "$final_app" "$stage/previous.app"
  if ! mv "$app" "$final_app"; then
    mv "$stage/previous.app" "$final_app"
    echo "Could not move the new bundle into place; the previous bundle was restored." >&2
    exit 1
  fi
else
  mv "$app" "$final_app"
fi
codesign --verify --deep --strict "$final_app"
echo "Installed $final_app (Sphyrna $version, $revision)"
echo "Signing identity: $identity"
