# Case 01: opencode modifies a single tracked file.
# Expected: status success, file in changed list as (M), diff included,
# non-zero diff size.

TASK="modify src/existing.ts"

opencode_script() {
  cat > src/existing.ts <<'EOF'
export function hello(): string {
  return "hello, world";
}
EOF
}

assert() {
  local out=$1
  local repo=$2

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"
  grep -q 'src/existing.ts (M)' "$out" || echo "FAIL: file should appear as (M) in changed list"
  grep -q '^\*\*Diff preview:\*\* included' "$out" || echo "FAIL: diff should be included"
  grep -q '+  return "hello, world";' "$out" || echo "FAIL: diff should contain the new line"
  grep -q '^\*\*Warnings:\*\* none' "$out" || echo "FAIL: should have no warnings"

  echo "PASS"
}
