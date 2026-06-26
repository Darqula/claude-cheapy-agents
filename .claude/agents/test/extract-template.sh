#!/usr/bin/env bash
# Extract the bash template from cheap-coder.md and substitute the placeholder
# with a single-quote-escaped task string. The output is a runnable bash script
# identical to what the production subagent would execute.
#
# Usage: extract-template.sh <path-to-cheap-coder.md> <task-string>
# Output: substituted bash script on stdout
#
# Substitution is done via substitute.js (a tiny Node helper) because awk/sed
# replacement strings have backslash-handling quirks that corrupt the escape
# sequence `'\''` in subtle ways.

set -e

AGENT_MD=$1
TASK=$2

if [ -z "$AGENT_MD" ] || [ -z "$TASK" ]; then
  echo "Usage: $0 <cheap-coder.md> <task-string>" >&2
  exit 2
fi

if [ ! -f "$AGENT_MD" ]; then
  echo "Agent file not found: $AGENT_MD" >&2
  exit 2
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node not found on PATH — required for template substitution" >&2
  exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Extract the bash template — the body of the only ```bash ... ``` block in
# the file (the one inside "## The template"). awk finds the START line
# (```bash) and the matching END line (```) and prints content between them.
TEMPLATE=$(awk '
  /^```bash$/ { in_block = 1; next }
  in_block && /^```$/ { in_block = 0; exit }
  in_block { print }
' "$AGENT_MD")

if [ -z "$TEMPLATE" ]; then
  echo "Could not extract bash template from $AGENT_MD" >&2
  exit 2
fi

# Substitute the placeholder. Template via stdin, task via env var.
# `TASK=... cmd1 | cmd2` only exports to cmd1, so we export and unset around
# the pipeline instead.
export TASK
printf '%s\n' "$TEMPLATE" | node "$SCRIPT_DIR/substitute.js"
unset TASK
