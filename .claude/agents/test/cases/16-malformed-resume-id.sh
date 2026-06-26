# Case 16 (session resumption): the task begins with a RESUME-SESSION header
# whose id is malformed. cheap-coder must degrade gracefully — run a FRESH
# session (no --session), warn about the bad header, and still deliver the
# task body with the header stripped.

TASK="RESUME-SESSION: not-a-valid-id

Make the change anyway."

opencode_script() {
  echo "// anyway" >> src/existing.ts
}

assert() {
  local out=$1

  # No valid --session was passed (malformed id => fresh session).
  if grep -q '^SESSION=ses_' "$FAKE_OPENCODE_ARGV_LOG"; then
    echo "FAIL: a malformed id must NOT be passed as --session"
  fi
  grep -q '^SESSION=$' "$FAKE_OPENCODE_ARGV_LOG" || \
    echo "FAIL: SESSION should be empty for a malformed resume id"

  # The malformed-header warning must fire.
  grep -q 'RESUME-SESSION header was present but the session id was malformed' "$out" || \
    echo "FAIL: malformed-header warning should fire"

  # The task body must still reach opencode, with the header stripped.
  grep -q 'Make the change anyway' "$FAKE_OPENCODE_ARGV_LOG" || \
    echo "FAIL: task body should still reach opencode"
  if grep -q 'RESUME-SESSION' "$FAKE_OPENCODE_ARGV_LOG"; then
    echo "FAIL: malformed header should be stripped from the message opencode receives"
  fi

  echo "PASS"
}
