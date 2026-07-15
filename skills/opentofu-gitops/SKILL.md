---
name: opentofu-gitops
description: "Build non-interactive OpenTofu CI and GitOps workflows with plan-first execution, immutable artifacts, policy evidence, approval checkpoints, drift review, and rollback checks. Use for automated pipelines, change handoffs, or controlled apply promotion."
---

# OpenTofu GitOps

## What this skill owns

- non-interactive planning for CI
- plan artifact capture and review output
- approval-gate patterns for apply
- rollback and destroy-plan safety checks

## CI flow templates

For interactive Codex workflows, use `opentofu_plan` to create an immutable
15-minute apply authorization. Preserve its `plan_id`, summary, plan JSON, plan
file, profile, workspace, and configuration hash as one review unit. Apply only
through `opentofu_execute_plan` with the exact returned confirmation after the
user approves that review unit.

The MCP plan registry is local to the stack under
`.tofu-artifacts/mcp/plans/`. CI systems may continue using the script contract
below when MCP is not the executor.

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
RUN_ID="ci-${BUILD_ID:?}"
ARTIFACT_DIR="artifacts/opentofu/${RUN_ID}"

"$PLUGIN_ROOT/scripts/preflight.sh" --path . --profile dev --check-only --run-id "$RUN_ID" --artifact-dir "$ARTIFACT_DIR"
"$PLUGIN_ROOT/scripts/policy-gates.sh" --path . --profile dev --ci --run-id "$RUN_ID" --artifact-dir "$ARTIFACT_DIR/policy"
"$PLUGIN_ROOT/scripts/run-plan.sh" --path . --ci --run-id "$RUN_ID" --artifact-dir "$ARTIFACT_DIR" plan
```

## Apply with explicit approval gate

```bash
# review policy checks first
"$PLUGIN_ROOT/scripts/policy-gates.sh" --path . --profile stg --run-id "$RUN_ID" --artifact-dir "$ARTIFACT_DIR/policy"

# apply only after approval references the reviewed plan artifact
"$PLUGIN_ROOT/scripts/run-plan.sh" --path . --run-id "$RUN_ID" --artifact-dir "$ARTIFACT_DIR" apply "$ARTIFACT_DIR/open-tofu-${RUN_ID}.tfplan"
```

## Artifact contract

Every GitOps handoff must preserve these artifacts for the same `run_id`:

- `plan`: `open-tofu-<run_id>.tfplan`, `plan-<run_id>.json`, and `plan-<run_id>.summary.txt`
- `policy`: `policy-<run_id>.jsonl` plus per-check evidence logs
- `drift`: `drift-<run_id>.txt` from drift-only review when drift was evaluated
- `summary`: human-readable handoff summary containing run id, profile, workspace, approval status, artifact paths, and unresolved risks

In CI mode, scripts must fail instead of overwriting existing artifacts. Treat
missing required outputs as a failed build, not a warning.

## Rollback preparedness

```bash
$PLUGIN_ROOT/scripts/run-plan.sh --path . plan -destroy -out=artifacts/rollback.tfplan
```

For `prod`, any plan with changes must emit a rollback pre-check artifact before
handoff. The pre-check should identify current state markers, backup path,
previous plan lookup status, and the reviewed plan artifact path.

## Notes

- keep plan output and manifest artifacts in versioned build directories.
- require human review for non-empty plan exit states before apply.
- use `$opentofu-policy` to enforce guardrails before merge.
- never apply from a plan artifact whose policy/drift/summary evidence was not captured under the same run id.
- never retry a consumed MCP plan; create and review a fresh plan after any failed or uncertain apply.
