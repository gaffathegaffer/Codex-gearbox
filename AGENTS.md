# Codex Gearbox project instructions

This repository implements an adaptive orchestration layer around `codex exec`.

## When working in this repository

1. Read `plugins/codex-gearbox/skills/codex-gearbox/SKILL.md` before changing routing, installation, model selection, or worker behavior.
2. Treat `config/gearbox.json` and `schemas/worker-result.schema.json` as public contracts. Keep scripts compatible with them.
3. Prefer Windows PowerShell 5.1-compatible syntax unless a feature truly requires newer PowerShell.
4. Do not introduce an OpenAI API key requirement. The primary execution path must keep using the user's existing Codex authentication.
5. Do not hard-code plan quota values. Gearbox can bound its own worker/escalation counts, but Codex does not expose a reliable personal remaining-quota counter here.
6. Never make `danger-full-access` or `--yolo` the default. `workspace-write` is the default child sandbox.
7. Never use `git reset --hard`, `git clean`, forced checkout, or equivalent destructive cleanup as part of installation, routing, tests, or diagnostics.
8. Keep child-worker handoffs compact. Stronger models should receive the original goal, the relevant previous result, verification state, and current repository state, not a giant duplicated transcript.
9. Use `--output-schema` plus `--output-last-message` for machine-readable worker decisions. Ensure output directories exist before invoking Codex.
10. Any model or CLI syntax that may have changed should be verified against the installed `codex --help` / `codex exec --help` first; current official docs are the fallback source.

## Validation after changes

At minimum:

- parse every JSON file;
- parse every PowerShell file with the PowerShell parser;
- run `scripts/doctor.ps1`;
- use `scripts/gearbox.ps1 -DryRun` for routing logic changes;
- do not spend model quota on a smoke inference unless the user explicitly asks or the change cannot otherwise be validated.
