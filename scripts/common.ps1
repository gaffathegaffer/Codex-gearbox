Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-GearboxRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Merge-GearboxObject {
    param([Parameter(Mandatory=$true)]$Base, [Parameter(Mandatory=$true)]$Override)

    foreach ($property in $Override.PSObject.Properties) {
        $name = $property.Name
        $incoming = $property.Value
        $existingProperty = $Base.PSObject.Properties[$name]

        if ($null -ne $existingProperty -and
            $existingProperty.Value -is [pscustomobject] -and
            $incoming -is [pscustomobject]) {
            Merge-GearboxObject -Base $existingProperty.Value -Override $incoming | Out-Null
        }
        elseif ($null -ne $existingProperty) {
            $Base.$name = $incoming
        }
        else {
            $Base | Add-Member -NotePropertyName $name -NotePropertyValue $incoming
        }
    }
    return $Base
}

function Get-GearboxConfig {
    $root = Get-GearboxRoot
    $defaultPath = Join-Path $root 'config\gearbox.json'
    if (-not (Test-Path $defaultPath)) { throw "Missing Gearbox config: $defaultPath" }

    $config = Get-Content -LiteralPath $defaultPath -Raw | ConvertFrom-Json
    $localPath = Join-Path $root 'config\gearbox.local.json'
    if (Test-Path $localPath) {
        $local = Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json
        $config = Merge-GearboxObject -Base $config -Override $local
    }
    return $config
}

function Test-CodexSandboxDistribution {
    param([Parameter(Mandatory=$true)][string]$CodexPath)
    $cli = (Resolve-Path -LiteralPath $CodexPath -ErrorAction Stop).Path
    $root = Split-Path -Parent $cli
    $required = @(
        'codex-windows-sandbox-setup.exe',
        'codex-command-runner.exe',
        'codex-code-mode-host.exe'
    )
    $paths = [ordered]@{}
    $missing = New-Object System.Collections.ArrayList
    foreach ($name in $required) {
        $path = Join-Path $root $name
        $paths[$name] = if (Test-Path -LiteralPath $path -PathType Leaf) { (Resolve-Path -LiteralPath $path).Path } else { $null }
        if ($null -eq $paths[$name]) { [void]$missing.Add($name) }
    }
    [pscustomobject]@{
        codex = $cli
        version = $null
        distribution_root = $root
        sandbox_ready = ($missing.Count -eq 0)
        sandbox_setup_helper = $paths['codex-windows-sandbox-setup.exe']
        command_runner = $paths['codex-command-runner.exe']
        code_mode_host = $paths['codex-code-mode-host.exe']
        missing_companions = @($missing)
        required_companions = $required
    }
}

function Get-CodexCommand {
    if ($env:CODEX_CLI_PATH) {
        $explicit = [Environment]::ExpandEnvironmentVariables([string]$env:CODEX_CLI_PATH)
        if (Test-Path -LiteralPath $explicit -PathType Leaf) {
            return (Resolve-Path -LiteralPath $explicit).Path
        }
        throw "CODEX_CLI_PATH was explicitly set but does not resolve to a file: $explicit"
    }

    $candidates = New-Object System.Collections.ArrayList
    if ($env:LOCALAPPDATA) {
        $root = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
        if (Test-Path -LiteralPath $root -PathType Container) {
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
                $candidate = Join-Path $_.FullName 'codex.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { [void]$candidates.Add($candidate) }
            }
        }
    }
    if ($env:USERPROFILE) {
        $candidate = Join-Path $env:USERPROFILE '.codex\plugins\.plugin-appserver\codex.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { [void]$candidates.Add($candidate) }
    }
    $command = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        $path = if ($command.Source) { $command.Source } else { $command.Definition }
        if ($path -and $path -notmatch '(?i)(^|\\)WindowsApps(\\|$)') { [void]$candidates.Add($path) }
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            if ((Test-CodexSandboxDistribution $candidate).sandbox_ready) { return (Resolve-Path -LiteralPath $candidate).Path }
        } catch { }
    }
    if ($candidates.Count -gt 0) {
        throw 'Codex CLI candidates were found, but no complete Windows sandbox distribution was found. Set CODEX_CLI_PATH to a complete Codex distribution.'
    }
    throw 'Codex CLI was not found on PATH and CODEX_CLI_PATH did not resolve to a file.'
}

function Get-Tier {
    param([Parameter(Mandatory=$true)]$Config, [Parameter(Mandatory=$true)][string]$TierId)
    $tier = $Config.tiers | Where-Object { $_.id -eq $TierId } | Select-Object -First 1
    if ($null -eq $tier) { throw "Unknown Gearbox tier: $TierId" }
    return $tier
}

function Get-TierIndex {
    param([Parameter(Mandatory=$true)]$Config, [Parameter(Mandatory=$true)][string]$TierId)
    for ($i = 0; $i -lt $Config.tiers.Count; $i++) {
        if ($Config.tiers[$i].id -eq $TierId) { return $i }
    }
    throw "Unknown Gearbox tier: $TierId"
}

function Clamp-Tier {
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$TierId,
        [Parameter(Mandatory=$true)][string]$MinTier,
        [Parameter(Mandatory=$true)][string]$MaxTier
    )
    $index = Get-TierIndex -Config $Config -TierId $TierId
    $minIndex = Get-TierIndex -Config $Config -TierId $MinTier
    $maxIndex = Get-TierIndex -Config $Config -TierId $MaxTier
    if ($minIndex -gt $maxIndex) { throw "MinTier '$MinTier' is above MaxTier '$MaxTier'." }
    if ($index -lt $minIndex) { return $MinTier }
    if ($index -gt $maxIndex) { return $MaxTier }
    return $TierId
}

function Get-NextHigherTier {
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$CurrentTier,
        [Parameter(Mandatory=$true)][string]$MaxTier
    )
    $current = Get-TierIndex -Config $Config -TierId $CurrentTier
    $max = Get-TierIndex -Config $Config -TierId $MaxTier
    if ($current -ge $max) { return $null }
    return $Config.tiers[$current + 1].id
}

function Write-GearboxJson {
    param([Parameter(Mandatory=$true)]$Value, [Parameter(Mandatory=$true)][string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-CodexVersionInfo {
    $codex = Get-CodexCommand
    $text = (& $codex --version 2>&1 | Out-String).Trim()
    $version = $null
    if ($text -match '(\d+\.\d+\.\d+)') {
        $version = [version]$Matches[1]
    }
    return [pscustomobject]@{ path = $codex; raw = $text; version = $version }
}

function Get-CodexSandboxHelperCandidates {
    param([Parameter(Mandatory=$true)][string]$CodexPath)
    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add((Join-Path (Split-Path -Parent $CodexPath) 'codex-windows-sandbox-setup.exe'))
    if ($env:LOCALAPPDATA) {
        $root = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
        if (Test-Path $root) { Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | ForEach-Object { [void]$candidates.Add((Join-Path $_.FullName 'codex-windows-sandbox-setup.exe')) } }
    }
    if ($env:USERPROFILE) { [void]$candidates.Add((Join-Path $env:USERPROFILE '.codex\plugins\.plugin-appserver\codex-windows-sandbox-setup.exe')) }
    @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)
}

function Resolve-CodexSandboxHelper {
    param([Parameter(Mandatory=$true)][string]$CodexPath)
    $expected = Join-Path (Split-Path -Parent $CodexPath) 'codex-windows-sandbox-setup.exe'
    $found = Get-CodexSandboxHelperCandidates $CodexPath
    $selected = $found | Select-Object -First 1
    [pscustomobject]@{ cli_path=(Resolve-Path $CodexPath).Path; expected_path=$expected; helper_path=if($selected){(Resolve-Path $selected).Path}else{$null}; helper_exists=($null -ne $selected); helper_is_adjacent=($null -ne $selected -and (Split-Path $selected -Parent) -eq (Split-Path $CodexPath -Parent)); candidates=$found }
}
