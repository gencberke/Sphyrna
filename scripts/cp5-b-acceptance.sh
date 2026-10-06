#!/bin/zsh
# CP5 B acceptance through LaunchServices on isolated data (B1 package
# migration, B2, B4, B5). Nothing here starts a provider or spends a model turn.
# "Nothing started" is proved by the absence of run hosts (every run lives in
# a LoomRunHost scope), PTY descriptors and terminals, and Quit by no host left.
# Synthetic catalog/terminal evidence uses --fake-providers with the fixture
# binary directory. Provider profiles/state stay under each isolated data-root;
# this enables unredacted fixture evidence without selecting real user profiles.
# Usage: scripts/cp5-b-acceptance.sh [path/to/Loom Dev.app]
#   default: ~/Library/Application Support/Loom-Dev/app (a path under ~/Documents is refused)
# Raw-only recovery: scripts/cp5-b-acceptance.sh --summarize-only existing-run-directory
# Evidence: ~/Library/Application Support/Loom-Dev/probe/runs/cp5-b-<timestamp>/
set -euo pipefail

root=${0:A:h:h}
if [[ ${1:-} == --summarize-only ]]; then
  base=${2:?Usage: cp5-b-acceptance.sh --summarize-only existing-run-directory}
  stamp=${base:t}
  stamp=${stamp#cp5-b-}
else
source "$root/scripts/dev-paths.sh"
app=${1:-$loom_default_app}
loom_refuse_documents "App path" "$app"
stamp=$(date +%Y%m%dT%H%M%S)
base="$HOME/Library/Application Support/Loom-Dev/probe/runs/cp5-b-$stamp"
mkdir -p "$base"
cd "$root"
# Run hosts execute the fake provider: build outside ~/Documents and run a copy from there.
build=(swift build --scratch-path "$(loom_scratch_path)")
for product in loom-catalog-fixture loom-fake-provider; do "${build[@]}" --product $product >/dev/null 2>&1; done
bin=$("${build[@]}" --show-bin-path)
mkdir -p "$base/fixtures"
cp "$bin/loom-catalog-fixture" "$bin/loom-fake-provider" "$base/fixtures/"
fixture="$base/fixtures/loom-catalog-fixture"
# Hosts are found by executable path (proc_pidpath), not by command line.
host_count() { python3 "$root/scripts/cp5-scope-probe.py" hosts "$app"; }

# The evidence instance being driven; set by launch/finish before any command.
evidence_dir=""
send_command() { loom_send_command "${evidence_dir:?no evidence directory selected}" "$1"; }
wait_file() { for _ in {1..300}; do [[ -f "$1" ]] && return 0; sleep 0.1; done; echo "missing $1" >&2; return 1; }
app_pid() { pgrep -f "$app/Contents/MacOS/Loom Dev" | head -1; }
jq_() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2"; }

if pgrep -f "Loom Dev.app/Contents/MacOS/Loom Dev" >/dev/null; then
  echo "Loom Dev is already running; quit it first." >&2; exit 2
fi

snap() { # dir label
  rm -f "$1/state-$2.json"; send_command "snapshot:$2"; wait_file "$1/state-$2.json"; sleep 0.2
}
cmd() { send_command "$1"; sleep "${2:-1.2}"; }
procs() { # dir label: run hosts of this package and PTY descriptors of the app process
  local pid=$(cat "$1/app-pid.txt")
  { echo "run-hosts: $(host_count)"
    echo "ptmx-fds: $(lsof -p "$pid" 2>/dev/null | grep -c 'ptmx' || true)"
    echo "threads: $(ps -M -p "$pid" | tail -n +2 | wc -l | tr -d ' ')"
    echo "rss-kb: $(ps -o rss= -p "$pid" | tr -d ' ')"; } > "$1/procs-$2.txt"
}
launch() { # name datadir [args...]
  local name=$1 data=$2; shift 2
  local dir="$base/$name"; mkdir -p "$dir"
  evidence_dir="$dir"
  open -a "$app" --args --evidence "$dir" --data-root "$data" --fake-providers "${fixture:h}" "$@"
  wait_file "$dir/launched.json"
  for _ in {1..100}; do
    snap "$dir" ready
    [[ $(jq_ "$dir/state-ready.json" "d['catalog']['ready']") == True ]] && break
    sleep 0.2
  done
  pgrep -f "$app/Contents/MacOS/Loom Dev" | head -1 > "$dir/app-pid.txt"
}
finish() { # dir
  local dir=$1 pid=$(cat "$1/app-pid.txt")
  evidence_dir="$dir"
  rm -f "$dir/quit.json"; send_command quit; wait_file "$dir/quit.json"
  for _ in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  { kill -0 "$pid" 2>/dev/null && echo "app still running" || echo "app exited"; } > "$dir/after-quit.txt"
  for _ in {1..100}; do [[ $(host_count) == 0 ]] && break; sleep 0.1; done
  echo "run-hosts: $(host_count)" > "$dir/after-quit-hosts.txt"
}

# ---- 1) Schema 1 catalog opened by the packaged app (B1) ----------------------
v1="$base/data-v1"
"$fixture" seed-v1 "$v1" > "$base/v1-seed.json"
dump() { sqlite3 "$v1/catalog.sqlite3" "select 'sessions',id,provider,provider_conversation_id,working_directory,title,created_at,last_used_at,lifecycle,pinned from sessions order by id; select 'runs',* from runs order by id; select 'links',* from run_sessions order by run_id,session_id; select 'identity',* from provider_identity_changes order by sequence;"; }
dump > "$base/v1-before.txt"
sqlite3 "$v1/catalog.sqlite3" "pragma user_version" > "$base/v1-version-before.txt"
launch schema-one "$v1"
snap "$base/schema-one" opened; procs "$base/schema-one" opened
cmd screenshot:schema-one 1.5
finish "$base/schema-one"
dump > "$base/v1-after.txt"
sqlite3 "$v1/catalog.sqlite3" "pragma user_version; pragma quick_check; pragma foreign_key_check;" > "$base/v1-version-after.txt"

# ---- 2) 10,000 rows: window, modes, search, projects, titles (B2, B4, B5) -----
data="$base/data-10k"
"$fixture" seed "$data" 10000 3 > "$base/seed.json"
newest=$(jq_ "$base/seed.json" "d['newest'][1]")
inproject=$(jq_ "$base/seed.json" "d['firstInFirstProject'][0]")
project0=$(jq_ "$base/seed.json" "d['projects'][0]['id']")
project1=$(jq_ "$base/seed.json" "d['projects'][1]['id']")
mkdir -p "$base/extra/alpha" "$base/extra/beta"
launch main "$data"
d="$base/main"
snap "$d" fresh; procs "$d" fresh
cmd screenshot:activity-1220x780 1.5
cmd "select:$newest"; cmd screenshot:selected 1.5; snap "$d" selected
cmd view-mode:projects; cmd screenshot:projects-1220x780 1.5; snap "$d" projects; procs "$d" projects
cmd "search:codex 77"; snap "$d" search-projects; cmd screenshot:search-projects 1.5
cmd view-mode:activity; snap "$d" search-activity; cmd screenshot:search-activity 1.5
cmd "search:"; snap "$d" search-cleared
# Projects: add, repeat (same folder, trailing slash), second, move, collapse, remove.
cmd "add-project:$base/extra/alpha"; snap "$d" added-alpha
cmd "add-project:$base/extra/alpha/"; snap "$d" added-alpha-again
cmd "add-project:$base/extra/beta"; snap "$d" added-beta
alpha=$(jq_ "$d/state-added-beta.json" "[p['id'] for p in d['catalog']['projects'] if p['name']=='alpha'][0]")
beta=$(jq_ "$d/state-added-beta.json" "[p['id'] for p in d['catalog']['projects'] if p['name']=='beta'][0]")
cmd "move-project:$beta:-1"; snap "$d" moved-beta
cmd "toggle-project:$project1"; snap "$d" collapsed-project1
cmd screenshot:projects-collapsed 1.5
cmd "remove-project:$project0"; snap "$d" remove-nonempty
cmd "remove-project:$alpha"; snap "$d" removed-alpha
# Titles: rename, then a terminal title event must not replace it.
cmd "select:$inproject"
cmd "begin-rename:$inproject" 1.5; snap "$d" rename-sheet-open
cmd "rename-text:Renamed by the user"; cmd rename-commit 1.5; snap "$d" renamed
# A rename must update an open search at once (review §27.1 madde 1).
cmd view-mode:activity; cmd "search:Renamed by the user"; snap "$d" search-title-in
cmd "rename:$inproject:Different name"; snap "$d" search-title-out
cmd "rename:$inproject:Renamed by the user"; snap "$d" search-title-back
cmd "search:"
# Folder panel (review §27.1 madde 3): key/active state must not decide how it opens.
mkdir -p "$base/extra/gamma" "$base/extra/delta"
cmd open-add-project-panel 2; snap "$d" panel-open
cmd close-panel 1.2; snap "$d" panel-closed
cmd open-add-project-panel 2; cmd "panel-choose:$base/extra/gamma" 2; snap "$d" panel-chosen
open -a Finder; sleep 2; snap "$d" app-inactive
cmd open-add-project-panel 2; snap "$d" panel-open-inactive
cmd close-panel 1.2; snap "$d" panel-closed-inactive
open -a "$app"; sleep 1.5
cmd close-window 1.2; snap "$d" window-hidden
cmd open-add-project-panel 2; snap "$d" panel-open-hidden
cmd close-panel 1.2; snap "$d" panel-closed-hidden
open -a "$app"; sleep 1.5
cmd "terminal-title:$inproject:Announced by the terminal"; snap "$d" after-terminal-title
# Window geometry: sidebar drag path, minimum size, collapsed sidebar.
cmd "sidebar-width:380" 1.5; snap "$d" sidebar-380
cmd view-mode:activity; cmd resize:780x500 1.2; cmd screenshot:activity-780x500 1.5; snap "$d" min-size
cmd view-mode:projects; cmd screenshot:projects-780x500 1.5
cmd resize:1220x780 1.0
cmd toggle-sidebar 1.2; snap "$d" collapsed; cmd screenshot:sidebar-collapsed 1.5
cmd toggle-sidebar 1.2
cmd "select:$inproject"; cmd view-mode:projects
snap "$d" before-quit; procs "$d" before-quit
finish "$d"
cp "$data/ui-preferences.json" "$base/preferences-after-run1.json"

# Second launch on the same data: everything must come back, nothing must start.
launch reopened "$data"
d="$base/reopened"
snap "$d" reopened; procs "$d" reopened
cmd screenshot:reopened 1.5
finish "$d"

# Dev synthetic terminal (A path) still works beside the catalog; state updates do not requery.
launch synthetic "$data" --fixture interactive
d="$base/synthetic"
sleep 1.5; snap "$d" live-1; sleep 3; snap "$d" live-2; procs "$d" live
finish "$d"

"$fixture" inspect "$data" "$inproject" "$newest" > "$base/inspect-after.json"
fi
python3 - "$base" "$root" "$stamp" <<'PYEOF'
import json, sys, os, re
base, root, stamp = sys.argv[1], sys.argv[2], sys.argv[3]
def load(*p): return json.load(open(os.path.join(base, *p)))
def txt(*p): return open(os.path.join(base, *p)).read().strip()
seed = load("seed.json"); inspect = load("inspect-after.json")
newest = seed["newest"][1]; inproject = seed["firstInFirstProject"][0]
def procs(name, label):
    return dict(l.split(": ") for l in txt(name, f"procs-{label}.txt").splitlines())
def st(name, label): return load(name, f"state-{label}.json")
checks = []
def check(id_, text, ok, detail="", status=None):
    checks.append({"id": id_, "check": text, "ok": bool(ok), "detail": detail,
                   "status": status or ("passed" if ok else "failed")})

# B1 in the package
before, after = txt("v1-before.txt"), txt("v1-after.txt")
opened = st("schema-one", "opened")["catalog"]
check("B1", "schema 1 file opened by the app; every session/run/link/identity row unchanged",
      before == after and txt("v1-version-before.txt") == "1", f"rows={len(before.splitlines())}")
va = txt("v1-version-after.txt").splitlines()
check("B1", "file is schema 2, quick_check ok, no FK violations", va[:2] == ["2", "ok"] and len(va) == 2, str(va))
check("B1", "app lists both migrated conversations", opened["activityRows"] == 2, str(opened["activityFirstTitles"]))

# B2/B4/B5 main run
fresh = st("main", "fresh"); c = fresh["catalog"]
p = procs("main", "fresh")
check("B2", "launch on 10,000 rows starts no PTY, run host or terminal", p["run-hosts"] == "0" and p["ptmx-fds"] == "0"
      and fresh["terminalSurfaceExists"] is False and fresh["terminalState"] == "idle", str(p))
check("B1", "first page shows at most 100 rows of 10,000", c["activityRows"] == 100 and c["activityHasMore"] is True
      and sum(x["count"] for x in c["projects"]) + c["unassignedCount"] == 10000, f"rows={c['activityRows']}")
check("B5", "start (projects + counts + first page) under 300 ms", c["startMilliseconds"] < 300, f"{c['startMilliseconds']:.1f} ms")
sel = st("main", "selected"); pr = procs("main", "projects")
check("B2", "selecting a history row and switching views starts no PTY/child/terminal",
      sel["catalog"]["selectedSessionID"] == newest and pr["run-hosts"] == "0" and pr["ptmx-fds"] == "0"
      and st("main", "projects")["terminalSurfaceExists"] is False, str(pr))
pj = st("main", "projects")["catalog"]
check("B4", "project view lists projects with paged rows", pj["viewMode"] == "projects" and pj["projectRows"] == [100, 100, 100], str(pj["projectRows"]))
sp, sa = st("main", "search-projects")["catalog"], st("main", "search-activity")["catalog"]
check("B4", "search works in both modes (codex 77)", sp["search"] == "codex 77" and sum(sp["projectRows"]) > 0 and sa["activityRows"] > 0
      and sa["activityHasMore"] is False, f"projects={sp['projectRows']} activity={sa['activityRows']}")
check("B4", "clearing the search restores the first page", st("main", "search-cleared")["catalog"]["activityRows"] == 100)
a1 = st("main", "added-alpha")["catalog"]; a2 = st("main", "added-alpha-again")["catalog"]
check("B4", "adding the same folder twice keeps one project and says so",
      len(a1["projects"]) == 4 and len(a2["projects"]) == 4 and "already" in (a2["infoMessage"] or ""), str(a2["infoMessage"]))
mv = st("main", "moved-beta")["catalog"]["projects"]
check("B2", "project order changes and persists (beta moved before alpha)",
      [x["name"] for x in mv].index("beta") < [x["name"] for x in mv].index("alpha"), str([x["name"] for x in mv]))
col = st("main", "collapsed-project1")["catalog"]["projects"]
check("B2", "collapse is stored", [x for x in col if x["id"] == seed["projects"][1]["id"]][0]["collapsed"] is True)
ne = st("main", "remove-nonempty")["catalog"]
check("B4", "a project with conversations is not removed and the error is visible",
      len(ne["projects"]) == 5 and ne["errorMessage"] is not None and "empty" in ne["errorMessage"], str(ne["errorMessage"]))
ra = st("main", "removed-alpha")["catalog"]
check("B4", "an empty project is removed", all(x["name"] != "alpha" for x in ra["projects"]))
rn = st("main", "renamed")["catalog"]; tt = st("main", "after-terminal-title")["catalog"]
so = st("main", "rename-sheet-open")
po, pc, pch = st("main", "panel-open"), st("main", "panel-closed"), st("main", "panel-chosen")
pai, pci, ai = st("main", "panel-open-inactive"), st("main", "panel-closed-inactive"), st("main", "app-inactive")
wh, poh, pch2 = st("main", "window-hidden"), st("main", "panel-open-hidden"), st("main", "panel-closed-hidden")
sin, sout, sback = (st("main", n)["catalog"] for n in ["search-title-in", "search-title-out", "search-title-back"])
check("B4", "the rename dialog is really presented as a window sheet with the current title",
      so["attachedSheet"] is not None and so["renameDraftText"] == so["catalog"]["selectedTitle"], str(so["attachedSheet"]))
check("B4", "committing the dialog saves the title and dismisses the sheet",
      st("main", "renamed")["attachedSheet"] is None and st("main", "renamed")["catalog"]["selectedTitle"] == "Renamed by the user")
check("B4", "the folder panel (Add Project) opens as a sheet and can be dismissed",
      po["attachedSheet"] is not None and "Panel" in po["attachedSheet"] and pc["attachedSheet"] is None,
      f"{po['attachedSheet']} -> {pc['attachedSheet']}")
check("B4", "choosing a folder in the panel adds the project",
      any(p["name"] == "gamma" for p in pch["catalog"]["projects"]) and pch["attachedSheet"] is None,
      str([p["name"] for p in pch["catalog"]["projects"]]))
check("B4", "with Loom inactive (another app frontmost) the panel still opens as a sheet of the main window",
      ai["appActive"] is False and pai["appActive"] is False and pai["windowIsKey"] is False
      and pai["attachedSheet"] is not None and "Panel" in pai["attachedSheet"] and pci["attachedSheet"] is None,
      f"active={pai['appActive']} key={pai['windowIsKey']} sheet={pai['attachedSheet']}")
check("B4", "with the window closed the panel opens standalone and can be dismissed",
      wh["windowVisible"] is False and poh["openPanelVisible"] is True and poh["attachedSheet"] is None
      and pch2["openPanelVisible"] is False, f"visible={wh['windowVisible']} panel={poh['openPanelVisible']}")
check("B4", "an open search follows a rename: the record leaves and re-enters the results",
      sin["activityRows"] == 1 and sout["activityRows"] == 0 and sout["selectedTitle"] == "Different name"
      and sback["activityRows"] == 1, f"{sin['activityRows']} -> {sout['activityRows']} -> {sback['activityRows']}")
check("B4", "rename shows at once; a terminal title event does not overwrite it",
      rn["selectedTitle"] == "Renamed by the user" and tt["selectedTitle"] == "Renamed by the user", tt["selectedTitle"])
row = [s for s in inspect["sessions"] if s["id"] == inproject][0]
check("B2", "custom title is durable in the catalog", row["title"] == "Renamed by the user" and row["titleIsCustom"] is True)
mn = st("main", "min-size")
check("B4", "minimum window reached: outer frame 780x500 (content area %s)" % mn["windowContentSize"],
      abs(mn["windowFrameSize"][0] - 780) < 2 and abs(mn["windowFrameSize"][1] - 500) < 2, str(mn["windowFrameSize"]))
required_images = ["activity-1220x780", "projects-1220x780", "activity-780x500", "projects-780x500", "sidebar-collapsed"]
missing_images = [n for n in required_images if not os.path.isfile(os.path.join(base, "main", f"screenshot-{n}.png"))]
images_ok = not missing_images and all(os.path.getsize(os.path.join(base, "main", f"screenshot-{n}.png")) > 20000 for n in required_images)
check("B4", "screenshots exist for 1220x780 and 780x500 (both modes)", images_ok,
      "Missing artifacts: " + ", ".join(missing_images) + "; native visual acceptance requires CUA capture." if missing_images else "",
      "unverified" if missing_images else None)
bq = st("main", "before-quit"); pb = procs("main", "before-quit")
check("B2", "nothing started during the whole run", pb["run-hosts"] == "0" and pb["ptmx-fds"] == "0" and bq["terminalSurfaceExists"] is False, str(pb))
check("B5", "no per-row timer/terminal: threads stay small", int(pb["threads"]) < 40, pb["threads"])
check("B5", "loaded rows stay bounded by pages, not by 10,000", bq["catalog"]["loadedRows"] <= 1000, str(bq["catalog"]["loadedRows"]))
check("B2", "quit succeeded and no run host is left", load("main", "quit.json")["succeeded"] is True and txt("main", "after-quit.txt") == "app exited"
      and txt("main", "after-quit-hosts.txt") == "run-hosts: 0")

# Reopen
ro = st("reopened", "reopened"); rc = ro["catalog"]; prefs = load("preferences-after-run1.json")
pr = procs("reopened", "reopened")
check("B2", "reopen keeps view mode, selection and selected title",
      rc["viewMode"] == "projects" == prefs["viewMode"] and rc["selectedSessionID"] == inproject == prefs["selectedSessionID"]
      and rc["selectedTitle"] == "Renamed by the user", f"{rc['viewMode']} {rc['selectedTitle']}")
names = [x["name"] for x in rc["projects"]]
check("B2", "reopen keeps project order and collapse", names == [x["name"] for x in bq["catalog"]["projects"]]
      and [x["collapsed"] for x in rc["projects"]] == [x["collapsed"] for x in bq["catalog"]["projects"]], str(names))
check("B2", "reopen starts no provider, PTY or terminal", pr["run-hosts"] == "0" and pr["ptmx-fds"] == "0" and ro["terminalSurfaceExists"] is False, str(pr))
check("B2", "sidebar preferences file persisted (width=%s collapsed=%s)" % (prefs["sidebarWidth"], prefs["sidebarCollapsed"]), "sidebarWidth" in prefs)
check("B2", "reopened window restores the saved sidebar width", abs(ro["sidebarWidth"] - prefs["sidebarWidth"]) < 2,
      f"saved={prefs['sidebarWidth']} actual={ro['sidebarWidth']}")
check("B2", "reopen quit succeeded", load("reopened", "quit.json")["succeeded"] is True)

# Synthetic dev terminal beside the catalog
l1, l2 = st("synthetic", "live-1")["catalog"], st("synthetic", "live-2")["catalog"]
check("B5", "hub events after the initial reload requery nothing (dev terminal running)",
      l2["pageQueries"] == l1["pageQueries"] and l2["framesApplied"] >= l1["framesApplied"], f"{l1['pageQueries']} -> {l2['pageQueries']}")
check("A", "dev fixture terminal runs; quit clean", st("synthetic", "live-1")["terminalSurfaceExists"] is True
      and load("synthetic", "quit.json")["succeeded"] is True)

# Real-provider evidence deliberately redacts selectedTitle even when no
# provider was started. Missing title evidence is not a product regression.
if rn["selectedTitle"] is None or rc["selectedTitle"] is None:
    title_checks = ["the rename dialog is really", "committing the dialog saves", "an open search follows",
                    "rename shows at once", "reopen keeps view mode, selection and selected title"]
    for item in checks:
        if any(item["check"].startswith(prefix) for prefix in title_checks):
            item.update(ok=False, status="unverified", detail="selectedTitle redacted in raw evidence; this complete criterion is unverified")

# The verdict, summary file and exit status come from one script (selftested).
json.dump({"run": "cp5-b-" + stamp, "checks": checks,
           "statistics": {"start10kMs": c["startMilliseconds"], "pageQueriesAfterRun": bq["catalog"]["pageQueries"],
                          "rowModels": bq["catalog"]["rowModels"]},
           "note": "Missing screenshots and redacted title evidence remain unverified and fail the overall acceptance verdict; native visual acceptance requires CUA capture."},
          open(os.path.join(base, "checks.json"), "w"), indent=2)
PYEOF
python3 "$root/scripts/cp5-b-summary.py" "$base"
