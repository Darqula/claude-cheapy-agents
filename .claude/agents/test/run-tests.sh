#!/usr/bin/env bash
# Test runner for cheap-coder.
#
# Usage: run-tests.sh [case-name]
#   With no arg: runs every cases/*.sh. With a name: runs only that case.
#
# Each test case is a bash script that defines:
#   - prestate(REPO)             - optional. Apply prestate before the script runs.
#   - opencode_script(REPO)      - body of a script the fake opencode will run
#                                  (mutations happen in $REPO).
#   - assert(OUTPUT_FILE, REPO)  - print 'PASS' or 'FAIL: <reason>' per line.
#   - Optional env vars: TASK, EXTRA_SETUP, FAKE_OPENCODE_* (see fake-bin/opencode)
#
# Each case runs in its own subshell so env vars don't leak.

set -u

ROOT=$(cd "$(dirname "$0")" && pwd)
AGENT_MD="$ROOT/../cheap-coder.md"
ENGINE="$ROOT/../lib/cheap-coder-run.sh"
FAKE_BIN="$ROOT/fake-bin"
FIXTURE="$ROOT/fixtures/setup-clean-repo.sh"

CASES_DIR="$ROOT/cases"
FILTER=${1:-}

# Make our scripts executable (one-time, idempotent).
chmod +x "$ENGINE" "$FAKE_BIN/opencode" "$FIXTURE" 2>/dev/null || true

# Track totals.
total=0
passed=0
failed=0
failed_names=()

# Color helpers (disabled when not a tty).
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
  C_GREEN=$(printf '\033[32m')
  C_RED=$(printf '\033[31m')
  C_DIM=$(printf '\033[2m')
  C_OFF=$(printf '\033[0m')
else
  C_GREEN=""; C_RED=""; C_DIM=""; C_OFF=""
fi

run_case() {
  local case_file=$1
  local case_name
  case_name=$(basename "$case_file" .sh)

  total=$((total + 1))
  printf '%s... ' "$case_name"

  # Run the case in a subshell so it can't leak.
  local case_dir
  case_dir=$(mktemp -d)
  local output_file="$case_dir/output.txt"
  local prestate_script="$case_dir/prestate.sh"
  local opencode_script="$case_dir/opencode-script.sh"
  local assert_file="$case_dir/assertions.txt"

  (
    set +e
    # Reset hook env vars.
    unset FAKE_OPENCODE_SCRIPT FAKE_OPENCODE_SUMMARY FAKE_OPENCODE_ERROR
    unset FAKE_OPENCODE_EXIT_CODE FAKE_OPENCODE_EMIT_NOTHING FAKE_OPENCODE_SESSION_ID
    TASK=""
    EXTRA_SETUP=""

    # Argv log lives in case_dir (outside the test repo) so it never shows up
    # as an untracked file in cheap-coder's diff; assert() reads it via the
    # same var.
    export FAKE_OPENCODE_ARGV_LOG="$case_dir/argv.log"

    # Source the case definition.
    # shellcheck disable=SC1090
    source "$case_file"

    # Export case-level vars so they survive into the fake opencode subprocess.
    export FAKE_OPENCODE_SUMMARY FAKE_OPENCODE_ERROR FAKE_OPENCODE_EXIT_CODE FAKE_OPENCODE_EMIT_NOTHING FAKE_OPENCODE_SESSION_ID

    # Set up a clean repo.
    REPO=$(bash "$FIXTURE")
    if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
      echo "FATAL: fixture failed" >&2
      exit 99
    fi

    # Apply prestate if defined.
    if declare -F prestate >/dev/null; then
      prestate "$REPO"
    fi

    # Write the opencode-script if the case defined one.
    if declare -F opencode_script >/dev/null; then
      {
        echo "#!/usr/bin/env bash"
        echo "set -e"
        declare -f opencode_script
        echo "opencode_script"
      } > "$opencode_script"
      chmod +x "$opencode_script"
      export FAKE_OPENCODE_SCRIPT="$opencode_script"
    fi

    # Run the real shipped engine exactly as the subagent/skill do, with PATH
    # front-loaded to find the fake opencode; minimal PATH (git, jq, bash, node).
    cd "$REPO"
    # Per-case setup that runs after cd into REPO but before the engine is
    # invoked (e.g. to start from a subdirectory).
    if [ -n "$EXTRA_SETUP" ]; then
      eval "$EXTRA_SETUP"
    fi
    PATH="$FAKE_BIN:$PATH" bash "$ENGINE" "${TASK:-test task}" > "$output_file" 2>&1
    cc_exit=$?

    # Run case assertions.
    if declare -F assert >/dev/null; then
      assert "$output_file" "$REPO" > "$assert_file"
    else
      echo "FAIL: case has no assert() function" > "$assert_file"
    fi

    # Tally based on whether all assertions PASSed.
    if grep -q '^FAIL' "$assert_file"; then
      echo "__CASE_FAILED__:$cc_exit" >> "$assert_file"
    fi
  )

  if grep -q '^FAIL' "$assert_file" 2>/dev/null; then
    failed=$((failed + 1))
    failed_names+=("$case_name")
    printf '%sFAIL%s\n' "$C_RED" "$C_OFF"
    sed 's/^/   /' "$assert_file" | grep -v '^   __CASE_FAILED__' || true
    echo "${C_DIM}   output: $output_file${C_OFF}"
  else
    passed=$((passed + 1))
    printf '%sPASS%s\n' "$C_GREEN" "$C_OFF"
    rm -rf "$case_dir"
  fi
}

if [ -n "$FILTER" ]; then
  case_path="$CASES_DIR/$FILTER.sh"
  if [ ! -f "$case_path" ]; then
    echo "No such case: $case_path" >&2
    exit 2
  fi
  run_case "$case_path"
else
  for case_file in "$CASES_DIR"/*.sh; do
    [ -f "$case_file" ] || continue
    run_case "$case_file"
  done
fi

echo ""
echo "Results: $passed passed, $failed failed (of $total)"
if [ "$failed" -gt 0 ]; then
  echo "Failed cases: ${failed_names[*]}"
  exit 1
fi
exit 0
