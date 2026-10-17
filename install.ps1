#Requires -Version 5.1
<#
.SYNOPSIS
    Installs (or uninstalls) GasTray - ETH / PLS gas meter for the Windows tray.

.DESCRIPTION
    One-liner install:
        irm https://raw.githubusercontent.com/mezzanine78/eth-pls-gas-tray/main/install.ps1 | iex

    With options (run the downloaded script as a scriptblock):
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mezzanine78/eth-pls-gas-tray/main/install.ps1))) -StartWithWindows
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mezzanine78/eth-pls-gas-tray/main/install.ps1))) -Uninstall

    Installs per-user (no admin) to %LOCALAPPDATA%\GasTray, adds a Start Menu
    shortcut and starts the app. If run from a local clone (GasTray.ps1 sitting in
    .\src next to this script) it copies the local files instead of downloading.

.PARAMETER NoStart           Do not launch GasTray after installing.
.PARAMETER StartWithWindows  Also add the HKCU Run entry (same as the tray menu toggle).
.PARAMETER Uninstall         Remove GasTray (app files, shortcut, Run entry). Add -KeepSettings to keep %APPDATA%\GasTray.
.PARAMETER Ref               Git branch/tag to download from (default: main).
#>
[CmdletBinding()]
param(
    [switch]$NoStart,
    [switch]$StartWithWindows,
    [switch]$Uninstall,
    [switch]$KeepSettings,
    [string]$Ref = 'main'
)

$ErrorActionPreference = 'Stop'
$Repo       = 'mezzanine78/eth-pls-gas-tray'
$RawBase    = "https://raw.githubusercontent.com/$Repo/$Ref/src"
$Files      = @('GasTray.ps1', 'GasTray.Core.psm1', 'GasTray.vbs', 'uninstall.ps1')
$InstallDir = Join-Path $env:LOCALAPPDATA 'GasTray'
$DataDir    = Join-Path $env:APPDATA 'GasTray'
$Shortcut   = Join-Path ([Environment]::GetFolderPath('Programs')) 'GasTray.lnk'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Write-Step([string]$m) { Write-Host "[GasTray] $m" -ForegroundColor Cyan }

function Stop-GasTrayProcess {
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -match 'GasTray\.ps1' -and $_.ProcessId -ne $PID }
        foreach ($p in $procs) {
            Write-Step "Stopping running GasTray (PID $($p.ProcessId))"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
        if ($procs) { Start-Sleep -Milliseconds 800 }
    } catch { Write-Warning "Could not check for running GasTray: $($_.Exception.Message)" }
}

if ($env:OS -ne 'Windows_NT') { throw 'GasTray installs on Windows only.' }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    Stop-GasTrayProcess
    Remove-ItemProperty -Path $RunKey -Name 'GasTray' -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Shortcut) { Remove-Item -LiteralPath $Shortcut -Force }
    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
    if (-not $KeepSettings -and (Test-Path -LiteralPath $DataDir)) { Remove-Item -LiteralPath $DataDir -Recurse -Force }
    Write-Step 'Uninstalled.'
    return
}

# ---------------------------------------------------------------- install
Stop-GasTrayProcess
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$localSrc = $null
if ($PSScriptRoot) {
    $candidate = Join-Path $PSScriptRoot 'src'
    if (Test-Path -LiteralPath (Join-Path $candidate 'GasTray.ps1')) { $localSrc = $candidate }
}

foreach ($f in $Files) {
    $dest = Join-Path $InstallDir $f
    if ($localSrc) {
        Write-Step "Copying $f"
        Copy-Item -LiteralPath (Join-Path $localSrc $f) -Destination $dest -Force
    } else {
        Write-Step "Downloading $f"
        Invoke-WebRequest -Uri "$RawBase/$f" -OutFile $dest -UseBasicParsing
    }
    Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue
}

# Start Menu shortcut -> hidden launcher (wscript + .vbs), or hidden powershell if VBScript is unavailable.
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$psExe   = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$appPs1  = Join-Path $InstallDir 'GasTray.ps1'
$vbs     = Join-Path $InstallDir 'GasTray.vbs'
if (Test-Path -LiteralPath $wscript) {
    $target = $wscript; $arguments = "`"$vbs`""
} else {
    $target = $psExe; $arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$appPs1`""
}
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($Shortcut)
$lnk.TargetPath = $target
$lnk.Arguments = $arguments
$lnk.WorkingDirectory = $InstallDir
$lnk.IconLocation = "$psExe,0"
$lnk.Description = 'GasTray - ETH / PLS gas meter'
$lnk.Save()
Write-Step "Start Menu shortcut: $Shortcut"

if ($StartWithWindows) {
    New-ItemProperty -Path $RunKey -Name 'GasTray' -Value ("`"$target`" $arguments") -PropertyType String -Force | Out-Null
    Write-Step 'Start with Windows: enabled'
}

Write-Step "Installed to $InstallDir"
Write-Step "Uninstall later with: powershell -ExecutionPolicy Bypass -File `"$InstallDir\uninstall.ps1`""

if (-not $NoStart) {
    Start-Process -FilePath $target -ArgumentList $arguments -WorkingDirectory $InstallDir
    Write-Step 'Started - look for the gas number in the system tray (you may need to drag it out of the ^ overflow).'
}
