$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent; . (Join-Path $root 'scripts\common.ps1')
$app='C:\Users\Gaffa\AppData\Local\OpenAI\Codex\bin\d7e8094cfb76a267\codex.exe'
$sandbox='C:\Users\Gaffa\.codex\.sandbox-bin\codex.exe'
if (-not (Test-Path $app) -or -not (Test-Path $sandbox)) { throw 'Expected local Codex fixtures are missing.' }
$a=Resolve-CodexSandboxHelper $app; if(-not $a.helper_exists -or -not $a.helper_is_adjacent){throw 'Complete AppData layout not detected.'}
$b=Resolve-CodexSandboxHelper $sandbox; if(-not $b.helper_exists -or $b.helper_is_adjacent){throw 'Standalone sandbox layout was not detected.'}
$old=$env:CODEX_CLI_PATH; $env:CODEX_CLI_PATH='C:\missing\codex.exe'; try { try { Get-CodexCommand; throw 'broken explicit CODEX_CLI_PATH was silently accepted' } catch { if($_.Exception.Message -notmatch 'PATH|resolve|found'){throw} } } finally { $env:CODEX_CLI_PATH=$old }
if($a.helper_path -ne (Join-Path (Split-Path $app -Parent) 'codex-windows-sandbox-setup.exe')){throw 'Adjacent helper was not preferred.'}
if($b.helper_path -eq (Join-Path (Split-Path $sandbox -Parent) 'codex-windows-sandbox-setup.exe')){throw 'Standalone layout incorrectly reported an adjacent helper.'}
Write-Output 'sandbox-bootstrap.tests: PASS'
