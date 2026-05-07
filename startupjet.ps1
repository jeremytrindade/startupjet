# startupjet.ps1, fresh-PC bootstrap orchestrator
# Author: Jeremy Trindade. License: MIT.
#
# Usage:
#   startupjet.bat              Normal install (scan, choose, auth, install, clone, verify)
#   startupjet.bat -Update      Upgrade all installed tools to latest versions
#   startupjet.bat -DryRun      Show what would happen without doing anything
#
# Flow: detect -> choose (all questions upfront) -> authenticate -> configure
#       -> install (unattended) -> clone (unattended) -> verify -> summary

param([switch]$Update, [switch]$DryRun, [switch]$ShowVersion, [Alias("h")][switch]$Help)

$script:VERSION = "1.2"

if ($ShowVersion) {
  Write-Host "startupjet v$script:VERSION"
  exit 0
}

if ($Help) {
  Write-Host "startupjet v$script:VERSION - fresh-PC bootstrap for Windows"
  Write-Host ""
  Write-Host "Usage: startupjet.bat [-Update] [-DryRun] [-ShowVersion] [-Help]"
  Write-Host "  -Update       Upgrade all installed tools to latest"
  Write-Host "  -DryRun       Show what would happen without making changes"
  Write-Host "  -ShowVersion  Show version"
  Write-Host "  -Help      Show this help"
  exit 0
}

$ErrorActionPreference = "Continue"
$startTime = Get-Date

# === Admin check helper ===
function Test-IsAdmin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]$identity
  $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:isAdmin = Test-IsAdmin
$script:presetApplied = $false

# === Log file ===
$logFile = Join-Path $PSScriptRoot "startupjet-$(Get-Date -Format 'yyyy-MM-dd-HHmm').log"
Start-Transcript -Path $logFile -Append | Out-Null
Write-Host "  Log: $logFile" -ForegroundColor DarkGray

if ($DryRun) {
  Write-Host "  DRY RUN MODE: no changes will be made" -ForegroundColor Yellow
}

try {

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

function Get-RecommendedModels {
  param($models, [double]$vram, [double]$ram, [double]$diskFree)
  $scored = @()
  foreach ($m in $models) {
    if (-not $m.minVRAM -or $m.minVRAM -eq 0) { continue }
    if ($ram -lt $m.minRAM) { continue }
    if ($diskFree -lt ($m.downloadMB / 1024)) { continue }
    $score = $m.quality
    if ($vram -ge $m.recVRAM) { $score += 3 }
    elseif ($vram -ge $m.minVRAM) { $score += 1 }
    else { continue }
    $scored += [PSCustomObject]@{ model = $m; score = $score }
  }
  $scored | Sort-Object score -Descending | Select-Object -First 3 | ForEach-Object { $_.model }
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

      # WMI AdapterRAM is a DWORD, caps at 4 GB. Try registry for the real value.
      if ($vramGB -le 4.1) {
        try {
          $regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
          $subKeys = Get-ChildItem $regBase -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "\\\d{4}$" }
          foreach ($sk in $subKeys) {
            $desc = (Get-ItemProperty $sk.PSPath -ErrorAction SilentlyContinue).DriverDesc
            if ($desc -and $gpuName -match [regex]::Escape($desc.Substring(0, [math]::Min(10, $desc.Length)))) {
              $qwMem = (Get-ItemProperty $sk.PSPath -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
              if ($qwMem -and $qwMem -gt 0) {
                $regVram = [math]::Round([int64]$qwMem / 1GB, 1)
                if ($regVram -gt $vramGB) {
                  $vramGB = $regVram
                }
                break
              }
            }
          }
        } catch {}
      }
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
# Load catalog from config/catalog.json (single source of truth for all platforms)
$catalogJsonPath = Join-Path $PSScriptRoot "config\catalog.json"
$catalogData = Get-Content $catalogJsonPath -Raw | ConvertFrom-Json

$catalog = @()
foreach ($t in $catalogData.tools) {
  $winInst = $t.install.windows
  if (-not $winInst) { continue }
  $cmd = if ($t.cmdWindows) { $t.cmdWindows } else { $t.cmd }
  $entry = @{
    id         = [int]$t.id
    name       = $t.name
    cmd        = $cmd
    category   = $t.category
    method     = $winInst.method
    installed  = $false
    selected   = $false
    downloadMB = if ($t.downloadMB) { $t.downloadMB } else { 50 }
    installMin = if ($t.installMin) { $t.installMin } else { 1 }
  }
  if ($winInst.id)      { $entry.wingetId = $winInst.id }
  if ($winInst.package) { $entry.pkg = $winInst.package }
  if ($winInst.cmd)     { $entry.manual = $winInst.cmd }
  $catalog += $entry
}
foreach ($m in $catalogData.models) {
  $catalog += @{
    id         = [int]$m.id
    name       = $m.name
    cmd        = $null
    category   = if ($m.category) { $m.category } else { "model" }
    method     = "ollama"
    size       = $m.size
    installed  = $false
    selected   = $false
    downloadMB = if ($m.downloadMB) { $m.downloadMB } else { 5000 }
    installMin = 0
    minVRAM    = if ($m.minVRAM) { $m.minVRAM } else { 0 }
    recVRAM    = if ($m.recVRAM) { $m.recVRAM } else { 0 }
    minRAM     = if ($m.minRAM)  { $m.minRAM }  else { 0 }
    quality    = if ($m.quality) { $m.quality } else { 5 }
    desc       = if ($m.desc)    { $m.desc }    else { "" }
  }
}

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
  Write-Phase "UPDATE MODE"

  # Self-update startupjet if it is a git repo
  if (Test-Path (Join-Path $PSScriptRoot ".git")) {
    Write-Host "  Updating startupjet itself..." -ForegroundColor Cyan
    $prevDir = Get-Location
    Set-Location $PSScriptRoot
    $pullResult = git pull 2>&1
    Set-Location $prevDir
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  [OK] startupjet repo updated" -ForegroundColor Green
    } else {
      Write-Host "  [--] git pull failed (offline or conflicts)" -ForegroundColor Yellow
    }
    Write-Host ""
  }

  Write-Host "  Upgrading installed tools..." -ForegroundColor Cyan
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

  # Model recommendations based on hardware scan
  $script:recommendedModels = @()
  if ($script:localAiCapable) {
    $installedModels = @($catalog | Where-Object { $_.method -eq "ollama" -and $_.minVRAM -and $_.minVRAM -gt 0 -and $_.installed })
    if ($installedModels.Count -gt 0) {
      Write-Host ""
      $installedNames = ($installedModels | ForEach-Object { $_.name }) -join ", "
      Write-Host "  Already installed: $installedNames" -ForegroundColor Green
    }

    $modelCandidates = @($catalog | Where-Object { $_.method -eq "ollama" -and $_.minVRAM -and $_.minVRAM -gt 0 -and -not $_.installed })
    $script:recommendedModels = @(Get-RecommendedModels -models $modelCandidates -vram $vramGB -ram $ramGB -diskFree $freeGB)
    if ($script:recommendedModels.Count -gt 0) {
      Write-Host ""
      Write-Host "  Best models to add for your hardware ($vramGB GB VRAM, $ramGB GB RAM, $freeGB GB free):" -ForegroundColor Cyan
      $rank = 0
      foreach ($rm in $script:recommendedModels) {
        $rank++
        $fit = if ($vramGB -ge $rm.recVRAM) { "full GPU speed" } else { "runs with CPU offload" }
        Write-Host ("    $rank. $($rm.name) ($($rm.size)) [$fit]") -ForegroundColor Green
        Write-Host ("       $($rm.desc)") -ForegroundColor DarkGray
      }
      Write-Host ""
    } elseif ($modelCandidates.Count -eq 0 -and $installedModels.Count -gt 0) {
      Write-Host "  All compatible models are already installed." -ForegroundColor Green
      Write-Host ""
    }
  }

  # --- Preset profiles ---
  Write-Host "  Setup profile:" -ForegroundColor White
  Write-Host ""
  Write-Host "    [A] Minimal dev    (Git, gh, Python, Node, pwsh, OpenSSH)" -ForegroundColor Cyan
  Write-Host "    [B] Developer      (A + VS Code, Tailscale, cloudflared, dev settings)" -ForegroundColor Cyan
  Write-Host "    [C] Full setup     (B + Claude Code, OpenAI Codex, uv, all but local LLMs)" -ForegroundColor Cyan
  Write-Host "    [D] Full + Ollama  (C + Ollama installed, no models preloaded)" -ForegroundColor Cyan
  if ($script:localAiCapable) {
    Write-Host "    [E] AI workstation (D + recommended models auto-pulled)" -ForegroundColor Cyan
  }
  Write-Host "    [F] Custom         (choose everything yourself)" -ForegroundColor Cyan
  Write-Host ""
  $presetChoice = Read-Host "  Profile [A/B/C/D/E/F]"

  $presetCategories = @()
  switch ($presetChoice.ToUpper()) {
    "A" {
      $presetNames = @("Git", "GitHub CLI", "Python 3", "PowerShell 7", "OpenSSH", "Node.js")
      foreach ($item in $notInstalled) {
        if ($presetNames -contains $item.name) { $item.selected = $true }
      }
      $script:installScope = "user"
      $authGh = $true; $authTailscale = $false; $authCloudflare = $false
      $sshKeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
      $generateSshKey = -not (Test-Path $sshKeyPath)
      $applyDevSettings = $false
      $installExtensions = $false; $extList = @()
      $script:presetApplied = $true
      Write-Host "  Profile: Minimal dev" -ForegroundColor Green
    }
    "B" {
      $presetNames = @("Git", "GitHub CLI", "Python 3", "PowerShell 7", "OpenSSH", "Node.js", "VS Code", "Tailscale", "cloudflared")
      foreach ($item in $notInstalled) {
        if ($presetNames -contains $item.name) { $item.selected = $true }
      }
      $script:installScope = "user"
      $authGh = $true; $authTailscale = $true; $authCloudflare = $true
      $sshKeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
      $generateSshKey = -not (Test-Path $sshKeyPath)
      $applyDevSettings = $true
      $installExtensions = $false; $extList = @()
      $extConfigPath = Join-Path $PSScriptRoot "config\vscode-extensions.json"
      if (Test-Path $extConfigPath) {
        try { $extData = Get-Content $extConfigPath -Raw | ConvertFrom-Json; $extList = @($extData.extensions); $installExtensions = $extList.Count -gt 0 } catch {}
      }
      $script:presetApplied = $true
      Write-Host "  Profile: Developer" -ForegroundColor Green
    }
    "C" {
      $presetNames = @("Git", "GitHub CLI", "Python 3", "PowerShell 7", "OpenSSH", "Node.js", "VS Code", "Tailscale", "cloudflared", "Claude Code", "OpenAI Codex", "uv")
      foreach ($item in $notInstalled) {
        if ($presetNames -contains $item.name) { $item.selected = $true }
      }
      $script:installScope = "user"
      $authGh = $true; $authTailscale = $true; $authCloudflare = $true
      $sshKeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
      $generateSshKey = -not (Test-Path $sshKeyPath)
      $applyDevSettings = $true
      $installExtensions = $false; $extList = @()
      $extConfigPath = Join-Path $PSScriptRoot "config\vscode-extensions.json"
      if (Test-Path $extConfigPath) {
        try { $extData = Get-Content $extConfigPath -Raw | ConvertFrom-Json; $extList = @($extData.extensions); $installExtensions = $extList.Count -gt 0 } catch {}
      }
      $script:presetApplied = $true
      Write-Host "  Profile: Full setup" -ForegroundColor Green
    }
    "D" {
      $presetNames = @("Git", "GitHub CLI", "Python 3", "PowerShell 7", "OpenSSH", "Node.js", "VS Code", "Tailscale", "cloudflared", "Claude Code", "OpenAI Codex", "Ollama", "uv")
      foreach ($item in $notInstalled) {
        if ($presetNames -contains $item.name) { $item.selected = $true }
      }
      $script:installScope = "user"
      $authGh = $true; $authTailscale = $true; $authCloudflare = $true
      $sshKeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
      $generateSshKey = -not (Test-Path $sshKeyPath)
      $applyDevSettings = $true
      $installExtensions = $false; $extList = @()
      $extConfigPath = Join-Path $PSScriptRoot "config\vscode-extensions.json"
      if (Test-Path $extConfigPath) {
        try { $extData = Get-Content $extConfigPath -Raw | ConvertFrom-Json; $extList = @($extData.extensions); $installExtensions = $extList.Count -gt 0 } catch {}
      }
      $script:presetApplied = $true
      Write-Host "  Profile: Full + Ollama" -ForegroundColor Green
    }
    "E" {
      if (-not $script:localAiCapable) {
        Write-Host "  AI workstation not available (hardware scan showed local AI not supported). Using Full + Ollama." -ForegroundColor Yellow
        $presetChoice = "D"
      }
      $presetNames = @("Git", "GitHub CLI", "Python 3", "PowerShell 7", "OpenSSH", "Node.js", "VS Code", "Tailscale", "cloudflared", "Claude Code", "OpenAI Codex", "Ollama", "uv")
      foreach ($item in $notInstalled) {
        if ($presetNames -contains $item.name) { $item.selected = $true }
      }
      # Select recommended models
      if ($script:recommendedModels.Count -gt 0) {
        $recIds = $script:recommendedModels | ForEach-Object { $_.id }
        foreach ($item in $catalog) {
          if ($recIds -contains $item.id) { $item.selected = $true }
        }
      }
      # Select cloud models
      foreach ($item in $notInstalled) {
        if ($item.category -eq "model-cloud") { $item.selected = $true }
      }
      $script:installScope = "user"
      $authGh = $true; $authTailscale = $true; $authCloudflare = $true
      $sshKeyPath = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
      $generateSshKey = -not (Test-Path $sshKeyPath)
      $applyDevSettings = $true
      $installExtensions = $false; $extList = @()
      $extConfigPath = Join-Path $PSScriptRoot "config\vscode-extensions.json"
      if (Test-Path $extConfigPath) {
        try { $extData = Get-Content $extConfigPath -Raw | ConvertFrom-Json; $extList = @($extData.extensions); $installExtensions = $extList.Count -gt 0 } catch {}
      }
      $script:presetApplied = $true
      Write-Host "  Profile: AI workstation" -ForegroundColor Green
    }
  }

  if ($script:presetApplied) {
    # Load workspace defaults
    $defaultsPath = Join-Path $PSScriptRoot "config\defaults.json"
    $workspacePath = "D:\aijetlabs"; $githubUser = "jeremytrindade"; $gitEmail = "jeremytrindade@gmail.com"
    if (Test-Path $defaultsPath) {
      try {
        $defs = Get-Content $defaultsPath -Raw | ConvertFrom-Json
        if ($defs.workspacePath) { $workspacePath = $defs.workspacePath }
        if ($defs.githubUser)    { $githubUser = $defs.githubUser }
        if ($defs.gitEmail)      { $gitEmail = $defs.gitEmail }
      } catch {}
    }

    $selectedCount = @($catalog | Where-Object { $_.selected }).Count
    Write-Host "  Selected: $selectedCount items" -ForegroundColor Green
    Write-Host "  Workspace: $workspacePath" -ForegroundColor DarkGray
    Write-Host "  Git: $githubUser <$gitEmail>" -ForegroundColor DarkGray
    if ($generateSshKey) { Write-Host "  SSH key: will generate" -ForegroundColor DarkGray }
    if ($applyDevSettings) { Write-Host "  Dev settings: on" -ForegroundColor DarkGray }
    if ($installExtensions) { Write-Host "  VS Code extensions: $($extList.Count)" -ForegroundColor DarkGray }
  }

  if (-not $script:presetApplied) {

  $localAiCount = @($notInstalled | Where-Object { $_.category -eq "local-ai" -or $_.category -eq "model" -or $_.category -eq "model-lg" }).Count
  $nonLocalCount = $notInstalled.Count - $localAiCount

  Write-Host "  What would you like to install?" -ForegroundColor White
  Write-Host ""
  if ($script:recommendedModels.Count -gt 0) {
    Write-Host "    [1] Install all tools + recommended models" -ForegroundColor Cyan
  } else {
    Write-Host "    [1] Install everything ($($notInstalled.Count) items)" -ForegroundColor $(if ($script:localAiCapable) { "Cyan" } else { "Yellow" })
  }
  Write-Host "    [2] Install everything EXCEPT local AI + models ($nonLocalCount items)" -ForegroundColor Cyan
  Write-Host "    [3] Customize (pick from the list)" -ForegroundColor Cyan
  Write-Host "    [4] Skip installs (only authenticate + configure + clone)" -ForegroundColor Cyan
  if ($script:recommendedModels.Count -gt 0) {
    Write-Host "    [5] Install everything including ALL models ($($notInstalled.Count) items)" -ForegroundColor Yellow
  }

  if (-not $script:localAiCapable) {
    Write-Host ""
    Write-Host "    Note: option [1] includes local AI that your hardware may not support." -ForegroundColor Yellow
  }

  Write-Host ""
  $choices = if ($script:recommendedModels.Count -gt 0) { "1/2/3/4/5" } else { "1/2/3/4" }
  $mode = Read-Host "  Choose [$choices]"

  switch ($mode) {
    "1" {
      if ($script:recommendedModels.Count -gt 0) {
        foreach ($item in $notInstalled) {
          if ($item.category -notin @("model", "model-lg")) {
            $item.selected = $true
          }
        }
        $recIds = $script:recommendedModels | ForEach-Object { $_.id }
        foreach ($item in $catalog) {
          if ($recIds -contains $item.id) { $item.selected = $true }
        }
        $selectedCount = @($catalog | Where-Object { $_.selected }).Count
        $modelNames = ($script:recommendedModels | ForEach-Object { $_.name }) -join ", "
        Write-Host "  Selected: $selectedCount items (models: $modelNames)" -ForegroundColor Green
      } elseif (-not $script:localAiCapable) {
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
    "5" {
      foreach ($item in $notInstalled) { $item.selected = $true }
      Write-Host "  Selected: everything including all models ($($notInstalled.Count) items)" -ForegroundColor Green
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
      $modelTotalGB = [math]::Round(($catalog | Where-Object { $_.category -eq "model" -and -not $_.installed } | ForEach-Object { $_.downloadMB } | Measure-Object -Sum).Sum / 1024, 1)
      $modelLabel   = if ($script:localAiCapable) { "AI models via Ollama (~$modelTotalGB GB total)" } else { "AI models via Ollama (NOT RECOMMENDED, see hardware scan)" }
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
      $recIds = @($script:recommendedModels | ForEach-Object { $_.id })
      $lastCategory = ""
      foreach ($item in $notInstalled) {
        if ($item.category -ne $lastCategory) {
          $lastCategory = $item.category
          Write-Host ("    --- " + $categoryLabels[$item.category] + " ---") -ForegroundColor Cyan
        }
        $sizeNote = if ($item.size) { " ($($item.size))" } else { "" }
        $recTag = if ($recIds -contains $item.id) { " [REC]" } else { "" }
        $color = if ($recIds -contains $item.id) { "Green" } else { "White" }
        Write-Host ("    [$($item.id)] $($item.name)$sizeNote$recTag") -ForegroundColor $color
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

  } # end if (-not $script:presetApplied)
}

if (-not $script:presetApplied) {

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
    if (-not $script:isAdmin) {
      Write-Host ""
      Write-Host "  Machine scope requires admin privileges." -ForegroundColor Yellow
      $elevate = Read-Host "  Re-launch as Administrator? [Y/n]"
      if ($elevate -ne "n" -and $elevate -ne "N") {
        $scriptPath = Join-Path $PSScriptRoot "startupjet.ps1"
        Start-Process pwsh -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`"" -Verb RunAs -ErrorAction SilentlyContinue
        if ($?) {
          Write-Host "  Elevated window opened. This window will close." -ForegroundColor Green
          Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
          exit 0
        } else {
          Write-Host "  Could not elevate. Falling back to user scope." -ForegroundColor Yellow
          $script:installScope = "user"
        }
      } else {
        Write-Host "  Continuing without admin. Some installs may fail." -ForegroundColor Yellow
      }
    }
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
$defaultWorkspace = "D:\aijetlabs"
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

} # end if (-not $script:presetApplied)

# =====================================================================
# From here on, NO MORE USER INPUT. Everything runs unattended.
# =====================================================================

Write-Host ""

if ($DryRun) {
  Write-Host ("=" * 60) -ForegroundColor Yellow
  Write-Host " DRY RUN, nothing will be changed" -ForegroundColor Yellow
  Write-Host ("=" * 60) -ForegroundColor Yellow

  Write-Phase "DRY RUN SUMMARY"

  $toInstall = @($catalog | Where-Object { $_.selected })
  if ($toInstall.Count -gt 0) {
    Write-Host "  Would install:" -ForegroundColor White
    foreach ($item in $toInstall) {
      $sizeNote = if ($item.size) { " ($($item.size))" } else { "" }
      Write-Host ("    + $($item.name)$sizeNote") -ForegroundColor Cyan
    }
  } else {
    Write-Host "  Nothing to install." -ForegroundColor DarkGray
  }

  Write-Host ""
  Write-Host "  Would authenticate:" -ForegroundColor White
  if ($authGh)         { Write-Host "    + GitHub CLI" -ForegroundColor Cyan }
  if ($authTailscale)  { Write-Host "    + Tailscale" -ForegroundColor Cyan }
  if ($authCloudflare) { Write-Host "    + cloudflared" -ForegroundColor Cyan }
  if (-not $authGh -and -not $authTailscale -and -not $authCloudflare) { Write-Host "    (none)" -ForegroundColor DarkGray }

  Write-Host ""
  Write-Host "  Would configure:" -ForegroundColor White
  Write-Host "    git user.name = $githubUser" -ForegroundColor Cyan
  Write-Host "    git user.email = $gitEmail" -ForegroundColor Cyan
  Write-Host "    Install scope: $script:installScope" -ForegroundColor Cyan
  if ($generateSshKey) { Write-Host "    Generate SSH key (ed25519)" -ForegroundColor Cyan }
  if ($applyDevSettings) { Write-Host "    Apply Windows dev settings" -ForegroundColor Cyan }
  if ($installExtensions) { Write-Host "    Install $($extList.Count) VS Code extensions" -ForegroundColor Cyan }

  Write-Host ""
  Write-Host "  Would clone repos to: $workspacePath\github\" -ForegroundColor White
  $reposJsonPath = Join-Path $PSScriptRoot "config\repos.json"
  if (Test-Path $reposJsonPath) {
    $reposData = Get-Content $reposJsonPath -Raw | ConvertFrom-Json
    foreach ($r in $reposData.repos) {
      $dest = Join-Path $workspacePath "github\$($r.name)"
      $exists = if (Test-Path $dest) { " [already exists]" } else { "" }
      $shallow = if ($r.shallow -eq $true) { " (shallow)" } else { "" }
      Write-Host ("    + $($r.owner)/$($r.name)$shallow$exists") -ForegroundColor Cyan
    }
  }

  Write-Host ""
  Write-Host "  Re-run without -DryRun to execute." -ForegroundColor Green
  Write-Host ""
  exit 0
}

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

# SSH key: try vault first, then generate
$sshKeyRestored = $false
if ($generateSshKey -and (Test-Command "bw")) {
  Write-Host ""
  Write-Host "  Bitwarden vault detected. Checking for existing SSH key..."
  $bwStatus = bw status 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
  if ($bwStatus.status -eq "locked" -or $bwStatus.status -eq "unauthenticated") {
    if (-not $DryRun) {
      Write-Host "  Unlocking Bitwarden vault..."
      $env:BW_SESSION = bw unlock --raw 2>&1
      if (-not $env:BW_SESSION) {
        $env:BW_SESSION = bw login --raw 2>&1
      }
    }
  }
  if ($env:BW_SESSION -or $bwStatus.status -eq "unlocked") {
    $sshItems = bw list items --search "ssh key" --session $env:BW_SESSION 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($sshItems -and $sshItems.Count -gt 0) {
      $sshItem = $sshItems[0]
      $sshDir = Join-Path $env:USERPROFILE ".ssh"
      if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }
      if (-not $DryRun) {
        foreach ($att in (bw list item-attachments $sshItem.id --session $env:BW_SESSION 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue)) {
          bw get attachment $att.id --itemid $sshItem.id --output (Join-Path $sshDir $att.fileName) --session $env:BW_SESSION 2>&1 | Out-Null
        }
        if (Test-Path $sshKeyPath) {
          Write-Host "  [OK] SSH key restored from vault" -ForegroundColor Green
          $sshKeyRestored = $true
        }
      } else {
        Write-Host "  [DRY RUN] Would restore SSH key from vault item: $($sshItem.name)" -ForegroundColor Yellow
        $sshKeyRestored = $true
      }
    }
  }
}

if ($generateSshKey -and -not $sshKeyRestored) {
  $sshDir = Join-Path $env:USERPROFILE ".ssh"
  if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
  }
  if (Test-Path $sshKeyPath) {
    Write-Host "  [OK] SSH key already exists: $sshKeyPath" -ForegroundColor Green
  } else {
    Write-Host "  Generating SSH key (ed25519)..."
    if (-not $DryRun) {
      ssh-keygen -t ed25519 -C $gitEmail -f $sshKeyPath -N '""' -q 2>&1 | Out-Null
      if (Test-Path $sshKeyPath) {
        Write-Host "  [OK] SSH key: $sshKeyPath" -ForegroundColor Green
      } else {
        Write-Host "  [FAIL] SSH key generation failed" -ForegroundColor Red
      }
    } else {
      Write-Host "  [DRY RUN] Would generate SSH key at $sshKeyPath" -ForegroundColor Yellow
    }
  }
}

if ($generateSshKey -and (Test-Path "$sshKeyPath.pub") -and (Test-Command "gh") -and -not $DryRun) {
  $ghCheck = gh auth status 2>&1
  if ($LASTEXITCODE -eq 0) {
    $keyTitle = "startupjet $(hostname) $(Get-Date -Format 'yyyy-MM-dd')"
    gh ssh-key add "$sshKeyPath.pub" --title $keyTitle 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  [OK] SSH key added to GitHub ($keyTitle)" -ForegroundColor Green
    } else {
      Write-Host "  [--] Could not add SSH key to GitHub (may already exist)" -ForegroundColor Yellow
    }
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
  if ($script:isAdmin) {
    try {
      reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Developer Mode enabled" -ForegroundColor Green
      } else {
        Write-Host "  [FAIL] Developer Mode registry write failed" -ForegroundColor Red
      }
    } catch {
      Write-Host "  [FAIL] Developer Mode: $_" -ForegroundColor Red
    }
  } else {
    Write-Host "  [skip] Developer Mode requires admin (re-run as Administrator)" -ForegroundColor Yellow
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
      # Ensure Ollama service is running before pulling models
      $ollamaReady = $false
      try {
        ollama list 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ollamaReady = $true }
      } catch {}
      if (-not $ollamaReady) {
        Write-Host "  Starting Ollama service..." -ForegroundColor Yellow
        Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        try {
          ollama list 2>&1 | Out-Null
          if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Ollama service started" -ForegroundColor Green
            $ollamaReady = $true
          }
        } catch {}
        if (-not $ollamaReady) {
          Write-Host "  [FAIL] Could not start Ollama service. Skipping model downloads." -ForegroundColor Red
          foreach ($m in $modelItems) { $script:summary.failed += $m.name }
        }
      }
      if (-not $ollamaReady) { $modelItems = @() }
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
# PHASE 5.5: DOTFILES (unattended)
# =====================================================================
$dotfilesCfg = Join-Path $PSScriptRoot "config\dotfiles.json"
if ((Test-Path $dotfilesCfg)) {
  $dotData = Get-Content $dotfilesCfg -Raw | ConvertFrom-Json
  $dotRepo = $dotData.repo
  $dotFiles = $dotData.files

  if ($dotRepo -and $dotRepo.Length -gt 0) {
    Write-Phase "PHASE 5.5, dotfiles"

    $dotDir = Join-Path $env:USERPROFILE ".dotfiles"
    if (-not (Test-Path $dotDir)) {
      Write-Host "  Cloning dotfiles from $dotRepo..."
      if (-not $DryRun) {
        git clone $dotRepo $dotDir 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
          Write-Host "  [OK] Dotfiles cloned" -ForegroundColor Green
        } else {
          Write-Host "  [FAIL] Dotfiles clone failed" -ForegroundColor Red
        }
      } else {
        Write-Host "  [DRY RUN] Would clone $dotRepo to $dotDir" -ForegroundColor Yellow
      }
    } else {
      Write-Host "  [OK] Dotfiles already cloned at $dotDir" -ForegroundColor Green
      if (-not $DryRun) {
        git -C $dotDir pull --ff-only 2>&1 | Out-Null
      }
    }

    if ((Test-Path $dotDir) -and -not $DryRun) {
      $dotFiles.PSObject.Properties | ForEach-Object {
        $src = Join-Path $dotDir $_.Name
        $dst = $_.Value -replace "~", $env:USERPROFILE
        if (-not (Test-Path $src)) {
          Write-Host "  [skip] Source not found: $($_.Name)" -ForegroundColor Yellow
          return
        }
        $dstDir = Split-Path $dst -Parent
        if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        if (Test-Path $dst) {
          $backup = "$dst.backup"
          Copy-Item $dst $backup -Force
          Write-Host "  Backed up $dst" -ForegroundColor DarkGray
        }
        Copy-Item $src $dst -Force
        Write-Host "  [OK] $($_.Name) -> $dst" -ForegroundColor Green
      }
    } elseif ($DryRun) {
      $dotFiles.PSObject.Properties | ForEach-Object {
        $dst = $_.Value -replace "~", $env:USERPROFILE
        Write-Host "  [DRY RUN] Would copy $($_.Name) -> $dst" -ForegroundColor Yellow
      }
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

# Prefer SSH clone if SSH key exists and gh is authenticated (enables push without reconfiguring remotes)
$preferSsh = $false
if ((Test-Path "$sshKeyPath") -and (Test-Command "gh")) {
  $ghStatus = gh auth status 2>&1
  if ($LASTEXITCODE -eq 0) { $preferSsh = $true }
}
if ($preferSsh) {
  Write-Host "  Using SSH clone (SSH key + gh auth detected)" -ForegroundColor Cyan
} else {
  Write-Host "  Using HTTPS clone" -ForegroundColor DarkGray
}
Write-Host ""

foreach ($repo in $repos) {
  $url = if ($preferSsh) { "git@github.com:$($repo.owner)/$($repo.name).git" } else { "https://github.com/$($repo.owner)/$($repo.name).git" }
  $dest = Join-Path $githubFolder $repo.name
  if (Test-Path $dest) {
    Write-Host ("  [pull] " + $repo.name + " already exists, updating...")
    git -C $dest pull --ff-only 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host ("  [OK] " + $repo.name + " updated") -ForegroundColor Green
    } else {
      Write-Host ("  [OK] " + $repo.name + " (pull skipped, may have local changes)") -ForegroundColor Yellow
    }
    continue
  }
  $shallow = if ($repo.shallow -eq $true) { "--depth 1" } else { "" }
  $shallowNote = if ($repo.shallow -eq $true) { " (shallow)" } else { "" }
  Write-Host ("  cloning " + $repo.name + "$shallowNote...")
  if ($repo.shallow -eq $true) {
    git clone --depth 1 $url $dest 2>&1 | Out-Null
  } else {
    git clone $url $dest 2>&1 | Out-Null
  }
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

# Post-clone dependency install
$clonedWithDeps = @()
foreach ($repoName in $script:summary.reposCloned) {
  $repoPath = Join-Path $githubFolder $repoName
  $pkgJson = Join-Path $repoPath "package.json"
  $reqTxt  = Join-Path $repoPath "requirements.txt"
  if (Test-Path $pkgJson) { $clonedWithDeps += @{ name = $repoName; path = $repoPath; type = "npm" } }
  if (Test-Path $reqTxt)  { $clonedWithDeps += @{ name = $repoName; path = $repoPath; type = "pip" } }
}

if ($clonedWithDeps.Count -gt 0) {
  Write-Host ""
  Write-Host "  Installing dependencies for cloned repos..." -ForegroundColor Cyan
  foreach ($dep in $clonedWithDeps) {
    if ($dep.type -eq "npm" -and (Test-Command "npm")) {
      Write-Host "  $($dep.name): npm install..."
      $prevDir = Get-Location
      Set-Location $dep.path
      npm install 2>&1 | Out-Null
      Set-Location $prevDir
      if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] $($dep.name) npm dependencies" -ForegroundColor Green
      } else {
        Write-Host "  [--] $($dep.name) npm install had issues" -ForegroundColor Yellow
      }
    }
    if ($dep.type -eq "pip" -and (Test-Command "python")) {
      Write-Host "  $($dep.name): pip install -r requirements.txt..."
      $prevDir = Get-Location
      Set-Location $dep.path
      python -m pip install -r requirements.txt 2>&1 | Out-Null
      Set-Location $prevDir
      if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] $($dep.name) pip dependencies" -ForegroundColor Green
      } else {
        Write-Host "  [--] $($dep.name) pip install had issues" -ForegroundColor Yellow
      }
    }
  }
}

# =====================================================================
# PHASE 6.5: POST-CLONE INTEGRATION (jet-rules + extended rules + workspace setup)
# =====================================================================

# Layer 1: jet-rules (universal open-source rules)
$jetRulesDir = Join-Path $githubFolder "jet-rules"
$jetRulesSource = Join-Path $jetRulesDir "rules.md"
if (Test-Path $jetRulesSource) {
  $jetRulesDest = Join-Path $workspacePath "jet-rules.md"
  Copy-Item $jetRulesSource $jetRulesDest -Force
  Write-Host "  [OK] jet-rules.md copied to $jetRulesDest" -ForegroundColor Green
}

# Layer 2: extended rules (from jet-rules/config.json -> extended.repo)
$jetRulesConfig = Join-Path $jetRulesDir "config.json"
if (Test-Path $jetRulesConfig) {
  try {
    $jrCfg = Get-Content $jetRulesConfig -Raw | ConvertFrom-Json
    $extFile = $jrCfg.extended.file
    if ($extFile) {
      $extRepoName = ($jrCfg.extended.repo -split "/")[-1]
      $extSource = Join-Path $githubFolder "$extRepoName\$extFile"
      if (Test-Path $extSource) {
        $extDest = Join-Path $workspacePath $extFile
        Copy-Item $extSource $extDest -Force
        Write-Host "  [OK] $extFile (extended rules) copied to $extDest" -ForegroundColor Green
      }
    }
  } catch {}
}

# Workspace support folders
$historyDir = Join-Path $workspacePath ".history"
if (-not (Test-Path $historyDir)) {
  New-Item -ItemType Directory -Force -Path $historyDir | Out-Null
  Write-Host "  [OK] Created $historyDir for conversation logging" -ForegroundColor Green
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

# Functional tests
Write-Host ""
Write-Host "  Functional tests..." -ForegroundColor Cyan

if (Test-Command "python") {
  $pyTest = python -c "import json, os, sys; print(f'python OK, {sys.version.split()[0]}')" 2>&1
  if ($pyTest -match "OK") {
    Write-Host "  [OK] Python import test: $pyTest" -ForegroundColor Green
  } else {
    Write-Host "  [WARN] Python import test: $pyTest" -ForegroundColor Yellow
  }
}

if (Test-Command "node") {
  $nodeTest = node -e "console.log('node OK, ' + process.version)" 2>&1
  if ($nodeTest -match "OK") {
    Write-Host "  [OK] Node.js test: $nodeTest" -ForegroundColor Green
  } else {
    Write-Host "  [WARN] Node.js test: $nodeTest" -ForegroundColor Yellow
  }
}

if ((Test-Command "ollama") -and $script:summary.modelsLoaded.Count -gt 0) {
  $testModel = $script:summary.modelsLoaded[0]
  Write-Host "  Ollama inference test ($testModel)..."
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $inferenceOut = ollama run $testModel "Say hello in exactly 5 words" 2>&1 | Select-Object -First 3
  $sw.Stop()
  if ($LASTEXITCODE -eq 0 -and $inferenceOut) {
    Write-Host "  [OK] Ollama inference: $($sw.Elapsed.TotalSeconds.ToString('F1'))s" -ForegroundColor Green
  } else {
    Write-Host "  [WARN] Ollama inference test did not complete" -ForegroundColor Yellow
  }
}

if (Test-Command "git") {
  $gitUser = git config --global user.name 2>&1
  $gitMail = git config --global user.email 2>&1
  if ($gitUser) {
    Write-Host "  [OK] Git identity: $gitUser <$gitMail>" -ForegroundColor Green
  } else {
    Write-Host "  [WARN] Git identity not set" -ForegroundColor Yellow
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

} finally {
  Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
