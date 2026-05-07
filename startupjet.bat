@echo off
REM startupjet entry point. Runs the PowerShell orchestrator with execution policy bypass.
REM Usage:
REM   startupjet.bat                       Interactive install (default)
REM   startupjet.bat install               Same as above
REM   startupjet.bat fix                   Audit + offer to consolidate cross-account waste
REM   startupjet.bat doctor                Read-only health check
REM   startupjet.bat update                Upgrade installed tools
REM   startupjet.bat help                  Show full help
REM
REM PC type:
REM   startupjet.bat install -FullDev      Cross-account install (Machine scope)
REM   startupjet.bat install -Shared       Per-account install only
REM
REM Non-interactive:
REM   startupjet.bat install -FullDev -Yes  Accept all defaults

cd /d "%~dp0"
echo.
echo ============================================
echo  startupjet, fresh-PC bootstrap
echo ============================================
echo.

REM Prefer PowerShell 7 (pwsh) if available, fall back to Windows PowerShell 5.1
where pwsh >nul 2>&1
if not errorlevel 1 (
  echo Using PowerShell 7
  pwsh -ExecutionPolicy Bypass -NoProfile -File "%~dp0startupjet.ps1" %*
  goto :done
)

where powershell >nul 2>&1
if errorlevel 1 (
  echo ERROR: PowerShell not found. This script requires Windows PowerShell 5.1+.
  pause
  exit /b 1
)

echo Using Windows PowerShell 5.1
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0startupjet.ps1" %*

:done
echo.
echo Done. Check the log file for details.
pause
