#!/bin/zsh
# Builds "Loom Dev.app" (local.loom.desktop.dev), named Sphyrna Dev, from a release build (CHECKPOINT-5-HISTORY §5).
# Usage: scripts/package-dev-app.sh [output-directory]
#   default: ~/Library/Application Support/Loom-Dev/app. A directory under
#   ~/Documents is refused: run hosts are separate TCC-responsible apps and
#   block on a Documents consent prompt when a package or fixture lives there.
# LOOM_SCRATCH_PATH moves build products (default ~/Library/Caches/loom-dev-build).
# Prefers the local "Loom Dev Code Signing" identity, then the first local
# "Apple Development"/"Developer ID" identity, or LOOM_CODESIGN_IDENTITY
# (exact name or SHA-1 hash; '-' explicitly selects ad-hoc). Without one the
# bundle is ad-hoc signed and this is reported: ad-hoc signing does not preserve
# privacy permissions across builds.
# Safe replacement: the bundle is assembled and signed in a temporary directory
# next to the target, verified, and only then moved into place. An existing app
# that is currently running from the target path is never touched (refused).
set -euo pipefail

root=${0:A:h:h}
source "$root/scripts/dev-paths.sh"
output=${1:-${loom_default_app:h}}
app="$output/Loom Dev.app"
final_app="$app"
loom_refuse_documents "Output directory" "$output"
scratch=$(loom_scratch_path)

# Any process executing from the target bundle (app, helpers, run hosts).
running_from_target() {
  ps -axo command= | awk -v prefix="$final_app/Contents/" 'index($0, prefix) == 1 { found = 1 } END { exit !found }'
}
refuse_if_running() {
  if running_from_target; then
    echo "Refusing to replace '$final_app': it is currently running. Quit it first." >&2
    exit 3
  fi
}
refuse_if_running

# Resolve once, before building or replacing the previous package. Signing and
# the run host's owner requirement must use the very same certificate, even
# when multiple keychains contain certificates with similar names.
identities=$(security find-identity -v -p codesigning)
requested=${LOOM_CODESIGN_IDENTITY:-}
if [[ -z "$requested" ]]; then
  requested=$(print -r -- "$identities" | awk -F'"' '$2 == "Loom Dev Code Signing" { print $2; exit }')
  [[ -n "$requested" ]] || requested=$(print -r -- "$identities" | awk -F'"' '/Apple Development|Developer ID Application/ { split($1, fields, " "); print fields[2]; exit }')
  [[ -n "$requested" ]] || requested=-
fi
if [[ "$requested" == - ]]; then
  identity=-
  signing="ad-hoc (no stable code-signing identity selected)"
else
  match_text=$(print -r -- "$identities" | awk -F'"' -v requested="$requested" '
    { split($1, fields, " "); hash = fields[2] }
    length(hash) == 40 && ($2 == requested || toupper(hash) == toupper(requested)) && !seen[hash]++ { print hash }
  ')
  matches=(${(f)match_text})
  (( ${#matches} == 1 )) || { echo "Code-signing identity must match exactly one valid certificate: $requested (found ${#matches})" >&2; exit 1; }
  identity=$matches[1]
  signing="identity: $identity ($requested)"
fi

cd "$root"
# Build products stay out of the checkout: release builds run dsymutil, which
# can block on a Documents consent prompt when the checkout lives under ~/Documents.
build=(swift build -c release --scratch-path "$scratch")
"${build[@]}" --product loom-app
"${build[@]}" --product loom-hook
"${build[@]}" --product loom-test-child
"${build[@]}" --product loom-run-host
bin=$("${build[@]}" --show-bin-path)

mkdir -p "$output"
stage=$(mktemp -d "$output/.loom-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Loom Dev.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/loom-app" "$app/Contents/MacOS/Loom Dev"
# Helpers sit beside the main executable; the app resolves them there only.
cp "$bin/loom-hook" "$bin/loom-test-child" "$app/Contents/MacOS/"
# The icon, Rising (scripts/make-app-icon.sh): the compiled icon and its flattened copy.
cp assets/icon/Assets.car assets/icon/Sphyrna.icns "$app/Contents/Resources/"
# The name people read is Sphyrna Dev (D-83) while the file stays "Loom Dev.app". Finder takes a localized name only
# while the plain CFBundleDisplayName is the file's name, so the plain one says "Loom Dev" and en.lproj (the one
# localization, so every language reads it) says Sphyrna Dev for Finder, the Dock and the menu bar.
mkdir -p "$app/Contents/Resources/en.lproj"
cat > "$app/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
"CFBundleName" = "Sphyrna Dev";
"CFBundleDisplayName" = "Sphyrna Dev";
STRINGS
# Run scopes: LaunchServices starts one instance per run, each in a fresh
# resource coalition (plans/cp5/OWN.md). It is its own TCC-responsible app.
host="$app/Contents/Helpers/LoomRunHost.app"
mkdir -p "$host/Contents/MacOS" "$host/Contents/Resources/en.lproj"
cp "$bin/loom-run-host" "$host/Contents/MacOS/loom-run-host"
# Activity Monitor lists the host under its LaunchServices name, and LaunchServices reads the display name only
# while the plain CFBundleDisplayName is the file's name; otherwise it shows "LoomRunHost" (FB6-12). So, as for the app,
# the plain one says LoomRunHost and en.lproj says Sphyrna Dev Run Host.
cat > "$host/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
"CFBundleName" = "Sphyrna Dev Run Host";
"CFBundleDisplayName" = "Sphyrna Dev Run Host";
STRINGS
cat > "$host/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.loom.desktop.dev.run-host</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleName</key><string>Sphyrna Dev Run Host</string>
  <key>CFBundleDisplayName</key><string>LoomRunHost</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleExecutable</key><string>loom-run-host</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSBackgroundOnly</key><true/>
  <key>LSMultipleInstancesProhibited</key><false/>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
</dict>
</plist>
PLIST
# Harness marks shown on session cards and Connections (design/DESIGN.md §6).
cp assets/harness/harness-claude.png assets/harness/harness-codex.png assets/harness/harness-codex-template.png \
  assets/harness/harness-opencode.png assets/harness/harness-agy.png "$app/Contents/Resources/"
revision=$(git rev-parse --short HEAD)
# Numeric and growing, as LaunchServices expects (build-loom.sh does the same); the commit is LoomRevision.
build_number=$(git rev-list --count HEAD)
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.loom.desktop.dev</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleName</key><string>Sphyrna Dev</string>
  <key>CFBundleDisplayName</key><string>Loom Dev</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleExecutable</key><string>Loom Dev</string>
  <key>CFBundleIconFile</key><string>Sphyrna</string>
  <key>CFBundleIconName</key><string>Sphyrna</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.0</string>
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

for helper in loom-hook loom-test-child; do
  codesign --force --options runtime --sign "$identity" "$app/Contents/MacOS/$helper"
done
# The host serves only its owner (plans/cp5/HOLISTIC.md SR1-F3): seal Loom's
# code requirement into the host's Info.plist before signing it. Only a stable
# identity makes this strong; ad-hoc builds can name Loom's identifier only.
if [[ "$identity" == - ]]; then
  owner='identifier "local.loom.desktop.dev"'
  echo "warning: ad-hoc signing; the run host can verify only Loom's identifier, not its signer" >&2
else
  owner="identifier \"local.loom.desktop.dev\" and certificate leaf = H\"$identity\""
fi
plutil -insert LoomOwnerRequirement -string "$owner" "$host/Contents/Info.plist"
codesign --force --options runtime --sign "$identity" "$host"
codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
if [[ "$identity" != - ]]; then
  codesign --verify --strict -R="$owner" "$app"
fi

# Replace only now, when the new bundle is complete and verified. The previous
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
app="$final_app"
codesign --verify --deep --strict "$app"
echo "Packaged $app"
echo "Signing: $signing"
