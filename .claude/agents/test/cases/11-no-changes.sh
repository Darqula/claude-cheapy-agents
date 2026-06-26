# Case 11: opencode makes no changes. Should still be `success`, files
# changed should be "none", diff size zero.

TASK="do nothing"

opencode_script() {
  : # no-op
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"
  grep -q '^- none' "$out" || echo "FAIL: changed list should be 'none'"
  grep -q '^\*\*Diff size:\*\* 0 files, +0/-0 lines' "$out" || \
    echo "FAIL: diff size should be 0 files / 0 lines"

  echo "PASS"
}
