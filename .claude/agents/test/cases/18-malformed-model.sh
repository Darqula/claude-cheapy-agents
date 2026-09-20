# Case 18 (model override, malformed): the task begins with a MODEL header
# whose id is malformed. Unlike the resume id (which degrades to a fresh
# session), a malformed model FAILS FAST: opencode must NOT be invoked,
# because silently falling back to the config default could run the task on
# an unknown/expensive model. The report must be a normal failure report.

TASK="MODEL: not-a-valid-model

Add a helper module."

opencode_script() {
  echo "// should never run" >> src/existing.ts
}

assert() {
  local out=$1

  # Status must be failure.
  grep -q '^\*\*Status:\*\* failure' "$out" || echo "FAIL: status should be failure"

  # opencode must NOT have been invoked at all — argv log should not exist
  # (the fake only writes it when it runs).
  if [ -f "$FAKE_OPENCODE_ARGV_LOG" ]; then
    echo "FAIL: opencode must NOT be invoked on a malformed MODEL header"
  fi

  # The failure report should point at the malformed model header.
  grep -q 'MODEL header was present but the model id was malformed' "$out" || \
    echo "FAIL: malformed-MODEL warning should be present in the failure report"
  grep -q "expected 'provider/model'" "$out" || \
    echo "FAIL: failure report should state the expected model id format"

  # Nothing should have been written to the repo.
  if grep -q 'should never run' "$REPO/src/existing.ts" 2>/dev/null; then
    echo "FAIL: opencode script must not run on a malformed MODEL header"
  fi

  echo "PASS"
}
