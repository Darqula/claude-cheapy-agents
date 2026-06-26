# Case 04 (regression — pre-existing untracked attribution): parent had an untracked scratch file before
# delegating. opencode creates a separate new file. The pre-existing
# scratch must NOT appear in the diff or be wrongly attributed to opencode.

TASK="create src/added.ts"

prestate() {
  local repo=$1
  ( cd "$repo" && echo "junk that is not opencode's" > scratch.txt )
}

opencode_script() {
  cat > src/added.ts <<'EOF'
export const added = true;
EOF
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"
  grep -q 'src/added.ts (??)' "$out" || echo "FAIL: src/added.ts should appear in changed list"

  # scratch.txt should NOT be in the changed list (it predates opencode).
  if grep -q 'scratch.txt' "$out"; then
    echo "FAIL: scratch.txt should not appear in changed list — it predated opencode"
  fi

  # scratch.txt content should NOT be in the diff.
  if grep -q 'junk that is not opencode' "$out"; then
    echo "FAIL: scratch.txt content should not appear in the diff"
  fi

  # opencode's file content should still be in the diff.
  grep -q '+export const added = true;' "$out" || \
    echo "FAIL: src/added.ts content should appear in the diff"

  # The dirty-tree warning should fire because scratch.txt was a pre-existing
  # untracked file.
  grep -q 'pre-existing uncommitted changes' "$out" || \
    echo "FAIL: dirty-tree warning should fire"

  echo "PASS"
}
