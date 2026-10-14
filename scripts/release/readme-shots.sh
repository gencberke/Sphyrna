#!/bin/zsh
# Renders the README pictures of the clean loom tree: design/readme/<name>.html -> assets/readme/<name>.png,
# at 2x with a transparent background, through headless Google Chrome and a throwaway profile (no window,
# no build; light). Each page reports its picture size in a data-shot-size attribute after load.
# Usage: scripts/release/readme-shots.sh [name…]   (default: every design/readme/*.html; LOOM_CHROME overrides the browser)
set -euo pipefail

root=${0:A:h:h:h}
chrome=${LOOM_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}
[[ -x $chrome ]] || { echo "Google Chrome not found at '$chrome'; set LOOM_CHROME" >&2; exit 2; }
names=($@)
(( $# )) || names=($root/design/readme/*.html(N:t:r))
(( ${#names} )) || { echo "No pages in design/readme" >&2; exit 2; }
profile=$(mktemp -d "${TMPDIR:-/tmp}/loom-readme-chrome.XXXXXX")
trap 'rm -rf "$profile"' EXIT
headless=(--headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check
  --user-data-dir="$profile" --default-background-color=00000000)
mkdir -p "$root/assets/readme"
for name in $names; do
  page=$root/design/readme/$name.html
  [[ -f $page ]] || { echo "No such page: $page" >&2; exit 2; }
  size=$("$chrome" $headless --window-size=3000,3000 --virtual-time-budget=2000 --dump-dom "file://$page" 2>/dev/null \
    | sed -n 's/.*data-shot-size="\([0-9]*x[0-9]*\)".*/\1/p' | head -1)
  [[ -n $size ]] || { echo "$name: the page reported no size" >&2; exit 1; }
  "$chrome" $headless --force-device-scale-factor=2 --window-size=${size/x/,} --virtual-time-budget=2000 \
    --screenshot="$root/assets/readme/$name.png" "file://$page" >/dev/null 2>&1
  print -r -- "$name: ${size} pt -> assets/readme/$name.png ($(( $(stat -f %z "$root/assets/readme/$name.png") / 1024 )) KB)"
done
