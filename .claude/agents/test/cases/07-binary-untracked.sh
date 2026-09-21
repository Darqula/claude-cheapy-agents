# Case 07 (defensive — binary untracked stat fallback): an untracked binary
# file must not crash the engine and must appear in the changed list and diff
# preview. `git apply --stat` accepts binary diffs on modern Git (2.30+), so
# the stat-fallback path mainly exists for older Git; whether the fallback
# warning fires here is not asserted.

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
