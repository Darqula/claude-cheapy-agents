# Case 15 (session resumption, regression guard): a task WITHOUT a resume
# header must NOT cause --session to be passed (no accidental "always resume").
# The session id is still captured and surfaced, since opencode emits it on
# every run regardless.

TASK="just do a normal change"

opencode_script() {
  echo "// normal" >> src/existing.ts
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"

  # SESSION must be empty in the argv log — no --session flag was passed.
  grep -q '^SESSION=$' "$FAKE_OPENCODE_ARGV_LOG" || \
    echo "FAIL: --session must NOT be passed when no RESUME-SESSION header is present"

  # The session id is still captured & surfaced for fresh sessions.
  grep -q '^\*\*Session ID:\*\* ses_FAKE0001$' "$out" || \
    echo "FAIL: session id should still be surfaced for a fresh session"

  echo "PASS"
}
