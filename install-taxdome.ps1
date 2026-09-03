$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Disable QuickEdit so a stray click can't freeze execution (best-effort) ---
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleMode {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
'@
    $h = [ConsoleMode]::GetStdHandle(-10); $m = 0
    [void][ConsoleMode]::GetConsoleMode($h, [ref]$m)
    [void][ConsoleMode]::SetConsoleMode($h, ($m -band (-bnot 0x0040)) -bor 0x0080)
} catch { }

# --- Config ---
$primary  = "https://files.taxdome.com/desktop/win/TaxDome_x64_Latest.exe"
$fallback = "https://github.com/harshal16saini/provisioning-toolkit/releases/download/v4.8.2/TaxDome_x64.exe"  # emergency mirror; refresh occasionally
$exe   = "C:\Temp\TaxDome_x64.exe"
$log   = "C:\Temp\td_install.log"
$unlog = "C:\Temp\td_uninstall.log"
$tdProps = 'TD_VENDOR=Verito','TD_AUTO_UPDATE=false','TAXDOME_INSTALL_APP=true','TAXDOME_INSTALL_DRIVERS=true'

New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null

# --- Detect installed v4 app (NOT the v3 "TaxDome" entry) ---
$installed = Get-ItemProperty `
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq 'TaxDome Desktop App x64' } |
    Select-Object -First 1

$instVer = [version]'0.0.0.0'
if ($installed) {
    $instVer = try { [version]$installed.DisplayVersion } catch { [version]'0.0.0.0' }
    Write-Host "Found TaxDome Desktop App x64 version $instVer"
} else {
    Write-Host "TaxDome Desktop App x64 not found. Will install fresh."
}

# --- Download latest installer (CLM-safe: curl.exe if present, else IWR) ---
function Get-Installer($url, $label) {
    Write-Host "Downloading from $label..."
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) {
        & $curl -L -s -o $exe $url
        if ($LASTEXITCODE -ne 0) { throw "curl.exe exit $LASTEXITCODE" }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    }
    if (-not (Test-Path $exe) -or (Get-Item $exe).Length -lt 1MB) {
        throw "Downloaded file missing or too small (<1MB) - likely an error page."
    }
}
try { Get-Installer $primary "TaxDome official" }
catch {
    Write-Warning "Official source failed ($($_.Exception.Message)). Trying GitHub mirror..."
    try { Get-Installer $fallback "GitHub mirror" }
    catch {
        Write-Host "Both download sources failed. Aborting. $($_.Exception.Message)" -ForegroundColor Red
        Start-Sleep -Seconds 10; return
    }
}

# --- Read the downloaded installer's version; compare to installed ---
$vi = (Get-Item $exe).VersionInfo
$newVer = [version]'0.0.0.0'
foreach ($cand in @($vi.ProductVersion, $vi.FileVersion)) {
    try { $newVer = [version]($cand -replace '[^\d\.].*$',''); break } catch { }
}
Write-Host "Downloaded installer version: $newVer"

if ($newVer -eq [version]'0.0.0.0') {
    Write-Warning "Could not read installer version. Proceeding with install anyway."
} elseif ($instVer -ge $newVer) {
    Write-Host "Installed version ($instVer) is same or newer. Nothing to do." -ForegroundColor Green
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10; return
}

# --- Preserve the old (v3) shortcut before v4's installer overwrites it ---
$pub = Join-Path $env:PUBLIC 'Desktop'
$lnk = Join-Path $pub 'TaxDome.lnk'
if ((Test-Path $lnk) -and -not (Test-Path (Join-Path $pub 'TaxDome v3.lnk'))) {
    try {
        $target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
        if ($target -like 'C:\Program Files (x86)\TaxDome\*') {
            Rename-Item -Path $lnk -NewName 'TaxDome v3.lnk' -Force
            Write-Host "Old v3 shortcut preserved as 'TaxDome v3.lnk'" -ForegroundColor Green
        }
    } catch { Write-Warning "Could not check/preserve v3 shortcut: $($_.Exception.Message)" }
}

# --- Uninstall existing v4 first (avoids reboot on upgrade) ---
if ($installed) {
    $raw = $installed.QuietUninstallString
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $installed.UninstallString }
    $unExe = $null
    if ($raw -match '^\s*"([^"]+)"') { $unExe = $Matches[1] }
    elseif ($raw) { $unExe = ($raw -split '\s+')[0] }

    if ($unExe -and (Test-Path $unExe)) {
        Write-Host "Uninstalling existing TaxDome v4 ($instVer)..."
        $u = Start-Process $unExe -ArgumentList (@('/uninstall','/quiet','/norestart','/log',$unlog) + $tdProps) -Wait -PassThru
        if ($u.ExitCode -notin 0,3010) {
            Write-Warning "Uninstall exit code $($u.ExitCode). See $unlog. Continuing with direct install (may require reboot)."
        } else {
            Write-Host "Old version uninstalled." -ForegroundColor Green
        }
    } else {
        Write-Warning "Cached uninstaller not found. Direct in-place install (may require reboot)."
    }
}

# --- Install ---
Write-Host "Installing..."
$p = Start-Process $exe -ArgumentList (@('/install','/quiet','/norestart','/log',$log) + $tdProps) -Wait -PassThru
Remove-Item $exe -Force -ErrorAction SilentlyContinue

switch ($p.ExitCode) {
    0     { Write-Host "TaxDome installed successfully." -ForegroundColor Green }
    3010  { Write-Host "Installed successfully - reboot required." -ForegroundColor Yellow }
    default { Write-Host "Install FAILED, exit code $($p.ExitCode). See $log" -ForegroundColor Red }
}

Write-Host ""
Write-Host "This window will close in 10 seconds..."
Start-Sleep -Seconds 10
