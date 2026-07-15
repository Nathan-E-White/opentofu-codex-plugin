# ADR 0001: Local STDIO with explicit stack context

## Status

Accepted.

## Decision

Bundle a local Go STDIO MCP server. Every tool receives an absolute stack path
and explicit environment profile. `OPENTOFU_MCP_ROOTS` optionally confines
canonical stack paths after symlink resolution.

## Consequences

No remote MCP service, OAuth layer, or `.app.json` connector is required for the
local Codex workflow. An unconstrained installation remains usable but reports
that it is accepting explicit paths without a configured root allowlist.

