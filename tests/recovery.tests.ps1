$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\common.ps1')
. (Join-Path $root 'scripts\recovery.ps1')
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('gearbox-recovery-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  git -C $tmp init -q; Set-Content (Join-Path $tmp 'x.txt') 'one'; git -C $tmp add x.txt; git -C $tmp -c user.name=test -c user.email=test@example.invalid commit -qm init
  $fp=Get-WorkspaceFingerprint $tmp
  $s=New-RecoveryState @{run_id='test';profile='balance';workdir=$tmp;sandbox='workspace-write';task='t';initial_tier='luna-medium';current_tier='luna-medium';max_steps=4;fingerprint=$fp}; $d=Join-Path ([IO.Path]::GetTempPath()) ('gearbox-state-'+[guid]::NewGuid()); New-Item $d -ItemType Directory|Out-Null; Save-RecoveryState $d $s; Add-RecoveryEvent $d 'run_started'
  if (-not (Get-ResumeAssessment $s $d).resumable) { throw 'fresh state should be resumable' }
  $inspection = Show-RecoveryInspection -RunDir $d -Json | Select-Object -Last 1
  if (-not $inspection.resumable) { throw 'inspection did not report resumable state' }
  $s.terminal_status='complete'; Save-RecoveryState $d $s; if ((Get-ResumeAssessment $s $d).resumable) { throw 'complete state must refuse' }
  $s.terminal_status='interrupted'; $s.checkpoint='worker_started'; Save-RecoveryState $d $s; if ((Get-ResumeAssessment $s $d).resumable) { throw 'unknown worker outcome must refuse' }
  $s.checkpoint='after_worker_result'; Save-RecoveryState $d $s; if ((Get-ResumeAssessment $s $d).resumable) { throw 'persisted worker decision must refuse until replayable' }
  $s.checkpoint='after_worker_result'; Save-RecoveryState $d $s; Set-Content (Join-Path $tmp 'x.txt') 'changed'; if ((Get-ResumeAssessment $s $d).resumable) { throw 'changed workspace must refuse' }
  $same=[pscustomobject]@{kind=$fp.kind;root=$fp.root;head=$fp.head;branch='other';status_hash=$fp.status_hash;status_count=$fp.status_count}; if ((Compare-WorkspaceFingerprint $same $tmp).safe) { throw 'changed branch must refuse' }
  $bad=Join-Path $tmp 'bad'; New-Item $bad -ItemType Directory|Out-Null; Set-Content (Join-Path $bad 'run-state.json') '{'; try { Read-RecoveryState $bad; throw 'corrupt state accepted' } catch { if ($_.Exception.Message -notmatch 'Invalid') { throw } }
  Write-Output 'recovery.tests: PASS'
} finally { Remove-Item $tmp -Recurse -Force; if(Test-Path $d){Remove-Item $d -Recurse -Force} }
