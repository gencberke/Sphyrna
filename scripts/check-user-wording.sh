#!/bin/zsh
# Wording guard: text the user reads says "session", never "conversation"
# (design/DESIGN.md voice row). Fails when a Swift string literal under
# Sources/LoomCatalogUI or Sources/loom-app contains "conversation" or
# "Conversation" as a word, unless the line matches an extended regex in
# scripts/check-user-wording.allow (one per line; evidence keys, identifiers).
# String interpolations and comment-only lines are ignored. Plain grep/perl on
# the sources (the clean loom tree has no scripts, so this is a script check).
# Usage: scripts/check-user-wording.sh   (exit 0 clean, 1 with violations listed)
set -euo pipefail

root=${0:A:h:h}
allow=${0:A:h}/check-user-wording.allow
cd "$root"

hits=$(grep -rnE '[Cc]onversation' Sources/LoomCatalogUI Sources/loom-app --include='*.swift' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
  | perl -ne 'if (/^([^:]+:\d+:)(.*)$/) { my ($p, $l) = ($1, $2); my $s = $l; 1 while $s =~ s/\\\([^()]*\)//; print $_ if $s =~ /"[^"]*(?<![\w])[Cc]onversations?(?![\w])[^"]*"/; }' \
  | { if [[ -f $allow ]]; then grep -vEf <(grep -vE '^[[:space:]]*(#|$)' "$allow") || true; else cat; fi; } || true)

if [[ -n $hits ]]; then
  echo "User-visible wording: use \"session\", not \"conversation\" in string literals (allowlist: scripts/check-user-wording.allow):" >&2
  print -r -- "$hits" >&2
  exit 1
fi
echo "wording guard: no \"conversation\" in user-visible literals"
