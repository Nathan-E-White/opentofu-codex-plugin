#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_OS="${1:-$(go env GOOS)}"
TARGET_ARCH="${2:-$(go env GOARCH)}"
OUTPUT_DIR="${PLUGIN_ROOT}/bin"
OUTPUT="${OUTPUT_DIR}/opentofu-mcp-${TARGET_OS}-${TARGET_ARCH}"

mkdir -p "$OUTPUT_DIR"
echo "building ${OUTPUT}"
(
  cd "$PLUGIN_ROOT"
  CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" \
    go build -trimpath -ldflags="-s -w" -o "$OUTPUT" ./cmd/opentofu-mcp
)
chmod 0755 "$OUTPUT"
echo "$OUTPUT"

