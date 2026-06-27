# cheap-coder — overview

A Claude Code subagent that delegates well-specified implementation work to a cheaper external coding model (Qwen / GLM / DeepSeek / MiniMax) via the [opencode](https://opencode.ai) CLI. The host Claude agent acts as PM and reviewer; cheap-coder is the implementer.

The goal is cost reduction without quality loss: modern Chinese coding models hit parity with Claude on SWE-Bench Verified/Pro, so file count and complexity are not disqualifiers — only task ambiguity is.

## Why

Claude tokens are expensive. Most of a coding session's token spend goes into routine implementation work (boilerplate, mechanical refactors, test scaffolding, single-file edits with clear specs) where a cheaper model produces equivalent output. If the host can offload that work to opencode and only review the resulting diff, the total cost per task drops substantially while the host's judgment stays in the loop where it matters.

The constraint is that the host must remain fully in control of the codebase state. opencode runs the edits, but the host reviews everything before any commit happens.

## How it works

When the host decides a task is well-specified enough to delegate, it invokes `Agent(subagent_type: "cheap-coder", prompt: "<task description>")` (older docs and installations may show this tool as `Task`, which Claude Code keeps as a compatibility alias). The subagent:

1. Sets up an isolated scratch directory and verifies preconditions (opencode installed, current dir is a git repo).
2. Wraps the parent's task with a fixed git-policy prefix (forbidding opencode from staging or committing).
3. Runs `opencode run` with a per-tool permission policy (allow read/edit/grep/bash for normal coding; deny sandbox-escape, interactive questions, sub-agent spawning).
4. Captures opencode's full event stream to a temp file (never enters the host's context).
5. Extracts a minimal structured summary via `jq` filters and `git diff`/`git status`.
6. Returns one fixed-format response to the host: status, file list, diff stat, optional diff preview (if <500 lines), warnings, and a "next step: review" directive.
7. Cleans up the scratch dir on every exit path via an EXIT trap.

The host then reviews the diff and decides whether to commit.

## Design principles

**Bounded summarization.** opencode's raw output can be tens of thousands of tokens. None of it touches the host. cheap-coder filters everything through `jq` into bounded files, then prints a fixed-format summary capped at ~10KB plus a 500-line diff preview. Above 500 diff lines, the host runs `git diff` itself.

**Script, not an inline template.** The subagent doesn't reproduce the bash protocol — it invokes a fixed, version-controlled script ([lib/cheap-coder-run.sh](lib/cheap-coder-run.sh)) and passes only the task (as an argument, or on stdin). Keeping the orchestrator's output to one short command — rather than a 500-line block it must retype verbatim — removes a whole class of failure modes: subtle drift, or a small orchestration model mangling the script (e.g. mis-quoting it) across invocations.

**Single Bash invocation.** The entire protocol runs in one bash process. Shell variables stay live; no inter-step state plumbing; cleanup is guaranteed by the EXIT trap regardless of how the script exits.

**No staging, no committing.** opencode is instructed via a non-negotiable prefix on every task: leave all changes as unstaged modifications. The host reviews the unstaged diff and decides what to commit.

**Trust but track.** opencode's exit code, error events, and diff are all surfaced to the host. The host can see if opencode produced unusually small output, if error events were emitted, if a wall-clock timeout fired, or if a no-staging violation occurred.

**Cross-platform bash.** Works on Linux, macOS, and Git Bash on Windows. Notable details: `mktemp -d` with no flags (the `-t` flag has divergent semantics across platforms), GNU `timeout` probing that rejects Windows's decoy `timeout.exe`, `LC_ALL=C` on sorts so `comm` is locale-stable, `git status --porcelain -z | tr` to handle paths with spaces or non-ASCII characters.

## Session resumption

opencode often doesn't nail a task in one shot — it picks the wrong file, misses a test, or asks (in its summary) a question the parent could answer in a sentence. Rather than re-delegate from scratch (paying to re-establish context) or drop down to direct host work (defeating the cost saving), the parent can **resume the same opencode conversation**.

The session id rides the agent's two existing channels — no new input/output plumbing:

- **Capture (opencode → parent):** every JSONL event carries `"sessionID":"ses_…"`. cheap-coder greps the first one and prints it as a `**Session ID:**` line in the structured summary (emitted for `success`, `partial`, *and* `failure` — even a broken run is worth iterating on).
- **Replay (parent → opencode):** the parent prepends one header line — `RESUME-SESSION: ses_xxx`, then a blank line, then the follow-up — to the task string. The engine script peels the header off the task body and passes `--session ses_xxx` to `opencode run`.

Two deliberate choices:

- **Explicit id, never `--continue`.** opencode's `--continue` ("last session") is non-deterministic here: each cheap-coder call is an independent process, so an unrelated opencode run on the same machine between two delegations could become the "last session" we'd accidentally resume. Explicit ids are unambiguous.
- **Malformed id degrades gracefully.** If the header is present but the id isn't a valid `ses_<base62>` token, cheap-coder runs a fresh session (no `--session`) and emits a warning, so the parent still gets a result and learns the header was wrong rather than silently losing the resume.

`--fork` is intentionally out of scope for now; it can be layered in later by parsing a second optional header.

## Files in this folder

| File | Purpose |
|---|---|
| [cheap-coder.md](cheap-coder.md) | The agent itself. Frontmatter routes the host; body tells the subagent to invoke the engine script with the task. |
| [lib/cheap-coder-run.sh](lib/cheap-coder-run.sh) | The engine — the entire bash protocol. Invoked identically by the subagent, the `/cheap` skill, and the test harness. |
| [install/](install/) | One-shot dependency installers (jq, opencode, timeout) for Linux, macOS, and Windows. See [install/README.md](install/README.md). |
| [test/](test/) | Runnable test harness — drives the engine script against a fake opencode. See [test/README.md](test/README.md). |

## Usage from another agent

The host calls cheap-coder via the standard Agent tool (formerly `Task` — still accepted as an alias in current Claude Code):

```
Agent(
  subagent_type: "cheap-coder",
  prompt: "Add a `debounce<T extends (...args: any[]) => void>(fn: T, ms: number): T` helper to src/utils/timing.ts. It should delay calling fn until ms milliseconds have passed since the last invocation. Add unit tests in src/utils/timing.test.ts covering: immediate-then-delay, rapid successive calls (only last fires), and ms=0 edge case. Use vitest, matching the style in src/utils/string.test.ts."
)
```

The task string should be self-contained — opencode has no memory of the host's conversation and cannot ask clarifying questions. Include concrete file paths (relative to git root), exact function signatures, observable acceptance criteria, and any constraints. Avoid open-ended verbs like "fix any other issues you notice."

The frontmatter description in `cheap-coder.md` documents the routing criteria (USE / DO NOT USE) and task-format guidance for the host.

## Limitations

- **Single git repo only.** cheap-coder fails fast if invoked outside a git repo. The host needs to `git init` first if working on something un-versioned.
- **No-staging policy is prompt-enforced, with detection.** The git-policy prefix instructs opencode never to `git add`/`git commit`/`git stash`. cheap-coder snapshots the index tree (`git write-tree`) before and after the opencode run and emits a warning if it changed — so disobedience does not go silently undetected. The prompt is still the actual enforcement; the warning just makes violations visible.
- **Concurrent invocations are independent.** Each invocation uses its own `mktemp -d` scratch dir, so two cheap-coder calls won't clobber each other, but they will operate on the same working tree — if both modify the same file, results depend on execution order.
- **15-minute wall-clock timeout.** Opencode runs that exceed 15 minutes are killed (when GNU timeout is available). The host receives a timeout warning and can re-delegate with a smaller task if appropriate.
- **No opencode model override.** Opencode's coding model is selected from the user's local opencode config; cheap-coder does not pass `-m`/`--model`. (The Claude-side orchestration model is separately pinned to Haiku via `model: haiku` in the agent frontmatter, since cheap-coder itself only performs mechanical substitution and one Bash call — no judgment work that needs a bigger model.)

## Settings / installation

cheap-coder lives in `.claude/agents/cheap-coder.md` and is discovered automatically by Claude Code when the project is opened. No global setup required.

The prerequisites below can be installed in one shot with the platform scripts in [install/](install/):

```bash
# Linux / macOS
bash .claude/agents/install/install.sh          # add --check to report status only

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File .claude\agents\install\install.ps1
```

The scripts are idempotent (anything already present is skipped) and install jq + opencode on all platforms, GNU `timeout` where applicable, and Git for Windows on Windows. See [install/README.md](install/README.md) for details. You still need to point opencode at a default model in its own config.

Prerequisites on the developer machine:
- [opencode CLI](https://opencode.ai) installed and on PATH.
- The user's opencode config (`~/.config/opencode/opencode.json` or similar) configured with a default model — whichever cheap model the user prefers.
- `jq` installed and on PATH — used to parse opencode's JSONL event stream into the report summary and to detect error events. cheap-coder hard-fails fast with a structured error if `jq` is missing.
- A working `bash` shell. On Windows, Git Bash works.
- Optional but recommended: GNU `timeout` (Linux: included; macOS: install coreutils via Homebrew, gives `gtimeout`; Git Bash: included).
