---
name: cheap
description: Delegate a well-specified coding task to the low-cost external model (opencode) instead of writing it with premium tokens. Runs the shared cheap-coder engine directly in this session — no subagent hop — and returns a reviewable diff. Use for substantial, clearly-specified implementation work (multi-file features, mechanical refactors, test/boilerplate scaffolding); for a one-liner or trivial fix just do it inline. Invoke when the user types /cheap <task>, or when you (the host) decide to delegate without the subagent wrapper.
---

# /cheap — delegate implementation to opencode

Hand a self-contained coding task to the cheap external model via the shared engine
(`.claude/agents/lib/cheap-coder-run.sh`), then review the result. This is the **same
engine** the `cheap-coder` subagent runs; the only difference is it runs here, in this
session, with no subagent/model hop. You stay PM + reviewer either way.

The task is whatever the user passed after `/cheap` (or, if you invoked this yourself,
the task you intend to delegate).

## Steps

1. **Is it worth delegating?** If the task is a one-liner, a rename, or a trivial
   single-file fix (the spec is about as much text as the code), tell the user it's
   faster to just do inline, and offer to. Otherwise continue. (See the size threshold
   in `CLAUDE.md`.)
2. **Make the task self-contained.** opencode cannot see this conversation and cannot
   ask questions, so the string you send must include: concrete file paths *relative to
   the git repo root*, exact signatures/types, observable acceptance criteria (which
   tests must pass / what the output should be), and any constraints (libraries, style,
   patterns to follow). Avoid open-ended "fix anything else you notice." If the request
   is too vague to delegate safely, ask the user to clarify rather than guessing.
3. **Run the engine** with the task as a single-quoted argument (escape any literal `'`
   as `'\''`):

   ```bash
   bash .claude/agents/lib/cheap-coder-run.sh '<the self-contained task>'
   ```

   For a task dense with single-quotes, pipe it on stdin instead (no escaping at all);
   keep the closing marker unindented at column 0:

   ```bash
   bash .claude/agents/lib/cheap-coder-run.sh <<'CHEAP_CODER_TASK'
   <the self-contained task, verbatim>
   CHEAP_CODER_TASK
   ```

   Run it from the **repository root** — the script path is relative to it (the engine
   then pins opencode to the git root on its own).

4. **Review the report yourself.** It ends with a status, the changed files, a diff
   size, a bounded diff preview (<500 lines), warnings, and a session id. Run `git diff`
   for anything the preview omitted. You are the reviewer — do not accept blindly. The
   engine never stages or commits; changes are left unstaged for you.
5. **Report to the user**: what changed, whether it's correct, and any follow-up. To keep
   refining the *same* opencode run instead of starting over, see **Resuming a previous
   run** below.

## Resuming a previous run

Every report prints a `**Session ID:**` line. To continue *that* opencode conversation —
e.g. "you missed test case X", "rename the helper to Y" — instead of paying to
re-establish context, pass the follow-up task with a `RESUME-SESSION:` header as its first
line, then a blank line, then the clarification. The engine peels that header off and
passes `--session <id>` to opencode. First `git add` (stage — **never commit**) the prior
run's still-uncommitted output, so its changes are attributed to the previous step and the
next report shows only the new delta:

```bash
git add -A   # stage the prior run's output; never commit
bash .claude/agents/lib/cheap-coder-run.sh <<'CHEAP_CODER_TASK'
RESUME-SESSION: ses_3xampleAbc123

The helper looks good, but you skipped the ms=0 edge case — add a unit test for it.
CHEAP_CODER_TASK
```

The argument form works too (`bash .claude/agents/lib/cheap-coder-run.sh 'RESUME-SESSION: ses_…'`),
but the heredoc is easier for a multi-line follow-up. Omit the header to start fresh.

## Overriding the model

Prepend a `MODEL: <provider/model>` header (optionally `provider/model#variant`) as the
first line of the task to pin the coding model for that run:

```bash
bash .claude/agents/lib/cheap-coder-run.sh <<'CHEAP_CODER_TASK'
MODEL: opencode-go/glm-5.3-flash

<the self-contained task, verbatim>
CHEAP_CODER_TASK
```

It composes freely with `RESUME-SESSION:` (either order). No header → the opencode config
default — which only works if that default is a valid model (opencode v2 fails with
`provider.internal` otherwise; the report will say so). A malformed model id fails the run
fast rather than silently using some other default — the report tells you the expected
format, so fix the id and re-run.

## Requirements

opencode on PATH and a git repo (the engine fails fast otherwise). The raw opencode
transcript never enters context — only the bounded report does.
