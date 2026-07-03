<#
.SYNOPSIS
  Detect where Species Class Abolition's overridden objects have drifted from the
  current base game .

.DESCRIPTION
  For every trait / civic / event the mod redefines, this finds the matching
  vanilla object in the *currently installed* game and reports:
    * DROPPED  - vanilla mechanic lines missing from the mod's copy
                 (e.g. the job_*_automated_workforce_mult lines Tankbound lost)
    * VALUE    - a scalar the mod froze at an old value
                 (e.g. planet_building_refund_mult = 1 vs vanilla 0.75)
  Lines that are clearly intentional SCA edits (species_class / allowed_archetypes /
  portrait_override / #SCA-marked) are treated as expected and not flagged.

  Run this after every Stellaris update. Non-zero exit = something to re-sync.

.EXAMPLE
  pwsh ./check-drift.ps1
  pwsh ./check-drift.ps1 -ShowIntended        # also list the expected SCA deltas
#>
[CmdletBinding()]
param(
    [string]$ModPath     = "C:\Program Files (x86)\Steam\steamapps\workshop\content\281990\3606682419",
    [string]$VanillaPath = "C:\Program Files (x86)\Steam\steamapps\common\Stellaris",
    [switch]$ShowIntended
)

# --- patterns -------------------------------------------------------------
# A vanilla line that looks like a game mechanic/value. Dropping one of these is the danger.
$MechanicRx = '(?i)\b(modifier|resources|upkeep|produces|workforce|automated)\b|job_[a-z_]+_(add|mult)|_workforce_mult|_upkeep_(add|mult)|planet_[a-z_]+_(add|mult)|country_[a-z_]+_(add|mult)|pop_[a-z_]+_(add|mult)'
# Differences that are intentional SCA edits (do not flag these).
$ScaTokenRx = '(?i)SCA_|species_class|allowed_archetypes|portrait_override|is_infernal|is_lithoid|host_has_dlc|species_potential_add|SPECIES_TRAIT_|#\s*SCA'
# Dropped vanilla lines that are explained by an SCA removal (do not flag).
$ScaRemoveRx = '(?i)species_class|portrait_override|allowed_archetypes|opposites'
# Only treat a *scalar value* change as drift if the key is an economy/mechanic value.
# (Availability flags the mod intentionally changes - cost/initial/sapient/randomized - are ignored.)
$ValueKeyRx = '(?i)_mult$|_add$|_upkeep|^planet_|^job_|^country_|^pop_|workforce'

# --- parse a Stellaris file into top-level objects ------------------------
function Get-Objects {
    param([string]$File, [switch]$IsEvent)
    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $File)) { return $result }
    $depth = 0; $name = $null; $buf = $null
    foreach ($raw in (Get-Content -LiteralPath $File)) {
        $code = $raw -replace '#.*$', ''            # ignore comments for brace counting
        if ($depth -eq 0) {
            $m = [regex]::Match($code, '^\s*([A-Za-z_][\w\.]*)\s*=\s*\{')
            if ($m.Success) { $name = $m.Groups[1].Value; $buf = [System.Collections.Generic.List[string]]::new() }
        }
        if ($null -ne $name) { $buf.Add($raw) }
        $depth += ([regex]::Matches($code, '\{')).Count
        $depth -= ([regex]::Matches($code, '\}')).Count
        if ($null -ne $name -and $depth -le 0) {
            $key = $name
            if ($IsEvent) {
                $idl = $buf | Where-Object { $_ -match '^\s*id\s*=\s*(\S+)' } | Select-Object -First 1
                if ($idl -match '^\s*id\s*=\s*(\S+)') { $key = $Matches[1] }
            }
            $result[$key] = $buf.ToArray()      # last definition wins (mirrors load order)
            $name = $null; $depth = 0
        }
    }
    return $result
}

# Merge every file in a folder (alphabetical = load order), last definition wins.
function Get-Index {
    param([string]$Folder, [switch]$IsEvent)
    $idx = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Folder)) { return $idx }
    foreach ($f in (Get-ChildItem -LiteralPath $Folder -Filter *.txt | Sort-Object Name)) {
        $objs = Get-Objects -File $f.FullName -IsEvent:$IsEvent
        foreach ($k in $objs.Keys) { $idx[$k] = @{ Lines = $objs[$k]; File = $f.Name } }
    }
    return $idx
}

# Significant lines: drop comments + blanks, normalise whitespace.
function Get-Sig { param([string[]]$Lines)
    $Lines | ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
        Where-Object { $_ -ne '' -and $_ -ne '{' -and $_ -ne '}' } |
        ForEach-Object { $_ -replace '\s+', ' ' }
}
# Map simple `key = scalar` assignments -> value (only keys that appear once).
function Get-Scalars { param([string[]]$Sig)
    $seen = @{}; $dup = @{}
    foreach ($l in $Sig) {
        $m = [regex]::Match($l, '^([\w\.@]+)\s*=\s*([^\{\}]+?)\s*$')
        if ($m.Success) {
            $k = $m.Groups[1].Value
            if ($seen.ContainsKey($k)) { $dup[$k] = $true } else { $seen[$k] = $m.Groups[2].Value }
        }
    }
    foreach ($k in $dup.Keys) { $seen.Remove($k) }
    return $seen
}

$categories = @(
    @{ Name = 'trait'; Mod = "$ModPath\common\traits";              Van = "$VanillaPath\common\traits";              Ev = $false },
    @{ Name = 'civic'; Mod = "$ModPath\common\governments\civics";  Van = "$VanillaPath\common\governments\civics";  Ev = $false },
    @{ Name = 'event'; Mod = "$ModPath\events";                     Van = "$VanillaPath\events";                     Ev = $false -bor $true }
)

$warnCount = 0; $checked = 0; $modOnly = 0
Write-Host "SCA drift check" -ForegroundColor Cyan
Write-Host ("mod    : {0}" -f $ModPath)
Write-Host ("vanilla: {0}`n" -f $VanillaPath)

foreach ($cat in $categories) {
    $modIdx = Get-Index -Folder $cat.Mod -IsEvent:([bool]$cat.Ev)
    $vanIdx = Get-Index -Folder $cat.Van -IsEvent:([bool]$cat.Ev)

    foreach ($key in $modIdx.Keys) {
        if (-not $vanIdx.Contains($key)) { $modOnly++; continue }   # mod-only object, nothing to compare
        $checked++
        $modSig = @(Get-Sig $modIdx[$key].Lines)
        $vanSig = @(Get-Sig $vanIdx[$key].Lines)
        $modSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$modSig)

        # DROPPED: vanilla mechanic lines missing from mod, not explained by an SCA removal
        $dropped = @($vanSig | Where-Object {
            -not $modSet.Contains($_) -and $_ -match $MechanicRx -and $_ -notmatch $ScaRemoveRx
        })

        # VALUE: same scalar key, different value, and not an SCA structural key
        $mv = Get-Scalars $modSig; $vv = Get-Scalars $vanSig
        $valDrift = foreach ($k in $vv.Keys) {
            if ($mv.ContainsKey($k) -and $mv[$k] -ne $vv[$k] -and $k -match $ValueKeyRx -and $k -notmatch $ScaTokenRx) {
                "{0}: mod={1}  vanilla={2}" -f $k, $mv[$k], $vv[$k]
            }
        }

        if ($dropped.Count -gt 0 -or $valDrift) {
            $warnCount++
            Write-Host ("[DRIFT] {0}  ({1})" -f $key, $modIdx[$key].File) -ForegroundColor Yellow
            foreach ($d in $dropped)  { Write-Host ("   DROPPED vanilla line : {0}" -f $d) -ForegroundColor Red }
            foreach ($v in $valDrift) { Write-Host ("   VALUE drift          : {0}" -f $v) -ForegroundColor Red }
        }
        elseif ($ShowIntended) {
            $added = @($modSig | Where-Object { -not ([System.Collections.Generic.HashSet[string]]::new([string[]]$vanSig)).Contains($_) })
            if ($added.Count) {
                Write-Host ("[ok] {0} - {1} intended SCA delta line(s)" -f $key, $added.Count) -ForegroundColor DarkGray
            }
        }
    }
}

Write-Host ""
Write-Host ("checked {0} overridden objects, {1} mod-only skipped" -f $checked, $modOnly)
if ($warnCount) { Write-Host ("{0} object(s) need re-sync with current vanilla." -f $warnCount) -ForegroundColor Yellow }
else            { Write-Host "No drift: every overridden object matches current vanilla (minus intended SCA edits)." -ForegroundColor Green }
exit $warnCount
