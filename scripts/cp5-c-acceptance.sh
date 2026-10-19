#!/bin/zsh
# CP5 C synthetic acceptance through LaunchServices on isolated data with
# fixture providers (C1-C5 and the C part of D3). No real Claude/Codex, no
# model turn, no user profile: the packaged app is started with
# `--fake-providers`, which only exists together with `--evidence`.
# Every conversation runs under its own run host; "nothing started" and "nothing
# left" are proved by counting hosts of this package (by path) and by the
# recorded scope of the live conversations, not by the app's children.
# Usage: scripts/cp5-c-acceptance.sh [path/to/Loom Dev.app]
#   default: ~/Library/Application Support/Loom-Dev/app (a path under ~/Documents is refused)
# LOOM_EXPERIMENT_DIR (default plans/experiments) receives summary.json.
# Evidence: ~/Library/Application Support/Loom-Dev/probe/runs/cp5-c-<timestamp>/
# Exit status: 0 only when every check passed (scripts/cp5-b-summary.py).
set -euo pipefail

root=${0:A:h:h}
# The polling predicate, final summary and negative self-test share this oracle.
C_ACCEPTANCE_ORACLE_CODE=$(cat <<'ORACLE'
def approval_done(opened, done):
    owner = opened.get("catalog", {}).get("selectedSessionID")
    rows = [row for row in opened.get("catalog", {}).get("activityRowDetails", []) if row.get("id") == owner]
    thread = rows[0].get("conversationID") if len(rows) == 1 else None
    requests = [event for event in opened.get("runtime", {}).get("codexRouting", {}).get("entries", [])
                if event.get("event") == "request" and event.get("threadID") == thread]
    if not owner or not thread or not requests:
        return False
    after = max(event.get("sequence", 0) for event in requests)
    completions = [event for event in done.get("runtime", {}).get("codexRouting", {}).get("entries", [])
                   if event.get("event") == "turnCompleted" and event.get("threadID") == thread and event.get("sequence", 0) > after]
    terminals = [terminal for terminal in done.get("conversationTerminals", []) if terminal.get("owner") == owner]
    catalog = done.get("catalog", {})
    return (catalog.get("selectedSessionID") == owner and catalog.get("selectedRequests") == []
            and catalog.get("selectedIndicator") in ("Ready", "Finished") and bool(completions)
            and any("CODEX-TURN-DONE completed approved" in terminal.get("screenTail", "") for terminal in terminals))

def hidden_working(state):
    return (state.get("windowVisible") is False and state.get("catalog", {}).get("selectedIndicator") == "Working"
            and state.get("runtime", {}).get("liveRuns", 0) >= 1)
ORACLE
)
export C_ACCEPTANCE_ORACLE_CODE
if [[ ${1:-} == --oracle-self-test ]]; then
  python3 - <<'ORACLE_TEST'
import copy, os
exec(os.environ["C_ACCEPTANCE_ORACLE_CODE"])
opened = {"catalog": {"selectedSessionID": "owner", "activityRowDetails": [{"id": "owner", "conversationID": "thread"}]},
          "runtime": {"codexRouting": {"entries": [{"event": "request", "threadID": "thread", "sequence": 10}]}}}
done = {"catalog": {"selectedSessionID": "owner", "selectedRequests": [], "selectedIndicator": "Finished"},
        "conversationTerminals": [{"owner": "owner", "screenTail": "CODEX-TURN-DONE completed approved"}],
        "runtime": {"codexRouting": {"entries": [{"event": "turnCompleted", "threadID": "thread", "sequence": 11}]}}}
assert approval_done(opened, done)
for mutate in [lambda state: state["catalog"].update(selectedIndicator="Working"),
               lambda state: state["catalog"].update(selectedSessionID="sibling"),
               lambda state: state["catalog"].update(selectedRequests=[{}]),
               lambda state: state["conversationTerminals"][0].update(screenTail="request disappeared"),
               lambda state: state["runtime"]["codexRouting"].update(entries=[]),
               lambda state: state["runtime"]["codexRouting"]["entries"][0].update(threadID="sibling"),
               lambda state: state["runtime"]["codexRouting"]["entries"][0].update(sequence=9)]:
    bad = copy.deepcopy(done); mutate(bad)
    assert not approval_done(opened, bad), bad
assert hidden_working({"windowVisible": False, "catalog": {"selectedIndicator": "Working"}, "runtime": {"liveRuns": 1}})
assert not hidden_working({"windowVisible": False, "catalog": {"selectedIndicator": "Ready"}, "runtime": {"liveRuns": 1}})
print("C4 oracle rejects empty-request-only, missing approval/completion, wrong owner/thread/sequence; D3 rejects hidden idle.")
ORACLE_TEST
  exit $?
fi
source "$root/scripts/dev-paths.sh"
app=${1:-$loom_default_app}
loom_refuse_documents "App path" "$app"
probe() { python3 "$root/scripts/cp5-scope-probe.py" "$@"; }
# Hosts are found by executable path (proc_pidpath), not by command line.
host_count() { python3 "$root/scripts/cp5-scope-probe.py" hosts "$app"; }
stamp=$(date +%Y%m%dT%H%M%S)
base="$HOME/Library/Application Support/Loom-Dev/probe/runs/cp5-c-$stamp"
mkdir -p "$base"
cd "$root"
# Release products (and dsymutil) stay out of ~/Documents; so do the fixtures.
build=(swift build -c release --scratch-path "$(loom_scratch_path)")
for product in loom-fake-provider loom-test-child; do "${build[@]}" --product $product >/dev/null 2>&1; done
bin=$("${build[@]}" --show-bin-path)
fixtures="$base/fixtures"; mkdir -p "$fixtures"
cp "$bin/loom-fake-provider" "$bin/loom-test-child" "$fixtures/"
provider="$fixtures/loom-fake-provider"

# Source and binary identity of this run (hashes only; no values).
{
  echo "git-head: $(git rev-parse HEAD)"
  echo "git-dirty-files: $(git status --porcelain | wc -l | tr -d ' ')"
  echo "sources-sha256: $(find Sources Tests Package.swift scripts -type f \( -name '*.swift' -o -name '*.sh' -o -name '*.py' -o -name 'Package.swift' \) | sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
  echo "app-sha256: $(shasum -a 256 "$app/Contents/MacOS/Loom Dev" | cut -d' ' -f1)"
  echo "fake-provider-sha256: $(shasum -a 256 "$provider" | cut -d' ' -f1)"
  echo "macos: $(sw_vers -productVersion)  swift: $(swift --version 2>&1 | head -1)"
} > "$base/source-and-binary.txt"

# The evidence instance being driven; set by launch/finish before any command.
evidence_dir=""
send_command() { loom_send_command "${evidence_dir:?no evidence directory selected}" "$1"; }
wait_file() { for _ in {1..300}; do [[ -f "$1" ]] && return 0; sleep 0.1; done; echo "missing $1" >&2; return 1; }
jq_() { python3 -c "import json,sys,os; exec(os.environ['C_ACCEPTANCE_ORACLE_CODE']); d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2"; }

if pgrep -f "Loom Dev.app/Contents/MacOS/Loom Dev" >/dev/null; then
  echo "Loom Dev is already running; quit it first." >&2; exit 2
fi

snap() { # dir label
  rm -f "$1/state-$2.json"; send_command "snapshot:$2"; wait_file "$1/state-$2.json"; sleep 0.15
}
cmd() { send_command "$1"; sleep "${2:-0.6}"; }
# Polls snapshots until a python expression over the state `d` holds (or the time is up).
until_() { # dir label seconds expression
  local end=$((SECONDS + $3))
  while (( SECONDS < end )); do
    snap "$1" "$2"
    [[ $(jq_ "$1/state-$2.json" "$4" 2>/dev/null || echo False) == True ]] && return 0
    sleep 0.25
  done
  echo "timed out waiting for $2 after $3 seconds" >&2
  return 1
}
procs() { # dir label: run hosts of this package, PTY descriptors, fixture processes
  local pid=$(cat "$1/app-pid.txt")
  probe snapshot "$app" > "$1/scope-$2.json"
  { echo "run-hosts: $(host_count)"
    echo "ptmx-fds: $(lsof -p "$pid" 2>/dev/null | grep -c 'ptmx' || true)"
    echo "fixture-procs: $(pgrep -f "$provider" | wc -l | tr -d ' ')"
    echo "test-child-procs: $(pgrep -f "$fixtures/loom-test-child" | wc -l | tr -d ' ')"
    echo "threads: $(ps -M -p "$pid" | tail -n +2 | wc -l | tr -d ' ')"; } > "$1/procs-$2.txt"
}
launch() { # name datadir [args...]
  local name=$1 data=$2; shift 2
  local dir="$base/$name"; mkdir -p "$dir"
  evidence_dir="$dir"
  open -a "$app" --args --evidence "$dir" --data-root "$data" --fake-providers "$fixtures" "$@"
  wait_file "$dir/launched.json"
  for _ in {1..100}; do
    snap "$dir" ready
    [[ $(jq_ "$dir/state-ready.json" "d['catalog']['ready'] and d['catalog']['actionsAvailable']") == True ]] && break
    sleep 0.2
  done
  send_command live-chat:off; sleep 1  # a start follows Settings 'Sessions run in' (Chat by default); this script drives terminal sessions
  pgrep -f "$app/Contents/MacOS/Loom Dev" | head -1 > "$dir/app-pid.txt"
}
finish() { # dir
  local dir=$1 pid=$(cat "$1/app-pid.txt")
  evidence_dir="$dir"
  rm -f "$dir/quit.json"; send_command quit; wait_file "$dir/quit.json"
  for _ in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  { kill -0 "$pid" 2>/dev/null && echo "app still running" || echo "app exited"; } > "$dir/after-quit.txt"
  for _ in {1..100}; do [[ $(host_count) == 0 ]] && break; sleep 0.1; done
}

# An unrelated process the app must never touch (D3: outside control process).
sleep 600 & outsider=$!
echo $outsider > "$base/outsider-pid.txt"
trap 'kill $outsider 2>/dev/null || true' EXIT

# ---- 1) Main run: start, hooks, Codex, stop, resume, /clear, approval, Quit ---
data="$base/data-main"; mkdir -p "$data" "$base/projects/alpha"
launch main "$data"
d="$base/main"
snap "$d" fresh; procs "$d" fresh
cmd view-mode:activity 0.8
cmd "add-project:$base/projects/alpha" 1
cmd view-mode:activity 0.8
snap "$d" project-added
alpha=$(jq_ "$d/state-project-added.json" "d['catalog']['projects'][0]['id']")

# C1 Claude, projectless. Two clicks in a row must make one run.
cmd "double-start:claude:none" 0.5
until_ "$d" claude-live 20 "len(d['conversationTerminals'])==1 and 'READY' in d['conversationTerminals'][0]['screenTail']"
snap "$d" claude-after-double-click; procs "$d" claude
cmd screenshot:claude-terminal 1.5
claude=$(jq_ "$d/state-claude-live.json" "d['conversationTerminals'][0]['owner']")
cmd "type:${claude}:hello from the acceptance script" 1
until_ "$d" claude-typed 15 "'echo: hello from' in d['conversationTerminals'][0]['screenTail'] and d['catalog']['selectedIndicator'] in ('Ready','Finished')"

# C1 Codex in a project.
cmd "start:codex:${alpha}" 1
until_ "$d" codex-live 25 "len(d['conversationTerminals'])==2 and all('READY' in t['screenTail'] for t in d['conversationTerminals'])"
snap "$d" codex-bound; procs "$d" two
codex=$(jq_ "$d/state-codex-live.json" "[t['owner'] for t in d['conversationTerminals'] if t['owner']!='$claude'][0]")
until_ "$d" codex-identity 15 "any(r['id']=='$codex' and r['conversationID'] for r in d['catalog']['activityRowDetails'])"

# C5 stopping one leaves the other working.
cmd "stop:$claude" 1
until_ "$d" claude-stopped 15 "len(d['conversationTerminals'])==1"
cmd "select:$codex" 0.5
cmd "type:${codex}:still alive" 1
until_ "$d" codex-after-stop 15 "'CODEX-TURN-DONE completed echo still alive' in d['conversationTerminals'][0]['screenTail']"
procs "$d" after-stop

# C2 resume keeps the identity and the history.
cmd "resume:$claude" 1
until_ "$d" claude-resumed 20 "any('remembered=1' in t['screenTail'] for t in d['conversationTerminals'])"

# C2 /clear inside the TUI: the same terminal moves to a new card of the same project? (Claude here is projectless.)
cmd "select:$claude" 0.5
cmd "type:${claude}:/clear" 1
until_ "$d" claude-cleared 15 "len(d['catalog']['activityRowDetails'])>=3 and not any(t['owner']=='$claude' for t in d['conversationTerminals'])"

# C4 Codex approval through the card.
cmd "select:$codex" 0.5
cmd "type:${codex}:approve this" 1
until_ "$d" approval-open 15 "len(d['catalog']['selectedRequests'])==1 and d['catalog']['selectedIndicator']=='Needs approval'"
cmd screenshot:codex-approval 1.5
cmd "answer:${codex}:accept" 1
until_ "$d" approval-done 15 "approval_done(json.load(open(os.path.join(os.path.dirname(sys.argv[1]),'state-approval-open.json'))), d)"

# D3 (C part): Quit with an active Codex turn and a hidden window.
cmd "type:${codex}:work 60000" 1
until_ "$d" active-turn 15 "d['catalog']['selectedIndicator']=='Working'"
cmd close-window 1.2
until_ "$d" hidden-active 15 "hidden_working(d)"
procs "$d" hidden-active
finish "$d"
sleep 0.5
probe verify "$app" "$d/scope-hidden-active.json" > "$d/after-quit-scope.json" || true
{ echo "fixture-procs: $(pgrep -f "$provider" | wc -l | tr -d ' ')"
  echo "test-child-procs: $(pgrep -f "$fixtures/loom-test-child" | wc -l | tr -d ' ')"
  echo "run-hosts: $(host_count)"
  echo "outsider-alive: $(kill -0 $outsider 2>/dev/null && echo yes || echo no)"; } > "$d/after-quit-procs.txt"

# ---- 2) Reopen: history back, nothing started ------------------------------------
launch reopened "$data"
d="$base/reopened"
snap "$d" reopened; procs "$d" reopened
finish "$d"

# ---- 3) Quit while a start is still resolving its environment -------------------
data2="$base/data-quit-start"; mkdir -p "$data2"
launch quit-start "$data2" --fake-toolchain-delay 4
d="$base/quit-start"
send_command "start:claude:none"; sleep 1
snap "$d" starting
finish "$d"
sleep 0.5
{ echo "fixture-procs: $(pgrep -f "$provider" | wc -l | tr -d ' ')"; echo "run-hosts: $(host_count)"; } > "$d/after-quit-procs.txt"
sqlite3 "$data2/catalog.sqlite3" "select count(*) from sessions; select count(*) from runs;" > "$d/catalog-counts.txt"

# ---- 4) Forced first-quit failure with a live conversation, then Try Again -------
data3="$base/data-quit-retry"; mkdir -p "$data3"
launch quit-retry "$data3" --fail-first-quit
d="$base/quit-retry"
cmd "start:claude:none" 1
until_ "$d" retry-live 20 "len(d['conversationTerminals'])==1 and 'READY' in d['conversationTerminals'][0]['screenTail']"
rm -f "$d/quit-attempt-1.json" "$d/quit-attempt-2.json"
send_command quit; wait_file "$d/quit-attempt-1.json"; sleep 1.5
snap "$d" after-failed-quit; procs "$d" after-failed-quit
send_command quit-alert-try-again; wait_file "$d/quit-attempt-2.json"
pid=$(cat "$d/app-pid.txt")
for _ in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
{ kill -0 "$pid" 2>/dev/null && echo "app still running" || echo "app exited"; } > "$d/after-quit.txt"
sleep 0.5
{ echo "fixture-procs: $(pgrep -f "$provider" | wc -l | tr -d ' ')"; echo "run-hosts: $(host_count)"; } > "$d/after-quit-procs.txt"

python3 - "$base" "$stamp" <<'PYEOF'
import json, sys, os
base, stamp = sys.argv[1], sys.argv[2]
exec(os.environ["C_ACCEPTANCE_ORACLE_CODE"])
def load(*p): return json.load(open(os.path.join(base, *p)))
def txt(*p): return open(os.path.join(base, *p)).read().strip()
def st(name, label): return load(name, f"state-{label}.json")
def kv(name, file): return dict(l.split(": ") for l in txt(name, file).splitlines())
checks = []
def check(id_, text, ok, detail=""):
    checks.append({"id": id_, "check": text, "ok": bool(ok), "detail": str(detail)})

fresh = st("main", "fresh"); pf = kv("main", "procs-fresh.txt")
check("C1", "launch starts no provider, run host, PTY or terminal; actions are available",
      pf["run-hosts"] == "0" and pf["ptmx-fds"] == "0" and pf["fixture-procs"] == "0"
      and fresh["conversationTerminals"] == [] and fresh["catalog"]["actionsAvailable"] is True, str(pf))

cl = st("main", "claude-live"); c1 = cl["conversationTerminals"]
check("C1", "start-Claude creates a live terminal; the hook helper of the package is used",
      len(c1) == 1 and "READY" in c1[0]["screenTail"] and cl["catalog"]["selectedProvider"] == "claude"
      and cl["catalog"]["selectedHasTerminalView"] is True, c1[0]["screenTail"][-120:] if c1 else "no terminal")
dc = st("main", "claude-after-double-click"); pc = kv("main", "procs-claude.txt")
check("C1", "two start clicks in a row created one conversation and one run",
      len(dc["conversationTerminals"]) == 1 and dc["runtime"]["liveRuns"] == 1 and int(pc["fixture-procs"]) >= 1
      and len([r for r in dc["catalog"]["activityRowDetails"]]) == 1, f"terminals={len(dc['conversationTerminals'])} runs={dc['runtime']['liveRuns']}")
ct = st("main", "claude-typed")
check("C1", "typed input reaches the provider and hooks bring the card to Ready",
      "echo: hello from" in ct["conversationTerminals"][0]["screenTail"] and ct["catalog"]["selectedIndicator"] in ("Ready", "Finished"),
      ct["catalog"]["selectedIndicator"])
home = os.path.realpath(os.path.expanduser("~"))
check("C1", "projectless Claude runs in the home folder",
      ("cwd=" + home) in c1[0]["screenTail"], c1[0]["screenTail"][:200])

cx = st("main", "codex-live"); p2 = kv("main", "procs-two.txt")
check("C1", "start-Codex in a project creates a second terminal; its own Codex server is running; both conversations have run hosts",
      len(cx["conversationTerminals"]) == 2 and cx["runtime"]["codexServerRunning"] is True and cx["runtime"]["codexLeases"] == 1
      and int(p2["run-hosts"]) >= 2
      and cx["catalog"]["selectedProvider"] == "codex", str(cx["runtime"]))
alpha_rows = [r for r in st("main", "codex-identity")["catalog"]["activityRowDetails"] if r["provider"] == "codex"]
check("C2", "the Codex conversation got its thread identity and belongs to the project",
      len(alpha_rows) == 1 and alpha_rows[0]["conversationID"] != "" and st("main", "codex-identity")["catalog"]["selectedProjectID"] is not None,
      str(alpha_rows))

cs = st("main", "claude-stopped"); ca = st("main", "codex-after-stop"); pa = kv("main", "procs-after-stop.txt")
check("C5", "stopping one conversation left the other one's input/output working",
      len(cs["conversationTerminals"]) == 1 and "CODEX-TURN-DONE completed echo still alive" in ca["conversationTerminals"][0]["screenTail"],
      ca["conversationTerminals"][0]["screenTail"][-100:])
check("C5", "the stopped conversation's process is gone and only the other run remains",
      cs["runtime"]["liveRuns"] == 1 and cs["runtime"]["codexLeases"] == 1, str(cs["runtime"]))

rs = st("main", "claude-resumed")
resumed = [t for t in rs["conversationTerminals"] if "remembered=1" in t["screenTail"]]
check("C2", "resume reopened the same provider conversation with its history, on the same card",
      len(resumed) == 1 and resumed[0]["owner"] == st("main", "claude-live")["conversationTerminals"][0]["owner"], str(len(resumed)))

cc = st("main", "claude-cleared")
codex_owner = [t["owner"] for t in st("main", "codex-live")["conversationTerminals"]
               if t["owner"] != st("main", "claude-live")["conversationTerminals"][0]["owner"]][0]
cleared_owner = [t["owner"] for t in cc["conversationTerminals"] if t["owner"] != codex_owner]
old_claude = st("main", "claude-live")["conversationTerminals"][0]["owner"]
check("C2", "/clear moved the run to a new card; the old card keeps its history and lost the terminal",
      len(cc["catalog"]["activityRowDetails"]) >= 3 and len(cleared_owner) == 1 and cleared_owner[0] != old_claude,
      f"rows={len(cc['catalog']['activityRowDetails'])} owners={[t['owner'] for t in cc['conversationTerminals']]}")

ao, ad = st("main", "approval-open"), st("main", "approval-done")
check("C4", "a Codex approval shows on the right card with its summary and Needs approval, unanswered",
      len(ao["catalog"]["selectedRequests"]) == 1 and ao["catalog"]["selectedRequests"][0]["answerable"] is True
      and ao["catalog"]["selectedIndicator"] == "Needs approval", str(ao["catalog"]["selectedRequests"]))
check("C4", "only the user's Approve resolved it; the turn then completed",
      approval_done(ao, ad), str(ad["catalog"]["selectedRequests"]))

ha = st("main", "hidden-active"); ph = kv("main", "procs-hidden-active.txt")
check("C1", "screenshots of the live terminal card and of the approval banner exist",
      all(os.path.getsize(os.path.join(base, "main", f"screenshot-{n}.png")) > 20000 for n in ["claude-terminal", "codex-approval"]))
check("D3", "closing the window keeps the working conversation alive",
      hidden_working(ha) and int(ph["fixture-procs"]) >= 1, str(ph))
q = load("main", "quit.json"); aq = kv("main", "after-quit-procs.txt")
check("D3", "Quit with an active turn and a hidden window succeeded; owned processes are gone",
      q["succeeded"] is True and q["remaining"] == 0 and aq["fixture-procs"] == "0" and aq["test-child-procs"] == "0"
      and txt("main", "after-quit.txt") == "app exited", f"{q} {aq}")
sv = load("main", "after-quit-scope.json")
check("D3", "after Quit no run host of the package is left, and none of the recorded scope's members or coalition remain",
      aq["run-hosts"] == "0" and sv["clean"] is True and sv["recordedHosts"] >= 1, f"{aq} {sv}")
check("D3", "the unrelated control process was not touched", aq["outsider-alive"] == "yes")

ro = st("reopened", "reopened"); pr = kv("reopened", "procs-reopened.txt")
check("C3", "reopening restores the conversations and starts no provider, PTY or terminal",
      len(ro["catalog"]["activityRowDetails"]) >= 3 and ro["conversationTerminals"] == [] and pr["run-hosts"] == "0"
      and pr["ptmx-fds"] == "0" and pr["fixture-procs"] == "0" and ro["runtime"]["liveRuns"] == 0
      and ro["runtime"]["codexServerRunning"] is False, str(pr))
check("C3", "the restored cards are history (no live run) and can be resumed",
      all(r["live"] is False for r in ro["catalog"]["activityRowDetails"]), str([r["live"] for r in ro["catalog"]["activityRowDetails"]]))

qs = st("quit-start", "starting"); qsq = load("quit-start", "quit.json")
qp = kv("quit-start", "after-quit-procs.txt"); counts = txt("quit-start", "catalog-counts.txt").splitlines()
check("D3", "Quit while a start was still resolving its environment succeeded and started nothing",
      qs["catalog"]["startingKeys"] != [] and qsq["succeeded"] is True and qp["fixture-procs"] == "0" and qp["run-hosts"] == "0" and counts == ["0", "0"],
      f"starting={qs['catalog']['startingKeys']} counts={counts}")

f1, f2 = load("quit-retry", "quit-attempt-1.json"), load("quit-retry", "quit-attempt-2.json")
af = st("quit-retry", "after-failed-quit"); pf2 = kv("quit-retry", "procs-after-failed-quit.txt")
check("D3", "a forced failed Quit shows no success: the alert is up, the app and its conversation stay",
      f1["succeeded"] is False and f1.get("remainingCountVerified") is False and f1["remaining"] is None
      and "failed" in af["quitState"] and af["quitAlert"] is not None
      and int(pf2["fixture-procs"]) >= 1 and len(af["conversationTerminals"]) == 1,
      f"{af['quitState']} alert={af['quitAlert']} procs={pf2}")
check("D3", "Try Again then succeeded, the app exited and no fixture process is left",
      f2["succeeded"] is True and txt("quit-retry", "after-quit.txt") == "app exited"
      and kv("quit-retry", "after-quit-procs.txt") == {"fixture-procs": "0", "run-hosts": "0"}, str(f2))

os.makedirs(base, exist_ok=True)
json.dump({"run": "cp5-c-" + stamp, "checks": checks}, open(os.path.join(base, "checks.json"), "w"), indent=2)
PYEOF
# `status` is read-only in zsh; keep the verdict's own exit code.
python3 "$root/scripts/cp5-b-summary.py" "$base" > "$base/verdict.txt" && verdict=0 || verdict=$?
cat "$base/verdict.txt"
experiments=${LOOM_EXPERIMENT_DIR:-$root/plans/experiments}
mkdir -p "$experiments"
cp "$base/summary.json" "$experiments/cp5-c-acceptance.json"
exit $verdict
