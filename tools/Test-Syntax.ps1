# Parses every .ps1/.psm1 in the repo with the PowerShell parser and runs PSScriptAnalyzer if present.
$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $root -Recurse -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
$bad = 0
foreach ($f in $files) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    '{0,-45} parse errors: {1}' -f $f.FullName.Substring($root.Length + 1), $errs.Count
    foreach ($e in $errs) { "    L$($e.Extent.StartLineNumber): $($e.Message)"; $bad++ }
}
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $excl = @('PSAvoidUsingWriteHost', 'PSUseShouldProcessForStateChangingFunctions', 'PSUseApprovedVerbs', 'PSReviewUnusedParameter', 'PSUseSingularNouns')
    $res = foreach ($f in $files) { Invoke-ScriptAnalyzer -Path $f.FullName -ExcludeRule $excl }
    "PSScriptAnalyzer: $(@($res).Count) finding(s) (excluded style rules: $($excl -join ', '))"
    $res | Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 220
    foreach ($ver in @('5.1', '7.0')) {
        $compat = foreach ($f in $files) {
            Invoke-ScriptAnalyzer -Path $f.FullName -IncludeRule PSUseCompatibleSyntax -Settings @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @($ver) } } }
        }
        "PSUseCompatibleSyntax target $ver : $(@($compat).Count) finding(s)"
        $compat | Format-Table RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 220
    }
}
if ($bad) { exit 1 }
