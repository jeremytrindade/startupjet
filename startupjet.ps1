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

function Refresh-SessionPath {
  $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machinePath;$userPath"

  # npm global bin (where claude, codex, etc. land)
  $npmGlobal = Join-Path $env:APPDATA "npm"
  if ((Test-Path $npmGlobal) -and ($env:Path -notlike "*$npmGlobal*")) {
    $env:Path += ";$npmGlobal"
  }

  # Common install paths that winget uses but may not register until next login
  $extraPaths = @(
    "$env:ProgramFiles\Git\cmd"
    "$env:ProgramFiles\GitHub CLI"
    "$env:ProgramFiles\nodejs"
    "$env:ProgramFiles\PowerShell\7"
    "$env:ProgramFiles\Tailscale"
    "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin"
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links"
    "$env:LOCALAPPDATA\Programs\Python\Python312"
    "$env:LOCALAPPDATA\Programs\Python\Python312\Scripts"
    "$env:LOCALAPPDATA\Programs\Python\Python311"
    "$env:LOCALAPPDATA\Programs\Python\Python311\Scripts"
    "$env:LOCALAPPDATA\Programs\Ollama"
    "$env:USERPROFILE\.local\bin"
    "$env:USERPROFILE\.cargo\bin"
  )
  foreach ($p in $extraPaths) {
    if ((Test-Path $p) -and ($env:Path -notlike "*$p*")) {
      $env:Path += ";$p"
    }
  }
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
  @{ name = "VS Code";      cmd = "code";       wingetId = "Microsoft.VisualStudioCode" }
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
          Refresh-SessionPath
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

# === Phase 2b: AI coding assistants ===
Write-Phase "PHASE 2b, AI coding assistants"

$aiTools = @(
  @{ name = "Claude Code";  cmd = "claude"; pkg = "@anthropic-ai/claude-code" }
  @{ name = "OpenAI Codex"; cmd = "codex";  pkg = "@openai/codex" }
)

$npmAvailable = Test-Command "npm"
if (-not $npmAvailable) {
  Write-Host "  npm not available. AI coding assistants require Node.js + npm." -ForegroundColor Yellow
  Write-Host "  Install Node.js first, then re-run startupjet." -ForegroundColor Yellow
} else {
  foreach ($ai in $aiTools) {
    if (Test-Command $ai.cmd) {
      Write-Host ("  [OK] " + $ai.name + " already installed") -ForegroundColor Green
      $script:summary.alreadyHad += $ai.name
    } else {
      $reply = Read-Host ("  Install " + $ai.name + "? [y/N]")
      if ($reply -eq "y" -or $reply -eq "Y") {
        Write-Host ("  Installing " + $ai.name + " via npm...")
        npm install -g $ai.pkg 2>&1 | Out-Null
        Refresh-SessionPath
        if (Test-Command $ai.cmd) {
          Write-Host ("  [OK] " + $ai.name + " installed") -ForegroundColor Green
          $script:summary.installed += $ai.name
        } else {
          Write-Host ("  [!!] " + $ai.name + " installed but not yet on PATH. Restart terminal after setup.") -ForegroundColor Yellow
          $script:summary.installed += $ai.name
        }
      } else {
        Write-Host ("  [skip] " + $ai.name) -ForegroundColor Yellow
      }
    }
  }
}

# === Phase 2c: Project-specific dependencies ===
Write-Phase "PHASE 2c, project-specific dependencies"

Write-Host "  local-llm-council-pc (local AI council on GPU)" -ForegroundColor White
Write-Host "    Requires: Ollama (LLM runtime), uv (Python pkg manager), Python >= 3.11" -ForegroundColor Cyan
Write-Host "    Also downloads 3 models (~14GB): llama3.1:8b, qwen2.5:7b, mistral:7b" -ForegroundColor Cyan
Write-Host ""

$reply = Read-Host "  Install local-llm-council-pc dependencies? [y/N]"
if ($reply -eq "y" -or $reply -eq "Y") {
  $projectDeps = @(
    @{ name = "Ollama";  cmd = "ollama"; wingetId = "Ollama.Ollama" }
    @{ name = "uv";      cmd = "uv";    wingetId = "astral-sh.uv" }
  )

  if (-not (Test-Command "winget")) {
    Write-Host "  winget not found, cannot auto-install." -ForegroundColor Red
  } else {
    foreach ($dep in $projectDeps) {
      if (Test-Command $dep.cmd) {
        Write-Host ("  [OK] " + $dep.name + " already installed") -ForegroundColor Green
        $script:summary.alreadyHad += $dep.name
      } else {
        Write-Host ("  Installing " + $dep.name + "...")
        winget install --id $dep.wingetId --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        Refresh-SessionPath
        if (Test-Command $dep.cmd) {
          Write-Host ("  [OK] " + $dep.name + " installed") -ForegroundColor Green
          $script:summary.installed += $dep.name
        } else {
          Write-Host ("  [!!] " + $dep.name + " installed but not yet on PATH. Restart terminal after setup.") -ForegroundColor Yellow
          $script:summary.installed += $dep.name
        }
      }
    }
  }

  # Ask about each model individually
  if (Test-Command "ollama") {
    Write-Host ""
    Write-Host "  Optional: download AI models for the council (requires Ollama)." -ForegroundColor Cyan
    Write-Host "  These run locally on your GPU. Each is a one-time download." -ForegroundColor Cyan
    Write-Host ""

    $models = @(
      @{ name = "llama3.1:8b"; size = "4.9 GB" }
      @{ name = "qwen2.5:7b";  size = "4.7 GB" }
      @{ name = "mistral:7b";  size = "4.1 GB" }
    )

    foreach ($model in $models) {
      $reply = Read-Host ("  Download " + $model.name + " (" + $model.size + ")? [y/N]")
      if ($reply -eq "y" -or $reply -eq "Y") {
        Write-Host ("  Pulling " + $model.name + " (this may take a few minutes)...")
        ollama pull $model.name
        if ($LASTEXITCODE -eq 0) {
          Write-Host ("  [OK] " + $model.name + " ready") -ForegroundColor Green
        } else {
          Write-Host ("  [!!] " + $model.name + " pull failed") -ForegroundColor Red
        }
      } else {
        Write-Host ("  [skip] " + $model.name) -ForegroundColor Yellow
      }
    }
  }
} else {
  Write-Host "  [skip] local-llm-council-pc dependencies" -ForegroundColor Yellow
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

# Final PATH refresh to pick up everything installed during this session
Refresh-SessionPath

Write-Host "  Verifying all tools are reachable on PATH..." -ForegroundColor Cyan
Write-Host ""

$allTools = @(
  @{ name = "Git";          cmd = "git";        versionFlag = "--version" }
  @{ name = "GitHub CLI";   cmd = "gh";         versionFlag = "--version" }
  @{ name = "Python 3";     cmd = "python";     versionFlag = "--version" }
  @{ name = "PowerShell 7"; cmd = "pwsh";       versionFlag = "--version" }
  @{ name = "OpenSSH";      cmd = "ssh";        versionFlag = "-V" }
  @{ name = "Node.js";      cmd = "node";       versionFlag = "--version" }
  @{ name = "npm";          cmd = "npm";        versionFlag = "--version" }
  @{ name = "VS Code";      cmd = "code";       versionFlag = "--version" }
  @{ name = "Tailscale";    cmd = "tailscale";  versionFlag = "--version" }
  @{ name = "cloudflared";  cmd = "cloudflared";versionFlag = "--version" }
  @{ name = "Claude Code";  cmd = "claude";     versionFlag = "--version" }
  @{ name = "OpenAI Codex"; cmd = "codex";      versionFlag = "--version" }
  @{ name = "Ollama";       cmd = "ollama";     versionFlag = "--version" }
  @{ name = "uv";           cmd = "uv";         versionFlag = "--version" }
)

$notOnPath = @()
foreach ($t in $allTools) {
  if (Test-Command $t.cmd) {
    $ver = & $t.cmd $t.versionFlag 2>&1 | Select-Object -First 1
    Write-Host ("  [OK] " + $t.name + ": $ver") -ForegroundColor Green
  } else {
    $notOnPath += $t.name
  }
}

if ($notOnPath.Count -gt 0) {
  Write-Host ""
  Write-Host "  Not on PATH (not installed or needs terminal restart):" -ForegroundColor Yellow
  foreach ($n in $notOnPath) {
    Write-Host ("    - $n") -ForegroundColor Yellow
  }
}

# Smoke test: write to ai-journal if cloned
Write-Host ""
$aiJournal = Join-Path $githubFolder "ai-journal"
if (Test-Path $aiJournal) {
  Write-Host "  ai-journal smoke test..."
  $testFile = Join-Path $aiJournal "_startupjet-smoke-test.tmp"
  "smoke test $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $testFile -Encoding UTF8
  Remove-Item $testFile -Force
  Write-Host "  [OK] write smoke test passed" -ForegroundColor Green
} else {
  Write-Host "  [skip] ai-journal not cloned, skipping smoke test" -ForegroundColor Yellow
}

# gh auth verify
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
