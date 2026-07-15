# OpenTofu Codex Plugin

This plugin provides guarded OpenTofu workflows for core execution, state,
workspaces, policy, modules, and GitOps. Enterprise mode keeps mutation explicit
and evidence-backed. A bundled Go STDIO MCP server adds typed preflight, policy,
immutable plan, confirmed apply, and bounded evidence tools.

## MCP server

Build the host binary before installing the local plugin:

```bash
./scripts/build-opentofu-mcp.sh
```

Tagged GitHub releases build complete plugin archives for macOS and Linux on
arm64 and amd64. The source checkout intentionally ignores `bin/`; local source
installs must build the host binary before refreshing the Codex plugin cache.

The launcher selects `bin/opentofu-mcp-<os>-<arch>` and never downloads code or
executables at MCP startup. The plugin exposes:

| Tool | Effect |
| --- | --- |
| `opentofu_preflight` | run explicit stack/profile context checks |
| `opentofu_policy_check` | run policy gates and write evidence |
| `opentofu_plan` | create plan artifacts plus a 15-minute immutable apply authorization |
| `opentofu_execute_plan` | consume one exact-confirmed plan and apply its saved plan file |
| `opentofu_get_evidence` | read up to 256 KiB from a stack evidence file |

Set `OPENTOFU_MCP_ROOTS` to a platform path-list of allowed stack roots when
path confinement is required. With no configured roots, the server accepts only
explicit absolute stack paths and reports that unrestricted root policy in
preflight output.

MCP apply is intentionally narrow. Destroy, import, state mutation, backend
migration, and workspace mutation remain on the guarded skill/script paths.

## Baseline

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
RUN_ID="local-$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR=".tofu-artifacts/${RUN_ID}"
export OPENTOFU_MODE=enterprise
export OPENTOFU_PROFILE=dev
```

Run local validation before handoff:

```bash
make validate-plugin PLUGIN=plugins/opentofu ENTERPRISE=1 PROFILE=dev
```

## Core

Plan first and keep the generated artifacts:

```bash
"$PLUGIN_ROOT/scripts/preflight.sh" --path . --profile dev --check-only --run-id "$RUN_ID" --artifact-dir "$ARTIFACT_DIR"
"$PLUGIN_ROOT/scripts/run-plan.sh" --path . --run-id "$RUN_ID" --artifact-dir "$ARTIFACT_DIR" plan
```

For apply, require approval context:

```bash
export OPENTOFU_APPROVAL_TOKEN="<approval-token>"
"$PLUGIN_ROOT/scripts/run-plan.sh" --path . --run-id "$RUN_ID" --artifact-dir "$ARTIFACT_DIR" apply "$ARTIFACT_DIR/open-tofu-${RUN_ID}.tfplan"
```

## State

State mutation requires explicit workspace/backend context:

```bash
ALLOW_STATE_WRITE=1 \
"$PLUGIN_ROOT/scripts/preflight.sh" \
  --path . \
  --profile stg \
  --mode mutating \
  --workspace stg \
  --backend-config backend-stg.hcl \
  --expected-workspace stg \
  --expected-backend backend-stg.hcl \
  --state-command "state mv" \
  --run-id "$RUN_ID" \
  --artifact-dir "$ARTIFACT_DIR"
```

## Workspaces

Workspace operations must be explicit. Backend migration records source and
target metadata:

```bash
"$PLUGIN_ROOT/scripts/run-plan.sh" \
  --path . \
  --workspace prod \
  --backend-config backend-prod.hcl \
  --backend-source-uri s3://old-state/prod.tfstate \
  --backend-target-uri s3://new-state/prod.tfstate \
  --run-id "$RUN_ID" \
  --artifact-dir "$ARTIFACT_DIR" \
  init -migrate-state
```

## Policy

Run policy gates before stg/prod plan or apply:

```bash
"$PLUGIN_ROOT/scripts/policy-gates.sh" \
  --path . \
  --profile prod \
  --run-id "$RUN_ID" \
  --artifact-dir "$ARTIFACT_DIR/policy"
```

Use an exception file only for documented external-tool exceptions:

```bash
"$PLUGIN_ROOT/scripts/policy-gates.sh" \
  --path . \
  --profile prod \
  --exception-file approvals/policy-exception.yaml \
  --run-id "$RUN_ID" \
  --artifact-dir "$ARTIFACT_DIR/policy"
```

## Modules

Module checks run through `preflight.sh` and `run-plan.sh`. For stricter
module governance, provide checksum expectations and deprecated-source patterns:

```bash
"$PLUGIN_ROOT/scripts/preflight.sh" \
  --path . \
  --profile prod \
  --mode mutating \
  --module-checksum-file governance/module-checksums.txt \
  --deprecated-module-source-file governance/deprecated-modules.txt \
  --run-id "$RUN_ID" \
  --artifact-dir "$ARTIFACT_DIR"
```

Deprecated module sources block mutation unless a non-empty exception file is
provided.

## GitOps

CI mode requires immutable artifacts and explicit run id/artifact dir:

```bash
"$PLUGIN_ROOT/scripts/policy-gates.sh" \
  --path . \
  --profile dev \
  --ci \
  --run-id "$RUN_ID" \
  --artifact-dir "$ARTIFACT_DIR/policy" \
  --skip-tflint \
  --skip-tfsec

"$PLUGIN_ROOT/scripts/run-plan.sh" \
  --path . \
  --ci \
  --run-id "$RUN_ID" \
  --artifact-dir "$ARTIFACT_DIR" \
  plan
```

Required handoff artifacts:

- `open-tofu-<run_id>.tfplan`
- `plan-<run_id>.json`
- `plan-<run_id>.summary.txt`
- `policy-<run_id>.jsonl`
- `drift-<run_id>.txt` when drift was evaluated
- a summary that includes approval status, profile, workspace, and unresolved risks

For prod plans with changes, `run-plan.sh` emits
`rollback-precheck-<run_id>.txt` before handoff.
