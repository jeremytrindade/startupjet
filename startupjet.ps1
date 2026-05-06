# startupjet.ps1, fresh-PC bootstrap orchestrator
# Author: Jeremy Trindade. License: MIT.
#
# Usage:
#   startupjet.bat              Normal install (scan, choose, auth, install, clone, verify)
#   startupjet.bat -Update      Upgrade all installed tools to latest versions
#
# Flow: detect -> choose (all questions upfront) -> authenticate -> configure
#       -> install (unattended) -> clone (unattended) -> verify -> summary

param([switch]$Update)

$ErrorActionPreference = "Continue"
$startTime = Get-Date

# === Log file ===
$logFile = Join-Path $PSScriptRoot "startupjet-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
Start-Transcript -Path $logFile -Append | Out-Null
Write-Host "  Log: $logFile" -ForegroundColor DarkGray

$script:summary = @{
  installed     = @()
  alreadyHad    = @()
  failed        = @()
  skipped       = @()
  authenticated = @()
  reposCloned   = @()
  reposSkipped  = @()
  modelsLoaded  = @()
  upgraded      = @()
  extensions    = @()
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

# === Resume support ===
$progressPath = Join-Path $PSScriptRoot "config\progress.json"
$script:progress = @{ completed = @() }

if (-not $Update -and (Test-Path $progressPath)) {
  try {
    $saved = Get-Content $progressPath -Raw | ConvertFrom-Json
    $script:progress.completed = @($saved.completed)
    Write-Host ""
    Write-Host "  Resuming previous run ($($script:progress.completed.Count) items already completed)" -ForegroundColor Cyan
  } catch {}
}

function Save-Progress($itemName) {
  if ($script:progress.completed -notcontains $itemName) {
    $script:progress.completed += $itemName
  }
  $dir = Join-Path $PSScriptRoot "config"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  @{ completed = $script:progress.completed; lastUpdate = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") } |
    ConvertTo-Json | Out-File $progressPath -Encoding UTF8
}

# =====================================================================
# PHASE 1: DETECT (silent scan)
# =====================================================================
Write-Phase "PHASE 1, scanning your system"

if (-not $Update) {
  # --- Hardware check ---
  Write-Host "  Hardware:" -ForegroundColor White

  $ramBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
  $ramGB = [math]::Round($ramBytes / 1GB, 1)
  $ramOk = $ramGB -ge 16
  $ramColor = if ($ramOk) { "Green" } else { "Yellow" }
  Write-Host ("  RAM:       $ramGB GB" + $(if ($ramOk) { "" } else { " (16 GB recommended for local AI)" })) -ForegroundColor $ramColor

  # GPU detection (nvidia-smi first for accurate VRAM, WMI fallback)
  $gpuName  = "none detected"
  $vramGB   = 0
  $gpuBrand = "unknown"

  $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
  if ($nvidiaSmi) {
    $gpuBrand = "nvidia"
    try {
      $nvsmiOut = nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>&1
      if ($LASTEXITCODE -eq 0 -and $nvsmiOut) {
        $parts = ($nvsmiOut -split ",") | ForEach-Object { $_.Trim() }
        $gpuName = $parts[0]
        if ($parts[1] -match "(\d+)") {
          $vramGB = [math]::Round([int]$Matches[1] / 1024, 1)
        }
      }
    } catch {}
  }

  if ($gpuName -eq "none detected") {
    $gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterRAM -gt 0 })
    if ($gpus.Count -gt 0) {
      $bestGpu = $gpus | Sort-Object AdapterRAM -Descending | Select-Object -First 1
      $gpuName = $bestGpu.Name
      $wmiVram = [math]::Round($bestGpu.AdapterRAM / 1GB, 1)
      if ($wmiVram -gt 0) { $vramGB = $wmiVram }
      if ($gpuName -match "NVIDIA") { $gpuBrand = "nvidia" }
      elseif ($gpuName -match "AMD|Radeon") { $gpuBrand = "amd" }
      elseif ($gpuName -match "Intel") { $gpuBrand = "intel" }
    }
  }

  $gpuOk = $vramGB -ge 6
  $gpuColor = if ($gpuOk) { "Green" } elseif ($vramGB -gt 0) { "Yellow" } else { "Red" }
  $vramNote = if ($vramGB -gt 0) { "$vramGB GB VRAM" } else { "VRAM unknown" }
  Write-Host ("  GPU:       $gpuName ($vramNote)") -ForegroundColor $gpuColor

  $targetDrive = "C"
  if (Test-Path "D:\") { $targetDrive = "D" }
  $driveInfo = Get-PSDrive $targetDrive -ErrorAction SilentlyContinue
  $freeGB = 0
  if ($driveInfo) { $freeGB = [math]::Round($driveInfo.Free / 1GB, 1) }
  $diskOk = $freeGB -ge 20
  $diskColor = if ($diskOk) { "Green" } else { "Yellow" }
  Write-Host ("  Disk free: $freeGB GB on $($targetDrive):") -ForegroundColor $diskColor

  # Local AI verdict
  Write-Host ""
  $script:localAiCapable = $false
  $script:localAiWarnings = @()

  if ($vramGB -ge 8) {
    Write-Host "  Local AI verdict: READY (GPU has $vramGB GB VRAM, 7B models will run well)" -ForegroundColor Green
    $script:localAiCapable = $true
  } elseif ($vramGB -ge 6) {
    Write-Host "  Local AI verdict: POSSIBLE (GPU has $vramGB GB VRAM, 7B models may be tight)" -ForegroundColor Yellow
    $script:localAiCapable = $true
    $script:localAiWarnings += "VRAM is on the low side for 7B models, expect slower inference"
  } elseif ($vramGB -gt 0) {
    Write-Host "  Local AI verdict: NOT RECOMMENDED ($vramGB GB VRAM is below the 6 GB minimum for 7B models)" -ForegroundColor Red
    $script:localAiWarnings += "GPU VRAM too low for 7B parameter models"
  } else {
    Write-Host "  Local AI verdict: NO DEDICATED GPU DETECTED (local AI models need a GPU with 6+ GB VRAM)" -ForegroundColor Red
    $script:localAiWarnings += "No dedicated GPU detected"
  }

  if ($ramGB -lt 16) { $script:localAiWarnings += "RAM below 16 GB recommended minimum" }
  if ($freeGB -lt 20) { $script:localAiWarnings += "Less than 20 GB free disk (models need ~15 GB)" }
  if ($gpuBrand -eq "amd") { $script:localAiWarnings += "AMD GPU: Ollama ROCm support is partial, may need extra setup" }
  if ($gpuBrand -eq "intel") { $script:localAiWarnings += "Intel GPU: Ollama support is experimental" }

  if ($script:localAiWarnings.Count -gt 0 -and $script:localAiCapable) {
    foreach ($w in $script:localAiWarnings) {
      Write-Host ("    Warning: $w") -ForegroundColor Yellow
    }
  }

  Write-Host ""

  # --- Internet speed test ---
  Write-Host "  Network:" -ForegroundColor White
  $script:downloadMBps = 0

  try {
    $speedTestUrl = "https://speed.cloudflare.com/__down?bytes=5000000"
    $tempFile = Join-Path $env:TEMP "startupjet-speedtest.bin"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-WebRequest -Uri $speedTestUrl -OutFile $tempFile -UseBasicParsing -ErrorAction Stop | Out-Null
    $sw.Stop()
    $fileSizeBytes = (Get-Item $tempFile).Length
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    $elapsedSec = $sw.Elapsed.TotalSeconds
    if ($elapsedSec -gt 0 -and $fileSizeBytes -gt 0) {
      $script:downloadMBps = [math]::Round(($fileSizeBytes / 1MB) / $elapsedSec, 1)
      $mbps = [math]::Round(($fileSizeBytes * 8 / 1MB) / $elapsedSec, 0)
      Write-Host "  Speed:     $script:downloadMBps MB/s ($mbps Mbps)" -ForegroundColor Green
    }
  } catch {
    Write-Host "  Speed:     could not test (offline or blocked)" -ForegroundColor Yellow
    $script:downloadMBps = 5
  }

  if ($script:downloadMBps -lt 2) {
    Write-Host "    Warning: slow connection. Large downloads (AI models) will take a long time." -ForegroundColor Yellow
  }

  Write-Host ""
} else {
  $script:localAiCapable = $true
  $script:localAiWarnings = @()
  $script:downloadMBps = 0
  Write-Host "  (update mode, skipping hardware and speed test)" -ForegroundColor DarkGray
  Write-Host ""
}

# --- Software catalog ---
$catalog = @(
  @{ id = 1;  name = "Git";            cmd = "git";        category = "dev";      method = "winget"; wingetId = "Git.Git";                   installed = $false; selected = $false; downloadMB = 55;   installMin = 1 }
  @{ id = 2;  name = "GitHub CLI";     cmd = "gh";         category = "dev";      method = "winget"; wingetId = "GitHub.cli";                 installed = $false; selected = $false; downloadMB = 15;   installMin = 0.5 }
  @{ id = 3;  name = "Python 3";       cmd = "python";     category = "dev";      method = "winget"; wingetId = "Python.Python.3.12";         installed = $false; selected = $false; downloadMB = 30;   installMin = 1 }
  @{ id = 4;  name = "PowerShell 7";   cmd = "pwsh";       category = "dev";      method = "winget"; wingetId = "Microsoft.PowerShell";       installed = $false; selected = $false; downloadMB = 100;  installMin = 1.5 }
  @{ id = 5;  name = "OpenSSH";        cmd = "ssh";        category = "dev";      method = "manual"; manual = "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"; installed = $false; selected = $false; downloadMB = 5; installMin = 0.5 }
  @{ id = 6;  name = "Node.js";        cmd = "node";       category = "dev";      method = "winget"; wingetId = "OpenJS.NodeJS";              installed = $false; selected = $false; downloadMB = 30;   installMin = 1 }
  @{ id = 7;  name = "VS Code";        cmd = "code";       category = "dev";      method = "winget"; wingetId = "Microsoft.VisualStudioCode"; installed = $false; selected = $false; downloadMB = 95;   installMin = 1.5 }
  @{ id = 8;  name = "Tailscale";      cmd = "tailscale";  category = "network";  method = "winget"; wingetId = "tailscale.tailscale";        installed = $false; selected = $false; downloadMB = 40;   installMin = 1 }
  @{ id = 9;  name = "cloudflared";    cmd = "cloudflared"; category = "network"; method = "winget"; wingetId = "Cloudflare.cloudflared";     installed = $false; selected = $false; downloadMB = 25;   installMin = 0.5 }
  @{ id = 10; name = "Claude Code";    cmd = "claude";     category = "ai";       method = "npm";    pkg = "@anthropic-ai/claude-code";       installed = $false; selected = $false; downloadMB = 50;   installMin = 1 }
  @{ id = 11; name = "OpenAI Codex";   cmd = "codex";      category = "ai";       method = "npm";    pkg = "@openai/codex";                   installed = $false; selected = $false; downloadMB = 30;   installMin = 1 }
  @{ id = 12; name = "Ollama";         cmd = "ollama";     category = "local-ai"; method = "winget"; wingetId = "Ollama.Ollama";              installed = $false; selected = $false; downloadMB = 110;  installMin = 1 }
  @{ id = 13; name = "uv";             cmd = "uv";         category = "local-ai"; method = "winget"; wingetId = "astral-sh.uv";               installed = $false; selected = $false; downloadMB = 15;   installMin = 0.5 }
  @{ id = 14; name = "llama3.1:8b";    cmd = $null;        category = "model";    method = "ollama"; size = "4.9 GB";                         installed = $false; selected = $false; downloadMB = 4900; installMin = 0 }
  @{ id = 15; name = "qwen2.5:7b";     cmd = $null;        category = "model";    method = "ollama"; size = "4.7 GB";                         installed = $false; selected = $false; downloadMB = 4700; installMin = 0 }
  @{ id = 16; name = "mistral:7b";     cmd = $null;        category = "model";    method = "ollama"; size = "4.1 GB";                         installed = $false; selected = $false; downloadMB = 4100; installMin = 0 }
  # Larger models (need 16+ GB VRAM)
  @{ id = 17; name = "gemma4:31b";        cmd = $null;     category = "model-lg"; method = "ollama"; size = "19 GB";                          installed = $false; selected = $false; downloadMB = 19000; installMin = 0 }
  @{ id = 18; name = "deepseek-r1:14b";   cmd = $null;     category = "model";    method = "ollama"; size = "9.0 GB";                         installed = $false; selected = $false; downloadMB = 9000;  installMin = 0 }
  # Cloud model (runs on Ollama cloud, no local GPU needed)
  @{ id = 19; name = "kimi-k2.6:cloud";   cmd = $null;     category = "model-cloud"; method = "ollama"; size = "cloud";                       installed = $false; selected = $false; downloadMB = 10;    installMin = 0 }
)

foreach ($item in $catalog) {
  if ($item.method -eq "ollama") {
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
# UPDATE MODE: upgrade installed tools and exit
# =====================================================================
if ($Update) {
  Write-Phase "UPDATE MODE, upgrading installed tools"
  Refresh-SessionPath

  if ($alreadyInstalled.Count -eq 0) {
    Write-Host "  Nothing to upgrade." -ForegroundColor Yellow
  } else {
    # winget upgrades
    $wingetUpgrades = @($alreadyInstalled | Where-Object { $_.method -eq "winget" })
    if ($wingetUpgrades.Count -gt 0 -and (Test-Command "winget")) {
      foreach ($item in $wingetUpgrades) {
        $idx = $wingetUpgrades.IndexOf($item) + 1
        Write-Host ("  [$idx/$($wingetUpgrades.Count)] Upgrading $($item.name)...")
        winget upgrade --id $item.wingetId --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
          Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
          $script:summary.upgraded += $item.name
        } else {
          Write-Host ("  [--] $($item.name) (already latest or not upgradeable)") -ForegroundColor Yellow
        }
      }
    }

    # npm upgrades
    $npmUpgrades = @($alreadyInstalled | Where-Object { $_.method -eq "npm" })
    if ($npmUpgrades.Count -gt 0 -and (Test-Command "npm")) {
      foreach ($item in $npmUpgrades) {
        Write-Host "  Upgrading $($item.name)..."
        npm update -g $item.pkg 2>&1 | Out-Null
        Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
        $script:summary.upgraded += $item.name
      }
    }

    # ollama model updates
    $modelUpgrades = @($alreadyInstalled | Where-Object { $_.method -eq "ollama" })
    if ($modelUpgrades.Count -gt 0 -and (Test-Command "ollama")) {
      foreach ($item in $modelUpgrades) {
        Write-Host "  Pulling latest $($item.name)..."
        ollama pull $item.name 2>&1
        if ($LASTEXITCODE -eq 0) {
          Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
          $script:summary.upgraded += $item.name
        }
      }
    }
  }

  Refresh-SessionPath

  Write-Phase "UPDATE SUMMARY"
  Write-Host ""
  if ($script:summary.upgraded.Count -gt 0) {
    Write-Host ("  Upgraded: " + ($script:summary.upgraded -join ", ")) -ForegroundColor Green
  } else {
    Write-Host "  Everything already up to date." -ForegroundColor Green
  }
  $elapsed = (Get-Date) - $startTime
  Write-Host ("  Time: " + $elapsed.ToString("hh\:mm\:ss")) -ForegroundColor Cyan
  Write-Host ("  Log:  $logFile") -ForegroundColor DarkGray
  Write-Host ""
  Stop-Transcript | Out-Null
  exit 0
}

# =====================================================================
# PHASE 2: CHOOSE (all questions upfront, then no more input until done)
# =====================================================================
Write-Phase "PHASE 2, choose what to install"

if ($notInstalled.Count -eq 0) {
  Write-Host "  Everything is already installed!" -ForegroundColor Green
} else {
  if (-not $script:localAiCapable) {
    Write-Host ""
    Write-Host "  Your hardware does NOT meet the requirements for local AI:" -ForegroundColor Red
    foreach ($w in $script:localAiWarnings) {
      Write-Host ("    - $w") -ForegroundColor Red
    }
    Write-Host "  Option [2] (skip local AI) is recommended for this PC." -ForegroundColor Yellow
    Write-Host ""
  } elseif ($script:localAiWarnings.Count -gt 0) {
    Write-Host ""
    Write-Host "  Your hardware can run local AI, with caveats:" -ForegroundColor Yellow
    foreach ($w in $script:localAiWarnings) {
      Write-Host ("    - $w") -ForegroundColor Yellow
    }
    Write-Host ""
  }

  $localAiCount = @($notInstalled | Where-Object { $_.category -eq "local-ai" -or $_.category -eq "model" -or $_.category -eq "model-lg" }).Count
  $nonLocalCount = $notInstalled.Count - $localAiCount

  Write-Host "  What would you like to install?" -ForegroundColor White
  Write-Host ""
  Write-Host "    [1] Install everything ($($notInstalled.Count) items)" -ForegroundColor $(if ($script:localAiCapable) { "Cyan" } else { "Yellow" })
  Write-Host "    [2] Install everything EXCEPT local AI + models ($nonLocalCount items)" -ForegroundColor Cyan
  Write-Host "    [3] Customize (pick from the list)" -ForegroundColor Cyan
  Write-Host "    [4] Skip installs (only authenticate + configure + clone)" -ForegroundColor Cyan

  if (-not $script:localAiCapable) {
    Write-Host ""
    Write-Host "    Note: option [1] includes local AI that your hardware may not support." -ForegroundColor Yellow
  }

  Write-Host ""
  $mode = Read-Host "  Choose [1/2/3/4]"

  switch ($mode) {
    "1" {
      if (-not $script:localAiCapable) {
        Write-Host ""
        Write-Host "  Warning: your hardware scan showed local AI may not work on this PC." -ForegroundColor Yellow
        $confirm = Read-Host "  Install local AI anyway? [y/N]"
        if ($confirm -eq "y" -or $confirm -eq "Y") {
          foreach ($item in $notInstalled) { $item.selected = $true }
          Write-Host "  Selected: everything ($($notInstalled.Count) items)" -ForegroundColor Green
        } else {
          foreach ($item in $notInstalled) {
            if ($item.category -ne "local-ai" -and $item.category -ne "model" -and $item.category -ne "model-lg") {
              $item.selected = $true
            }
          }
          $selectedCount = @($catalog | Where-Object { $_.selected }).Count
          Write-Host "  Selected: $selectedCount items (local AI skipped per your choice)" -ForegroundColor Green
        }
      } else {
        foreach ($item in $notInstalled) { $item.selected = $true }
        Write-Host "  Selected: everything ($($notInstalled.Count) items)" -ForegroundColor Green
      }
    }
    "2" {
      foreach ($item in $notInstalled) {
        if ($item.category -ne "local-ai" -and $item.category -ne "model" -and $item.category -ne "model-lg") {
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

      $localAiLabel = if ($script:localAiCapable) { "Local AI (GPU: $gpuName, $vramGB GB VRAM)" } else { "Local AI (GPU: NOT RECOMMENDED for this PC)" }
      $modelLabel   = if ($script:localAiCapable) { "AI models via Ollama (~13.7 GB total)" } else { "AI models via Ollama (NOT RECOMMENDED, see hardware scan)" }
      $modelLgLabel = if ($script:localAiCapable) { "Larger AI models (need 16+ GB VRAM)" } else { "Larger AI models (NOT RECOMMENDED, need 16+ GB VRAM)" }
      $categoryLabels = @{
        "dev"         = "Dev tools"
        "network"     = "Network"
        "ai"          = "AI coding assistants"
        "local-ai"    = $localAiLabel
        "model"       = $modelLabel
        "model-lg"    = $modelLgLabel
        "model-cloud" = "Cloud AI models (runs on Ollama cloud, no local GPU needed)"
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

  # Show what will be installed + time estimate
  $toInstall = @($catalog | Where-Object { $_.selected })
  if ($toInstall.Count -gt 0) {
    Write-Host ""
    Write-Host "  Will install:" -ForegroundColor White
    foreach ($item in $toInstall) {
      $sizeNote = if ($item.size) { " ($($item.size))" } else { "" }
      Write-Host ("    + $($item.name)$sizeNote") -ForegroundColor Green
    }

    $totalDownloadMB = ($toInstall | ForEach-Object { $_.downloadMB } | Measure-Object -Sum).Sum
    $totalInstallMin = ($toInstall | ForEach-Object { $_.installMin } | Measure-Object -Sum).Sum

    if ($script:downloadMBps -gt 0) {
      $downloadMin = [math]::Ceiling($totalDownloadMB / $script:downloadMBps / 60)
      $totalMin = $downloadMin + [math]::Ceiling($totalInstallMin)
      $totalDownloadDisplay = if ($totalDownloadMB -ge 1024) {
        "$([math]::Round($totalDownloadMB / 1024, 1)) GB"
      } else {
        "$totalDownloadMB MB"
      }

      Write-Host ""
      Write-Host "  Estimated time:" -ForegroundColor Cyan
      Write-Host "    Total download: ~$totalDownloadDisplay" -ForegroundColor White
      Write-Host "    At your speed ($script:downloadMBps MB/s): ~$downloadMin min download + ~$([math]::Ceiling($totalInstallMin)) min install" -ForegroundColor White

      if ($totalMin -lt 5) {
        Write-Host "    Total: ~$totalMin minutes. Quick one." -ForegroundColor Green
      } elseif ($totalMin -lt 30) {
        Write-Host "    Total: ~$totalMin minutes. Grab a coffee." -ForegroundColor Cyan
      } elseif ($totalMin -lt 60) {
        Write-Host "    Total: ~$totalMin minutes. Go for a walk." -ForegroundColor Yellow
      } else {
        $hours = [math]::Round($totalMin / 60, 1)
        Write-Host "    Total: ~$hours hours. Do something else entirely." -ForegroundColor Yellow
      }
    }
  }
}

# --- Install scope ---
$script:installScope = "user"
$toInstall = @($catalog | Where-Object { $_.selected })
if ($toInstall.Count -gt 0) {
  Write-Host ""
  Write-Host "  Install scope:" -ForegroundColor White
  Write-Host "    [1] Current user only (no admin needed)" -ForegroundColor Cyan
  Write-Host "    [2] All users on this PC (may require admin)" -ForegroundColor Cyan
  Write-Host ""
  $scopeChoice = Read-Host "  Choose [1/2]"
  if ($scopeChoice -eq "2") {
    $script:installScope = "machine"
    Write-Host "  Scope: all users (machine-wide)" -ForegroundColor Green
  } else {
    Write-Host "  Scope: current user only" -ForegroundColor Green
  }
}

# --- Auth choices ---
Write-Host ""
Write-Host "  Which services should we authenticate?" -ForegroundColor White

$authGh         = $false
$authTailscale  = $false
$authCloudflare = $false

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
  $ghSelected = $catalog | Where-Object { $_.name -eq "GitHub CLI" -and $_.selected }
  if ($ghSelected) { $authGh = $true }
}

$reply = Read-Host "  Authenticate Tailscale? [y/N]"
$authTailscale = ($reply -eq "y" -or $reply -eq "Y")

$reply = Read-Host "  Authenticate cloudflared? [y/N]"
$authCloudflare = ($reply -eq "y" -or $reply -eq "Y")

# --- SSH key ---
$generateSshKey = $false
$sshKeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
if (-not (Test-Path $sshKeyPath)) {
  Write-Host ""
  $reply = Read-Host "  Generate SSH key for GitHub? [Y/n]"
  $generateSshKey = ($reply -ne "n" -and $reply -ne "N")
} else {
  Write-Host ""
  Write-Host "  [OK] SSH key already exists at $sshKeyPath" -ForegroundColor Green
}

# --- Windows dev settings ---
Write-Host ""
$applyDevSettings = $false
$reply = Read-Host "  Apply Windows dev settings? (file extensions, hidden files, dev mode) [Y/n]"
$applyDevSettings = ($reply -ne "n" -and $reply -ne "N")

# --- VS Code extensions ---
$installExtensions = $false
$extList = @()
$vscodeAvailable = (Test-Command "code") -or ($catalog | Where-Object { $_.name -eq "VS Code" -and $_.selected })
if ($vscodeAvailable) {
  $extConfigPath = Join-Path $PSScriptRoot "config\vscode-extensions.json"
  if (Test-Path $extConfigPath) {
    try {
      $extData = Get-Content $extConfigPath -Raw | ConvertFrom-Json
      $extList = @($extData.extensions)
      if ($extList.Count -gt 0) {
        Write-Host ""
        $reply = Read-Host "  Install $($extList.Count) VS Code extensions? [Y/n]"
        $installExtensions = ($reply -ne "n" -and $reply -ne "N")
        if ($installExtensions) {
          Write-Host "  Extensions: $($extList -join ', ')" -ForegroundColor DarkGray
        }
      }
    } catch {}
  }
}

# --- Workspace configuration ---
Write-Host ""
Write-Host "  Workspace configuration:" -ForegroundColor White

# Load defaults from config/defaults.json if available
$defaultWorkspace = "D:\claudeui"
$defaultGithubUser = "jeremytrindade"
$defaultGitEmail = "jeremytrindade@gmail.com"
$defaultsPath = Join-Path $PSScriptRoot "config\defaults.json"
if (Test-Path $defaultsPath) {
  try {
    $defaults = Get-Content $defaultsPath -Raw | ConvertFrom-Json
    if ($defaults.workspacePath) { $defaultWorkspace = $defaults.workspacePath }
    if ($defaults.githubUser)    { $defaultGithubUser = $defaults.githubUser }
    if ($defaults.gitEmail)      { $defaultGitEmail = $defaults.gitEmail }
  } catch {}
}

$workspacePath = Read-Host "  Workspace path [$defaultWorkspace]"
if ([string]::IsNullOrWhiteSpace($workspacePath)) { $workspacePath = $defaultWorkspace }

$githubUser = Read-Host "  GitHub username [$defaultGithubUser]"
if ([string]::IsNullOrWhiteSpace($githubUser)) { $githubUser = $defaultGithubUser }

$gitEmail = Read-Host "  Git email [$defaultGitEmail]"
if ([string]::IsNullOrWhiteSpace($gitEmail)) { $gitEmail = $defaultGitEmail }

# =====================================================================
# From here on, NO MORE USER INPUT. Everything runs unattended.
# =====================================================================

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host " All questions answered. Running unattended from here." -ForegroundColor Green
Write-Host " You can walk away. Come back when it is done." -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green

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
# PHASE 4: CONFIGURE (git identity, SSH key, dev settings, save config)
# =====================================================================
Write-Phase "PHASE 4, configure"

# Git identity
if (Test-Command "git") {
  $gitScope = if ($script:installScope -eq "machine") { "--system" } else { "--global" }
  git config $gitScope user.email $gitEmail
  git config $gitScope user.name $githubUser
  Write-Host "  [OK] git user.name=$githubUser user.email=$gitEmail ($gitScope)" -ForegroundColor Green
} else {
  Write-Host "  [defer] git not installed yet, will configure after install" -ForegroundColor Yellow
}

# SSH key generation
if ($generateSshKey) {
  $sshDir = Join-Path $env:USERPROFILE ".ssh"
  if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
  }
  Write-Host "  Generating SSH key (ed25519)..."
  ssh-keygen -t ed25519 -C $gitEmail -f $sshKeyPath -N '""' -q 2>&1 | Out-Null
  if (Test-Path $sshKeyPath) {
    Write-Host "  [OK] SSH key: $sshKeyPath" -ForegroundColor Green
    # Add to GitHub if gh is authenticated
    if (Test-Command "gh") {
      $ghCheck = gh auth status 2>&1
      if ($LASTEXITCODE -eq 0) {
        $keyTitle = "startupjet $(hostname) $(Get-Date -Format 'yyyy-MM-dd')"
        gh ssh-key add "$sshKeyPath.pub" --title $keyTitle 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
          Write-Host "  [OK] SSH key added to GitHub ($keyTitle)" -ForegroundColor Green
        } else {
          Write-Host "  [--] Could not add SSH key to GitHub (will retry after auth)" -ForegroundColor Yellow
        }
      }
    }
  } else {
    Write-Host "  [FAIL] SSH key generation failed" -ForegroundColor Red
  }
}

# Windows dev settings
if ($applyDevSettings) {
  Write-Host ""
  Write-Host "  Applying Windows dev settings..."
  try {
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0 -ErrorAction Stop
    Write-Host "  [OK] Show file extensions" -ForegroundColor Green
  } catch {
    Write-Host "  [FAIL] Show file extensions: $_" -ForegroundColor Red
  }
  try {
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Hidden" -Value 1 -ErrorAction Stop
    Write-Host "  [OK] Show hidden files" -ForegroundColor Green
  } catch {
    Write-Host "  [FAIL] Show hidden files: $_" -ForegroundColor Red
  }
  try {
    reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  [OK] Developer Mode enabled" -ForegroundColor Green
    } else {
      Write-Host "  [--] Developer Mode requires admin (run as Administrator to enable)" -ForegroundColor Yellow
    }
  } catch {
    Write-Host "  [--] Developer Mode requires admin (run as Administrator to enable)" -ForegroundColor Yellow
  }
}

# Save config
$configDir = Join-Path $PSScriptRoot "config"
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
$configPath = Join-Path $configDir "user-config.json"
@{
  workspacePath = $workspacePath
  githubUser    = $githubUser
  gitEmail      = $gitEmail
  installScope  = $script:installScope
  timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
} | ConvertTo-Json | Out-File $configPath -Encoding UTF8
Write-Host "  [OK] Config saved to $configPath" -ForegroundColor Green

# =====================================================================
# PHASE 5: INSTALL (fully unattended, with resume support)
# =====================================================================
Write-Phase "PHASE 5, install selected tools"

$toInstall = @($catalog | Where-Object { $_.selected })

if ($toInstall.Count -eq 0) {
  Write-Host "  Nothing to install." -ForegroundColor Yellow
} else {
  $hasWinget = Test-Command "winget"
  $wingetScope = "--scope $($script:installScope)"

  # 5a: winget installs
  $wingetItems = @($toInstall | Where-Object { $_.method -eq "winget" })
  if ($wingetItems.Count -gt 0) {
    if (-not $hasWinget) {
      Write-Host "  winget not found. Cannot auto-install winget packages." -ForegroundColor Red
      foreach ($w in $wingetItems) { $script:summary.failed += $w.name }
    } else {
      foreach ($item in $wingetItems) {
        if ($script:progress.completed -contains $item.name) {
          Write-Host ("  [skip] $($item.name) (completed in previous run)") -ForegroundColor DarkGray
          $script:summary.installed += $item.name
          continue
        }
        $idx = $wingetItems.IndexOf($item) + 1
        Write-Host ("  [$idx/$($wingetItems.Count)] Installing $($item.name)...")
        winget install --id $item.wingetId --silent --accept-source-agreements --accept-package-agreements --scope $script:installScope 2>&1 | Out-Null
        Refresh-SessionPath
        if ($item.cmd -and (Test-Command $item.cmd)) {
          Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
        } else {
          Write-Host ("  [OK] $($item.name) (may need terminal restart for PATH)") -ForegroundColor Yellow
        }
        $script:summary.installed += $item.name
        Save-Progress $item.name
      }
    }
  }

  # 5b: manual installs (OpenSSH)
  $manualItems = @($toInstall | Where-Object { $_.method -eq "manual" })
  foreach ($item in $manualItems) {
    if ($script:progress.completed -contains $item.name) {
      Write-Host ("  [skip] $($item.name) (completed in previous run)") -ForegroundColor DarkGray
      $script:summary.installed += $item.name
      continue
    }
    Write-Host ("  Installing $($item.name) via system capability...")
    try {
      Invoke-Expression $item.manual 2>&1 | Out-Null
      Refresh-SessionPath
      if ($item.cmd -and (Test-Command $item.cmd)) {
        Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
      } else {
        Write-Host ("  [OK] $($item.name) (may need terminal restart)") -ForegroundColor Yellow
      }
      $script:summary.installed += $item.name
      Save-Progress $item.name
    } catch {
      Write-Host ("  [FAIL] $($item.name): $_") -ForegroundColor Red
      $script:summary.failed += $item.name
    }
  }

  # Refresh PATH before npm installs
  Refresh-SessionPath

  # 5c: npm installs (AI coding assistants)
  $npmItems = @($toInstall | Where-Object { $_.method -eq "npm" })
  if ($npmItems.Count -gt 0) {
    if (-not (Test-Command "npm")) {
      Write-Host "  npm not available. Skipping AI coding assistants." -ForegroundColor Yellow
      foreach ($n in $npmItems) { $script:summary.failed += $n.name }
    } else {
      foreach ($item in $npmItems) {
        if ($script:progress.completed -contains $item.name) {
          Write-Host ("  [skip] $($item.name) (completed in previous run)") -ForegroundColor DarkGray
          $script:summary.installed += $item.name
          continue
        }
        Write-Host ("  Installing $($item.name) via npm...")
        npm install -g $item.pkg 2>&1 | Out-Null
        Refresh-SessionPath
        if ($item.cmd -and (Test-Command $item.cmd)) {
          Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
        } else {
          Write-Host ("  [OK] $($item.name) (may need terminal restart for PATH)") -ForegroundColor Yellow
        }
        $script:summary.installed += $item.name
        Save-Progress $item.name
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
        if ($script:progress.completed -contains $item.name) {
          Write-Host ("  [skip] $($item.name) (completed in previous run)") -ForegroundColor DarkGray
          $script:summary.modelsLoaded += $item.name
          continue
        }
        Write-Host ("  Pulling $($item.name) ($($item.size), this may take a while)...")
        ollama pull $item.name 2>&1
        if ($LASTEXITCODE -eq 0) {
          Write-Host ("  [OK] $($item.name)") -ForegroundColor Green
          $script:summary.modelsLoaded += $item.name
          Save-Progress $item.name
        } else {
          Write-Host ("  [FAIL] $($item.name)") -ForegroundColor Red
          $script:summary.failed += $item.name
        }
      }
    }
  }

  # 5e: deferred auth (tools installed above that need auth)
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
    $gitScope = if ($script:installScope -eq "machine") { "--system" } else { "--global" }
    git config $gitScope user.email $gitEmail
    git config $gitScope user.name $githubUser
  }

  # 5g: deferred SSH key add to GitHub
  if ($generateSshKey -and (Test-Path "$sshKeyPath.pub") -and (Test-Command "gh")) {
    $ghCheck = gh auth status 2>&1
    if ($LASTEXITCODE -eq 0) {
      $existingKeys = gh ssh-key list 2>&1
      $pubKeyContent = Get-Content "$sshKeyPath.pub" -Raw
      if ($existingKeys -notmatch [regex]::Escape(($pubKeyContent.Trim().Split(" ")[1]))) {
        $keyTitle = "startupjet $(hostname) $(Get-Date -Format 'yyyy-MM-dd')"
        gh ssh-key add "$sshKeyPath.pub" --title $keyTitle 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
          Write-Host "  [OK] SSH key added to GitHub" -ForegroundColor Green
        }
      }
    }
  }

  # 5h: VS Code extensions
  if ($installExtensions -and $extList.Count -gt 0) {
    Refresh-SessionPath
    if (Test-Command "code") {
      Write-Host ""
      Write-Host "  Installing VS Code extensions..." -ForegroundColor Cyan
      foreach ($ext in $extList) {
        Write-Host "  Installing $ext..."
        code --install-extension $ext --force 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
          Write-Host ("  [OK] $ext") -ForegroundColor Green
          $script:summary.extensions += $ext
        } else {
          Write-Host ("  [FAIL] $ext") -ForegroundColor Red
        }
      }
    } else {
      Write-Host "  VS Code not on PATH. Skipping extensions." -ForegroundColor Yellow
    }
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

# SSH key check
$sshPubPath = "$sshKeyPath.pub"
if (Test-Path $sshPubPath) {
  Write-Host ""
  Write-Host "  [OK] SSH key: $sshKeyPath" -ForegroundColor Green
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
Write-Host ("  Extensions:       " + ($script:summary.extensions -join ", "))
Write-Host ("  Failed:           " + ($script:summary.failed -join ", "))
Write-Host ("  Authenticated:    " + ($script:summary.authenticated -join ", "))
Write-Host ("  Repos cloned:     " + ($script:summary.reposCloned -join ", "))
Write-Host ("  Repos skipped:    " + ($script:summary.reposSkipped -join ", "))
Write-Host ("  Install scope:    $script:installScope")
Write-Host ""
Write-Host ("  Total time: " + $elapsed.ToString("hh\:mm\:ss")) -ForegroundColor Cyan
Write-Host ("  Workspace ready at: $workspacePath") -ForegroundColor Cyan
Write-Host ("  Log file: $logFile") -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Now in any AI chat, paste this:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Read $workspacePath\github\ai-journal\UPDATE.md and follow it." -ForegroundColor White
Write-Host ""

# Clean up progress file on successful run (no failures)
if ($script:summary.failed.Count -eq 0) {
  Remove-Item $progressPath -Force -ErrorAction SilentlyContinue
} else {
  Write-Host "  Some items failed. Re-run startupjet.bat to retry (progress saved)." -ForegroundColor Yellow
  Write-Host ""
}

Stop-Transcript | Out-Null
