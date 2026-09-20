# Case 19 (model override, regression guard): a task WITHOUT a MODEL header
# must NOT cause --model to be passed (no accidental "always override") —
# model selection stays with the user's opencode config, exactly as before.

TASK="just do a normal change"

opencode_script() {
  echo "// normal" >> src/existing.ts
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"

  # MODEL must be empty in the argv log — no --model flag was passed.
  grep -q '^MODEL=$' "$FAKE_OPENCODE_ARGV_LOG" || \
    echo "FAIL: --model must NOT be passed when no MODEL header is present"

  echo "PASS"
}
