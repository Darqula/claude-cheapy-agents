# claude-cheapy-agents

A Claude Code subagent — **cheap-coder** — that delegates well-specified coding to a
low-cost external model (Qwen-3.7 Max via the [opencode](https://opencode.ai) CLI) while
the host Claude stays the PM and reviewer. The point is to cut token cost on routine
implementation without giving up host-side judgment: opencode writes the code, the host
reviews the diff before anything is committed.

## Requirements

- **opencode CLI** on PATH, authenticated, with a model configured (`opencode auth login`).
- **jq** — parses opencode's JSONL event stream.
- **bash** — Git Bash works on Windows.
- **node** — only needed for the test harness.

Install all of the above in one shot:

```bash
bash .claude/agents/install/install.sh        # Linux / macOS  (--check to report only)
powershell -ExecutionPolicy Bypass -File .claude\agents\install\install.ps1   # Windows
```

## Usage

The host invokes it through the standard Agent tool:

```
Agent(subagent_type: "cheap-coder", prompt: "<self-contained task>")
```

opencode has no memory of the host conversation and cannot ask questions, so the task
must be **self-contained**: concrete file paths (relative to the git root), exact
signatures/types, observable acceptance criteria, and any constraints. Avoid open-ended
verbs like "fix anything else you notice" — they invite scope creep.

- **Good:** "Add a `debounce<T extends (...args: any[]) => void>(fn: T, ms: number): T`
  helper to `src/utils/timing.ts` … add vitest tests for immediate-then-delay, rapid
  calls (only last fires), and ms=0."
- **Bad:** "Add debouncing and clean up the utils folder."

### Iterating on a result

cheap-coder returns a `**Session ID:**` line. To refine its output, resume the same
opencode conversation: start the follow-up task with `RESUME-SESSION: <id>` on its own
line, then a blank line, then your clarification. Before re-delegating, `git add`
(stage — never commit) the prior run's output so the next report attributes only the new
edits.

## How it works

cheap-coder runs as a single bash process that:

1. Verifies preconditions (opencode + jq on PATH, inside a git repo) and snapshots git state.
2. Prepends a non-negotiable git-policy prefix (opencode may not stage or commit) to the task.
3. Runs `opencode run` with per-tool permissions scoped to that one invocation, under a
   15-minute timeout where GNU `timeout` is available.
4. Harvests the result from `git diff`/`git status` (not by parsing opencode's output)
   and returns a fixed-format report: status, summary, files changed, diff size, a
   bounded diff preview (<500 lines), warnings, and the session id.

The raw opencode transcript never enters the host's context — only the bounded report
does. The coding model is whatever the user's opencode config selects (cheap-coder passes
no `-m`).

## Tests

```bash
.claude/agents/test/run-tests.sh        # all cases
```

The harness extracts the real bash template out of `cheap-coder.md` and runs it against a
fake opencode driven by env vars — so it exercises the shipped code, not a copy.

## Limitations

- **One git repo — the host's.** cheap-coder operates on the git repo of the session that
  invokes it and fails fast outside a repo; it can't be pointed at a different folder.
- **Stage before delegating to a dirty tree.** Pre-existing *unstaged* edits to a file the
  subagent also touches can't be cleanly attributed in the report (the diff content is
  still correct — only the "Files changed" list is affected). Stage or commit first.
- **No model override.** The coding model comes from the user's opencode config; cheap-coder
  does not pass `-m`/`--model`.

## More

- [`.claude/agents/cheap-coder.md`](.claude/agents/cheap-coder.md) — the agent: routing
  frontmatter + the bash protocol (every design decision is an inline comment).
- [`.claude/agents/README.md`](.claude/agents/README.md) — deeper design notes and rationale.
- [`.claude/agents/install/`](.claude/agents/install/) · [`.claude/agents/test/`](.claude/agents/test/)
  — dependency installers and the test harness.
