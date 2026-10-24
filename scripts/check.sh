#!/bin/zsh
# The repo's required local checks in one command (there is no CI). DEVELOPMENT.md §2.
# Usage: scripts/check.sh [--suite <Name>...] [--tests] [--windows --idle] [--full --idle] [--release-tree]
#                         [--scratch <path>] [--macro-plugin <dylib>]
#   default   git diff --check, git diff --cached --check, trailing whitespace in untracked files, zsh -n on
#             scripts/**/*.sh, py_compile on scripts/**/*.py, clang -Wall -Wextra -Werror -fsyntax-only on the C
#             sources, then swift build (debug) in the build slot.
#   --suite   adds swift test --filter <Name> per name (target, suite or test name, a regex).
#   --tests   adds every test target. Tests that open a real window are skipped unless --windows.
#   --windows includes the window tests; needs --idle (unlocked screen, Mac idle by the user's word).
#   --full    needs --idle: release build, the staged release-tree build (--release-tree) and the full
#             release suite, window tests included.
#   --release-tree  exports the promote allowlist from the checked-out tree (uncommitted work included, so it
#             equals HEAD when clean) into <scratch>-release-stage with Package.release.swift as
#             Package.swift, runs swift build -c release there (scratch <path>-release-tree), and fails when the
#             loom-app binary carries development-evidence symbols or strings. The release flavor never rots.
#   --scratch SwiftPM scratch path (or LOOM_SCRATCH_PATH; default ~/Library/Caches/loom-dev-build); never under ~/Documents.
#   --macro-plugin  appends -Xswiftc -load-plugin-library for swift test (only if the Testing macro plugin is not found).
# Every swift command runs through scripts/with-build-slot.sh. Log: $LOOM_CHECK_LOG_DIR (default
# ~/Library/Caches/loom-check-logs)/check-<time>.log. Exit: 0 pass, 1 a check failed, 2 usage or refusal,
# 3 build slot not free in time.
set -euo pipefail

script_path=${0:A}
root=${script_path:h:h}
source "$root/scripts/dev-paths.sh"
source "$root/scripts/release/allowlist.sh"

# Window tests (open a real window: need an unlocked screen). Matched as regexes against test ids.
window_tests=(
  byteQuotaCoversRasterRounding                                  # TerminalImageLimitTests
  layerBackingStorePreservesPixelsOutsideTheDirtyRect            # TerminalPartialDrawTests
  hostedWorkingIndicatorRunsOnlyWhenTheEnvironmentAllowsIt       # SidebarStatusTests
  realSidebarRunsAWorkingRowOnlyForAnActiveWindowAndExpandedSidebar  # SidebarStatusTests
  aClickOnATabSwitchesItAndAPageControlAnswersItsClick           # SettingsWindowClickTests
)

usage() { sed -n '2,/^set -euo/p' "$script_path" | sed '$d; s/^# \{0,1\}//' >&2; }
die_usage() { echo "check: $1" >&2; exit 2; }

suites=() run_tests=0 windows=0 idle=0 full=0 release_tree=0 macro_plugin=""
while (( $# )); do
  case $1 in
    --suite) shift; (( $# )) && [[ $1 != -* ]] || die_usage "--suite needs at least one name"
             while (( $# )) && [[ $1 != -* ]]; do suites+=($1); shift; done; continue ;;
    --tests) run_tests=1 ;;
    --windows) windows=1 ;;
    --idle) idle=1 ;;
    --full) full=1 ;;
    --release-tree) release_tree=1 ;;
    --scratch) (( $# > 1 )) || die_usage "--scratch needs a path"; export LOOM_SCRATCH_PATH=$2; shift ;;
    --macro-plugin) (( $# > 1 )) || die_usage "--macro-plugin needs a dylib path"; macro_plugin=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die_usage "unknown argument: $1" ;;
  esac
  shift
done
(( windows && ! idle )) && die_usage "--windows needs --idle (an unlocked screen and a Mac the user declared idle)"
(( full && ! idle )) && die_usage "--full needs --idle (release suite and window tests only when the user says the Mac is idle)"
[[ -z $macro_plugin || -f $macro_plugin ]] || die_usage "--macro-plugin: no such file: $macro_plugin"
(( full )) && windows=1

scratch=$(loom_scratch_path)
log_dir=${LOOM_CHECK_LOG_DIR:-$HOME/Library/Caches/loom-check-logs}
loom_refuse_documents "LOOM_CHECK_LOG_DIR" "$log_dir"
mkdir -p "$log_dir"
log="$log_dir/check-$(date +%Y%m%dT%H%M%S)-$$.log"
pycache=$(mktemp -d "${TMPDIR:-/tmp}/loom-check-pycache.XXXXXX")
trap 'rm -rf "$pycache"' EXIT
cd "$root"

failed_step="" step_status=0
# step <label> <command...>: runs the command, appends its output to the log, prints one line.
step() {
  local label=$1; shift
  print -r -- "=== $label: $*" >> "$log"
  local code=0
  "$@" >> "$log" 2>&1 || code=$?
  if (( code == 0 )); then
    print -r -- "  ok    $label"
  else
    print -r -- "  FAIL  $label (exit $code)"
    failed_step=$label step_status=$code
    echo "--- last log lines:" >&2; tail -n 15 "$log" >&2
    finish
  fi
}
finish() {
  if [[ -n $failed_step ]]; then
    print -r -- "check: FAIL at '$failed_step' (log: $log)"
    (( step_status == 3 )) && exit 3
    exit 1
  fi
  print -r -- "check: PASS (log: $log)"
  exit 0
}

untracked_whitespace() {
  local files=(${(0)"$(git ls-files --others --exclude-standard -z)"})
  (( ${#files} )) || return 0
  local hits
  hits=$(grep -nIE '[[:blank:]]+$' -- $files || true)
  [[ -z $hits ]] && return 0
  print -r -- "trailing whitespace in untracked files:"; print -r -- "$hits"
  return 1
}
zsh_syntax() { local f; for f in scripts/**/*.sh(N); do zsh -n "$f" || return 1; done; }
python_syntax() { PYTHONPYCACHEPREFIX=$pycache python3 -m py_compile scripts/**/*.py(N); }
c_syntax() {
  local f dir
  for f in Sources/*/*.c(N) scripts/*.c(N); do
    dir=${f:h}
    clang -Wall -Wextra -Werror -fsyntax-only -I "$dir" -I "$dir/include" -I Sources/CLoomPOSIX/include "$f" || return 1
  done
}
slot() { scripts/with-build-slot.sh "$@"; }
# test_runs_passed: reads swift test's output; every "Test run started." has its "Test run with N tests … passed",
# and there is one at least. XCTest's "Executed 0 tests" is no summary for Swift Testing.
test_runs_passed() {
  local line open=0 pairs=0
  while IFS= read -r line; do
    if [[ $line == *'Test run started.'* ]]; then
      (( open )) && return 1
      open=1
    elif [[ $line =~ 'Test run with [0-9]+ tests? .*passed' ]]; then
      (( open )) || return 1
      open=0 pairs=$(( pairs + 1 ))
    fi
  done
  (( !open && pairs > 0 ))
}
swift_test() { # <extra args...>
  local plugin=() start
  [[ -n $macro_plugin ]] && plugin=(-Xswiftc -load-plugin-library -Xswiftc $macro_plugin)
  start=$(( $(wc -c < "$log") + 1 ))
  slot swift test --scratch-path "$scratch" "$@" $plugin || return $?
  # An exit 0 proves nothing without the runs' passing summaries: a test process can end early with status 0.
  tail -c +$start "$log" | test_runs_passed && return 0
  print -r -- "swift test exited 0, but a test run has no passing summary (the test process ended early)"
  return 1
}
skip_args=()
(( windows )) || for t in $window_tests; do skip_args+=(--skip $t); done
# The release flavor (what promote.sh would export: no LOOM_EVIDENCE, no Sources/loom-app/Evidence) must build and
# must not carry the app-side evidence code. Library-side inert seams (TerminalPresentationLog, IndicatorEvidence)
# stay in the binary on purpose.
# The stage keeps one fixed path next to the scratch (re-created each run, file times preserved) so the release
# build stays incremental.
loom_check_release_tree() {
  local release_stage="$scratch-release-stage"
  loom_refuse_documents "release tree" "$release_stage" || return 1
  rm -rf "$release_stage" && mkdir -p "$release_stage" || return 1
  loom_stage_release_tree "$release_stage" || return 1
  cp scripts/release/Package.release.swift "$release_stage/Package.swift" || return 1
  slot swift build -c release --package-path "$release_stage" --scratch-path "$scratch-release-tree" || return 1
  local binary="$scratch-release-tree/release/loom-app" hits
  [[ -x $binary ]] || { print -r -- "no release loom-app binary at $binary"; return 1; }
  hits=$({ nm -a "$binary" 2>/dev/null; strings -a "$binary"; } \
    | grep -E 'DevelopmentEvidence|EvidenceResourcePool|EvidenceStreamAudit|fail-first-quit|LOOM_FORCE_SCOPE_FAILURE|fake-toolchain-delay|evidence-resources' | head -n 10 || true)
  [[ -z $hits ]] || { print -r -- "development evidence code in the release loom-app binary:"; print -r -- "$hits"; return 1; }
  print -r -- "release tree builds; no app-side evidence symbols or strings in $binary"
}

step "git diff --check" git diff --check
step "git diff --cached --check" git diff --cached --check
step "untracked files: trailing whitespace" untracked_whitespace
step "zsh -n scripts/**/*.sh" zsh_syntax
step "py_compile scripts/**/*.py" python_syntax
step "clang -Werror syntax (C sources)" c_syntax
step "theme literals (LoomCatalogUI)" zsh scripts/check-theme-literals.sh
step "user wording (session, not conversation; Sphyrna, not Loom)" zsh scripts/check-user-wording.sh
if (( full )); then
  step "swift build -c release" slot swift build -c release --scratch-path "$scratch"
else
  step "swift build" slot swift build --scratch-path "$scratch"
fi
if (( full || release_tree )); then step "staged release tree (build, no evidence code)" loom_check_release_tree; fi
test_cfg=()
(( full )) && test_cfg=(-c release)
if (( full || run_tests )); then
  window_label=; (( windows )) && window_label=", windows included"
  step "swift test${test_cfg:+ -c release} (all targets$window_label)" swift_test $test_cfg $skip_args
elif (( ${#suites} )); then
  filters=(); for s in $suites; do filters+=(--filter $s); done
  step "swift test --filter ${(j:, :)suites}" swift_test $filters $skip_args
else
  echo "  --    tests not run (--suite <Name> or --tests)"
fi
if (( full || run_tests || ${#suites} )); then
  summary=$(grep -E 'Test run with [0-9]+ tests? .*(passed|failed)|Executed [0-9]+ tests?' "$log" | tail -n 2 || true)
  [[ -n $summary ]] && print -r -- "$summary" | sed -E 's/^.*Test run with ([0-9]+) tests?.* passed.*$/\1 tests passed/'
fi
finish
