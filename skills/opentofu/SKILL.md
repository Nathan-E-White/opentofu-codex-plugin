---
name: opentofu
description: Route general OpenTofu and Terraform-compatible infrastructure requests to the correct lifecycle, state, workspace, policy, module, or GitOps workflow. Use for broad OpenTofu questions, multi-step infrastructure work, or requests whose operational seam is not yet clear.
---

# OpenTofu

## Core Rule

Use this as the general entrypoint for OpenTofu / Terraform-compatible workflow questions.
If the request is about:

- core lifecycle tasks, use `$opentofu-core`
- state inspection or mutation, use `$opentofu-state`
- workspaces, remote state backends, or lockfile consistency, use `$opentofu-workspaces`
- formatting and policy gates, use `$opentofu-policy`
- module sourcing and migration planning, use `$opentofu-modules`
- CI/GitOps approvals and plan artifacts, use `$opentofu-gitops`

## MCP-first operating model

When the bundled `opentofu` MCP server is available, prefer its typed tools for
the supported path:

| Intent | MCP tool | Safety behavior |
| --- | --- | --- |
| Context checks | `opentofu_preflight` | explicit absolute stack path and optional root confinement |
| Policy evidence | `opentofu_policy_check` | profile-bound checks with evidence under `.tofu-artifacts/mcp/` |
| Change planning | `opentofu_plan` | immutable plan record bound to configuration, workspace, profile, and plan hash |
| Apply | `opentofu_execute_plan` | exact confirmation, 15-minute expiry, drift rejection, single use |
| Evidence read | `opentofu_get_evidence` | bounded reads confined to the stack artifact directory |

The MCP mutation surface supports saved-plan apply only. Continue to use the
focused skills and guarded scripts for destroy, import, state mutation, backend
migration, and workspace mutation. Do not tunnel those operations through MCP
tool parameters.

## Decision routing table

| Intent | Indicator in request | Route |
| --- | --- | --- |
| Core lifecycle | `init`, `plan`, `validate`, `apply`, `destroy`, `refresh` | `$opentofu-core` |
| State operations | `state list`, `state show`, `state mv`, `state rm`, `output` | `$opentofu-state` |
| Workspace/backend | `workspace`, remote backends, `drift`, backend config, migrations | `$opentofu-workspaces` |
| Policy checks | `fmt`, `lint`, `tflint`, `tfsec`, `policy` | `$opentofu-policy` |
| Module changes | `module`, `module upgrade`, `providers lock`, source migration | `$opentofu-modules` |
| Plan/apply control | `plan-only`, `approve`, `artifact`, rollout gates | `$opentofu-gitops` |

## Safety defaults

Treat every destructive step as explicit request-bound:

- require explicit confirmation for `destroy`, `state rm`, and `import` unless the user already said yes.
- never run automatic apply flows with `-auto-approve` unless requested.
- keep workspace context explicit when multiple environments exist.
- in `OPENTOFU_MODE=enterprise` or `OPENTOFU_PROFILE=stg|prod`, require an approval token before destructive handoffs.
- Require the same deterministic unblock path everywhere: set OPENTOFU_APPROVAL_TOKEN (or --approval-token) and rerun the same command with unchanged context: `run_id`, `profile`, `workspace`, and `backend_hint`.

## Shared preflight

For planning, state operations, and policy pipelines:

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
"$PLUGIN_ROOT/scripts/preflight.sh" --path .
"$PLUGIN_ROOT/scripts/preflight.sh" --path . --check-only
```

When a mutating command is requested, set mutation mode and explicit workspace/backend context:

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
"$PLUGIN_ROOT/scripts/preflight.sh" --path . --mode mutating --workspace prod --backend-config backend.hcl
```

Example enterprise/stg/prod unblock pattern:

```bash
export OPENTOFU_MODE=enterprise
export OPENTOFU_PROFILE=stg
export OPENTOFU_APPROVAL_TOKEN="change-2026-07-06-01"
export OPENTOFU_RUN_ID="20260706T120000-001"

PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
"$PLUGIN_ROOT/scripts/run-plan.sh" --path . \
  --workspace stg \
  --backend-config backend-stg.hcl \
  --approval-token "$OPENTOFU_APPROVAL_TOKEN" \
  apply
```

## Advanced routing defaults

If a request mixes core and policy checks, run policy checks first, then route execution.

- `$opentofu-policy` for validation, tflint, and tfsec.
- `$opentofu-core` for `plan` + `apply` execution.
- `$opentofu-gitops` for non-interactive plan artifacts and approval gate patterns.

## Shared escalation and policy mode

- Run in enterprise mode by setting:
  `OPENTOFU_MODE=enterprise`.
- set `OPENTOFU_PROFILE=dev|stg|prod` so strictness and context checks are stable.
- include `OPENTOFU_RUN_ID` and reuse it across destructive handoff + artifact calls.
- Every handoff that can mutate state or infrastructure should include a deterministic `run_id`.
- For destructive handoffs (`apply`, `destroy`, `state rm`, `state mv`, `import`), require explicit user confirmation before forwarding.
- For MCP apply, use only the exact confirmation returned by `opentofu_plan`; never construct or reuse a token from another plan.
- For state handoffs, use `preflight` with explicit state-write and context parameters: `--state-command`, `--expected-workspace`, `--expected-backend` and match the current `profile/workspace/backend` exactly.
