#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TARGET_OS="${1:?usage: package-opentofu-plugin.sh <goos> <goarch> [version]}"
TARGET_ARCH="${2:?usage: package-opentofu-plugin.sh <goos> <goarch> [version]}"
VERSION="${3:-$(git -C "$PLUGIN_ROOT" describe --tags --always --dirty)}"
SLUG="opentofu-codex-plugin-${VERSION}-${TARGET_OS}-${TARGET_ARCH}"
DIST_DIR="${PLUGIN_ROOT}/dist"
STAGE_DIR="$(mktemp -d)"
ARCHIVE="${DIST_DIR}/${SLUG}.tar.gz"

cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

GOCACHE="${GOCACHE:-${TMPDIR:-/tmp}/opentofu-go-cache}" \
GOMODCACHE="${GOMODCACHE:-${TMPDIR:-/tmp}/opentofu-go-mod-cache}" \
  "${SCRIPT_DIR}/build-opentofu-mcp.sh" "$TARGET_OS" "$TARGET_ARCH"

mkdir -p "${STAGE_DIR}/opentofu" "$DIST_DIR"
git -C "$PLUGIN_ROOT" archive HEAD | tar -x -C "${STAGE_DIR}/opentofu"
mkdir -p "${STAGE_DIR}/opentofu/bin"
cp "${PLUGIN_ROOT}/bin/opentofu-mcp-${TARGET_OS}-${TARGET_ARCH}" "${STAGE_DIR}/opentofu/bin/"
tar -czf "$ARCHIVE" -C "$STAGE_DIR" opentofu

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"
else
  shasum -a 256 "$ARCHIVE" > "${ARCHIVE}.sha256"
fi

echo "$ARCHIVE"

