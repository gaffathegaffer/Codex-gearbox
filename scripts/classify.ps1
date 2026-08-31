[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Task,
    [Parameter(Mandatory=$true)][string]$Workdir,
    [Parameter(Mandatory=$true)][string]$BaseTier,
    [Parameter(Mandatory=$true)][string]$MinTier,
    [Parameter(Mandatory=$true)][string]$MaxTier
)

. (Join-Path $PSScriptRoot 'common.ps1')
$config = Get-GearboxConfig
$score = 0
$signals = New-Object System.Collections.ArrayList

$rules = @(
    @{ pattern='(?i)\b(typo|spelling|format|formatting|rename|readme|documentation|docs|lint|dependency update|install dependencies)\b'; delta=-1; label='routine/mechanical wording' },
    @{ pattern='(?i)\b(debug|diagnos|failing|failure|regression|refactor|performance|optimi[sz]|compatib|integration)\w*\b'; delta=1; label='diagnostic/refactor wording' },
    @{ pattern='(?i)\b(architecture|architectural|security|vulnerability|migration|concurrency|race condition|deadlock|cuda|kernel|memory leak|root cause|deep audit|formal verification)\b'; delta=2; label='high-complexity wording' },
    @{ pattern='(?i)\b(entire|whole|across|all modules|all packages|repository-wide|repo-wide|system-wide)\b'; delta=1; label='broad-scope wording' },
    @{ pattern='(?i)\b(deploy|production|database migration|schema migration|authentication|authorization|cryptograph|payment|billing)\w*\b'; delta=2; label='high-impact wording' }
)

foreach ($rule in $rules) {
    if ($Task -match $rule.pattern) {
        $score += [int]$rule.delta
        [void]$signals.Add([string]$rule.label)
    }
}

$broadTask = $Task -match '(?i)\b(entire|whole|across|all modules|all packages|repository-wide|repo-wide|system-wide|audit)\b'
$fileCount = $null
if ($broadTask -and (Get-Command git -ErrorAction SilentlyContinue)) {
    try {
        & git -C $Workdir rev-parse --is-inside-work-tree *> $null
        if ($LASTEXITCODE -eq 0) {
            $tracked = @(& git -C $Workdir ls-files 2>$null)
            $fileCount = $tracked.Count
            if ($fileCount -ge 5000) {
                $score += 2
                [void]$signals.Add('very large tracked repository')
            }
            elseif ($fileCount -ge 1000) {
                $score += 1
                [void]$signals.Add('large tracked repository')
            }
        }
    }
    catch {}
}

$offset = 0
if ($score -ge 5) { $offset = 3 }
elseif ($score -ge 3) { $offset = 2 }
elseif ($score -ge 1) { $offset = 1 }
elseif ($score -le -2) { $offset = -1 }

$baseIndex = Get-TierIndex -Config $config -TierId $BaseTier
$minIndex = Get-TierIndex -Config $config -TierId $MinTier
$maxIndex = Get-TierIndex -Config $config -TierId $MaxTier
$candidateIndex = $baseIndex + $offset
if ($candidateIndex -lt $minIndex) { $candidateIndex = $minIndex }
if ($candidateIndex -gt $maxIndex) { $candidateIndex = $maxIndex }
$suggested = [string]$config.tiers[$candidateIndex].id

[pscustomobject]@{
    base_tier = $BaseTier
    suggested_tier = $suggested
    score = $score
    offset = $offset
    signals = @($signals)
    tracked_file_count = $fileCount
    quota_cost = 'none'
} | ConvertTo-Json -Depth 8 -Compress
