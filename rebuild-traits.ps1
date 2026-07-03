<#
.SYNOPSIS
  Regenerate Species Class Abolition's same-filename trait files from
  (current base-game vanilla) + (sca-deltas.txt).

.DESCRIPTION
  Trait overrides must be same-filename full-file replacements (a keyed override
  in a separate file duplicates the trait in the species designer). That means the
  mod's trait files are "whole vanilla file + a few SCA-edited traits", and they go
  stale every time Stellaris patches its trait files.

  This script eliminates the chore: it takes each trait block in sca-deltas.txt,
  finds the vanilla file that trait lives in, and rewrites that file into the mod
  as (current vanilla, with the SCA block swapped in). Run it after every Stellaris
  update, then commit/publish.

  sca-deltas.txt is the ONLY hand-maintained trait content. To change a trait,
  edit it there and re-run this. Never edit the generated mod files directly.

  Keep this script + sca-deltas.txt OUTSIDE the Steam workshop folder (Steam strips
  loose files from it on validation).

.EXAMPLE
  pwsh ./rebuild-traits.ps1
  pwsh ./rebuild-traits.ps1 -WhatIf     # show what would change without writing
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DeltasFile  = "$PSScriptRoot\sca-deltas.txt",
    [string]$VanillaPath = "C:\Program Files (x86)\Steam\steamapps\common\Stellaris",
    [string]$ModPath     = "C:\Program Files (x86)\Steam\steamapps\workshop\content\281990\3606682419"
)

$ErrorActionPreference = 'Stop'
$vanTraitDir = Join-Path $VanillaPath 'common\traits'
$modTraitDir = Join-Path $ModPath     'common\traits'
foreach ($p in @($DeltasFile,$vanTraitDir,$modTraitDir)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Error "Not found: $p"; exit 2 }
}

# Parse a file into ordered trait blocks: name -> string[] (raw lines). Brace-tracked,
# so comments/blank lines between top-level blocks are ignored.
function Get-TraitBlocks {
    param([string]$File)
    $blocks = [ordered]@{}
    $depth = 0; $name = $null; $buf = $null
    foreach ($raw in (Get-Content -LiteralPath $File)) {
        $code = $raw -replace '#.*$', ''
        if ($depth -eq 0 -and $code -match '^\s*(trait_[A-Za-z0-9_]+)\s*=\s*\{') {
            $name = $Matches[1]; $buf = [System.Collections.Generic.List[string]]::new()
        }
        if ($null -ne $name) { $buf.Add($raw) }
        $depth += ([regex]::Matches($code, '\{')).Count
        $depth -= ([regex]::Matches($code, '\}')).Count
        if ($null -ne $name -and $depth -le 0) { $blocks[$name] = $buf.ToArray(); $name = $null; $depth = 0 }
    }
    return $blocks
}

# Rewrite one vanilla file, swapping in delta blocks for matching keys.
function Build-File {
    param([string]$VanFile, [hashtable]$Deltas)   # $Deltas: key -> string[]
    $out = [System.Collections.Generic.List[string]]::new()
    $depth = 0; $skip = $false
    foreach ($raw in (Get-Content -LiteralPath $VanFile)) {
        $code = $raw -replace '#.*$', ''
        if (-not $skip -and $depth -eq 0 -and $code -match '^\s*(trait_[A-Za-z0-9_]+)\s*=\s*\{') {
            $k = $Matches[1]
            if ($Deltas.ContainsKey($k)) {
                foreach ($l in $Deltas[$k]) { $out.Add($l) }
                $skip = $true
                $depth = ([regex]::Matches($code, '\{')).Count - ([regex]::Matches($code, '\}')).Count
                continue
            }
        }
        if ($skip) {
            $depth += ([regex]::Matches($code, '\{')).Count
            $depth -= ([regex]::Matches($code, '\}')).Count
            if ($depth -le 0) { $skip = $false }
            continue
        }
        $out.Add($raw)
        $depth += ([regex]::Matches($code, '\{')).Count
        $depth -= ([regex]::Matches($code, '\}')).Count
    }
    return $out
}

Write-Host "SCA trait rebuild" -ForegroundColor Cyan
Write-Host ("deltas : {0}" -f $DeltasFile)
Write-Host ("vanilla: {0}" -f $vanTraitDir)
Write-Host ("mod    : {0}`n" -f $modTraitDir)

# 1. load deltas
$deltaBlocks = Get-TraitBlocks $DeltasFile
if ($deltaBlocks.Count -eq 0) { Write-Error "No trait blocks found in $DeltasFile"; exit 2 }

# 2. index every vanilla trait -> its file
$vanIndex = @{}
foreach ($vf in Get-ChildItem -LiteralPath $vanTraitDir -Filter *.txt) {
    foreach ($k in (Get-TraitBlocks $vf.FullName).Keys) { if (-not $vanIndex.ContainsKey($k)) { $vanIndex[$k] = $vf.Name } }
}

# 3. group deltas by the vanilla file they belong to
$byFile = @{}; $orphans = @()
foreach ($k in $deltaBlocks.Keys) {
    if ($vanIndex.ContainsKey($k)) {
        $fn = $vanIndex[$k]
        if (-not $byFile.ContainsKey($fn)) { $byFile[$fn] = @{} }
        $byFile[$fn][$k] = $deltaBlocks[$k]
    } else { $orphans += $k }
}
if ($orphans.Count) {
    Write-Host ("WARNING: {0} delta trait(s) not found in any vanilla file (skipped): {1}" -f $orphans.Count, ($orphans -join ', ')) -ForegroundColor Yellow
    Write-Host "  (a mod-only trait belongs in 00_sca_species_traits.txt, not sca-deltas.txt)`n" -ForegroundColor Yellow
}

# 4. rebuild each affected file
$fail = 0
foreach ($fn in ($byFile.Keys | Sort-Object)) {
    $vanFile = Join-Path $vanTraitDir $fn
    $lines   = Build-File $vanFile $byFile[$fn]
    $o = ($lines -join "`n" | Select-String '{' -AllMatches).Matches.Count
    $c = ($lines -join "`n" | Select-String '}' -AllMatches).Matches.Count
    $vanN = (Get-TraitBlocks $vanFile).Count
    $modN = ($lines | Select-String '^trait_[A-Za-z0-9_]+ = \{').Count
    $applied = $byFile[$fn].Count
    $status = if ($o -eq $c -and $modN -eq $vanN) { 'OK' } else { $fail++; 'CHECK!' }
    Write-Host ("  {0,-42} +{1} deltas  traits {2}/{3}  braces {4}/{5}  {6}" -f $fn, $applied, $modN, $vanN, $o, $c, $status) `
        -ForegroundColor $(if ($status -eq 'OK') { 'Green' } else { 'Red' })
    if ($status -eq 'OK') {
        if ($PSCmdlet.ShouldProcess((Join-Path $modTraitDir $fn), 'write')) {
            Set-Content -LiteralPath (Join-Path $modTraitDir $fn) -Value $lines -Encoding utf8
        }
    } else {
        Write-Host "     -> NOT written (validation failed; check the delta block for this file)" -ForegroundColor Red
    }
}

Write-Host ""
if ($fail) { Write-Host ("{0} file(s) failed validation and were not written." -f $fail) -ForegroundColor Red; exit 1 }
Write-Host ("Rebuilt {0} trait file(s) from {1} deltas. 00_sca_species_traits.txt (new traits) left untouched." -f $byFile.Count, $deltaBlocks.Count) -ForegroundColor Green
