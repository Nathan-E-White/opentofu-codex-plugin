# OpenTofu Plugin Context

## Stack Context

The canonical absolute stack path, environment profile, workspace, backend
hint, configuration hash, and optional configured root policy used by one MCP
operation.

## Evidence Run

A run-scoped directory under `.tofu-artifacts/mcp/runs/` containing bounded
preflight, policy, plan, apply, and summary evidence.

## Immutable Apply Plan

A saved OpenTofu plan plus a record binding its hash to the stack configuration
hash, profile, workspace, backend hint, evidence run, creation time, and expiry.

## Apply Confirmation

The exact `CONFIRM apply <workspace> <plan-id>` token returned for one immutable
apply plan. It is authorization context, not a reusable secret or generic
approval token.

## Consumed Plan

An immutable apply plan claimed atomically before execution. It remains consumed
after success, failure, timeout, or uncertain remote outcome.

## Script-only Mutation

A destructive or context-changing operation deliberately excluded from the MCP
interface: destroy, import, state mutation, backend migration, or workspace
mutation. Focused skills and guarded scripts own these operations.

