# Case 09 (no-staging policy): opencode disobeys and stages a change. The PRE/POST
# git write-tree comparison must catch this and emit a warning.

TASK="modify and stage something"

opencode_script() {
  echo "// modified" >> src/existing.ts
  git add src/existing.ts
}

assert() {
  local out=$1

  grep -q 'git index changed during opencode run' "$out" || \
    echo "FAIL: index-mutation warning should fire"

  echo "PASS"
}
