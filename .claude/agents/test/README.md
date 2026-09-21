# cheap-coder test harness

Runnable test suite for the [cheap-coder](../cheap-coder.md) subagent. Exercises the actual shipped engine script ([../lib/cheap-coder-run.sh](../lib/cheap-coder-run.sh)) against a fake opencode CLI that simulates prescribed behavior.

## Usage

```bash
.claude/agents/test/run-tests.sh           # run all cases
.claude/agents/test/run-tests.sh 03-add-untracked-nested   # run one case
```

A passing run prints `PASS` per case and exits 0. Failures print the failed assertions and the path to the case's captured stdout, then exit 1.

## What gets tested

Each test creates a fresh throwaway git repo via [fixtures/setup-clean-repo.sh](fixtures/setup-clean-repo.sh), optionally applies a prestate (e.g. a pre-existing untracked file), runs the shipped engine script against a fake opencode that mutates the working tree, and asserts against the structured stdout.

Production opencode is never invoked. Tests are deterministic and offline.

## What's under test

The harness invokes the real shipped engine, [../lib/cheap-coder-run.sh](../lib/cheap-coder-run.sh), exactly as the subagent and the `/cheap` skill do — passing the task as the first argument. The tests run the production script directly, so they cannot drift from what ships.

## Fake binaries

[fake-bin/opencode](fake-bin/opencode) is placed first on `PATH` when running cheap-coder. The fake opencode reads behavior from env vars set by the test case:

- `FAKE_OPENCODE_SCRIPT` — path to a script that mutates the working tree
- `FAKE_OPENCODE_SUMMARY` — the assistant summary text (default: "did the work")
- `FAKE_OPENCODE_ERROR` — if set, emit a JSONL error event before the summary
- `FAKE_OPENCODE_EXIT_CODE` — exit code to return (default: 0)
- `FAKE_OPENCODE_EMIT_NOTHING` — if `1`, emit no JSONL events
- `FAKE_OPENCODE_SESSION_ID` — session id stamped on every event (default: `ses_FAKE0001`)
- `FAKE_OPENCODE_ARGV_LOG` — set by the runner (not the case) to a path where the fake records `--session`/`--model` values, `CONFIG_SET=1` when `OPENCODE_CONFIG_CONTENT` is exported, `STANDALONE=1` when `--standalone` is passed, and the message it received; a case's `assert()` reads the same var to verify flag passthrough and header stripping

`jq` is **not** faked — tests run against the real `jq` binary, the same one cheap-coder requires in production.

## Writing a new case

A case is a bash file in [cases/](cases/) defining some of:

```bash
TASK="what to ask cheap-coder to do"          # task string passed to cheap-coder

prestate() {                                   # optional
  local repo=$1
  # apply state BEFORE cheap-coder runs (pre-existing files, etc.)
}

opencode_script() {                            # the fake opencode runs this in $REPO
  # mutate the working tree as if opencode did the work
}

EXTRA_SETUP="cd src/components"                # optional shell to run before cheap-coder

assert() {                                     # check the captured stdout
  local out=$1
  grep -q 'expected text' "$out" || echo "FAIL: reason"
  echo "PASS"
}
```

Per-case env vars (`FAKE_OPENCODE_SUMMARY` etc.) are exported automatically.

The case file is sourced inside a subshell, so cross-case state cannot leak.

## Prerequisites

- bash, git, jq, node (node is used by the fake opencode to JSON-encode event text)

The tests use the real `jq` binary — the same prerequisite cheap-coder enforces in production.
