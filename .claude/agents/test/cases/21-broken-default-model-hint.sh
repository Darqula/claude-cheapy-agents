# Case 21 (broken config default model hint): opencode v2 fails with a
# provider.internal 500 when no usable default model is configured (the
# stream spins on step_start events then dies — verified against v2.0.10).
# When that signature appears AND no MODEL header was supplied, the report
# must tell the parent how to fix it (set a default or pass a MODEL header).

TASK="just do a normal change"

# Simulate the v2 failure signature in the event stream: opencode dies with a
# provider.internal 500 (non-zero exit), like the real broken-default run.
export FAKE_OPENCODE_ERROR="provider.internal: Internal server error"
export FAKE_OPENCODE_EXIT_CODE=1

opencode_script() {
  echo "// never happens" >> src/existing.ts
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* failure' "$out" || echo "FAIL: status should be failure"

  # The broken-default hint must fire (no MODEL header was supplied).
  grep -q 'provider.internal error with no MODEL header' "$out" || \
    echo "FAIL: broken-default-model hint should fire"
  grep -q "prepend a 'MODEL: provider/model' header" "$out" || \
    echo "FAIL: hint should suggest the MODEL header"

  echo "PASS"
}
