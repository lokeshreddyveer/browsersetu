#!/bin/zsh
# The only supported way to run Browser Setu's Xcode tests (UI and unit). Usage:
#   scripts/test-isolated.sh [--build] <xcodebuild test arguments, e.g. -only-testing:BrowserSetuMacUITests/D1cOneRowUITests ...>
#   scripts/test-isolated.sh --per-class [--build] ...   each test class is its own run with its own before/after proof; stops at the first isolation failure (exit 70)
#   scripts/test-isolated.sh --d1c [--build]      the D1c layout acceptance set (see D1C_SET below)
#
# What it enforces, for every run:
#   * the screenshot-privacy check (no whole-screen capture anywhere in the UI tests),
#   * a relocated home for the app-hosted unit tests (TEST_RUNNER_CFFIXED_USER_HOME); UI tests relocate theirs in the harness, and the Debug app itself restarts any test process that still has the
#     person's own home before it touches WebKit (TestIsolation.relocateHomeIfNeeded),
#   * the before/after proof that the person's own Browser Setu files and preferences did not change (scripts/check-uitest-isolation.py).
# It refuses to start while the installed Browser Setu is running (same bundle identifier).
set -u
cd "$(dirname "$0")/.."

# Throwaway UI-test profiles: every launch makes a `bs-perf-<8 hex>` folder in the user temporary folder (the sandboxed test runner cannot remove it itself). When this launcher exits, the ones created
# since it started are removed: exact names only, nothing older, nothing else, and the temporary folder itself must exist and be the user's.
RUN_MARKER=$(mktemp "${TMPDIR:-/tmp}/bs-run-marker.XXXXXX")
TEMP_ROOT=$(getconf DARWIN_USER_TEMP_DIR)
remove_this_runs_profiles() {
  if [ -n "$TEMP_ROOT" ] && [ -d "$TEMP_ROOT" ] && [ -f "$RUN_MARKER" ]; then
    find "$TEMP_ROOT" -maxdepth 1 -type d -name 'bs-perf-[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]' -newerBB "$RUN_MARKER" -exec rm -rf -- {} +
  fi
  rm -f -- "$RUN_MARKER"
}
trap remove_this_runs_profiles EXIT
DERIVED=${BS_DERIVED_DATA:-/private/tmp/bs-d1c}
PROJECT=apps/apple/BrowserSetu.xcodeproj
UI=BrowserSetuMacUITests; UNIT=BrowserSetuMacTests
D1C_SET=(
  -only-testing:$UI/D1cOneRowUITests -only-testing:$UI/D1cOneRowTransitionUITests
  -only-testing:$UI/D1aTabsUITests -only-testing:$UI/D1aVerificationUITests -only-testing:$UI/D1bGeometryUITests -only-testing:$UI/D1bMinimalUITests
  -only-testing:$UNIT/ChromeLayoutTests -only-testing:$UNIT/LayoutStateTests -only-testing:$UNIT/LayoutConsistencyTests -only-testing:$UNIT/TabChipRulesTests
  -only-testing:$UNIT/TestIsolationTests -only-testing:$UNIT/D1cOneRowModelTests
  -only-testing:$UNIT/RoundTripAndBudgetTests/testEveryTabGetsAWidthEvenWhenNoneIsActive -only-testing:$UNIT/RoundTripAndBudgetTests/testSelectedTabKeepsAUsableFieldAtNarrowWidths
)
# The D2a Sidebar acceptance set: the Sidebar's own tests, layout switching across Classic / Minimal / One Row / Sidebar, the shared tab and keyboard code the Sidebar now uses, and the layout and tab unit tests.
D2_SET=( -only-testing:$UI/D2SidebarUITests )
# The wider set for the end of D2a: Sidebar, layout switching across Classic / Minimal / One Row / Sidebar, the shared tab and keyboard code, and the layout and tab unit tests.
D2_FULL_SET=(
  -only-testing:$UI/D2SidebarUITests -only-testing:$UI/D1cOneRowTransitionUITests -only-testing:$UI/D1aTabsUITests
  -only-testing:$UI/D1bMinimalUITests/testKeyboardNavigationInMinimal
  -only-testing:$UI/D1cOneRowUITests/testSelectedTabCloseButton -only-testing:$UI/D1cOneRowUITests/testCompactCellsNeverCloseOnClick
  -only-testing:$UNIT/ChromeLayoutTests -only-testing:$UNIT/LayoutStateTests -only-testing:$UNIT/LayoutConsistencyTests -only-testing:$UNIT/TabChipRulesTests
  -only-testing:$UNIT/TestIsolationTests -only-testing:$UNIT/D1cOneRowModelTests
)
build=0; per_class=0; args=()
for a in "$@"; do
  case $a in --build) build=1 ;; --per-class) per_class=1 ;; --d1c) args+=("${D1C_SET[@]}") ;; --d2) args+=("${D2_SET[@]}") ;; --d2-full) args+=("${D2_FULL_SET[@]}") ;; *) args+=("$a") ;; esac
done
[ ${#args[@]} -gt 0 ] || { echo "no tests selected"; exit 2; }
if pgrep -x "Browser Setu" >/dev/null; then echo "The installed Browser Setu is running: quit it first (same bundle identifier)."; exit 2; fi
python3 -I scripts/check-uitest-privacy.py || exit 2
HOME_DIR=${TMPDIR:-/private/tmp}/bs-unit-home-$(id -u)
mkdir -p "$HOME_DIR/Library/Preferences"
if [ $build -eq 1 ]; then
  t0=$(date +%s)
  xcodebuild build-for-testing -project $PROJECT -scheme BrowserSetuMac -destination 'platform=macOS' -derivedDataPath "$DERIVED" > /private/tmp/bs-build.log 2>&1
  grep -E "error:|TEST BUILD" /private/tmp/bs-build.log | sort -u | cut -c1-300
  echo "build: $(( $(date +%s) - t0 )) s"
  # A failed build must stop here: running the old products would test code that is not the code in the tree.
  grep -q "TEST BUILD SUCCEEDED" /private/tmp/bs-build.log || { echo "BUILD FAILED: no tests were run."; exit 3; }
fi
# One run of xcodebuild under the isolation proof: $1 is the label, the rest are the test selections. The proof keeps its evidence on disk (before and after the run, also when it is interrupted).
run_group() {
  local label=$1; shift
  local RESULT=/private/tmp/bs-test-$(date +%H%M%S)-${label//[^A-Za-z0-9_-]/_}.xcresult
  local t0=$(date +%s)
  TEST_RUNNER_CFFIXED_USER_HOME="$HOME_DIR" python3 -I scripts/check-uitest-isolation.py --label "$label" -- xcodebuild test-without-building -project $PROJECT -scheme BrowserSetuMac -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" -resultBundlePath "$RESULT" "$@" > "$RESULT.log" 2>&1
  local rc=$?
  echo "[$label] tests: $(( $(date +%s) - t0 )) s, exit $rc, log $RESULT.log (result bundle $RESULT)"
  grep -E "Test Case.*failed|error:|Executed .* tests|ISOLATION|isolation evidence" "$RESULT.log" | cut -c1-400 | sort -u
  # A class that passed does not keep its result bundle (about 70 MB each; the log stays). A failing class keeps it for diagnosis. BS_KEEP_RESULTS=1 keeps every bundle (screenshots live in them).
  if [ $rc -eq 0 ] && [ "${BS_KEEP_RESULTS:-0}" != "1" ] && [ -d "$RESULT" ]; then rm -rf -- "$RESULT"; fi
  return $rc
}
if [ $per_class -eq 0 ]; then
  run_group all "${args[@]}"
  exit $?
fi
# --per-class: each test class is its own run with its own before/after proof; an isolation failure (exit 70) stops everything after it, and so does any other failure unless BS_CONTINUE_AFTER_FAILURE=1.
flags=(); keys=(); typeset -A selected
for a in "${args[@]}"; do
  if [[ $a == -only-testing:* ]]; then
    parts=("${(@s:/:)${a#-only-testing:}}")
    key="${parts[1]}${parts[2]:+/${parts[2]}}"
    (( ${keys[(Ie)$key]} )) || keys+=("$key")
    selected[$key]+="$a"$'\n'
  else
    flags+=("$a")
  fi
done
final=0
for key in "${keys[@]}"; do
  group=("${(@f)${selected[$key]%$'\n'}}")
  run_group "$key" "${flags[@]}" "${group[@]}"; rc=$?
  [ $rc -ne 0 ] && [ $final -eq 0 ] && final=$rc
  if [ $rc -eq 70 ]; then echo "ISOLATION FAILURE in $key: nothing after it was run."; exit 70; fi
  if [ $rc -ne 0 ] && [ "${BS_CONTINUE_AFTER_FAILURE:-0}" != "1" ]; then echo "STOPPED after $key failed (exit $rc); the classes after it were not run."; exit $rc; fi
done
exit $final
