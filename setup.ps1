#Requires -Version 7
<#
.SYNOPSIS
  Downloads, verifies and installs the CI tools pinned in tools.json into .tools/ (next to this script).
.DESCRIPTION
  Each tool is downloaded over HTTPS from its url in tools.json and its SHA-256 compared with the pinned value before
  anything is extracted or run; a mismatch stops with exit 1 and leaves nothing installed. Installed:
    .tools/lua/lua.exe                         Lua, built from the pinned source with MSVC (found with vswhere)
    .tools/luacheck/luacheck.exe
    .tools/modules/PSScriptAnalyzer/<ver>/     the PSGallery package, extracted
    .tools/actionlint/actionlint.exe
  A tool already installed at its pinned version and hash (.tools/<name>/.pin) is kept.
  -Path prints the tool folders (lua, luacheck, actionlint), one per line, and installs nothing; exit 1 if a tool is
  missing.
.EXAMPLE
  ./setup.ps1
  ./setup.ps1 -Path
#>
param([switch] $Path)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Join-Path $PSScriptRoot '.tools'
$spec = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'tools.json') -Raw | ConvertFrom-Json
$exe = @{ lua = 'lua\lua.exe'; luacheck = 'luacheck\luacheck.exe'; actionlint = 'actionlint\actionlint.exe' }
$allowed = '^https://(www\.lua\.org/ftp/|github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/releases/download/|www\.powershellgallery\.com/api/v2/package/)'

function Pin($t) { "$($t.name) $($t.version) $($t.sha256)" }
function Installed($t) {
    $pin = Join-Path $root "$($t.name)\.pin"
    (Test-Path -LiteralPath $pin) -and (Get-Content -LiteralPath $pin -Raw).Trim() -ceq (Pin $t)
}

if ($Path) {
    $missing = @($spec.tools | Where-Object { -not (Installed $_) } | ForEach-Object name)
    if ($missing) { Write-Host "FAIL not installed: $($missing -join ', '); run setup.ps1"; exit 1 }
    foreach ($k in 'lua', 'luacheck', 'actionlint') { Split-Path (Join-Path $root $exe[$k]) }
    exit 0
}

function Get-Verified($t) {
    if ($t.url -cnotmatch $allowed) { throw "$($t.name): url $($t.url) is not from lua.org, github.com releases or PSGallery" }
    if ($t.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "$($t.name): sha256 is not 64 lowercase hex digits" }
    $dl = Join-Path $root 'dl'
    New-Item -ItemType Directory -Force $dl | Out-Null
    $file = Join-Path $dl "$($t.name)-$($t.version).download"
    Invoke-WebRequest -Uri $t.url -OutFile $file -MaximumRedirection 5 -UseBasicParsing
    $got = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -cne $t.sha256) {
        Remove-Item -LiteralPath $file -Force
        throw "$($t.name) $($t.version): SHA-256 $got does not match the pinned $($t.sha256); nothing installed"
    }
    $file
}

function Build-Lua([string] $src, [string] $out) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'lua: vswhere.exe not found; install Visual Studio with the C++ tools' }
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vs) { throw 'lua: no Visual Studio with the x64 C++ tools (vswhere)' }
    $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
    # Every core and library file plus lua.c (the interpreter); luac.c is the separate compiler. Flags as Lua's makefile.
    $files = (Get-ChildItem -LiteralPath $src -Filter *.c | Where-Object Name -cne 'luac.c' | ForEach-Object { "`"$($_.FullName)`"" }) -join ' '
    New-Item -ItemType Directory -Force $out | Out-Null
    $obj = Join-Path $src 'obj'
    New-Item -ItemType Directory -Force $obj | Out-Null
    $cmd = "call `"$vcvars`" >nul && cl /nologo /O2 /MT /W1 /DLUA_COMPAT_5_3 /Fo`"$obj\\`" /Fe`"$out\lua.exe`" $files"
    $log = & cmd.exe /d /c $cmd 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $out 'lua.exe'))) {
        $log | ForEach-Object { Write-Host "  | $_" }
        throw "lua: the MSVC build failed (exit $LASTEXITCODE)"
    }
}

New-Item -ItemType Directory -Force $root | Out-Null
try {
    foreach ($t in $spec.tools) {
        if (Installed $t) { Write-Host "$($t.name) $($t.version): installed"; continue }
        $file = Get-Verified $t
        $dest = Join-Path $root $t.name
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        $stage = Join-Path $root "stage-$($t.name)"
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -Force $stage | Out-Null
        switch ($t.name) {
            'lua' {
                # Windows' own bsdtar (System32), not another tar on PATH (Git's can't take C:\ paths).
                & (Join-Path $env:SystemRoot 'System32\tar.exe') -xzf $file -C $stage
                if ($LASTEXITCODE -ne 0) { throw "lua: could not extract $file" }
                Build-Lua (Join-Path $stage "lua-$($t.version)\src") $dest
                $v = & (Join-Path $dest 'lua.exe') -v 2>&1
                if ("$v" -notmatch [regex]::Escape("Lua $($t.version)")) { throw "lua: the built lua.exe reports '$v'" }
            }
            'luacheck' {
                New-Item -ItemType Directory -Force $dest | Out-Null
                Copy-Item -LiteralPath $file (Join-Path $dest 'luacheck.exe')
            }
            'PSScriptAnalyzer' {
                $zip = Join-Path $stage 'p.zip'
                Copy-Item -LiteralPath $file $zip
                Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $stage 'x')
                $mod = Join-Path $root "modules\PSScriptAnalyzer\$($t.version)"
                if (Test-Path -LiteralPath $mod) { Remove-Item -LiteralPath $mod -Recurse -Force }
                New-Item -ItemType Directory -Force $mod | Out-Null
                # The package's NuGet metadata isn't part of the module.
                Get-ChildItem -LiteralPath (Join-Path $stage 'x') -Force |
                    Where-Object { $_.Name -cnotin '_rels', 'package', '[Content_Types].xml' -and $_.Extension -ne '.nuspec' } |
                    Copy-Item -Destination $mod -Recurse
                New-Item -ItemType Directory -Force $dest | Out-Null
            }
            'actionlint' {
                $zip = Join-Path $stage 'a.zip'
                Copy-Item -LiteralPath $file $zip
                Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $stage 'x')
                New-Item -ItemType Directory -Force $dest | Out-Null
                Copy-Item -LiteralPath (Join-Path $stage 'x\actionlint.exe') $dest
            }
            default { throw "tools.json names an unknown tool '$($t.name)'" }
        }
        Remove-Item -LiteralPath $stage -Recurse -Force
        Set-Content -LiteralPath (Join-Path $dest '.pin') -Value (Pin $t) -Encoding ascii
        Write-Host "$($t.name) $($t.version): installed (SHA-256 verified)"
    }
} catch {
    Write-Host "FAIL setup: $($_.Exception.Message)"
    exit 1
}
exit 0
