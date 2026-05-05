# startupjet

> One-click bootstrap for a developer workstation that follows the [Jeremy Trindade infra patterns](https://github.com/jeremytrindade). Fork it, edit `config/repos.json` and `config/prerequisites.json`, run, done.

## What it does

On a fresh Windows PC, in 5 to 10 minutes:

1. Detects missing tools (git, gh, Python, PowerShell 7, OpenSSH, Tailscale, cloudflared, Node.js).
2. Installs them via winget.
3. Authenticates GitHub, Tailscale, Cloudflare interactively.
4. Asks where to put your workspace folder.
5. Clones a configured list of repos (skipping private ones you do not have access to).
6. Verifies everything works with a smoke test.
7. Tells you the canonical AI prompt to use for journaling future work.

## Quick start

1. Download this repo as ZIP, OR `gh repo clone jeremytrindade/startupjet`.
2. Extract anywhere.
3. Double-click `startupjet.bat`.
4. Follow the prompts.

## Requirements

- Windows 10 / 11 with PowerShell 5.1 or higher (default on modern Windows).
- An internet connection.
- A GitHub account (for `gh auth login`).
- Optional: Tailscale, Cloudflare accounts if you want those configured.

## Customize for your own setup

Fork this repo, edit:

- `config/prerequisites.json` to add or remove tools.
- `config/repos.json` to set your own repos to clone.
- `config/defaults.json` to change default workspace path / folder name.

## How it works

- `startupjet.bat` calls `startupjet.ps1` with `-ExecutionPolicy Bypass` so PowerShell does not block.
- `startupjet.ps1` is the single orchestrator that runs the 6 phases.
- All logic is in PowerShell (cross-platform-ish, but currently Windows-only via winget).

## License

MIT, see [LICENSE](LICENSE).

## Status

v1.0 (2026-05-05). Tested on Windows 11. Pull requests welcome.
