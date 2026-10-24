#!/bin/zsh
# Draws Sphyrna's app icon layers (D-97) from layers.html into figure-1024.png and ground-1024.png, next to this
# script. Needs Google Chrome; it runs headless with a throwaway profile and no network.
# Usage: design/identity/icon/draw.sh   (then scripts/make-app-icon.sh)
set -euo pipefail

here=${0:A:h}
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x $chrome ]] || { echo "Google Chrome is missing: $chrome" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/loom-icon-layers.XXXXXX")
trap 'rm -rf "$work"' EXIT

"$chrome" --headless=new --user-data-dir="$work/profile" --no-first-run --disable-extensions \
  --disable-background-networking --disable-sync --virtual-time-budget=10000 \
  --dump-dom "file://$here/layers.html" 2>/dev/null > "$work/dom.html"

python3 -I - "$work/dom.html" "$here" <<'PY'
import base64, html, json, re, sys
dom, here = sys.argv[1], sys.argv[2]
m = re.search(r'<pre id="out">(.*?)</pre>', open(dom).read(), re.S)
text = html.unescape(m.group(1)) if m else 'missing'
if not text.startswith('{'): sys.exit('layers.html failed: ' + text[:200])
for layer, url in json.loads(text).items():
    with open(f'{here}/{layer}-1024.png', 'wb') as f:
        f.write(base64.b64decode(url.split(',', 1)[1]))
PY
echo "Wrote $here/figure-1024.png and ground-1024.png"
