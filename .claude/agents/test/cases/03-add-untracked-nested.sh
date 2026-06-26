# Case 03 (regression — collapsed untracked dir): opencode creates a new directory with multiple
# files in it. Plain `git status --porcelain` would collapse this to
# `?? src/new-module/`, hiding the individual files. We need each file
# to appear separately AND each file's content to be in the diff.

TASK="create src/new-module/ with two files"

opencode_script() {
  mkdir -p src/new-module
  cat > src/new-module/index.ts <<'EOF'
export const index = 1;
EOF
  cat > src/new-module/index.test.ts <<'EOF'
import { index } from "./index";
test("x", () => { expect(index).toBe(1); });
EOF
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"

  # Both files must appear by name in the changed list.
  grep -q 'src/new-module/index.ts' "$out" || \
    echo "FAIL: src/new-module/index.ts should appear in changed list (collapsed dir bug?)"
  grep -q 'src/new-module/index.test.ts' "$out" || \
    echo "FAIL: src/new-module/index.test.ts should appear in changed list (collapsed dir bug?)"

  # The collapsed directory entry must NOT appear (would be wrong shape).
  if grep -q 'src/new-module/ (??)' "$out"; then
    echo "FAIL: collapsed dir entry 'src/new-module/ (??)' should not appear — must list individual files"
  fi

  # Diff must contain both file contents.
  grep -q '+export const index = 1;' "$out" || \
    echo "FAIL: diff should contain index.ts content"
  grep -q '+test("x", () => { expect(index).toBe(1); });' "$out" || \
    echo "FAIL: diff should contain index.test.ts content"

  echo "PASS"
}
