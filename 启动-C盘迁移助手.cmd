@echo off
rem ============================================================
rem  C-Drive Migration Assistant - launcher
rem  Just double-click this file.
rem ============================================================
setlocal
set "SCRIPT=%~dp0MigrateGui.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] MigrateGui.ps1 not found next to this launcher.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if errorlevel 1 (
    echo.
    echo [HINT] If it failed to start, try running as Administrator,
    echo        or run this in PowerShell:
    echo        powershell -ExecutionPolicy Bypass -File "%SCRIPT%"
    pause
)
endlocal
