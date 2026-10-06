#!/bin/zsh
# Runs a command inside the build slot: one lockf lock that serializes every build, test, package and measurement.
# Usage: scripts/with-build-slot.sh <command> [arguments...]
#   LOOM_BUILD_LOCK    lock file (default ~/Library/Caches/loom-run1/build-slot.lock; under ~/Documents it is refused, exit 2)
#   LOOM_SLOT_TIMEOUT  seconds to wait for the slot (default 3600)
# lockf -k keeps the file and serves waiters in order. Exit status: the command's, except 2 for usage or a refused lock
# path and 3 when the slot was not free within the timeout (the command did not run). While the command runs,
# <lock>.holder holds one line (pid, start time, command) for whoever waits; it is best effort and informational only.
set -euo pipefail

root=${0:A:h:h}
source "$root/scripts/dev-paths.sh"

if (( $# == 0 )) || [[ $1 == -h || $1 == --help ]]; then
  echo "Usage: scripts/with-build-slot.sh <command> [arguments...]" >&2
  exit 2
fi

lock=${LOOM_BUILD_LOCK:-$HOME/Library/Caches/loom-run1/build-slot.lock}
timeout=${LOOM_SLOT_TIMEOUT:-3600}
loom_refuse_documents "LOOM_BUILD_LOCK" "$lock"
[[ $timeout == <-> ]] || { echo "LOOM_SLOT_TIMEOUT must be a whole number of seconds: $timeout" >&2; exit 2; }
mkdir -p "${lock:h}"
holder="$lock.holder"

# Tell the caller who is in the way before blocking (-t 0: fail at once if the lock is held).
if ! /usr/bin/lockf -s -t 0 -k "$lock" /usr/bin/true 2>/dev/null; then
  echo "build slot busy (waiting up to ${timeout}s): $(cat "$holder" 2>/dev/null || echo 'holder unknown')" >&2
fi

# The marker file tells a lockf timeout (exit 75, nothing ran) apart from a command that itself exits 75.
started=$(mktemp "${TMPDIR:-/tmp}/loom-slot-started.XXXXXX")
trap 'rm -f "$started"' EXIT

# Runs under the lock. Not exec'd, so the holder line can be removed afterwards (only if it is still ours).
slot_body='
  holder=$1 started=$2; shift 2
  line="pid=$$ time=$(date -u +%Y-%m-%dT%H:%M:%SZ) cmd=${(j: :)${(q)@}}"
  print -r -- "$line" >| "$holder" 2>/dev/null || true
  print started >| "$started"
  trap '"'"'[[ $(cat "$holder" 2>/dev/null) == "$line" ]] && rm -f "$holder"'"'"' EXIT
  "$@"
'
set +e
/usr/bin/lockf -k -t "$timeout" "$lock" /bin/zsh -c "$slot_body" zsh "$holder" "$started" "$@"
rc=$?
set -e
if (( rc == 75 )) && [[ ! -s $started ]]; then
  echo "build slot not free within ${timeout}s: $lock ($(cat "$holder" 2>/dev/null || echo 'holder unknown'))" >&2
  exit 3
fi
exit $rc
