#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
esac

BINARY="${PLUGIN_ROOT}/bin/opentofu-mcp-${OS}-${ARCH}"
if [[ ! -x "$BINARY" ]]; then
  echo "OpenTofu MCP binary is missing for ${OS}/${ARCH}: ${BINARY}" >&2
  echo "Build it before installing the plugin: ${PLUGIN_ROOT}/scripts/build-opentofu-mcp.sh" >&2
  exit 127
fi

export OPENTOFU_PLUGIN_ROOT="$PLUGIN_ROOT"
exec "$BINARY"
