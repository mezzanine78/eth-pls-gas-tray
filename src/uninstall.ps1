#Requires -Version 5.1
<#
.SYNOPSIS
    Removes GasTray: stops it, deletes the Run entry, Start Menu shortcut and
    %LOCALAPPDATA%\GasTray. Settings in %APPDATA%\GasTray are removed unless -KeepSettings.
#>
[CmdletBinding()]
param([switch]$KeepSettings)

$ErrorActionPreference = 'Stop'
$InstallDir = Join-Path $env:LOCALAPPDATA 'GasTray'
$DataDir    = Join-Path $env:APPDATA 'GasTray'
$Shortcut   = Join-Path ([Environment]::GetFolderPath('Programs')) 'GasTray.lnk'

try {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.CommandLine -match 'GasTray\.ps1' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
} catch { }

Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'GasTray' -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $Shortcut) { Remove-Item -LiteralPath $Shortcut -Force }
if (-not $KeepSettings -and (Test-Path -LiteralPath $DataDir)) { Remove-Item -LiteralPath $DataDir -Recurse -Force }

# This script lives inside $InstallDir; delete the folder from a detached process after we exit.
if (Test-Path -LiteralPath $InstallDir) {
    $cmd = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$InstallDir' -Recurse -Force -ErrorAction SilentlyContinue"
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $cmd -WindowStyle Hidden
}
Write-Host '[GasTray] Uninstalled.' -ForegroundColor Cyan
