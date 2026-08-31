[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Workdir,
    [string]$VerifyCommand,
    [string]$OutputDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Workdir)) { throw "Workdir not found: $Workdir" }
if ($OutputDir) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
$isGitRepo = $false
$branch = $null
$commit = $null
$status = ''
$diffStat = ''

if ($gitAvailable) {
    & git -C $Workdir rev-parse --is-inside-work-tree *> $null
    $isGitRepo = ($LASTEXITCODE -eq 0)
    if ($isGitRepo) {
        $branch = (& git -C $Workdir rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
        $commit = (& git -C $Workdir rev-parse HEAD 2>$null | Out-String).Trim()
        $status = (& git -C $Workdir status --porcelain=v1 2>&1 | Out-String).TrimEnd()
        $diffStat = (& git -C $Workdir diff --stat 2>&1 | Out-String).TrimEnd()
    }
}

$verifyExit = $null
$verifyOutput = ''
if ($VerifyCommand) {
    Push-Location $Workdir
    try {
        $global:LASTEXITCODE = 0
        $script = [scriptblock]::Create($VerifyCommand)
        $verifyOutput = (& $script 2>&1 | Out-String).TrimEnd()
        $verifyExit = $LASTEXITCODE
        if ($null -eq $verifyExit) { $verifyExit = 0 }
    }
    catch {
        $verifyOutput = $_ | Out-String
        $verifyExit = 1
    }
    finally {
        Pop-Location
    }

    if ($OutputDir) {
        $verifyOutput | Set-Content -LiteralPath (Join-Path $OutputDir 'verification.log') -Encoding UTF8
    }
}

[pscustomobject]@{
    git_available = $gitAvailable
    is_git_repo = $isGitRepo
    branch = $branch
    commit = $commit
    git_status = $status
    diff_stat = $diffStat
    verify_command = $VerifyCommand
    verify_exit_code = $verifyExit
    verify_output = $verifyOutput
} | ConvertTo-Json -Depth 8 -Compress
