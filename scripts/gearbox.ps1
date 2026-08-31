[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)][string]$Task,
    [ValidateSet('eco','balance','sport','custom')][string]$Profile = 'balance',
    [string]$Workdir = (Get-Location).Path,
    [string]$MinTier,
    [string]$StartTier,
    [string]$MaxTier,
    [int]$MaxSteps = 0,
    [string]$VerifyCommand,
    [string]$Sandbox,
    [switch]$NoFinalReview,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot 'common.ps1')
$config = Get-GearboxConfig
if (-not (Test-Path $Workdir)) { throw "Workdir not found: $Workdir" }
$Workdir = (Resolve-Path $Workdir).Path

$profileConfig = $config.profiles.$Profile
if ($null -eq $profileConfig) { throw "Profile not found in config: $Profile" }

if (-not $MinTier) { $MinTier = [string]$profileConfig.min_tier }
if (-not $StartTier) { $StartTier = [string]$profileConfig.start_tier }
if (-not $MaxTier) { $MaxTier = [string]$profileConfig.max_tier }
if ($MaxSteps -le 0) { $MaxSteps = [int]$profileConfig.max_steps }
if (-not $Sandbox) { $Sandbox = [string]$config.sandbox }

$minIndex = Get-TierIndex -Config $config -TierId $MinTier
$maxIndex = Get-TierIndex -Config $config -TierId $MaxTier
if ($minIndex -gt $maxIndex) { throw "MinTier '$MinTier' is above MaxTier '$MaxTier'." }
$StartTier = Clamp-Tier -Config $config -TierId $StartTier -MinTier $MinTier -MaxTier $MaxTier
$currentTier = $StartTier
$maxEscalations = [int]$profileConfig.max_escalations

$plan = [pscustomobject]@{
    profile = $Profile
    workdir = $Workdir
    min_tier = $MinTier
    start_tier = $StartTier
    max_tier = $MaxTier
    max_steps = $MaxSteps
    max_escalations = $maxEscalations
    final_review = [string]$profileConfig.final_review
    review_tier = [string]$profileConfig.review_tier
    sandbox = $Sandbox
    verify_command = $VerifyCommand
}

if ($DryRun) {
    Write-Host 'Codex Gearbox DRY RUN' -ForegroundColor Cyan
    $plan | ConvertTo-Json -Depth 10
    exit 0
}

$codexInfo = Get-CodexVersionInfo
if ($null -eq $codexInfo.version) { throw "Could not parse Codex version from: $($codexInfo.raw)" }
$minimumVersion = [version][string]$config.minimum_codex_version
if ($codexInfo.version -lt $minimumVersion) {
    throw "Codex $($codexInfo.version) is too old for this Gearbox configuration. Minimum: $minimumVersion"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runId = "$stamp-$([guid]::NewGuid().ToString('N').Substring(0,6))"
$runDir = Join-Path $Workdir ('.gearbox\runs\' + $runId)
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$runMeta = [pscustomobject]@{
    run_id = $runId
    created_at = (Get-Date).ToString('o')
    task = $Task
    plan = $plan
    codex = $codexInfo.raw
}
Write-GearboxJson -Value $runMeta -Path (Join-Path $runDir 'run.json')

$workerScript = Join-Path $PSScriptRoot 'worker.ps1'
$verifyScript = Join-Path $PSScriptRoot 'verify.ps1'
$history = New-Object System.Collections.ArrayList
$failureCounts = @{}
$escalations = 0
$handoffPath = $null
$reviewDone = $false
$reviewMode = $false
$finalStatus = 'blocked'
$finalSummary = 'Gearbox stopped without a completion result.'
$lastResult = $null

Write-Host "Gearbox [$Profile] $StartTier -> $MaxTier" -ForegroundColor Cyan

for ($step = 1; $step -le $MaxSteps; $step++) {
    $stepDir = Join-Path $runDir ('step-{0:d2}' -f $step)
    New-Item -ItemType Directory -Path $stepDir -Force | Out-Null
    Write-Host ("[{0}/{1}] {2}{3}" -f $step,$MaxSteps,$currentTier,($(if($reviewMode){' [review]'}else{''}))) -ForegroundColor Yellow

    $workerText = & $workerScript -Task $Task -Workdir $Workdir -TierId $currentTier -MinTier $MinTier -MaxTier $MaxTier -StepDir $stepDir -ContextPath $handoffPath -Sandbox $Sandbox -ReviewMode:$reviewMode
    $wrapper = $null
    try { $wrapper = $workerText | Select-Object -Last 1 | ConvertFrom-Json }
    catch { $wrapper = $null }

    if ($null -eq $wrapper) {
        $result = $null
        $exitCode = 1
    }
    else {
        $result = $wrapper.result
        $exitCode = [int]$wrapper.codex_exit_code
    }

    $runVerifyCommand = $null
    if ($null -ne $result -and $result.status -eq 'complete') { $runVerifyCommand = $VerifyCommand }
    $verifyText = & $verifyScript -Workdir $Workdir -VerifyCommand $runVerifyCommand -OutputDir $stepDir
    $verification = $verifyText | ConvertFrom-Json

    $record = [pscustomobject]@{
        step = $step
        tier = $currentTier
        review = $reviewMode
        codex_exit_code = $exitCode
        result = $result
        objective_verification = $verification
    }
    [void]$history.Add($record)
    Write-GearboxJson -Value $record -Path (Join-Path $stepDir 'step.json')

    if ($null -eq $result -or $exitCode -ne 0) {
        $next = Get-NextHigherTier -Config $config -CurrentTier $currentTier -MaxTier $MaxTier
        if ($null -ne $next -and $escalations -lt $maxEscalations) {
            $escalations++
            $handoff = [pscustomobject]@{
                original_task = $Task
                reason = 'Worker process failed or produced invalid structured output.'
                from_tier = $currentTier
                codex_exit_code = $exitCode
                stderr_tail = if ($wrapper) { $wrapper.stderr_tail } else { '' }
                objective_verification = $verification
            }
            $handoffPath = Join-Path $runDir 'handoff.json'
            Write-GearboxJson -Value $handoff -Path $handoffPath
            $currentTier = $next
            $reviewMode = $false
            continue
        }
        $finalStatus = 'blocked'
        $finalSummary = 'A worker failed and the configured escalation ceiling/budget was exhausted.'
        break
    }

    $lastResult = $result

    if ($result.failure_signature) {
        $signature = [string]$result.failure_signature
        if (-not $failureCounts.ContainsKey($signature)) { $failureCounts[$signature] = 0 }
        $failureCounts[$signature]++
        if ($failureCounts[$signature] -ge 2 -and $result.status -ne 'complete') {
            $forced = Get-NextHigherTier -Config $config -CurrentTier $currentTier -MaxTier $MaxTier
            if ($null -ne $forced -and $escalations -lt $maxEscalations) {
                $result.status = 'escalate'
                $result.recommended_next_tier = $forced
            }
        }
    }

    if ($result.status -eq 'blocked') {
        $finalStatus = 'blocked'
        $finalSummary = [string]$result.summary
        break
    }

    if ($result.status -eq 'escalate') {
        if ($escalations -ge $maxEscalations) {
            $finalStatus = 'blocked'
            $finalSummary = "Escalation requested but profile budget ($maxEscalations) is exhausted. $($result.unresolved)"
            break
        }

        $candidate = $null
        if ($result.recommended_next_tier) {
            try { $candidate = Clamp-Tier -Config $config -TierId ([string]$result.recommended_next_tier) -MinTier $MinTier -MaxTier $MaxTier } catch { $candidate = $null }
        }
        $currentIndex = Get-TierIndex -Config $config -TierId $currentTier
        if ($candidate) {
            $candidateIndex = Get-TierIndex -Config $config -TierId $candidate
            if ($candidateIndex -le $currentIndex) { $candidate = $null }
        }
        if (-not $candidate) { $candidate = Get-NextHigherTier -Config $config -CurrentTier $currentTier -MaxTier $MaxTier }
        if (-not $candidate) {
            $finalStatus = 'blocked'
            $finalSummary = "Worker requested escalation at the configured ceiling. $($result.unresolved)"
            break
        }

        $escalations++
        $handoff = [pscustomobject]@{
            original_task = $Task
            reason = 'Worker requested stronger reasoning.'
            from_tier = $currentTier
            result = $result
            objective_verification = $verification
        }
        $handoffPath = Join-Path $runDir 'handoff.json'
        Write-GearboxJson -Value $handoff -Path $handoffPath
        $currentTier = $candidate
        $reviewMode = $false
        continue
    }

    if ($result.status -eq 'continue') {
        $candidate = $currentTier
        if ($result.recommended_next_tier) {
            try { $candidate = Clamp-Tier -Config $config -TierId ([string]$result.recommended_next_tier) -MinTier $MinTier -MaxTier $MaxTier } catch { $candidate = $currentTier }
        }
        $candidateIndex = Get-TierIndex -Config $config -TierId $candidate
        $currentIndex = Get-TierIndex -Config $config -TierId $currentTier
        if ($candidateIndex -gt $currentIndex) {
            if ($escalations -ge $maxEscalations) { $candidate = $currentTier }
            else { $escalations++ }
        }

        $handoff = [pscustomobject]@{
            original_task = $Task
            reason = 'Worker completed a phase and requested continuation.'
            from_tier = $currentTier
            result = $result
            objective_verification = $verification
        }
        $handoffPath = Join-Path $runDir 'handoff.json'
        Write-GearboxJson -Value $handoff -Path $handoffPath
        $currentTier = $candidate
        $reviewMode = $false
        continue
    }

    if ($result.status -eq 'complete') {
        if ($VerifyCommand -and $null -ne $verification.verify_exit_code -and [int]$verification.verify_exit_code -ne 0) {
            $next = Get-NextHigherTier -Config $config -CurrentTier $currentTier -MaxTier $MaxTier
            if ($null -ne $next -and $escalations -lt $maxEscalations) {
                $escalations++
                $handoff = [pscustomobject]@{
                    original_task = $Task
                    reason = 'External verification command failed after worker reported completion.'
                    from_tier = $currentTier
                    result = $result
                    objective_verification = $verification
                }
                $handoffPath = Join-Path $runDir 'handoff.json'
                Write-GearboxJson -Value $handoff -Path $handoffPath
                $currentTier = $next
                $reviewMode = $false
                continue
            }
            $finalStatus = 'blocked'
            $finalSummary = 'Worker reported completion, but the explicit verification command failed and no escalation remained.'
            break
        }

        $needsReview = $false
        if (-not $NoFinalReview -and -not $reviewDone) {
            switch ([string]$profileConfig.final_review) {
                'always' { $needsReview = $true }
                'risk' { $needsReview = ([bool]$result.should_review -or [string]$result.risk -eq 'high') }
                default { $needsReview = $false }
            }
        }

        if ($needsReview) {
            $reviewTier = Clamp-Tier -Config $config -TierId ([string]$profileConfig.review_tier) -MinTier $MinTier -MaxTier $MaxTier
            $reviewIndex = Get-TierIndex -Config $config -TierId $reviewTier
            $currentIndex = Get-TierIndex -Config $config -TierId $currentTier
            if ($reviewIndex -lt $currentIndex) { $reviewTier = $currentTier }
            $handoff = [pscustomobject]@{
                original_task = $Task
                reason = 'Profile requires final review.'
                from_tier = $currentTier
                result = $result
                objective_verification = $verification
            }
            $handoffPath = Join-Path $runDir 'handoff.json'
            Write-GearboxJson -Value $handoff -Path $handoffPath
            $currentTier = $reviewTier
            $reviewMode = $true
            $reviewDone = $true
            continue
        }

        $finalStatus = 'complete'
        $finalSummary = [string]$result.summary
        break
    }
}

$summary = [pscustomobject]@{
    run_id = $runId
    status = $finalStatus
    summary = $finalSummary
    profile = $Profile
    start_tier = $StartTier
    final_tier = $currentTier
    min_tier = $MinTier
    max_tier = $MaxTier
    escalations = $escalations
    steps_used = $history.Count
    run_dir = $runDir
    last_result = $lastResult
    history = $history
}
Write-GearboxJson -Value $summary -Path (Join-Path $runDir 'summary.json')

if ($finalStatus -eq 'complete') {
    Write-Host "Gearbox COMPLETE: $finalSummary" -ForegroundColor Green
    Write-Host "Run log: $runDir"
    $summary | ConvertTo-Json -Depth 12
    exit 0
}
else {
    Write-Host "Gearbox STOPPED: $finalSummary" -ForegroundColor Red
    Write-Host "Run log: $runDir"
    $summary | ConvertTo-Json -Depth 12
    exit 2
}
