[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$install = Join-Path $PSScriptRoot 'install.ps1'
$doctor = Join-Path $PSScriptRoot 'doctor.ps1'

Write-Host 'Codex Gearbox bootstrap' -ForegroundColor Cyan
& $install
if ($LASTEXITCODE -ne 0) { throw 'Gearbox installation failed.' }

& $doctor
if ($LASTEXITCODE -ne 0) { throw 'Gearbox doctor reported required failures.' }

Write-Host 'Bootstrap complete. No live routed workload was started.' -ForegroundColor Green
