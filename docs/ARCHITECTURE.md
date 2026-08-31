# Architecture

Codex Gearbox is intentionally a thin orchestrator around supported Codex CLI primitives rather than a fork of Codex.

## Execution flow

1. The user supplies a task, profile, workspace, and optional floor/ceiling.
2. `scripts/gearbox.ps1` resolves the profile and clamps all tiers to the configured range.
3. `scripts/worker.ps1` launches `codex exec` with an explicit GPT-5.6 model and `model_reasoning_effort`.
4. The worker operates in the real workspace and returns a JSON-schema-constrained decision.
5. `scripts/verify.ps1` captures objective repository state and can run an explicit user-provided verification command.
6. The router decides to complete, continue, escalate, downshift, review, or stop.
7. The next worker gets a compact handoff JSON rather than a duplicated transcript.

## Why separate workers

Codex does not need an undocumented mid-inference model mutation for Gearbox to be useful. Separate workers provide strong boundaries:

- every tier choice is visible in logs;
- a configured ceiling is enforceable;
- stronger workers receive only relevant handoff state;
- routine follow-up can be deliberately downshifted;
- failures can be retried/escalated without keeping one expensive model active for the whole workflow.

## Routing signals

The worker contributes semantic signals: completion state, risk, confidence, unresolved issue, recommended tier, and a stable failure signature.

The router contributes mechanical signals: exit code, structured-output validity, repeated failure signature, explicit verification command result, max-step count, escalation budget, and floor/ceiling.

A model recommendation is advisory. The router always clamps it to policy.

## Quota philosophy

Gearbox cannot reliably query a personal ChatGPT/Codex remaining weekly quota and therefore does not pretend to enforce a percentage-of-plan budget. Instead it enforces local, auditable budgets such as maximum steps, maximum escalations, and a maximum tier.

These controls reduce unnecessary high-tier work but do not make worker calls free. Every `codex exec` call uses the user's normal Codex access and is accounted for normally.

## Security

Default child sandbox: `workspace-write`.

Default approval mode: `never` for child workers, because a nested non-interactive worker cannot stop for a phone-side approval prompt. The sandbox and Codex execpolicy remain the boundary.

`danger-full-access` is available only as an explicit configuration/user override. Gearbox never silently falls back to it when a sandboxed worker fails.

## Windows caveat

Codex CLI behavior changes over time and Windows sandbox regressions can occur. Diagnostics inspect the installed CLI rather than assuming the repository's development-time environment. If `workspace-write` is broken in a particular Codex build, diagnose or upgrade Codex first instead of automatically disabling sandboxing.
