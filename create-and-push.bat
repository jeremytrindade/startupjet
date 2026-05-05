@echo off
cd /d D:\claudeui\github\startupjet

echo.
echo === Creating jeremytrindade/startupjet on GitHub ===
gh repo create jeremytrindade/startupjet --public --description "One-click bootstrap for a fresh Windows PC. Detects, installs, authenticates, configures workspace, clones repos. Fork to adapt for your own infra."
if errorlevel 1 echo (repo may already exist, continuing)

echo.
echo === Initialising local git repo ===
git init
git branch -m main
git add .
git commit -m "Initial commit: startupjet MVP (single-file orchestrator + bat + README + index.html)"

echo.
echo === Setting remote and pushing ===
git remote add origin https://github.com/jeremytrindade/startupjet.git
git push -u origin main

echo.
echo === Done! Repo live at: https://github.com/jeremytrindade/startupjet ===
pause
