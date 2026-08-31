[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$SmokeTest
)

. (Join-Path $PSScriptRoot 'common.ps1')
$root = Get-GearboxRoot
$checks = New-Object System.Collections.ArrayList

function Add-Check {
    param([string]$Name,[bool]$Ok,[string]$Detail,[string]$Level='required')
    [void]$checks.Add([pscustomobject]@{ name=$Name; ok=$Ok; level=$Level; detail=$Detail })
}

Add-Check 'windows' ($env:OS -eq 'Windows_NT') ("OS=" + [string]$env:OS) 'recommended'
Add-Check 'powershell' ($PSVersionTable.PSVersion.Major -ge 5) ("PowerShell=" + $PSVersionTable.PSVersion.ToString())
Add-Check 'git' ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) ((& git --version 2>&1 | Out-String).Trim())

$codexInfo = $null
try {
    $codexInfo = Get-CodexVersionInfo
    Add-Check 'codex' $true ($codexInfo.raw + ' @ ' + $codexInfo.path)
    $minimum = [version][string](Get-GearboxConfig).minimum_codex_version
    Add-Check 'codex-gpt56-minimum' ($null -ne $codexInfo.version -and $codexInfo.version -ge $minimum) ("minimum=$minimum; installed=$($codexInfo.version)")

    $help = (& $codexInfo.path exec --help 2>&1 | Out-String)
    foreach ($flag in @('--model','--output-schema','--output-last-message','--sandbox')) {
        Add-Check ("codex-exec-$flag") ($help -match [regex]::Escape($flag)) 'present in codex exec --help'
    }
}
catch {
    Add-Check 'codex' $false $_.Exception.Message
}

foreach ($jsonPath in @('config\gearbox.json','schemas\worker-result.schema.json','.agents\plugins\marketplace.json','plugins\codex-gearbox\.codex-plugin\plugin.json')) {
    $full = Join-Path $root $jsonPath
    try {
        Get-Content -LiteralPath $full -Raw | ConvertFrom-Json | Out-Null
        Add-Check ("json:$jsonPath") $true 'valid JSON'
    }
    catch { Add-Check ("json:$jsonPath") $false $_.Exception.Message }
}

$parseErrors = @()
Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -eq 0) { Add-Check ("powershell:" + $_.Name) $true 'syntax OK' }
    else {
        $detail = (($errors | ForEach-Object { $_.Message }) -join '; ')
        Add-Check ("powershell:" + $_.Name) $false $detail
        $parseErrors += $errors
    }
}

$runtime = Join-Path $HOME '.codex-gearbox\scripts\gearbox.ps1'
Add-Check 'installed-runtime' (Test-Path $runtime) $runtime 'recommended'
$skillA = Join-Path $HOME '.agents\skills\codex-gearbox\SKILL.md'
$skillB = Join-Path $HOME '.codex\skills\codex-gearbox\SKILL.md'
Add-Check 'skill-fallback-agents' (Test-Path $skillA) $skillA 'recommended'
Add-Check 'skill-fallback-codex' (Test-Path $skillB) $skillB 'recommended'

$pluginDetail = 'plugin command not detected'
$pluginOk = $false
if ($codexInfo) {
    try {
        $pluginHelp = (& $codexInfo.path plugin --help 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) {
            $pluginOk = $true
            $pluginDetail = 'codex plugin command available'
        }
    } catch {}
}
Add-Check 'plugin-command' $pluginOk $pluginDetail 'optional'

if ($SmokeTest -and $codexInfo) {
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('gearbox-smoke-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        $output = (& $codexInfo.path --ask-for-approval never exec --skip-git-repo-check --cd $temp --model gpt-5.6-luna -c 'model_reasoning_effort=low' --sandbox read-only --ephemeral 'Reply with exactly GEARBOX_OK' 2>&1 | Out-String)
        Add-Check 'live-luna-smoke' ($LASTEXITCODE -eq 0 -and $output -match 'GEARBOX_OK') 'Live inference completed. This consumed Codex usage.' 'optional'
    }
    catch { Add-Check 'live-luna-smoke' $false $_.Exception.Message 'optional' }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

$requiredFailures = @($checks | Where-Object { -not $_.ok -and $_.level -eq 'required' })
$report = [pscustomobject]@{
    ok = ($requiredFailures.Count -eq 0)
    checked_at = (Get-Date).ToString('o')
    root = $root
    smoke_test_used = [bool]$SmokeTest
    checks = $checks
}

if ($Json) {
    $report | ConvertTo-Json -Depth 10
}
else {
    Write-Host 'Codex Gearbox doctor' -ForegroundColor Cyan
    foreach ($check in $checks) {
        $tag = if ($check.ok) { 'OK' } else { if ($check.level -eq 'required') { 'FAIL' } else { 'WARN' } }
        Write-Host ("[{0}] {1}: {2}" -f $tag,$check.name,$check.detail)
    }
    Write-Host (if ($report.ok) { 'READY' } else { 'NOT READY' }) -ForegroundColor $(if ($report.ok) { 'Green' } else { 'Red' })
}

if ($report.ok) { exit 0 } else { exit 1 }
