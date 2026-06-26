# cheap-coder dependency installers

One-shot scripts that install everything [cheap-coder](../cheap-coder.md) needs
to run, on all three supported platforms. They are idempotent — anything already
on `PATH` is left untouched, so they are safe to re-run.

| Platform | Script | Run with |
|---|---|---|
| Linux | [install.sh](install.sh) | `bash .claude/agents/install/install.sh` |
| macOS | [install.sh](install.sh) | `bash .claude/agents/install/install.sh` |
| Windows | [install.ps1](install.ps1) | `powershell -ExecutionPolicy Bypass -File .claude\agents\install\install.ps1` |

`install.sh` auto-detects Linux vs macOS; one script covers both because they
share bash and most of the logic. Windows gets its own PowerShell script.

## What they install

| Dependency | Required? | Why | Notes |
|---|---|---|---|
| **jq** | **Yes** | Parses opencode's JSONL event stream; cheap-coder hard-fails without it | Installed everywhere |
| **opencode** | **Yes** | The external coding CLI cheap-coder drives | brew → official script → npm (unix); npm → package manager (Windows) |
| **GNU `timeout`** | Recommended | Powers cheap-coder's 15-minute wall-clock cap | Linux: already present. macOS: installed via `coreutils` (as `gtimeout`). Windows: ships with Git Bash |
| **Git for Windows** | **Yes (Windows)** | cheap-coder's body is a bash script — Git Bash provides bash, `timeout`, and coreutils | Windows only; unix already has bash |
| **node** | Checked, not installed | opencode's npm install path and the test harness need it | Scripts warn (with install hint) if missing rather than pulling a heavy runtime |

After opencode is installed you still need to point it at a model — set a default
coding model in your opencode config (`~/.config/opencode/opencode.json` or
equivalent). The installers do not touch that file.

## Usage

```bash
# Linux / macOS — install whatever is missing
bash .claude/agents/install/install.sh

# Report status only, install nothing
bash .claude/agents/install/install.sh --check
```

```powershell
# Windows — install whatever is missing
powershell -ExecutionPolicy Bypass -File .claude\agents\install\install.ps1

# Report status only, install nothing
powershell -ExecutionPolicy Bypass -File .claude\agents\install\install.ps1 -Check
```

Exit code is `0` when all **required** dependencies are present, non-zero if any
required one is missing or could not be installed. Optional dependencies (the
timeout cap, node) only warn.

## Package managers used

- **Linux** — first match of `apt-get`, `dnf`, `yum`, `pacman`, `zypper`, `apk`.
  Uses `sudo` automatically when not root.
- **macOS** — [Homebrew](https://brew.sh). If brew is absent the script falls
  back to opencode's official installer / npm where possible and points you to
  install brew for jq.
- **Windows** — first match of `winget` (ships with Windows 10/11), Scoop, or
  Chocolatey.

If automatic installation fails, each script prints the manual install URL for
the dependency that could not be installed.
