# Case 08: opencode emits an error event but exits 0. Should be classified
# as `partial` and the error message should appear in warnings.

TASK="do something that triggers an error event"

FAKE_OPENCODE_ERROR="bash command failed with exit code 1"

opencode_script() {
  cat > src/existing.ts <<'EOF'
export function hello(): string { return "ok"; }
EOF
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* partial' "$out" || echo "FAIL: status should be partial"
  grep -q 'ToolError: bash command failed with exit code 1' "$out" || \
    echo "FAIL: error event should appear in warnings"

  echo "PASS"
}
