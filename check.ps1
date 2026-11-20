#Requires -Version 7
<#
.SYNOPSIS
  Checks one mod repo the way CI does: mod.json, luacheck, PSScriptAnalyzer, then the repo's own test.ps1.
.DESCRIPTION
  check.ps1 -Repo <mod repo> [-Tag v<version>] runs four steps; every step runs even when an earlier one failed:
    mod.json          the release rules (Test-ModJson in modid.ps1, a synced copy of the workspace's), with the UE4SS
                      built-in mod names from ue4ss-builtins.json; with -Tag, the tag must be v<mod.json version>
    luacheck          every *.lua with lint/.luacheckrc
    PSScriptAnalyzer  every *.ps1, *.psm1 and *.psd1 with lint/PSScriptAnalyzerSettings.psd1 (Error and Warning fail)
    tests             <repo>/test.ps1 in a child pwsh, with the pinned Lua first on PATH
  Both linters skip the folders build, .worktrees, unreal, native, ue4ss-src, ci and nucleus (anywhere in the path)
  and .git. The tools come from .tools/ (run setup.ps1 first). The summary goes to stdout and, when
  $env:GITHUB_STEP_SUMMARY is set, to the job summary. Exit 0 when all four pass, else 1.
.EXAMPLE
  ./setup.ps1; $env:NN_CI = '1'; ./check.ps1 -Repo ../mods/waypoints
#>
param([Parameter(Mandatory)] [string] $Repo, [string] $Tag)
$ErrorActionPreference = 'Stop'

$ExcludeDirs = @('build', '.worktrees', 'unreal', 'native', 'ue4ss-src', 'ci', 'nucleus', '.git')
$tools = Join-Path $PSScriptRoot '.tools'
$results = [ordered]@{}   # step -> @{ Ok; Lines }

function Add-Result([string] $step, [bool] $ok, [string[]] $lines = @()) { $results[$step] = @{ Ok = $ok; Lines = @($lines) } }

# Files under the repo with one of the extensions, skipping $ExcludeDirs; paths relative to the repo, with /.
function Get-RepoFiles([string[]] $ext) {
    $out = [Collections.Generic.List[string]]::new()
    $stack = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $stack.Push([IO.DirectoryInfo]::new($Repo))
    while ($stack.Count) {
        $d = $stack.Pop()
        foreach ($e in $d.EnumerateFileSystemInfos()) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($e -is [IO.DirectoryInfo]) { if ($ExcludeDirs -notcontains $e.Name) { $stack.Push($e) } }
            elseif ($ext -contains $e.Extension.ToLowerInvariant()) { $out.Add($e.FullName.Substring($Repo.Length + 1).Replace('\', '/')) }
        }
    }
    $arr = $out.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    , $arr
}

$Repo = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Repo).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $Repo -PathType Container)) { Write-Host "FAIL -Repo is not a folder: $Repo"; exit 1 }
$need = @{
    lua = Join-Path $tools 'lua\lua.exe'; luacheck = Join-Path $tools 'luacheck\luacheck.exe'
    PSScriptAnalyzer = Join-Path $tools 'modules\PSScriptAnalyzer'
}
$missing = @($need.Keys | Where-Object { -not (Test-Path -LiteralPath $need[$_]) } | Sort-Object)
if ($missing) { Write-Host "FAIL tools missing in $tools ($($missing -join ', ')); run setup.ps1 first"; exit 1 }
Write-Host "check: $Repo$(if ($Tag) { " at tag $Tag" })"

# --- mod.json ------------------------------------------------------------------------------------------------------
Write-Host '== mod.json'
try {
    . (Join-Path $PSScriptRoot 'modid.ps1')
    $errs = [Collections.Generic.List[string]]::new()
    $path = Join-Path $Repo 'mod.json'
    $mod = $null
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errs.Add('no mod.json at the repo root') }
    else {
        $jsonArgs = @{ Depth = 64; NoEnumerate = $true }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonArgs.DateKind = 'String' }
        try { $mod = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json @jsonArgs }
        catch { $errs.Add("mod.json is not valid JSON: $($_.Exception.Message)") }
    }
    if ($errs.Count -eq 0) {
        $builtins = @((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ue4ss-builtins.json') -Raw | ConvertFrom-Json).names)
        foreach ($e in (Test-ModJson -Mod $mod -Builtins $builtins).Errors) { $errs.Add($e) }
        if ($Tag) {
            $v = if ($mod -is [Management.Automation.PSCustomObject] -and $mod.version -is [string]) { $mod.version } else { '(none)' }
            if ($Tag -cne "v$v") { $errs.Add("tag $Tag does not match mod.json version $v") }
        }
    }
    $errs | ForEach-Object { Write-Host "  $_" }
    Add-Result 'mod.json' ($errs.Count -eq 0) $errs.ToArray()
} catch { Add-Result 'mod.json' $false @("check failed: $($_.Exception.Message)") }

# --- luacheck ------------------------------------------------------------------------------------------------------
Write-Host '== luacheck'
try {
    $lua = Get-RepoFiles @('.lua')
    Write-Host "  $($lua.Count) Lua files"
    if (-not $lua.Count) { Add-Result 'luacheck' $true }
    else {
        Push-Location -LiteralPath $Repo
        try {
            $out = @(& $need.luacheck --config (Join-Path $PSScriptRoot 'lint\.luacheckrc') --codes --formatter plain --no-color -- @lua 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
        } finally { Pop-Location }
        $out | ForEach-Object { Write-Host "  $_" }
        $found = @($out | Where-Object { $_ -match '^\S.*:\d+:\d+: ' })
        if ($code -ne 0 -and -not $found) { $found = @("luacheck exited $code") + $out }
        Add-Result 'luacheck' ($code -eq 0) $found
    }
} catch { Add-Result 'luacheck' $false @("check failed: $($_.Exception.Message)") }

# --- PSScriptAnalyzer ----------------------------------------------------------------------------------------------
Write-Host '== PSScriptAnalyzer'
try {
    Import-Module (Get-ChildItem -LiteralPath $need.PSScriptAnalyzer -Recurse -Filter 'PSScriptAnalyzer.psd1' | Select-Object -First 1).FullName -Force
    $settings = Join-Path $PSScriptRoot 'lint\PSScriptAnalyzerSettings.psd1'
    $found = [Collections.Generic.List[string]]::new()
    $psFiles = Get-RepoFiles @('.ps1', '.psm1', '.psd1')
    Write-Host "  $($psFiles.Count) PowerShell files"
    foreach ($f in $psFiles) {
        $ev = $null
        $recs = @(Invoke-ScriptAnalyzer -Path (Join-Path $Repo $f) -Settings $settings -ErrorVariable ev -ErrorAction SilentlyContinue)
        foreach ($r in $recs) {
            if ("$($r.Severity)" -in 'Error', 'Warning', 'ParseError') { $found.Add("${f}:$($r.Line):$($r.RuleName): $($r.Message)") }
        }
        foreach ($e in @($ev)) { if ($e) { $found.Add("${f}: PSScriptAnalyzer error: $($e.Exception.Message)") } }
    }
    $found | ForEach-Object { Write-Host "  $_" }
    Add-Result 'PSScriptAnalyzer' ($found.Count -eq 0) $found.ToArray()
} catch { Add-Result 'PSScriptAnalyzer' $false @("check failed: $($_.Exception.Message)") }

# --- tests ---------------------------------------------------------------------------------------------------------
Write-Host '== tests'
try {
    $test = Join-Path $Repo 'test.ps1'
    if (-not (Test-Path -LiteralPath $test -PathType Leaf)) { Add-Result 'tests' $false @('no test.ps1 at the repo root') }
    else {
        $oldPath = $env:PATH
        $env:PATH = (Split-Path $need.lua) + [IO.Path]::PathSeparator + $env:PATH
        $pwsh = (Get-Process -Id $PID).Path
        Push-Location -LiteralPath $Repo
        try {
            $out = @(& $pwsh -NoProfile -NonInteractive -File $test 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
        } finally { Pop-Location; $env:PATH = $oldPath }
        $out | ForEach-Object { Write-Host "  | $_" }
        if ($code -eq 0) { Add-Result 'tests' $true }
        else {
            $names = $out | ForEach-Object { if ($_ -match '^Unit tests failed: (.+)$') { $Matches[1] } } | Select-Object -Last 1
            Add-Result 'tests' $false @(if ($names) { $names } else { "test.ps1 exited $code" })
        }
    }
} catch { Add-Result 'tests' $false @("check failed: $($_.Exception.Message)") }

# --- summary -------------------------------------------------------------------------------------------------------
$md = [Collections.Generic.List[string]]::new()
$md.Add("### ci: $(Split-Path $Repo -Leaf)$(if ($Tag) { " ($Tag)" })")
$md.Add('')
Write-Host ''
Write-Host '== summary'
foreach ($k in $results.Keys) {
    $r = $results[$k]
    if ($r.Ok) {
        Write-Host "$k ok"; $md.Add("- ${k}: ok")
    } elseif ($k -eq 'tests') {
        Write-Host "tests FAILED: $($r.Lines -join '; ')"; $md.Add("- tests: **FAILED**: $($r.Lines -join '; ')")
    } else {
        Write-Host "$k FAILED"; $md.Add("- ${k}: **FAILED**")
        foreach ($l in $r.Lines) { Write-Host "  $l"; $md.Add("  - ``$($l.Replace('`', "'"))``") }
    }
}
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $md -Encoding utf8 }
$bad = @($results.Values | Where-Object { -not $_.Ok }).Count
exit ([int] ($bad -gt 0))
