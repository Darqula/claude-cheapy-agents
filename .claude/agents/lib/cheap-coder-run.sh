#!/usr/bin/env bash
# cheap-coder protocol — runs in ONE bash process so all shell variables stay live.
# No `set -e`: the protocol deliberately tolerates expected non-zero exits
# (e.g. `jq` returning empty when no error events exist). Exit codes that
# actually matter are checked explicitly.

# ---- Step 1: setup ----

# Per-invocation scratch dir. Bare `mktemp -d` works on GNU, BSD, and Git Bash
# (the `-t TEMPLATE` form has divergent semantics across platforms — do not use it).
CC_TMP=$(mktemp -d) || { echo "FATAL: mktemp -d failed"; exit 1; }

# Guarantee cleanup on ANY exit path (normal, error, SIGINT, SIGTERM, opencode
# crash, our own `exit N` below). The `[ -n ... ]` guard is paranoia in case
# CC_TMP is somehow empty — `rm -rf ""` errors out harmlessly on modern rm
# but we'd rather not even try.
trap '[ -n "$CC_TMP" ] && rm -rf "$CC_TMP"' EXIT

# Precondition: opencode CLI must be installed and on PATH.
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

# Precondition: jq must be installed. The summary/error-event extractors
# depend on it; without jq, those `jq` calls would fail silently (stderr is
# discarded) and the script would report `success` with no summary and no
# error detection. Fail fast and tell the parent.
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

# Precondition: must be inside a git repo. We need a stable root for `--dir`
# and we need `git status`/`git diff` to track opencode's work.
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

# Move into the repo root for every subsequent git operation. opencode itself
# is pinned via `--dir "$GIT_ROOT"`, but several git commands we invoke from
# this script are cwd-sensitive (notably `git ls-files --others`, which only
# lists untracked files under the current directory). Without this cd, if the
# parent invoked us from a subdirectory, untracked-file discovery and any
# relative paths would silently miss content outside that subtree. Matches
# the documented contract that paths are interpreted relative to repo root.
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

# Record pre-existing uncommitted changes so opencode's modifications can be
# distinguished from work the parent already had in progress.
#   - `--porcelain -z` uses NUL record separators AND emits paths raw (no
#     double-quoting of paths containing spaces or non-ASCII chars, which
#     plain --porcelain would otherwise produce).
#   - `-uall` expands untracked directories to their individual files.
#     Without this, a new directory like `src/new-module/` would appear as
#     a single `?? src/new-module/` entry, hiding the actual nested files
#     from both the changed list and the synthesized untracked-file diff.
#   - `tr '\0' '\n'` converts back to line-oriented so `sort` and `comm`
#     work normally. Safe because v1 `-z` never emits literal newlines
#     inside paths (the one case `-z` is specifically designed to protect).
#   - LC_ALL=C pins sort order to byte-wise so `comm` later cannot be
#     misled by locale differences between this sort and the poststate sort.
LC_ALL=C git status --porcelain -uall -z | tr '\0' '\n' | LC_ALL=C sort > "$CC_TMP/prestate.txt"

# Snapshot the index tree hash so we can detect if opencode mutated the index
# despite the no-staging policy. `git write-tree` hashes the current index into
# a tree object without modifying anything. Comparing pre vs post tells us
# whether the index changed during the opencode run — far more precise than
# `git diff --cached --quiet`, which false-positives on any pre-existing
# staged content. Empty string if not in a git repo with a valid index;
# the guard above already rejected that case, so we expect a valid hash here.
PRE_INDEX_TREE=$(git write-tree 2>/dev/null)

# ---- Step 2: invoke opencode ----

# The parent's task. Passed as the FIRST ARGUMENT when present; otherwise read from
# stdin (e.g. a `<<'EOF'` heredoc), which needs no shell-escaping at all. Callers that
# can quote reliably — the /cheap skill, the test harness, a human on the CLI — pass it
# as "$1". The stdin path is the no-escaping escape hatch for tasks with gnarly quotes.
# Either way the rest of the protocol is identical; nothing here is templated anymore.
if [ "$#" -ge 1 ]; then
  PARENT_TASK="$1"
else
  PARENT_TASK="$(cat)"
fi

# Optional session resumption. The parent may prepend a single header line
#   RESUME-SESSION: ses_<id>
# (optionally followed by a blank line) to the task string. If present, we peel
# it off and pass `--session <id>` to opencode so the conversation continues
# instead of starting fresh. We use an explicit id (never opencode's `--continue`
# "last session") because each cheap-coder call is an independent process — a
# concurrent opencode run elsewhere could otherwise become the "last session".
#
# All string surgery here is pure bash parameter expansion (no sed/awk) so it
# behaves identically across GNU/BSD/Git Bash. `${var%%$'\n'*}` is the first
# line; `${var#*$'\n'}` is everything after the first newline.
RESUME_SESSION_ID=""
RESUME_HEADER_MALFORMED=0
case "$PARENT_TASK" in
  "RESUME-SESSION: "*)
    resume_first_line=${PARENT_TASK%%$'\n'*}
    resume_candidate=${resume_first_line#RESUME-SESSION: }
    # Strip the header line, and one optional blank separator line, from the body.
    resume_body=${PARENT_TASK#*$'\n'}
    [ "$resume_body" = "$PARENT_TASK" ] && resume_body=""   # header-only, no body
    case "$resume_body" in $'\n'*) resume_body=${resume_body#$'\n'} ;; esac
    PARENT_TASK=$resume_body
    # Validate: opencode session ids are `ses_` + base62 ([A-Za-z0-9]). Anything
    # else (empty, wrong prefix, stray chars) is treated as no-resume and warned
    # about later, so the parent still gets a result and learns the header was bad.
    if printf '%s' "$resume_candidate" | grep -Eq '^ses_[A-Za-z0-9]+$'; then
      RESUME_SESSION_ID=$resume_candidate
    else
      RESUME_HEADER_MALFORMED=1
    fi
    ;;
esac

# Compose the full prompt: non-negotiable git-policy prefix + the parent's task.
# The prefix instructs opencode never to stage/commit — we want all changes left
# as unstaged modifications so the parent can review the diff before deciding
# what to commit. Trust-based enforcement (no post-check); opencode follows
# explicit instructions reliably and the parent will see any violations in the
# resulting git state regardless.
FULL_TASK="IMPORTANT — git policy: Do NOT run 'git add', 'git commit', 'git stash', or any other command that modifies the git index or refs. Leave all your changes as unstaged modifications in the working tree. The parent agent will review the diff and decide what to commit.

Your task:
${PARENT_TASK}"

# 15-minute wall-clock timeout to prevent hanging opencode runs from blocking
# the parent forever. The `timeout` binary is tricky cross-platform:
#   - Linux:        /usr/bin/timeout (GNU coreutils) — what we want
#   - macOS:        no `timeout` by default; GNU version installs as `gtimeout`
#                   from Homebrew coreutils
#   - Git Bash:     ships GNU `timeout`, BUT PATH often resolves first to
#                   C:\Windows\System32\timeout.exe — a completely different
#                   utility that waits for a keypress and does NOT run commands.
#                   Using it would silently break us.
# Strategy: probe candidates and require GNU coreutils signature in --version
# output. If nothing qualifies, run opencode unprotected with a warning.
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

# Run opencode. Key choices:
#   - OPENCODE_PERMISSION (env var): per-tool permission policy scoped to this
#     ONE invocation. Does not touch the user's opencode.json. Allows what
#     opencode needs for normal coding work, denies external_directory
#     (sandbox escape), question (no human to answer in non-interactive mode),
#     task/skill (cheap-coder runs one task, doesn't spawn its own agents).
#   - --dir: pinned to git root so opencode's cwd is unambiguous on Windows
#     where the shell's cwd can drift.
#   - --format json: emits JSONL event stream — one event per line. Stdout
#     redirected to a file so the raw transcript never enters the agent's
#     context. Stderr captured separately for diagnostics.
#   - --session: passed ONLY when the parent supplied a valid RESUME-SESSION
#     header (parsed above). `${RESUME_SESSION_ID:+--session $RESUME_SESSION_ID}`
#     expands to nothing when empty, preserving the fresh-session default exactly.
#   - No -m/--model flag: model selection comes from the user's opencode config.
# `${TIMEOUT_CMD:+$TIMEOUT_CMD 900}` expands to `timeout 900` if probe succeeded,
# nothing otherwise.
#
# Two defensive measures for non-interactive use, both no-ops in a normal terminal:
#
#  1. Drop any inherited http(s)_proxy. Some environments (a sandbox / network-
#     mediation layer) inject http_proxy/https_proxy; opencode honors them and routes
#     its backend API calls through that proxy, which can stall for minutes even when
#     direct egress works fine. Unsetting talks to the backend directly.
#  2. Redirect opencode's stdin from /dev/null. The task is already captured (as the
#     argument or via the stdin read above), so opencode needs no stdin of its own —
#     and an inherited non-TTY stdin (which the subagent's Bash call hands down) can
#     otherwise make it block waiting on input that never arrives.
#
# Both are pure no-ops in a normal interactive shell with no proxy, so they are safe
# everywhere.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
OPENCODE_PERMISSION='{"read":"allow","edit":"allow","glob":"allow","grep":"allow","lsp":"allow","websearch":"allow","webfetch":"allow","bash":"allow","external_directory":"deny","question":"deny","task":"deny","skill":"deny"}' \
${TIMEOUT_CMD:+$TIMEOUT_CMD 900} \
opencode run \
  --dir "$GIT_ROOT" \
  --format json \
  ${RESUME_SESSION_ID:+--session $RESUME_SESSION_ID} \
  "$FULL_TASK" \
  < /dev/null \
  > "$CC_TMP/opencode.jsonl" 2> "$CC_TMP/opencode.err"
exit_code=$?

# ---- Step 3: extract minimal summary ----

# Each extraction below uses `jq` (or similar) to write a small bounded file.
# We never `cat` the raw jsonl — it can be huge. Each output file is what we
# eventually read into the summary.

# Pre-create all the scratch files we'll read from below. The counters use
# `wc -l < file` which complains noisily to bash's stderr if the file does
# not exist (the redirection failure bypasses wc's own 2>/dev/null). The
# extractors below may not write some files (e.g. no error events).
: > "$CC_TMP/summary.txt"
: > "$CC_TMP/errors.txt"
: > "$CC_TMP/changed.txt"
: > "$CC_TMP/diff.txt"
: > "$CC_TMP/diffstat.txt"
: > "$CC_TMP/new_untracked.txt"

# 3a. Final assistant text (opencode's own summary, last `text` event).
#     Strategy: find the LAST JSONL line containing `"type":"text"`, then
#     extract `.part.text` from that single line. This is safer than
#     `jq | tail -n 1` because jq's raw output for a string containing
#     embedded newlines is multi-line — `tail -n 1` would then take only
#     the last LINE of the summary, silently truncating multi-line content.
#     `grep ... | tail -n 1` operates on JSONL lines (one event per line),
#     which is the right granularity.
LAST_TEXT_LINE=$(grep '"type":"text"' "$CC_TMP/opencode.jsonl" 2>/dev/null | tail -n 1)
if [ -n "$LAST_TEXT_LINE" ]; then
  printf '%s\n' "$LAST_TEXT_LINE" | jq -r '.part.text' > "$CC_TMP/summary.txt" 2>/dev/null
fi

# Fallback: more permissive filter that doesn't pin the event-type discriminator.
# Handles schema drift where the `type` field is renamed/missing but `part.text`
# still exists. Take the last JSONL line that has any `.part.text` content.
if [ ! -s "$CC_TMP/summary.txt" ]; then
  LAST_PART_LINE=$(grep '"part"' "$CC_TMP/opencode.jsonl" 2>/dev/null | tail -n 1)
  if [ -n "$LAST_PART_LINE" ]; then
    printf '%s\n' "$LAST_PART_LINE" | jq -r '.part.text // empty' > "$CC_TMP/summary.txt" 2>/dev/null
  fi
fi

# Cap summary at 8KB — the diff is the authoritative artifact, the summary
# is just a hint. Lossy truncation is acceptable.
if [ "$(wc -c < "$CC_TMP/summary.txt" 2>/dev/null || echo 0)" -gt 8192 ]; then
  head -c 8192 "$CC_TMP/summary.txt" > "$CC_TMP/summary.txt.tmp"
  printf "\n[...truncated at 8KB; see diff for full picture]" >> "$CC_TMP/summary.txt.tmp"
  mv "$CC_TMP/summary.txt.tmp" "$CC_TMP/summary.txt"
fi

# 3a-bis. Capture opencode's session id. Every JSONL event carries it as
#     "sessionID":"ses_<base62>" at the top level; we only need the first hit.
#     The parent reuses this to resume the conversation via a RESUME-SESSION:
#     header on a follow-up delegation. grep-then-sed (not jq) because the value
#     is a fixed-shape token and this avoids any event-type discrimination.
SESSION_ID=$(grep -m1 -o '"sessionID":"ses_[A-Za-z0-9]*"' "$CC_TMP/opencode.jsonl" 2>/dev/null | head -n 1 | sed 's/.*"ses_/ses_/; s/"$//')

# 3b. Error events from the stream (separate from exit code; opencode can
#     emit errors without aborting).
jq -r 'select(.type=="error") | "\(.error.name): \(.error.data.message // "no message")"' "$CC_TMP/opencode.jsonl" 2>/dev/null > "$CC_TMP/errors.txt"

# 3c. Files opencode changed. We derive from git, not from parsing tool_use
#     events, because the field name for paths inside `part.state.input`
#     varies by tool (filePath, path, file, etc. — undocumented). Git is
#     authoritative and schema-version-independent.
#     Same `-z | tr | sort` pipeline as prestate so the two files have
#     identical ordering and unquoted paths — required for `comm` to work
#     correctly. LC_ALL=C pins byte-wise sort, locale-independent.
LC_ALL=C git status --porcelain -uall -z | tr '\0' '\n' | LC_ALL=C sort > "$CC_TMP/poststate.txt"
comm -13 "$CC_TMP/prestate.txt" "$CC_TMP/poststate.txt" > "$CC_TMP/changed.txt"

# 3d. Diff stat and size. Plain `git diff` only covers tracked-file
#     modifications — it ignores untracked files entirely. Since cheap-coder
#     is heavily used for greenfield work (new modules, new tests, new docs),
#     we must explicitly synthesize diffs for untracked files too, or the
#     parent's report would be misleadingly empty for the most common case.
#
#     Strategy: tracked diff via `git diff`, then append a `git diff --no-index`
#     against /dev/null for each untracked file that is *new since prestate*.
#     Critical: we drive the untracked-file list from `changed.txt` (the
#     `comm -13` delta of porcelain status), NOT from `git ls-files --others`.
#     The latter returns ALL current untracked files, including any scratch
#     files the parent had lying around before delegating — those would
#     pollute the diff and be wrongly attributed to opencode. The `??`-coded
#     entries in `changed.txt` are by construction "untracked AND new since
#     prestate", which is exactly what we want.
git diff > "$CC_TMP/diff.txt" 2>/dev/null
# Extract paths for newly-untracked files from the delta. Each `changed.txt`
# line is `XY path` with XY being the porcelain status (here `??` for
# untracked). awk strips the 3-char prefix to recover the path.
awk '/^\?\? / { print substr($0, 4) }' "$CC_TMP/changed.txt" > "$CC_TMP/new_untracked.txt"
# Synthesize a diff for each new untracked file. `--no-index` exits non-zero
# when files differ (always vs /dev/null), so we tolerate that with `|| true`.
while IFS= read -r untracked; do
  [ -z "$untracked" ] && continue
  git diff --no-index --no-color /dev/null "$untracked" >> "$CC_TMP/diff.txt" 2>/dev/null || true
done < "$CC_TMP/new_untracked.txt"
# Stat derived from the combined diff via `git apply --stat` (works on diff
# text rather than re-running git diff, so it counts untracked additions).
# Fall back to plain `git diff --stat` if `git apply --stat` rejects the
# synthesized hunks. The most common cause of the fallback is binary
# untracked files: `git diff --no-index /dev/null binary` emits "Binary
# files ... differ" which `git apply --stat` cannot parse. Track whether
# the fallback was taken so we can warn the parent that the diff stat
# may not reflect untracked additions.
stat_fallback=0
if ! git apply --stat "$CC_TMP/diff.txt" > "$CC_TMP/diffstat.txt" 2>/dev/null; then
  git diff --stat > "$CC_TMP/diffstat.txt" 2>/dev/null
  stat_fallback=1
fi
# Counters: use `wc -l` rather than `grep -c .`. The latter exits 1 when
# the file has zero matching lines and emits "0", so `grep -c . file ||
# echo 0` captures BOTH outputs and produces a multi-line "0\n0" string
# that breaks the arithmetic comparison `[ "$x" -gt 0 ]` later. `wc -l`
# always exits 0 and emits a single integer. Safe because our porcelain
# captures always terminate every record with a newline.
diff_lines=$(wc -l < "$CC_TMP/diff.txt" 2>/dev/null || echo 0)
diff_lines=${diff_lines:-0}
new_untracked_count=$(wc -l < "$CC_TMP/new_untracked.txt" 2>/dev/null || echo 0)
new_untracked_count=${new_untracked_count:-0}

# 3e. Decide whether to include diff content in the response. Cap at 500 lines
#     to keep the parent's context bounded — for larger diffs, the parent runs
#     `git diff` directly.
include_diff=0
if [ "$diff_lines" -gt 0 ] && [ "$diff_lines" -lt 500 ]; then
  include_diff=1
fi

# 3f. Anomaly detection — defensive defaults so empty files don't break the
#     arithmetic comparison ([ "" -gt 0 ] is a syntax error in bash).
summary_size=$(wc -c < "$CC_TMP/summary.txt" 2>/dev/null || echo 0)
summary_size=${summary_size:-0}
changed_count=$(wc -l < "$CC_TMP/changed.txt" 2>/dev/null || echo 0)
changed_count=${changed_count:-0}
jsonl_size=$(wc -c < "$CC_TMP/opencode.jsonl" 2>/dev/null || echo 0)
jsonl_size=${jsonl_size:-0}

WARNINGS=""

# Anomaly 1: opencode changed files but produced no final assistant text.
# Likely a crash mid-output or schema mismatch.
if [ "$summary_size" -eq 0 ] && [ "$changed_count" -gt 0 ]; then
  WARNINGS="${WARNINGS}opencode changed files but produced no final summary text — possible crash or schema mismatch; review the diff carefully. "
fi

# Anomaly 2: opencode produced almost nothing at all (event stream <100 bytes).
# Distinguishes "ran successfully but did nothing visible" (ambiguous) from
# normal success.
if [ "$jsonl_size" -lt 100 ] && [ "$exit_code" -eq 0 ]; then
  WARNINGS="${WARNINGS}opencode produced unusually small output stream (<100 bytes) — verify the task was understood. "
fi

# Anomaly 3: opencode hit the wall-clock timeout (only possible when GNU
# timeout was active). Exit 124 = killed by timeout.
if [ "$exit_code" -eq 124 ]; then
  WARNINGS="${WARNINGS}opencode exceeded 15-minute wall-clock timeout and was killed. "
fi

# Anomaly 4: error events present in stream.
if [ -s "$CC_TMP/errors.txt" ]; then
  err_preview=$(head -c 500 "$CC_TMP/errors.txt" | tr '\n' '; ')
  WARNINGS="${WARNINGS}error events from opencode: ${err_preview}. "
fi

# Anomaly 5: non-zero exit code (other than the timeout case already handled).
if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 124 ]; then
  stderr_preview=$(tail -c 500 "$CC_TMP/opencode.err" 2>/dev/null | tr '\n' '; ')
  WARNINGS="${WARNINGS}opencode exited non-zero (code $exit_code): ${stderr_preview}. "
fi

# Anomaly 6: git index mutated during the opencode run. Compare the index
# tree hash captured before opencode ran against a fresh hash now. If they
# differ, opencode disobeyed the no-staging policy (or something else
# modified the index concurrently). Plain `git diff` hides staged changes,
# so without this signal the parent could silently miss work.
POST_INDEX_TREE=$(git write-tree 2>/dev/null)
if [ -n "$PRE_INDEX_TREE" ] && [ -n "$POST_INDEX_TREE" ] && [ "$PRE_INDEX_TREE" != "$POST_INDEX_TREE" ]; then
  WARNINGS="${WARNINGS}git index changed during opencode run — opencode may have staged changes despite the no-staging policy; inspect with 'git diff --cached'. "
fi

# Anomaly 7: `git apply --stat` rejected the combined diff and we fell back
# to tracked-only stat. Most likely cause: a binary untracked file produced
# a "Binary files ... differ" line that `git apply --stat` cannot parse.
# When this happens alongside new untracked files, the reported diff stat
# does NOT include those untracked additions — warn the parent.
if [ "$stat_fallback" -eq 1 ] && [ "$new_untracked_count" -gt 0 ]; then
  WARNINGS="${WARNINGS}diff stat fell back to tracked-only — likely a binary untracked file; the 'Diff size' below does not count untracked additions. Inspect the listed '??' files directly. "
fi

# Caveat about the comm-based file list: if the parent had pre-existing
# uncommitted changes to a file (e.g. ` M foo.ts` in prestate) and opencode
# also modified that file, the porcelain status line is unchanged between
# prestate and poststate. `comm -13` then misses the overlap and the file
# does not appear in "Files changed" — though the actual diff content
# (git diff) still shows opencode's modifications correctly. Documented
# rather than fixed: the simplest mitigation is for the parent to commit
# or stash before delegating to a dirty tree.
if [ -s "$CC_TMP/prestate.txt" ]; then
  WARNINGS="${WARNINGS}parent had pre-existing uncommitted changes — this report cannot reliably attribute overlapping file edits to opencode; review the full working tree diff carefully. "
fi

# Anomaly 8: the parent supplied a RESUME-SESSION: header but the id was not a
# valid `ses_<base62>` token. We ran a FRESH session (no --session) rather than
# fail, so the parent still gets a result — but flag it so they can fix the id
# and re-delegate to actually resume.
if [ "$RESUME_HEADER_MALFORMED" -eq 1 ]; then
  WARNINGS="${WARNINGS}RESUME-SESSION header was present but the session id was malformed (expected 'ses_' followed by letters/digits) — ran a fresh session instead of resuming. "
fi

# ---- Step 4: status rubric ----
#
# success: exit code 0 AND no error events
# partial: exit code 0 BUT error events present (opencode reported issues
#          while continuing — task may be incomplete)
# failure: exit code non-zero
if [ "$exit_code" -ne 0 ]; then
  STATUS="failure"
elif [ -s "$CC_TMP/errors.txt" ]; then
  STATUS="partial"
else
  STATUS="success"
fi

# ---- Step 5: emit structured summary to stdout ----
# This is the entire return value to the parent. Format is fixed so the
# parent can parse it deterministically.

# Diff stat one-liner (e.g. "3 files changed, +42/-15 lines"). Falls back
# to "0 files, +0/-0 lines" when diff is empty.
if [ -s "$CC_TMP/diffstat.txt" ]; then
  DIFFSTAT_LINE=$(tail -n 1 "$CC_TMP/diffstat.txt")
  # `git apply --stat` / `git diff --stat` summary lines start with a leading
  # space (e.g. " 2 files changed, 204 insertions(+)"). Trim it so the rendered
  # "**Diff size:** N files…" has no double space. Pure bash param expansion
  # (no sed) for cross-platform parity.
  DIFFSTAT_LINE="${DIFFSTAT_LINE#"${DIFFSTAT_LINE%%[![:space:]]*}"}"
else
  DIFFSTAT_LINE="0 files, +0/-0 lines"
fi

# Format changed-files list. Each porcelain line is `XY path` where XY is
# the 2-char status code (M = modified, A = added, ?? = untracked, etc.).
# Renames (R) and copies (C) emit TWO records under `-z`: first the new
# path with the status code, then the old/source path with no status.
# The `skip_next` flag swallows that second record so we don't list it
# as a phantom unchanged entry.
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

# Summary text — fall back to a placeholder if empty so the parent's
# template parser doesn't see a stray blank line.
if [ -s "$CC_TMP/summary.txt" ]; then
  SUMMARY_TEXT=$(cat "$CC_TMP/summary.txt")
else
  SUMMARY_TEXT="(no final assistant text — see warnings)"
fi

# Warnings — "none" when nothing flagged.
if [ -z "$WARNINGS" ]; then
  WARNINGS="none"
fi

# Print the structured block. Parent will copy this verbatim.
# Multi-line summaries (paragraphs, markdown lists) are emitted as a fenced
# block on their own so the structured `**Field:**` shape stays parseable.
# Single-line summaries stay inline for readability.
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
# Surface the session id (when captured) so the parent can iterate on this exact
# opencode conversation. Emitted regardless of status — even a failed/partial run
# is worth resuming. Placed near the end where the parent's eye lands.
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

# EXIT trap will now clean up $CC_TMP automatically.
exit 0
