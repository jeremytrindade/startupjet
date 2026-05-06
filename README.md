# startupjet

> One-click bootstrap for a developer workstation that follows the [Jeremy Trindade infra patterns](https://github.com/jeremytrindade). Fork it, edit `config/repos.json`, run, done.

## What it does

On a fresh Windows PC:

1. **Scans** your system for 19 tools across dev, network, AI coding, and local AI categories. Detects GPU, RAM, disk, and runs a speed test for accurate time estimates.
2. **Asks everything upfront**: install mode, install scope (current user or all users), auth choices, SSH key, Windows dev settings, VS Code extensions, and workspace config.
3. **Authenticates** GitHub, Tailscale, Cloudflare (interactive browser flows, done early).
4. **Configures** git identity, generates SSH key (optionally adds to GitHub), applies Windows dev settings, saves config.
5. **Installs** everything you selected via winget, npm, and ollama pull. Fully unattended from here. Progress saved after each item for resume on failure.
6. **Clones** a configured list of repos (skipping private ones you do not have access to).
7. **Verifies** every tool is on PATH with version check, runs a smoke test.
8. **Reports** total time, what was installed, and what to do next.

After answering the initial questions (~2 min), you can walk away. Come back to a fully configured PC.

## Available tools

| Category | Tools |
|----------|-------|
| Dev tools | Git, GitHub CLI, Python 3, PowerShell 7, OpenSSH, Node.js, VS Code |
| Network | Tailscale, cloudflared |
| AI coding assistants | Claude Code, OpenAI Codex |
| Local AI (GPU) | Ollama, uv, llama3.1:8b (4.9 GB), qwen2.5:7b (4.7 GB), mistral:7b (4.1 GB), deepseek-r1:14b (9 GB) |
| Larger models (16+ GB VRAM) | gemma4:31b (19 GB) |
| Cloud models (Ollama cloud) | kimi-k2.6:cloud (no local GPU needed) |

## Quick start

1. Download this repo as ZIP, OR `gh repo clone jeremytrindade/startupjet`.
2. Extract anywhere.
3. Double-click `startupjet.bat`.
4. Answer the setup questions (install mode, scope, auth, SSH key, dev settings, workspace path).
5. Walk away. Come back when it is done.

## Update installed tools

Run `startupjet.bat -Update` to upgrade all installed tools to their latest versions. Runs winget upgrade, npm update, and ollama pull for each detected tool. No questions asked.

## Features

- **Install scope**: choose to install for current user only or all users on the PC (winget `--scope user` vs `--scope machine`).
- **Log file**: all output saved to `startupjet-YYYY-MM-DD-HHmm.log` automatically.
- **SSH key generation**: detects `~/.ssh/id_ed25519`, offers to generate ed25519 key and add it to GitHub via `gh ssh-key add`.
- **Resume on failure**: progress saved to `config/progress.json` after each install. Re-run to pick up where it left off.
- **VS Code extensions**: auto-installs extensions from `config/vscode-extensions.json` (editable).
- **Windows dev settings**: optionally enables Developer Mode, shows file extensions, shows hidden files.
- **Hardware detection**: GPU (nvidia-smi or WMI), RAM, disk. Clear READY/POSSIBLE/NOT RECOMMENDED verdict for local AI.
- **Speed test**: downloads a 5 MB file from Cloudflare CDN to estimate total install time.
- **Update mode**: `startupjet.bat -Update` upgrades everything already installed.

## Requirements

- Windows 10 / 11 with PowerShell 5.1 or higher (default on modern Windows).
- An internet connection.
- A GitHub account (for `gh auth login`).
- Optional: Tailscale, Cloudflare accounts if you want those configured.
- Optional: GPU with 8GB+ VRAM for local AI models.

## Customize for your own setup

Fork this repo, edit:

- `config/repos.json` to set your own repos to clone.
- `config/vscode-extensions.json` to set your own VS Code extensions.
- `config/defaults.json` to change default workspace path and folder name.

## How it works

- `startupjet.bat` calls `startupjet.ps1` with `-ExecutionPolicy Bypass` so PowerShell does not block.
- `startupjet.ps1` is the single orchestrator that runs 7 phases: scan, choose, auth, configure, install, clone, verify.
- All questions are asked in Phase 2. From Phase 5 onward, everything runs unattended.
- All logic is in PowerShell (Windows-only via winget).
- Pass `-Update` to upgrade all installed tools instead of fresh install.

## License

MIT, see [LICENSE](LICENSE).

## Status

v1.2 (2026-05-06). Tested on Windows 11. Pull requests welcome.
