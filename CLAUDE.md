# Project instructions

## ALWAYS delegate implementation to the cheap-coder subagent

This project provides a `cheap-coder` subagent that hands well-specified coding to a
low-cost external model (Qwen-3.7 Max via the opencode CLI) at coding-benchmark parity
with Claude. Using it is the DEFAULT, not the exception.

**IMPORTANT — routing rule, apply it on EVERY coding task:**

- BY DEFAULT, DELEGATE any task whose *what* is clear and whose work is *writing code*:
  new features, modules, tests, mechanical refactors, bug fixes with a known location,
  boilerplate, and documentation. File count and complexity are NEVER reasons to skip
  delegation — ONLY ambiguity is.
- You REMAIN the PM and reviewer. Write a clear, self-contained spec (concrete file
  paths, signatures/types, acceptance criteria), delegate via
  `Agent(subagent_type: "cheap-coder", …)`, then REVIEW the returned `git diff` yourself
  before accepting anything.
- Implement directly ONLY when one of these holds: defining the spec *is* the work
  (architecture decisions, "should we do X?"), the root cause is unknown
  (investigation/debugging), or the change depends on unwritten conversational context.
- NEVER skip delegation just because a task feels small or quick. Every line you write
  yourself spends the user's premium-model tokens; cheap-coder exists to make
  implementation cheap. THE BURDEN OF PROOF IS ON *NOT* DELEGATING.

**Iterating on a cheap-coder result:**

- cheap-coder returns a `**Session ID:**` line. To refine its output, RESUME that
  session: start the follow-up task with `RESUME-SESSION: <id>` on its own line, then a
  blank line, then your clarification. opencode keeps the prior context, so this is far
  cheaper than re-explaining.
- ALWAYS `git add` (stage — NEVER `git commit`) the prior run's uncommitted output
  before the next delegation, so the next report attributes only the new edits and the
  diff is not silently truncated.
