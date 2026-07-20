$ErrorActionPreference = 'Stop'

$version  = 'v4.8.2'
$primary  = "https://taxdome-public.s3.amazonaws.com/desktop/win/$version/TaxDome_x64.exe"
$fallback = "https://github.com/harshal16saini/provisioning-toolkit/releases/download/$version/TaxDome_x64.exe"
$exe = "C:\Temp\TaxDome_x64.exe"
$log = "C:\Temp\td_install.log"

New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null

function Get-Installer($url, $label) {
    Write-Host "Downloading from $label..."
    Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
}

try {
    Get-Installer $primary "TaxDome official"
}
catch {
    Write-Warning "Official source failed ($($_.Exception.Message)). Trying GitHub mirror..."
    try {
        Get-Installer $fallback "GitHub mirror"
    }
    catch {
        Write-Error "Both download sources failed. Aborting. $($_.Exception.Message)"
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
    default { Write-Error "Install failed, exit code $($p.ExitCode). See $log" }
}
