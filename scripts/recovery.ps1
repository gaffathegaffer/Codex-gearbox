Set-StrictMode -Version 2.0

function Get-RecoveryStatePath { param([Parameter(Mandatory=$true)][string]$RunDir) Join-Path $RunDir 'run-state.json' }
function Get-RecoveryEventsPath { param([Parameter(Mandatory=$true)][string]$RunDir) Join-Path $RunDir 'events.jsonl' }

function Write-GearboxJsonAtomic {
    param([Parameter(Mandatory=$true)]$Value,[Parameter(Mandatory=$true)][string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    try {
        $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json | Out-Null
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($tmp, $Path, $backup, $true)
        }
        else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Add-RecoveryEvent {
    param([Parameter(Mandatory=$true)][string]$RunDir,[Parameter(Mandatory=$true)][string]$Type,[hashtable]$Data=@{})
    $event = [ordered]@{ event_id = [guid]::NewGuid().ToString('N'); at = (Get-Date).ToString('o'); type = $Type }
    foreach ($key in $Data.Keys) { $event[$key] = $Data[$key] }
    try {
        Add-Content -LiteralPath (Get-RecoveryEventsPath $RunDir) -Value (($event | ConvertTo-Json -Compress -Depth 15)) -Encoding UTF8
        return $true
    }
    catch {
        Write-Warning "Could not append recovery event '$Type': $($_.Exception.Message)"
        return $false
    }
}

function Get-WorkspaceFingerprint {
    param([Parameter(Mandatory=$true)][string]$Workdir)
    $resolved = (Resolve-Path -LiteralPath $Workdir -ErrorAction Stop).Path
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $root = (& git -C $resolved rev-parse --show-toplevel 2>$null | Select-Object -Last 1).Trim()
        if ($LASTEXITCODE -eq 0 -and $root) {
            $head = (& git -C $resolved rev-parse HEAD 2>$null | Select-Object -Last 1).Trim()
            $branch = (& git -C $resolved symbolic-ref --short -q HEAD 2>$null | Select-Object -Last 1).Trim()
            $status = @(& git -C $resolved status --porcelain=v1 --untracked-files=all 2>$null)
            $statusHash = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes(($status -join "`n")))).Replace('-','').ToLowerInvariant()
            return [pscustomobject]@{ kind='git'; root=(Resolve-Path $root).Path; head=$head; branch=$branch; dirty=($status.Count -gt 0); status_hash=$statusHash; status_count=$status.Count }
        }
    }
    $items = Get-ChildItem -LiteralPath $resolved -Force -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }
    $hash = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash([Text.Encoding]::UTF8.GetBytes(($items -join "`n")))).Replace('-','').ToLowerInvariant()
    [pscustomobject]@{ kind='filesystem'; root=$resolved; head=$null; branch=$null; dirty=$null; status_hash=$hash; status_count=$items.Count }
}

function Compare-WorkspaceFingerprint {
    param([Parameter(Mandatory=$true)]$Expected,[Parameter(Mandatory=$true)][string]$Workdir)
    if (-not (Test-Path -LiteralPath $Workdir -PathType Container)) { return [pscustomobject]@{ safe=$false; reason='workdir_missing'; current=$null } }
    try { $actual=Get-WorkspaceFingerprint $Workdir } catch { return [pscustomobject]@{ safe=$false; reason='fingerprint_failed'; current=$null } }
    if ($Expected.kind -ne $actual.kind -or $Expected.root -ne $actual.root) { return [pscustomobject]@{ safe=$false; reason='workdir_identity_changed'; current=$actual } }
    if ($Expected.kind -eq 'git' -and $Expected.head -ne $actual.head) { return [pscustomobject]@{ safe=$false; reason='git_head_changed'; current=$actual } }
    if ($Expected.kind -eq 'git' -and $Expected.branch -ne $actual.branch) { return [pscustomobject]@{ safe=$false; reason='git_branch_changed'; current=$actual } }
    if ($Expected.kind -eq 'git' -and $Expected.status_hash -ne $actual.status_hash) { return [pscustomobject]@{ safe=$false; reason='workspace_status_changed'; current=$actual } }
    if ($Expected.kind -eq 'filesystem' -and $Expected.status_hash -ne $actual.status_hash) { return [pscustomobject]@{ safe=$false; reason='filesystem_fingerprint_changed'; current=$actual } }
    [pscustomobject]@{ safe=$true; reason='unchanged'; current=$actual }
}

function New-RecoveryState {
    param([hashtable]$Values)
    [ordered]@{ format='gearbox.run-state'; version=1; run_id=$Values.run_id; created_at=(Get-Date).ToString('o'); updated_at=(Get-Date).ToString('o'); profile=$Values.profile; workdir=$Values.workdir; sandbox=$Values.sandbox; task=$Values.task; initial_tier=$Values.initial_tier; current_tier=$Values.current_tier; current_step=0; max_steps=$Values.max_steps; escalation_count=0; worker_history=@(); verification=@(); changed_files=@(); review_state='not_started'; terminal_status='running'; checkpoint='before_first_worker'; workspace_fingerprint=$Values.fingerprint; failure_signature=$null }
}

function Save-RecoveryState { param([Parameter(Mandatory=$true)][string]$RunDir,[Parameter(Mandatory=$true)]$State)
    $State.updated_at=(Get-Date).ToString('o'); Write-GearboxJsonAtomic $State (Get-RecoveryStatePath $RunDir)
}

function Read-RecoveryState { param([Parameter(Mandatory=$true)][string]$RunDir)
    $path=Get-RecoveryStatePath $RunDir; if (-not (Test-Path -LiteralPath $path)) { throw "Missing run-state.json: $path" }
    try { $s=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { throw "Invalid run-state.json: $($_.Exception.Message)" }
    if ($s.format -ne 'gearbox.run-state' -or [int]$s.version -ne 1) { throw "Unsupported run-state format/version: $($s.format) v$($s.version)" }
    $s
}

function Get-ResumeAssessment { param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)][string]$RunDir)
    if ($State.terminal_status -ne 'running' -and $State.terminal_status -ne 'interrupted') { return [pscustomobject]@{ resumable=$false; reason='terminal_state'; checkpoint=$State.checkpoint } }
    $cmp=Compare-WorkspaceFingerprint $State.workspace_fingerprint $State.workdir
    if (-not $cmp.safe) { return [pscustomobject]@{ resumable=$false; reason=$cmp.reason; checkpoint=$State.checkpoint } }
    if ($State.checkpoint -eq 'worker_started') { return [pscustomobject]@{ resumable=$false; reason='worker_outcome_unknown'; checkpoint=$State.checkpoint } }
    if ($State.checkpoint -eq 'after_worker_result' -or $State.checkpoint -eq 'before_review') { return [pscustomobject]@{ resumable=$false; reason='persisted_worker_decision_not_replayable'; checkpoint=$State.checkpoint } }
    [pscustomobject]@{ resumable=$true; reason='safe_checkpoint'; checkpoint=$State.checkpoint }
}

function Show-RecoveryInspection {
    param([Parameter(Mandatory=$true)][string]$RunDir,[switch]$Json)
    $s=Read-RecoveryState $RunDir; $a=Get-ResumeAssessment $s $RunDir; $ev=@(); $ep=Get-RecoveryEventsPath $RunDir
    if (Test-Path $ep) {
        $lines = @(Get-Content $ep | Select-Object -Last 20)
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            try { $ev=@($line | ConvertFrom-Json); break } catch { }
        }
    }
    $o=[pscustomobject]@{ run_id=$s.run_id; status=$s.terminal_status; profile=$s.profile; latest_tier=$s.current_tier; workers=@($s.worker_history).Count; escalation_count=$s.escalation_count; latest_event=if($ev){$ev[0].type}else{$null}; workdir=$s.workdir; fingerprint_status=$a.reason; resumable=$a.resumable; resume_reason=$a.reason }
    if ($Json) { $o | ConvertTo-Json -Depth 10 } else { $o | Format-List }
    $o
}

function Test-RecoveryFailureInjection {
    param([Parameter(Mandatory=$true)][string]$Checkpoint)
    if ($env:GEARBOX_TEST_INTERRUPT -eq $Checkpoint) { throw "Injected interruption at checkpoint: $Checkpoint" }
}
