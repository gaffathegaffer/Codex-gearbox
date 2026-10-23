$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/common.ps1')
if ((Get-GearboxPlatform) -eq 'Windows') {
    Write-Output 'linux-worker.tests: SKIP (Linux integration test)'
    exit 0
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('gearbox linux ' + [guid]::NewGuid().ToString('N'))
$oldCodexPath = $env:CODEX_CLI_PATH
$oldMode = $env:GEARBOX_FIXTURE_MODE
$oldPath = $env:PATH
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $cli = Join-Path $tmp 'codex'
    # Deterministic CLI fixture: captures the real worker invocation and stdin,
    # never calls a model or modifies authentication.
    @'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
mode = os.environ.get('GEARBOX_FIXTURE_MODE', '')
if args == ['--version']:
    print('codex-cli 0.163.0')
elif args == ['debug', 'models']:
    models = [] if mode == 'missing-model' else [{
        'slug': 'gpt-6.1-sol',
        'supported_reasoning_levels': [{'effort': 'medium'}]
    }]
    print(json.dumps(models))
else:
    step = pathlib.Path(args[args.index('--output-last-message') + 1]).parent
    (step / 'invocation.json').write_text(json.dumps({
        'args': args, 'path': os.environ['PATH'], 'prompt': sys.stdin.read()
    }))
    if mode == 'failure':
        print('fixture failure', file=sys.stderr)
        sys.exit(7)
    if mode == 'proxy-denied':
        print('HTTP CONNECT failed with status 403', file=sys.stderr)
        sys.exit(7)
    result = dict(status='complete', summary='fixture complete', verification=['fixture'],
        changed_files=[], unresolved=None, recommended_next_tier=None, risk='low',
        confidence=1, should_review=False, failure_signature=None, next_action=None)
    (step / 'final.json').write_text(json.dumps(result))
    print('{}')
'@ | Set-Content -LiteralPath $cli -Encoding utf8NoBOM
    & chmod +x $cli
    $env:CODEX_CLI_PATH = $cli
    $distribution = Test-CodexSandboxDistribution $cli
    if (-not $distribution.sandbox_ready -or $distribution.required_companions.Count) { throw 'Unix CLI incorrectly requires Windows companions.' }
    if ((Get-CodexCommand) -ne $cli) { throw 'Explicit Unix CLI was not selected.' }
    Remove-Item Env:CODEX_CLI_PATH
    $env:PATH = $tmp + [IO.Path]::PathSeparator + $oldPath
    if ((Get-CodexCommand) -ne $cli) { throw 'Unix PATH discovery failed.' }
    $env:PATH = $oldPath
    $env:CODEX_CLI_PATH = $cli

    $step = Join-Path $tmp 'step one'
    $params = @{Task='Test structured handoff'; Workdir=$root; TierId='sol-medium'; MinTier='luna-low'; MaxTier='sol-high'; StepDir=$step}
    $wrapper = & (Join-Path $root 'scripts/worker.ps1') @params | ConvertFrom-Json
    if ($wrapper.codex_exit_code -ne 0 -or $wrapper.result.status -ne 'complete') { throw ('Unix worker failed: ' + ($wrapper | ConvertTo-Json -Depth 10 -Compress)) }
    $capture = Get-Content (Join-Path $step 'invocation.json') -Raw | ConvertFrom-Json
    if ($capture.path -cne $oldPath -or $env:PATH -cne $oldPath) { throw 'Unix PATH was changed.' }
    if ($capture.args -notcontains 'gpt-6.1-sol' -or $capture.args -notcontains 'model_reasoning_effort=medium' -or $capture.args -notcontains 'workspace-write') { throw 'Model, reasoning or sandbox was not passed correctly.' }
    if ($capture.args -notcontains '--output-schema' -or $capture.args -notcontains '--output-last-message' -or $capture.prompt -notmatch 'Test structured handoff') { throw 'Structured output or prompt was lost.' }
    if (-not $wrapper.shell_preflight.child_pwsh -or $wrapper.shell_preflight.workaround -ne 'none') { throw 'Unix executable discovery failed.' }

    $env:GEARBOX_FIXTURE_MODE = 'failure'
    $wrapper = & (Join-Path $root 'scripts/worker.ps1') @params | ConvertFrom-Json
    if ($wrapper.codex_exit_code -ne 7 -or $null -ne $wrapper.result -or -not $wrapper.parse_error) { throw 'Native failure or stale final output was accepted.' }
    Remove-Item (Join-Path $step 'invocation.json')
    $env:GEARBOX_FIXTURE_MODE = 'missing-model'
    $wrapper = & (Join-Path $root 'scripts/worker.ps1') @params | ConvertFrom-Json
    if ($wrapper.result.failure_signature -ne 'model_unavailable' -or (Test-Path (Join-Path $step 'invocation.json'))) { throw 'Unavailable model was executed.' }
    Remove-Item Env:GEARBOX_FIXTURE_MODE
    $catalog = @(Get-CodexModelCatalog $cli)
    if (Test-GearboxModelSupport -Tier ([pscustomobject]@{model='gpt-6.1-sol';reasoning='ultra'}) -Catalog $catalog) { throw 'Unsupported reasoning was accepted.' }

    # Exercise routing, worker, verification and persisted recovery together.
    $workdir = Join-Path $tmp 'repo'
    New-Item -ItemType Directory -Path $workdir | Out-Null
    & git -C $workdir init -q
    Set-Content (Join-Path $workdir 'sample.txt') 'fixture'
    & git -C $workdir add sample.txt
    & git -C $workdir -c user.name=test -c user.email=test@example.invalid commit -qm fixture
    $text = & (Join-Path $root 'scripts/gearbox.ps1') -Profile custom -StartTier sol-medium -MaxTier sol-high -MaxSteps 1 -NoFinalReview -Task 'Fixture task' -Workdir $workdir -VerifyCommand 'git diff --exit-code'
    if ($LASTEXITCODE -ne 0) { throw 'Router failed.' }
    $summary = $text | Select-Object -Last 1 | ConvertFrom-Json
    $state = Get-Content (Join-Path $summary.run_dir 'run-state.json') -Raw | ConvertFrom-Json
    if ($summary.status -ne 'complete' -or $summary.steps_used -ne 1 -or $state.terminal_status -ne 'complete') { throw 'Router did not persist completion.' }
    $env:GEARBOX_FIXTURE_MODE = 'proxy-denied'
    $text = & (Join-Path $root 'scripts/gearbox.ps1') -Profile custom -StartTier sol-medium -MaxTier sol-high -MaxSteps 2 -NoFinalReview -Task 'Fixture task' -Workdir $workdir
    if ($LASTEXITCODE -ne 2) { throw 'Proxy denial did not stop routing.' }
    $summary = $text | Select-Object -Last 1 | ConvertFrom-Json
    if ($summary.steps_used -ne 1 -or $summary.escalations -ne 0 -or $summary.last_result.failure_signature -ne 'proxy_connection_denied' -or $summary.history[0].codex_exit_code -ne 7) { throw 'Proxy denial was escalated or native exit status was lost.' }
    $global:LASTEXITCODE = 0
    Write-Output 'linux-worker.tests: PASS (discovery, invocation, failure, model validation, routing and recovery)'
}
finally {
    $env:CODEX_CLI_PATH = $oldCodexPath
    $env:GEARBOX_FIXTURE_MODE = $oldMode
    $env:PATH = $oldPath
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
