#!/bin/zsh
# CHECKPOINT-5-HISTORY §6 starting measurements for the A slice (one synthetic terminal).
# Usage: scripts/cp5-a-measure.sh [repetitions=3] [path/to/Loom Dev.app]
# (default: ~/Library/Application Support/Loom-Dev/app; a path under ~/Documents is refused)
# Per scenario: warm-up (10 s), then a sample (60 s) bounded by two app
# snapshots. CPU = cumulative CPU delta / monotonic sample time (% of one
# core). A repetition is invalid (and reported so, never as zero) when a
# snapshot is missing, the window state differs from the scenario, or any
# visibility/occlusion change falls inside the sample. `frames` are frame-
# driver ticks; `renders` are completed draws. Feed percentiles come from the
# difference of cumulative histograms over the same interval (bucket upper
# bounds, powers of two µs). Input→draw latency (latency-* scenario) has its
# own interval and validity: every sample measured, no timeout, window
# visible and unoccluded, no visibility change during that run. Run hosts and
# other scope members are counted (scopeCPUPercent); an unreadable member
# invalidates the sample, and after Quit none of them may remain.
# Evidence: ~/Library/Application Support/Loom-Dev/probe/runs/cp5-a-measure-<ts>/
set -euo pipefail

root=${0:A:h:h}
source "$root/scripts/dev-paths.sh"
reps=${1:-3}
app=${2:-$loom_default_app}
loom_refuse_documents "App path" "$app"
base="$HOME/Library/Application Support/Loom-Dev/probe/runs/cp5-a-measure-$(date +%Y%m%dT%H%M%S)"
mkdir -p "$base"
warmup=${LOOM_MEASURE_WARMUP:-10} sample=${LOOM_MEASURE_SAMPLE:-60}

# The evidence instance being driven; set by launch/finish before any command.
evidence_dir=""
send_command() { loom_send_command "${evidence_dir:?no evidence directory selected}" "$1"; }
wait_file() { for _ in {1..600}; do [[ -f "$1" ]] && return 0; sleep 0.1; done; echo "missing $1" >&2; return 1; }
# CPU/footprint sources carry exact app and supervisor-recorded birth identities.
resource_snapshot() {
  python3 "$root/scripts/cp5-d-measure.py" --snapshot-directory "$1" > "$1/resource-$2.json"
  python3 - "$1" "$2" <<'EOF'
import json, sys
from pathlib import Path
d, label = Path(sys.argv[1]), sys.argv[2]
ack = json.loads((d / f"resource-{label}.json").read_text())
(d / f"state-{label}.json").write_text(json.dumps(ack["app"]))
result = ack["result"]
cpu, identities = {}, {}
def add(identity, usage):
    if identity and usage:
        key = str(identity["pid"])
        cpu[key] = (usage["userTimeNanoseconds"] + usage["systemTimeNanoseconds"]) / 1e9
        identities[key] = identity
add(result["appIdentity"], result["appUsage"])
for row in result["supervisorRuns"]:
    if not row["identityMatches"]: raise SystemExit("Registered fixture identity changed")
    add(row["identity"], row["usage"])
for row in result["windowServers"]: add(row["identity"], row["usage"])
scope = result.get("scope") or {}
if scope.get("valid") is not True: raise SystemExit(f"Scope accounting invalid: {scope.get('invalid')}")
scope_pids = []
for kind in ("hosts", "others"):
    for row in scope[kind]:
        if not row["usage"]: raise SystemExit("Scope member usage missing")
        add(row["identity"], row["usage"]); scope_pids.append(str(row["identity"]["pid"]))
(d / f"cpu-{label}.json").write_text(json.dumps({"uptime": result["uptime"], "cpu": cpu, "identities": identities,
                                                 "scope": scope_pids, "hostCount": len(scope["hosts"])}))
footprint = (result.get("appUsage") or {}).get("physicalFootprintBytes")
(d / f"footprint-{label}.txt").write_text(str(footprint) + " B" if footprint is not None else "unavailable")
EOF
}
active_dir="" active_pid=""
cleanup_active() {
  local original_exit=$?
  trap - EXIT
  if [[ -n $active_dir && ! -f "$active_dir/quit.json" ]]; then
    python3 "$root/scripts/cp5-d-measure.py" --quit-directory "$active_dir" > "$active_dir/cleanup-quit-ack.json" 2>&1 || true
  fi
  if [[ -n $active_dir && -f "$active_dir/quit.json" ]]; then
    python3 "$root/scripts/cp5-d-check-quit.py" "$active_dir" "$app" > "$active_dir/cleanup-trap.json" 2>&1 || original_exit=1
  fi
  exit $original_exit
}
trap cleanup_active EXIT

measure() { # name extra-args fixture-args show|hide rep
  local name=$1 extra=$2 fixture=$3 hide=$4 rep=$5
  local dir="$base/$name-$rep"
  if [[ $name == latency* ]]; then
    # The legacy --fixture belongs to TerminalRunController, while resource
    # latency intentionally requires the selected EvidenceResourcePool surface.
    python3 "$root/scripts/cp5-d-measure.py" --app "$app" --scenario latency \
      --warmup "$warmup" --visibility visible --output "$dir"
    python3 - "$dir/result.json" "$name" "$rep" <<'EOF' | tee -a "$base/results.jsonl"
import json, sys
result = json.load(open(sys.argv[1]))
print(json.dumps(result | {"scenario": sys.argv[2], "rep": int(sys.argv[3])}))
EOF
    return
  fi
  mkdir -p "$dir"
  local -a launch_args=(--evidence "$dir" --data-root "$dir/data" ${=extra})
  [[ -n $fixture ]] && launch_args+=(--fixture ${=fixture})
  active_dir="$dir"; evidence_dir="$dir"
  open -a "$app" --args "${launch_args[@]}"
  wait_file "$dir/launched.json"
  active_dir="$dir"
  local pid
  pid=$(python3 - "$dir/launched.json" <<'EOF'
import json,sys
print(json.load(open(sys.argv[1]))["pid"])
EOF
)
  active_pid=$pid
  sleep 1
  [[ $hide == hide ]] && python3 "$root/scripts/cp5-d-measure.py" --operation-directory "$dir" --operation hide > "$dir/hide-ack.json"
  sleep $warmup
  resource_snapshot "$dir" start
  local child
  child=$(python3 - "$dir/resource-start.json" "${fixture}" <<'EOF'
import json,sys
runs=json.load(open(sys.argv[1]))["result"]["supervisorRuns"]
if len(runs) != (1 if sys.argv[2] else 0): raise SystemExit("Unexpected registered fixture count")
print(runs[0]["identity"]["pid"] if runs else "")
EOF
)
  local ws
  ws=$(python3 - "$dir/resource-start.json" <<'EOF'
import json,sys
rows=json.load(open(sys.argv[1]))["result"]["windowServers"]
print(rows[0]["identity"]["pid"] if len(rows)==1 else "")
EOF
)
  sleep $sample
  resource_snapshot "$dir" end
  if [[ $name == latency* ]]; then
    python3 "$root/scripts/cp5-d-measure.py" --operation-directory "$dir" --operation latency --operation-argument 200 > "$dir/latency-ack.json" || true
    wait_file "$dir/latency.json" || true
  fi
  sleep 0.5
  local measurement_result=0
  python3 - "$dir" "$name" "$rep" "$hide" "$pid" "$ws" "${child:-}" <<'EOF' | tee -a "$base/results.jsonl" || measurement_result=$?
import json, os, sys
d, name, rep, hide, pid, ws, child = sys.argv[1:]
def load(f):
    try: return json.load(open(f"{d}/{f}"))
    except Exception: return None
s, e = load("state-start.json"), load("state-end.json")
c0, c1 = load("cpu-start.json"), load("cpu-end.json")
invalid = []
if not (s and e and c0 and c1): invalid.append("missing snapshot")
if c0 and c1 and c0.get("identities") != c1.get("identities"): invalid.append("recorded process identity changed")
for label, counters in (("start", c0), ("end", c1)):
    for required in filter(None, (pid, child, *((counters or {}).get("scope", [])))):
        if not counters or required not in counters.get("cpu", {}): invalid.append(f"{label} CPU for registered PID {required} missing")
expect_visible = hide != "hide"
for label, st in (("start", s), ("end", e)):
    if st and (st["windowVisible"] != expect_visible or st["windowOcclusionVisible"] != expect_visible):
        invalid.append(f"{label} visibility {st['windowVisible']}/{st['windowOcclusionVisible']}")
if s and e:
    inside = [v for v in e.get("visibilityEvents", []) if s["uptime"] <= v["uptime"] <= e["uptime"]]
    if inside: invalid.append(f"{len(inside)} visibility change(s) inside sample")
row = {"scenario": name, "rep": int(rep), "valid": not invalid, "invalidReasons": invalid}
if c0 and c1:
    span = c1["uptime"] - c0["uptime"]
    if span <= 0: invalid.append("nonpositive sample interval")
    pct = lambda p: round((c1["cpu"][p] - c0["cpu"][p]) / span * 100, 2) if span > 0 and p in c0["cpu"] and p in c1["cpu"] else None
    row.update(sampleSeconds=round(span, 3), appCPUPercent=pct(pid),
               fixtureCPUPercent=pct(child) if child else None, windowServerCPUPercent=pct(ws),
               scopeCPUPercent=round(sum(pct(p) or 0 for p in c0.get("scope", [])), 2),
               runHosts=c1.get("hostCount"))
    if c0.get("scope") != c1.get("scope"): invalid.append("scope member set changed inside sample")
row["appFootprint"] = [open(f"{d}/footprint-{k}.txt").read().strip() for k in ("start", "end")]
if "unavailable" in row["appFootprint"]: invalid.append("physical footprint unavailable")
ts, te = (s or {}).get("terminal"), (e or {}).get("terminal")
if ts and te:
    h = [b - a for a, b in zip(ts["feedHistogramMicroseconds"], te["feedHistogramMicroseconds"])]
    total = sum(h)
    def bound(q):
        if total == 0: return None
        acc = 0
        for i, n in enumerate(h):
            acc += n
            if acc >= q * total: return 2 ** i / 1000 if i < len(h) - 1 else None
    row.update(frames=te["frames"] - ts["frames"], renders=te["renders"] - ts["renders"],
               outputBytes=te["outputBytes"] - ts["outputBytes"], feedBatches=total,
               feedP95UpperBoundMs=bound(0.95), feedMaxUpperBoundMs=bound(1.0),
               runMaxFeedMs=te["maxFeedMilliseconds"])
if name.startswith("latency"):
    # The latency run has its own interval and validity (not the CPU window).
    lat = load("latency.json")
    if lat is None:
        row["inputToDraw"] = {"valid": False, "invalidReasons": ["latency.json missing"]}
    else:
        row["inputToDraw"] = {k: lat.get(k) for k in ("valid", "invalidReasons", "samples", "measured", "timeouts",
                                                       "p50Milliseconds", "p95Milliseconds", "maxMilliseconds")}
        if lat.get("measured") != lat.get("samples") or lat.get("timeouts"):
            row["inputToDraw"]["valid"] = False
if name.startswith("latency") and not row["inputToDraw"].get("valid"):
    invalid.append("input-to-draw run invalid")
row["valid"] = not invalid
print(json.dumps(row))
sys.exit(0 if row["valid"] else 1)
EOF
  python3 "$root/scripts/cp5-d-measure.py" --quit-directory "$dir" > "$dir/quit-ack.json"
  wait_file "$dir/quit.json"
  for _ in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  python3 "$root/scripts/cp5-d-check-quit.py" "$dir" "$app" > "$dir/cleanup-check.json"
  active_dir="" active_pid=""
  return $measurement_result
}

if pgrep -f "Loom Dev.app/Contents/MacOS/Loom Dev" >/dev/null; then
  echo "Loom Dev is already running; quit it first." >&2; exit 2
fi
rate=1048576
total=$(python3 - "$rate" "$warmup" "$sample" <<'EOF'
import sys
print(int(int(sys.argv[1]) * (float(sys.argv[2]) + float(sys.argv[3]) + 20)))
EOF
)
for rep in $(seq 1 $reps); do
  measure idle-visible "" "" show $rep
  measure idle-hidden "" "interactive" hide $rep
  measure stream-visible-cg "" "stream $rate $total" show $rep
  measure stream-visible-metal "--metal" "stream $rate $total" show $rep
  measure stream-hidden "" "stream $rate $total" hide $rep
  measure latency-visible "" "interactive" show $rep
done
echo "$base"
