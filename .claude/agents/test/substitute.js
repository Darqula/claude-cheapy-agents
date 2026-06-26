#!/usr/bin/env node
// Substitute {{PARENT_TASK_QUOTED}} in the template with a single-quote-escaped
// form of the task string. Reads template from stdin, task from $TASK env var,
// writes the substituted bash script to stdout.
//
// The single-quote-escape rule: replace every ' with '\''. Then wrap in single
// quotes. This is the standard bash idiom for literal-quoting a string.
//
// We use Node here (not awk/sed) because both have backslash-handling traps
// in their replacement strings that produce subtly wrong output. Node's
// .split().join() is a literal string replacement — no backslash or special
// character interpretation in either the needle or the replacement.

const fs = require("fs");

const template = fs.readFileSync(0, "utf8");
const task = process.env.TASK || "";
const escaped = task.split("'").join("'\\''");
const quoted = "'" + escaped + "'";
const result = template.split("{{PARENT_TASK_QUOTED}}").join(quoted);
process.stdout.write(result);
