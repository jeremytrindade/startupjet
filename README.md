# startupjet

> One tool to set up and maintain a developer workstation. Windows-first, macOS and Linux supported. Fork it, edit the `config/` files, run, done.

## Verbs

`startupjet` is structured like `brew` or `scoop`: one tool, multiple verbs.

| Verb | What it does |
|---|---|
| `install` (default) | Set up this account / PC: scan, install, auth, configure, clone repos. |
| `fix` | Walk every Windows account, find duplicate Ollama models / npm globals / uv cache / pip cache, offer to consolidate them into shared locations on the largest non-system disk. Cross-account aware. |
| `doctor` | Read-only health check. Same audit as `fix`, no apply prompts. |
| `update` | Upgrade installed tools to their latest versions. |
| `help` | Show usage. |

```bat
startupjet                       :: interactive install
startupjet fix -FullDev          :: consolidate cross-account waste
startupjet doctor                :: are things okay? (no changes)
startupjet update                :: upgrade everything
startupjet install -FullDev -Yes :: unattended, cross-account install
```

## PC type

The first time you run `install` or `fix`, it asks how this PC is used. The answer is persisted to `config/user-config.json` so it does not ask again.

| Choice | Meaning |
|---|---|
| Full developer PC | All accounts on this PC are you. Sets Machine-wide env vars (`OLLAMA_MODELS`, `NPM_CONFIG_PREFIX`, `UV_CACHE_DIR`, `PIP_CACHE_DIR`), grants `BUILTIN\Users` Modify on the shared dirs, migrates other accounts' caches. Needs admin to land Machine-scope changes. |
| Shared PC | Other people use this. Per-account installs only. Machine-wide settings never written. Other accounts' folders never touched. |

## What it does

On a fresh PC (any OS):

1. **Scans** your system for 14 tools across dev, network, AI coding, and local AI categories. Detects GPU, RAM, disk, and runs a speed test for accurate time estimates.
2. **Asks everything upfront**: pick a preset (Minimal dev, Developer, Full setup, AI workstation) or choose Custom. One choice replaces 8 questions.
3. **Authenticates** GitHub, Tailscale, Cloudflare (interactive browser flows, done early).
4. **Configures** git identity, restores SSH key from vault or generates a new one (adds to GitHub), applies dev settings, saves config.
5. **Installs** everything you selected via winget/brew/apt, npm, and ollama pull. Fully unattended from here. Progress saved after each item for resume on failure.
6. **Applies dotfiles** from your configured dotfiles repo (symlinks on macOS/Linux, copies on Windows).
7. **Clones** a configured list of repos (skipping private ones you do not have access to). Auto-runs npm install / pip install for cloned repos.
8. **Verifies** every tool on PATH with version check, runs functional tests (Python imports, Node.js, Ollama inference), reports total time.

After answering the initial questions (~2 min), you can walk away. Come back to a fully configured PC.

## Available tools

| Category | Tools |
|----------|-------|
| Dev tools | Git, GitHub CLI, Python 3, PowerShell 7 (Windows), Node.js, OpenSSH, VS Code |
| Network | Tailscale, cloudflared |
| AI coding assistants | Claude Code, OpenAI Codex |
| Local AI (GPU) | Ollama, uv, llama3.1:8b (4.9 GB), qwen2.5:7b (4.7 GB), mistral:7b (4.1 GB), deepseek-r1:14b (9 GB), qwen3:30b-a3b (18 GB, MoE) |
| Larger models (16+ GB VRAM) | gemma4:31b (19 GB) |
| Cloud models (Ollama cloud) | kimi-k2.6:cloud (no local GPU needed) |
| Optional | Bitwarden CLI (vault integration for SSH keys) |

## Quick start

### Windows

1. Download this repo as ZIP, OR `gh repo clone jeremytrindade/startupjet`.
2. Extract anywhere.
3. Double-click `startupjet.bat`.
4. Pick a preset or choose Custom.
5. Walk away. Come back when it is done.

### macOS / Linux

```bash
git clone https://github.com/jeremytrindade/startupjet.git
cd startupjet
chmod +x startupjet.sh
./startupjet.sh
```

## Update installed tools

```
# Windows
startupjet.bat -Update

# macOS / Linux
./startupjet.sh --update
```

Pulls the latest startupjet repo (self-update), then runs winget/brew/apt upgrade, npm update, and ollama pull for each detected tool. No questions asked.

## Dry run

```
# Windows
startupjet.bat -DryRun

# macOS / Linux
./startupjet.sh --dry-run
```

Shows exactly what would be installed, configured, and cloned without making any changes. Useful for testing on an already-configured PC.

## Features

- **Cross-platform**: Windows (winget), macOS (Homebrew), Linux (apt). Single config, three runners.
- **Preset profiles**: Minimal dev, Developer, Full setup, or AI workstation. One choice replaces 8 questions.
- **Install scope** (Windows): current user only or all users (winget `--scope user` vs `--scope machine`).
- **Log file**: all output saved to `startupjet-YYYY-MM-DD-HHmm.log` automatically.
- **SSH key from vault**: if Bitwarden CLI is installed and unlocked, restores existing SSH keys from your vault. Falls back to generating a new ed25519 key.
- **Dotfiles management**: clone your dotfiles repo and symlink/copy files to the right places. Configure in `config/dotfiles.json`.
- **Resume on failure**: progress saved to `config/progress.json` after each install. Re-run to pick up where it left off.
- **VS Code extensions**: auto-installs extensions from `config/vscode-extensions.json`.
- **Windows dev settings**: optionally enables Developer Mode, shows file extensions, shows hidden files.
- **Post-clone dependency install**: detects `package.json` and `requirements.txt` in cloned repos, runs npm install / pip install automatically.
- **Shallow clone**: repos marked `"shallow": true` in `config/repos.json` are cloned with `--depth 1`.
- **Hardware detection**: GPU (nvidia-smi, WMI, system_profiler), RAM, disk. Clear READY/POSSIBLE/NOT RECOMMENDED verdict for local AI.
- **Smart model recommendations**: scores all models against your VRAM, RAM, and disk, suggests the 3 best-fit.
- **Functional tests**: Phase 7 runs Python import test, Node.js test, Ollama inference test (with timing), git identity check.
- **Speed test**: downloads a 5 MB file from Cloudflare CDN to estimate total install time.

## Customize for your own setup

Fork this repo and edit the files in `config/`. The scripts read everything from config, so you never need to touch the engine code.

| File | What to edit |
|------|-------------|
| `config/defaults.json` | Your workspace path, GitHub username, git email |
| `config/repos.json` | Your repos to clone. Mark required repos, set shallow clone |
| `config/vscode-extensions.json` | Your VS Code extensions |
| `config/dotfiles.json` | Your dotfiles repo URL and file mappings |
| `config/catalog.json` | Add or remove tools. Each tool has install methods per OS |

The `config/` folder is the only thing you need to change. Everything else is the engine that reads it.

### Setting your workspace path

Edit `config/defaults.json` to set where repos are cloned and tools are configured:

```json
{
  "workspacePath": "D:\\aijetlabs",
  "workspacePathUnix": "~/workspace",
  "githubUser": "your-username",
  "gitEmail": "your@email.com"
}
```

- `workspacePath` is used on Windows. Repos go into `<workspacePath>\github\`.
- `workspacePathUnix` is used on macOS/Linux. `~` expands to your home directory.
- During setup you can also override the path interactively when prompted.

## Requirements

### Windows
- Windows 10 / 11 with PowerShell 5.1+ (default on modern Windows).
- An internet connection.

### macOS
- macOS 12+ with python3 (ships with Xcode CLT).
- Homebrew will be installed automatically if missing.

### Linux
- Ubuntu/Debian with python3 (pre-installed on most distros).
- An internet connection. Some tools need sudo.

### All platforms
- A GitHub account (for `gh auth login`).
- Optional: Tailscale, Cloudflare accounts if you want those configured.
- Optional: GPU with 8GB+ VRAM for local AI models.
- Optional: Bitwarden CLI for vault-based SSH key restore.

## How it works

```
Windows: startupjet.bat [-Update] [-DryRun]
  -> powershell/pwsh -ExecutionPolicy Bypass -File startupjet.ps1
    -> Phase 1: Scan (hardware + speed test + tools)
    -> Phase 2: Choose (preset or custom)
    -> Phase 3: Authenticate (gh, tailscale, cloudflared)
    -> Phase 4: Configure (git, SSH key/vault, dev settings)
    ---- no more user input after this ----
    -> Phase 5: Install (winget + npm + ollama + extensions)
    -> Phase 5.5: Dotfiles (clone + copy)
    -> Phase 6: Clone repos (from config/repos.json)
    -> Phase 7: Verify (PATH check + functional tests + timing)

macOS/Linux: ./startupjet.sh [--update] [--dry-run]
  -> Same 7-phase flow using brew (macOS) or apt (Linux)
  -> Reads the same config/ files
  -> Dotfiles use symlinks instead of copies
```

## License

MIT, see [LICENSE](LICENSE).

## Status

v1.2 (2026-05-06). Tested on Windows 11. macOS and Linux support added. Pull requests welcome.
