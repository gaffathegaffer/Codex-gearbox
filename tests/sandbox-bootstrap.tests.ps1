$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent; . (Join-Path $root 'scripts\common.ps1')
$app='C:\Users\Gaffa\AppData\Local\OpenAI\Codex\bin\d7e8094cfb76a267\codex.exe'
$sandbox='C:\Users\Gaffa\.codex\.sandbox-bin\codex.exe'
if (-not (Test-Path $app) -or -not (Test-Path $sandbox)) { throw 'Expected local Codex fixtures are missing.' }
$a=Test-CodexSandboxDistribution $app; if(-not $a.sandbox_ready -or $a.missing_companions.Count -ne 0){throw 'Complete AppData layout not detected.'}
$b=Test-CodexSandboxDistribution $sandbox; if($b.sandbox_ready -or $b.missing_companions.Count -lt 2){throw 'Standalone incomplete layout was not rejected.'}
$old=$env:CODEX_CLI_PATH; $env:CODEX_CLI_PATH='C:\missing\codex.exe'; try { try { Get-CodexCommand; throw 'broken explicit CODEX_CLI_PATH was silently accepted' } catch { if($_.Exception.Message -notmatch 'PATH|resolve|found'){throw} } } finally { $env:CODEX_CLI_PATH=$old }
if($a.sandbox_setup_helper -ne (Join-Path (Split-Path $app -Parent) 'codex-windows-sandbox-setup.exe')){throw 'Adjacent helper was not detected.'}
if($b.sandbox_setup_helper){throw 'Incomplete layout incorrectly reported a local setup helper.'}
$oldPath=$env:CODEX_CLI_PATH
try {
  Remove-Item Env:CODEX_CLI_PATH -ErrorAction SilentlyContinue
  $implicit=Get-CodexCommand
  if($implicit -ne (Resolve-Path $app).Path){throw 'Implicit discovery did not choose the complete AppData distribution.'}
} finally { if($null -eq $oldPath){Remove-Item Env:CODEX_CLI_PATH -ErrorAction SilentlyContinue}else{$env:CODEX_CLI_PATH=$oldPath} }
$step=Join-Path ([IO.Path]::GetTempPath()) ('gearbox-incomplete-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $step | Out-Null
try {
  $env:CODEX_CLI_PATH=$sandbox
  $raw=& (Join-Path $root 'scripts\worker.ps1') -Task 'preflight only' -Workdir $root -TierId luna-low -MinTier luna-low -MaxTier luna-low -StepDir $step -Sandbox workspace-write
  $wrapper=$raw | Select-Object -Last 1 | ConvertFrom-Json
  if($wrapper.result.status -ne 'blocked' -or $wrapper.result.failure_signature -ne 'incomplete_codex_distribution'){throw 'Incomplete explicit distribution was not refused before worker execution.'}
} finally { Remove-Item Env:CODEX_CLI_PATH -ErrorAction SilentlyContinue; Remove-Item $step -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output ('complete.sandbox_ready=' + $a.sandbox_ready)
Write-Output ('incomplete.sandbox_ready=' + $b.sandbox_ready)
Write-Output 'sandbox-bootstrap.tests: PASS'
