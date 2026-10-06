#!/bin/zsh
# CP5 A acceptance smoke through LaunchServices (A1, A3, D2, D3 synthetic,
# §13 madde 2 and 4, §18.1 madde 3).
# Runs live under run hosts (not the app's children), so fixtures are found by
# scope (scripts/cp5-scope-probe.py) and checked gone after Quit by recorded
# identity, recorded coalition and host path. Exit status 0 only when all hold.
# Usage: scripts/cp5-a-acceptance.sh [path/to/Loom Dev.app]
#   default: ~/Library/Application Support/Loom-Dev/app (a path under ~/Documents is refused)
# Evidence: ~/Library/Application Support/Loom-Dev/probe/runs/cp5-a-<timestamp>/
set -euo pipefail

root=${0:A:h:h}
source "$root/scripts/dev-paths.sh"
app=${1:-$loom_default_app}
loom_refuse_documents "App path" "$app"
probe() { python3 "$root/scripts/cp5-scope-probe.py" "$@"; }
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
stamp=$(date +%Y%m%dT%H%M%S)
base="$HOME/Library/Application Support/Loom-Dev/probe/runs/cp5-a-$stamp"
mkdir -p "$base"
# The evidence instance being driven; set by launch/finish before any command.
evidence_dir=""
send_command() { loom_send_command "${evidence_dir:?no evidence directory selected}" "$1"; }
wait_file() { for _ in {1..200}; do [[ -f "$1" ]] && return 0; sleep 0.1; done; echo "missing $1" >&2; return 1; }
app_pid() { pgrep -f "$app/Contents/MacOS/Loom Dev" | head -1; }

if pgrep -f "Loom Dev.app/Contents/MacOS/Loom Dev" >/dev/null; then
  echo "Loom Dev is already running; quit it first." >&2; exit 2
fi

record_scope() { # dir: every run host of this package and the members of its scope
  probe snapshot "$app" > "$1/scope-before.json"
  python3 - "$1/scope-before.json" > "$1/fixtures.txt" <<'EOF'
import json, sys
for host in json.load(open(sys.argv[1]))["hosts"]:
    for member in host["members"]:
        if member["pid"] != host["pid"]:
            print(member["pid"], host["pid"], host["coalition"], member["path"])
EOF
}

scenario() { # name, fixture args...
  local name=$1; shift
  local dir="$base/$name"
  mkdir -p "$dir"
  evidence_dir="$dir"
  open -a "$app" --args --evidence "$dir" --data-root "$dir/data" --fixture "$@"
  wait_file "$dir/launched.json"
  sleep 1.5
  local pid=$(app_pid)
  record_scope "$dir"
  lsof -p "$pid" 2>/dev/null | awk '/ptmx|\/dev\/tty/ { print $4, $5, $9 }' > "$dir/app-pty-fds.txt" || true
  echo "$pid" > "$dir/app-pid.txt"
}

finish() { # dir [expect-fixtures]: Quit, then prove the whole scope is gone
  local dir=$1 pid=$(cat "$1/app-pid.txt")
  evidence_dir="$dir"
  send_command quit
  wait_file "$dir/quit.json"
  for _ in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  { kill -0 "$pid" 2>/dev/null && echo "app still running" || echo "app exited"; } > "$dir/after-quit.txt"
  [[ $(cat "$dir/after-quit.txt") == "app exited" ]] || fail "$dir: app still running after Quit"
  if probe verify "$app" "$dir/scope-before.json" > "$dir/after-quit-scope.json"; then :; else
    fail "$dir: run hosts or scope members remain after Quit: $(cat "$dir/after-quit-scope.json")"
  fi
  if [[ ${2:-} == expect-fixtures && ! -s "$dir/fixtures.txt" ]]; then
    fail "$dir: no fixture was found in any run scope before Quit"
  fi
}

# 1) Visible -> Cmd+W equivalent -> hidden output -> reopen -> Quit.
scenario window-cycle stream 1048576 62914560
d="$base/window-cycle"
send_command snapshot:visible-a; sleep 5; send_command snapshot:visible-b
send_command close-window; sleep 2; send_command snapshot:hidden-a; sleep 10; send_command snapshot:hidden-b
open -a "$app"; sleep 1.5; send_command snapshot:reopened
finish "$d" expect-fixtures

# 2) Quit while the window is closed and output is running.
scenario hidden-quit stream 1048576 62914560
d="$base/hidden-quit"
send_command close-window; sleep 2; send_command snapshot:hidden
finish "$d" expect-fixtures

# 3) Quit immediately after launch starts (launch may still be in flight).
d="$base/quit-during-launch"; mkdir -p "$d"
evidence_dir="$d"
open -a "$app" --args --evidence "$d" --data-root "$d/data" --fixture interactive
wait_file "$d/launched.json"; app_pid > "$d/app-pid.txt"
record_scope "$d"
finish "$d"

# 4) Forced scope failure (LOOM_FORCE_SCOPE_FAILURE needs --evidence): the
#    notice is visible before any work starts and survives close/reopen;
#    repeated new-terminal requests fail visibly and nothing starts.
d="$base/ownership-notice"; mkdir -p "$d"
evidence_dir="$d"
open -a "$app" --env LOOM_FORCE_SCOPE_FAILURE=1 --args --evidence "$d" --data-root "$d/data"
wait_file "$d/launched.json"; app_pid > "$d/app-pid.txt"
sleep 1.5
send_command new-terminal; send_command new-terminal; send_command new-terminal
sleep 1.5; send_command snapshot:after-requests
sleep 0.5
record_scope "$d"
send_command close-window; sleep 0.5; open -a "$app"; sleep 1; send_command snapshot:reopened
sleep 0.5
python3 - "$d" <<'EOF' || fail "ownership-notice: $(cat "$d/notice-check.txt" 2>/dev/null)"
import json, sys
d = sys.argv[1]
problems = []
for label in ("after-requests", "reopened"):
    state = json.load(open(f"{d}/state-{label}.json"))
    if state["ownershipNoticeShown"] is not True: problems.append(f"{label}: notice not shown")
    if not state["terminalState"].startswith("ended"): problems.append(f"{label}: terminal state {state['terminalState']}, expected the failed start to have ended")
    if state["windowCount"] != 1: problems.append(f"{label}: windowCount {state['windowCount']}")
first = json.load(open(f"{d}/state-after-requests.json"))
if first["attachedSheet"] is None: problems.append("start failure is not visible (no alert sheet)")
if json.load(open(f"{d}/scope-before.json"))["hosts"]: problems.append("a run host started")
open(f"{d}/notice-check.txt", "w").write("; ".join(problems) or "ok")
sys.exit(1 if problems else 0)
EOF
finish "$d"

# 5) Controlled first-quit failure: app, run and alert stay; new work is
#    refused; the alert's real Try Again button then quits cleanly.
d="$base/quit-failure-retry"; mkdir -p "$d"
evidence_dir="$d"
open -a "$app" --args --evidence "$d" --data-root "$d/data" --fail-first-quit --fixture interactive
wait_file "$d/launched.json"; sleep 1.5; app_pid > "$d/app-pid.txt"
record_scope "$d"
send_command quit; wait_file "$d/quit-attempt-1.json"; sleep 1
send_command new-terminal; sleep 1; send_command snapshot:after-failed-quit
{ kill -0 "$(cat "$d/app-pid.txt")" && echo "app alive after failed quit"
  probe snapshot "$app"; } > "$d/after-failed-quit.txt" 2>&1 || true
[[ -s "$d/fixtures.txt" ]] || fail "quit-failure-retry: no fixture in a run scope before the forced failure"
send_command quit-alert-try-again; wait_file "$d/quit-attempt-2.json"
pid=$(cat "$d/app-pid.txt"); for _ in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
{ kill -0 "$pid" 2>/dev/null && echo "app still running" || echo "app exited"; } > "$d/after-quit.txt"
[[ $(cat "$d/after-quit.txt") == "app exited" ]] || fail "quit-failure-retry: app still running after Try Again"
probe verify "$app" "$d/scope-before.json" > "$d/after-quit-scope.json" || fail "quit-failure-retry: scope remains: $(cat "$d/after-quit-scope.json")"

echo "$base"
(( failures == 0 )) || { echo "$failures acceptance check(s) failed" >&2; exit 1; }
