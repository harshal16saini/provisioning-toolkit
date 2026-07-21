$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Disable QuickEdit so a stray click can't freeze execution ---
$sig = @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleMode {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
'@
try {
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
$primary  = "https://taxdome-public.s3.amazonaws.com/desktop/win/$version/TaxDome_x64.exe"
$fallback = "https://github.com/harshal16saini/provisioning-toolkit/releases/download/$version/TaxDome_x64.exe"
$exe = "C:\Temp\TaxDome_x64.exe"
$log = "C:\Temp\td_install.log"

# Where to place the shortcut = folder the .bat was launched from
$launchDir = $env:TD_LAUNCHDIR
if ([string]::IsNullOrWhiteSpace($launchDir) -or -not (Test-Path $launchDir)) {
    $launchDir = [Environment]::GetFolderPath('Desktop')  # fallback
    Write-Warning "Launch folder not provided; falling back to $launchDir"
}

New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null

# --- Detect installed v4 app (NOT the v3 "TaxDome" entry) ---
function Get-TaxDomeV4 {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        Get-ItemProperty $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq 'TaxDome Desktop App x64' } |
            Select-Object -First 1 |
            ForEach-Object { return $_ }
    }
}

$installed = Get-TaxDomeV4

function Copy-Shortcut {
    # Find the TaxDome v4 shortcut anywhere it may have been created, copy to launch dir
    $src = Get-ChildItem "C:\Users\*\Desktop\*TaxDome*.lnk","C:\Users\Public\Desktop\*TaxDome*.lnk" -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($src) {
        Copy-Item $src.FullName $launchDir -Force -ErrorAction SilentlyContinue
        Write-Host "Shortcut copied to $launchDir" -ForegroundColor Green
    } else {
        Write-Host "No TaxDome shortcut found to copy." -ForegroundColor Yellow
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
    function Get-Installer($url, $label) {
        Write-Host "Downloading from $label..."
        (New-Object System.Net.WebClient).DownloadFile($url, $exe)
    }
    try { Get-Installer $primary "TaxDome official" }
    catch {
        Write-Warning "Official source failed ($($_.Exception.Message)). Trying GitHub mirror..."
        try { Get-Installer $fallback "GitHub mirror" }
        catch {
            Write-Host "Both download sources failed. Aborting. $($_.Exception.Message)" -ForegroundColor Red
            Start-Sleep -Seconds 8
            return
        }
    }

    $args = @(
        '/install','/quiet','/norestart',
        '/log',$log,
        'TD_VENDOR=Verito',
        'TD_AUTO_UPDATE=false',
        'TAXDOME_INSTALL_APP=true',
        'TAXDOME_INSTALL_DRIVERS=true'
    )
    Write-Host "Installing..."
    $p = Start-Process $exe -ArgumentList $args -Wait -PassThru

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

# --- Always copy shortcut to launch folder (whether installed or already present) ---
Copy-Shortcut

Write-Host ""
Write-Host "This window will close in 10 seconds..."
Start-Sleep -Seconds 10
