# Case 14 (session resumption): the task string begins with a valid
# RESUME-SESSION header. cheap-coder must (i) pass --session <id> through to
# opencode, (ii) strip the header from the message opencode actually receives,
# and (iii) still deliver the follow-up body.

TASK="RESUME-SESSION: ses_PRIOR123

Also add a second test covering the empty-string case."

opencode_script() {
  echo "// follow-up change" >> src/existing.ts
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"

  # (i) --session was passed through with the right id.
  grep -q '^SESSION=ses_PRIOR123$' "$FAKE_OPENCODE_ARGV_LOG" || \
    echo "FAIL: --session ses_PRIOR123 should be passed to opencode"

  # (ii) the RESUME-SESSION header must NOT reach opencode's prompt.
  if grep -q 'RESUME-SESSION' "$FAKE_OPENCODE_ARGV_LOG"; then
    echo "FAIL: RESUME-SESSION header should be stripped from the message opencode receives"
  fi

  # (iii) the follow-up body must still reach opencode.
  grep -q 'Also add a second test covering the empty-string case' "$FAKE_OPENCODE_ARGV_LOG" || \
    echo "FAIL: follow-up task body should reach opencode"

  echo "PASS"
}
