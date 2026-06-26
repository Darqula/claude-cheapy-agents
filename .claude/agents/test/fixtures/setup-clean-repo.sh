#!/usr/bin/env bash
# Create a fresh, isolated git repo with a small initial commit so the test
# has something to diff against. Prints the absolute path of the new repo.

set -e

REPO=$(mktemp -d)

cd "$REPO"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
git config commit.gpgsign false
git config core.autocrlf false
git config core.safecrlf false

# Make a small initial commit so the repo has a valid HEAD and a populated index.
mkdir -p src
cat > src/existing.ts <<'EOF'
export function hello(): string {
  return "hello";
}
EOF

cat > README.md <<'EOF'
# test repo
EOF

git add -A
git commit -q -m "initial"

printf '%s' "$REPO"
