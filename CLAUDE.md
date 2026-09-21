# Project instructions

## Delegate substantial implementation to the cheap-coder subagent

This project provides a `cheap-coder` subagent that hands well-specified coding to a
low-cost external model via the opencode CLI at coding-benchmark parity with Claude. For substantial implementation work it is the DEFAULT; small tasks you do
inline (see the size threshold below).

**IMPORTANT — routing rule, apply it on EVERY coding task:**

- DELEGATE BY DEFAULT any *substantial* task whose *what* is clear and whose work is
  *writing code*: multi-file features, new modules, broad mechanical refactors,
  repetitive boilerplate or test scaffolding, documentation sets — work where a short
  spec compresses a lot of generation. Ambiguity is the only hard disqualifier here.
- SIZE THRESHOLD — implement inline (do NOT delegate) when the task is SMALL: roughly a
  single file and under ~30 changed lines — a one-liner, a rename, a trivial fix, or
  anything where writing a self-contained spec is about as much work as the code itself.
  Below that line the spec, the round-trip latency, and the diff review cost more than
  just doing it. The test is *compression*: delegate when the implementation is large
  relative to its spec; do it yourself when the spec ≈ the code.
- You REMAIN the PM and reviewer. For delegated work, write a clear, self-contained spec
  (concrete file paths, signatures/types, acceptance criteria), delegate via
  `Agent(subagent_type: "cheap-coder", …)` — or the `/cheap` skill, which runs the same
  engine in-session with no subagent hop — then REVIEW the returned `git diff` yourself
  before accepting anything.
- Implement directly REGARDLESS of size when: defining the spec *is* the work
  (architecture decisions, "should we do X?"), the root cause is unknown
  (investigation/debugging), or the change depends on unwritten conversational context.

**Iterating on a cheap-coder result:**

- cheap-coder returns a `**Session ID:**` line. To refine its output, RESUME that
  session: start the follow-up task with `RESUME-SESSION: <id>` on its own line, then a
  blank line, then your clarification. opencode keeps the prior context, so this is far
  cheaper than re-explaining.
- ALWAYS `git add` (stage — NEVER `git commit`) the prior run's uncommitted output
  before the next delegation, so the next report attributes only the new edits and the
  diff is not silently truncated.
