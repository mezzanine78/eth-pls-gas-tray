#Requires -Version 5.1
<#
.SYNOPSIS
    GasTray - live Ethereum (ETH) and PulseChain (PLS) gas meter in the Windows system tray.

.DESCRIPTION
    Shows the current gas price (gwei, avg tier) for the selected chain as text on
    the tray icon, coloured green/amber/red by configurable thresholds. Tooltip and
    right-click menu show low/avg/fast for both chains and a rough fiat cost of a
    21000-gas transfer. Data comes from free keyless public RPCs (with fallbacks)
    and CoinGecko's keyless simple/price endpoint. Network calls run in a
    background runspace so the UI never freezes.

    Settings: %APPDATA%\GasTray\settings.json   Log: %APPDATA%\GasTray\gastray.log

.PARAMETER SelfTest
    Fetch once, print the results to the console and exit (no UI). Works on any OS.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File .\GasTray.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GasTray.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$script:AppName     = 'GasTray'
$script:AppVersion  = '1.0.0'
$script:AppDir      = $PSScriptRoot
$script:ModulePath  = Join-Path $PSScriptRoot 'GasTray.Core.psm1'
$appData = [Environment]::GetFolderPath('ApplicationData')
if ([string]::IsNullOrEmpty($appData)) { $appData = $env:APPDATA }
if ([string]::IsNullOrEmpty($appData)) { $appData = [IO.Path]::GetTempPath() }
$script:DataDir     = Join-Path $appData $script:AppName
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:LogPath     = Join-Path $script:DataDir 'gastray.log'
$script:RunKey      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

Import-Module $script:ModulePath -Force -DisableNameChecking

function Write-GasLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        if ((Test-Path -LiteralPath $script:LogPath) -and ((Get-Item -LiteralPath $script:LogPath).Length -gt 512KB)) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
        }
        Add-Content -LiteralPath $script:LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message)
    } catch { }
}

$script:Settings = Read-GasTraySettings -Path $script:SettingsPath
if (-not (Test-Path -LiteralPath $script:SettingsPath)) {
    try { Save-GasTraySettings -Path $script:SettingsPath -Settings $script:Settings } catch { }
}

# ---------------------------------------------------------------- self test
if ($SelfTest) {
    $snap = Get-GasSnapshot -Settings $script:Settings -IncludePrice
    $price = $snap.Price
    foreach ($c in @('ETH', 'PLS')) {
        $p = $null; if ($price -and $price.ContainsKey($c)) { $p = $price[$c] }
        Write-Output (Format-ChainLine -Chain $c -Gas $snap.$c -Price $p -Symbol $script:Settings.CurrencySymbol)
        if ($snap.$c) { Write-Output ('     via {0} ({1})' -f $snap.$c.Url, $snap.$c.Method) }
    }
    if (-not $price) { Write-Output 'Price: unavailable (fiat cost hidden)' }
    foreach ($e in $snap.Errors) { Write-Output ('ERROR ' + $e) }
    $chain = $script:Settings.IconChain
    if ($snap.$chain) {
        $t = $script:Settings.Thresholds[$chain]
        Write-Output ('Icon would show: "{0}" ({1})' -f (Format-GasShort $snap.$chain.AvgGwei), (Get-GasLevel -Gwei $snap.$chain.AvgGwei -Amber $t.Amber -Red $t.Red))
    }
    return
}

# ---------------------------------------------------------------- UI (Windows only)
if ($env:OS -ne 'Windows_NT') { throw 'The tray UI needs Windows. Use -SelfTest on other platforms.' }

# Single instance.
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\GasTray_mezzanine78', [ref]$createdNew)
if (-not $createdNew) { Write-GasLog 'Another instance is already running; exiting.'; return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('GasTrayNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GasTrayNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Colors = @{
    Green   = @{ Back = [System.Drawing.Color]::FromArgb(46, 125, 50);  Fore = [System.Drawing.Color]::White }
    Amber   = @{ Back = [System.Drawing.Color]::FromArgb(249, 168, 37); Fore = [System.Drawing.Color]::Black }
    Red     = @{ Back = [System.Drawing.Color]::FromArgb(198, 40, 40);  Fore = [System.Drawing.Color]::White }
    Unknown = @{ Back = [System.Drawing.Color]::FromArgb(97, 97, 97);   Fore = [System.Drawing.Color]::White }
}
$script:IconHandle = [IntPtr]::Zero

function New-GasIcon {
    param([string]$Text, [string]$Level)
    $size = [Math]::Max(32, [System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
    $col = $script:Colors[$Level]; if (-not $col) { $col = $script:Colors.Unknown }
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)
        # Rounded square background.
        $r = [int]($size / 5); $d = $r * 2; $w = $size - 1
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($w - $d, 0, $d, $d, 270, 90)
        $path.AddArc($w - $d, $w - $d, $d, $d, 0, 90); $path.AddArc(0, $w - $d, $d, $d, 90, 90)
        $path.CloseFigure()
        $brush = New-Object System.Drawing.SolidBrush($col.Back)
        $g.FillPath($brush, $path); $brush.Dispose(); $path.Dispose()
        # Largest bold font that fits.
        $fmt = [System.Drawing.StringFormat]::GenericTypographic
        $font = $null
        for ($fs = [float]($size * 0.75); $fs -ge 6; $fs -= 0.5) {
            if ($font) { $font.Dispose() }
            $font = New-Object System.Drawing.Font('Segoe UI', $fs, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $m = $g.MeasureString($Text, $font, 1000, $fmt)
            if ($m.Width -le ($size - 2) -and $m.Height -le $size) { break }
        }
        $m = $g.MeasureString($Text, $font, 1000, $fmt)
        $fb = New-Object System.Drawing.SolidBrush($col.Fore)
        $g.DrawString($Text, $font, $fb, [float](($size - $m.Width) / 2), [float](($size - $m.Height) / 2), $fmt)
        $fb.Dispose(); $font.Dispose()
    } finally { $g.Dispose() }
    $h = $bmp.GetHicon(); $bmp.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($h)
    return @{ Icon = $icon; Handle = $h }
}

function Set-TrayIcon {
    param([string]$Text, [string]$Level)
    $new = New-GasIcon -Text $Text -Level $Level
    $oldHandle = $script:IconHandle
    $oldIcon = $script:Notify.Icon
    $script:Notify.Icon = $new.Icon
    $script:IconHandle = $new.Handle
    if ($oldIcon) { $oldIcon.Dispose() }
    if ($oldHandle -ne [IntPtr]::Zero) { [void][GasTrayNative]::DestroyIcon($oldHandle) }
}

# ---------------------------------------------------------------- start with Windows
function Get-LauncherCommand {
    $vbs = Join-Path $script:AppDir 'GasTray.vbs'
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    if ((Test-Path -LiteralPath $vbs) -and (Test-Path -LiteralPath $wscript)) {
        return ('"{0}" "{1}"' -f $wscript, $vbs)
    }
    $ps = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $ps)) { $ps = 'powershell.exe' }
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{1}"' -f $ps, (Join-Path $script:AppDir 'GasTray.ps1'))
}
function Test-StartWithWindows {
    try { return $null -ne (Get-ItemProperty -Path $script:RunKey -Name $script:AppName -ErrorAction Stop).$($script:AppName) } catch { return $false }
}
function Set-StartWithWindows {
    param([bool]$Enabled)
    if ($Enabled) {
        New-ItemProperty -Path $script:RunKey -Name $script:AppName -Value (Get-LauncherCommand) -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $script:RunKey -Name $script:AppName -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- background fetch
$script:Runspace = [runspacefactory]::CreateRunspace()
$script:Runspace.ApartmentState = 'MTA'
$script:Runspace.Open()
$script:Job = $null          # @{ PS; Handle; Started }
$script:NextDue = Get-Date   # fetch immediately
$script:LastPriceTime = [datetime]::MinValue
$script:Price = $null
$script:Snapshot = $null
$script:LastError = $null

$script:FetchScript = {
    param($ModulePath, $Settings, $IncludePrice)
    if (-not (Get-Module -Name GasTray.Core)) { Import-Module $ModulePath -DisableNameChecking }
    Get-GasSnapshot -Settings $Settings -IncludePrice:$IncludePrice
}

function Start-Fetch {
    if ($script:Job) { return }
    $incPrice = [bool]$script:Settings.ShowFiat -and (((Get-Date) - $script:LastPriceTime).TotalSeconds -ge $script:Settings.PriceRefreshSec)
    $ps = [powershell]::Create()
    $ps.Runspace = $script:Runspace
    [void]$ps.AddScript($script:FetchScript).AddArgument($script:ModulePath).AddArgument($script:Settings).AddArgument($incPrice)
    $script:Job = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date; IncPrice = $incPrice }
    $script:MiUpdated.Text = 'Updating...'
}

function Complete-Fetch {
    $job = $script:Job; $script:Job = $null
    $script:NextDue = (Get-Date).AddSeconds($script:Settings.IntervalSec)
    try {
        $out = $job.PS.EndInvoke($job.Handle)
        $snap = $null; if ($out -and $out.Count -gt 0) { $snap = $out[$out.Count - 1] }
        if (-not $snap) { throw 'no data returned' }
        if ($job.IncPrice) {
            $script:LastPriceTime = Get-Date
            if ($snap.Price) { $script:Price = $snap.Price }
        }
        $script:Snapshot = $snap
        $script:LastError = $null
        if ($snap.Errors -and @($snap.Errors).Count -gt 0) {
            $script:LastError = (@($snap.Errors) -join ' | ')
            Write-GasLog $script:LastError
        }
    } catch {
        $script:LastError = $_.Exception.Message
        Write-GasLog ('Fetch failed: ' + $script:LastError)
    } finally {
        $job.PS.Dispose()
    }
    Update-Ui
}

# ---------------------------------------------------------------- UI update
function Update-Ui {
    $s = $script:Settings
    $snap = $script:Snapshot
    $sym = $s.CurrencySymbol
    $priceForUi = $null; if ($s.ShowFiat) { $priceForUi = $script:Price }
    foreach ($c in @('ETH', 'PLS')) {
        $g = $null; if ($snap) { $g = $snap.$c }
        $p = $null; if ($priceForUi -and $priceForUi.ContainsKey($c)) { $p = $priceForUi[$c] }
        $script:MiChain[$c].Text = Format-ChainLine -Chain $c -Gas $g -Price $p -Symbol $sym
    }
    $chain = $s.IconChain
    $g = $null; if ($snap) { $g = $snap.$chain }
    if ($g) {
        $t = $s.Thresholds[$chain]
        Set-TrayIcon -Text (Format-GasShort $g.AvgGwei) -Level (Get-GasLevel -Gwei $g.AvgGwei -Amber $t.Amber -Red $t.Red)
    } else {
        Set-TrayIcon -Text '?' -Level 'Unknown'
    }
    if ($snap) {
        $tip = Format-TrayTooltip -Snapshot $snap -Price $priceForUi -Symbol $sym
    } else {
        $tip = 'GasTray: no data yet'
    }
    $script:Notify.Text = $tip
    $upd = 'Updated '
    if ($snap) { $upd += ('{0:HH:mm:ss}' -f $snap.Time) } else { $upd += 'never' }
    $upd += (' - every {0}s' -f $s.IntervalSec)
    if ($script:LastError) { $upd += '  (some sources failed, see log)' }
    $script:MiUpdated.Text = $upd
    foreach ($k in $script:MiIconChain.Keys) { $script:MiIconChain[$k].Checked = ($k -eq $chain) }
    foreach ($k in $script:MiInterval.Keys) { $script:MiInterval[$k].Checked = ($k -eq $s.IntervalSec) }
    $script:MiStartup.Checked = Test-StartWithWindows
}

function Save-Settings {
    try { Save-GasTraySettings -Path $script:SettingsPath -Settings $script:Settings } catch { Write-GasLog ('Save settings failed: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------- build tray
$script:Notify = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$title = New-Object System.Windows.Forms.ToolStripMenuItem("GasTray $($script:AppVersion) - ETH / PLS gas")
$title.Enabled = $false
[void]$menu.Items.Add($title)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$script:MiChain = @{}
foreach ($c in @('ETH', 'PLS')) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem("$c  loading...")
    $mi.Tag = $c
    $mi.ToolTipText = 'Click to show this chain on the tray icon'
    $mi.Add_Click({ param($src, $evt) $script:Settings.IconChain = [string]$src.Tag; Save-Settings; Update-Ui })
    $script:MiChain[$c] = $mi
    [void]$menu.Items.Add($mi)
}
$script:MiUpdated = New-Object System.Windows.Forms.ToolStripMenuItem('Updating...')
$script:MiUpdated.Enabled = $false
[void]$menu.Items.Add($script:MiUpdated)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$miIcon = New-Object System.Windows.Forms.ToolStripMenuItem('Icon shows')
$script:MiIconChain = @{}
foreach ($c in @('ETH', 'PLS')) {
    $label = if ($c -eq 'ETH') { 'Ethereum (ETH)' } else { 'PulseChain (PLS)' }
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($label)
    $mi.Tag = $c
    $mi.Add_Click({ param($src, $evt) $script:Settings.IconChain = [string]$src.Tag; Save-Settings; Update-Ui })
    $script:MiIconChain[$c] = $mi
    [void]$miIcon.DropDownItems.Add($mi)
}
[void]$menu.Items.Add($miIcon)

$miInt = New-Object System.Windows.Forms.ToolStripMenuItem('Refresh interval')
$script:MiInterval = @{}
foreach ($sec in @(15, 30, 60)) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem("$sec seconds")
    $mi.Tag = $sec
    $mi.Add_Click({
        param($src, $evt)
        $script:Settings.IntervalSec = [int]$src.Tag
        $script:NextDue = (Get-Date).AddSeconds($script:Settings.IntervalSec)
        Save-Settings; Update-Ui
    })
    $script:MiInterval[$sec] = $mi
    [void]$miInt.DropDownItems.Add($mi)
}
[void]$menu.Items.Add($miInt)

$miRefresh = New-Object System.Windows.Forms.ToolStripMenuItem('Refresh now')
$miRefresh.Add_Click({ $script:NextDue = Get-Date; Start-Fetch })
[void]$menu.Items.Add($miRefresh)

$script:MiStartup = New-Object System.Windows.Forms.ToolStripMenuItem('Start with Windows')
$script:MiStartup.Add_Click({
    try { Set-StartWithWindows -Enabled (-not (Test-StartWithWindows)) } catch { Write-GasLog ('Run key: ' + $_.Exception.Message) }
    $script:MiStartup.Checked = Test-StartWithWindows
})
[void]$menu.Items.Add($script:MiStartup)

$miSettings = New-Object System.Windows.Forms.ToolStripMenuItem('Open settings file')
$miSettings.Add_Click({ Save-Settings; Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:SettingsPath) })
[void]$menu.Items.Add($miSettings)

$miReload = New-Object System.Windows.Forms.ToolStripMenuItem('Reload settings')
$miReload.Add_Click({ $script:Settings = Read-GasTraySettings -Path $script:SettingsPath; $script:NextDue = Get-Date; Update-Ui })
[void]$menu.Items.Add($miReload)

[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
$miExit.Add_Click({ Stop-GasTray })
[void]$menu.Items.Add($miExit)

$script:Notify.ContextMenuStrip = $menu
$script:Notify.Add_DoubleClick({ $script:NextDue = Get-Date; Start-Fetch })
Set-TrayIcon -Text '...' -Level 'Unknown'
$script:Notify.Text = 'GasTray: loading...'
$script:Notify.Visible = $true

# One-second UI timer: completes finished jobs, starts due ones, kills hung ones.
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 1000
$script:Timer.Add_Tick({
    try {
        if ($script:Job) {
            if ($script:Job.Handle.IsCompleted) {
                Complete-Fetch
            } elseif (((Get-Date) - $script:Job.Started).TotalSeconds -gt 120) {
                Write-GasLog 'Fetch hung > 120s; abandoning it.'
                $old = $script:Job; $script:Job = $null
                try { [void]$old.PS.BeginStop($null, $null) } catch { }
                # Fresh runspace so a stuck one cannot block the next fetch.
                $script:Runspace = [runspacefactory]::CreateRunspace(); $script:Runspace.Open()
                $script:LastError = 'Fetch timed out'
                $script:NextDue = (Get-Date).AddSeconds($script:Settings.IntervalSec)
                Update-Ui
            }
        } elseif ((Get-Date) -ge $script:NextDue) {
            Start-Fetch
        }
    } catch {
        Write-GasLog ('Timer: ' + $_.Exception.Message)
    }
})

function Stop-GasTray {
    try { $script:Timer.Stop() } catch { }
    try { $script:Notify.Visible = $false; $script:Notify.Dispose() } catch { }
    if ($script:IconHandle -ne [IntPtr]::Zero) { [void][GasTrayNative]::DestroyIcon($script:IconHandle) }
    try { $script:Runspace.Close() } catch { }
    try { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } catch { }
    [System.Windows.Forms.Application]::ExitThread()
}

Write-GasLog "GasTray $($script:AppVersion) started (PowerShell $($PSVersionTable.PSVersion))"
Update-Ui
$script:Timer.Start()
Start-Fetch
$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)
