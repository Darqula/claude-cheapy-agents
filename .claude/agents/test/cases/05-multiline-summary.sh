# Case 05 (regression — multi-line summary truncation): opencode's final summary contains a real newline.
# The emitter must fence multi-line summaries but keep single-line summaries
# inline. We assert the fenced form is used here.

TASK="modify src/existing.ts with a multi-line summary"

FAKE_OPENCODE_SUMMARY="line one
line two"

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

  # The summary header line should appear standalone (no inline text after the colon).
  grep -Eq '^\*\*Opencode summary:\*\*$' "$out" || \
    echo "FAIL: multi-line summary should be emitted as fenced block (header alone)"

  # Both summary lines should appear inside a fenced block.
  grep -q '^line one$' "$out" || echo "FAIL: first summary line should appear"
  grep -q '^line two$' "$out" || echo "FAIL: second summary line should appear"

  echo "PASS"
}
