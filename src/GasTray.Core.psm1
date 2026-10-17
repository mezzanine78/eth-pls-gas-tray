#Requires -Version 5.1
<#
    GasTray.Core.psm1
    Pure data / formatting logic for the GasTray app. No WinForms here, so this
    module can be unit-tested on any OS with Windows PowerShell 5.1 or pwsh 7+.
#>

Set-StrictMode -Version 2.0

# Default keyless public RPC endpoints (checked live 2026-10-18).
$script:DefaultRpc = @{
    ETH = @(
        'https://ethereum-rpc.publicnode.com',
        'https://eth.drpc.org',
        'https://rpc.flashbots.net',
        'https://rpc.mevblocker.io'
    )
    PLS = @(
        'https://pulsechain-rpc.publicnode.com',
        'https://rpc.pulsechain.com',
        'https://rpc-pulsechain.g4mm4.io'
    )
}

# CoinGecko ids per chain (free, keyless simple/price endpoint).
$script:CoinGeckoId = @{ ETH = 'ethereum'; PLS = 'pulsechain' }

function Initialize-GasTrayTls {
    # Windows PowerShell 5.1 may default to TLS 1.0/1.1; public RPCs need 1.2+.
    try {
        $tls12 = [System.Net.SecurityProtocolType]::Tls12
        if (([System.Net.ServicePointManager]::SecurityProtocol -band $tls12) -ne $tls12) {
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor $tls12
        }
    } catch { }
}

function Get-GasTrayDefaultRpc {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('ETH', 'PLS')][string]$Chain)
    return [string[]]$script:DefaultRpc[$Chain]
}

function ConvertFrom-HexQuantity {
    <# Converts a JSON-RPC hex quantity ("0x2c2f010") to [decimal]. #>
    [CmdletBinding()]
    [OutputType([decimal])]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$Hex)
    process {
        $h = $Hex.Trim()
        if ($h -match '^0[xX]') { $h = $h.Substring(2) }
        if ([string]::IsNullOrEmpty($h)) { return [decimal]0 }
        if ($h -notmatch '^[0-9a-fA-F]+$') { throw "Not a hex quantity: '$Hex'" }
        # Leading 0 keeps BigInteger from treating the top bit as a sign bit.
        $big = [System.Numerics.BigInteger]::Parse('0' + $h, [System.Globalization.NumberStyles]::AllowHexSpecifier)
        return [decimal]$big
    }
}

function Invoke-EthRpc {
    <#
        Calls a JSON-RPC method, trying each URL in order until one returns a
        result. Returns [pscustomobject]@{ Result; Url; Errors }.
        Throws if every URL fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Url,
        [Parameter(Mandatory)][string]$Method,
        [object[]]$Params = @(),
        [int]$TimeoutSec = 8
    )
    Initialize-GasTrayTls
    $body = @{ jsonrpc = '2.0'; id = 1; method = $Method; params = $Params } | ConvertTo-Json -Depth 6 -Compress
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($u in $Url) {
        if ([string]::IsNullOrWhiteSpace($u)) { continue }
        try {
            $resp = Invoke-RestMethod -Uri $u -Method Post -Body $body -ContentType 'application/json' `
                -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
            if ($null -eq $resp) { throw 'empty response' }
            if ($resp -is [string]) { throw ('non-JSON response: ' + $resp.Substring(0, [Math]::Min(80, $resp.Length))) }
            $hasErr = $resp.PSObject.Properties.Name -contains 'error'
            if ($hasErr -and $null -ne $resp.error) { throw ('RPC error: ' + ($resp.error | ConvertTo-Json -Compress)) }
            if (-not ($resp.PSObject.Properties.Name -contains 'result') -or $null -eq $resp.result) { throw 'no result field' }
            return [pscustomobject]@{ Result = $resp.result; Url = $u; Errors = $errors.ToArray() }
        } catch {
            $errors.Add(('{0}: {1}' -f $u, $_.Exception.Message))
        }
    }
    throw ("All RPC endpoints failed for {0}: {1}" -f $Method, ($errors -join ' | '))
}

function Get-Median {
    param([decimal[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return [decimal]0 }
    $s = $Values | Sort-Object
    $s = @($s)
    $n = $s.Count
    if ($n % 2 -eq 1) { return [decimal]$s[[int](($n - 1) / 2)] }
    return ([decimal]$s[$n / 2 - 1] + [decimal]$s[$n / 2]) / 2
}

function ConvertFrom-FeeHistory {
    <#
        Turns an eth_feeHistory result (percentiles 10/50/90) into gwei values.
        Next-block base fee = last baseFeePerGas entry. Tip per tier = median of
        that percentile across the sampled blocks (robust to outlier blocks).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$FeeHistory)
    $baseFees = @($FeeHistory.baseFeePerGas)
    if ($baseFees.Count -eq 0) { throw 'feeHistory has no baseFeePerGas' }
    $nextBase = ConvertFrom-HexQuantity ([string]$baseFees[$baseFees.Count - 1])

    $tips = @{ 0 = @(); 1 = @(); 2 = @() }
    $hasReward = $FeeHistory.PSObject.Properties.Name -contains 'reward'
    if ($hasReward -and $null -ne $FeeHistory.reward) {
        foreach ($blk in @($FeeHistory.reward)) {
            $row = @($blk)
            for ($i = 0; $i -lt 3 -and $i -lt $row.Count; $i++) {
                $tips[$i] += (ConvertFrom-HexQuantity ([string]$row[$i]))
            }
        }
    }
    $gwei = [decimal]1000000000
    $tLow = Get-Median $tips[0]; $tAvg = Get-Median $tips[1]; $tFast = Get-Median $tips[2]
    # Keep tiers monotonic.
    if ($tAvg -lt $tLow) { $tAvg = $tLow }
    if ($tFast -lt $tAvg) { $tFast = $tAvg }
    return [pscustomobject]@{
        BaseGwei = [double]($nextBase / $gwei)
        LowGwei  = [double](($nextBase + $tLow) / $gwei)
        AvgGwei  = [double](($nextBase + $tAvg) / $gwei)
        FastGwei = [double](($nextBase + $tFast) / $gwei)
    }
}

function Get-ChainGas {
    <#
        Returns gas for one chain: low/avg/fast/base in gwei plus the source.
        Uses eth_feeHistory (20 blocks, p10/p50/p90); falls back to eth_gasPrice.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ETH', 'PLS')][string]$Chain,
        [string[]]$RpcUrls,
        [int]$TimeoutSec = 8,
        [int]$BlockCount = 20
    )
    if (-not $RpcUrls -or $RpcUrls.Count -eq 0) { $RpcUrls = @(Get-GasTrayDefaultRpc -Chain $Chain) }
    $errs = @()
    try {
        $r = Invoke-EthRpc -Url $RpcUrls -Method 'eth_feeHistory' -Params @($BlockCount, 'latest', @(10, 50, 90)) -TimeoutSec $TimeoutSec
        $g = ConvertFrom-FeeHistory -FeeHistory $r.Result
        return [pscustomobject]@{
            Chain = $Chain; BaseGwei = $g.BaseGwei; LowGwei = $g.LowGwei; AvgGwei = $g.AvgGwei; FastGwei = $g.FastGwei
            Method = 'eth_feeHistory'; Url = $r.Url; Errors = @($r.Errors); Time = Get-Date
        }
    } catch {
        $errs += $_.Exception.Message
    }
    # Fallback: legacy gas price (single number for all tiers).
    $r = Invoke-EthRpc -Url $RpcUrls -Method 'eth_gasPrice' -Params @() -TimeoutSec $TimeoutSec
    $gp = [double]((ConvertFrom-HexQuantity ([string]$r.Result)) / [decimal]1000000000)
    return [pscustomobject]@{
        Chain = $Chain; BaseGwei = $null; LowGwei = $gp; AvgGwei = $gp; FastGwei = $gp
        Method = 'eth_gasPrice'; Url = $r.Url; Errors = @($errs + $r.Errors); Time = Get-Date
    }
}

function Get-CoinPrice {
    <#
        Returns a hashtable @{ ETH = <price>; PLS = <price> } in the given fiat
        currency from CoinGecko simple/price (keyless). Missing coins are omitted.
        Returns $null on failure (caller just hides fiat cost).
    #>
    [CmdletBinding()]
    param(
        [string]$Currency = 'aud',
        [int]$TimeoutSec = 8,
        [string]$BaseUrl = 'https://api.coingecko.com/api/v3/simple/price'
    )
    Initialize-GasTrayTls
    $cur = $Currency.ToLowerInvariant()
    $ids = ($script:CoinGeckoId.Values | Sort-Object) -join ','
    $uri = '{0}?ids={1}&vs_currencies={2}' -f $BaseUrl, $ids, $cur
    try {
        $resp = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $out = @{}
        foreach ($k in $script:CoinGeckoId.Keys) {
            $id = $script:CoinGeckoId[$k]
            if ($resp.PSObject.Properties.Name -contains $id) {
                $coin = $resp.$id
                if ($coin.PSObject.Properties.Name -contains $cur -and $null -ne $coin.$cur) {
                    $out[$k] = [double]$coin.$cur
                }
            }
        }
        if ($out.Count -eq 0) { return $null }
        return $out
    } catch {
        Write-Verbose ("Price fetch failed: " + $_.Exception.Message)
        return $null
    }
}

function Get-TransferCost {
    <# Fiat cost of a transaction: gwei * gas * 1e-9 * price. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][double]$Gwei,
        [Parameter(Mandatory)][double]$Price,
        [int]$GasUnits = 21000
    )
    return $Gwei * $GasUnits * 1e-9 * $Price
}

function Format-GasShort {
    <# Compact text that fits on a 16-32 px tray icon (max ~4 chars). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Gwei)
    if ($null -eq $Gwei) { return '?' }
    $v = [double]$Gwei
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    if ($v -ge 999500000) { return ($v / 1e9).ToString('0.#', $ci) + 'B' }
    if ($v -ge 9950000)   { return ($v / 1e6).ToString('0', $ci) + 'M' }
    if ($v -ge 999500)    { return ($v / 1e6).ToString('0.#', $ci) + 'M' }
    if ($v -ge 9999.5)    { return ($v / 1e3).ToString('0', $ci) + 'K' }
    if ($v -ge 999.5)     { return ($v / 1e3).ToString('0.#', $ci) + 'K' }
    if ($v -ge 9.95)      { return $v.ToString('0', $ci) }
    if ($v -ge 0.995)     { return $v.ToString('0.#', $ci) }
    if ($v -ge 0.0095)    { return $v.ToString('.00', $ci) }
    if ($v -gt 0)         { return '<.01' }
    return '0'
}

function Format-GasLong {
    <# Readable gwei for menus/tooltips. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Gwei)
    if ($null -eq $Gwei) { return '?' }
    $v = [double]$Gwei
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    if ($v -ge 1e6) { return ($v / 1e6).ToString('0.00', $ci) + 'M' }
    if ($v -ge 1e4) { return ($v / 1e3).ToString('0.0', $ci) + 'K' }
    if ($v -ge 100) { return $v.ToString('0', $ci) }
    if ($v -ge 1)   { return $v.ToString('0.0#', $ci) }
    if ($v -ge 0.01) { return $v.ToString('0.00#', $ci) }
    return $v.ToString('0.####', $ci)
}

function Format-Money {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][double]$Amount, [string]$Symbol = 'A$')
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Amount -ge 100)  { return $Symbol + $Amount.ToString('0', $ci) }
    if ($Amount -ge 0.1)  { return $Symbol + $Amount.ToString('0.00', $ci) }
    if ($Amount -ge 0.001) { return $Symbol + $Amount.ToString('0.000', $ci) }
    if ($Amount -ge 0.0001) { return $Symbol + $Amount.ToString('0.0000', $ci) }
    return '<' + $Symbol + '0.0001'
}

function Get-GasLevel {
    <# Returns 'Green', 'Amber' or 'Red' for a gwei value against thresholds. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Gwei,
        [Parameter(Mandatory)][double]$Amber,
        [Parameter(Mandatory)][double]$Red
    )
    if ($null -eq $Gwei) { return 'Unknown' }
    $v = [double]$Gwei
    if ($v -ge $Red) { return 'Red' }
    if ($v -ge $Amber) { return 'Amber' }
    return 'Green'
}

function Get-GasTrayDefaultSettings {
    # Thresholds compare against the AVG tier, in gwei.
    return [ordered]@{
        IconChain       = 'ETH'
        IntervalSec     = 30
        Currency        = 'aud'
        CurrencySymbol  = 'A$'
        ShowFiat        = $true
        PriceRefreshSec = 300
        TimeoutSec      = 8
        Thresholds      = [ordered]@{
            ETH = [ordered]@{ Amber = 5; Red = 20 }
            PLS = [ordered]@{ Amber = 1000000; Red = 3000000 }
        }
        Rpc             = [ordered]@{
            ETH = @($script:DefaultRpc.ETH)
            PLS = @($script:DefaultRpc.PLS)
        }
    }
}

function Merge-GasTraySettings {
    <# Overlays a loaded settings object onto defaults so missing keys get defaults. #>
    [CmdletBinding()]
    param($Loaded)
    $s = Get-GasTrayDefaultSettings
    if ($null -eq $Loaded) { return $s }
    $names = $Loaded.PSObject.Properties.Name
    foreach ($k in @('IconChain', 'Currency', 'CurrencySymbol')) {
        if ($names -contains $k -and $Loaded.$k) { $s[$k] = [string]$Loaded.$k }
    }
    foreach ($k in @('IntervalSec', 'PriceRefreshSec', 'TimeoutSec')) {
        if ($names -contains $k -and [int]$Loaded.$k -gt 0) { $s[$k] = [int]$Loaded.$k }
    }
    if ($names -contains 'ShowFiat') { $s.ShowFiat = [bool]$Loaded.ShowFiat }
    if ($s.IconChain -notin @('ETH', 'PLS')) { $s.IconChain = 'ETH' }
    if ($s.IntervalSec -lt 10) { $s.IntervalSec = 10 }
    foreach ($c in @('ETH', 'PLS')) {
        if ($names -contains 'Thresholds' -and $Loaded.Thresholds -and ($Loaded.Thresholds.PSObject.Properties.Name -contains $c)) {
            $t = $Loaded.Thresholds.$c
            if ($t.PSObject.Properties.Name -contains 'Amber') { $s.Thresholds[$c].Amber = [double]$t.Amber }
            if ($t.PSObject.Properties.Name -contains 'Red') { $s.Thresholds[$c].Red = [double]$t.Red }
        }
        if ($names -contains 'Rpc' -and $Loaded.Rpc -and ($Loaded.Rpc.PSObject.Properties.Name -contains $c)) {
            $urls = @($Loaded.Rpc.$c | Where-Object { $_ -match '^https?://' })
            if ($urls.Count -gt 0) { $s.Rpc[$c] = $urls }
        }
    }
    return $s
}

function Read-GasTraySettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        try {
            $loaded = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            return Merge-GasTraySettings -Loaded $loaded
        } catch {
            Write-Warning ("Settings unreadable, using defaults: " + $_.Exception.Message)
        }
    }
    return Get-GasTrayDefaultSettings
}

function Save-GasTraySettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Settings)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-GasSnapshot {
    <#
        One full refresh: both chains (+ optional prices). Never throws; each
        chain gets an Error string instead. This is what the tray app runs in
        its background runspace.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Settings,
        [switch]$IncludePrice
    )
    $snap = [ordered]@{ Time = Get-Date; ETH = $null; PLS = $null; Price = $null; Errors = @() }
    foreach ($c in @('ETH', 'PLS')) {
        try {
            $snap[$c] = Get-ChainGas -Chain $c -RpcUrls @($Settings.Rpc[$c]) -TimeoutSec $Settings.TimeoutSec
        } catch {
            $snap.Errors += ('{0}: {1}' -f $c, $_.Exception.Message)
        }
    }
    if ($IncludePrice) {
        $snap.Price = Get-CoinPrice -Currency $Settings.Currency -TimeoutSec $Settings.TimeoutSec
    }
    return [pscustomobject]$snap
}

function Format-ChainLine {
    <# "ETH  low 0.05 / avg 0.05 / fast 0.06 gwei  ~A$0.003" #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Chain, $Gas, $Price, [string]$Symbol = 'A$')
    if ($null -eq $Gas) { return "$Chain  unavailable" }
    $line = '{0}  low {1} / avg {2} / fast {3} gwei' -f $Chain, (Format-GasLong $Gas.LowGwei), (Format-GasLong $Gas.AvgGwei), (Format-GasLong $Gas.FastGwei)
    if ($null -ne $Price) {
        $line += '  ~' + (Format-Money -Amount (Get-TransferCost -Gwei $Gas.AvgGwei -Price $Price) -Symbol $Symbol) + ' per transfer'
    }
    return $line
}

function Format-TrayTooltip {
    <# NotifyIcon.Text is limited to 63 chars on .NET Framework; keep it short. #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Snapshot, $Price, [string]$Symbol = 'A$')
    $parts = @()
    foreach ($c in @('ETH', 'PLS')) {
        $g = $Snapshot.$c
        if ($null -eq $g) { $parts += "$c n/a"; continue }
        $p = "$c " + (Format-GasLong $g.AvgGwei) + ' gwei'
        if ($null -ne $Price -and $Price.ContainsKey($c)) {
            $p += ' ' + (Format-Money -Amount (Get-TransferCost -Gwei $g.AvgGwei -Price $Price[$c]) -Symbol $Symbol)
        }
        $parts += $p
    }
    $t = $parts -join "`n"
    if ($t.Length -gt 63) { $t = $t.Substring(0, 63) }
    return $t
}

Export-ModuleMember -Function ConvertFrom-HexQuantity, Invoke-EthRpc, ConvertFrom-FeeHistory, Get-ChainGas, Get-CoinPrice,
    Get-TransferCost, Format-GasShort, Format-GasLong, Format-Money, Get-GasLevel, Get-GasTrayDefaultSettings,
    Merge-GasTraySettings, Read-GasTraySettings, Save-GasTraySettings, Get-GasSnapshot, Format-ChainLine,
    Format-TrayTooltip, Get-GasTrayDefaultRpc, Initialize-GasTrayTls, Get-Median
