# Case 10 (regression — missing cd to git root): cheap-coder script is started from a subdirectory of the
# repo. The script must `cd $GIT_ROOT` so untracked files outside that
# subdirectory are still discovered.

TASK="create a file in a sibling directory"

prestate() {
  local repo=$1
  ( cd "$repo" && mkdir -p src/components )
}

opencode_script() {
  # opencode itself runs at repo root (via --dir), so it can write anywhere.
  mkdir -p tests
  cat > tests/new.test.ts <<'EOF'
test("sanity", () => { expect(true).toBe(true); });
EOF
}

# Run cheap-coder from src/components (a subdirectory) to exercise the cd guard.
EXTRA_SETUP="cd src/components"

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"
  grep -q 'tests/new.test.ts (??)' "$out" || \
    echo "FAIL: new file in sibling dir should be discovered (cd to GIT_ROOT failing?)"
  grep -q '+test("sanity"' "$out" || \
    echo "FAIL: diff should contain new file content"

  echo "PASS"
}
