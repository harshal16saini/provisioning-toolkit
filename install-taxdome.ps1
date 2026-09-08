<#
    install-taxdome.ps1  —  unattended TaxDome v4 installer (RDS-aware)

    Runs ONCE. If the install returns 1641/3010 (Dokan driver swap needs a
    restart), it registers a SYSTEM "at startup" scheduled task and then ASKS
    whether to reboot now (Y/N, defaults to NO after 60s - it never reboots on
    its own). Either way the task re-runs THIS script with -Resume at the next
    boot to finish the install before any user logs in, then self-cleans the
    task, state, and cached exe. No second manual run is ever needed.

    Two supported ways to run it:
      1. Directly - save this file and run it: double-click > "Run with PowerShell",
         right-click > Run with PowerShell, or  .\install-taxdome.ps1  in a console.
         It self-elevates via UAC if not already admin.
      2. Via install-taxdome.bat - which elevates, downloads this script to the
         stable path, and runs it with -File.
    Do NOT paste the script text into a console: pasted code has no file path
    ($PSCommandPath is empty), so it cannot self-elevate or persist a resume copy.

    Params:
      -Resume   Internal. Set only by the post-reboot scheduled task.
#>
param(
    [switch]$Resume
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Self-elevate (so the script works run directly, not just via the elevated .bat) ---
# SYSTEM (the resume task) and any elevated admin console pass straight through.
# Guarded: if the identity APIs are unavailable (e.g. Constrained Language Mode), assume we are
# elevated rather than die - the supported launchers (.bat / SYSTEM task) are always elevated.
$__isAdmin = $true; $__isSystem = $false
try {
    $__id       = [Security.Principal.WindowsIdentity]::GetCurrent()
    $__isSystem = $__id.User.Value -eq 'S-1-5-18'
    $__isAdmin  = (New-Object Security.Principal.WindowsPrincipal($__id)).IsInRole(
                      [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if (-not ($__isAdmin -or $__isSystem)) {
    if ($PSCommandPath) {
        Write-Host "Not elevated - relaunching as administrator..." -ForegroundColor Yellow
        # Single pre-quoted string: Windows PowerShell 5.1 does NOT quote array elements that contain
        # spaces, so a profile path like C:\Users\John Smith\... would otherwise be split.
        $relaunchArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Resume) { $relaunchArgs += ' -Resume' }
        try { Start-Process powershell.exe -Verb RunAs -ArgumentList $relaunchArgs } catch {
            Write-Host "Elevation was cancelled or failed. Run this from an elevated PowerShell, or use install-taxdome.bat." -ForegroundColor Red
        }
        return   # hand off to the elevated instance
    } else {
        Write-Host "Not running as administrator, and cannot self-elevate because this script has no file path" -ForegroundColor Red
        Write-Host "(it was pasted or piped into the console). Save it as install-taxdome.ps1 and run the FILE," -ForegroundColor Yellow
        Write-Host "or launch install-taxdome.bat." -ForegroundColor Yellow
        return
    }
}

# --- Paths / identifiers (stable, survive reboot) ---
$StableDir    = 'C:\ProgramData\Verito'
$StableScript = Join-Path $StableDir 'install-taxdome.ps1'      # copy the task runs
$CachedExe    = Join-Path $StableDir 'TaxDome_x64.exe'          # installer cached for boot (network may be down at startup)
$StateFile    = Join-Path $StableDir 'td-install-state.json'    # attempt counter
$Transcript   = Join-Path $StableDir 'td-provision.log'         # full unattended log
$TaskName     = 'Verito-TaxDome-ResumeInstall'
$MaxAttempts  = 3   # first pass + up to 2 post-reboot resumes, then bail (loop guard)

# Reboot policy. The FIRST pass never auto-reboots: it asks Y/N (default NO). If the RESUME pass -
# which runs as SYSTEM at boot, before anyone logs in, with nobody to ask - ever needs a further
# reboot (rare), this decides it. $true = reboot automatically at that pre-login moment so the install
# always completes; $false = never auto-reboot, leave the task armed until the next manual restart.
$AutoRebootOnResume = $true

# Defensive fallback only. The supported launcher (install-taxdome.bat) downloads this
# script to $StableScript and runs it with -File, so $PSCommandPath is normally already set.
$ScriptSourceUrl = 'https://raw.githubusercontent.com/harshal16saini/provisioning-toolkit/main/install-taxdome.ps1'

# --- Working paths (transient) ---
# Per-run unique name: a leftover/locked TaxDome_x64_*.exe from a prior run can't block this download.
$exe = Join-Path 'C:\Temp' ("TaxDome_x64_{0}.exe" -f $PID)
$log = 'C:\Temp\td_install.log'
$tdProps = 'TD_VENDOR=Verito','TD_AUTO_UPDATE=false','TAXDOME_INSTALL_APP=true','TAXDOME_INSTALL_DRIVERS=true'

# --- Config: primary only. Old GitHub v4.8.2 fallback REMOVED (it reinstalled the buggy build). ---
$primary = 'https://files.taxdome.com/desktop/win/TaxDome_x64_Latest.exe'

New-Item -ItemType Directory -Path $StableDir -Force | Out-Null
New-Item -ItemType Directory -Path 'C:\Temp'  -Force | Out-Null

# Best-effort: if transcription is already active in the launching console (or unavailable), keep going.
$__transcribing = $false
try { Start-Transcript -Path $Transcript -Append -Force | Out-Null; $__transcribing = $true } catch { }

function Write-Log {
    param([string]$Msg, [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO')
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $color = @{ INFO='Gray'; WARN='Yellow'; ERROR='Red'; OK='Green' }[$Level]
    Write-Host "[$stamp][$Level] $Msg" -ForegroundColor $color
}

# Run a native exe without PS 5.1's NativeCommandError trap (stderr + EAP=Stop = terminating error).
function Invoke-Native([string]$Path, [string[]]$ArgList) {
    try {
        $p = Start-Process -FilePath $Path -ArgumentList $ArgList -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        return $p.ExitCode
    } catch { return -1 }
}

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
    $hnd = [ConsoleMode]::GetStdHandle(-10); $mode = 0
    [void][ConsoleMode]::GetConsoleMode($hnd, [ref]$mode)
    [void][ConsoleMode]::SetConsoleMode($hnd, ($mode -band (-bnot 0x0040)) -bor 0x0080)
} catch { }

# --- Helpers -----------------------------------------------------------------
function Stop-TaxDome {
    # Kills TaxDome in ALL sessions (admin on RDS kills other users' instances too).
    # Electron = several processes; MSI fails with 1603 "files in use" if any survive.
    $procs = Get-Process -Name 'TaxDome*' -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Log "Stopping $($procs.Count) TaxDome process(es)..."
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Get-Service -Name 'TaxDome*' -ErrorAction SilentlyContinue |
        Where-Object Status -ne 'Stopped' |
        Stop-Service -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $left = Get-Process -Name 'TaxDome*' -ErrorAction SilentlyContinue
    if ($left) { Write-Log "$($left.Count) TaxDome process(es) still running - install may fail with 1603." 'WARN' }
}

function Set-RdsInstallMode([bool]$on) {
    # No-op on non-RDS hosts (change.exe errors are swallowed by Invoke-Native).
    $chg = Join-Path $env:SystemRoot 'System32\change.exe'
    if (Test-Path $chg) {
        $arg = if ($on) { '/install' } else { '/execute' }
        [void](Invoke-Native $chg @('user', $arg))
    }
}

function Get-Installer {
    # CLM-safe: try curl.exe, then fall back to Invoke-WebRequest (different write path).
    # Retries with backoff. Clears the destination first so a stale/locked file can't block us.
    param([string]$Url, [string]$Dest, [int]$Retries = 3)
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    # Tidy any leftover installers from prior runs (best-effort).
    Get-ChildItem 'C:\Temp\TaxDome_x64_*.exe' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    for ($i = 1; $i -le $Retries; $i++) {
        Remove-Item $Dest -Force -ErrorAction SilentlyContinue
        try {
            Write-Log "Download attempt $i/$Retries from $Url"
            $got = $false
            if (Test-Path $curl) {
                & $curl -L -s -f -o $Dest $Url
                if ($LASTEXITCODE -eq 0) {
                    $got = $true
                } else {
                    $hint = if ($LASTEXITCODE -eq 23) { ' (write error - AV lock, disk full, or C:\Temp not writable)' } else { '' }
                    Write-Log "curl.exe exit $LASTEXITCODE$hint" 'WARN'
                }
            }
            if (-not $got) {
                Write-Log "Trying Invoke-WebRequest..."
                Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
            }
            if (-not (Test-Path $Dest) -or (Get-Item $Dest).Length -lt 1MB) {
                throw "Downloaded file missing or <1MB (likely an error page)."
            }
            return
        } catch {
            Write-Log "Attempt $i failed: $($_.Exception.Message)" 'WARN'
            Remove-Item $Dest -Force -ErrorAction SilentlyContinue
            if ($i -lt $Retries) { Start-Sleep -Seconds (5 * $i) }
        }
    }
    throw ("All $Retries download attempts failed for $Url. " +
           "If this was 'curl.exe exit 23' (write error), the network was fine but the file could not be " +
           "written: check antivirus real-time protection / exclusions on C:\Temp, free space on C:, and " +
           "that no locked TaxDome_x64*.exe remains in C:\Temp.")
}

function Ensure-StableCopy {
    # Guarantee a persistent copy of this script exists BEFORE we touch the system,
    # so a reboot-required result can always be resumed. Handles -File and irm|iex.
    # Normal path: the launcher already downloaded us to $StableScript and ran us with -File.
    if ($PSCommandPath -and ($PSCommandPath -ieq $StableScript)) { return }

    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        # Run from some other on-disk path (manual/ad-hoc). Copy this exact file to the stable path.
        Copy-Item -Path $PSCommandPath -Destination $StableScript -Force
    } else {
        # $PSCommandPath empty (e.g. piped to iex). Cannot recover the running source from memory
        # ($MyInvocation.ScriptBlock returns the CALLER under iex), so pull a fresh copy from the repo.
        Write-Log "No local script path detected; fetching a persistent copy from the repo..." 'WARN'
        Invoke-WebRequest -Uri $ScriptSourceUrl -OutFile $StableScript -UseBasicParsing
    }

    # Validate: exists, non-trivial, and is actually THIS script (not an HTML error/stale page).
    $valid = (Test-Path $StableScript) -and ((Get-Item $StableScript).Length -gt 1KB) -and
             ((Get-Content $StableScript -Raw) -like "*$TaskName*")
    if (-not $valid) {
        Remove-Item $StableScript -Force -ErrorAction SilentlyContinue
        throw ("Could not persist a valid copy of this script to $StableScript. " +
               "Aborting BEFORE install so the system is left untouched. " +
               "Likely cause: the script was pasted/piped (no `$PSCommandPath) AND the repo copy at " +
               "$ScriptSourceUrl is stale or unreachable. Fix: run via install-taxdome.bat, or " +
               "'-File .\install-taxdome.ps1' from a saved copy, and make sure the new script is committed to the repo.")
    }
    Write-Log "Persistent script copy ready at $StableScript"
}

function Get-Attempt {
    if (Test-Path $StateFile) {
        try { return [int]((Get-Content $StateFile -Raw | ConvertFrom-Json).Attempt) } catch { return 0 }
    }
    return 0
}
function Set-Attempt([int]$n) {
    @{ Attempt = $n; Updated = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}

function Register-ResumeTask([string]$ScriptPath) {
    $psExe     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action    = New-ScheduledTaskAction -Execute $psExe `
                    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -Resume"
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}

function Disarm-ResumeTask {
    # Stop the task from firing again. Used on hard failure so we fail loud and stay put.
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $CachedExe -Force -ErrorAction SilentlyContinue
}

function Complete-Cleanup {
    # Idempotent. Removes the resume task, state, cached exe, and script copy. Keeps the transcript log.
    Disarm-ResumeTask
    Remove-Item $StateFile    -Force -ErrorAction SilentlyContinue
    Remove-Item $StableScript -Force -ErrorAction SilentlyContinue   # deleting a running .ps1 is safe on Windows
    Write-Log "Cleanup done: resume task, cached installer, script copy, and state removed." 'OK'
}

function Read-YesNoTimeout {
    # Console Y/N prompt with a timeout. Defaults to $Default if no key is pressed, or if there is
    # no interactive console (ISE, redirected stdin, service) - so it can never hang an unattended run.
    param([string]$Prompt, [int]$TimeoutSec = 60, [bool]$Default = $false)
    $defTxt = if ($Default) { 'YES' } else { 'NO' }
    Write-Host ""
    Write-Host "$Prompt  [Y/N]   (auto-selects $defTxt in ${TimeoutSec}s)" -ForegroundColor Cyan
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ($host.UI.RawUI.KeyAvailable) {
                $k = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                if ($k.Character -in 'y','Y') { Write-Host 'Y'; return $true }
                if ($k.Character -in 'n','N') { Write-Host 'N'; return $false }
            }
            Start-Sleep -Milliseconds 200
        }
    } catch { }   # no interactive console: fall through to the default
    Write-Host "(no answer - defaulting to $defTxt)"
    return $Default
}

function Invoke-RebootPath([int]$ThisAttempt, [int]$ExitCode) {
    if ($ThisAttempt -ge $MaxAttempts) {
        Write-Log "Reboot required AGAIN after $($ThisAttempt-1) prior pass(es). Max attempts ($MaxAttempts) hit - NOT rebooting to avoid a loop." 'ERROR'
        Write-Log "Investigate manually. Provision log: $Transcript  |  MSI log: $log" 'ERROR'
        Disarm-ResumeTask
        return   # state file intentionally left behind for diagnostics
    }

    # Cache the installer: the startup task can fire before the network is up.
    Move-Item -Path $exe -Destination $CachedExe -Force -ErrorAction SilentlyContinue

    Set-Attempt $ThisAttempt
    Register-ResumeTask -ScriptPath $StableScript
    Write-Log "Registered SYSTEM startup task '$TaskName'. The install finishes automatically on the next reboot - no re-run needed." 'OK'

    # Decide whether to reboot now. The FIRST pass asks the operator (default NO, so nothing reboots
    # unless explicitly confirmed). The RESUME pass runs as SYSTEM at boot with nobody to ask; see
    # $AutoRebootOnResume below for how that (rare) case is handled.
    if ($Resume) {
        if (-not $AutoRebootOnResume) {
            Write-Log "Resume pass still needs a reboot. Task re-armed; the install completes on the next restart." 'WARN'
            return
        }
        Write-Log "Resume pass still needs a reboot (pre-login, no users affected). Rebooting automatically." 'WARN'
        $doReboot = $true
    } else {
        $doReboot = Read-YesNoTimeout -Prompt "Reboot now to finish the TaxDome install?" -TimeoutSec 60 -Default $false
    }

    if (-not $doReboot) {
        Write-Log "Reboot deferred. Task '$TaskName' stays armed; the install completes automatically whenever this machine next restarts." 'WARN'
        return
    }

    # Confirmed: reboot with a short countdown. (shutdown /a writes to stderr when nothing is
    # pending; both calls are isolated from the Stop trap.)
    try { $ErrorActionPreference = 'Continue'; & shutdown.exe /a 2>$null } catch { } finally { $ErrorActionPreference = 'Stop' }
    Write-Log "Rebooting in 15s to complete the Dokan driver swap. Abort with:  shutdown /a" 'WARN'
    try {
        $ErrorActionPreference = 'Continue'
        & shutdown.exe /r /t 15 /c "TaxDome driver update - rebooting to finish install" 2>$null
        $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = 'Stop' }
    if ($rc -ne 0) {
        Write-Log "shutdown.exe exit $rc - reboot not scheduled. Task is armed; reboot manually to finish." 'ERROR'
    } else {
        Write-Log "Reboot scheduled. Machine restarts in 15s." 'OK'
    }
}

# --- Main --------------------------------------------------------------------
$installExit = $null
try {
    # A first (non-resume) pass always starts a NEW cycle. Only the resume pass reads the counter -
    # otherwise a stale state file left from a previous MaxAttempts bail would block fresh runs forever.
    if ($Resume) { $priorAttempts = Get-Attempt } else { $priorAttempts = 0; Remove-Item $StateFile -Force -ErrorAction SilentlyContinue }
    $thisAttempt = $priorAttempts + 1
    Write-Log "=== TaxDome install pass (attempt $thisAttempt, Resume=$([bool]$Resume)) ===" 'OK'

    # Detect installed v4 app (NOT the v3 "TaxDome" entry)
    $installed = Get-ItemProperty `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'TaxDome Desktop App x64' } |
        Select-Object -First 1

    $instVer = [version]'0.0.0.0'
    if ($installed) {
        $instVer = try { [version]$installed.DisplayVersion } catch { [version]'0.0.0.0' }
        Write-Log "Found TaxDome Desktop App x64 version $instVer"
    } else {
        Write-Log "TaxDome Desktop App x64 not found. Will install fresh."
    }

    # Acquire installer: reuse cached copy on resume, else download (with retries).
    if ($Resume -and (Test-Path $CachedExe)) {
        Copy-Item -Path $CachedExe -Destination $exe -Force
        Write-Log "Using cached installer from the pre-reboot pass."
    } else {
        Get-Installer -Url $primary -Dest $exe
    }

    # Read the downloaded installer's version; compare to installed.
    $vi = (Get-Item $exe).VersionInfo
    $newVer = [version]'0.0.0.0'
    foreach ($cand in @($vi.ProductVersion, $vi.FileVersion)) {
        try { $newVer = [version]($cand -replace '[^\d\.].*$',''); break } catch { }
    }
    Write-Log "Downloaded installer version: $newVer"

    if ($newVer -eq [version]'0.0.0.0') {
        Write-Log "Could not read installer version. Proceeding with install anyway." 'WARN'
    } elseif ($Resume) {
        # Never skip on resume: this pass exists to COMPLETE a pending install. Even if the installer
        # wrote its version to the registry before the reboot, the app is not finished. Re-running the
        # bundle when it is already complete is an idempotent repair that returns 0, so this is safe.
        Write-Log "Resume pass: completing the pending install regardless of registry version ($instVer)."
    } elseif ($instVer -ge $newVer) {
        Write-Log "Installed version ($instVer) is same or newer. Nothing to do." 'OK'
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
        Complete-Cleanup   # clear any leftover task/state from a prior cycle
        return
    }

    # NOTE: no manual pre-uninstall. The new bundle performs the MajorUpgrade of the
    # old 4.x bundle itself; running the old uninstaller first was returning 1619.

    # Secure the resume path BEFORE mutating anything. Throws (and aborts) if it can't.
    # Everything below this line changes the system; nothing above it does.
    Ensure-StableCopy

    # Preserve the old (v3) shortcut before v4's installer overwrites it: ONLY if the Public Desktop
    # "TaxDome.lnk" positively points into the v3 install dir (C:\Program Files (x86)\TaxDome), rename
    # it to "TaxDome v3.lnk" so the v4 installer can create its new shortcut in place.
    # A v4 shortcut (target under C:\Program Files\TaxDome - no "(x86)") is a DIFFERENT path and is
    # left untouched; it simply points at the updated exe after the upgrade. An unreadable target is
    # also left as-is (we never rename on a guess).
    $pub  = Join-Path $env:PUBLIC 'Desktop'
    $lnk  = Join-Path $pub 'TaxDome.lnk'
    $keep = Join-Path $pub 'TaxDome v3.lnk'
    if ((Test-Path $lnk) -and -not (Test-Path $keep)) {
        $target = $null
        try { $target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath } catch { }
        if ($target -like 'C:\Program Files (x86)\TaxDome\*') {
            try {
                Rename-Item -Path $lnk -NewName 'TaxDome v3.lnk' -Force
                Write-Log "v3 shortcut renamed to 'TaxDome v3.lnk' (target: $target)." 'OK'
            } catch { Write-Log "Could not rename v3 shortcut: $($_.Exception.Message)" 'WARN' }
        } else {
            Write-Log "Desktop 'TaxDome.lnk' target is not v3 ('$target'); leaving it as-is." 'INFO'
        }
    }

    # --- Install ---
    Stop-TaxDome
    Set-RdsInstallMode $true
    Write-Log "Installing..."
    $p = Start-Process $exe -ArgumentList (@('/install','/quiet','/norestart','/log',$log) + $tdProps) -Wait -PassThru
    Set-RdsInstallMode $false
    $installExit = $p.ExitCode

    $rebootNeeded = $false
    switch ($installExit) {
        0     { Write-Log "TaxDome installed successfully." 'OK' }
        3010  { $rebootNeeded = $true }   # ERROR_SUCCESS_REBOOT_REQUIRED
        1641  { $rebootNeeded = $true }   # ERROR_SUCCESS_REBOOT_INITIATED - Dokan driver swap
        default {
            Write-Log "Install FAILED, exit code $installExit. See $log" 'ERROR'
            if ($Resume) { Disarm-ResumeTask; Write-Log "Resume task disarmed so it won't retry every boot." 'WARN' }
        }
    }

    if ($rebootNeeded) {
        Write-Log "REBOOT REQUIRED (exit $installExit). Dokan driver replaced; TaxDome not fully installed yet." 'WARN'
        Invoke-RebootPath -ThisAttempt $thisAttempt -ExitCode $installExit
        return
    }

    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    if ($installExit -eq 0) { Complete-Cleanup }
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    # Fail loud, stay put. Never reboot on an unexpected error; never let the task loop.
    if ($Resume) { Disarm-ResumeTask; Write-Log "Resume task disarmed after unhandled error." 'WARN' }
}
finally {
    # Clean the transient installer on every exit path (on the reboot path it was already
    # moved to $CachedExe, so this is a no-op there). Prevents a leftover locking the next run.
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    if ($__transcribing) { try { Stop-Transcript | Out-Null } catch { } }
    if (-not $Resume) {
        Write-Host ""
        Write-Host "This window will close in 10 seconds..."
        Start-Sleep -Seconds 10
    }
}
