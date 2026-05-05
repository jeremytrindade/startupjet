# startupjet.ps1, fresh-PC bootstrap orchestrator (MVP, single-file).
# Author: Jeremy Trindade. License: MIT.

$ErrorActionPreference = "Continue"
$script:summary = @{
  installed     = @()
  alreadyHad    = @()
  failed        = @()
  authenticated = @()
  reposCloned   = @()
  reposSkipped  = @()
}

# === Helpers ===
function Write-Phase($title) {
  Write-Host ""
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host (" $title") -ForegroundColor Cyan
  Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Test-Command($name) {
  $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

# === Phase 1: Detect ===
Write-Phase "PHASE 1, detect prerequisites"

$prerequisites = @(
  @{ name = "Git";          cmd = "git";        wingetId = "Git.Git" }
  @{ name = "GitHub CLI";   cmd = "gh";         wingetId = "GitHub.cli" }
  @{ name = "Python 3";     cmd = "python";     wingetId = "Python.Python.3.12" }
  @{ name = "PowerShell 7"; cmd = "pwsh";       wingetId = "Microsoft.PowerShell" }
  @{ name = "OpenSSH";      cmd = "ssh";        wingetId = $null;  manual = "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" }
  @{ name = "Tailscale";    cmd = "tailscale";  wingetId = "tailscale.tailscale" }
  @{ name = "cloudflared";  cmd = "cloudflared";wingetId = "Cloudflare.cloudflared" }
  @{ name = "Node.js";      cmd = "node";       wingetId = "OpenJS.NodeJS" }
)

$missing = @()
foreach ($p in $prerequisites) {
  if (Test-Command $p.cmd) {
    Write-Host ("  [OK] " + $p.name) -ForegroundColor Green
    $script:summary.alreadyHad += $p.name
  } else {
    Write-Host ("  [--] " + $p.name + " missing") -ForegroundColor Yellow
    $missing += $p
  }
}

Write-Host ""
Write-Host ("  $($script:summary.alreadyHad.Count) installed, $($missing.Count) missing")

# === Phase 2: Install ===
if ($missing.Count -gt 0) {
  Write-Phase "PHASE 2, install missing tools ($($missing.Count))"

  if (-not (Test-Command "winget")) {
    Write-Host "  winget not found. Cannot auto-install. Install tools manually." -ForegroundColor Red
  } else {
    $reply = Read-Host "Install all missing? [Y/n]"
    if ($reply -ne "n" -and $reply -ne "N") {
      foreach ($m in $missing) {
        Write-Host ("  Installing " + $m.name + "...")
        if ($m.wingetId) {
          winget install --id $m.wingetId --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
          # Refresh PATH for this session
          $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
          if (Test-Command $m.cmd) {
            Write-Host ("  [OK] " + $m.name + " installed") -ForegroundColor Green
            $script:summary.installed += $m.name
          } else {
            Write-Host ("  [!!] " + $m.name + " installed but not yet on PATH. Restart terminal after setup.") -ForegroundColor Yellow
            $script:summary.installed += $m.name
          }
        } else {
          Write-Host ("  No winget package. Manual install required:") -ForegroundColor Yellow
          Write-Host ("    $($m.manual)") -ForegroundColor White
          $script:summary.failed += $m.name
        }
      }
    }
  }
} else {
  Write-Phase "PHASE 2, install (skipped, nothing missing)"
}

# === Phase 3: Authenticate ===
Write-Phase "PHASE 3, authenticate accounts"

if (Test-Command "gh") {
  $ghStatus = gh auth status 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  Running gh auth login (follow the browser prompts)..."
    gh auth login
  } else {
    Write-Host "  [OK] GitHub CLI already authenticated" -ForegroundColor Green
  }
  $script:summary.authenticated += "GitHub (gh)"
} else {
  Write-Host "  [skip] gh not available, skipping GitHub auth" -ForegroundColor Yellow
}

$reply = Read-Host "Authenticate Tailscale now? [y/N]"
if ($reply -eq "y" -or $reply -eq "Y") {
  if (Test-Command "tailscale") {
    tailscale up
    $script:summary.authenticated += "Tailscale"
  } else {
    Write-Host "  tailscale not installed, skipping" -ForegroundColor Yellow
  }
}

$reply = Read-Host "Authenticate cloudflared now? [y/N]"
if ($reply -eq "y" -or $reply -eq "Y") {
  if (Test-Command "cloudflared") {
    cloudflared tunnel login
    $script:summary.authenticated += "cloudflared"
  } else {
    Write-Host "  cloudflared not installed, skipping" -ForegroundColor Yellow
  }
}

# === Phase 4: Configure ===
Write-Phase "PHASE 4, configure workspace"

$workspacePath = Read-Host "Workspace path [D:\claudeui]"
if ([string]::IsNullOrWhiteSpace($workspacePath)) { $workspacePath = "D:\claudeui" }

$githubUser = Read-Host "GitHub username [jeremytrindade]"
if ([string]::IsNullOrWhiteSpace($githubUser)) { $githubUser = "jeremytrindade" }

$gitEmail = Read-Host "Git email [jeremytrindade@gmail.com]"
if ([string]::IsNullOrWhiteSpace($gitEmail)) { $gitEmail = "jeremytrindade@gmail.com" }

git config --global user.email $gitEmail
git config --global user.name $githubUser

# Save user config
$configDir = Join-Path $PSScriptRoot "config"
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
$configPath = Join-Path $configDir "user-config.json"
@{
  workspacePath = $workspacePath
  githubUser    = $githubUser
  gitEmail      = $gitEmail
  timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
} | ConvertTo-Json | Out-File $configPath -Encoding UTF8

Write-Host "  Config saved to $configPath" -ForegroundColor Green

# === Phase 5: Clone repos ===
Write-Phase "PHASE 5, clone repos"

$githubFolder = Join-Path $workspacePath "github"
New-Item -ItemType Directory -Force -Path $githubFolder | Out-Null

$reposJsonPath = Join-Path $PSScriptRoot "config\repos.json"
if (Test-Path $reposJsonPath) {
  $reposData = Get-Content $reposJsonPath -Raw | ConvertFrom-Json
  $repos = $reposData.repos
} else {
  # Fallback defaults if no config file
  $repos = @(
    [PSCustomObject]@{ owner = "jeremytrindade"; name = "playbook";   required = $true }
    [PSCustomObject]@{ owner = "jeremytrindade"; name = "ai-journal"; required = $true }
  )
}

foreach ($repo in $repos) {
  $url  = "https://github.com/$($repo.owner)/$($repo.name).git"
  $dest = Join-Path $githubFolder $repo.name
  if (Test-Path $dest) {
    Write-Host ("  [skip] " + $repo.name + " already exists at $dest")
    continue
  }
  Write-Host ("  cloning " + $repo.name + "...")
  git clone $url $dest 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Host ("  [OK] " + $repo.name) -ForegroundColor Green
    $script:summary.reposCloned += $repo.name
  } else {
    if ($repo.required -eq $true) {
      Write-Host ("  [FAIL] " + $repo.name + " (required, clone failed)") -ForegroundColor Red
    } else {
      Write-Host ("  [skip] " + $repo.name + " (private or no access)") -ForegroundColor Yellow
    }
    $script:summary.reposSkipped += $repo.name
  }
}

# === Phase 6: Verify ===
Write-Phase "PHASE 6, verify"

$aiJournal = Join-Path $githubFolder "ai-journal"
if (Test-Path $aiJournal) {
  Write-Host "  ai-journal cloned, smoke test write..."
  $testFile = Join-Path $aiJournal "_startupjet-smoke-test.tmp"
  "smoke test $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $testFile -Encoding UTF8
  Remove-Item $testFile -Force
  Write-Host "  [OK] write smoke test passed" -ForegroundColor Green
} else {
  Write-Host "  [skip] ai-journal not cloned, skipping smoke test" -ForegroundColor Yellow
}

# Git verify
if (Test-Command "git") {
  $v = git --version 2>&1
  Write-Host "  [OK] git: $v" -ForegroundColor Green
}
if (Test-Command "gh") {
  $ghWho = gh api user --jq '.login' 2>&1
  if ($LASTEXITCODE -eq 0) {
    Write-Host "  [OK] gh authenticated as: $ghWho" -ForegroundColor Green
  }
}

# === Summary ===
Write-Phase "SUMMARY"
Write-Host ("  Installed:        " + ($script:summary.installed -join ", "))
Write-Host ("  Already had:      " + ($script:summary.alreadyHad -join ", "))
Write-Host ("  Failed install:   " + ($script:summary.failed -join ", "))
Write-Host ("  Authenticated:    " + ($script:summary.authenticated -join ", "))
Write-Host ("  Repos cloned:     " + ($script:summary.reposCloned -join ", "))
Write-Host ("  Repos skipped:    " + ($script:summary.reposSkipped -join ", "))
Write-Host ""
Write-Host "  Workspace ready at: $workspacePath" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Now in any AI chat, paste this:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Read $workspacePath\github\ai-journal\UPDATE.md and follow it." -ForegroundColor White
Write-Host ""
