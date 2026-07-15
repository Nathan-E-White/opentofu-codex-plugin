---
name: opentofu-state
description: "Inspect and safely modify OpenTofu state through list, show, move, remove, output, refresh, backup, and recovery workflows. Use for state surgery, address migrations, stale-resource cleanup, drift reconciliation, or backend-aware state diagnostics."
---

# OpenTofu State Workflows

## What this skill owns

- reading and inspecting state
- safe state surgery with explicit confirmation
- output exports for downstream tooling
- refresh and drift-aware reconciliation prep

The bundled MCP server does not expose state mutation in its first release.
Use `opentofu_preflight` for shared context checks, then keep `state mv`,
`state rm`, sensitive `state show`, backups, and recovery on this skill's
explicit script/command path.

## State command patterns

- inspect state entries:

```bash
tofu state list
tofu state show <resource>
tofu output
```

- move resources between addresses:

```bash
$PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
cd <repo>
"$PLUGIN_ROOT/scripts/preflight.sh" --path . --check-only

tofu state mv <old.address> <new.address>
```

- remove stale resources:

```bash
tofu state rm <resource>
```

- refresh runtime state:

```bash
$PLUGIN_ROOT/scripts/run-plan.sh --path . refresh -target=<resource>
```

## Safety guidance

- confirm exact resource IDs and modules before `state mv` or `state rm`.
- Require the same deterministic unblock path everywhere: set OPENTOFU_APPROVAL_TOKEN (or --approval-token) and rerun the same command with unchanged context: `run_id`, `profile`, `workspace`, and `backend_hint`.
- use workdir-specific snapshots or backups before manual state changes.
- if drift is expected, pair with `$opentofu-workspaces` and `$opentofu-policy` before apply.

## State safety policy by profile

| Profile | Safe by default | Unsafe (requires confirmation + gating) |
| --- | --- | --- |
| dev | `state list`, `state show` | `state mv`, `state rm` |
| stg | `state list` | `state mv`, `state rm`, `state show` |
| prod | `state list` | `state mv`, `state rm`, `state show` |

In dev, `state show` is read-oriented; in stg/prod it is treated as sensitive and must follow the same gated approval flow.

Use these command patterns with explicit workspace/backend context checks:

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
OPENTOFU_APPROVAL_TOKEN="change-2026-07-06-01"

# Dev profile example for state mutation with explicit workspace/backend context
$PLUGIN_ROOT/scripts/preflight.sh --path . \
  --mode mutating \
  --state-command "state mv" \
  --workspace dev \
  --backend-config backend-dev.hcl \
  --expected-workspace dev \
  --expected-backend backend-dev.hcl \
  --profile dev \
  --check-only

ALLOW_STATE_WRITE=1 \
$PLUGIN_ROOT/scripts/run-plan.sh --path . \
  --workspace dev \
  --backend-config backend-dev.hcl \
  --expected-workspace dev \
  --expected-backend backend-dev.hcl \
  state mv module.old module.new

# Stg/prod profile: treat state show like a gated action and require token-based unblock
$PLUGIN_ROOT/scripts/preflight.sh --path . \
  --mode mutating \
  --state-command "state show" \
  --workspace prod \
  --backend-config backend-prod.hcl \
  --expected-workspace prod \
  --expected-backend backend-prod.hcl \
  --profile prod \
  --check-only

ALLOW_STATE_WRITE=1 \
OPENTOFU_PROFILE=prod \
OPENTOFU_APPROVAL_TOKEN="$OPENTOFU_APPROVAL_TOKEN" \
$PLUGIN_ROOT/scripts/run-plan.sh --path . \
  --workspace prod \
  --backend-config backend-prod.hcl \
  --expected-workspace prod \
  --expected-backend backend-prod.hcl \
  state show module.old

# Read-oriented profile example (with explicit confirmation)
tofu state show module.old
```
