# Codex Gearbox bootstrap procedure

This document is meant to be executed by Codex on the user's Windows PC.

## Goal

Leave Codex Gearbox installed, indexed, diagnosed, and ready for later routed tasks. Do not run a real Gearbox workload during bootstrap.

## Procedure

1. Preserve all existing user work. Never run `git reset --hard`, `git clean`, forced checkout, or commands that discard uncommitted files.
2. Confirm the checkout is `https://github.com/gaffathegaffer/Codex-gearbox` and inspect `git status`, branch, commit, and remotes.
3. If the checkout is behind `origin/main`, update it non-destructively. If clean, normally use `git fetch origin` and `git pull --ff-only origin main`. If dirty, preserve the changes and integrate safely rather than discarding them.
4. Read `AGENTS.md`, `README.md`, and `plugins/codex-gearbox/skills/codex-gearbox/SKILL.md`.
5. Inspect the locally installed Codex before assuming flags or paths:
   - `where.exe codex`
   - `codex --version`
   - `codex exec --help`
   - `codex doctor --summary --ascii`
6. GPT-5.6 in Codex requires Codex CLI 0.144.0 or newer. If the installed CLI is older, identify how this PC installed Codex and update it using the matching official/safe channel. Preserve authentication and user config. Do not guess package-manager commands if installation provenance is unclear.
7. Run `scripts/install.ps1`. It should:
   - copy the Gearbox runtime to `$HOME\.codex-gearbox`;
   - install/update the local Codex plugin if the installed CLI exposes plugin commands;
   - install personal skill fallbacks under `$HOME\.agents\skills\codex-gearbox` and `$HOME\.codex\skills\codex-gearbox`.
8. Run `scripts/doctor.ps1` and fix concrete local setup problems it identifies. Do not weaken sandboxing to hide a failure.
9. Validate all repository PowerShell scripts with the PowerShell parser and all JSON files with `ConvertFrom-Json`.
10. Run a quota-free routing dry run, for example:

```powershell
& .\scripts\gearbox.ps1 -Profile balance -DryRun -Task "Inspect this repository and report readiness" -Workdir (Get-Location).Path
```

11. Do not run the optional `doctor.ps1 -SmokeTest` unless a live inference is genuinely needed. It consumes Codex usage.
12. Do not execute a real routed coding task during bootstrap.

## Completion criteria

Report:

- repository path, branch, and commit;
- Codex executable path and version;
- whether `codex exec` exposes `--model`, `--output-schema`, `--output-last-message`, and `--sandbox`;
- runtime install path;
- plugin installation state;
- both personal skill-fallback states;
- JSON and PowerShell parse status;
- `doctor.ps1` result;
- `gearbox.ps1 -DryRun` result;
- any remaining blocker.

If plugin or skill indexing requires opening a new Codex thread or restarting the Codex surface, say so explicitly.
