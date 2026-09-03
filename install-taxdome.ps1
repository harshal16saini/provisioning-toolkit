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
$tdProps = 'TD_VENDOR=Verito','TD_AUTO_UPDATE=false','TAXDOME_INSTALL_APP=true','TAXDOME_INSTALL_DRIVERS=true'

New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null

# --- Helpers ---
function Stop-TaxDome {
    # Kills TaxDome in ALL sessions (admin on RDS kills other users' instances too).
    # Electron = several processes; MSI fails with 1603 "files in use" if any survive.
    $procs = Get-Process -Name 'TaxDome*' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "Stopping $($procs.Count) TaxDome process(es)..."
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Get-Service -Name 'TaxDome*' -ErrorAction SilentlyContinue |
        Where-Object Status -ne 'Stopped' |
        Stop-Service -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $left = Get-Process -Name 'TaxDome*' -ErrorAction SilentlyContinue
    if ($left) { Write-Warning "$($left.Count) TaxDome process(es) still running - install may fail with 1603." }
}

function Set-RdsInstallMode([bool]$on) {
    # No-op on non-RDS hosts (change.exe returns an error we ignore).
    $chg = Join-Path $env:SystemRoot 'System32\change.exe'
    if (Test-Path $chg) {
        $mode = if ($on) { '/install' } else { '/execute' }
        & $chg user $mode *> $null
    }
}

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
        & $curl -L -s -f -o $exe $url
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

# NOTE: no manual pre-uninstall. The new bundle performs the MajorUpgrade of the
# old 4.x bundle itself; running the old uninstaller first was returning 1619.

# --- Install ---
Stop-TaxDome
Set-RdsInstallMode $true
Write-Host "Installing..."
$p = Start-Process $exe -ArgumentList (@('/install','/quiet','/norestart','/log',$log) + $tdProps) -Wait -PassThru
Set-RdsInstallMode $false
Remove-Item $exe -Force -ErrorAction SilentlyContinue

$rebootNeeded = $false
switch ($p.ExitCode) {
    0     { Write-Host "TaxDome installed successfully." -ForegroundColor Green }
    3010  { $rebootNeeded = $true }
    1641  { $rebootNeeded = $true }   # ERROR_SUCCESS_REBOOT_INITIATED - Dokan driver swap needs a restart
    default { Write-Host "Install FAILED, exit code $($p.ExitCode). See $log" -ForegroundColor Red }
}

if ($rebootNeeded) {
    Write-Host ""
    Write-Host "REBOOT REQUIRED (exit $($p.ExitCode)). The Dokan driver was replaced; TaxDome itself is not installed yet." -ForegroundColor Yellow
    Write-Host "After the reboot, re-run this installer BEFORE anyone opens TaxDome. It will finish in one pass." -ForegroundColor Yellow
    Write-Host ""
    $ans = Read-Host "Reboot now? (Y/N)"
    if ($ans -match '^[Yy]') {
        Write-Host "Rebooting in 15 seconds..."
        shutdown.exe /r /t 15 /c "TaxDome driver update - rebooting to complete install"
    } else {
        Write-Host "Reboot skipped. Nothing else will install until the machine restarts." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "This window will close in 10 seconds..."
Start-Sleep -Seconds 10
