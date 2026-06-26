#!/usr/bin/env bash
# cheap-coder dependency installer — Linux and macOS.
#
# Installs the prerequisites cheap-coder needs to run:
#   - jq        (REQUIRED — parses opencode's JSONL event stream; cheap-coder
#                hard-fails without it)
#   - opencode  (REQUIRED — the external coding CLI cheap-coder drives)
#   - coreutils (macOS only, RECOMMENDED — provides `gtimeout`, which powers
#                cheap-coder's 15-minute wall-clock cap; on Linux GNU `timeout`
#                is already present)
#
# It also CHECKS for (but does not install) node, which opencode/the test
# harness rely on, and reports if it is missing.
#
# Idempotent: anything already on PATH is left untouched. Safe to re-run.
#
# Windows users: run install.ps1 from PowerShell instead.
#
# Usage:
#   .claude/agents/install/install.sh           # install whatever is missing
#   .claude/agents/install/install.sh --check    # report status only, install nothing
#   .claude/agents/install/install.sh --help
#
# No `set -e`: a single failed install should not abort the rest — we install
# what we can and report a non-zero exit at the end if any REQUIRED dep failed.
set -u

# ---- pretty output (degrades gracefully when stdout is not a TTY) ----
if [ -t 1 ]; then
  BOLD=$(printf '\033[1m'); RED=$(printf '\033[31m'); GRN=$(printf '\033[32m')
  YLW=$(printf '\033[33m'); RST=$(printf '\033[0m')
else
  BOLD=""; RED=""; GRN=""; YLW=""; RST=""
fi
info() { printf '%s==>%s %s\n' "$BOLD" "$RST" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$YLW" "$RST" "$*"; }
err()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---- args ----
CHECK_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  -h|--help)
    grep '^#' "$0" | sed 's/^# \{0,1\}//; 1d'
    exit 0
    ;;
  "") ;;
  *) err "unknown argument: $1 (try --help)"; exit 2 ;;
esac

# ---- platform detection ----
OS=$(uname -s 2>/dev/null || echo unknown)
case "$OS" in
  Linux)  PLATFORM=linux ;;
  Darwin) PLATFORM=macos ;;
  *)
    err "unsupported platform '$OS' — this script handles Linux and macOS."
    err "On Windows, run install.ps1 from PowerShell instead."
    exit 1
    ;;
esac
info "Platform: $PLATFORM"

# ---- privilege escalation (Linux package managers need root) ----
SUDO=""
if [ "$(id -u 2>/dev/null || echo 1000)" -ne 0 ] && have sudo; then
  SUDO="sudo"
fi

# ---- package-manager detection ----
# macOS uses Homebrew; Linux probes the common distro managers in turn.
PM=""
if [ "$PLATFORM" = macos ]; then
  if have brew; then
    PM=brew
  else
    warn "Homebrew not found. Install it from https://brew.sh and re-run."
    warn "Falling back to non-brew install paths where possible."
  fi
else
  for candidate in apt-get dnf yum pacman zypper apk; do
    if have "$candidate"; then PM="$candidate"; break; fi
  done
  if [ -z "$PM" ]; then
    warn "no supported package manager found (apt-get/dnf/yum/pacman/zypper/apk)."
  fi
fi
[ -n "$PM" ] && info "Package manager: $PM"

# pm_install <packages...> — install via the detected package manager.
# Returns non-zero if no usable PM or the install command fails.
pm_install() {
  case "$PM" in
    apt-get) $SUDO apt-get update -y && $SUDO apt-get install -y "$@" ;;
    dnf)     $SUDO dnf install -y "$@" ;;
    yum)     $SUDO yum install -y "$@" ;;
    pacman)  $SUDO pacman -Sy --noconfirm "$@" ;;
    zypper)  $SUDO zypper install -y "$@" ;;
    apk)     $SUDO apk add "$@" ;;
    brew)    brew install "$@" ;;
    *)       return 1 ;;
  esac
}

FAILED=0  # set to 1 if any REQUIRED dependency is missing/uninstallable

# ---- jq (required) ----
install_jq() {
  if have jq; then
    ok "jq already present ($(jq --version 2>/dev/null))"
    return
  fi
  if [ "$CHECK_ONLY" -eq 1 ]; then warn "jq MISSING (required)"; FAILED=1; return; fi
  info "Installing jq..."
  if pm_install jq && have jq; then
    ok "jq installed ($(jq --version 2>/dev/null))"
  else
    err "could not install jq automatically — install it manually: https://jqlang.github.io/jq/download/"
    FAILED=1
  fi
}

# ---- opencode (required) ----
# Try, in order: Homebrew tap (macOS), the official install script (needs curl),
# then npm (needs node). Any one succeeding is enough.
install_opencode() {
  if have opencode; then
    ok "opencode already present ($(opencode --version 2>/dev/null | head -n1))"
    return
  fi
  if [ "$CHECK_ONLY" -eq 1 ]; then warn "opencode MISSING (required)"; FAILED=1; return; fi
  info "Installing opencode..."
  if [ "$PLATFORM" = macos ] && have brew; then
    if brew install sst/tap/opencode && have opencode; then
      ok "opencode installed (brew)"; return
    fi
  fi
  if have curl; then
    if curl -fsSL https://opencode.ai/install | bash && have opencode; then
      ok "opencode installed (official script)"; return
    fi
  fi
  if have npm; then
    if npm install -g opencode-ai && have opencode; then
      ok "opencode installed (npm)"; return
    fi
  fi
  err "could not install opencode automatically — see https://opencode.ai/docs/"
  err "(needs one of: Homebrew, curl, or npm)"
  FAILED=1
}

# ---- coreutils / gtimeout (macOS only, recommended) ----
# A failure here only warns — cheap-coder runs fine without a timeout, just
# without the 15-minute wall-clock guard.
install_timeout_macos() {
  if have gtimeout || have timeout; then
    ok "GNU timeout available (15-minute cap enabled)"
    return
  fi
  if [ "$CHECK_ONLY" -eq 1 ]; then
    warn "gtimeout MISSING (optional — enables cheap-coder's 15-min wall-clock cap)"
    return
  fi
  info "Installing coreutils (for gtimeout)..."
  if have brew && brew install coreutils && have gtimeout; then
    ok "coreutils installed (gtimeout available)"
  else
    warn "could not install coreutils — cheap-coder will run opencode without a wall-clock limit"
  fi
}

# ---- node (checked, not installed) ----
check_node() {
  if have node; then
    ok "node present ($(node --version 2>/dev/null)) — opencode/test harness OK"
  else
    warn "node not found — needed for opencode's npm install path and the test harness."
    warn "Install from https://nodejs.org/ or your package manager if you hit issues."
  fi
}

# ---- run ----
install_jq
install_opencode
[ "$PLATFORM" = macos ] && install_timeout_macos
check_node

echo
if [ "$FAILED" -eq 0 ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    info "${GRN}All required dependencies present.${RST}"
  else
    info "${GRN}Done — required dependencies are installed.${RST}"
  fi
  exit 0
else
  if [ "$CHECK_ONLY" -eq 1 ]; then
    err "One or more REQUIRED dependencies are missing (see above)."
  else
    err "One or more REQUIRED dependencies could not be installed (see above)."
  fi
  exit 1
fi
