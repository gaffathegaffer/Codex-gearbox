[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task = '',

    [ValidateSet('eco','balance','sport','custom')]
    [string]$Profile = 'balance',

    [string]$Workdir = (Get-Location).Path,
    [string]$MinTier,
    [string]$StartTier,
    [string]$MaxTier,
    [int]$MaxSteps = 0,
    [string]$VerifyCommand,
    [string]$Sandbox,
    [switch]$NoFinalReview,
    [switch]$DryRun,
    [string]$Resume,
    [string]$InspectRun,
    [switch]$Json
)

$runtime = Join-Path $PSScriptRoot 'scripts\gearbox.ps1'
if (-not (Test-Path $runtime)) {
    throw "Gearbox runtime not found: $runtime"
}

& $runtime @PSBoundParameters
exit $LASTEXITCODE
