[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Task,
    [Parameter(Mandatory=$true)][string]$Workdir,
    [Parameter(Mandatory=$true)][string]$TierId,
    [Parameter(Mandatory=$true)][string]$MinTier,
    [Parameter(Mandatory=$true)][string]$MaxTier,
    [Parameter(Mandatory=$true)][string]$StepDir,
    [string]$ContextPath,
    [string]$Sandbox,
    [switch]$ReviewMode
)

. (Join-Path $PSScriptRoot 'common.ps1')
$config = Get-GearboxConfig
$tier = Get-Tier -Config $config -TierId $TierId
$codex = Get-CodexCommand
if (-not $Sandbox) { $Sandbox = [string]$config.sandbox }

if (-not (Test-Path $Workdir)) { throw "Workdir not found: $Workdir" }
New-Item -ItemType Directory -Path $StepDir -Force | Out-Null

$schemaPath = Join-Path (Get-GearboxRoot) 'schemas\worker-result.schema.json'
$promptPath = Join-Path $StepDir 'prompt.txt'
$finalPath = Join-Path $StepDir 'final.json'
$stdoutPath = Join-Path $StepDir 'stdout.log'
$stderrPath = Join-Path $StepDir 'stderr.log'
$preflightPath = Join-Path $StepDir 'shell-preflight.json'

$contextText = ''
if ($ContextPath -and (Test-Path $ContextPath)) {
    $contextText = Get-Content -LiteralPath $ContextPath -Raw
    $limit = [int]$config.context_char_limit
    if ($contextText.Length -gt $limit) {
        $contextText = $contextText.Substring(0, $limit) + "`n[handoff truncated by Gearbox]"
    }
}

$modeText = if ($ReviewMode) {
@'
This is a FINAL REVIEW pass. Inspect the work already performed for the original goal. Do not redo correct work merely for stylistic preference. Find concrete defects, omissions, regressions, unsafe assumptions, or missing verification. Fix concrete issues you can verify. Return complete when the implementation is sound, escalate only if a stronger tier is genuinely needed, and blocked only for an external dependency you cannot resolve.
'@
} else {
@'
This is an IMPLEMENTATION pass. Perform useful work now. Do not merely advise the next agent. Complete as much of the original goal as this tier can reliably handle.
'@
}

$prompt = @"
You are a Codex Gearbox worker running at tier '$TierId' ($($tier.model), reasoning=$($tier.reasoning)).

ORIGINAL GOAL:
$Task

ALLOWED GEAR RANGE:
minimum=$MinTier
maximum=$MaxTier

$modeText

OPERATING RULES:
- Work directly in the supplied repository/workspace and verify concrete changes when practical.
- Preserve all existing and uncommitted user work. Never run git reset --hard, git clean, forced checkout, or equivalent destructive cleanup.
- Do not commit, push, publish, deploy, upload, or open a PR unless the original goal explicitly asks for it.
- Do not expose secrets or credentials.
- Do not spend time philosophizing about model choice. The Gearbox router controls that.
- Use status=complete only when the original goal is fully satisfied and reasonably verified.
- Use status=continue when useful work is complete but another routine phase remains. You may recommend the same or a LOWER tier to downshift.
- Use status=escalate only after a concrete attempt or inspection shows that materially stronger reasoning is likely to improve correctness. Explain the unresolved technical reason and recommend a higher tier within the allowed range.
- Use status=blocked only for a real external blocker such as missing credentials, required user decision, unavailable service, admin permission, or an environmental condition that cannot be repaired safely.
- Set failure_signature to a short stable phrase when a repeatable technical failure remains; otherwise null.
- Mark should_review=true for high-impact, security-sensitive, broad architectural, destructive, deployment, migration, or otherwise high-risk changes.
- Keep the final structured result concise. The router already has access to the workspace.

PREVIOUS HANDOFF (may be empty):
$contextText

Return only the JSON object required by the supplied output schema.
"@

$prompt | Set-Content -LiteralPath $promptPath -Encoding UTF8

$arguments = @(
    '--ask-for-approval','never',
    'exec',
    '--cd',$Workdir,
    '--model',[string]$tier.model,
    '-c',("model_reasoning_effort=" + [string]$tier.reasoning),
    '--sandbox',$Sandbox,
    '--ephemeral',
    '--color','never',
    '--json',
    '--output-schema',$schemaPath,
    '--output-last-message',$finalPath,
    '-'
)

# Codex native Windows sandbox currently cannot reliably spawn the Microsoft Store/MSIX
# PowerShell executable under a restricted token. The failure surfaces as
# CreateProcessAsUserW failed: 5 (Access is denied). Keep the user's global PATH untouched,
# but remove WindowsApps entries only from the environment inherited by this child Codex.
$originalPath = [string]$env:PATH
$pathEntries = @($originalPath -split ';' | Where-Object { $_ -and $_.Trim() })
$removedWindowsApps = New-Object System.Collections.ArrayList
$safePathEntries = New-Object System.Collections.ArrayList
foreach ($entry in $pathEntries) {
    $normalized = $entry.Trim().TrimEnd('\')
    if ($normalized -match '(?i)(^|\\)WindowsApps($|\\)') {
        [void]$removedWindowsApps.Add($entry)
    }
    else {
        [void]$safePathEntries.Add($entry)
    }
}
$childPath = (@($safePathEntries) -join ';')

function Resolve-ExecutableFromPath {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$PathValue
    )

    $extensions = @('')
    if ([System.IO.Path]::GetExtension($Name) -eq '') {
        $extensions = @('.exe','.cmd','.bat','')
    }

    foreach ($directory in @($PathValue -split ';')) {
        if (-not $directory) { continue }
        foreach ($extension in $extensions) {
            $candidate = Join-Path $directory ($Name + $extension)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }
    return $null
}

$preflight = [ordered]@{
    generated_at = (Get-Date).ToString('o')
    sandbox = $Sandbox
    codex = [string]$codex
    original_path_contains_windowsapps = ($removedWindowsApps.Count -gt 0)
    removed_windowsapps_entries = @($removedWindowsApps)
    child_path = $childPath
    child_pwsh = Resolve-ExecutableFromPath -Name 'pwsh' -PathValue $childPath
    child_powershell = Resolve-ExecutableFromPath -Name 'powershell' -PathValue $childPath
    workaround = 'child-path-windowsapps-filter'
}
$preflight | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $preflightPath -Encoding UTF8

$exitCode = 1
try {
    $env:PATH = $childPath
    $prompt | & $codex @arguments 1> $stdoutPath 2> $stderrPath
    $exitCode = $LASTEXITCODE
}
catch {
    $_ | Out-String | Set-Content -LiteralPath $stderrPath -Encoding UTF8
    $exitCode = 1
}
finally {
    $env:PATH = $originalPath
}

$result = $null
$parseError = $null
if (Test-Path $finalPath) {
    try {
        $result = Get-Content -LiteralPath $finalPath -Raw | ConvertFrom-Json
    }
    catch {
        $parseError = $_.Exception.Message
    }
}
else {
    $parseError = 'Codex did not produce the final output file.'
}

$stderrTail = ''
if (Test-Path $stderrPath) {
    $lines = Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue
    if ($lines) { $stderrTail = (($lines | Select-Object -Last 20) -join "`n") }
}

$wrapper = [pscustomobject]@{
    tier = $TierId
    model = [string]$tier.model
    reasoning = [string]$tier.reasoning
    codex_exit_code = $exitCode
    result = $result
    parse_error = $parseError
    stderr_tail = $stderrTail
    step_dir = $StepDir
    shell_preflight = $preflight
}

$wrapper | ConvertTo-Json -Depth 20 -Compress
