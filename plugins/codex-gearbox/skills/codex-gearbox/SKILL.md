---
name: codex-gearbox
description: Route local Codex work adaptively across GPT-5.6 Luna, Terra and Sol using Eco, Balance or Sport profiles. Use when the user asks for Gearbox, autopilot, automatic model switching, quota-aware Codex execution, Eco/Balance/Sport mode, a model ceiling/floor, or wants a task delegated to the cheapest capable Codex tier with escalation when needed.
---

# Codex Gearbox

Use the installed Gearbox runtime instead of manually simulating adaptive routing inside one parent response.

## Core behavior

- Gearbox is an orchestration layer. It launches separate `codex exec` workers with explicit model and reasoning settings.
- The parent Codex thread should stay lightweight: resolve the requested profile/bounds, invoke Gearbox, and report the result. Do not independently redo the whole task before or after Gearbox.
- Prefer `balance` when the user does not name a profile.
- Respect explicit `MinTier` and `MaxTier` bounds exactly. Never exceed the user's ceiling.
- `workspace-write` is the default sandbox. Never silently switch to `danger-full-access` / `--yolo`.
- Preserve local and uncommitted work. Never run destructive Git cleanup as part of routing.

## Find the runtime

Preferred installed entry point:

```powershell
$gearbox = Join-Path $HOME '.codex-gearbox\gearbox.ps1'
```

If that file is missing but the current repository is Codex Gearbox, use its root `gearbox.ps1` and recommend running `scripts/install.ps1` afterward.

## Typical invocations

```powershell
& $gearbox -Profile balance -Task "Fix the failing tests and verify the result" -Workdir "C:\path\to\repo"
```

```powershell
& $gearbox -Profile eco -MaxTier terra-high -Task "Install and configure this project" -Workdir "C:\path\to\repo"
```

```powershell
& $gearbox -Profile sport -MinTier terra-medium -MaxTier sol-high -Task "Audit and improve this implementation" -Workdir "C:\path\to\repo"
```

## Profile intent

- `eco`: optimize for quota. Start on Luna and escalate reluctantly. Default ceiling is Terra High.
- `balance`: optimize capability per unit of usage. Start on Luna Medium and permit escalation through Sol High when evidence justifies it.
- `sport`: optimize quality. Start on Terra Medium and permit Sol up to Max, while still handing mechanical follow-up down when possible.
- `custom`: only use when the user supplied explicit routing requirements or the task genuinely needs non-default bounds.

## Do not waste the parent model

When invoked from a Codex thread, the parent model is already consuming usage. Do not spend a strong parent turn analyzing work that the routed workers will immediately repeat. For routine orchestration, Luna is the preferred parent model when the user can choose it.

## Diagnostics

Before troubleshooting routing internals, run:

```powershell
& (Join-Path $HOME '.codex-gearbox\scripts\doctor.ps1')
```

Use `-SmokeTest` only when a real live model call is necessary. It consumes Codex usage.

## Updating Gearbox

When the source checkout is available, update it non-destructively and rerun:

```powershell
& .\scripts\install.ps1
& .\scripts\doctor.ps1
```

Do not overwrite `config/gearbox.local.json` in the installed runtime if the user has local overrides.
