# Case 13 (session resumption): opencode stamps "sessionID" on its events.
# cheap-coder must capture the first one and surface it as a **Session ID:**
# line plus a **Resume with:** hint.

TASK="modify src/existing.ts"

opencode_script() {
  echo "// touched" >> src/existing.ts
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"
  grep -q '^\*\*Session ID:\*\* ses_FAKE0001$' "$out" || \
    echo "FAIL: session id should be surfaced as a **Session ID:** line"
  grep -q "Resume with:.*RESUME-SESSION: ses_FAKE0001" "$out" || \
    echo "FAIL: a **Resume with:** hint carrying the session id should be present"

  echo "PASS"
}
