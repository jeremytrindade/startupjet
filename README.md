# startupjet

> One-click bootstrap for a developer workstation that follows the [Jeremy Trindade infra patterns](https://github.com/jeremytrindade). Fork it, edit `config/repos.json`, run, done.

## What it does

On a fresh Windows PC:

1. **Scans** your system for 16 tools across dev, network, AI coding, and local AI categories.
2. **Asks everything upfront**: install all, all except local AI, or customize per-tool. Plus auth choices and workspace config.
3. **Authenticates** GitHub, Tailscale, Cloudflare (interactive browser flows, done early).
4. **Installs** everything you selected via winget, npm, and ollama pull. Fully unattended from here.
5. **Clones** a configured list of repos (skipping private ones you do not have access to).
6. **Verifies** every tool is on PATH with version check, runs a smoke test.
7. **Reports** total time + what to do next.

After answering the initial questions (~2 min), you can walk away. Come back to a fully configured PC.

## Available tools

| Category | Tools |
|----------|-------|
| Dev tools | Git, GitHub CLI, Python 3, PowerShell 7, OpenSSH, Node.js, VS Code |
| Network | Tailscale, cloudflared |
| AI coding assistants | Claude Code, OpenAI Codex |
| Local AI (GPU) | Ollama, uv, llama3.1:8b (4.9 GB), qwen2.5:7b (4.7 GB), mistral:7b (4.1 GB) |

## Quick start

1. Download this repo as ZIP, OR `gh repo clone jeremytrindade/startupjet`.
2. Extract anywhere.
3. Double-click `startupjet.bat`.
4. Answer the setup questions (install mode, auth, workspace path).
5. Walk away. Come back when it is done.

## Requirements

- Windows 10 / 11 with PowerShell 5.1 or higher (default on modern Windows).
- An internet connection.
- A GitHub account (for `gh auth login`).
- Optional: Tailscale, Cloudflare accounts if you want those configured.
- Optional: GPU with 8GB+ VRAM for local AI models.

## Customize for your own setup

Fork this repo, edit:

- `config/repos.json` to set your own repos to clone.

## How it works

- `startupjet.bat` calls `startupjet.ps1` with `-ExecutionPolicy Bypass` so PowerShell does not block.
- `startupjet.ps1` is the single orchestrator that runs 7 phases: scan, choose, auth, configure, install, clone, verify.
- All questions are asked in Phase 2. From Phase 5 onward, everything runs unattended.
- All logic is in PowerShell (Windows-only via winget).

## License

MIT, see [LICENSE](LICENSE).

## Status

v1.1 (2026-05-06). Tested on Windows 11. Pull requests welcome.
