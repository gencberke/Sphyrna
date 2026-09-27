#!/bin/sh
# A LaunchServices launch receives its own resource coalition; direct execution does not.
set -eu
cd "$(dirname "$0")/../.."
swift build
bin=$(swift build --show-bin-path)
app="$PWD/.build/LoomProbe.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/loom-probe" "$bin/loom-test-child" "$app/Contents/MacOS/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.loom.probe</string>
<key>CFBundleName</key><string>Loom Probe</string>
<key>CFBundleExecutable</key><string>loom-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
printf '%s\n' "$app"
# Example: open -n -W "$app" --env LOOM_PROBE_ROOT=/tmp/loom-probe-test --args synthetic apple-escape
