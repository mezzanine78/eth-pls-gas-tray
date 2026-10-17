# Builds dist/eth-pls-gas-tray-v<version>.zip containing eth-pls-gas-tray/{install.ps1, README.md, src/}
param([string]$Version)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Version) {
    $m = Select-String -Path (Join-Path $root 'src/GasTray.ps1') -Pattern "AppVersion\s*=\s*'([^']+)'" | Select-Object -First 1
    $Version = $m.Matches[0].Groups[1].Value
}
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'stage'
$pkg = Join-Path $stage 'eth-pls-gas-tray'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $pkg 'src') -Force | Out-Null
Copy-Item (Join-Path $root 'install.ps1'), (Join-Path $root 'README.md') -Destination $pkg
Copy-Item (Join-Path $root 'src/*') -Destination (Join-Path $pkg 'src')
$zip = Join-Path $dist "eth-pls-gas-tray-v$Version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $pkg -DestinationPath $zip
Remove-Item $stage -Recurse -Force
Write-Output $zip
