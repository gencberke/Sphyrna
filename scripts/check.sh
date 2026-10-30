#!/bin/zsh
# The repo's required local checks in one command (there is no CI). DEVELOPMENT.md §2.
# Usage: scripts/check.sh [--unit] [--integration] [--tests] [--suite <Name>...] [--frozen] [--windows --idle]
#                         [--full --idle] [--release-tree] [--scratch <path>] [--macro-plugin <dylib>]
#   default   git diff --check, git diff --cached --check, trailing whitespace in untracked files, zsh -n on
#             scripts/**/*.sh, py_compile on scripts/**/*.py, clang -Wall -Wextra -Werror -fsyntax-only on the C
#             sources, the source guards and the test guard (scripts/check-source-guards.py, check-tests.py), then
#             swift build (debug) in the build slot. After any test step the log goes into the test ledger
#             (scripts/test-ledger.py) and the wall time per target and the five slowest tests are printed.
#   Tests run by tier, and a tier is its targets (DEVELOPMENT §2): T1 unit is the area targets, T2 integration is
#   LoomIntegrationTests, T3 window is LoomWindowTests, TF frozen is LoomFrozenTests.
#   --unit    adds T1 in debug: the routine slice check.
#   --integration  adds T2 in debug.
#   --tests   adds T1 and T2 in debug.
#   --suite   adds swift test --filter <Name> per name (target, suite or test name, a regex), never in the window or
#             frozen target: --windows and --frozen run those whole.
#   --frozen  adds TF in debug, after the rest: code D-100 and D-102 left unreachable, kept and compiled, run on demand;
#             with --suite, the named suites there instead of the whole lane.
#   --windows adds T3 in a swift test of its own, after every other test step; needs --idle (unlocked screen, Mac idle
#             by the user's word); with --suite, the named suites there instead of the whole of T3, and nowhere else.
#   --full    needs --idle: the staged release-tree build (--release-tree), then swift test -c release over T1 and T2
#             (the release test build), then T3 alone in release. No plain swift build -c release: packaging builds
#             its products by name, and the release test build compiles everything the gate runs (D-119).
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

# The tiers, by target: a test target is its own test product and run, and its name is the one prefix a test cannot forget.
unit_targets=(LoomCoreTests LoomTerminalTests LoomChatTests LoomRemoraTests LoomLaunchOptionsTests LoomCatalogUITests)

usage() { sed -n '2,/^set -euo/p' "$script_path" | sed '$d; s/^# \{0,1\}//' >&2; }
die_usage() { echo "check: $1" >&2; exit 2; }

suites=() run_tests=0 unit=0 integration=0 frozen=0 windows=0 idle=0 full=0 release_tree=0 macro_plugin=""
while (( $# )); do
  case $1 in
    --suite) shift; (( $# )) && [[ $1 != -* ]] || die_usage "--suite needs at least one name"
             while (( $# )) && [[ $1 != -* ]]; do suites+=($1); shift; done; continue ;;
    --tests) run_tests=1 ;;
    --unit) unit=1 ;;
    --integration) integration=1 ;;
    --frozen) frozen=1 ;;
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
(( run_tests || full )) && unit=1 integration=1
[[ -z $macro_plugin || -f $macro_plugin ]] || die_usage "--macro-plugin: no such file: $macro_plugin"
(( full )) && windows=1

scratch=$(loom_scratch_path)
log_dir=${LOOM_CHECK_LOG_DIR:-$HOME/Library/Caches/loom-check-logs}
loom_refuse_documents "LOOM_CHECK_LOG_DIR" "$log_dir"
mkdir -p "$log_dir"
log="$log_dir/check-$(date +%Y%m%dT%H%M%S)-$$.log"
export LOOM_CHECK_LOG_DIR=$log_dir
pycache=$(mktemp -d "${TMPDIR:-/tmp}/loom-check-pycache.XXXXXX")
trap 'rm -rf "$pycache"' EXIT
cd "$root"
# The tree the log speaks for: the ledger keys its runs by it (`+dirty` when tracked files differ from HEAD).
source_sha=$(git rev-parse --short --verify -q HEAD 2>/dev/null || true)
if [[ -n $source_sha ]]; then
  git diff --quiet HEAD -- 2>/dev/null || source_sha+="+dirty"
  print -r -- "=== source: $source_sha" >> "$log"
fi

failed_step="" step_status=0 tests_ran=0
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
# ledger_report: after a test step, files the log in the ledger and prints its summary. It reports; it never fails a check.
ledger_report() {
  (( tests_ran )) || return 0
  python3 scripts/test-ledger.py ingest "$log" >> "$log" 2>&1 || { print -r -- "  (test ledger: could not file this log)"; return 0; }
  python3 scripts/test-ledger.py summary --log "$log" 2>/dev/null | sed 's/^/  /' || true
}
finish() {
  ledger_report
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
unit_filters=(); for t in $unit_targets; do unit_filters+=(--filter "^$t\\."); done
integration_filters=(--filter '^LoomIntegrationTests\.')
window_filters=(--filter '^LoomWindowTests\.')
frozen_filters=(--filter '^LoomFrozenTests\.')
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
step "selectable text labels (LoomCatalogUI, loom-app)" zsh scripts/check-selectable-labels.sh
step "source guards (Sources/)" python3 scripts/check-source-guards.py
step "test guard (Tests/, ratchet)" python3 scripts/check-tests.py
(( full )) || step "swift build" slot swift build --scratch-path "$scratch"
if (( full || release_tree )); then step "staged release tree (build, no evidence code)" loom_check_release_tree; fi
test_cfg=()
(( full )) && test_cfg=(-c release)
(( unit || integration || frozen || windows || ${#suites} )) && tests_ran=1
cfg_label=${test_cfg:+ -c release}
if (( unit || integration )); then
  tiers=() filters=()
  (( unit )) && tiers+=(T1) filters+=($unit_filters)
  (( integration )) && tiers+=(T2) filters+=($integration_filters)
  step "swift test$cfg_label (${(j: and :)tiers})" swift_test $test_cfg $filters
fi
if (( ${#suites} && ! windows )); then
  filters=(); for s in $suites; do filters+=(--filter $s); done
  skips=(--skip '^LoomWindowTests\.'); (( frozen )) || skips+=(--skip '^LoomFrozenTests\.')
  step "swift test --filter ${(j:, :)suites}" swift_test $filters $skips
fi
(( frozen && ! ${#suites} )) && step "swift test (TF frozen)" swift_test $frozen_filters
# The window tests never share a run with another target: offscreen suites host windows too, and in the e58c2c9 gate the
# window tests' clicks, keys and focus did not land among them (each passed alone).
if (( windows && ${#suites} )); then
  step "swift test$cfg_label (T3 window, alone: ${(j:, :)suites})" swift_test $test_cfg --filter "^LoomWindowTests\..*(${(j:|:)suites})"
elif (( windows )); then
  step "swift test$cfg_label (T3 window, alone)" swift_test $test_cfg $window_filters
fi
(( tests_ran )) || echo "  --    tests not run (--unit, --integration, --tests, --suite <Name>, --frozen or --windows)"
if (( tests_ran )); then
  summary=$(grep -E 'Test run with [0-9]+ tests? .*(passed|failed)|Executed [0-9]+ tests?' "$log" | tail -n 2 || true)
  [[ -n $summary ]] && print -r -- "$summary" | sed -E 's/^.*Test run with ([0-9]+) tests?.* passed.*$/\1 tests passed/'
fi
finish
