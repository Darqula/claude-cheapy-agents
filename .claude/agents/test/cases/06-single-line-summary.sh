# Case 06 (regression — single-line summary wrongly fenced): single-line summary should
# NOT be fenced. This is the bug we accidentally trigger with the buggy
# grep -q $'\n' detection — it fences even single-line summaries.

TASK="modify src/existing.ts"

FAKE_OPENCODE_SUMMARY="single line summary that should not be fenced"

opencode_script() {
  cat > src/existing.ts <<'EOF'
export function hello(): string {
  return "ok";
}
EOF
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"

  # The summary must be inline (text on the same line as the field name).
  grep -q '^\*\*Opencode summary:\*\* single line summary that should not be fenced' "$out" || \
    echo "FAIL: single-line summary should be inline, not fenced"

  # Header-alone form must NOT be present.
  if grep -Eq '^\*\*Opencode summary:\*\*$' "$out"; then
    echo "FAIL: header-alone form indicates summary was wrongly fenced"
  fi

  echo "PASS"
}
