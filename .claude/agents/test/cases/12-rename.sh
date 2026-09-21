# Case 12: rename via `git mv`. Under `-z` the porcelain emits two records
# (new path with code R, then the source path with no code); the awk
# skip_next logic must swallow the second. Note: `git mv` stages the rename,
# so the index-mutation warning also fires — unrelated to what is asserted
# here.
TASK="rename src/existing.ts to src/renamed.ts"

opencode_script() {
  git mv src/existing.ts src/renamed.ts
}

assert() {
  local out=$1

  grep -E 'src/renamed.ts \(R\)' "$out" || \
    echo "FAIL: renamed file should appear with R status code"

  # The source path must not appear as a phantom entry without a status code.
  if grep -E '^- src/existing.ts \(\)' "$out"; then
    echo "FAIL: phantom source-path record was not swallowed by awk skip_next"
  fi

  echo "PASS"
}
