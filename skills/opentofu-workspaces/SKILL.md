---
name: opentofu-workspaces
description: "Manage OpenTofu workspaces, remote backends, backend migrations, dependency locks, and state consistency with explicit environment scope. Use for workspace selection or deletion, backend reconfiguration, migration planning, lock contention, or ambiguous state context."
---

# OpenTofu Workspaces and Backends

## What this skill owns

- workspace lifecycle and switching
- remote backend init and migration patterns
- lockfile and state consistency checks

The bundled MCP server can preflight and bind a plan to an explicit workspace,
but it does not expose workspace creation/deletion or backend migration. Keep
those mutations on this skill's guarded script path with source/target evidence.

## Workspace patterns

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"

"$PLUGIN_ROOT/scripts/preflight.sh" --path . --check-only

tofu workspace list
tofu workspace new <name>
tofu workspace select <name>
tofu workspace show
```

## Remote backend and migration checks

- inspect backend references:

```bash
rg -n "backend \"" *.tf *.tfvars .
```

- initialize remote backend for a selected workspace:

```bash
$PLUGIN_ROOT/scripts/run-plan.sh --path . init -reconfigure
```

## Lockfile and drift readiness

- run lock and state consistency checks:

```bash
$PLUGIN_ROOT/scripts/run-plan.sh --path . validate
$PLUGIN_ROOT/scripts/drift-check.sh --path . --workspace <workspace>
```

## Workspace + lockfile hygiene checklist

Use this before any migration or long mutating workspace sequence:

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
RUN_ID="${OPENTOFU_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$$}"
WORKSPACE="dev"
BACKEND_HINT="backend-dev.hcl"

"$PLUGIN_ROOT/scripts/preflight.sh" --path . \
  --mode mutating \
  --workspace "$WORKSPACE" \
  --backend-config "$BACKEND_HINT" \
  --expected-workspace "$WORKSPACE" \
  --expected-backend "$BACKEND_HINT" \
  --profile dev \
  --check-only

for lockfile in .terraform.lock.hcl terraform.lock.hcl; do
  if [[ -f "$lockfile" ]]; then
    lockfile_hash="$(sha256sum "$lockfile" | awk '{print $1}')"
    echo "lockfile_ok path=${lockfile} sha256=${lockfile_hash}"
  else
    echo "lockfile_missing path=${lockfile}"
  fi
done

ls -1 .terraform/terraform.tfstate terraform.tfstate 2>/dev/null | sed 's/^/state_file: /'

"$PLUGIN_ROOT/scripts/drift-check.sh" --path . \
  --run-id "$RUN_ID" \
  --artifact-dir .tofu-artifacts \
  --workspace "$WORKSPACE" \
  --backend-uri "s3://state-bucket-dev/my/workspace.tfstate" \
  --backend-source-uri "s3://state-bucket-old/my/workspace.tfstate" \
  --backend-target-uri "s3://state-bucket-new/my/workspace.tfstate"
```

Checklist:

- require explicit workspace targets for `workspace select`, `workspace new`, and `workspace delete`.
- ensure expected workspace matches active workspace where `--expected-workspace` is set.
- require workspace + backend context for mutating workspace/backend flows.
- capture and record lockfile hashes before migration and optionally enforce `--expected-lockfile-hash`.
- confirm state file path(s) exist under expected convention for the active workflow.

## Migration runbook (workspace + backend + lockfile)

Use `drift-check` and `run-plan` together so every migration step has precheck and artifact evidence.

1. Pre-run

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
RUN_ID="${OPENTOFU_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$$}"

"$PLUGIN_ROOT/scripts/preflight.sh" --path . \
  --mode mutating \
  --workspace prod \
  --backend-config backend-prod.hcl \
  --expected-workspace prod \
  --expected-backend backend-prod.hcl \
  --profile prod \
  --check-only
```

2. Drift and contract validation

```bash
"$PLUGIN_ROOT/scripts/drift-check.sh" --path . \
  --workspace prod \
  --run-id "$RUN_ID" \
  --artifact-dir .tofu-artifacts \
  --expected-workspace prod \
  --backend-uri "s3://state-bucket-prod-old/my/prod.tfstate" \
  --expected-backend-uri "s3://state-bucket-prod-old/my/prod.tfstate" \
  --expected-lockfile-hash "placeholder-lockfile-hash" \
  --backend-source-uri "s3://state-bucket-prod-old/my/prod.tfstate" \
  --backend-target-uri "s3://state-bucket-prod-new/my/prod.tfstate"
```

3. Execute migration with explicit source/target metadata and artifacts

```bash
OPENTOFU_APPROVAL_TOKEN="change-2026-07-06-01"
OPENTOFU_RUN_ID="$RUN_ID"

"$PLUGIN_ROOT/scripts/run-plan.sh" --path . \
  --workspace prod \
  --backend-config backend-prod.hcl \
  --approval-token "$OPENTOFU_APPROVAL_TOKEN" \
  --backend-source-uri "s3://state-bucket-prod-old/my/prod.tfstate" \
  --backend-target-uri "s3://state-bucket-prod-new/my/prod.tfstate" \
  init -migrate-state
```

4. Evidence handoff

```bash
ls -1 .tofu-artifacts/drift-${RUN_ID}.txt .tofu-artifacts/backend-migration-${RUN_ID}-before.txt .tofu-artifacts/backend-migration-${RUN_ID}-after.txt
```

- Confirm workspace/backend context and lockfile hashes in drift and migration artifacts before proceed.

## Safe migration matrix

| Profile | Workspace argument policy | Backend URI policy | Lockfile hash policy | Notes |
| --- | --- | --- | --- | --- |
| dev | Hard-fail when missing workspace for migration and stateful mutation. | Warn on missing/mismatch for read-only checks, fail for migration. | Warn on mismatch. | Good place to capture baseline lockfile hashes. |
| stg | Hard-fail when missing workspace for migration/stateful mutation. | Hard-fail on expected backend mismatch when `--expected-backend-uri` is set. | Hard-fail when expected hash mismatches. | Keep explicit `run_id` and rerun context. |
| prod | Hard-fail when missing workspace for migration/stateful mutation. | Hard-fail on missing backend URI and mismatch when `--expected-backend-uri` is set. | Hard-fail when expected hash mismatches. | Treat every migration step as explicitly auditable. |

## Operating notes

- never switch workspace as part of long apply chains without restating scope.
- when migrating workspaces, preserve backend config context and confirm target workspace ownership.
