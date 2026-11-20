#Requires -Version 7
<#
.SYNOPSIS
  Self-test of the ci repo: check.ps1 against fixture repos (tests/fixtures/good and broken copies of it), the
  workflows' pins and the bad-pin step, the setup refusals that need no network, actionlint, and lint of this repo's
  own scripts. Needs the tools from setup.ps1. Exit 0 when every case passes.
.EXAMPLE
  ./setup.ps1; ./tests/run-tests.ps1
#>
$ErrorActionPreference = 'Stop'
$ci = Split-Path $PSScriptRoot
$check = Join-Path $ci 'check.ps1'
$good = Join-Path $PSScriptRoot 'fixtures\good'
$actionlint = Join-Path $ci '.tools\actionlint\actionlint.exe'
$pwsh = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) "nn-ci-test-$PID"

$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $name, $detail) {
    if ($cond) { $script:passed++; Write-Host "PASS $name" }
    else { $script:failed++; Write-Host "FAIL $name$(if ($null -ne $detail) { "`n     $(("$detail" -split "`n") -join "`n     ")" })" }
}

# A copy of the good fixture, changed by $edit (a script block taking the copy's folder).
$n = 0
function New-Fixture([scriptblock] $edit) {
    $script:n++
    $dir = Join-Path $tmp "repo$script:n"
    Copy-Item -LiteralPath $good -Destination $dir -Recurse
    if ($edit) { & $edit $dir }
    $dir
}
function Set-ModJson([string] $dir, [scriptblock] $edit) {
    $p = Join-Path $dir 'mod.json'
    $m = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    & $edit $m
    Set-Content -LiteralPath $p -Value ($m | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM
}
function Invoke-Check([string] $dir, [string[]] $extra = @()) {
    $env:GITHUB_STEP_SUMMARY = Join-Path $tmp "summary$script:n.md"
    try { $out = & $pwsh -NoProfile -NonInteractive -File $check -Repo $dir @extra 2>&1 | Out-String }
    finally { $code = $LASTEXITCODE; Remove-Item Env:GITHUB_STEP_SUMMARY }
    $summary = if ($out -match '(?s)== summary\r?\n(.*)$') { $Matches[1] } else { '' }
    [pscustomobject]@{ Code = $code; Out = $out; Summary = $summary }
}
function Has-Line([string] $text, [string] $line) { $text -split '\r?\n' -ccontains $line }

foreach ($t in 'lua\lua.exe', 'luacheck\luacheck.exe', 'actionlint\actionlint.exe') {
    if (-not (Test-Path -LiteralPath (Join-Path $ci ".tools\$t"))) { Write-Host "FAIL tools missing ($t); run setup.ps1 first"; exit 1 }
}
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    # --- clean repo: all four steps ok, exit 0; build/ and nucleus/ hold lint errors that must be skipped ----------
    $r = Invoke-Check (New-Fixture $null)
    Ok ($r.Code -eq 0) 'clean: exit 0' $r.Out
    foreach ($l in 'mod.json ok', 'luacheck ok', 'PSScriptAnalyzer ok', 'tests ok') { Ok (Has-Line $r.Summary $l) "clean: '$l'" $r.Summary }
    Ok ($r.Out -match '(?m)^  2 Lua files' -and $r.Out -match '(?m)^  2 PowerShell files') 'clean: build/ and nucleus/ are not linted' $r.Out
    $sum = Get-Content -LiteralPath (Join-Path $tmp "summary$n.md") -Raw
    Ok ($sum -match '(?m)^- tests: ok') 'clean: the job summary is written' $sum

    # --- broken mod.json: the release.ps1 message per field; the other steps still run; exit 1 --------------------
    $pinned = 'v3.0.1-1181-g83330635'
    $cases = [ordered]@{
        'scope All'          = @{ Edit = { param($m) $m.scope = 'All' }; Want = "mod.json field scope: 'All' is not one of client, host, host-plus, both" }
        'missing version'    = @{ Edit = { param($m) $m.PSObject.Properties.Remove('version') }; Want = 'mod.json field version: missing or not a non-empty string' }
        'www id'             = @{ Edit = { param($m) $m.id = 'www.github.com/x.y' }; Want = "mod.json field id: 'www.github.com/x.y': an id is not a URL; use <owner>.<mod> or github.com/<owner>.<mod>" }
        'dependsOn Keybinds' = @{ Edit = { param($m) $m.dependsOn = @([pscustomobject]@{ id = 'Keybinds'; version = '>=1.0.0' }) }; Want = "mod.json field dependsOn[0]: 'Keybinds' is the UE4SS built-in mod Keybinds; UE4SS always ships it, so a released mod doesn't list it" }
        'wrong ue4ss'        = @{ Edit = { param($m) $m.ue4ss = 'v3.0.1-0' }; Want = "mod.json field ue4ss: 'v3.0.1-0' is not the pinned $pinned" }
    }
    foreach ($k in $cases.Keys) {
        $c = $cases[$k]
        $dir = New-Fixture { param($d) Set-ModJson $d $c.Edit }
        $r = Invoke-Check $dir
        Ok ($r.Code -eq 1) "mod.json ${k}: exit 1" $r.Out
        Ok ((Has-Line $r.Summary 'mod.json FAILED') -and (Has-Line $r.Summary "  $($c.Want)")) "mod.json ${k}: the release.ps1 message" $r.Summary
        Ok ((Has-Line $r.Summary 'luacheck ok') -and (Has-Line $r.Summary 'PSScriptAnalyzer ok') -and (Has-Line $r.Summary 'tests ok')) "mod.json ${k}: the other steps still ran" $r.Summary
    }
    $dir = New-Fixture { param($d) Set-ModJson $d { param($m) foreach ($c in $cases.Values) { & $c.Edit $m } } }
    $r = Invoke-Check $dir
    $all = @($cases.Values | ForEach-Object { Has-Line $r.Summary "  $($_.Want)" }) -notcontains $false
    Ok ($r.Code -eq 1 -and $all) 'mod.json all five at once: every failure in the summary' $r.Summary
    $dir = New-Fixture { param($d) Set-Content -LiteralPath (Join-Path $d 'mod.json') -Value '{ "id": ' }
    $r = Invoke-Check $dir
    Ok ($r.Code -eq 1 -and $r.Summary -match '(?m)^  mod\.json is not valid JSON') 'mod.json not JSON: refused' $r.Summary

    # --- failing test ------------------------------------------------------------------------------------------
    $dir = New-Fixture { param($d) (Get-Content -LiteralPath (Join-Path $d 'test.ps1') -Raw).Replace('$failed = @()', '$failed = @(''main_test'')') | Set-Content -LiteralPath (Join-Path $d 'test.ps1') }
    $r = Invoke-Check $dir
    Ok ($r.Code -eq 1 -and (Has-Line $r.Summary 'tests FAILED: main_test')) 'failing test: tests FAILED: <name>, exit 1' $r.Summary
    $dir = New-Fixture { param($d) Remove-Item -LiteralPath (Join-Path $d 'test.ps1') }
    $r = Invoke-Check $dir
    Ok ($r.Code -eq 1 -and (Has-Line $r.Summary 'tests FAILED: no test.ps1 at the repo root')) 'no test.ps1: FAILED' $r.Summary

    # --- lint errors: file:line:code listed, exit 1 --------------------------------------------------------------
    $dir = New-Fixture { param($d) $f = Join-Path $d 'Scripts\main.lua'; (Get-Content -LiteralPath $f -Raw).Replace('return M', "print(undefined_global_x)`nreturn M") | Set-Content -LiteralPath $f }
    $r = Invoke-Check $dir
    Ok ($r.Code -eq 1 -and (Has-Line $r.Summary 'luacheck FAILED') -and $r.Summary -match '(?m)^  Scripts/main\.lua:\d+:\d+: \(W113\) accessing undefined variable ''undefined_global_x''') 'lint: undefined Lua global listed' $r.Summary
    $dir = New-Fixture { param($d) Add-Content -LiteralPath (Join-Path $d 'tool.ps1') -Value 'gci | Out-Null' }
    $r = Invoke-Check $dir
    Ok ($r.Code -eq 1 -and (Has-Line $r.Summary 'PSScriptAnalyzer FAILED') -and $r.Summary -match '(?m)^  tool\.ps1:\d+:PSAvoidUsingCmdletAliases: ') 'lint: PSScriptAnalyzer warning listed' $r.Summary
    Ok ((Has-Line $r.Summary 'luacheck ok') -and (Has-Line $r.Summary 'tests ok')) 'lint: the other steps still ran' $r.Summary

    # --- tags ---------------------------------------------------------------------------------------------------
    $dir = New-Fixture $null
    $r = Invoke-Check $dir @('-Tag', 'v0.3.0')
    Ok ($r.Code -eq 0 -and (Has-Line $r.Summary 'mod.json ok')) 'tag v0.3.0 on 0.3.0: passes' $r.Summary
    $r = Invoke-Check $dir @('-Tag', 'v0.3.1')
    Ok ($r.Code -eq 1 -and (Has-Line $r.Summary '  tag v0.3.1 does not match mod.json version 0.3.0')) 'tag v0.3.1 on 0.3.0: refused' $r.Summary

    # --- workflows: SHA pins, the caller's two pins, the bad-pin step, actionlint ---------------------------------
    $wf = @(Get-ChildItem -LiteralPath (Join-Path $ci '.github\workflows') -Filter *.yml) + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures\caller') -Filter *.yml)
    foreach ($f in $wf) {
        $uses = @(Select-String -LiteralPath $f.FullName -Pattern '^\s*(-\s+)?uses:\s*(.*)$' | ForEach-Object { $_.Matches[0].Groups[2].Value.Trim() })
        $bad = @($uses | Where-Object { $_ -cnotmatch '^(actions/checkout|NuclearNightmare-Community/ci/\.github/workflows/mod\.yml)@[0-9a-f]{40} # v\d+\.\d+\.\d+$' })
        Ok ($uses.Count -gt 0 -and -not $bad) "pins: every uses: in $($f.Name) is a full SHA with a # vX.Y.Z comment, actions/checkout or ci only" ($bad -join "`n")
        $text = Get-Content -LiteralPath $f.FullName -Raw
        Ok ($text -match '(?m)^permissions: \{\}' -and $text -notmatch 'pull_request_target' -and $text -match 'contents: read') "permissions: $($f.Name) has permissions: {} and contents: read, no pull_request_target"
        if ($text -match 'actions/checkout@') { Ok (([regex]::Matches($text, 'actions/checkout@')).Count -eq ([regex]::Matches($text, 'persist-credentials: false')).Count) "checkout: persist-credentials: false in every checkout of $($f.Name)" }
    }
    $caller = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\caller\ci.yml') -Raw
    $u = [regex]::Match($caller, 'mod\.yml@([0-9a-f]{40})').Groups[1].Value
    $p = [regex]::Match($caller, 'ci-ref:\s*([0-9a-f]{40})').Groups[1].Value
    Ok ($u -and $u -ceq $p) 'caller: the uses: SHA equals ci-ref' "uses $u, ci-ref $p"

    $mod = Get-Content -LiteralPath (Join-Path $ci '.github\workflows\mod.yml') -Raw
    $pinStep = $mod.IndexOf('- name: Check the pins')
    $ciCheckout = $mod.IndexOf('repository: NuclearNightmare-Community/ci')
    Ok ($pinStep -gt 0 -and $ciCheckout -gt $pinStep) 'bad pin: the pin check runs before the checkout of ci'
    $m = [regex]::Match($mod, '(?s)- name: Check the pins.*?run: \|\r?\n(.*?)\r?\n\r?\n')
    $script = ($m.Groups[1].Value -split '\r?\n' | ForEach-Object { $_ -replace '^ {10}', '' }) -join "`n"
    $stepFile = Join-Path $tmp 'pins.ps1'
    Set-Content -LiteralPath $stepFile -Value $script
    $pinCases = @(
        @{ Ci = 'main'; Nucleus = ''; Code = 1; Want = "input ci-ref must be a full 40-hex ci commit SHA (got 'main')" },
        @{ Ci = '0123456789ABCDEF0123456789abcdef01234567'; Nucleus = ''; Code = 1; Want = 'input ci-ref' },
        @{ Ci = "0123456789abcdef0123456789abcdef01234567`n"; Nucleus = ''; Code = 1; Want = 'input ci-ref' },
        @{ Ci = '0123456789abcdef0123456789abcdef01234567'; Nucleus = "v0.15.0`n"; Code = 1; Want = 'input nucleus-ref' },
        @{ Ci = '0123456789abcdef0123456789abcdef01234567'; Nucleus = ''; Code = 0; Want = $null },
        @{ Ci = '0123456789abcdef0123456789abcdef01234567'; Nucleus = 'v0.15.0'; Code = 0; Want = $null },
        @{ Ci = '0123456789abcdef0123456789abcdef01234567'; Nucleus = 'main; rm -rf /'; Code = 1; Want = 'input nucleus-ref' }
    )
    foreach ($c in $pinCases) {
        $env:CI_REF = $c.Ci; $env:NUCLEUS_REF = $c.Nucleus
        try { $out = & $pwsh -NoProfile -NonInteractive -File $stepFile 2>&1 | Out-String } finally { $code = $LASTEXITCODE; Remove-Item Env:CI_REF, Env:NUCLEUS_REF }
        Ok ($code -eq $c.Code -and (-not $c.Want -or $out.Contains($c.Want))) "bad pin: ci-ref '$($c.Ci)' nucleus-ref '$($c.Nucleus)' -> exit $($c.Code)" $out
    }

    $lint = & $actionlint -no-color @($wf.FullName) 2>&1 | Out-String
    Ok ($LASTEXITCODE -eq 0 -and -not $lint.Trim()) 'actionlint: no findings in the workflows and the caller fixture' $lint

    # --- setup refusals (no download) and the shared exclusions ---------------------------------------------------
    $sdir = Join-Path $tmp 'setup'
    New-Item -ItemType Directory -Force $sdir | Out-Null
    Copy-Item -LiteralPath (Join-Path $ci 'setup.ps1') $sdir
    Set-Content -LiteralPath (Join-Path $sdir 'tools.json') -Value '{ "tools": [ { "name": "luacheck", "version": "1.2.0", "url": "https://example.com/luacheck.exe", "sha256": "0f1c69c4d09f1ebb4d8df14c215e4553e2e639bd4cb7bf3c639b0daa6198317b" } ] }'
    $out = & $pwsh -NoProfile -NonInteractive -File (Join-Path $sdir 'setup.ps1') 2>&1 | Out-String
    Ok ($LASTEXITCODE -eq 1 -and $out -match 'is not from lua\.org, github\.com releases or PSGallery' -and -not (Test-Path (Join-Path $sdir '.tools\luacheck'))) 'setup: a url outside the allowed sources is refused' $out
    $spec = Get-Content -LiteralPath (Join-Path $ci 'tools.json') -Raw | ConvertFrom-Json
    Ok (@($spec.tools | Where-Object { $_.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $_.version -cnotmatch '^\d+\.\d+\.\d+$' }).Count -eq 0 -and $spec.tools.Count -eq 4) 'tools.json: four tools, exact versions, SHA-256 each'

    $rc = Get-Content -LiteralPath (Join-Path $ci 'lint\.luacheckrc') -Raw
    $rcDirs = @([regex]::Matches([regex]::Match($rc, 'exclude_files = \{([^}]*)\}').Groups[1].Value, '"([^"/]+)/\*\*"') | ForEach-Object { $_.Groups[1].Value })
    $ckDirs = @([regex]::Match((Get-Content -LiteralPath $check -Raw), '\$ExcludeDirs = @\(([^)]*)\)').Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") } | Where-Object { $_ -ne '.git' })
    Ok (($rcDirs -join ',') -ceq ($ckDirs -join ',')) 'exclusions: check.ps1 and .luacheckrc skip the same folders' "luacheckrc $($rcDirs -join ','); check.ps1 $($ckDirs -join ',')"

    # --- this repo's own scripts pass the shared PowerShell settings ----------------------------------------------
    Import-Module (Get-ChildItem -LiteralPath (Join-Path $ci '.tools\modules\PSScriptAnalyzer') -Recurse -Filter 'PSScriptAnalyzer.psd1' | Select-Object -First 1).FullName -Force
    $own = Get-ChildItem -LiteralPath $ci -Recurse -Include *.ps1, *.psd1 | Where-Object { $_.FullName -notmatch '\\(\.tools|\.worktrees|fixtures)\\' }
    $found = @(foreach ($f in $own) { Invoke-ScriptAnalyzer -Path $f.FullName -Settings (Join-Path $ci 'lint\PSScriptAnalyzerSettings.psd1') | ForEach-Object { "$($f.Name):$($_.Line):$($_.RuleName)" } })
    Ok (-not $found) "own scripts: PSScriptAnalyzer clean ($($own.Count) files)" ($found -join "`n")
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host "run-tests: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
