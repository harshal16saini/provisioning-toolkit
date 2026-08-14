@echo off
:: Self-elevate to admin (fltmc, not net session, to avoid a relaunch loop)
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo Downloading installer...
powershell -NoProfile -Command "New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $u='https://raw.githubusercontent.com/harshal16saini/provisioning-toolkit/main/install-taxdome.ps1'; $o='C:\Temp\install-taxdome.ps1'; $c=Join-Path $env:SystemRoot 'System32\curl.exe'; if (Test-Path $c) { & $c -L -s -o $o $u } else { Invoke-WebRequest -UseBasicParsing $u -OutFile $o }"

if not exist "C:\Temp\install-taxdome.ps1" (
    echo Download failed - check network / EDR policy. & pause & exit /b
)

echo Running installer...
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Temp\install-taxdome.ps1"

del "C:\Temp\install-taxdome.ps1" >nul 2>&1
echo.
pause
