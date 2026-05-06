@echo off
REM startupjet entry point. Runs the PowerShell orchestrator with execution policy bypass.
REM Usage:
REM   startupjet.bat              Normal install
REM   startupjet.bat -Update      Upgrade installed tools

cd /d "%~dp0"
echo.
echo ============================================
echo  startupjet, fresh-PC bootstrap
echo ============================================
echo.

REM Check PowerShell exists (it should, on any modern Windows)
where powershell >nul 2>&1
if errorlevel 1 (
  echo ERROR: PowerShell not found. This script requires Windows PowerShell 5.1+.
  pause
  exit /b 1
)

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0startupjet.ps1" %*
echo.
echo Done. Check the log file for details.
pause
