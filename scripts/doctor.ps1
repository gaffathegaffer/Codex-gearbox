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

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory=$false)]$Object,
        [Parameter(Mandatory=$true)][string[]]$Names
    )
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Test-ModelIdentity {
    param(
        [Parameter(Mandatory=$true)]$Model,
        [Parameter(Mandatory=$true)][string]$Expected
    )
    foreach ($name in @('slug','model','id')) {
        $property = $Model.PSObject.Properties[$name]
        if ($null -ne $property -and [string]$property.Value -eq $Expected) { return $true }
    }
    return $false
}

Add-Check 'windows' ($env:OS -eq 'Windows_NT') ("OS=" + [string]$env:OS) 'recommended'
Add-Check 'powershell' ($PSVersionTable.PSVersion.Major -ge 5) ("PowerShell=" + $PSVersionTable.PSVersion.ToString())

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $gitCommand) {
    $gitVersion = (& git --version 2>&1 | Out-String).Trim()
    Add-Check 'git' $true $gitVersion
}
else {
    Add-Check 'git' $false 'Git was not found on PATH.'
}

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

    try {
        $catalogText = (& $codexInfo.path debug models 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $catalogText) {
            $catalog = $catalogText | ConvertFrom-Json
            $models = @()
            if ($catalog -is [System.Array]) {
                $models = @($catalog)
            }
            else {
                $modelsValue = Get-OptionalPropertyValue -Object $catalog -Names @('models')
                if ($null -ne $modelsValue) { $models = @($modelsValue) }
            }

            foreach ($slug in @('gpt-5.6-luna','gpt-5.6-terra','gpt-5.6-sol')) {
                $model = $models | Where-Object { Test-ModelIdentity -Model $_ -Expected $slug } | Select-Object -First 1
                Add-Check ("model-catalog:$slug") ($null -ne $model) ($(if ($model) { 'available in local Codex model catalog' } else { 'not found in local Codex model catalog' })) 'recommended'
            }

            $sol = $models | Where-Object { Test-ModelIdentity -Model $_ -Expected 'gpt-5.6-sol' } | Select-Object -First 1
            if ($sol) {
                $solText = ($sol | ConvertTo-Json -Depth 20 -Compress)
                Add-Check 'model-catalog:sol-ultra' ($solText -match 'ultra') ($(if ($solText -match 'ultra') { 'Sol Ultra advertised by local catalog.' } else { 'Sol Ultra not advertised by this local catalog; keep it opt-in and do not use until supported.' })) 'optional'
            }
        }
        else {
            Add-Check 'model-catalog' $false '`codex debug models` unavailable or returned no data.' 'optional'
        }
    }
    catch {
        Add-Check 'model-catalog' $false ('Could not inspect local model catalog: ' + $_.Exception.Message) 'optional'
    }
}
catch {
    Add-Check 'codex' $false $_.Exception.Message
}

foreach ($jsonPath in @('config\gearbox.json','schemas\worker-result.schema.json')) {
    $full = Join-Path $root $jsonPath
    try {
        Get-Content -LiteralPath $full -Raw | ConvertFrom-Json | Out-Null
        Add-Check ("json:$jsonPath") $true 'valid JSON'
    }
    catch { Add-Check ("json:$jsonPath") $false $_.Exception.Message }
}

foreach ($jsonPath in @('.agents\plugins\marketplace.json','plugins\codex-gearbox\.codex-plugin\plugin.json')) {
    $full = Join-Path $root $jsonPath
    if (Test-Path -LiteralPath $full) {
        try {
            Get-Content -LiteralPath $full -Raw | ConvertFrom-Json | Out-Null
            Add-Check ("json:$jsonPath") $true 'valid JSON at source checkout path' 'recommended'
        }
        catch { Add-Check ("json:$jsonPath") $false $_.Exception.Message 'recommended' }
    }
    else {
        Add-Check ("json:$jsonPath") $true 'not bundled in slim installed runtime; validate from the source checkout when present' 'optional'
    }
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
Add-Check 'recovery-module' (Test-Path (Join-Path $root 'scripts\recovery.ps1')) 'scripts/recovery.ps1 present' 'required'
Add-Check 'recovery-format' $true 'run-state.json v1 and events.jsonl are local/optional per run' 'recommended'
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
    $readyText = if ($report.ok) { 'READY' } else { 'NOT READY' }
    $readyColor = if ($report.ok) { 'Green' } else { 'Red' }
    Write-Host $readyText -ForegroundColor $readyColor
}

if ($report.ok) { exit 0 } else { exit 1 }
