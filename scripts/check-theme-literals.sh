#!/bin/zsh
# Theme guard: visual values of LoomCatalogUI live in LoomTheme.swift and its LoomTheme+*.swift
# extensions only. Fails when another source file there uses a color literal, Color.white, a
# fixed-size system font or a literal corner radius. Plain grep on the sources
# (the clean loom tree has no Tests, so this is a script, not a unit test).
# Usage: scripts/check-theme-literals.sh   (exit 0 clean, 1 with violations listed)
set -euo pipefail

root=${0:A:h:h}
dir="$root/Sources/LoomCatalogUI"
pattern='Color\(red:|Color\.white|\.system\(size:|cornerRadius: *[0-9]'

hits=$(grep -rnE "$pattern" "$dir" --include='*.swift' | grep -vE '/LoomTheme(\+[A-Za-z]+)?\.swift:' || true)
if [[ -n $hits ]]; then
  echo "Theme literals outside Sources/LoomCatalogUI/LoomTheme*.swift (use LoomTheme tokens):" >&2
  print -r -- "$hits" >&2
  exit 1
fi
echo "theme guard: no visual literals outside LoomTheme*.swift"
