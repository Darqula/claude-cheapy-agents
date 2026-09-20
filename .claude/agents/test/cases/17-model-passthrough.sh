# Case 17 (model override): the task string begins with a valid MODEL header.
# cheap-coder must (i) pass --model <id> through to opencode, (ii) strip the
# header from the message opencode actually receives, and (iii) still deliver
# the task body.

TASK="MODEL: opencode-go/glm-5.3-flash

Add a helper module with the usual acceptance criteria."

opencode_script() {
  echo "// model-override change" >> src/existing.ts
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"

  # (i) --model was passed through with the exact id from the header.
  grep -q '^MODEL=opencode-go/glm-5.3-flash$' "$FAKE_OPENCODE_ARGV_LOG" || \
    echo "FAIL: --model opencode-go/glm-5.3-flash should be passed to opencode"

  # (ii) the MODEL header must NOT reach opencode's prompt.
  if grep -q 'MODEL: opencode-go' "$FAKE_OPENCODE_ARGV_LOG"; then
    echo "FAIL: MODEL header should be stripped from the message opencode receives"
  fi

  # (iii) the task body must still reach opencode.
  grep -q 'Add a helper module with the usual acceptance criteria' "$FAKE_OPENCODE_ARGV_LOG" || \
    echo "FAIL: task body should reach opencode"

  echo "PASS"
}
