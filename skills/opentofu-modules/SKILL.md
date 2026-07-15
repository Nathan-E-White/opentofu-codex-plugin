---
name: opentofu-modules
description: "Inspect and improve OpenTofu module source, version, provider-lock, dependency-graph, upgrade, and import-migration hygiene. Use when changing modules, reviewing supply-chain provenance, upgrading providers, or planning module-aware state moves."
---

# OpenTofu Modules

## What this skill owns

- module source and version hygiene
- dependency graph inspection and cleanup
- module-aware migration and import planning

`opentofu_preflight` and `opentofu_plan` reuse the plugin's module-source
checks. Module upgrades, imports, source exceptions, and provider-lock changes
remain explicit skill/script workflows rather than generic MCP arguments.

## Module hygiene commands

```bash
PLUGIN_ROOT="${CODEX_HOME:-$HOME/.codex}/plugins/opentofu"

$PLUGIN_ROOT/scripts/preflight.sh --path . --profile dev --check-only

tofu get -update

tofu graph > module-graph.dot
tofu providers
```

## Upgrade and deprecation checks

- review module source locations before version jumps:

```bash
grep -R "module \"" -n .
```

- validate dependency lock and provider integrity:

```bash
tofu providers lock -platform linux_amd64 -platform darwin_arm64
```

- import-oriented migration planning:

```bash
$PLUGIN_ROOT/scripts/run-plan.sh --path . plan -refresh-only=true
$PLUGIN_ROOT/scripts/run-plan.sh --path . plan -replace='module.example.aws_x.y[0]'
```

## Module source sanity

Run module source checks before import, upgrade, apply, or destroy:

```bash
$PLUGIN_ROOT/scripts/preflight.sh \
  --path . \
  --profile stg \
  --check-only
```

The module source check records local paths, registry sources, VCS sources,
deprecated matches, and checksum expectation results. Treat these as hard
failures before mutation in stg/prod or enterprise mode:

- local module path does not exist
- VCS module source is not pinned with `?ref=`
- VCS `ref` points at a branch-like moving target such as `main`, `master`, or `develop`
- registry module has no explicit `version`
- module source matches a deprecated-source pattern and no exception file is present
- checksum expectation file is provided but does not cover the module source

## Graph and version hygiene

- Run `tofu graph` and review unexpected provider/module edges before import migration.
- Run `tofu providers` and confirm provider sources are expected for the target environment.
- Keep module versions pinned for stg/prod and enterprise mutation workflows.
- Use plan-only checks first for import migrations; do not combine import planning with `apply`.

## Deprecated source exception flow

Deprecated sources are blocked before mutation unless an exception file is
provided through `OPENTOFU_MODULE_EXCEPTION_FILE` or the script option that
accepts a module exception file. The exception must be non-empty and identify
the deprecated source, approver, expiry, and replacement path.

## Guidance

- pin module versions where governance requires reproducibility.
- avoid automatic `-upgrade` in production workflows unless requested.
- capture module-source reports in handoffs for import and module upgrade work.
