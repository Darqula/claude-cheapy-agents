#!/usr/bin/env bash
# cheap-coder engine — runs the whole protocol in one bash process so shell
# variables stay live. No `set -e`: expected non-zero exits (e.g. jq on an
# empty stream) are tolerated; exits that matter are checked explicitly.

# ---- Step 1: setup ----

# Per-invocation scratch dir. Bare `mktemp -d` works on GNU, BSD, and Git Bash
# (the `-t TEMPLATE` form has divergent semantics across platforms).
CC_TMP=$(mktemp -d) || { echo "FATAL: mktemp -d failed"; exit 1; }

# Cleanup on every exit path (normal, error, signal, opencode crash).
trap '[ -n "$CC_TMP" ] && rm -rf "$CC_TMP"' EXIT

# Precondition: opencode CLI on PATH.
if ! command -v opencode >/dev/null 2>&1; then
  cat <<'FAIL'
## cheap-coder result

**Status:** failure
**Opencode summary:** (not invoked)
**Files changed:** none
**Diff size:** 0 files, +0/-0 lines
**Diff preview:** omitted
**Warnings:** opencode CLI not found on PATH — install it from https://opencode.ai or ensure your shell can find it
**Next step (parent):** install opencode, then re-delegate.
FAIL
  exit 0
fi

# Precondition: jq on PATH. The summary/error-event extractors depend on it
# and would otherwise fail silently, producing a hollow "success".
if ! command -v jq >/dev/null 2>&1; then
  cat <<'FAIL'
## cheap-coder result

**Status:** failure
**Opencode summary:** (not invoked)
**Files changed:** none
**Diff size:** 0 files, +0/-0 lines
**Diff preview:** omitted
**Warnings:** jq not found on PATH — cheap-coder uses jq to parse opencode's JSONL event stream; without it, summaries and error detection are unreliable
**Next step (parent):** install jq (e.g. `apt install jq`, `brew install jq`, or download from https://jqlang.github.io/jq/), then re-delegate.
FAIL
  exit 0
fi

# Precondition: inside a git repo. The repo root is opencode's working
# directory (v2 removed `opencode run --dir`) and provides `git status`/`git
# diff` for the report.
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$GIT_ROOT" ]; then
  cat <<'FAIL'
## cheap-coder result

**Status:** failure
**Opencode summary:** (not invoked)
**Files changed:** none
**Diff size:** 0 files, +0/-0 lines
**Diff preview:** omitted
**Warnings:** not a git repository — cheap-coder requires a git repo so changes can be reviewed via `git diff`
**Next step (parent):** run `git init` or change to a git repo, then re-delegate.
FAIL
  exit 0
fi

# Work from the repo root: the opencode CLI uses its own cwd (no `--dir` in
# v2), and several git commands are cwd-sensitive (`git ls-files --others`
# only lists untracked files under the current directory). Without this cd,
# a caller in a subdirectory would miss content outside that subtree.
cd "$GIT_ROOT" || {
  cat <<'FAIL'
## cheap-coder result

**Status:** failure
**Opencode summary:** (not invoked)
**Files changed:** none
**Diff size:** 0 files, +0/-0 lines
**Diff preview:** omitted
**Warnings:** could not cd into git repo root — filesystem permission or transient I/O issue
**Next step (parent):** check repo access, then re-delegate.
FAIL
  exit 0
}

# Pre-existing uncommitted changes, later diffed against the post-run state to
# attribute only opencode's work.
#   --porcelain -z  NUL-separated, paths unquoted (survives spaces/non-ASCII)
#   -uall           expand untracked dirs to individual files
#   tr '\0' '\n'    line-oriented for sort/comm (-z paths never contain \n)
#   LC_ALL=C        byte-wise sort so `comm` below is locale-stable
LC_ALL=C git status --porcelain -uall -z | tr '\0' '\n' | LC_ALL=C sort > "$CC_TMP/prestate.txt"

# Index tree hash before the run; compared after to detect no-staging policy
# violations. (`git diff --cached --quiet` would false-positive on pre-existing
# staged content; the tree hash only changes if the index itself changed.)
PRE_INDEX_TREE=$(git write-tree 2>/dev/null)

# ---- Step 2: invoke opencode ----

# The parent's task: first argument when present, else read from stdin
# (heredoc) — the no-escaping path for quote-heavy tasks. The protocol is
# identical either way.
if [ "$#" -ge 1 ]; then
  PARENT_TASK="$1"
else
  PARENT_TASK="$(cat)"
fi

# Optional directive headers, peeled off the top of the task (each with one
# optional blank separator line). Either order, both allowed:
#   RESUME-SESSION: ses_<id>          — continue that opencode conversation
#   MODEL: provider/model[#variant]   — override the coding model for this run
#
# RESUME-SESSION uses an explicit id, never opencode's `--continue` ("last
# session"): each cheap-coder call is an independent process, and a concurrent
# opencode run elsewhere could become the "last session".
#
# String surgery is bash parameter expansion only (no sed/awk) for
# cross-platform parity.
RESUME_SESSION_ID=""
RESUME_HEADER_MALFORMED=0
MODEL_ID=""
MODEL_HEADER_MALFORMED=0
while :; do
  case "$PARENT_TASK" in
    "RESUME-SESSION: "*)
      resume_first_line=${PARENT_TASK%%$'\n'*}
      resume_candidate=${resume_first_line#RESUME-SESSION: }
      # Strip the header line and one optional blank separator line.
      resume_body=${PARENT_TASK#*$'\n'}
      [ "$resume_body" = "$PARENT_TASK" ] && resume_body=""   # header-only, no body
      case "$resume_body" in $'\n'*) resume_body=${resume_body#$'\n'} ;; esac
      PARENT_TASK=$resume_body
      # Session ids are `ses_` + base62; anything else is treated as no-resume
      # and warned about later.
      if printf '%s' "$resume_candidate" | grep -Eq '^ses_[A-Za-z0-9]+$'; then
        RESUME_SESSION_ID=$resume_candidate
      else
        RESUME_HEADER_MALFORMED=1
      fi
      ;;
    "MODEL: "*)
      model_first_line=${PARENT_TASK%%$'\n'*}
      model_candidate=${model_first_line#MODEL: }
      model_body=${PARENT_TASK#*$'\n'}
      [ "$model_body" = "$PARENT_TASK" ] && model_body=""   # header-only, no body
      case "$model_body" in $'\n'*) model_body=${model_body#$'\n'} ;; esac
      PARENT_TASK=$model_body
      # Model ids are `provider/model` optionally `#variant`. A malformed value
      # fails fast (below): falling back to the config default could run the
      # task on an unknown model, so an explicit override must be exactly right
      # or not run at all. Omitting the header is the way to use the default.
      if printf '%s' "$model_candidate" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._#/-]*$'; then
        MODEL_ID=$model_candidate
      else
        MODEL_HEADER_MALFORMED=1
      fi
      ;;
    *)
      break
      ;;
  esac
done

# Fail fast on a malformed MODEL header, before any snapshot or invocation —
# same structured-report shape as the precondition failures above.
if [ "$MODEL_HEADER_MALFORMED" -eq 1 ]; then
  cat <<'FAIL'
## cheap-coder result

**Status:** failure
**Opencode summary:** (not invoked)
**Files changed:** none
**Diff size:** 0 files, +0/-0 lines
**Diff preview:** omitted
**Warnings:** MODEL header was present but the model id was malformed — expected 'provider/model' or 'provider/model#variant' (e.g. 'opencode-go/glm-5.3-flash'); opencode was NOT invoked
**Next step (parent):** fix the MODEL header (format: 'MODEL: provider/model') and re-delegate; omit the header entirely to use the opencode config default.
FAIL
  exit 0
fi

# Prompt = git-policy prefix + task. The prefix keeps all changes unstaged so
# the parent can review them; violations would be visible in the git state
# regardless (trust-based, no post-check).
FULL_TASK="IMPORTANT — git policy: Do NOT run 'git add', 'git commit', 'git stash', or any other command that modifies the git index or refs. Leave all your changes as unstaged modifications in the working tree. The parent agent will review the diff and decide what to commit.

Your task:
${PARENT_TASK}"

# 15-minute wall-clock limit for hanging runs. GNU `timeout` only: macOS
# needs Homebrew's `gtimeout`, and Git Bash's PATH often resolves to Windows
# timeout.exe first — a different utility that waits for a keypress. Require
# the GNU coreutils signature in --version; run unprotected with a warning
# if nothing qualifies.
TIMEOUT_CMD=""
for candidate in timeout gtimeout; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" --version 2>&1 | grep -qi "gnu coreutils"; then
      TIMEOUT_CMD="$candidate"
      break
    fi
  fi
done
if [ -z "$TIMEOUT_CMD" ]; then
  echo "WARN: GNU timeout/gtimeout not found; opencode will run without a wall-clock limit" >&2
fi

# Per-invocation permission policy via inline config — does not touch the
# user's opencode.json. v2 mechanics (verified on v2.0.10):
#   - `OPENCODE_PERMISSION` (v1) no longer exists in the binary.
#   - `OPENCODE_CONFIG_CONTENT` is only read by a server started for this
#     invocation; the default background service loads its config once at
#     startup and ignores it — hence `--standalone` below, which also
#     isolates this run from concurrent sessions.
#   - Key names follow the binary's schema (v1-shaped `permission` object);
#     the newer `permissions` rules array is not accepted by this build.
# Denies: external_directory (sandbox escape), question (no human to answer
# non-interactively), task/skill (one task, no nested agents). Everything not
# denied keeps opencode's allow-by-default behavior.

# Stdout is the JSONL event stream, redirected to a file so the raw transcript
# never enters the agent's context; stderr is captured separately.
# `--session`/`--model` expand to nothing when the corresponding header is
# absent; `${TIMEOUT_CMD:+...}` expands to `timeout 900` only when the probe
# succeeded.
#
# Defensive no-ops for non-interactive shells (both harmless in a terminal):
#   - unset inherited http(s)_proxy: injected proxy env vars can stall
#     opencode's backend calls even when direct egress works.
#   - stdin from /dev/null: the task is already captured; an inherited
#     non-TTY stdin can make opencode block on input that never arrives.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
OPENCODE_CONFIG_CONTENT='{"permission":{"external_directory":"deny","question":"deny","task":"deny","skill":"deny"}}' \
${TIMEOUT_CMD:+$TIMEOUT_CMD 900} \
opencode run \
  --standalone \
  --format json \
  ${RESUME_SESSION_ID:+--session $RESUME_SESSION_ID} \
  ${MODEL_ID:+--model $MODEL_ID} \
  "$FULL_TASK" \
  < /dev/null \
  > "$CC_TMP/opencode.jsonl" 2> "$CC_TMP/opencode.err"
exit_code=$?

# ---- Step 3: extract minimal summary ----

# Extract bounded artifacts; the raw JSONL is never printed (it can be huge).

# Pre-create scratch files: `wc -l < file` errors loudly if a file is missing,
# and some extractors may skip writing (e.g. no error events).
: > "$CC_TMP/summary.txt"
: > "$CC_TMP/errors.txt"
: > "$CC_TMP/changed.txt"
: > "$CC_TMP/diff.txt"
: > "$CC_TMP/diffstat.txt"
: > "$CC_TMP/new_untracked.txt"

# 3a. Final assistant text: take the LAST JSONL line containing `"type":"text"`
# and extract `.part.text` from that line. (jq's raw output for a multi-line
# string is multi-line, so `jq | tail -n 1` would truncate to the last physical
# line; grepping JSONL lines first keeps `tail` line-granular.)
LAST_TEXT_LINE=$(grep '"type":"text"' "$CC_TMP/opencode.jsonl" 2>/dev/null | tail -n 1)
if [ -n "$LAST_TEXT_LINE" ]; then
  printf '%s\n' "$LAST_TEXT_LINE" | jq -r '.part.text' > "$CC_TMP/summary.txt" 2>/dev/null
fi

# Fallback for schema drift (event type renamed/missing but `part.text`
# still present): last JSONL line with any `.part.text` content.
if [ ! -s "$CC_TMP/summary.txt" ]; then
  LAST_PART_LINE=$(grep '"part"' "$CC_TMP/opencode.jsonl" 2>/dev/null | tail -n 1)
  if [ -n "$LAST_PART_LINE" ]; then
    printf '%s\n' "$LAST_PART_LINE" | jq -r '.part.text // empty' > "$CC_TMP/summary.txt" 2>/dev/null
  fi
fi

# Cap at 8KB — the diff is the authoritative artifact; the summary is a hint.
if [ "$(wc -c < "$CC_TMP/summary.txt" 2>/dev/null || echo 0)" -gt 8192 ]; then
  head -c 8192 "$CC_TMP/summary.txt" > "$CC_TMP/summary.txt.tmp"
  printf "\n[...truncated at 8KB; see diff for full picture]" >> "$CC_TMP/summary.txt.tmp"
  mv "$CC_TMP/summary.txt.tmp" "$CC_TMP/summary.txt"
fi

# 3a-bis. Session id: every event carries "sessionID" at the top level; first
# hit. Surfaced so the parent can resume this conversation via a
# RESUME-SESSION header. grep+sed; the value is a fixed-shape token.
SESSION_ID=$(grep -m1 -o '"sessionID":"ses_[A-Za-z0-9]*"' "$CC_TMP/opencode.jsonl" 2>/dev/null | head -n 1 | sed 's/.*"ses_/ses_/; s/"$//')

# 3b. Error events (opencode can error without aborting). The event shape
# changed in v2 — `.error.type`/`.error.message` vs v1 `.error.name`/
# `.error.data.message`; the `//` fallbacks cover both.
jq -r 'select(.type=="error") | "\(.error.name // .error.type // "unknown"): \(.error.data.message // .error.message // "no message")"' "$CC_TMP/opencode.jsonl" 2>/dev/null > "$CC_TMP/errors.txt"

# 3c. Changed files, derived from git rather than tool_use events (path field
# names inside `part.state.input` vary by tool). Same -z|tr|sort pipeline and
# LC_ALL=C as prestate so `comm` ordering matches.
LC_ALL=C git status --porcelain -uall -z | tr '\0' '\n' | LC_ALL=C sort > "$CC_TMP/poststate.txt"
comm -13 "$CC_TMP/prestate.txt" "$CC_TMP/poststate.txt" > "$CC_TMP/changed.txt"

# 3d. Diff. Plain `git diff` ignores untracked files, so synthesize a /dev/null
# diff for each untracked file that is new since prestate. The list comes from
# changed.txt (the porcelain delta), NOT `git ls-files --others` — the latter
# also returns pre-existing parent scratch files, which would be misattributed
# to opencode.
git diff > "$CC_TMP/diff.txt" 2>/dev/null
# changed.txt lines are `XY path`; strip the 3-char prefix.
awk '/^\?\? / { print substr($0, 4) }' "$CC_TMP/changed.txt" > "$CC_TMP/new_untracked.txt"
# `--no-index` exits non-zero when files differ; tolerate it.
while IFS= read -r untracked; do
  [ -z "$untracked" ] && continue
  git diff --no-index --no-color /dev/null "$untracked" >> "$CC_TMP/diff.txt" 2>/dev/null || true
done < "$CC_TMP/new_untracked.txt"
# Stat from the combined diff via `git apply --stat` so untracked additions
# count. Falls back to `git diff --stat` when `git apply --stat` rejects the
# synthesized hunks (typically a binary untracked file). The fallback is
# flagged so the parent can be warned the stat omits untracked additions.
stat_fallback=0
if ! git apply --stat "$CC_TMP/diff.txt" > "$CC_TMP/diffstat.txt" 2>/dev/null; then
  git diff --stat > "$CC_TMP/diffstat.txt" 2>/dev/null
  stat_fallback=1
fi
# Counters via `wc -l`, not `grep -c .`: the latter exits 1 on zero matches
# and makes `grep -c . file || echo 0` produce a multi-line string that breaks
# `[ "$x" -gt 0 ]`. The porcelain captures always end records with a newline,
# so `wc -l` counts are exact.
diff_lines=$(wc -l < "$CC_TMP/diff.txt" 2>/dev/null || echo 0)
diff_lines=${diff_lines:-0}
new_untracked_count=$(wc -l < "$CC_TMP/new_untracked.txt" 2>/dev/null || echo 0)
new_untracked_count=${new_untracked_count:-0}

# 3e. Include the diff content only below 500 lines, to bound the parent's
#     context; larger diffs are fetched via `git diff`.
include_diff=0
if [ "$diff_lines" -gt 0 ] && [ "$diff_lines" -lt 500 ]; then
  include_diff=1
fi

# 3f. Anomaly detection. Defaults keep the `[ "$x" -gt 0 ]` arithmetic safe
#     when a file is empty.
summary_size=$(wc -c < "$CC_TMP/summary.txt" 2>/dev/null || echo 0)
summary_size=${summary_size:-0}
changed_count=$(wc -l < "$CC_TMP/changed.txt" 2>/dev/null || echo 0)
changed_count=${changed_count:-0}
jsonl_size=$(wc -c < "$CC_TMP/opencode.jsonl" 2>/dev/null || echo 0)
jsonl_size=${jsonl_size:-0}

WARNINGS=""

# Anomaly 1: files changed but no final assistant text — likely a crash
# mid-output or a schema mismatch.
if [ "$summary_size" -eq 0 ] && [ "$changed_count" -gt 0 ]; then
  WARNINGS="${WARNINGS}opencode changed files but produced no final summary text — possible crash or schema mismatch; review the diff carefully. "
fi

# Anomaly 2: near-empty event stream (<100 bytes) with a zero exit code —
# ambiguous "ran but did nothing visible".
if [ "$jsonl_size" -lt 100 ] && [ "$exit_code" -eq 0 ]; then
  WARNINGS="${WARNINGS}opencode produced unusually small output stream (<100 bytes) — verify the task was understood. "
fi

# Anomaly 3: wall-clock timeout (exit 124; only possible when GNU timeout ran).
if [ "$exit_code" -eq 124 ]; then
  WARNINGS="${WARNINGS}opencode exceeded 15-minute wall-clock timeout and was killed. "
fi

# Anomaly 4: error events present.
if [ -s "$CC_TMP/errors.txt" ]; then
  err_preview=$(head -c 500 "$CC_TMP/errors.txt" | tr '\n' '; ')
  WARNINGS="${WARNINGS}error events from opencode: ${err_preview}. "
fi

# Anomaly 5: non-zero exit code other than the timeout case above.
if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 124 ]; then
  stderr_preview=$(tail -c 500 "$CC_TMP/opencode.err" 2>/dev/null | tr '\n' '; ')
  WARNINGS="${WARNINGS}opencode exited non-zero (code $exit_code): ${stderr_preview}. "
fi

# Anomaly 6: index mutated during the run — opencode may have staged changes
# despite the no-staging policy. Plain `git diff` hides staged changes.
POST_INDEX_TREE=$(git write-tree 2>/dev/null)
if [ -n "$PRE_INDEX_TREE" ] && [ -n "$POST_INDEX_TREE" ] && [ "$PRE_INDEX_TREE" != "$POST_INDEX_TREE" ]; then
  WARNINGS="${WARNINGS}git index changed during opencode run — opencode may have staged changes despite the no-staging policy; inspect with 'git diff --cached'. "
fi

# Anomaly 7: diff-stat fallback with new untracked files — the reported stat
# omits untracked additions (typically a binary untracked file).
if [ "$stat_fallback" -eq 1 ] && [ "$new_untracked_count" -gt 0 ]; then
  WARNINGS="${WARNINGS}diff stat fell back to tracked-only — likely a binary untracked file; the 'Diff size' below does not count untracked additions. Inspect the listed '??' files directly. "
fi

# Dirty-tree caveat: if the parent had pre-existing edits to a file opencode
# also modified, the porcelain status is unchanged between prestate and
# poststate, so `comm -13` misses the overlap from "Files changed" (the diff
# content is still correct). Mitigation: stage or commit before delegating.
if [ -s "$CC_TMP/prestate.txt" ]; then
  WARNINGS="${WARNINGS}parent had pre-existing uncommitted changes — this report cannot reliably attribute overlapping file edits to opencode; review the full working tree diff carefully. "
fi

# Anomaly 8: malformed RESUME-SESSION id — ran a fresh session instead;
# flagged so the parent can fix the id and re-delegate.
if [ "$RESUME_HEADER_MALFORMED" -eq 1 ]; then
  WARNINGS="${WARNINGS}RESUME-SESSION header was present but the session id was malformed (expected 'ses_' followed by letters/digits) — ran a fresh session instead of resuming. "
fi

# Anomaly 9: provider.internal errors with no MODEL header — the signature of
# a broken config default model (spinning step_start events, then a 500).
# With a MODEL header the parent already knows which id to fix.
if [ -z "$MODEL_ID" ] && grep -q 'provider\.internal' "$CC_TMP/errors.txt" 2>/dev/null; then
  WARNINGS="${WARNINGS}provider.internal error with no MODEL header — the opencode config default model may be invalid/rotated; set a working default ('opencode models' to list) or prepend a 'MODEL: provider/model' header. "
fi

# ---- Step 4: status rubric ----
#
# success: exit 0, no error events
# partial: exit 0 but error events present — task may be incomplete
# failure: non-zero exit
if [ "$exit_code" -ne 0 ]; then
  STATUS="failure"
elif [ -s "$CC_TMP/errors.txt" ]; then
  STATUS="partial"
else
  STATUS="success"
fi

# ---- Step 5: emit structured summary ----
# The entire return value to the parent; fixed format for deterministic parsing.

# Diff stat one-liner; "0 files, +0/-0 lines" when empty.
if [ -s "$CC_TMP/diffstat.txt" ]; then
  DIFFSTAT_LINE=$(tail -n 1 "$CC_TMP/diffstat.txt")
  # Summary lines start with a leading space; trim it via bash parameter
  # expansion (no sed) for cross-platform parity.
  DIFFSTAT_LINE="${DIFFSTAT_LINE#"${DIFFSTAT_LINE%%[![:space:]]*}"}"
else
  DIFFSTAT_LINE="0 files, +0/-0 lines"
fi

# Changed-files list. Porcelain lines are `XY path`. Renames (R) and copies
# (C) emit two records under `-z` (new path with status, then source path
# without); skip_next swallows the second so it isn't listed as a phantom.
if [ -s "$CC_TMP/changed.txt" ]; then
  FILES_BLOCK=$(awk '
    {
      if (skip_next) { skip_next = 0; next }
      code = substr($0, 1, 2);
      path = substr($0, 4);
      gsub(/ /, "", code);
      printf "- %s (%s)\n", path, code;
      if (code == "R" || code == "C") skip_next = 1;
    }' "$CC_TMP/changed.txt")
else
  FILES_BLOCK="- none"
fi

# Summary placeholder when empty, so the parent's parser sees no stray blank line.
if [ -s "$CC_TMP/summary.txt" ]; then
  SUMMARY_TEXT=$(cat "$CC_TMP/summary.txt")
else
  SUMMARY_TEXT="(no final assistant text — see warnings)"
fi

# Warnings — "none" when nothing flagged.
if [ -z "$WARNINGS" ]; then
  WARNINGS="none"
fi

# Emit the fixed-format block. Multi-line summaries are fenced so the
# `**Field:**` shape stays parseable.
echo "## cheap-coder result"
echo ""
echo "**Status:** $STATUS"
case "$SUMMARY_TEXT" in
  *$'\n'*)
    echo "**Opencode summary:**"
    echo '```'
    printf '%s\n' "$SUMMARY_TEXT"
    echo '```'
    ;;
  *)
    echo "**Opencode summary:** $SUMMARY_TEXT"
    ;;
esac
echo "**Files changed:**"
echo "$FILES_BLOCK"
echo "**Diff size:** $DIFFSTAT_LINE"
if [ "$include_diff" -eq 1 ]; then
  echo "**Diff preview:** included"
else
  if [ "$new_untracked_count" -gt 0 ]; then
    echo "**Diff preview:** omitted (too large or empty — parent should run \`git diff\` for tracked changes AND inspect the \`??\` files listed above separately, since \`git diff\` does not show untracked file contents)"
  else
    echo "**Diff preview:** omitted (too large or empty — parent should run \`git diff\` directly)"
  fi
fi
echo "**Warnings:** $WARNINGS"
# Session id (when captured) — surfaced for resuming, regardless of status.
if [ -n "$SESSION_ID" ]; then
  echo "**Session ID:** $SESSION_ID"
  echo "**Resume with:** prepend 'RESUME-SESSION: $SESSION_ID' (then a blank line) to a follow-up task to continue this opencode conversation"
fi
if [ "$include_diff" -eq 0 ] && [ "$new_untracked_count" -gt 0 ]; then
  echo "**Next step (parent):** Review the diff before accepting. Run \`git diff\` for the tracked-file changes, and \`cat\` (or read) each \`??\` file listed above to see new untracked contents."
else
  echo "**Next step (parent):** Review the diff before accepting. If the preview is omitted, run \`git diff\` to see the full change."
fi

if [ "$include_diff" -eq 1 ]; then
  echo ""
  echo '```diff'
  cat "$CC_TMP/diff.txt"
  echo '```'
fi

# The EXIT trap cleans up $CC_TMP.
exit 0
