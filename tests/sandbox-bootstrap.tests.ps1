$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\common.ps1')

$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('gearbox-sandbox-fixtures-'+[guid]::NewGuid().ToString('N'))
$oldLocalAppData=$env:LOCALAPPDATA
$oldUserProfile=$env:USERPROFILE
$oldCodexPath=$env:CODEX_CLI_PATH
$oldPath=$env:PATH

function New-DummyFile {
  param([Parameter(Mandatory=$true)][string]$Path)
  New-Item -ItemType File -Path $Path -Force | Out-Null
}

function New-CompleteFixture {
  param([Parameter(Mandatory=$true)][string]$Path)
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  foreach($name in @('codex.exe','codex-windows-sandbox-setup.exe','codex-command-runner.exe','codex-code-mode-host.exe')) {
    New-DummyFile (Join-Path $Path $name)
  }
}

try {
  $appRoot=Join-Path $fixtureRoot 'AppData\OpenAI\Codex\bin'
  $complete=Join-Path $appRoot 'complete-2026'
  $incomplete=Join-Path $fixtureRoot 'sandbox-bin'
  $external=Join-Path $fixtureRoot 'external-helper'
  $windowsApps=Join-Path $fixtureRoot 'WindowsApps'
  $userProfile=Join-Path $fixtureRoot 'User'

  New-CompleteFixture $complete
  New-Item -ItemType Directory -Path $incomplete,$external,$windowsApps,$userProfile -Force | Out-Null
  New-DummyFile (Join-Path $incomplete 'codex.exe')
  New-DummyFile (Join-Path $incomplete 'codex-command-runner-0.146.0-alpha.9.2.exe')
  New-DummyFile (Join-Path $external 'codex-windows-sandbox-setup.exe')
  New-DummyFile (Join-Path $windowsApps 'codex.exe')

  $completeInfo=Test-CodexSandboxDistribution (Join-Path $complete 'codex.exe')
  if(-not $completeInfo.sandbox_ready){throw 'Complete synthetic distribution was not accepted.'}
  if($completeInfo.missing_companions.Count -ne 0){throw 'Complete synthetic distribution reported missing companions.'}

  $incompleteInfo=Test-CodexSandboxDistribution (Join-Path $incomplete 'codex.exe')
  if($incompleteInfo.sandbox_ready){throw 'Versioned runner-only layout was accepted.'}
  foreach($name in @('codex-windows-sandbox-setup.exe','codex-command-runner.exe','codex-code-mode-host.exe')) {
    if($incompleteInfo.missing_companions -notcontains $name){throw "Missing companion was not reported: $name"}
  }
  if($incompleteInfo.command_runner){throw 'Versioned runner was incorrectly used as unversioned command runner.'}

  $missingSetup=Join-Path $fixtureRoot 'missing-setup'
  New-CompleteFixture $missingSetup
  Remove-Item -LiteralPath (Join-Path $missingSetup 'codex-windows-sandbox-setup.exe') -Force
  if((Test-CodexSandboxDistribution (Join-Path $missingSetup 'codex.exe')).missing_companions -notcontains 'codex-windows-sandbox-setup.exe'){throw 'Missing setup helper was not detected.'}

  $missingRunner=Join-Path $fixtureRoot 'missing-runner'
  New-CompleteFixture $missingRunner
  Remove-Item -LiteralPath (Join-Path $missingRunner 'codex-command-runner.exe') -Force
  New-DummyFile (Join-Path $missingRunner 'codex-command-runner-0.146.0-alpha.9.2.exe')
  if((Test-CodexSandboxDistribution (Join-Path $missingRunner 'codex.exe')).missing_companions -notcontains 'codex-command-runner.exe'){throw 'Missing unversioned command runner was not detected.'}

  $missingHost=Join-Path $fixtureRoot 'missing-host'
  New-CompleteFixture $missingHost
  Remove-Item -LiteralPath (Join-Path $missingHost 'codex-code-mode-host.exe') -Force
  if((Test-CodexSandboxDistribution (Join-Path $missingHost 'codex.exe')).missing_companions -notcontains 'codex-code-mode-host.exe'){throw 'Missing code-mode-host was not detected.'}

  $env:LOCALAPPDATA=Join-Path $fixtureRoot 'AppData'
  $env:USERPROFILE=$userProfile
  $env:PATH=(Join-Path $windowsApps '')+';'+$oldPath
  Remove-Item Env:CODEX_CLI_PATH -ErrorAction SilentlyContinue
  $implicit=Get-CodexCommand
  if($implicit -ne (Resolve-Path (Join-Path $complete 'codex.exe')).Path){throw 'Implicit discovery did not choose the complete user-owned candidate.'}

  $env:CODEX_CLI_PATH=(Join-Path $incomplete 'codex.exe')
  $explicit=[Environment]::ExpandEnvironmentVariables([string]$env:CODEX_CLI_PATH)
  if(-not (Test-Path -LiteralPath $explicit -PathType Leaf)){throw 'Synthetic explicit incomplete CLI fixture is missing.'}
  $explicitInfo=Test-CodexSandboxDistribution $explicit
  if($explicitInfo.sandbox_ready){throw 'Explicit valid incomplete CLI was reported sandbox-ready.'}
  if($explicitInfo.missing_companions.Count -ne 3){throw 'Explicit incomplete CLI did not report all missing companions.'}

  $invalid=Join-Path $fixtureRoot 'missing-codex.exe'
  $env:CODEX_CLI_PATH=$invalid
  try { Get-CodexCommand -ErrorAction Stop; throw 'Invalid explicit CODEX_CLI_PATH was silently accepted.' }
  catch { if($_.Exception.Message -notmatch 'CODEX_CLI_PATH|resolve|file'){throw} }

  Write-Output ('complete.sandbox_ready=' + $completeInfo.sandbox_ready)
  Write-Output ('incomplete.sandbox_ready=' + $incompleteInfo.sandbox_ready)
  Write-Output ('implicit.selected=' + $implicit)
  Write-Output 'sandbox-bootstrap.tests: PASS'
}
finally {
  if($null -eq $oldLocalAppData){Remove-Item Env:LOCALAPPDATA -ErrorAction SilentlyContinue}else{$env:LOCALAPPDATA=$oldLocalAppData}
  if($null -eq $oldUserProfile){Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue}else{$env:USERPROFILE=$oldUserProfile}
  if($null -eq $oldCodexPath){Remove-Item Env:CODEX_CLI_PATH -ErrorAction SilentlyContinue}else{$env:CODEX_CLI_PATH=$oldCodexPath}
  $env:PATH=$oldPath
  if(Test-Path -LiteralPath $fixtureRoot){Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
