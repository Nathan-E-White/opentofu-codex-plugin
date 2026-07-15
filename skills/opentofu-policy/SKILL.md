---
name: opentofu-policy
description: "Run OpenTofu formatting, validation, lint, security, policy, exception, and compliance gates with evidence capture. Use before plan or apply handoff, especially for staging, production, CI, tflint, or tfsec workflows."
---

# OpenTofu Policy and Quality Gates

## What this skill owns

- pre-deploy quality gates for OpenTofu plans
- deterministic formatting checks
- optional static analysis via tflint and tfsec when installed

## Recommended policy flow

When MCP is available, call `opentofu_policy_check` with an absolute
`stack_path`, explicit `profile`, and optional workspace. Its returned artifact
directory is part of the handoff contract. The tool writes evidence and may run
`tofu init`, so it is not annotated read-only even though it does not mutate
infrastructure.

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"
"$PLUGIN_ROOT/scripts/policy-gates.sh" --path . --profile dev
```

## Strict mode (required external tools)

```bash
$PLUGIN_ROOT/scripts/policy-gates.sh --path . --profile stg --require-external
```

## Policy chain requirements

- `dev`: `tofu fmt -check -recursive`, `tofu init -input=false`, and `tofu validate` are mandatory. `tflint` and `tfsec` may be skipped with `--skip-tflint` or `--skip-tfsec`; skipped checks are still recorded in JSONL evidence.
- `stg` and `prod`: the full policy chain must complete before any `plan` or `apply` handoff. `tflint` and `tfsec` are required when present or when `--require-external` is used, and missing/failed required checks block the run unless an exception file is supplied.
- Every run must preserve the policy JSONL evidence path in the handoff. For stg/prod, include `run_id`, profile, workspace, and exception file path when an exception is used.

## What each gate covers

- `tofu fmt -check -recursive` for style and drift-safe diffs.
- `tofu init -input=false` for backend/provider initialization readiness.
- `tofu validate` for configuration correctness.
- `tflint` when installed.
- `tfsec` when installed.

## Exception process

Use exceptions sparingly and only for known, time-bound non-compliance.

```bash
$PLUGIN_ROOT/scripts/policy-gates.sh \
  --path . \
  --profile prod \
  --exception-file approvals/policy-exception.yaml
```

The exception file must exist and be non-empty. It should include request id,
approver, affected profile, skipped or failed checks, reason, expiry date, and
follow-up owner. An exception can downgrade a required external-tool miss or
failure to an `exception` evidence record, but it does not bypass `tofu fmt`,
`tofu init`, or `tofu validate`.

## Notes

- if `tflint`/`tfsec` is missing, non-strict mode continues with tofu checks and warns.
- strict mode (`--require-external`) fails fast when optional checks are unavailable.
- stg/prod handoff without policy JSONL evidence is incomplete; do not proceed to mutation.
