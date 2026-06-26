<#
.SYNOPSIS
  cheap-coder dependency installer for Windows.

.DESCRIPTION
  Installs the prerequisites cheap-coder needs to run on Windows:
    - jq        (REQUIRED — parses opencode's JSONL stream; cheap-coder hard-fails without it)
    - opencode  (REQUIRED — the external coding CLI cheap-coder drives)
    - Git for Windows (REQUIRED — cheap-coder's body is a bash script; Git Bash
                       also ships GNU `timeout` + coreutils, used for the 15-min cap)

  It also CHECKS for (but does not install) node, which opencode's npm install
  path and the test harness rely on.

  Uses winget, then Scoop, then Chocolatey — whichever is available. Idempotent:
  anything already on PATH is left untouched. Safe to re-run.

  Linux / macOS users: run install.sh instead.

.PARAMETER Check
  Report dependency status only; install nothing.

.EXAMPLE
  .\.claude\agents\install\install.ps1
.EXAMPLE
  .\.claude\agents\install\install.ps1 -Check
#>
[CmdletBinding()]
param([switch]$Check)

# Don't abort the whole script on the first failed install — install what we
# can and report a non-zero exit at the end if a REQUIRED dep is missing.
$ErrorActionPreference = 'Continue'

function Have($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }
function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  + $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "  x $m" -ForegroundColor Red }

$script:Failed = $false

# Detect available package manager, preferring winget (ships with modern Windows).
$Pm = $null
foreach ($candidate in 'winget', 'scoop', 'choco') {
  if (Have $candidate) { $Pm = $candidate; break }
}
if ($Pm) { Info "Package manager: $Pm" }
else {
  Warn "No package manager found (winget/scoop/choco)."
  Warn "Install one: winget ships with Windows 10/11; otherwise see https://scoop.sh or https://chocolatey.org"
}

# Run the detected package manager to install one logical package, given a
# per-manager id map. Output is shown to the console; callers verify success
# with a post-install `Have` check rather than this command's exit status,
# because native-command stdout would otherwise pollute a returned value.
function Install-Pkg($wingetId, $scoopId, $chocoId) {
  switch ($Pm) {
    'winget' { winget install --id $wingetId -e --source winget --accept-package-agreements --accept-source-agreements }
    'scoop'  { scoop install $scoopId }
    'choco'  { choco install $chocoId -y }
  }
}

# ---- jq (required) ----
function Install-Jq {
  if (Have jq) { Ok "jq already present ($(jq --version 2>$null))"; return }
  if ($Check) { Warn "jq MISSING (required)"; $script:Failed = $true; return }
  Info "Installing jq..."
  Install-Pkg 'jqlang.jq' 'jq' 'jq'
  if (Have jq) {
    Ok "jq installed"
  } else {
    Err "could not install jq automatically — https://jqlang.github.io/jq/download/"
    $script:Failed = $true
  }
}

# ---- Git for Windows (required — provides bash + GNU timeout + coreutils) ----
function Install-Git {
  if ((Have bash) -or (Have git)) { Ok "git/bash already present"; return }
  if ($Check) { Warn "Git for Windows MISSING (required — cheap-coder runs as a bash script)"; $script:Failed = $true; return }
  Info "Installing Git for Windows (provides Git Bash)..."
  Install-Pkg 'Git.Git' 'git' 'git'
  if ((Have git) -or (Have bash)) {
    Ok "Git for Windows installed — run cheap-coder from Git Bash"
  } else {
    Err "could not install Git for Windows automatically — https://git-scm.com/download/win"
    $script:Failed = $true
  }
}

# ---- opencode (required) ----
# npm is the most reliable cross-manager path on Windows; fall back to package
# managers that carry an opencode package.
function Install-Opencode {
  if (Have opencode) { Ok "opencode already present ($(opencode --version 2>$null | Select-Object -First 1))"; return }
  if ($Check) { Warn "opencode MISSING (required)"; $script:Failed = $true; return }
  Info "Installing opencode..."
  if (Have npm) {
    npm install -g opencode-ai
    if (Have opencode) { Ok "opencode installed (npm)"; return }
  }
  if ($Pm) {
    Install-Pkg 'opencode.opencode' 'opencode' 'opencode'
    if (Have opencode) { Ok "opencode installed ($Pm)"; return }
  }
  Err "could not install opencode automatically — see https://opencode.ai/docs/"
  Err "(easiest path: install Node.js, then 'npm install -g opencode-ai')"
  $script:Failed = $true
}

# ---- node (checked, not installed) ----
function Check-Node {
  if (Have node) {
    Ok "node present ($(node --version 2>$null)) — opencode/test harness OK"
  } else {
    Warn "node not found — needed for opencode's npm install path and the test harness."
    Warn "Install from https://nodejs.org/ (or 'winget install OpenJS.NodeJS')."
  }
}

# ---- run ----
Install-Git
Install-Jq
Install-Opencode
Check-Node

Write-Host ""
if (-not $script:Failed) {
  if ($Check) { Info "All required dependencies present." }
  else { Info "Done — required dependencies are installed. Run cheap-coder from Git Bash." }
  exit 0
} else {
  if ($Check) { Err "One or more REQUIRED dependencies are missing (see above)." }
  else { Err "One or more REQUIRED dependencies could not be installed (see above)." }
  exit 1
}
