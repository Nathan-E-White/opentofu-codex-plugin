# ADR 0002: Single-use immutable apply plans

## Status

Accepted.

## Decision

MCP apply consumes a saved plan record bound to the plan hash, stack
configuration hash, workspace, profile, backend hint, evidence paths, and a
15-minute expiry. Execution requires the exact returned confirmation token.
The consumed marker is created atomically before starting apply.

## Consequences

Configuration or plan drift invalidates execution. Failed and uncertain applies
cannot reuse the same authorization. OpenTofu still performs its own stale-state
checks when applying the saved plan.

