# Case 12: opencode renames a tracked file. With `git mv`, the porcelain
# entry under -z emits TWO records: the new path with code R, then the
# source path with no code. The awk skip_next logic in cheap-coder must
# swallow that second record.

TASK="rename src/existing.ts to src/renamed.ts"

opencode_script() {
  git mv src/existing.ts src/renamed.ts
  # Reverse the rename out of the index so we leave only working-tree state.
  # Actually `git mv` updates the index — we must reset the index to undo
  # that, since cheap-coder's no-staging policy is enforced at the prompt
  # level only. For the test, we accept the staged state and rely on the
  # index-mutation warning to fire.
}

assert() {
  local out=$1

  # rename will trigger the index-mutation warning since git mv stages the
  # rename. That's a separate signal; what we're testing here is that the
  # awk skip_next correctly handles the two-record format.
  # The renamed file should appear in the list (status code starts with R).
  grep -E 'src/renamed.ts \(R\)' "$out" || \
    echo "FAIL: renamed file should appear with R status code"

  # The source path src/existing.ts should NOT appear as a phantom entry
  # without any status code.
  if grep -E '^- src/existing.ts \(\)' "$out"; then
    echo "FAIL: phantom source-path record was not swallowed by awk skip_next"
  fi

  echo "PASS"
}
