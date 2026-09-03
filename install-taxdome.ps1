$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Force TLS 1.2 for older hosts (Server 2016 / stock PS 5.1) ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Disable QuickEdit so a stray click can't freeze execution (best-effort; skipped in Constrained Language Mode) ---
try {
    $sig = @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleMode {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
'@
    Add-Type -TypeDefinition $sig
    $h = [ConsoleMode]::GetStdHandle(-10)
    $m = 0
    [void][ConsoleMode]::GetConsoleMode($h, [ref]$m)
    $m = $m -band (-bnot 0x0040)
    $m = $m -bor 0x0080
    [void][ConsoleMode]::SetConsoleMode($h, $m)
} catch { }

# --- Config ---
$version    = 'v4.8.2'
$minVersion = [version]'4.8.2.9467'   # the version this script installs; compare against this
$primary  = "https://files.taxdome.com/desktop/win/TaxDome_x64_Latest.exe"
$fallback = "https://github.com/harshal16saini/provisioning-toolkit/releases/download/$version/TaxDome_x64.exe"
$exe = "C:\Temp\TaxDome_x64.exe"
$log = "C:\Temp\td_install.log"

New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null

# --- Detect installed v4 app (NOT the v3 "TaxDome" entry) ---
# Query both hives in one call and force a single result (fixes double-emit bug).
function Get-TaxDomeV4 {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'TaxDome Desktop App x64' } |
        Select-Object -First 1
}

$installed = Get-TaxDomeV4

# --- Preserve the old (v3) shortcut before v4's installer overwrites it ---
# Spec: IF a v3 shortcut exists in Public Desktop -> rename to "TaxDome v3". Else do nothing.
# (The installer creates the new blue "TaxDome" shortcut in Public Desktop itself.)
function Protect-V3Shortcut {
    $pub = Join-Path $env:PUBLIC 'Desktop'
    $lnk = Join-Path $pub 'TaxDome.lnk'
    if (-not (Test-Path $lnk)) { return }   # nothing there -> do nothing

    # Read the shortcut's target (COM is blocked in Constrained Language Mode -> skip safely)
    try {
        $ws     = New-Object -ComObject WScript.Shell
        $target = $ws.CreateShortcut($lnk).TargetPath
    } catch { return }

    # Only rename if we can POSITIVELY confirm it points to the old v3 install
    if ($target -notlike 'C:\Program Files (x86)\TaxDome\*') {
        return   # v4 shortcut, unknown, or unreadable -> leave it alone
    }

    $keep = Join-Path $pub 'TaxDome v3.lnk'
    if (Test-Path $keep) { return }   # already preserved on an earlier run

    try {
        Rename-Item -Path $lnk -NewName 'TaxDome v3.lnk' -Force
        Write-Host "Old v3 shortcut preserved as 'TaxDome v3.lnk'" -ForegroundColor Green
    } catch {
        Write-Warning "Could not preserve v3 shortcut: $($_.Exception.Message)"
    }
}

# --- Decide what to do ---
$needInstall = $true
if ($installed) {
    $instVer = try { [version]$installed.DisplayVersion } catch { [version]'0.0.0.0' }
    Write-Host "Found TaxDome Desktop App x64 version $instVer"
    if ($instVer -ge $minVersion) {
        Write-Host "Installed version is same or newer. Skipping install." -ForegroundColor Green
        $needInstall = $false
    } else {
        Write-Host "Installed version is older. Will override." -ForegroundColor Yellow
    }
} else {
    Write-Host "TaxDome Desktop App x64 not found. Will install fresh."
}

# --- Install if needed ---
if ($needInstall) {
    Protect-V3Shortcut

    # CLM-safe download: native curl.exe if present (Server 2019+), else Invoke-WebRequest cmdlet.
    # Both work under AppLocker/WDAC Constrained Language Mode; System.Net.WebClient does NOT.
    function Get-Installer($url, $label) {
        Write-Host "Downloading from $label..."
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        if (Test-Path $curl) {
            & $curl -L -s -o $exe $url
            if ($LASTEXITCODE -ne 0) { throw "curl.exe exit $LASTEXITCODE" }
        } else {
            Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
        }
        # Validate: a real installer is tens of MB. A tiny file = error page / bad download.
        if (-not (Test-Path $exe) -or (Get-Item $exe).Length -lt 1MB) {
            throw "Downloaded file missing or too small (<1MB) - likely an error page, not the installer."
        }
    }

    try { Get-Installer $primary "TaxDome official" }
    catch {
        Write-Warning "Official source failed ($($_.Exception.Message)). Trying GitHub mirror..."
        try { Get-Installer $fallback "GitHub mirror" }
        catch {
            Write-Host "Both download sources failed. Aborting. $($_.Exception.Message)" -ForegroundColor Red
            Start-Sleep -Seconds 10
            return
        }
    }

    $installArgs = @(
        '/install','/quiet','/norestart',
        '/log',$log,
        'TD_VENDOR=Verito',
        'TD_AUTO_UPDATE=false',
        'TAXDOME_INSTALL_APP=true',
        'TAXDOME_INSTALL_DRIVERS=true'
    )
    Write-Host "Installing..."
    $p = Start-Process $exe -ArgumentList $installArgs -Wait -PassThru

    if (Test-Path $exe) {
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
        Write-Host "Installer removed from server."
    }

    switch ($p.ExitCode) {
        0     { Write-Host "TaxDome installed successfully." -ForegroundColor Green }
        3010  { Write-Host "Installed successfully - reboot required." -ForegroundColor Yellow }
        default {
            Write-Host "Install FAILED, exit code $($p.ExitCode). See $log" -ForegroundColor Red
            Write-Host ""
            Write-Host "This window will close in 10 seconds..."
            Start-Sleep -Seconds 10
            return
        }
    }
}

Write-Host ""
Write-Host "This window will close in 10 seconds..."
Start-Sleep -Seconds 10
