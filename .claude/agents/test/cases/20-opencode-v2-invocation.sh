# Case 20 (opencode v2 invocation shape): the engine must invoke opencode the
# way v2.0.10 actually accepts it — verified against the live CLI:
#   - NO --dir (removed in v2; "Unrecognized flag" aborts the run),
#   - --standalone (per-invocation OPENCODE_CONFIG_CONTENT is ignored by the
#     shared background service — only a private server reads it),
#   - OPENCODE_CONFIG_CONTENT exported (the v1 OPENCODE_PERMISSION env var no
#     longer exists in the v2 binary).

TASK="just do a normal change"

opencode_script() {
  echo "// normal" >> src/existing.ts
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"

  # --standalone was passed (required for per-run config to apply).
  grep -q '^STANDALONE=1$' "$FAKE_OPENCODE_ARGV_LOG" || \
    echo "FAIL: --standalone should be passed to opencode (per-run config needs a private server)"

  # OPENCODE_CONFIG_CONTENT was exported (inline permission config).
  grep -q '^CONFIG_SET=1$' "$FAKE_OPENCODE_ARGV_LOG" || \
    echo "FAIL: OPENCODE_CONFIG_CONTENT should be exported for the per-invocation permission policy"

  # No v1 leftovers reach the CLI.
  if grep -q '^OPENCODE_PERMISSION=1$' "$FAKE_OPENCODE_ARGV_LOG" 2>/dev/null; then
    echo "FAIL: OPENCODE_PERMISSION is gone in v2"
  fi

  echo "PASS"
}
