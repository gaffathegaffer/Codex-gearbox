[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $HOME '.codex-gearbox')
)

. (Join-Path $PSScriptRoot 'common.ps1')
$root = Get-GearboxRoot
$config = Get-GearboxConfig
$codex = Get-CodexCommand

Write-Host "Installing Codex Gearbox from $root" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

# Preserve a user-local override if one already exists in the installed runtime.
$existingLocal = Join-Path $InstallRoot 'config\gearbox.local.json'
$localBackup = $null
if (Test-Path $existingLocal) {
    $localBackup = Get-Content -LiteralPath $existingLocal -Raw
}

foreach ($directory in @('scripts','config','schemas')) {
    $source = Join-Path $root $directory
    $target = Join-Path $InstallRoot $directory
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $root 'gearbox.ps1') -Destination (Join-Path $InstallRoot 'gearbox.ps1') -Force
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $InstallRoot 'README.md') -Force

if ($null -ne $localBackup) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $existingLocal) -Force | Out-Null
    $localBackup | Set-Content -LiteralPath $existingLocal -Encoding UTF8
}

$skillSource = Join-Path $root 'plugins\codex-gearbox\skills\codex-gearbox'
$fallbacks = @(
    (Join-Path $HOME '.agents\skills\codex-gearbox'),
    (Join-Path $HOME '.codex\skills\codex-gearbox')
)
foreach ($target in $fallbacks) {
    if (Test-Path $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $skillSource -Destination $target -Recurse -Force
    Write-Host "Installed skill fallback: $target"
}

$pluginState = 'unsupported-or-failed'
try {
    $pluginHelp = (& $codex plugin --help 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
        $marketplaceName = [string](Get-Content -LiteralPath (Join-Path $root '.agents\plugins\marketplace.json') -Raw | ConvertFrom-Json).name
        & $codex plugin marketplace add $root *> $null
        if ($LASTEXITCODE -eq 0) {
            & $codex plugin remove ("codex-gearbox@" + $marketplaceName) *> $null
            & $codex plugin add ("codex-gearbox@" + $marketplaceName) *> $null
            if ($LASTEXITCODE -eq 0) { $pluginState = 'installed' } else { $pluginState = 'marketplace-added-plugin-add-failed' }
        }
        else { $pluginState = 'marketplace-add-failed' }
    }
}
catch {
    $pluginState = 'plugin-command-error'
}

Write-Host "Runtime: $InstallRoot" -ForegroundColor Green
Write-Host "Plugin: $pluginState"
Write-Host 'A new Codex thread/restart may be needed once for plugin/skill indexing.'

[pscustomobject]@{
    runtime = $InstallRoot
    plugin = $pluginState
    skill_fallbacks = $fallbacks
    default_profile = [string]$config.default_profile
} | ConvertTo-Json -Depth 8

# Plugin support is optional because the skill fallbacks and runtime are sufficient.
# Make the script's process result reflect the required installation, not a prior optional CLI probe.
exit 0
