# Pester 5+ tests for GasTray.Core. Run: Invoke-Pester ./tests  (add -ExcludeTag Live to stay offline)
BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\src\GasTray.Core.psm1') -Force
    $endpoints = @(Get-GasTrayDefaultRpc -Chain ETH | ForEach-Object { @{ c = 'ETH'; u = $_ } }) +
                 @(Get-GasTrayDefaultRpc -Chain PLS | ForEach-Object { @{ c = 'PLS'; u = $_ } })
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\GasTray.Core.psm1') -Force
    $script:Live = [System.Collections.Generic.List[string]]::new()
}

Describe 'ConvertFrom-HexQuantity' {
    It 'parses small and large quantities' {
        ConvertFrom-HexQuantity '0x0' | Should -Be 0
        ConvertFrom-HexQuantity '0x2c2f010' | Should -Be 46329872
        ConvertFrom-HexQuantity '0x38d7ea4c68000' | Should -Be 1000000000000000
        ConvertFrom-HexQuantity '0xde0b6b3a7640000' | Should -Be 1000000000000000000
        ConvertFrom-HexQuantity '0xffffffffffffffff' | Should -Be ([decimal]'18446744073709551615')
    }
    It 'rejects garbage' { { ConvertFrom-HexQuantity '0xZZ' } | Should -Throw }
}

Describe 'ConvertFrom-FeeHistory' {
    It 'uses the next-block base fee plus median tips' {
        $fh = [pscustomobject]@{
            baseFeePerGas = @('0x3b9aca00', '0x3b9aca00', '0x77359400')   # 1, 1, 2 gwei (last = next block)
            reward        = @(
                @('0x5f5e100', '0x3b9aca00', '0x77359400'),  # 0.1 / 1 / 2 gwei
                @('0x5f5e100', '0x3b9aca00', '0xb2d05e00')   # 0.1 / 1 / 3 gwei
            )
        }
        $g = ConvertFrom-FeeHistory -FeeHistory $fh
        $g.BaseGwei | Should -Be 2
        $g.LowGwei  | Should -Be 2.1
        $g.AvgGwei  | Should -Be 3
        $g.FastGwei | Should -Be 4.5
    }
    It 'works with no reward array (base fee only)' {
        $g = ConvertFrom-FeeHistory -FeeHistory ([pscustomobject]@{ baseFeePerGas = @('0x3b9aca00') })
        $g.AvgGwei | Should -Be 1
    }
}

Describe 'Formatting and levels' {
    It 'Format-GasShort fits on an icon' -ForEach @(
        @{ v = 0.0619; e = '.06' }, @{ v = 0.004; e = '<.01' }, @{ v = 1.04; e = '1' }, @{ v = 4.56; e = '4.6' },
        @{ v = 23.4; e = '23' }, @{ v = 512; e = '512' }, @{ v = 1500; e = '1.5K' }, @{ v = 670914; e = '671K' },
        @{ v = 1158374; e = '1.2M' }, @{ v = 25000000; e = '25M' }
    ) {
        $s = Format-GasShort $v
        $s | Should -Be $e
        $s.Length | Should -BeLessOrEqual 4
    }
    It 'Format-GasShort handles null' { Format-GasShort $null | Should -Be '?' }
    It 'Get-GasLevel thresholds' {
        Get-GasLevel -Gwei 1 -Amber 5 -Red 20 | Should -Be 'Green'
        Get-GasLevel -Gwei 5 -Amber 5 -Red 20 | Should -Be 'Amber'
        Get-GasLevel -Gwei 25 -Amber 5 -Red 20 | Should -Be 'Red'
        Get-GasLevel -Gwei $null -Amber 5 -Red 20 | Should -Be 'Unknown'
    }
    It 'transfer cost maths' {
        Get-TransferCost -Gwei 10 -Price 4000 | Should -BeGreaterThan 0.8399
        Get-TransferCost -Gwei 10 -Price 4000 | Should -BeLessThan 0.8401
    }
    It 'tooltip stays within 63 chars' {
        $snap = [pscustomobject]@{
            ETH = [pscustomobject]@{ LowGwei = 1234.5; AvgGwei = 2345.6; FastGwei = 3456.7 }
            PLS = [pscustomobject]@{ LowGwei = 12345678; AvgGwei = 23456789; FastGwei = 34567890 }
        }
        (Format-TrayTooltip -Snapshot $snap -Price @{ ETH = 99999; PLS = 99 }).Length | Should -BeLessOrEqual 63
    }
}

Describe 'Settings' {
    It 'merges partial settings onto defaults and sanitises' {
        $loaded = '{"IconChain":"PLS","IntervalSec":5,"Thresholds":{"ETH":{"Red":50}},"Rpc":{"PLS":["https://example.invalid","not-a-url"]}}' | ConvertFrom-Json
        $s = Merge-GasTraySettings -Loaded $loaded
        $s.IconChain | Should -Be 'PLS'
        $s.IntervalSec | Should -Be 10
        $s.Thresholds.ETH.Red | Should -Be 50
        $s.Thresholds.ETH.Amber | Should -Be 5
        @($s.Rpc.PLS).Count | Should -Be 1
        @($s.Rpc.ETH).Count | Should -BeGreaterThan 1
    }
    It 'round-trips through JSON on disk' {
        $p = Join-Path ([IO.Path]::GetTempPath()) ("gastray-test-{0}.json" -f [guid]::NewGuid())
        $s = Get-GasTrayDefaultSettings; $s.IconChain = 'PLS'; $s.IntervalSec = 60
        Save-GasTraySettings -Path $p -Settings $s
        $r = Read-GasTraySettings -Path $p
        $r.IconChain | Should -Be 'PLS'; $r.IntervalSec | Should -Be 60
        Remove-Item $p
    }
}

Describe 'Fallback logic (mocked)' {
    It 'falls back to eth_gasPrice when eth_feeHistory fails everywhere' {
        Mock -ModuleName GasTray.Core Invoke-EthRpc -ParameterFilter { $Method -eq 'eth_feeHistory' } { throw 'feeHistory unsupported' }
        Mock -ModuleName GasTray.Core Invoke-EthRpc -ParameterFilter { $Method -eq 'eth_gasPrice' } { [pscustomobject]@{ Result = '0x77359400'; Url = 'mock'; Errors = @() } }
        $g = Get-ChainGas -Chain ETH -RpcUrls @('https://mock')
        $g.Method | Should -Be 'eth_gasPrice'
        $g.AvgGwei | Should -Be 2
        $g.LowGwei | Should -Be 2
    }
    It 'Get-GasSnapshot never throws when every endpoint is dead' {
        $s = Get-GasTrayDefaultSettings
        $s.Rpc.ETH = @('https://127.0.0.1:1'); $s.Rpc.PLS = @('https://127.0.0.1:1'); $s.TimeoutSec = 2
        $snap = Get-GasSnapshot -Settings $s
        $snap.ETH | Should -BeNullOrEmpty
        $snap.PLS | Should -BeNullOrEmpty
        @($snap.Errors).Count | Should -Be 2
    }
}

Describe 'LIVE public endpoints' -Tag Live {
    It 'ETH default endpoints return sane gas' {
        $g = Get-ChainGas -Chain ETH
        $g.Method | Should -Be 'eth_feeHistory'
        $g.AvgGwei | Should -BeGreaterThan 0
        $g.AvgGwei | Should -BeLessThan 10000
        $g.LowGwei | Should -BeLessOrEqual $g.AvgGwei
        $g.AvgGwei | Should -BeLessOrEqual $g.FastGwei
        $script:Live.Add(('ETH default : low {0:N4} / avg {1:N4} / fast {2:N4} gwei (base {3:N4}) via {4}' -f $g.LowGwei, $g.AvgGwei, $g.FastGwei, $g.BaseGwei, $g.Url))
    }
    It 'PLS default endpoints return sane gas' {
        $g = Get-ChainGas -Chain PLS
        $g.Method | Should -Be 'eth_feeHistory'
        $g.AvgGwei | Should -BeGreaterThan 1000
        $script:Live.Add(('PLS default : low {0:N0} / avg {1:N0} / fast {2:N0} gwei (base {3:N0}) via {4}' -f $g.LowGwei, $g.AvgGwei, $g.FastGwei, $g.BaseGwei, $g.Url))
    }
    It 'ETH falls back past a dead first URL' {
        $urls = @('https://does-not-exist.invalid') + (Get-GasTrayDefaultRpc -Chain ETH)
        $g = Get-ChainGas -Chain ETH -RpcUrls $urls -TimeoutSec 5
        $g.Url | Should -Not -Be 'https://does-not-exist.invalid'
        @($g.Errors).Count | Should -BeGreaterOrEqual 1
        $script:Live.Add(('ETH fallback: avg {0:N4} gwei via {1} after error [{2}]' -f $g.AvgGwei, $g.Url, ($g.Errors -join '; ')))
    }
    It 'PLS falls back past a dead first URL' {
        $urls = @('https://does-not-exist.invalid') + (Get-GasTrayDefaultRpc -Chain PLS)
        $g = Get-ChainGas -Chain PLS -RpcUrls $urls -TimeoutSec 5
        $g.Url | Should -Not -Be 'https://does-not-exist.invalid'
        $script:Live.Add(('PLS fallback: avg {0:N0} gwei via {1}' -f $g.AvgGwei, $g.Url))
    }
    It 'endpoint <c> <u> answers eth_feeHistory' -ForEach $endpoints {
        $g = Get-ChainGas -Chain $c -RpcUrls @($u) -TimeoutSec 8
        $g.Method | Should -Be 'eth_feeHistory'
        $script:Live.Add(('{0} {1,-40} avg {2:N4} gwei' -f $c, $u, $g.AvgGwei))
    }
    It 'CoinGecko returns ETH and PLS AUD prices' {
        $p = Get-CoinPrice -Currency aud
        $p | Should -Not -BeNullOrEmpty
        $p.ETH | Should -BeGreaterThan 100
        $p.PLS | Should -BeGreaterThan 0
        $script:Live.Add(('Price AUD : ETH {0} / PLS {1}' -f $p.ETH, $p.PLS))
    }
    It 'price failure returns null (fiat hidden)' {
        Get-CoinPrice -BaseUrl 'https://does-not-exist.invalid/simple/price' -TimeoutSec 3 | Should -BeNullOrEmpty
    }
}

AfterAll {
    if ($script:Live.Count) {
        $out = Join-Path $PSScriptRoot 'live-results.txt'
        (@("Live run $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') on $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription), PowerShell $($PSVersionTable.PSVersion)") + $script:Live) |
            Set-Content -Path $out -Encoding UTF8
    }
}
