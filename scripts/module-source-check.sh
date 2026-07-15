#!/usr/bin/env bash
set -euo pipefail

PATH_ARG="."
PROFILE="${OPENTOFU_PROFILE:-dev}"
MODE="readonly"
RUN_ID="${OPENTOFU_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$$}"
ARTIFACT_DIR="${OPENTOFU_MODULE_ARTIFACT_DIR:-.tofu-artifacts}"
CI_MODE="${OPENTOFU_CI:-0}"
EXCEPTION_FILE="${OPENTOFU_MODULE_EXCEPTION_FILE:-}"
CHECKSUM_FILE="${OPENTOFU_MODULE_CHECKSUM_FILE:-}"
DEPRECATED_SOURCE_FILE="${OPENTOFU_DEPRECATED_MODULE_SOURCE_FILE:-}"
DEPRECATED_SOURCES="${OPENTOFU_DEPRECATED_MODULE_SOURCES:-}"
TARGET_DIR=""
REPORT_PATH=""
FAILED=0
WARNED=0
MODULE_COUNT=0

print_usage() {
  cat <<'USAGE'
Usage: module-source-check.sh --path <dir> [options]

Checks OpenTofu module source hygiene and writes module-sources-<run_id>.txt.

Options:
  --profile <dev|stg|prod>             Environment profile
  --mode readonly|mutating             Operation mode
  --run-id <id>                        Stable run identifier
  --artifact-dir <dir>                 Evidence output directory
  --ci                                 Refuse to overwrite existing report
  --exception-file <path>              Non-empty exception file for deprecated sources
  --checksum-file <path>               Optional module source checksum expectation file
  --deprecated-source-file <path>      File with one deprecated source substring per line
USAGE
}

is_strict_context() {
  [[ "$PROFILE" == "stg" || "$PROFILE" == "prod" || "${OPENTOFU_MODE:-}" == "enterprise" || "$MODE" == "mutating" ]]
}

has_exception() {
  [[ -n "$EXCEPTION_FILE" && -s "$EXCEPTION_FILE" ]]
}

append_report() {
  printf '%s\n' "$*" >> "$REPORT_PATH"
}

mark_fail() {
  FAILED=1
  append_report "    result: fail"
  append_report "    remediation: $1"
}

mark_warn() {
  WARNED=1
  append_report "    result: warning"
  append_report "    remediation: $1"
}

mark_pass() {
  append_report "    result: pass"
}

is_local_source() {
  case "$1" in
    ./*|../*|/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_vcs_source() {
  case "$1" in
    git::*|*github.com/*|*gitlab.com/*|*bitbucket.org/*|*.git*|ssh://*|git@*) return 0 ;;
    *) return 1 ;;
  esac
}

module_ref() {
  local source="$1"
  local ref
  if [[ "$source" != *"ref="* ]]; then
    return 1
  fi
  ref="${source#*ref=}"
  ref="${ref%%&*}"
  ref="${ref%%\?*}"
  printf '%s' "$ref"
}

ref_is_branch_like() {
  case "$1" in
    main|master|develop|development|dev|staging|stage|prod|production|HEAD) return 0 ;;
    *) return 1 ;;
  esac
}

source_is_deprecated() {
  local source="$1"
  local pattern

  if [[ -n "$DEPRECATED_SOURCES" ]]; then
    local old_ifs="$IFS"
    IFS=,
    for pattern in $DEPRECATED_SOURCES; do
      IFS="$old_ifs"
      [[ -z "$pattern" ]] && continue
      if [[ "$source" == *"$pattern"* ]]; then
        return 0
      fi
      IFS=,
    done
    IFS="$old_ifs"
  fi

  if [[ -n "$DEPRECATED_SOURCE_FILE" && -f "$DEPRECATED_SOURCE_FILE" ]]; then
    while IFS= read -r pattern || [[ -n "$pattern" ]]; do
      [[ -z "$pattern" || "$pattern" == \#* ]] && continue
      if [[ "$source" == *"$pattern"* ]]; then
        return 0
      fi
    done < "$DEPRECATED_SOURCE_FILE"
  fi

  return 1
}

checksum_expected_for_source() {
  local source="$1"
  [[ -z "$CHECKSUM_FILE" ]] && return 0
  if [[ ! -f "$CHECKSUM_FILE" ]]; then
    mark_fail "checksum expectation file not found: $CHECKSUM_FILE"
    return 1
  fi
  if grep -F -- "$source" "$CHECKSUM_FILE" >/dev/null 2>&1; then
    return 0
  fi
  mark_fail "add module source to checksum expectation file: $source"
  return 1
}

scan_modules() {
  local file="$1"
  awk -v source_file="$file" '
    function quoted_value(line, value) {
      value = line
      sub(/^[^=]*=[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      return value
    }
    function module_name(line, value) {
      value = line
      sub(/^[[:space:]]*module[[:space:]]*"/, "", value)
      sub(/".*$/, "", value)
      return value
    }
    /^[[:space:]]*module[[:space:]]+"/ {
      in_module = 1
      name = module_name($0)
      source = ""
      version = ""
      start_line = FNR
    }
    in_module && /^[[:space:]]*source[[:space:]]*=/ {
      source = quoted_value($0)
    }
    in_module && /^[[:space:]]*version[[:space:]]*=/ {
      version = quoted_value($0)
    }
    in_module && /^[[:space:]]*}/ {
      if (source != "") {
        printf "%s\t%s\t%s\t%s\t%s\n", source_file, start_line, name, source, version
      }
      in_module = 0
    }
  ' "$file"
}

evaluate_module() {
  local file="$1"
  local line="$2"
  local name="$3"
  local source="$4"
  local version="$5"
  local module_dir
  local local_path
  local ref

  MODULE_COUNT=$((MODULE_COUNT + 1))
  append_report "  - module: ${name}"
  append_report "    file: ${file}:${line}"
  append_report "    source: ${source}"
  append_report "    version: ${version:-unset}"

  if is_local_source "$source"; then
    module_dir="$(cd "$(dirname "$file")" && pwd)"
    if [[ "$source" == /* ]]; then
      local_path="$source"
    else
      local_path="${module_dir}/${source}"
    fi
    if [[ -d "$local_path" ]]; then
      mark_pass
    else
      mark_fail "create local module path or correct source: $local_path"
    fi
  elif is_vcs_source "$source"; then
    if ! ref="$(module_ref "$source")"; then
      mark_fail "pin VCS module source with ?ref=<tag-or-commit>"
    elif ref_is_branch_like "$ref"; then
      mark_fail "replace branch-like ref '$ref' with an immutable tag or commit"
    else
      mark_pass
    fi
  else
    if [[ -z "$version" ]]; then
      if is_strict_context; then
        mark_fail "add explicit version for registry module source"
      else
        mark_warn "add explicit version before stg/prod or enterprise mutation"
      fi
    else
      mark_pass
    fi
  fi

  if source_is_deprecated "$source"; then
    if is_strict_context; then
      if has_exception; then
        append_report "    deprecated_source: exception"
        append_report "    exception_file: ${EXCEPTION_FILE}"
      else
        mark_fail "deprecated module source requires non-empty exception file before mutation"
      fi
    else
      mark_warn "deprecated source detected; prepare replacement or exception before mutation"
    fi
  fi

  checksum_expected_for_source "$source" || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path|-p)
      PATH_ARG="${2:?missing --path value}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:?missing --profile value}"
      shift 2
      ;;
    --mode)
      MODE="${2:?missing --mode value}"
      shift 2
      ;;
    --run-id)
      RUN_ID="${2:?missing --run-id value}"
      shift 2
      ;;
    --artifact-dir)
      ARTIFACT_DIR="${2:?missing --artifact-dir value}"
      shift 2
      ;;
    --ci)
      CI_MODE=1
      shift
      ;;
    --exception-file)
      EXCEPTION_FILE="${2:?missing --exception-file value}"
      shift 2
      ;;
    --checksum-file)
      CHECKSUM_FILE="${2:?missing --checksum-file value}"
      shift 2
      ;;
    --deprecated-source-file)
      DEPRECATED_SOURCE_FILE="${2:?missing --deprecated-source-file value}"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      print_usage
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "readonly" && "$MODE" != "mutating" ]]; then
  echo "error: --mode must be readonly or mutating" >&2
  exit 2
fi

if [[ "$CI_MODE" != "0" && "$CI_MODE" != "1" ]]; then
  echo "error: --ci/OPENTOFU_CI must resolve to 0 or 1" >&2
  exit 2
fi

case "$PROFILE" in
  dev|stg|prod) ;;
  *) echo "error: --profile must be dev, stg, or prod" >&2; exit 2 ;;
esac

if [[ ! -d "$PATH_ARG" ]]; then
  echo "error: path '$PATH_ARG' does not exist" >&2
  exit 1
fi

TARGET_DIR="$(cd "$PATH_ARG" && pwd)"
mkdir -p "$ARTIFACT_DIR"
REPORT_PATH="${ARTIFACT_DIR%/}/module-sources-${RUN_ID}.txt"
if [[ "$CI_MODE" == "1" && -e "$REPORT_PATH" ]]; then
  echo "module-source-check: CI mode refuses to overwrite existing artifact: $REPORT_PATH" >&2
  exit 1
fi

{
  echo "run_id: ${RUN_ID}"
  echo "command: module-source-check"
  echo "working_dir: ${TARGET_DIR}"
  echo "profile: ${PROFILE}"
  echo "mode: ${MODE}"
  echo "exception_file: ${EXCEPTION_FILE:-unset}"
  echo "checksum_file: ${CHECKSUM_FILE:-unset}"
  echo "deprecated_source_file: ${DEPRECATED_SOURCE_FILE:-unset}"
  echo "deprecated_sources: ${DEPRECATED_SOURCES:-unset}"
  echo "modules:"
} > "$REPORT_PATH"

while IFS= read -r -d '' tf_file; do
  while IFS=$'\t' read -r file line name source version; do
    [[ -z "${source:-}" ]] && continue
    evaluate_module "$file" "$line" "$name" "$source" "$version"
  done < <(scan_modules "$tf_file")
done < <(find "$TARGET_DIR" -type f \( -name '*.tf' -o -name '*.tf.json' \) -print0)

if [[ "$MODULE_COUNT" -eq 0 ]]; then
  append_report "  - none"
fi

if [[ "$FAILED" -ne 0 ]]; then
  append_report "status: failed"
  echo "module-source-check: failed; evidence=$REPORT_PATH" >&2
  exit 1
fi

if [[ "$WARNED" -ne 0 ]]; then
  append_report "status: warnings"
  echo "module-source-check: warnings; evidence=$REPORT_PATH"
  exit 0
fi

append_report "status: passed"
echo "module-source-check: passed; evidence=$REPORT_PATH"
