---
name: opentofu-core
description: "Run guarded OpenTofu lifecycle workflows for formatting, initialization, validation, planning, applying, destroying, importing, and refreshing infrastructure. Use when Codex must execute or prepare core `tofu` operations with preflight checks, explicit mutation approval, and reviewable output."
---

# OpenTofu Core

## What this skill owns

- configuration formatting and initialization
- validation and planning
- apply / destroy request flow with explicit checks
- resource import workflows

## Core flow

For preflight, planning, and saved-plan apply, prefer the bundled MCP tools:

1. `opentofu_preflight`
2. `opentofu_policy_check` when policy evidence is required
3. `opentofu_plan`
4. review its summary and JSON artifacts
5. after explicit user approval, call `opentofu_execute_plan` with the same
   `stack_path`, returned `plan_id`, and exact confirmation token

The plan expires after 15 minutes and is single-use. Configuration changes or
plan-file changes invalidate it. A failed apply still consumes the plan because
the remote result may be uncertain.

Run preflight before major lifecycle operations:

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
"$PLUGIN_ROOT/scripts/preflight.sh" --path .
```

Execute lifecycle tasks with the standard wrapper for consistent output:

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
"$PLUGIN_ROOT/scripts/run-plan.sh" --path . init
"$PLUGIN_ROOT/scripts/run-plan.sh" --path . validate
"$PLUGIN_ROOT/scripts/run-plan.sh" --path . plan -compact-warnings
"$PLUGIN_ROOT/scripts/run-plan.sh" --path . apply
```

## Basic command patterns

- format without mutation:

```bash
tofu fmt -recursive -check .
tofu fmt -recursive
```

- initialize and validate:

```bash
$PLUGIN_ROOT/scripts/run-plan.sh --path . init
$PLUGIN_ROOT/scripts/run-plan.sh --path . validate
```

- plan and apply:

```bash
$PLUGIN_ROOT/scripts/run-plan.sh --path . plan -out=artifacts/open-tofu.tfplan
$PLUGIN_ROOT/scripts/run-plan.sh --path . apply artifacts/open-tofu.tfplan
```

- import:

```bash
tofu import [options] module.path provider.id
```

## Guardrails

- `destroy` and `apply` commands should be paired with explicit user confirmation before running outside dry-run.
- default wrappers keep `-input=false` where applicable.
- never reuse plans across unrelated directories.
- avoid `--target` and `-target` unless scoped rollback is explicitly requested and reviewed.
- avoid `-replace` without impact analysis because it can trigger broad replacement.
- do not use `-auto-approve` without explicit enterprise approval path.
- do not use the MCP apply tool for destroy, import, refresh, or ad hoc apply arguments.

### Enterprise apply approval gate

In `OPENTOFU_MODE=enterprise`, `apply` is blocked until approval is supplied:

- OPENTOFU_APPROVAL_TOKEN (or --approval-token)
- `OPENTOFU_PROFILE` (`dev`, `stg`, or `prod`)
- optional deterministic context: `run_id`, `profile`, `workspace`, and `backend_hint`/`OPENTOFU_BACKEND_HINT`
- Require the same deterministic unblock path everywhere: set OPENTOFU_APPROVAL_TOKEN (or --approval-token) and rerun the same command with unchanged context: `run_id`, `profile`, `workspace`, and `backend_hint`.

Example:

```bash
export OPENTOFU_MODE=enterprise
export OPENTOFU_APPROVAL_TOKEN="change-review-1234"
export OPENTOFU_PROFILE=stg
export OPENTOFU_RUN_ID="$(date +%Y%m%dT%H%M%S)"
export OPENTOFU_BACKEND_HINT=backend-prod.hcl

$PLUGIN_ROOT/scripts/run-plan.sh --path . --workspace prod --backend-config "$OPENTOFU_BACKEND_HINT" apply
```
