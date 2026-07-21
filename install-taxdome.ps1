$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # prevents progress-bar download throttling

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
    $h = [ConsoleMode]::GetStdHandle(-10)   # STD_INPUT_HANDLE
    $m = 0
    [void][ConsoleMode]::GetConsoleMode($h, [ref]$m)
    $m = $m -band (-bnot 0x0040)            # clear ENABLE_QUICK_EDIT
    $m = $m -bor 0x0080                     # set ENABLE_EXTENDED_FLAGS
    [void][ConsoleMode]::SetConsoleMode($h, $m)
} catch { }  # non-fatal if console doesn't support it

# --- Config ---
$version  = 'v4.8.2'
$primary  = "https://taxdome-public.s3.amazonaws.com/desktop/win/$version/TaxDome_x64.exe"
$fallback = "https://github.com/harshal16saini/provisioning-toolkit/releases/download/$version/TaxDome_x64.exe"
$exe = "C:\Temp\TaxDome_x64.exe"
$log = "C:\Temp\td_install.log"

New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null

function Get-Installer($url, $label) {
    Write-Host "Downloading from $label..."
    (New-Object System.Net.WebClient).DownloadFile($url, $exe)
}

# --- Download: official first, GitHub mirror as fallback ---
try {
    Get-Installer $primary "TaxDome official"
}
catch {
    Write-Warning "Official source failed ($($_.Exception.Message)). Trying GitHub mirror..."
    try {
        Get-Installer $fallback "GitHub mirror"
    }
    catch {
        Write-Host "Both download sources failed. Aborting. $($_.Exception.Message)" -ForegroundColor Red
        Start-Sleep -Seconds 8
        return
    }
}

# --- Install ---
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

# --- Clean up installer regardless of outcome ---
if (Test-Path $exe) {
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    Write-Host "Installer removed from server."
}

# --- Report result ---
switch ($p.ExitCode) {
    0     { Write-Host "TaxDome installed successfully." -ForegroundColor Green }
    3010  { Write-Host "Installed successfully - reboot required." -ForegroundColor Yellow }
    default { Write-Host "Install FAILED, exit code $($p.ExitCode). See $log" -ForegroundColor Red }
}

Write-Host ""
Write-Host "This window will close in 10 seconds..."
Start-Sleep -Seconds 10
