# Case 02: opencode creates a single new file at the top level.
# Expected: status success, file in changed list with (??) code, diff
# includes the new file content (synthesized via --no-index).

TASK="create src/new-file.ts"

opencode_script() {
  cat > src/new-file.ts <<'EOF'
export const x = 42;
EOF
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"
  grep -q 'src/new-file.ts (??)' "$out" || echo "FAIL: new file should appear as (??) in changed list"
  grep -q '^\*\*Diff preview:\*\* included' "$out" || echo "FAIL: diff should be included"
  grep -q '+export const x = 42;' "$out" || echo "FAIL: diff should contain the new file content"

  echo "PASS"
}
