# Case 07 (defensive — binary untracked stat fallback): opencode creates an untracked binary file. The script
# must not crash, the file must appear in the changed list, and the diff
# preview should indicate the binary content (via "Binary files ... differ").
# `git apply --stat` accepts binary diffs on modern Git (2.30+), so the
# stat-fallback warning may not fire — that's fine. The stat-fallback handling
# is defensive for older/stricter Git versions where the fallback path activates.

TASK="add a binary asset"

opencode_script() {
  # Create a small binary blob (random bytes via printf of escapes).
  mkdir -p assets
  printf '\x00\x01\x02\xff\xfe\xfd\x00\x01\x02\xff\xfe\xfd' > assets/blob.bin
}

assert() {
  local out=$1

  grep -q '^\*\*Status:\*\* success' "$out" || echo "FAIL: status should be success"
  grep -q 'assets/blob.bin (??)' "$out" || \
    echo "FAIL: binary file should appear in changed list as (??)"

  # The "Binary files differ" marker should appear in the diff preview.
  grep -q 'Binary files .* differ' "$out" || \
    echo "FAIL: diff preview should contain the binary-files marker"

  echo "PASS"
}
