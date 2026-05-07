#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
CATALOG="$CONFIG_DIR/catalog.json"
REPOS_CFG="$CONFIG_DIR/repos.json"
DEFAULTS_CFG="$CONFIG_DIR/defaults.json"
EXTENSIONS_CFG="$CONFIG_DIR/vscode-extensions.json"
DOTFILES_CFG="$CONFIG_DIR/dotfiles.json"
PROGRESS_FILE="$CONFIG_DIR/progress.json"
LOG_FILE="$SCRIPT_DIR/startupjet-$(date +%Y-%m-%d-%H%M).log"
VERSION="1.2"

DRY_RUN=false
UPDATE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run|-d) DRY_RUN=true ;;
    --update|-u)  UPDATE=true ;;
    --version|-v)
      echo "startupjet v$VERSION"
      exit 0
      ;;
    --help|-h)
      echo "startupjet v$VERSION - fresh-machine bootstrap for macOS and Linux"
      echo ""
      echo "Usage: ./startupjet.sh [--update] [--dry-run] [--version]"
      echo "  --update   Upgrade all installed tools to latest"
      echo "  --dry-run  Show what would happen without making changes"
      echo "  --version  Show version"
      exit 0
      ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

exec > >(tee -a "$LOG_FILE") 2>&1

log()     { echo -e "$1"; }
info()    { log "${CYAN}[INFO]${NC} $1"; }
ok()      { log "${GREEN}[ OK ]${NC} $1"; }
warn()    { log "${YELLOW}[WARN]${NC} $1"; }
fail()    { log "${RED}[FAIL]${NC} $1"; }
header()  { log "\n${BOLD}======== $1 ========${NC}"; }
divider() { log "${DIM}────────────────────────────────────────${NC}"; }

cleanup() {
  log "\n${BOLD}Log saved to: $LOG_FILE${NC}"
}
trap cleanup EXIT

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required to parse config files."
  echo "  macOS: xcode-select --install"
  echo "  Linux: sudo apt install python3"
  exit 1
fi

case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *)      echo "Unsupported OS: $(uname -s)"; exit 1 ;;
esac

WORKSPACE=$(python3 -c "
import json, os
d = json.load(open('$DEFAULTS_CFG'))
wp = d.get('workspacePathUnix', '')
if not wp:
    wp = d.get('workspacePath', '')
if not wp or '\\\\' in wp or ':' in wp[1:]:
    wp = '~/workspace'
print(os.path.expanduser(wp))
")
GH_USER=$(python3 -c "import json; print(json.load(open('$DEFAULTS_CFG')).get('githubUser',''))")
GIT_EMAIL=$(python3 -c "import json; print(json.load(open('$DEFAULTS_CFG')).get('gitEmail',''))")

SELECTED_TOOLS=()
SELECTED_MODELS=()
INSTALL_AUTH_GH=false
INSTALL_AUTH_TS=false
INSTALL_AUTH_CF=false
GENERATE_SSH=false
INSTALL_EXTENSIONS=false
APPLY_DOTFILES=false
RAM_GB=0
VRAM_GB=0
DISK_FREE_GB=0
GPU_NAME="none"

SUMMARY_INSTALLED=()
SUMMARY_ALREADY=()
SUMMARY_FAILED=()
SUMMARY_AUTH=()
SUMMARY_REPOS_CLONED=()
SUMMARY_REPOS_SKIPPED=()
SUMMARY_MODELS=()
SUMMARY_EXTENSIONS=()

# ─────────────────────────────────────────────────────────────────
# Phase 1: Scan
# ─────────────────────────────────────────────────────────────────
phase1_scan() {
  header "Phase 1: Scan"
  info "OS: $OS ($(uname -m))"

  if [[ "$OS" == "macos" ]]; then
    RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  else
    RAM_GB=$(free -g 2>/dev/null | awk '/Mem:/ {print $2}' || echo 0)
  fi
  info "RAM: ${RAM_GB} GB"

  VRAM_GB=0
  GPU_NAME="none"
  if [[ "$OS" == "macos" ]]; then
    if [[ "$(uname -m)" == "arm64" ]]; then
      GPU_NAME="Apple Silicon (unified memory)"
      VRAM_GB=$RAM_GB
    else
      GPU_NAME=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Chipset Model" | head -1 | sed 's/.*: //' || echo "unknown")
      local vram_mb
      vram_mb=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "VRAM" | head -1 | grep -oE '[0-9]+' | head -1 || echo "0")
      VRAM_GB=$(( vram_mb / 1024 ))
    fi
  else
    if command -v nvidia-smi &>/dev/null; then
      GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA (unknown)")
      local vram_mb
      vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
      VRAM_GB=$(( vram_mb / 1024 ))
    elif lspci 2>/dev/null | grep -qi nvidia; then
      GPU_NAME="NVIDIA (driver not loaded)"
    fi
  fi
  info "GPU: $GPU_NAME, VRAM: ${VRAM_GB} GB"

  if [[ "$OS" == "macos" ]]; then
    DISK_FREE_GB=$(df -g / | awk 'NR==2 {print $4}')
  else
    DISK_FREE_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
  fi
  info "Disk free: ${DISK_FREE_GB} GB"

  info "Speed test (5 MB from Cloudflare)..."
  local speed_file="/tmp/startupjet-speedtest"
  local t_start t_end
  t_start=$(python3 -c "import time; print(time.time())")
  curl -sS -o "$speed_file" "https://speed.cloudflare.com/__down?bytes=5000000" 2>/dev/null || true
  t_end=$(python3 -c "import time; print(time.time())")
  local speed_mbps
  speed_mbps=$(python3 -c "
import os
try:
    sz = os.path.getsize('$speed_file')
    el = $t_end - $t_start
    print(f'{sz * 8 / el / 1e6:.1f}') if el > 0 else print('?')
except: print('?')
")
  rm -f "$speed_file"
  info "Download speed: ~${speed_mbps} Mbps"

  divider
  info "Scanning installed tools..."

  python3 << PYEOF
import json, shutil, subprocess

with open("$CATALOG") as f:
    cat = json.load(f)

for tool in cat["tools"]:
    name = tool["name"]
    cmd = tool["cmd"]
    inst = tool.get("install", {}).get("$OS", {})
    method = inst.get("method", "none")
    if method in ("none",):
        continue
    found = shutil.which(cmd) is not None
    if found:
        try:
            ver = subprocess.check_output([cmd, "--version"], stderr=subprocess.STDOUT, timeout=5).decode().strip().split("\n")[0][:60]
        except:
            ver = "installed"
        print(f"\033[0;32m[ OK ]\033[0m {name}: {ver}")
    else:
        print(f"\033[1;33m[MISS]\033[0m {name} ({cmd})")
PYEOF

  if (( VRAM_GB >= 8 )); then
    ok "Local AI verdict: READY (${VRAM_GB} GB VRAM)"
  elif (( VRAM_GB >= 4 )); then
    warn "Local AI verdict: POSSIBLE (${VRAM_GB} GB VRAM, smaller models only)"
  else
    warn "Local AI verdict: NOT RECOMMENDED (${VRAM_GB} GB VRAM)"
  fi
}

# ─────────────────────────────────────────────────────────────────
# Phase 2: Choose
# ─────────────────────────────────────────────────────────────────
phase2_choose() {
  header "Phase 2: Choose"

  echo ""
  echo "  [A] Minimal dev    - Git, GitHub CLI, Python, Node, pwsh, OpenSSH"
  echo "  [B] Developer      - A + VS Code, Tailscale, cloudflared, dev settings"
  echo "  [C] Full setup     - B + Claude Code, OpenAI Codex, all but local LLMs"
  echo "  [D] AI workstation - C + Ollama, uv, recommended models"
  echo "  [E] Custom         - Pick everything yourself"
  echo ""
  read -rp "Choose a preset [A/B/C/D/E]: " preset_choice

  local dev_ids=(1 2 3 4 5 6 7)
  local net_ids=(8 9)
  local ai_ids=(10 11)
  local local_ai_ids=(12 13)

  case "${preset_choice^^}" in
    A)
      SELECTED_TOOLS=("${dev_ids[@]}")
      INSTALL_AUTH_GH=true
      GENERATE_SSH=true
      INSTALL_EXTENSIONS=true
      ;;
    B)
      SELECTED_TOOLS=("${dev_ids[@]}" "${net_ids[@]}")
      INSTALL_AUTH_GH=true
      INSTALL_AUTH_TS=true
      INSTALL_AUTH_CF=true
      GENERATE_SSH=true
      INSTALL_EXTENSIONS=true
      ;;
    C)
      SELECTED_TOOLS=("${dev_ids[@]}" "${net_ids[@]}" "${ai_ids[@]}")
      INSTALL_AUTH_GH=true
      INSTALL_AUTH_TS=true
      INSTALL_AUTH_CF=true
      GENERATE_SSH=true
      INSTALL_EXTENSIONS=true
      ;;
    D)
      SELECTED_TOOLS=("${dev_ids[@]}" "${net_ids[@]}" "${ai_ids[@]}" "${local_ai_ids[@]}")
      INSTALL_AUTH_GH=true
      INSTALL_AUTH_TS=true
      INSTALL_AUTH_CF=true
      GENERATE_SSH=true
      INSTALL_EXTENSIONS=true
      select_recommended_models
      ;;
    E)
      custom_choose
      return
      ;;
    *)
      warn "Invalid choice, defaulting to Full setup."
      SELECTED_TOOLS=("${dev_ids[@]}" "${net_ids[@]}" "${ai_ids[@]}")
      INSTALL_AUTH_GH=true
      INSTALL_AUTH_TS=true
      INSTALL_AUTH_CF=true
      GENERATE_SSH=true
      INSTALL_EXTENSIONS=true
      ;;
  esac

  if [[ -f "$DOTFILES_CFG" ]]; then
    APPLY_DOTFILES=true
  fi

  read -rp "Workspace path [$WORKSPACE]: " ws_input
  if [[ -n "$ws_input" ]]; then
    WORKSPACE="$ws_input"
  fi
}

select_recommended_models() {
  local recs
  recs=$(python3 << PYEOF
import json

with open("$CATALOG") as f:
    cat = json.load(f)

vram = $VRAM_GB
ram = $RAM_GB
disk = $DISK_FREE_GB

scored = []
for m in cat["models"]:
    min_vram = m.get("minVRAM", 0)
    rec_vram = m.get("recVRAM", 0)
    min_ram = m.get("minRAM", 0)
    quality = m.get("quality", 5)
    size_str = m.get("size", "0")

    if size_str == "cloud":
        size_gb = 0
    else:
        size_gb = float(size_str.replace(" GB", "").replace(" MB", ""))

    if min_ram > 0 and ram < min_ram:
        continue
    if size_gb > 0 and disk < size_gb:
        continue

    score = quality
    if min_vram == 0:
        score += 2
    elif vram >= rec_vram:
        score += 3
    elif vram >= min_vram:
        score += 1
    else:
        continue

    scored.append((score, m["id"], m["name"], m["desc"]))

scored.sort(key=lambda x: -x[0])
for s, mid, name, desc in scored[:3]:
    print(f"{mid}|{name}|{desc}")
PYEOF
  )

  if [[ -z "$recs" ]]; then
    warn "No models fit your hardware. Skipping local AI models."
    return
  fi

  info "Recommended models for your hardware:"
  while IFS='|' read -r mid mname mdesc; do
    echo "    $mname - $mdesc"
    SELECTED_MODELS+=("$mid")
  done <<< "$recs"
}

custom_choose() {
  info "Available tools:"
  local tool_list
  tool_list=$(python3 << PYEOF
import json, shutil
with open("$CATALOG") as f:
    cat = json.load(f)
for t in cat["tools"]:
    inst = t.get("install", {}).get("$OS", {})
    if inst.get("method", "none") == "none":
        continue
    installed = "installed" if shutil.which(t["cmd"]) else "not installed"
    print(f"  {t['id']:>2}. {t['name']:<20} [{t['category']}] ({installed})")
PYEOF
  )
  echo "$tool_list"
  echo ""
  read -rp "Enter tool IDs to install (comma-separated, e.g. 1,2,3,6): " tool_ids
  IFS=',' read -ra SELECTED_TOOLS <<< "$tool_ids"
  SELECTED_TOOLS=("${SELECTED_TOOLS[@]// /}")

  read -rp "Authenticate GitHub CLI? [Y/n]: " yn
  [[ "${yn,,}" != "n" ]] && INSTALL_AUTH_GH=true

  read -rp "Authenticate Tailscale? [y/N]: " yn
  [[ "${yn,,}" == "y" ]] && INSTALL_AUTH_TS=true

  read -rp "Authenticate Cloudflare? [y/N]: " yn
  [[ "${yn,,}" == "y" ]] && INSTALL_AUTH_CF=true

  read -rp "Generate SSH key? [Y/n]: " yn
  [[ "${yn,,}" != "n" ]] && GENERATE_SSH=true

  read -rp "Install VS Code extensions? [Y/n]: " yn
  [[ "${yn,,}" != "n" ]] && INSTALL_EXTENSIONS=true

  if [[ -f "$DOTFILES_CFG" ]]; then
    read -rp "Apply dotfiles? [Y/n]: " yn
    [[ "${yn,,}" != "n" ]] && APPLY_DOTFILES=true
  fi

  local has_ollama=false
  for tid in "${SELECTED_TOOLS[@]}"; do
    [[ "$tid" == "12" ]] && has_ollama=true
  done
  if $has_ollama; then
    read -rp "Auto-select recommended AI models? [Y/n]: " yn
    if [[ "${yn,,}" != "n" ]]; then
      select_recommended_models
    else
      info "Available models:"
      python3 << PYEOF
import json
with open("$CATALOG") as f:
    cat = json.load(f)
for m in cat["models"]:
    print(f"  {m['id']:>2}. {m['name']:<20} {m['size']:>8}  {m['desc']}")
PYEOF
      read -rp "Enter model IDs (comma-separated): " model_ids
      IFS=',' read -ra SELECTED_MODELS <<< "$model_ids"
      SELECTED_MODELS=("${SELECTED_MODELS[@]// /}")
    fi
  fi

  read -rp "Workspace path [$WORKSPACE]: " ws_input
  [[ -n "$ws_input" ]] && WORKSPACE="$ws_input"
}

# ─────────────────────────────────────────────────────────────────
# Phase 3: Authenticate
# ─────────────────────────────────────────────────────────────────
phase3_auth() {
  header "Phase 3: Authenticate"

  if $INSTALL_AUTH_GH && command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
      ok "GitHub CLI already authenticated"
      SUMMARY_AUTH+=("GitHub (gh)")
    else
      info "Launching GitHub CLI login..."
      if ! $DRY_RUN; then
        gh auth login && SUMMARY_AUTH+=("GitHub (gh)")
      else
        info "[DRY RUN] Would run: gh auth login"
      fi
    fi
  elif $INSTALL_AUTH_GH; then
    warn "GitHub CLI not installed yet, will auth after install"
  fi

  if $INSTALL_AUTH_TS && command -v tailscale &>/dev/null; then
    info "Launching Tailscale login..."
    if ! $DRY_RUN; then
      if sudo tailscale up; then
        SUMMARY_AUTH+=("Tailscale")
      else
        warn "Tailscale login skipped"
      fi
    else
      info "[DRY RUN] Would run: sudo tailscale up"
    fi
  fi

  if $INSTALL_AUTH_CF && command -v cloudflared &>/dev/null; then
    info "Launching Cloudflare login..."
    if ! $DRY_RUN; then
      if cloudflared tunnel login; then
        SUMMARY_AUTH+=("cloudflared")
      else
        warn "Cloudflare login skipped"
      fi
    else
      info "[DRY RUN] Would run: cloudflared tunnel login"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────
# Phase 4: Configure
# ─────────────────────────────────────────────────────────────────
phase4_configure() {
  header "Phase 4: Configure"

  if [[ -n "$GIT_EMAIL" ]]; then
    if ! $DRY_RUN; then
      git config --global user.name "$GH_USER"
      git config --global user.email "$GIT_EMAIL"
      ok "Git identity: $GH_USER <$GIT_EMAIL>"
    else
      info "[DRY RUN] Would set git identity: $GH_USER <$GIT_EMAIL>"
    fi
  fi

  if $GENERATE_SSH; then
    local ssh_key="$HOME/.ssh/id_ed25519"
    local ssh_restored=false

    # Try vault first (Bitwarden CLI)
    if command -v bw &>/dev/null; then
      info "Bitwarden vault detected. Checking for existing SSH key..."
      local bw_status
      bw_status=$(bw status 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

      if [[ "$bw_status" == "locked" || "$bw_status" == "unauthenticated" ]]; then
        if ! $DRY_RUN; then
          info "Unlocking Bitwarden vault..."
          export BW_SESSION=$(bw unlock --raw 2>/dev/null || bw login --raw 2>/dev/null || echo "")
        fi
      fi

      if [[ -n "${BW_SESSION:-}" || "$bw_status" == "unlocked" ]]; then
        local ssh_items
        ssh_items=$(bw list items --search "ssh key" ${BW_SESSION:+--session "$BW_SESSION"} 2>/dev/null || echo "[]")
        local item_count
        item_count=$(echo "$ssh_items" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

        if [[ "$item_count" -gt 0 ]]; then
          local item_id
          item_id=$(echo "$ssh_items" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null || echo "")
          if [[ -n "$item_id" ]] && ! $DRY_RUN; then
            mkdir -p "$HOME/.ssh"
            local atts
            atts=$(bw list item-attachments "$item_id" ${BW_SESSION:+--session "$BW_SESSION"} 2>/dev/null || echo "[]")
            echo "$atts" | python3 -c "
import json, sys, subprocess
for att in json.load(sys.stdin):
    subprocess.run(['bw', 'get', 'attachment', att['id'], '--itemid', '$item_id', '--output', '$HOME/.ssh/' + att['fileName']] + (['--session', '$BW_SESSION'] if '$BW_SESSION' else []), capture_output=True)
" 2>/dev/null
            if [[ -f "$ssh_key" ]]; then
              chmod 600 "$ssh_key"
              ok "SSH key restored from vault"
              ssh_restored=true
            fi
          elif ! $DRY_RUN; then
            warn "Vault item found but could not extract attachments"
          else
            info "[DRY RUN] Would restore SSH key from vault"
            ssh_restored=true
          fi
        fi
      fi
    fi

    if ! $ssh_restored; then
      if [[ -f "$ssh_key" ]]; then
        ok "SSH key already exists: $ssh_key"
      elif ! $DRY_RUN; then
        mkdir -p "$HOME/.ssh"
        ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f "$ssh_key" -N ""
        ok "Generated SSH key: $ssh_key"
      else
        info "[DRY RUN] Would generate SSH key at $ssh_key"
      fi
    fi

    if [[ -f "$ssh_key.pub" ]] && command -v gh &>/dev/null && gh auth status &>/dev/null && ! $DRY_RUN; then
      gh ssh-key add "$ssh_key.pub" --title "startupjet-$(hostname)-$(date +%Y%m%d)" 2>/dev/null
      if [[ $? -eq 0 ]]; then
        ok "SSH key added to GitHub"
      else
        warn "Could not add SSH key to GitHub (may already exist)"
      fi
    fi
  fi

  if ! $DRY_RUN; then
    mkdir -p "$WORKSPACE"
    ok "Workspace ready: $WORKSPACE"
  else
    info "[DRY RUN] Would create workspace: $WORKSPACE"
  fi
}

# ─────────────────────────────────────────────────────────────────
# Phase 5: Install
# ─────────────────────────────────────────────────────────────────
check_progress() {
  local key="$1"
  if [[ -f "$PROGRESS_FILE" ]]; then
    python3 -c "
import json
with open('$PROGRESS_FILE') as f:
    d = json.load(f)
exit(0 if d.get('$key') else 1)
" 2>/dev/null
    return $?
  fi
  return 1
}

install_homebrew() {
  if command -v brew &>/dev/null; then
    ok "Homebrew already installed"
    return
  fi
  info "Installing Homebrew..."
  if ! $DRY_RUN; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ "$OS" == "macos" && "$(uname -m)" == "arm64" ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ "$OS" == "linux" ]]; then
      eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
  else
    info "[DRY RUN] Would install Homebrew"
  fi
}

install_tool() {
  local tool_id="$1"

  if check_progress "$tool_id"; then
    local skip_name
    skip_name=$(python3 -c "import json; cat=json.load(open('$CATALOG')); print(next((t['name'] for t in cat['tools'] if t['id']==$tool_id),'?'))")
    ok "$skip_name (resumed from progress)"
    return
  fi

  local tool_info
  tool_info=$(python3 << PYEOF
import json
with open("$CATALOG") as f:
    cat = json.load(f)
for t in cat["tools"]:
    if t["id"] == $tool_id:
        inst = t.get("install", {}).get("$OS", {})
        method = inst.get("method", "none")
        pkg = inst.get("package", inst.get("id", ""))
        cmd_str = inst.get("cmd", "")
        print(f"{t['name']}|{t['cmd']}|{method}|{pkg}|{cmd_str}")
        break
PYEOF
  )

  if [[ -z "$tool_info" ]]; then
    warn "Tool ID $tool_id not found in catalog for $OS"
    return
  fi

  IFS='|' read -r name cmd method pkg cmd_str <<< "$tool_info"

  if command -v "$cmd" &>/dev/null; then
    ok "$name already installed"
    SUMMARY_ALREADY+=("$name")
    return
  fi

  info "Installing $name..."

  if $DRY_RUN; then
    info "[DRY RUN] Would install $name via $method"
    return
  fi

  case "$method" in
    brew)
      brew install "$pkg"
      ;;
    cask)
      brew install --cask "$pkg"
      ;;
    apt)
      sudo apt update -qq
      sudo apt install -y $pkg
      ;;
    npm)
      if ! command -v npm &>/dev/null; then
        warn "npm not available, skipping $name"
        SUMMARY_FAILED+=("$name")
        return
      fi
      npm install -g "$pkg"
      ;;
    script)
      eval "$cmd_str"
      ;;
    manual)
      eval "$cmd_str"
      ;;
    builtin)
      ok "$name is built-in"
      SUMMARY_ALREADY+=("$name")
      return
      ;;
    *)
      warn "Unknown install method '$method' for $name on $OS"
      SUMMARY_FAILED+=("$name")
      return
      ;;
  esac

  if command -v "$cmd" &>/dev/null; then
    ok "$name installed"
    SUMMARY_INSTALLED+=("$name")
  else
    warn "$name installed but not on PATH yet (may need shell restart)"
    SUMMARY_INSTALLED+=("$name")
  fi

  save_progress "$tool_id" "installed"
}

install_model() {
  local model_id="$1"

  if check_progress "model_$model_id"; then
    local skip_name
    skip_name=$(python3 -c "import json; cat=json.load(open('$CATALOG')); print(next((m['name'] for m in cat['models'] if m['id']==$model_id),'?'))")
    ok "$skip_name (resumed from progress)"
    return
  fi

  local model_info
  model_info=$(python3 << PYEOF
import json
with open("$CATALOG") as f:
    cat = json.load(f)
for m in cat["models"]:
    if m["id"] == $model_id:
        print(f"{m['name']}|{m['size']}")
        break
PYEOF
  )

  if [[ -z "$model_info" ]]; then
    warn "Model ID $model_id not found"
    return
  fi

  IFS='|' read -r mname msize <<< "$model_info"

  if [[ "$msize" == "cloud" ]]; then
    ok "$mname is cloud-hosted, no download needed"
    SUMMARY_MODELS+=("$mname")
    return
  fi

  info "Pulling $mname ($msize)..."

  if $DRY_RUN; then
    info "[DRY RUN] Would run: ollama pull $mname"
    return
  fi

  if ! command -v ollama &>/dev/null; then
    warn "Ollama not installed, cannot pull $mname"
    SUMMARY_FAILED+=("$mname")
    return
  fi

  if ! ollama list &>/dev/null 2>&1; then
    info "Starting Ollama service..."
    ollama serve &>/dev/null &
    sleep 3
  fi

  if ollama pull "$mname"; then
    ok "$mname downloaded"
    SUMMARY_MODELS+=("$mname")
  else
    warn "Failed to pull $mname"
    SUMMARY_FAILED+=("$mname")
  fi
  save_progress "model_$model_id" "pulled"
}

save_progress() {
  local key="$1"
  local status="$2"
  python3 << PYEOF
import json, os
pf = "$PROGRESS_FILE"
data = {}
if os.path.exists(pf):
    with open(pf) as f:
        data = json.load(f)
data["$key"] = "$status"
with open(pf, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

phase5_install() {
  header "Phase 5: Install"

  if [[ "$OS" == "macos" ]]; then
    install_homebrew
  fi

  local needs_apt_update=true
  for tid in "${SELECTED_TOOLS[@]}"; do
    if [[ "$OS" == "linux" ]] && $needs_apt_update; then
      local method
      method=$(python3 -c "
import json
with open('$CATALOG') as f: cat = json.load(f)
for t in cat['tools']:
    if t['id'] == $tid:
        print(t.get('install',{}).get('$OS',{}).get('method',''))
        break
")
      if [[ "$method" == "apt" ]] && ! $DRY_RUN; then
        info "Updating apt package index..."
        sudo apt update -qq
        needs_apt_update=false
      fi
    fi
    install_tool "$tid"
  done

  for mid in "${SELECTED_MODELS[@]}"; do
    install_model "$mid"
  done

  if $INSTALL_EXTENSIONS && command -v code &>/dev/null && [[ -f "$EXTENSIONS_CFG" ]]; then
    info "Installing VS Code extensions..."
    if ! $DRY_RUN; then
      python3 -c "
import json
with open('$EXTENSIONS_CFG') as f:
    exts = json.load(f).get('extensions', [])
for e in exts:
    print(e)
" | while read -r ext; do
        if code --install-extension "$ext" --force 2>/dev/null; then
          ok "Extension: $ext"
          SUMMARY_EXTENSIONS+=("$ext")
        else
          warn "Extension failed: $ext"
        fi
      done
    else
      info "[DRY RUN] Would install VS Code extensions from $EXTENSIONS_CFG"
    fi
  fi

  if $INSTALL_AUTH_GH && command -v gh &>/dev/null; then
    if ! gh auth status &>/dev/null; then
      info "GitHub CLI is now installed. Launching login..."
      if ! $DRY_RUN; then
        gh auth login && SUMMARY_AUTH+=("GitHub (gh)")
      fi
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────
# Phase 5.5: Dotfiles
# ─────────────────────────────────────────────────────────────────
phase5_dotfiles() {
  if ! $APPLY_DOTFILES || [[ ! -f "$DOTFILES_CFG" ]]; then
    return
  fi

  header "Phase 5.5: Dotfiles"

  python3 << PYEOF
import json, os, subprocess, sys

with open("$DOTFILES_CFG") as f:
    cfg = json.load(f)

repo = cfg.get("repo", "")
files = cfg.get("files", {})
dry = $( $DRY_RUN && echo "True" || echo "False" )
home = os.path.expanduser("~")
dotfiles_dir = os.path.join(home, ".dotfiles")

if not repo:
    print("\033[1;33m[WARN]\033[0m No dotfiles repo configured")
    sys.exit(0)

if dry:
    print(f"\033[0;36m[INFO]\033[0m [DRY RUN] Would clone {repo} to {dotfiles_dir}")
    for src, dst in files.items():
        target = dst.replace("~", home)
        print(f"\033[0;36m[INFO]\033[0m [DRY RUN] Would symlink {src} -> {target}")
    sys.exit(0)

if not os.path.exists(dotfiles_dir):
    print(f"\033[0;36m[INFO]\033[0m Cloning dotfiles from {repo}...")
    subprocess.run(["git", "clone", repo, dotfiles_dir], check=True)
else:
    print(f"\033[0;32m[ OK ]\033[0m Dotfiles repo already cloned")
    subprocess.run(["git", "-C", dotfiles_dir, "pull", "--ff-only"], check=False)

for src, dst in files.items():
    source = os.path.join(dotfiles_dir, src)
    target = dst.replace("~", home)

    if not os.path.exists(source):
        print(f"\033[1;33m[WARN]\033[0m Source not found: {source}")
        continue

    target_dir = os.path.dirname(target)
    os.makedirs(target_dir, exist_ok=True)

    if os.path.islink(target):
        os.remove(target)
    elif os.path.exists(target):
        backup = target + ".backup"
        os.rename(target, backup)
        print(f"\033[0;36m[INFO]\033[0m Backed up {target} -> {backup}")

    os.symlink(source, target)
    print(f"\033[0;32m[ OK ]\033[0m {src} -> {target}")
PYEOF
}

# ─────────────────────────────────────────────────────────────────
# Phase 6: Clone repos
# ─────────────────────────────────────────────────────────────────
phase6_clone() {
  header "Phase 6: Clone repos"

  if [[ ! -f "$REPOS_CFG" ]]; then
    warn "No repos.json found, skipping clone phase"
    return
  fi

  local prefer_ssh="False"
  local ssh_key_path="$HOME/.ssh/id_ed25519"
  [[ ! -f "$ssh_key_path" ]] && ssh_key_path="$HOME/.ssh/id_rsa"
  if [[ -f "$ssh_key_path" ]] && command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
      prefer_ssh="True"
      info "SSH key found + gh authenticated, using SSH URLs for cloning"
    fi
  fi

  local clone_output
  clone_output=$(python3 << PYEOF
import json, os, subprocess

with open("$REPOS_CFG") as f:
    repos = json.load(f).get("repos", [])

workspace = "$WORKSPACE"
dry = $( $DRY_RUN && echo "True" || echo "False" )
prefer_ssh = $prefer_ssh
os.makedirs(workspace, exist_ok=True)

for repo in repos:
    owner = repo["owner"]
    name = repo["name"]
    required = repo.get("required", False)
    shallow = repo.get("shallow", False)
    desc = repo.get("description", "")
    if prefer_ssh:
        url = f"git@github.com:{owner}/{name}.git"
    else:
        url = f"https://github.com/{owner}/{name}.git"
    dest = os.path.join(workspace, name)

    if os.path.exists(dest):
        result = subprocess.run(["git", "-C", dest, "pull", "--ff-only"], capture_output=True, text=True)
        if result.returncode == 0:
            print(f"\033[0;32m[ OK ]\033[0m {name} updated (git pull)")
        else:
            print(f"\033[1;33m[WARN]\033[0m {name} pull skipped (may have local changes)")
        continue

    if dry:
        depth = " (shallow)" if shallow else ""
        print(f"\033[0;36m[INFO]\033[0m [DRY RUN] Would clone {owner}/{name}{depth}")
        continue

    cmd = ["git", "clone"]
    if shallow:
        cmd += ["--depth", "1"]
    cmd += [url, dest]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        print(f"\033[0;32m[ OK ]\033[0m Cloned {name}")
        print(f"@@CLONED@@{name}")

        pkg_json = os.path.join(dest, "package.json")
        req_txt = os.path.join(dest, "requirements.txt")
        if os.path.exists(pkg_json):
            print(f"\033[0;36m[INFO]\033[0m Running npm install in {name}...")
            subprocess.run(["npm", "install"], cwd=dest, capture_output=True)
        if os.path.exists(req_txt):
            print(f"\033[0;36m[INFO]\033[0m Running pip install in {name}...")
            subprocess.run(["pip3", "install", "-r", req_txt], cwd=dest, capture_output=True)
    else:
        if required:
            print(f"\033[0;31m[FAIL]\033[0m Required repo {name} failed to clone")
        else:
            print(f"\033[1;33m[WARN]\033[0m Skipped {name} (private or 404)")
        print(f"@@SKIPPED@@{name}")
PYEOF
  )

  echo "$clone_output" | grep -v "^@@" || true
  while IFS= read -r line; do
    local rname="${line#@@CLONED@@}"
    SUMMARY_REPOS_CLONED+=("$rname")
  done < <(echo "$clone_output" | grep "^@@CLONED@@" || true)
  while IFS= read -r line; do
    local rname="${line#@@SKIPPED@@}"
    SUMMARY_REPOS_SKIPPED+=("$rname")
  done < <(echo "$clone_output" | grep "^@@SKIPPED@@" || true)
}

# ─────────────────────────────────────────────────────────────────
# Phase 7: Verify
# ─────────────────────────────────────────────────────────────────
phase7_verify() {
  header "Phase 7: Verify"

  info "Checking installed tools..."
  local pass_count=0
  local fail_count=0

  for tid in "${SELECTED_TOOLS[@]}"; do
    local cmd_name
    cmd_name=$(python3 -c "
import json
with open('$CATALOG') as f: cat = json.load(f)
for t in cat['tools']:
    if t['id'] == $tid:
        print(t['cmd'])
        break
")
    local tool_name
    tool_name=$(python3 -c "
import json
with open('$CATALOG') as f: cat = json.load(f)
for t in cat['tools']:
    if t['id'] == $tid:
        print(t['name'])
        break
")

    if command -v "$cmd_name" &>/dev/null; then
      local ver
      ver=$("$cmd_name" --version 2>&1 | head -1 | cut -c1-60 || echo "ok")
      ok "$tool_name: $ver"
      (( pass_count++ ))
    else
      fail "$tool_name: not found on PATH"
      (( fail_count++ ))
    fi
  done

  divider
  info "Functional tests..."

  if command -v git &>/dev/null; then
    local git_user
    git_user=$(git config --global user.name 2>/dev/null || echo "")
    if [[ -n "$git_user" ]]; then
      ok "git config: $git_user"
    else
      warn "git config: no user.name set"
    fi
  fi

  if command -v python3 &>/dev/null; then
    local py_test
    py_test=$(python3 -c "import json, os, sys; print(f'python3 OK, {sys.version.split()[0]}')" 2>&1 || echo "FAIL")
    if [[ "$py_test" == *"OK"* ]]; then
      ok "Python import test: $py_test"
    else
      warn "Python import test: $py_test"
    fi
  fi

  if command -v node &>/dev/null; then
    local node_test
    node_test=$(node -e "console.log('node OK, ' + process.version)" 2>&1 || echo "FAIL")
    if [[ "$node_test" == *"OK"* ]]; then
      ok "Node.js test: $node_test"
    else
      warn "Node.js test: $node_test"
    fi
  fi

  if command -v ollama &>/dev/null && [[ ${#SELECTED_MODELS[@]} -gt 0 ]]; then
    info "Ollama inference test..."
    local first_model
    first_model=$(python3 -c "
import json
with open('$CATALOG') as f: cat = json.load(f)
for m in cat['models']:
    if m['id'] == ${SELECTED_MODELS[0]}:
        if m['size'] != 'cloud': print(m['name'])
        break
")
    if [[ -n "$first_model" ]]; then
      local t_start t_end
      t_start=$(python3 -c "import time; print(time.time())")
      local inference_out
      inference_out=$(ollama run "$first_model" "Say hello in exactly 5 words" 2>&1 | head -3 || echo "FAIL")
      t_end=$(python3 -c "import time; print(time.time())")
      local elapsed
      elapsed=$(python3 -c "print(f'{$t_end - $t_start:.1f}')")
      if [[ "$inference_out" != "FAIL" ]]; then
        ok "Ollama inference ($first_model): ${elapsed}s"
      else
        warn "Ollama inference test failed for $first_model"
      fi
    fi
  fi

  if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    ok "SSH key exists: ~/.ssh/id_ed25519"
  fi

  divider
  ok "Passed: $pass_count, Failed: $fail_count"
}

# ─────────────────────────────────────────────────────────────────
# Update mode
# ─────────────────────────────────────────────────────────────────
run_update() {
  header "Update mode"

  info "Self-updating startupjet..."
  if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    git -C "$SCRIPT_DIR" pull --ff-only && ok "startupjet updated" || warn "Self-update failed (not a git repo?)"
  fi

  if [[ "$OS" == "macos" ]] && command -v brew &>/dev/null; then
    info "Updating Homebrew packages..."
    brew update && brew upgrade
    ok "Homebrew packages updated"
  fi

  if [[ "$OS" == "linux" ]]; then
    info "Updating apt packages..."
    sudo apt update -qq && sudo apt upgrade -y
    ok "Apt packages updated"
  fi

  if command -v npm &>/dev/null; then
    info "Updating global npm packages..."
    npm update -g
    ok "npm packages updated"
  fi

  if command -v ollama &>/dev/null; then
    info "Pulling latest Ollama models..."
    ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r model; do
      [[ -z "$model" ]] && continue
      info "Pulling $model..."
      ollama pull "$model" && ok "$model updated" || warn "Failed to pull $model"
    done
  fi

  ok "Update complete"
}

# ─────────────────────────────────────────────────────────────────
# Dry run summary
# ─────────────────────────────────────────────────────────────────
print_dry_run_summary() {
  header "Dry Run Summary"
  info "Platform: $OS ($(uname -m))"
  info "Hardware: ${RAM_GB} GB RAM, ${VRAM_GB} GB VRAM, ${DISK_FREE_GB} GB disk free"

  echo ""
  info "Would install tools:"
  for tid in "${SELECTED_TOOLS[@]}"; do
    python3 -c "
import json
with open('$CATALOG') as f: cat = json.load(f)
for t in cat['tools']:
    if t['id'] == $tid:
        inst = t.get('install',{}).get('$OS',{})
        print(f'    {t[\"name\"]:20s} via {inst.get(\"method\",\"?\")}')
        break
"
  done

  if [[ ${#SELECTED_MODELS[@]} -gt 0 ]]; then
    echo ""
    info "Would pull models:"
    for mid in "${SELECTED_MODELS[@]}"; do
      python3 -c "
import json
with open('$CATALOG') as f: cat = json.load(f)
for m in cat['models']:
    if m['id'] == $mid:
        print(f'    {m[\"name\"]:20s} ({m[\"size\"]})')
        break
"
    done
  fi

  echo ""
  $INSTALL_AUTH_GH && info "Would authenticate: GitHub CLI"
  $INSTALL_AUTH_TS && info "Would authenticate: Tailscale"
  $INSTALL_AUTH_CF && info "Would authenticate: Cloudflare"
  $GENERATE_SSH && info "Would generate SSH key"
  $INSTALL_EXTENSIONS && info "Would install VS Code extensions"
  $APPLY_DOTFILES && info "Would apply dotfiles"
  info "Workspace: $WORKSPACE"

  echo ""
  info "Repos to clone:"
  python3 -c "
import json
with open('$REPOS_CFG') as f: repos = json.load(f).get('repos', [])
for r in repos:
    depth = ' (shallow)' if r.get('shallow') else ''
    req = ' [required]' if r.get('required') else ''
    print(f'    {r[\"owner\"]}/{r[\"name\"]}{depth}{req}')
"

  divider
  info "No changes were made. Remove --dry-run to execute."
}

# ─────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────
main() {
  log "${BOLD}startupjet v$VERSION${NC} - $(date)"
  log "Platform: $OS ($(uname -m))"
  echo ""

  START_TIME=$(date +%s)

  if $UPDATE; then
    phase1_scan
    run_update
    return
  fi

  phase1_scan
  phase2_choose

  if $DRY_RUN; then
    print_dry_run_summary
    return
  fi

  log ""
  log "${BOLD}From here on, everything runs unattended.${NC}"
  log ""

  phase3_auth
  phase4_configure

  # Save user config snapshot
  python3 << PYEOF
import json, datetime
cfg = {
    "workspace": "$WORKSPACE",
    "githubUser": "$GH_USER",
    "gitEmail": "$GIT_EMAIL",
    "os": "$OS",
    "timestamp": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
}
with open("$CONFIG_DIR/user-config.json", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
  ok "Config saved to $CONFIG_DIR/user-config.json"

  phase5_install
  phase5_dotfiles
  phase6_clone

  # Post-clone integration: jet-rules + extended rules + workspace setup

  # Layer 1: jet-rules (universal open-source rules)
  local jet_rules_dir="$WORKSPACE/jet-rules"
  if [[ -f "$jet_rules_dir/rules.md" ]]; then
    cp "$jet_rules_dir/rules.md" "$WORKSPACE/jet-rules.md"
    ok "jet-rules.md copied to $WORKSPACE/jet-rules.md"
  fi

  # Layer 2: extended rules (from jet-rules/config.json -> extended.repo)
  if [[ -f "$jet_rules_dir/config.json" ]]; then
    local ext_file ext_repo_name ext_source
    ext_file=$(python3 -c "import json; print(json.load(open('$jet_rules_dir/config.json')).get('extended',{}).get('file',''))" 2>/dev/null || echo "")
    ext_repo_name=$(python3 -c "import json; print(json.load(open('$jet_rules_dir/config.json')).get('extended',{}).get('repo','').split('/')[-1])" 2>/dev/null || echo "")
    if [[ -n "$ext_file" && -n "$ext_repo_name" ]]; then
      ext_source="$WORKSPACE/$ext_repo_name/$ext_file"
      if [[ -f "$ext_source" ]]; then
        cp "$ext_source" "$WORKSPACE/$ext_file"
        ok "$ext_file (extended rules) copied to $WORKSPACE/$ext_file"
      fi
    fi
  fi

  # Workspace support folders
  if [[ ! -d "$WORKSPACE/.history" ]]; then
    mkdir -p "$WORKSPACE/.history"
    ok "Created $WORKSPACE/.history for conversation logging"
  fi

  phase7_verify

  local elapsed=$(( $(date +%s) - START_TIME ))
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))

  # Clean up progress file on successful run
  if [[ ${#SUMMARY_FAILED[@]} -eq 0 && -f "$PROGRESS_FILE" ]]; then
    rm -f "$PROGRESS_FILE"
    info "Progress file cleaned up (all items completed)"
  elif [[ ${#SUMMARY_FAILED[@]} -gt 0 && -f "$PROGRESS_FILE" ]]; then
    warn "Some items failed. Re-run ./startupjet.sh to retry (progress saved)."
  fi

  header "Summary"
  echo ""
  local join_installed; join_installed=$(IFS=', '; echo "${SUMMARY_INSTALLED[*]}")
  local join_already;   join_already=$(IFS=', '; echo "${SUMMARY_ALREADY[*]}")
  local join_models;    join_models=$(IFS=', '; echo "${SUMMARY_MODELS[*]}")
  local join_ext;       join_ext=$(IFS=', '; echo "${SUMMARY_EXTENSIONS[*]}")
  local join_failed;    join_failed=$(IFS=', '; echo "${SUMMARY_FAILED[*]}")
  local join_auth;      join_auth=$(IFS=', '; echo "${SUMMARY_AUTH[*]}")
  local join_cloned;    join_cloned=$(IFS=', '; echo "${SUMMARY_REPOS_CLONED[*]}")
  local join_skipped;   join_skipped=$(IFS=', '; echo "${SUMMARY_REPOS_SKIPPED[*]}")

  echo "  Installed:        ${join_installed:-(none)}"
  echo "  Already had:      ${join_already:-(none)}"
  echo "  Models loaded:    ${join_models:-(none)}"
  echo "  Extensions:       ${join_ext:-(none)}"
  echo "  Failed:           ${join_failed:-(none)}"
  echo "  Authenticated:    ${join_auth:-(none)}"
  echo "  Repos cloned:     ${join_cloned:-(none)}"
  echo "  Repos skipped:    ${join_skipped:-(none)}"
  echo ""
  ok "Total time: ${mins}m ${secs}s"
  ok "Workspace: $WORKSPACE"
  ok "Log: $LOG_FILE"
  echo ""
  info "Next steps:"
  echo "  1. Open a new terminal to pick up PATH changes"
  echo "  2. Run 'cd $WORKSPACE' to start working"
  if [[ -n "$GH_USER" ]]; then
    echo "  3. Verify: gh repo list $GH_USER --limit 5"
  fi

  local ai_journal="$WORKSPACE/ai-journal"
  if [[ -d "$ai_journal" ]]; then
    echo ""
    info "Now in any AI chat, paste this:"
    echo ""
    echo "  Read $ai_journal/UPDATE.md and follow it."
    echo ""
  fi
}

main
