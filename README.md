# Codex Gearbox

Adaptive model routing for OpenAI Codex on a local machine.

Codex Gearbox adds an `eco / balance / sport` layer above `codex exec`. Instead of running every phase of a task on the most expensive model and reasoning level, Gearbox starts at an appropriate tier, evaluates the result, escalates only when needed, and can hand routine work back down to a cheaper tier.

> **Status:** experimental orchestration layer for Codex CLI. It does not change Codex itself and it does not bypass plan limits. Every worker is a normal Codex run and counts as Codex usage.

## What it does

- Routes work between GPT-5.6 Luna, Terra, and Sol.
- Controls reasoning effort independently from model choice.
- Provides `eco`, `balance`, `sport`, and `custom` profiles.
- Supports explicit minimum and maximum tiers, including an opt-in `sol-ultra` ceiling.
- Uses structured worker results to decide whether to complete, escalate, retry, continue, or stop.
- Carries compact handoff context between workers instead of forcing every stronger model to rediscover the entire task.
- Records run metadata, decisions, outputs, and verification state under `.gearbox/`.
- Preserves the user's working tree. Gearbox never runs destructive Git cleanup commands on its own.
- Installs as a Codex plugin/skill when supported, with personal skill fallbacks for compatibility.

## Why

The expensive part of an agentic coding task is often unevenly distributed. Dependency installation, formatting, routine edits, and test reruns usually do not require the same model budget as architecture decisions, ambiguous debugging, or final review.

Gearbox treats model capacity like gears rather than a permanent setting:

```text
phone / Codex Remote
        |
        v
   Codex Gearbox
        |
        +--> Luna  : routine execution
        +--> Terra : difficult debugging / broader reasoning
        +--> Sol   : high-stakes analysis / deep review
```

## Default profiles

| Profile | Starts at | Maximum | Intended behavior |
| --- | --- | --- | --- |
| `eco` | Luna / medium | Terra / high | Spend as little as practical; escalate reluctantly. |
| `balance` | Luna / medium | Sol / high | Default. Escalate when evidence says it is useful. |
| `sport` | Terra / medium | Sol / max | Quality-first, but still avoids using the strongest tier for mechanical work. |
| `custom` | user supplied | user supplied | Explicit floor, ceiling, budgets, and review behavior. |

**Sol Ultra is deliberately outside the built-in profile ceilings.** To permit it for a particular workload, explicitly pass `-MaxTier sol-ultra`. This makes the most expensive/orchestrated mode an opt-in rather than something Gearbox can silently wander into.

The exact tier table lives in `config/gearbox.json` and can be edited without changing the router code.

## Requirements

- Windows 10/11
- PowerShell 5.1 or newer
- Git
- OpenAI Codex CLI with ChatGPT or API authentication
- Codex CLI **0.144.0 or newer** for GPT-5.6 access

Codex currently exposes non-interactive execution with `codex exec`, a per-run model override with `--model`, configuration overrides with `-c key=value`, JSON-schema-constrained final output with `--output-schema`, and sandbox selection with `--sandbox`.

## Install

Clone the repository, open the checkout in Codex, and paste the contents of `CODEX_START_PROMPT.md` into Codex. The bootstrap prompt tells Codex to inspect the machine, install the plugin/skill, run diagnostics, and leave the system ready without starting a real routed workload.

Manual installation is also possible:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& .\scripts\install.ps1
& .\scripts\doctor.ps1
```

## Use

From a PowerShell terminal:

```powershell
& "$HOME\.codex-gearbox\gearbox.ps1" -Profile balance -Task "Fix the failing tests and verify the project"
```

Or, from a checkout of this repository:

```powershell
& .\scripts\gearbox.ps1 -Profile balance -Task "Fix the failing tests and verify the project" -Workdir C:\path\to\project
```

Useful examples:

```powershell
# Very quota-conscious
& .\scripts\gearbox.ps1 -Profile eco -Task "Install dependencies and run the test suite" -Workdir C:\repo

# Balanced default with an explicit ceiling
& .\scripts\gearbox.ps1 -Profile balance -MaxTier sol-high -Task "Find and fix the CUDA initialization failure" -Workdir C:\repo

# Quality-first with a lower floor
& .\scripts\gearbox.ps1 -Profile sport -MinTier terra-medium -Task "Audit this refactor, fix regressions, and verify it" -Workdir C:\repo

# Explicitly permit Ultra for an exceptional job
& .\scripts\gearbox.ps1 -Profile sport -MaxTier sol-ultra -Task "Deeply audit this unusually complex system" -Workdir C:\repo

# See the plan without spending Codex usage
& .\scripts\gearbox.ps1 -Profile balance -DryRun -Task "Refactor the data layer" -Workdir C:\repo
```

## Safety model

Gearbox defaults child workers to `workspace-write` and `--ask-for-approval never` so the orchestration can remain non-interactive while writes stay scoped to the workspace. It does **not** default to `danger-full-access` or `--yolo`.

If a local Codex/Windows sandbox bug prevents legitimate workspace writes, `doctor.ps1` reports the condition. Changing the sandbox to `danger-full-access` is an explicit user decision in `config/gearbox.local.json`; the installer does not silently weaken the sandbox.

Gearbox also refuses to automate destructive Git cleanup (`git reset --hard`, `git clean -fd`, deleting uncommitted work) unless the task itself explicitly requests such an operation and the active worker's normal Codex safety policy permits it.

## Routing model

Each worker receives the original goal plus a compact handoff packet. Its final response is constrained by `schemas/worker-result.schema.json` and includes:

- `status`: `complete`, `continue`, `escalate`, or `blocked`
- a concise summary of work performed
- verification evidence
- unresolved problem / escalation reason
- recommended next tier
- confidence and risk classification

The router combines that signal with objective observations such as worker exit code, repeated failure signatures, Git status, optional verification command results, escalation budget, and the configured min/max tier.

A worker cannot exceed the ceiling merely by asking for a stronger model.

## Configuration

`config/gearbox.json` is version-controlled and contains safe defaults. `config/gearbox.local.json` is optional and ignored by Git. Local values override the defaults.

Typical local override:

```json
{
  "default_profile": "balance",
  "sandbox": "workspace-write",
  "profiles": {
    "balance": {
      "max_tier": "sol-high",
      "max_escalations": 2
    }
  }
}
```

## Logs

Every routed task gets its own directory:

```text
.gearbox/
  runs/
    20260831-170000-1234/
      run.json
      step-01/
        prompt.txt
        final.json
        stdout.log
        stderr.log
      handoff.json
      summary.json
```

`.gearbox/` is ignored by Git by default.

## Project layout

```text
.agents/plugins/marketplace.json
plugins/codex-gearbox/
  .codex-plugin/plugin.json
  skills/codex-gearbox/
    SKILL.md
    agents/openai.yaml
config/gearbox.json
schemas/worker-result.schema.json
scripts/
  bootstrap.ps1
  common.ps1
  doctor.ps1
  install.ps1
  gearbox.ps1
  worker.ps1
  verify.ps1
AGENTS.md
CODEX_BOOTSTRAP.md
CODEX_START_PROMPT.md
```

## Important limitation

This is adaptive **orchestration**, not an undocumented in-place model switch. A single Codex inference does not transform itself from Luna into Sol halfway through the same turn. Gearbox starts separate `codex exec` workers at selected tiers and passes state between them.

That separation is intentional: it keeps model choice inspectable, bounded, and auditable.

## License

MIT. See `LICENSE`.
