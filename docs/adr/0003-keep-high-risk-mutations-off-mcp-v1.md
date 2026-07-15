# ADR 0003: Keep high-risk mutations off the first MCP interface

## Status

Accepted.

## Decision

The first MCP interface supports preflight, policy checks, normal planning,
bounded evidence reads, and saved-plan apply. Destroy, import, state mutation,
backend migration, and workspace mutation remain focused skill/script flows.

## Consequences

The model cannot smuggle arbitrary OpenTofu arguments through a generic command
tool. Additional mutation tools require their own typed plan contracts, safety
annotations, tests, and review rather than expansion of `opentofu_execute_plan`.

