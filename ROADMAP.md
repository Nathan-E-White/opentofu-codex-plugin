# OpenTofu Plugin Enterprise Roadmap (Actionable Checklist)

## MCP app expansion (v0.2.0)

| Tag | Owner | Area | Task | Status |
| --- | --- | --- | --- | --- |
| mcp-01 | Platform | Packaging | Add a bundled Go STDIO MCP server and plugin `.mcp.json` wiring. | [x] |
| mcp-01 | Security | Path policy | Add explicit absolute stack context with optional canonical root confinement. | [x] |
| mcp-01 | Security | Apply protocol | Bind saved plan and configuration hashes to a 15-minute, exact-confirmed, single-use plan record. | [x] |
| mcp-01 | Platform | Tool interface | Add typed preflight, policy, plan, execute-plan, and bounded evidence tools with accurate annotations. | [x] |
| mcp-01 | Docs | Skills | Update all focused skills, prompts, glossary, ADRs, and README for the MCP/script seam. | [x] |
| mcp-01 | Quality | Validation | Run Go tests, MCP protocol smoke tests, shell syntax, and plugin validation. | [x] |
| mcp-01 | Release | Distribution | Publish the standalone `opentofu-codex-plugin` repository and verify local Codex installation. | [ ] |

## Goal
Deliver enterprise-grade behavior for existing OpenTofu skills without changing the current feature surface.

## How to use this file
- Update task status in place with `[ ]` (not started), `[x]` (done), or `[~]` (blocked/partial).
- Use `Tag` as either `sprint-##` or `crash-##`.
- Keep one checkbox per row and one owner per row.

## Global checklist

### Foundation (shared across skills)

| Tag | Owner | Skill | Task | Status |
| --- | --- | --- | --- | --- |
| sprint-01 | Platform | Foundation | Create `plugins/opentofu/scripts/opentofu-runner.sh` with command allowlist, timeout defaults, JSON run envelope, redaction filter, and safe logging format. | [x] |
| sprint-01 | Platform | Foundation | Update `plugins/opentofu/scripts/preflight.sh` to enforce workspace/backend safety checks before every non-readonly operation. | [x] |
| sprint-01 | Security | Foundation | Update `plugins/opentofu/scripts/policy-gates.sh` to require `--profile=<dev\|stg\|prod>`. | [x] |
| sprint-01 | Platform | Foundation | Update `plugins/opentofu/agents/openai.yaml` to surface `OPENTOFU_MODE=enterprise` and mutation approval policy. | [x] |
| sprint-01 | Platform | Foundation | Update `plugins/opentofu/SKILL.md` with shared escalation/policy language. | [x] |
| sprint-01 | Platform | Foundation | Update `plugins/opentofu/.codex-plugin/plugin.json` with version/capability metadata for enterprise mode. | [x] |
| crash-01 | Platform | Foundation | Ensure `make validate-plugin PLUGIN=plugins/opentofu` succeeds after each task batch. | [x] |

### Routing skill (`opentofu`)

| Tag | Owner | Skill | Task | Status |
| --- | --- | --- | --- | --- |
| sprint-01 | Docs | `opentofu` | In `plugins/opentofu/skills/opentofu/SKILL.md`, add decision table routing to child skills by intent. | [x] |
| sprint-01 | Docs | `opentofu` | Map `state` → `opentofu-state`; `module` → `opentofu-modules`; `policy` → `opentofu-policy`; `workspace` → `opentofu-workspaces`; `plan/apply` control → `opentofu-gitops`. | [x] |
| sprint-01 | Docs | `opentofu` | Update `plugins/opentofu/skills/opentofu/agents/openai.yaml` to emit `run_id` and request explicit confirmation for destructive handoff. | [x] |

### `opentofu-core`

| Tag | Owner | Skill | Task | Status |
| --- | --- | --- | --- | --- |
| sprint-01 | SRE | `opentofu-core` | In `plugins/opentofu/skills/opentofu-core/agents/openai.yaml`, enforce `tofu fmt` and `tofu validate` before `apply`. | [x] |
| sprint-01 | SRE | `opentofu-core` | Add `--target` / force flags warning text in `plugins/opentofu/skills/opentofu-core/SKILL.md`. | [x] |
| sprint-01 | SRE | `opentofu-core` | Update `plugins/opentofu/scripts/run-plan.sh` to emit deterministic plan JSON + human summary + lockfile/state metadata. | [x] |
| crash-02 | Security | `opentofu-core` | Block `apply` in enterprise mode without approval token and document required escalation path. | [x] |

Completion evidence:
- `plugins/opentofu/scripts/run-plan.sh` (`require_enterprise_apply_approval`) returns blocked output when `OPENTOFU_MODE=enterprise` and `OPENTOFU_APPROVAL_TOKEN` is missing.
- `plugins/opentofu/scripts/run-plan.sh` now gates enterprise `apply` with deterministic context logging: `run_id`, `profile`, `workspace`, `backend_hint`, and path.
- `plugins/opentofu/skills/opentofu-core/agents/openai.yaml` documents the same deterministic rerun path and token workflow.
- `plugins/opentofu/skills/opentofu/agents/openai.yaml` includes the same enterprise/state rerun unblock semantics.

### `opentofu-state`

| Tag | Owner | Skill | Task | Status |
| --- | --- | --- | --- | --- |
| sprint-02 | SRE | `opentofu-state` | Add mutating confirmation requirements for `state rm`, `state mv`, and `state show` in `agents/openai.yaml`. | [x] |
| sprint-02 | SRE | `opentofu-state` | Define safe vs unsafe state operations by environment profile in `plugins/opentofu/skills/opentofu-state/SKILL.md`. | [x] |
| sprint-02 | SRE | `opentofu-state` | Add `ALLOW_STATE_WRITE` + expected workspace/backend checks to `plugins/opentofu/scripts/preflight.sh`. | [x] |
| sprint-02 | SRE | `opentofu-state` | Capture before/after state artifacts for mutation workflows. | [x] |

Completion evidence:
- `plugins/opentofu/skills/opentofu-state/agents/openai.yaml` and `plugins/opentofu/skills/opentofu-state/SKILL.md` explicitly define `state rm` and `state mv` as mutating and `state show` as sensitive in stg/prod.
- `plugins/opentofu/scripts/preflight.sh` adds `ALLOW_STATE_WRITE`, `--expected-workspace`, and `--expected-backend` enforcement for mutating state commands.
- `plugins/opentofu/scripts/run-plan.sh` requires approval token for `state rm`, `state mv`, and `state show` in stg/prod or enterprise mode and captures deterministic before/after snapshots for those operations.
- Artifact format added by `capture_state_artifacts()` writes `phase`, `operation`, workspace/backend context, profile, timestamp, and state file metadata to `.tofu-artifacts/state-<run_id>-<op>-before/after.txt`.

### `opentofu-workspaces`

| Tag | Owner | Skill | Task | Status |
| --- | --- | --- | --- | --- |
| sprint-03 | Platform | `opentofu-workspaces` | In `plugins/opentofu/skills/opentofu-workspaces/agents/openai.yaml`, enforce explicit workspace arguments and reject ambiguous workspace commands. | [x] |
| sprint-03 | Platform | `opentofu-workspaces` | Add lockfile/workspace hygiene checklist and runbook in `plugins/opentofu/skills/opentofu-workspaces/SKILL.md`. | [x] |
| sprint-03 | Security | `opentofu-workspaces` | Extend `plugins/opentofu/scripts/drift-check.sh` with backend URI + lockfile hash + workspace metadata checks. | [x] |
| crash-03 | SRE | `opentofu-workspaces` | Record backend migration source/target metadata as run artifacts. | [x] |

Completion evidence:

- [x] `plugins/opentofu/skills/opentofu-workspaces/agents/openai.yaml` includes explicit ambiguous-command rejection language for workspace operations and migration-only confirmation context.
- [x] `plugins/opentofu/skills/opentofu-workspaces/SKILL.md` includes workspace + lockfile hygiene checklist, migration runbook, and safe migration matrix.
- [x] `plugins/opentofu/scripts/drift-check.sh` accepts `--run-id`, `--artifact-dir`, `--expected-workspace`, `--backend-uri`, `--expected-backend-uri`, `--expected-lockfile-hash`, `--backend-source-uri`, and `--backend-target-uri` with deterministic `drift-<run_id>.txt` artifacts.
- [x] `plugins/opentofu/scripts/run-plan.sh` requires `--backend-source-uri` + `--backend-target-uri` when `-migrate-state` is used and writes `.tofu-artifacts/backend-migration-<run_id>-[before|after].txt`.

Repro example:

```bash
./scripts/run-plan.sh --path . --workspace prod --backend-config backend-prod.hcl \
  --backend-source-uri s3://state-old/prod.tfstate \
  --backend-target-uri s3://state-new/prod.tfstate \
  init -migrate-state
```

### `opentofu-policy`

| Tag | Owner | Skill | Task | Status |
| --- | --- | --- | --- | --- |
| sprint-03 | Compliance | `opentofu-policy` | Require policy chain completion before `plan/apply` in stg/prod in `plugins/opentofu/skills/opentofu-policy/agents/openai.yaml`. | [x] |
| sprint-03 | Compliance | `opentofu-policy` | Define mandatory/optional checks and exception process in `plugins/opentofu/skills/opentofu-policy/SKILL.md`. | [x] |
| sprint-04 | Security | `opentofu-policy` | Update `plugins/opentofu/scripts/policy-gates.sh` output schema to `{check,status,message,evidence_path}`. | [x] |
| sprint-04 | Security | `opentofu-policy` | Add optional `tflint` and `tfsec` execution with skip controls in dev profile. | [x] |
| crash-04 | Security | `opentofu-policy` | Hard-stop non-compliant runs with actionable remediation and fail reason. | [x] |

### `opentofu-modules`

| Tag | Owner | Skill | Task | Status |
| --- | --- | --- | --- | --- |
| sprint-04 | Platform | `opentofu-modules` | Add pre-import/import migration verification + deprecation risk flags in `plugins/opentofu/skills/opentofu-modules/agents/openai.yaml`. | [x] |
| sprint-04 | Platform | `opentofu-modules` | Add module graph sanity + version hygiene instructions in `plugins/opentofu/skills/opentofu-modules/SKILL.md`. | [x] |
| sprint-04 | Security | `opentofu-modules` | Add module source sanity checks in `run-plan.sh`/`preflight.sh` (local path, VCS tag, checksum expectations). | [x] |
| crash-04 | SRE | `opentofu-modules` | Add block-or-exception flow for deprecated module sources before mutation. | [x] |

### `opentofu-gitops`

| Tag | Owner | Skill | Task | Status |
| --- | --- | --- | --- | --- |
| sprint-05 | SRE | `opentofu-gitops` | Add plan-only-first workflow + explicit approval checkpoint in `plugins/opentofu/skills/opentofu-gitops/agents/openai.yaml`. | [x] |
| sprint-05 | SRE | `opentofu-gitops` | Define artifact contract (`plan`, `policy`, `drift`, `summary`) in `plugins/opentofu/skills/opentofu-gitops/SKILL.md`. | [x] |
| sprint-05 | Platform | `opentofu-gitops` | Add CI mode to `run-plan.sh` and `policy-gates.sh` for immutable artifact writes and required-output checks. | [x] |
| crash-05 | Platform | `opentofu-gitops` | Add rollback pre-check output for every planned production change. | [x] |

### Release, CI, and adoption

| Tag | Owner | Skill | Task | Status |
| --- | --- | --- | --- | --- |
| sprint-05 | Platform | Repository | Keep `scripts/run-validator.sh` as canonical local validation entrypoint (no behavior changes). | [x] |
| sprint-05 | Platform | Repository | Add CI-friendly enterprise mode to `Makefile` `validate-plugin` target. | [x] |
| sprint-05 | Docs | Repository | Add `plugins/opentofu/README.md` with enterprise example flows for each skill family. | [x] |
| crash-05 | Docs | Repository | Keep this roadmap continuously updated with per-task status for handoff visibility. | [x] |

### Definition of done
- [x] All `sprint-*` tasks in sections above are checked `[x]`.
- [x] All `crash-*` risk-mitigation tasks are checked `[x]` or explicitly deferred with reason.
- [x] At least one end-to-end enterprise path is demonstrated for each skill family:
  - core
  - state
  - workspaces
  - policy
  - modules
  - gitops
