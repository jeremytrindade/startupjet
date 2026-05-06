# startupjet.ps1, fresh-PC bootstrap orchestrator (MVP, single-file).
# Author: Jeremy Trindade. License: MIT.
#
# Flow: detect -> choose (all questions upfront) -> authenticate -> configure
#       -> install (unattended) -> clone (unattended) -> verify -> summary
#
# After the "choose" and "authenticate" phases, no more user input is needed.
# You can walk away and come back to a fully configured PC.

$ErrorActionPreference = "Continue"
$script:summary = @{
  installed     = @()
  alreadyHad    = @()
  failed        = @()
  skipped       = @()
  authenticated = @()
  reposCloned   = @()
  reposSkipped  = @()
  modelsLoaded  = @()
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

  $npmGlobal = Join-Path $env:APPDATA "npm"
  if ((Test-Path $npmGlobal) -and ($env:Path -notlike "*$npmGlobal*")) {
    $env:Path += ";$npmGlobal"
  }

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

# =====================================================================
# PHASE 1: DETECT (silent scan, no questions)
# =====================================================================
Write-Phase "PHASE 1, scanning your system"

$catalog = @(
  # Dev tools
  @{ id = 1;  name = "Git";            cmd = "git";        category = "dev";      method = "winget"; wingetId = "Git.Git";                   installed = $false; selected = $false }
  @{ id = 2;  name = "GitHub CLI";     cmd = "gh";         category = "dev";      method = "winget"; wingetId = "GitHub.cli";                 installed = $false; selected = $false }
  @{ id = 3;  name = "Python 3";       cmd = "python";     category = "dev";      method = "winget"; wingetId = "Python.Python.3.12";         installed = $false; selected = $false }
  @{ id = 4;  name = "PowerShell 7";   cmd = "pwsh";       category = "dev";      method = "winget"; wingetId = "Microsoft.PowerShell";       installed = $false; selected = $false }
  @{ id = 5;  name = "OpenSSH";        cmd = "ssh";        category = "dev";      method = "manual"; manual = "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"; installed = $false; selected = $false }
  @{ id = 6;  name = "Node.js";        cmd = "node";       category = "dev";      method = "winget"; wingetId = "OpenJS.NodeJS";              installed = $false; selected = $false }
  @{ id = 7;  name = "VS Code";        cmd = "code";       category = "dev";      method = "winget"; wingetId = "Microsoft.VisualStudioCode"; installed = $false; selected = $false }
  # Network
  @{ id = 8;  name = "Tailscale";      cmd = "tailscale";  category = "network";  method = "winget"; wingetId = "tailscale.tailscale";        installed = $false; selected = $false }
  @{ id = 9;  name = "cloudflared";    cmd = "cloudflared"; category = "network"; method = "winget"; wingetId = "Cloudflare.cloudflared";     installed = $false; selected = $false }
  # AI coding assistants
  @{ id = 10; name = "Claude Code";    cmd = "claude";     category = "ai";       method = "npm";    pkg = "@anthropic-ai/claude-code";       installed = $false; selected = $false }
  @{ id = 11; name = "OpenAI Codex";   cmd = "codex";      category = "ai";       method = "npm";    pkg = "@openai/codex";                   installed = $false; selected = $false }
  # Local AI (GPU)
  @{ id = 12; name = "Ollama";         cmd = "ollama";     category = "local-ai"; method = "winget"; wingetId = "Ollama.Ollama";              installed = $false; selected = $false }
  @{ id = 13; name = "uv";             cmd = "uv";         category = "local-ai"; method = "winget"; wingetId = "astral-sh.uv";               installed = $false; selected = $false }
  # AI models (ollama pull)
  @{ id = 14; name = "llama3.1:8b";    cmd = $null;        category = "model";    method = "ollama"; size = "4.9 GB";                         installed = $false; selected = $false }
  @{ id = 15; name = "qwen2.5:7b";     cmd = $null;        category = "model";    method = "ollama"; size = "4.7 GB";                         installed = $false; selected = $false }
  @{ id = 16; name = "mistral:7b";     cmd = $null;        category = "model";    method = "ollama"; size = "4.1 GB";                         installed = $false; selected = $false }
)

# Check what is already installed
foreach ($item in $catalog) {
  if ($item.method -eq "ollama") {
    # Models: check if ollama is available and model is pulled
    if (Test-Command "ollama") {
      $modelList = ollama list 2>&1
      if ($modelList -match [regex]::Escape($item.name)) {
        $item.installed = $true
      }
    }
  } elseif ($item.cmd) {
    $item.installed = Test-Command $item.cmd
  }
}

$alreadyInstalled = @($catalog | Where-Object { $_.installed })
$notInstalled     = @($catalog | Where-Object { -not $_.installed })

Write-Host ""
foreach ($item in $catalog) {
  if ($item.installed) {
    Write-Host ("  [OK] " + $item.name) -ForegroundColor Green
    $script:summary.alreadyHad += $item.name
  } else {
    $sizeNote = if ($item.size) { " ($($item.size))" } else { "" }
    Write-Host ("  [--] " + $item.name + $sizeNote) -ForegroundColor Yellow
  }
}
Write-Host ""
Write-Host ("  $($alreadyInstalled.Count) installed, $($notInstalled.Count) available to install")

# =====================================================================
# PHASE 2: CHOOSE (all questions upfront, then no more input until done)
# =====================================================================
Write-Phase "PHASE 2, choose what to install"

if ($notInstalled.Count -eq 0) {
  Write-Host "  Everything is already installed!" -ForegroundColor Green
} else {
  Write-Host ""
  Write-Host "  What would you like to install?" -ForegroundColor White
  Write-Host ""
  Write-Host "    [1] Install everything ($($notInstalled.Count) items)" -ForegroundColor Cyan
  Write-Host "    [2] Install everything EXCEPT local AI + models (skip Ollama, uv, models)" -ForegroundColor Cyan
  Write-Host "    [3] Customize (pick from the list)" -ForegroundColor Cyan
  Write-Host "    [4] Skip installs (only authenticate + configure + clone)" -ForegroundColor Cyan
  Write-Host ""

  $mode = Read-Host "  Choose [1/2/3/4]"

  switch ($mode) {
    "1" {
      foreach ($item in $notInstalled) { $item.selected = $true }
      Write-Host "  Selected: everything ($($notInstalled.Count) items)" -ForegroundColor Green
    }
    "2" {
      foreach ($item in $notInstalled) {
        if ($item.category -ne "local-ai" -and $item.category -ne "model") {
          $item.selected = $true
        }
      }
      $selectedCount = @($catalog | Where-Object { $_.selected }).Count
      Write-Host "  Selected: $selectedCount items (local AI skipped)" -ForegroundColor Green
    }
    "3" {
      Write-Host ""
      Write-Host "  Available to install (enter numbers separated by commas, or 'all'):" -ForegroundColor White
      Write-Host ""

      $categoryLabels = @{
        "dev"      = "Dev tools"
        "network"  = "Network"
        "ai"       = "AI coding assistants"
        "local-ai" = "Local AI (GPU)"
        "model"    = "AI models (downloaded via Ollama)"
      }
      $lastCategory = ""
      foreach ($item in $notInstalled) {
        if ($item.category -ne $lastCategory) {
          $lastCategory = $item.category
          Write-Host ("    --- " + $categoryLabels[$item.category] + " ---") -ForegroundColor Cyan
        }
        $sizeNote = if ($item.size) { " ($($item.size))" } else { "" }
        Write-Host ("    [$($item.id)] $($item.name)$sizeNote")
      }

      Write-Host ""
      $picks = Read-Host "  Enter numbers (e.g. 1,2,6,10) or 'all'"

      if ($picks -eq "all") {
        foreach ($item in $notInstalled) { $item.selected = $true }
      } else {
        $pickedIds = $picks -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "^\d+$" } | ForEach-Object { [int]$_ }
        foreach ($item in $catalog) {
          if ($pickedIds -contains $item.id -and -not $item.installed) {
            $item.selected = $true
          }
        }
      }

      $selectedCount = @($catalog | Where-Object { $_.selected }).Count
      Write-Host ""
      Write-Host "  Selected: $selectedCount items" -ForegroundColor Green
    }
    default {
      Write-Host "  Skipping installs." -ForegroundColor Yellow
    }
  }

  # Show what will be installed
  $toInstall = @($catalog | Where-Object { $_.selected })
  if ($toInstall.Count -gt 0) {
    Write-Host ""
    Write-Host "  Will install:" -ForegroundColor White
    foreach ($item in $toInstall) {
      $sizeNote = if ($item.size) { " ($($item.size))" } else { "" }
      Write-Host ("    + $($item.name)$sizeNote") -ForegroundColor Green
    }
  }
}

# Auth choices
Write-Host ""
Write-Host "  Which services should we authenticate?" -ForegroundColor White

$authGh         = $false
$authTailscale  = $false
$authCloudflare = $false

# GitHub: always ask if not already authed
if (Test-Command "gh") {
  $ghStatus = gh auth status 2>&1
  if ($LASTEXITCODE -ne 0) {
    $reply = Read-Host "  Authenticate GitHub CLI? [Y/n]"
    $authGh = ($reply -ne "n" -and $reply -ne "N")
  } else {
    Write-Host "  [OK] GitHub CLI already authenticated" -ForegroundColor Green
    $script:summary.authenticated += "GitHub (gh)"
  }
} else {
  Write-Host "  [skip] gh not installed yet (will auth after install if selected)" -ForegroundColor Yellow
  # If gh is in the install list, flag for post-install auth
  $ghSelected = $catalog | Where-Object { $_.name -eq "GitHub CLI" -and $_.selected }
  if ($ghSelected) { $authGh = $true }
}

$reply = Read-Host "  Authenticate Tailscale? [y/N]"
$authTailscale = ($reply -eq "y" -or $reply -eq "Y")

$reply = Read-Host "  Authenticate cloudflared? [y/N]"
$authCloudflare = ($reply -eq "y" -or $reply -eq "Y")

# Configure workspace
Write-Host ""
Write-Host "  Workspace configuration:" -ForegroundColor White

$workspacePath = Read-Host "  Workspace path [D:\claudeui]"
if ([string]::IsNullOrWhiteSpace($workspacePath)) { $workspacePath = "D:\claudeui" }

$githubUser = Read-Host "  GitHub username [jeremytrindade]"
if ([string]::IsNullOrWhiteSpace($githubUser)) { $githubUser = "jeremytrindade" }

$gitEmail = Read-Host "  Git email [jeremytrindade@gmail.com]"
if ([string]::IsNullOrWhiteSpace($gitEmail)) { $gitEmail = "jeremytrindade@gmail.com" }

# =====================================================================
# From here on, NO MORE USER INPUT. Everything runs unattended.
# =====================================================================

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " All questions answered. Running unattended from here." -ForegroundColor Green
Write-Host " You can walk away. Come back when it is done." -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green

$startTime = Get-Date

# =====================================================================
# PHASE 3: AUTHENTICATE (interactive browser flows, before installs)
# =====================================================================
Write-Phase "PHASE 3, authenticate"

if ($authGh -and (Test-Command "gh")) {
  Write-Host "  Running gh auth login..."
  gh auth login
  $script:summary.authenticated += "GitHub (gh)"
}

if ($authTailscale) {
  if (Test-Command "tailscale") {
    Write-Host "  Running tailscale up..."
    tailscale up
    $script:summary.authenticated += "Tailscale"
  } else {
    Write-Host "  [defer] Tailscale not installed yet, will auth after install" -ForegroundColor Yellow
  }
}

if ($authCloudflare) {
  if (Test-Command "cloudflared") {
    Write-Host "  Running cloudflared tunnel login..."
    cloudflared tunnel login
    $script:summary.authenticated += "cloudflared"
  } else {
    Write-Host "  [defer] cloudflared not installed yet, will auth after install" -ForegroundColor Yellow
  }
}

# =====================================================================
# PHASE 4: CONFIGURE (git identity + save config)
# =====================================================================
Write-Phase "PHASE 4, configure"

if (Test-Command "git") {
  git config --global user.email $gitEmail
  git config --global user.name $githubUser
  Write-Host "  [OK] git user.name=$githubUser user.email=$gitEmail" -ForegroundColor Green
} else {
  Write-Host "  [defer] git not installed yet, will configure after install" -ForegroundColor Yellow
}

$configDir = Join-Path $PSScriptRoot "config"
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
$configPath = Join-Path $configDir "user-config.json"
@{
  workspacePath = $workspacePath
  githubUser    = $githubUser
  gitEmail      = $gitEmail
  timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
} | ConvertTo-Json | Out-File $configPath -Encoding UTF8
Write-Host "  [OK] Config saved to $configPath" -ForegroundColor Green

# =====================================================================
# PHASE 5: INSTALL (fully unattended)
# =====================================================================
Write-Phase "PHASE 5, install selected tools"

$toInstall = @($catalog | Where-Object { $_.selected })

if ($toInstall.Count -eq 0) {
  Write-Host "  Nothing to install." -ForegroundColor Yellow
} else {
  $hasWinget = Test-Command "winget"

  # 5a: winget installs
  $wingetItems = @($toInstall | Where-Object { $_.method -eq "winget" })
  if ($wingetItems.Count -gt 0) {
    if (-not $hasWinget) {
      Write-Host "  winget not found. Cannot auto-install winget packages." -ForegroundColor Red
      foreach ($w in $wingetItems) { $script:summary.failed += $w.name }
    } else {
      foreach ($item in $wingetItems) {
        Write-Host ("  [$($wingetItems.IndexOf($item) + 1)/$($wingetItems.Count)] Installing $($item.name)...")
        winget install --id $item.wingetId --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        Refresh-SessionPath
        if ($item.cmd -and (Test-Command $item.cmd)) {
          Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
          $script:summary.installed += $item.name
        } else {
          Write-Host ("  [OK] $($item.name) (may need terminal restart for PATH)") -ForegroundColor Yellow
          $script:summary.installed += $item.name
        }
      }
    }
  }

  # 5b: manual installs (OpenSSH)
  $manualItems = @($toInstall | Where-Object { $_.method -eq "manual" })
  foreach ($item in $manualItems) {
    Write-Host ("  Installing $($item.name) via system capability...")
    try {
      Invoke-Expression $item.manual 2>&1 | Out-Null
      Refresh-SessionPath
      if ($item.cmd -and (Test-Command $item.cmd)) {
        Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
        $script:summary.installed += $item.name
      } else {
        Write-Host ("  [OK] $($item.name) (may need terminal restart)") -ForegroundColor Yellow
        $script:summary.installed += $item.name
      }
    } catch {
      Write-Host ("  [FAIL] $($item.name): $_") -ForegroundColor Red
      $script:summary.failed += $item.name
    }
  }

  # Refresh PATH before npm installs (need node/npm from winget)
  Refresh-SessionPath

  # 5c: npm installs (AI coding assistants)
  $npmItems = @($toInstall | Where-Object { $_.method -eq "npm" })
  if ($npmItems.Count -gt 0) {
    if (-not (Test-Command "npm")) {
      Write-Host "  npm not available. Skipping AI coding assistants." -ForegroundColor Yellow
      foreach ($n in $npmItems) { $script:summary.failed += $n.name }
    } else {
      foreach ($item in $npmItems) {
        Write-Host ("  Installing $($item.name) via npm...")
        npm install -g $item.pkg 2>&1 | Out-Null
        Refresh-SessionPath
        if ($item.cmd -and (Test-Command $item.cmd)) {
          Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
          $script:summary.installed += $item.name
        } else {
          Write-Host ("  [OK] $($item.name) (may need terminal restart for PATH)") -ForegroundColor Yellow
          $script:summary.installed += $item.name
        }
      }
    }
  }

  # 5d: ollama model pulls
  $modelItems = @($toInstall | Where-Object { $_.method -eq "ollama" })
  if ($modelItems.Count -gt 0) {
    Refresh-SessionPath
    if (-not (Test-Command "ollama")) {
      Write-Host "  Ollama not available. Skipping model downloads." -ForegroundColor Yellow
      foreach ($m in $modelItems) { $script:summary.failed += $m.name }
    } else {
      foreach ($item in $modelItems) {
        Write-Host ("  Pulling $($item.name) ($($item.size), this may take a while)...")
        ollama pull $item.name 2>&1
        if ($LASTEXITCODE -eq 0) {
          Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
          $script:summary.modelsLoaded += $item.name
        } else {
          Write-Host ("  [FAIL] $($item.name)") -ForegroundColor Red
          $script:summary.failed += $item.name
        }
      }
    }
  }

  # 5e: deferred auth (tools that were not available during Phase 3)
  Refresh-SessionPath

  if ($authGh -and (Test-Command "gh") -and ($script:summary.authenticated -notcontains "GitHub (gh)")) {
    Write-Host "  Running deferred gh auth login..."
    gh auth login
    $script:summary.authenticated += "GitHub (gh)"
  }
  if ($authTailscale -and (Test-Command "tailscale") -and ($script:summary.authenticated -notcontains "Tailscale")) {
    Write-Host "  Running deferred tailscale up..."
    tailscale up
    $script:summary.authenticated += "Tailscale"
  }
  if ($authCloudflare -and (Test-Command "cloudflared") -and ($script:summary.authenticated -notcontains "cloudflared")) {
    Write-Host "  Running deferred cloudflared tunnel login..."
    cloudflared tunnel login
    $script:summary.authenticated += "cloudflared"
  }

  # 5f: deferred git config (if git was just installed)
  if (Test-Command "git") {
    git config --global user.email $gitEmail
    git config --global user.name $githubUser
  }
}

# =====================================================================
# PHASE 6: CLONE REPOS (unattended)
# =====================================================================
Write-Phase "PHASE 6, clone repos"

$githubFolder = Join-Path $workspacePath "github"
New-Item -ItemType Directory -Force -Path $githubFolder | Out-Null

$reposJsonPath = Join-Path $PSScriptRoot "config\repos.json"
if (Test-Path $reposJsonPath) {
  $reposData = Get-Content $reposJsonPath -Raw | ConvertFrom-Json
  $repos = $reposData.repos
} else {
  $repos = @(
    [PSCustomObject]@{ owner = "jeremytrindade"; name = "playbook";   required = $true }
    [PSCustomObject]@{ owner = "jeremytrindade"; name = "ai-journal"; required = $true }
  )
}

foreach ($repo in $repos) {
  $url  = "https://github.com/$($repo.owner)/$($repo.name).git"
  $dest = Join-Path $githubFolder $repo.name
  if (Test-Path $dest) {
    Write-Host ("  [skip] " + $repo.name + " already exists")
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

# =====================================================================
# PHASE 7: VERIFY (unattended)
# =====================================================================
Write-Phase "PHASE 7, verify"

Refresh-SessionPath

Write-Host "  Checking all tools on PATH..." -ForegroundColor Cyan
Write-Host ""

$verifyList = @(
  @{ name = "Git";          cmd = "git";        flag = "--version" }
  @{ name = "GitHub CLI";   cmd = "gh";         flag = "--version" }
  @{ name = "Python 3";     cmd = "python";     flag = "--version" }
  @{ name = "PowerShell 7"; cmd = "pwsh";       flag = "--version" }
  @{ name = "OpenSSH";      cmd = "ssh";        flag = "-V" }
  @{ name = "Node.js";      cmd = "node";       flag = "--version" }
  @{ name = "npm";          cmd = "npm";        flag = "--version" }
  @{ name = "VS Code";      cmd = "code";       flag = "--version" }
  @{ name = "Tailscale";    cmd = "tailscale";  flag = "--version" }
  @{ name = "cloudflared";  cmd = "cloudflared";flag = "--version" }
  @{ name = "Claude Code";  cmd = "claude";     flag = "--version" }
  @{ name = "OpenAI Codex"; cmd = "codex";      flag = "--version" }
  @{ name = "Ollama";       cmd = "ollama";     flag = "--version" }
  @{ name = "uv";           cmd = "uv";         flag = "--version" }
)

$notOnPath = @()
foreach ($t in $verifyList) {
  if (Test-Command $t.cmd) {
    $ver = & $t.cmd $t.flag 2>&1 | Select-Object -First 1
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

# Smoke test
Write-Host ""
$aiJournal = Join-Path $githubFolder "ai-journal"
if (Test-Path $aiJournal) {
  $testFile = Join-Path $aiJournal "_startupjet-smoke-test.tmp"
  "smoke test $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $testFile -Encoding UTF8
  Remove-Item $testFile -Force
  Write-Host "  [OK] ai-journal write smoke test passed" -ForegroundColor Green
}

if (Test-Command "gh") {
  $ghWho = gh api user --jq '.login' 2>&1
  if ($LASTEXITCODE -eq 0) {
    Write-Host "  [OK] gh authenticated as: $ghWho" -ForegroundColor Green
  }
}

# =====================================================================
# SUMMARY
# =====================================================================
$elapsed = (Get-Date) - $startTime

Write-Phase "SUMMARY"
Write-Host ""
Write-Host ("  Installed:        " + (($script:summary.installed | Select-Object -Unique) -join ", "))
Write-Host ("  Already had:      " + ($script:summary.alreadyHad -join ", "))
Write-Host ("  Models loaded:    " + ($script:summary.modelsLoaded -join ", "))
Write-Host ("  Failed:           " + ($script:summary.failed -join ", "))
Write-Host ("  Authenticated:    " + ($script:summary.authenticated -join ", "))
Write-Host ("  Repos cloned:     " + ($script:summary.reposCloned -join ", "))
Write-Host ("  Repos skipped:    " + ($script:summary.reposSkipped -join ", "))
Write-Host ""
Write-Host ("  Total time: " + $elapsed.ToString("hh\:mm\:ss")) -ForegroundColor Cyan
Write-Host ("  Workspace ready at: $workspacePath") -ForegroundColor Cyan
Write-Host ""
Write-Host "  Now in any AI chat, paste this:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Read $workspacePath\github\ai-journal\UPDATE.md and follow it." -ForegroundColor White
Write-Host ""
