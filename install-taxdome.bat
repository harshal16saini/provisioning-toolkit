@echo off
:: Self-elevate to admin, preserving the launch folder
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs -ArgumentList '%~dp0'"
    exit /b
)

:: %~1 is the launch folder passed through elevation; fallback to current dir
set "LAUNCHDIR=%~1"
if "%LAUNCHDIR%"=="" set "LAUNCHDIR=%~dp0"

echo Running installer...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:TD_LAUNCHDIR='%LAUNCHDIR%'; irm https://raw.githubusercontent.com/harshal16saini/provisioning-toolkit/main/install-taxdome.ps1 | iex"
