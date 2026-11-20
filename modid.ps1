<#
.SYNOPSIS
  Mod id helpers for the release tools (distribution story 13; _bmad-output/specs/spec-distribution-v0/mod-ids.md).
  Dot-source it: . (Join-Path $PSScriptRoot 'modid.ps1')

  The block between "# BEGIN modid" and "# END modid" is the id normalizer and the displayName check. verify.ps1 and
  base-pack/Install-NNMods.ps1 run as standalone copies, so they carry a byte-identical copy of the block;
  tests/run-modid-tests.ps1 and base-pack.ps1 fail when a copy drifts. Nucleus's lua/pkg/modid.lua implements the same
  rule; both run the cases in tests/modid-cases.json. Keep the block ASCII and runnable on Windows PowerShell 5.1.

  Outside the block (release tools only):
    Get-ModPart <normalized id>                  -> the mod part (after the last dot)
    Test-ModIdOwner -Id -Repo [-Installer]       -> $null when <owner>/<name> owns the id, else a message
    Get-Ue4ssBuiltinMods -BaseJson <base.json>   -> the folder names the pinned UE4SS zip ships under ue4ss/Mods/
    Test-ModJson -Mod <parsed mod.json> -Builtins <names> [-TagVersion <x.y.z>]
                                                 -> @{ Errors = <messages>; DependsOn = <normalized entries> }
    $SemverRx, $NameRx, $PinnedUe4ss             -> the mod.json rules' constants

  The mod.json rules exist once, here: release.ps1 refuses on the first error, and the public CI repo
  (NuclearNightmare-Community/ci, a byte copy of this file written by tools/ci/sync.ps1) lists them all.
#>

# BEGIN modid
# Mod id normalizer (mod-ids.md, "Normalizer"). Canonical copy: tools/release/modid.ps1, cases:
# tools/release/tests/modid-cases.json, Lua twin: Nucleus lua/pkg/modid.lua. Never throws.
#   ConvertTo-ModId $x       -> @{ Id = '<owner>.<mod>'; Error = $null } or @{ Id = $null; Error = '<message>' }
#   Test-ModDisplayName $x   -> $null when $x is a valid displayName, else a message
# Only ASCII letters are lowercased and the length is counted in UTF-8 bytes, as Lua does.
function ConvertTo-ModId {
    param([AllowNull()] [AllowEmptyString()] [object] $Id)
    $forms = 'use <owner>.<mod> or github.com/<owner>.<mod>'
    if ($Id -isnot [string]) { return @{ Id = $null; Error = 'an id must be a string' } }
    $raw = [string] $Id
    if ($raw.Length -eq 0) { return @{ Id = $null; Error = 'an id must not be empty' } }
    if ($raw.Length -gt 200 -or [Text.Encoding]::UTF8.GetByteCount($raw) -gt 200) {
        return @{ Id = $null; Error = 'an id must be at most 200 bytes' }
    }
    $chars = $raw.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $n = [int] $chars[$i]
        if ($n -ge 65 -and $n -le 90) { $chars[$i] = [char] ($n + 32) }
    }
    $s = -join $chars
    if ($s.StartsWith('github.com/', [StringComparison]::Ordinal)) { $s = $s.Substring(11) }
    if ($s.Contains('://') -or $s.StartsWith('www.', [StringComparison]::Ordinal)) {
        return @{ Id = $null; Error = "an id is not a URL; $forms" }
    }
    $slash = $s.IndexOf('/')
    if ($slash -ge 0 -and $s.Substring(0, $slash).Contains('.')) {
        return @{ Id = $null; Error = "ids on hosts other than GitHub are not supported yet; $forms" }
    }
    if (-not $s.Contains('.')) { return @{ Id = $null; Error = "an id needs a namespace; $forms" } }
    if ($s -cnotmatch '\A[a-z0-9-]+\.[a-z0-9-]+\z') {
        return @{ Id = $null; Error = "an id must be <owner>.<mod> with only a-z, 0-9 and - in each part; $forms" }
    }
    return @{ Id = $s; Error = $null }
}

function Test-ModDisplayName {
    param([AllowNull()] [AllowEmptyString()] [object] $Name)
    if ($Name -isnot [string]) { return 'displayName must be a string' }
    $s = [string] $Name
    if ($s.Length -lt 1 -or $s.Length -gt 64) { return 'displayName must be 1 to 64 characters' }
    if ($s -cmatch '[\x00-\x1F\x7F]') { return 'displayName must not contain control characters' }
    if ($s.StartsWith(' ') -or $s.EndsWith(' ')) { return 'displayName must not start or end with a space' }
    return $null
}

# Mod scopes (index-format.md, "scope"): who needs the mod installed. Case-sensitive, in the order messages use.
#   client: works without the host; an unmodded host is fine.
#   host: only the host needs it; unmodded clients still play. Nucleus keeps it dormant on clients.
#   host-plus: the host needs it; clients who have it get the full experience, unmodded clients still play.
#   both: the host and every client need it.
#   Test-ModScope $x -> $null when $x is one of $ModScopes, else "scope: '<x>' is not one of client, host, host-plus, both"
$ModScopes = @('client', 'host', 'host-plus', 'both')
function Test-ModScope {
    param([AllowNull()] [AllowEmptyString()] [object] $Scope)
    if ($Scope -is [string] -and $ModScopes -ccontains $Scope) { return $null }
    $shown = if ($null -eq $Scope) { '' } else { [string] $Scope }
    if ($shown.Length -gt 40) { $shown = $shown.Substring(0, 40) + '...' }
    return "scope: '$shown' is not one of $($ModScopes -join ', ')"
}
# END modid

# Get-ModPart 'owner.mod' -> 'mod': everything after the last dot of a normalized id.
function Get-ModPart {
    param([Parameter(Mandatory)] [string] $Id)
    return $Id.Substring($Id.LastIndexOf('.') + 1)
}

# Test-ModIdOwner -Id <id> -Repo <owner>/<name> [-Installer] -> $null when the repo owns the id (mod-ids.md,
# "Ownership"): the namespace equals the repo owner and the mod part equals the repo name (both case-insensitive), or
# with -Installer, '<repo name>-installer'. Otherwise a message naming the id and the repo.
function Test-ModIdOwner {
    param([AllowNull()] [object] $Id, [AllowNull()] [object] $Repo, [switch] $Installer)
    $n = ConvertTo-ModId $Id
    if ($n.Error) { return "id: $($n.Error)" }
    if ($Repo -isnot [string] -or $Repo -cnotmatch '\A([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)\z') {
        return "repo must be <owner>/<name> on GitHub, for id '$($n.Id)'"
    }
    # ASCII only (the pattern above), so ToLowerInvariant can't map a non-ASCII letter onto an ASCII one.
    $owner = $Matches[1].ToLowerInvariant()
    $name = $Matches[2].ToLowerInvariant()
    $dot = $n.Id.LastIndexOf('.')
    $ns = $n.Id.Substring(0, $dot)
    $part = $n.Id.Substring($dot + 1)
    $want = if ($Installer) { "$name-installer" } else { $name }
    if ($ns -cne $owner -or $part -cne $want) {
        $rule = if ($Installer) { "an installer's id must be <repo owner>.<repo name>-installer" } else { 'an id must be <repo owner>.<repo name>' }
        return "repo '$Repo' does not own id '$($n.Id)' ($rule, case-insensitive)"
    }
    return $null
}

# Get-Ue4ssBuiltinMods -BaseJson base-pack/base.json -> the folder names under ue4ss/Mods/ among base.json's
# ue4ss.files keys (recorded from the pinned UE4SS zip; includes 'shared'). Released mods may not depend on them.
function Get-Ue4ssBuiltinMods {
    param([Parameter(Mandatory)] [string] $BaseJson)
    $base = Get-Content -LiteralPath $BaseJson -Raw | ConvertFrom-Json
    $names = [Collections.Generic.List[string]]::new()
    foreach ($k in $base.ue4ss.files.PSObject.Properties.Name) {
        if ($k -cmatch '\Aue4ss/Mods/([^/]+)/' -and -not $names.Contains($Matches[1])) { $names.Add($Matches[1]) }
    }
    return , $names.ToArray()
}

# mod.json rules (AGENTS.md "Conventions"; release.ps1 and the CI repo's check.ps1 both use them).
$SemverRx = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?\z'
$NameRx = '^[A-Za-z0-9][A-Za-z0-9_-]*\z'
$PinnedUe4ss = 'v3.0.1-1181-g83330635'

# Test-ModJson -Mod <parsed mod.json> -Builtins <UE4SS built-in mod names> [-TagVersion <version>]
#   -> @{ Errors = string[]; DependsOn = object[] }
# Every rule release.ps1 applies to a mod.json (release-process.md, mod-ids.md): id through the normalizer, name,
# version semver (and = -TagVersion when given), scope, game {version, build}, ue4ss = the pinned build, optional
# displayName, dependsOn an array of {id, version} where no id names a UE4SS built-in mod (matched by folder name in
# any case, before the normalizer, so the message is specific) and every id normalizes. Errors come in the order
# release.ps1 refuses them (it refuses on the first); a field that already failed isn't checked again. DependsOn holds
# each entry with its id normalized (other fields kept), for the entries that passed.
function Test-ModJson {
    param([AllowNull()] [object] $Mod, [AllowNull()] [AllowEmptyCollection()] [string[]] $Builtins = @(), [string] $TagVersion)
    $errors = [Collections.Generic.List[string]]::new()
    $deps = [Collections.Generic.List[object]]::new()
    $isObj = { param($o) $o -is [Management.Automation.PSCustomObject] }
    $has = { param($o, [string] $n) (& $isObj $o) -and $o.PSObject.Properties.Name -ccontains $n }
    if (-not (& $isObj $Mod)) {
        $errors.Add('mod.json is not a JSON object')
        return @{ Errors = $errors.ToArray(); DependsOn = $deps.ToArray() }
    }
    $bad = @{}
    foreach ($f in 'id', 'name', 'version', 'ue4ss') {
        if (-not (& $has $Mod $f) -or $Mod.$f -isnot [string] -or -not $Mod.$f) {
            $errors.Add("mod.json field ${f}: missing or not a non-empty string"); $bad[$f] = $true
        }
    }
    if (-not $bad['id']) {
        $nid = ConvertTo-ModId $Mod.id
        if ($nid.Error) { $errors.Add("mod.json field id: '$($Mod.id)': $($nid.Error)") }
    }
    if (-not $bad['name'] -and $Mod.name -cnotmatch $NameRx) { $errors.Add("mod.json field name: '$($Mod.name)' is not [A-Za-z0-9][A-Za-z0-9_-]*") }
    if (-not $bad['version']) {
        if ($Mod.version -cnotmatch $SemverRx) { $errors.Add("mod.json field version: '$($Mod.version)' is not semver") }
        elseif ($TagVersion -and $Mod.version -cne $TagVersion) {
            $errors.Add("mod.json version $($Mod.version) does not match tag v$TagVersion (version $TagVersion)")
        }
    }
    $sc = Test-ModScope $Mod.scope
    if ($sc) { $errors.Add("mod.json field $sc") }
    $g = $Mod.game
    if (-not (& $has $Mod 'game') -or -not (& $isObj $g) -or -not (& $has $g 'version') -or -not (& $has $g 'build') -or
        $g.version -isnot [string] -or $g.build -isnot [string] -or -not $g.version -or -not $g.build) {
        $errors.Add('mod.json field game: missing or not {version, build} non-empty strings')
    }
    if (-not $bad['ue4ss'] -and $Mod.ue4ss -cne $PinnedUe4ss) { $errors.Add("mod.json field ue4ss: '$($Mod.ue4ss)' is not the pinned $PinnedUe4ss") }
    if (& $has $Mod 'displayName') {
        $dn = Test-ModDisplayName $Mod.displayName
        if ($dn) { $errors.Add("mod.json field displayName: $dn") }
    }
    if (-not (& $has $Mod 'dependsOn') -or $Mod.dependsOn -isnot [array]) {
        $errors.Add('mod.json field dependsOn: missing or not an array')
    } else {
        $k = 0
        foreach ($d in $Mod.dependsOn) {
            $at = "mod.json field dependsOn[$k]"
            $k++
            if (-not (& $isObj $d) -or -not (& $has $d 'id') -or $d.id -isnot [string] -or
                -not (& $has $d 'version') -or $d.version -isnot [string]) { $errors.Add("${at}: not an object with string id and version"); continue }
            $hit = $Builtins | Where-Object { $_ -eq $d.id } | Select-Object -First 1
            if ($hit) { $errors.Add("${at}: '$($d.id)' is the UE4SS built-in mod $hit; UE4SS always ships it, so a released mod doesn't list it"); continue }
            $dn2 = ConvertTo-ModId $d.id
            if ($dn2.Error) { $errors.Add("${at}.id: '$($d.id)': $($dn2.Error)"); continue }
            $copy = [ordered]@{}
            foreach ($pr in $d.PSObject.Properties) { $copy[$pr.Name] = if ($pr.Name -ceq 'id') { $dn2.Id } else { $pr.Value } }
            $deps.Add([pscustomobject]$copy)
        }
    }
    return @{ Errors = $errors.ToArray(); DependsOn = $deps.ToArray() }
}
