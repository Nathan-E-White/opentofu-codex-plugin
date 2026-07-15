#!/usr/bin/env bash
set -euo pipefail

TOFU_BIN="${TOFU_BIN:-tofu}"
PATH_ARG="."
WORKSPACE=""
REQUIRE_EXTERNAL=0
PROFILE=""
RUN_ID="${OPENTOFU_POLICY_RUN_ID:-${OPENTOFU_RUN_ID:-}}"
RUN_ID_WAS_SET=0
ARTIFACT_DIR="${OPENTOFU_POLICY_ARTIFACT_DIR:-${OPENTOFU_ARTIFACT_DIR:-.tofu-artifacts}}"
ARTIFACT_DIR_WAS_SET=0
CI_MODE="${OPENTOFU_CI:-0}"
SKIP_TFLINT=0
SKIP_TFSEC=0
EXCEPTION_FILE="${OPENTOFU_POLICY_EXCEPTION_FILE:-}"
POLICY_JSONL=""
TOFU_DIR=""

if [[ -n "$RUN_ID" ]]; then
  RUN_ID_WAS_SET=1
fi
if [[ -n "${OPENTOFU_POLICY_ARTIFACT_DIR:-}${OPENTOFU_ARTIFACT_DIR:-}" ]]; then
  ARTIFACT_DIR_WAS_SET=1
fi

print_usage() {
  cat <<'USAGE'
Usage: policy-gates.sh --path <dir> --profile <dev|stg|prod> [options]

Runs non-destructive policy gates for OpenTofu runs and emits JSONL records:
{"check","status","message","evidence_path"}

Options:
  --path, -p <dir>          OpenTofu working directory
  --profile <dev|stg|prod> Policy profile
  --workspace, -w <name>    Workspace to select before checks
  --run-id <id>             Stable run identifier
  --artifact-dir <dir>      Directory for policy JSONL and per-check logs
  --ci                      Require explicit run id/artifact dir and immutable artifacts
  --require-external        Require tflint and tfsec even in dev
  --skip-tflint             Record tflint as skipped in dev
  --skip-tfsec              Record tfsec as skipped in dev
  --exception-file <path>   Non-empty exception file for stg/prod external-tool misses/failures
USAGE
}

json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r/\\r/g' -e 's/\n/\\n/g'
}

safe_slug() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

has_exception() {
  [[ -n "$EXCEPTION_FILE" && -s "$EXCEPTION_FILE" ]]
}

required_external_tools() {
  [[ "$PROFILE" == "stg" || "$PROFILE" == "prod" || "$REQUIRE_EXTERNAL" -eq 1 ]]
}

evidence_path_for() {
  local check="$1"
  printf '%s/%s-%s.log' "${ARTIFACT_DIR%/}" "$(safe_slug "$check")" "$RUN_ID"
}

emit_record() {
  local check="$1"
  local status="$2"
  local message="$3"
  local evidence_path="$4"
  local record

  record="{\"check\":\"$(json_escape "$check")\",\"status\":\"$(json_escape "$status")\",\"message\":\"$(json_escape "$message")\",\"evidence_path\":\"$(json_escape "$evidence_path")\"}"
  printf '%s\n' "$record"
  if [[ -n "$POLICY_JSONL" ]]; then
    printf '%s\n' "$record" >> "$POLICY_JSONL"
  fi
}

ensure_can_write_artifact() {
  local path="$1"
  if [[ "$CI_MODE" == "1" && -e "$path" ]]; then
    emit_record "artifact_immutability" "failed" "CI mode refuses to overwrite existing artifact: $path" "$path"
    exit 1
  fi
}

fail_check() {
  local check="$1"
  local message="$2"
  local evidence_path="$3"
  emit_record "$check" "failed" "$message" "$evidence_path"
  exit 1
}

run_required_check() {
  local check="$1"
  local success_message="$2"
  local failure_message="$3"
  shift 3
  local evidence_path

  evidence_path="$(evidence_path_for "$check")"
  ensure_can_write_artifact "$evidence_path"

  if "$@" > "$evidence_path" 2>&1; then
    emit_record "$check" "passed" "$success_message" "$evidence_path"
    return 0
  fi

  fail_check "$check" "$failure_message; review evidence and rerun after remediation" "$evidence_path"
}

run_external_tool() {
  local check="$1"
  local binary="$2"
  shift 2
  local evidence_path

  evidence_path="$(evidence_path_for "$check")"

  if [[ "$binary" == "tflint" && "$SKIP_TFLINT" -eq 1 ]]; then
    handle_external_skip "$check" "$evidence_path" "skip requested with --skip-tflint"
    return 0
  fi
  if [[ "$binary" == "tfsec" && "$SKIP_TFSEC" -eq 1 ]]; then
    handle_external_skip "$check" "$evidence_path" "skip requested with --skip-tfsec"
    return 0
  fi

  if ! command -v "$binary" >/dev/null 2>&1; then
    handle_external_skip "$check" "$evidence_path" "$binary is not installed or not on PATH"
    return 0
  fi

  ensure_can_write_artifact "$evidence_path"
  if "$binary" "$@" > "$evidence_path" 2>&1; then
    emit_record "$check" "passed" "$binary completed" "$evidence_path"
    return 0
  fi

  if required_external_tools && has_exception; then
    emit_record "$check" "exception" "$binary failed; exception file accepted: $EXCEPTION_FILE" "$evidence_path"
    return 0
  fi

  fail_check "$check" "$binary failed; remediate findings or provide --exception-file for stg/prod exception flow" "$evidence_path"
}

handle_external_skip() {
  local check="$1"
  local evidence_path="$2"
  local reason="$3"

  ensure_can_write_artifact "$evidence_path"
  printf 'check: %s\nstatus: skipped\nreason: %s\nprofile: %s\nrun_id: %s\n' "$check" "$reason" "$PROFILE" "$RUN_ID" > "$evidence_path"

  if required_external_tools; then
    if has_exception; then
      emit_record "$check" "exception" "$reason; exception file accepted: $EXCEPTION_FILE" "$evidence_path"
      return 0
    fi
    fail_check "$check" "$reason; required for profile=$PROFILE. Install tool, remove skip, or provide --exception-file" "$evidence_path"
  fi

  emit_record "$check" "skipped" "$reason" "$evidence_path"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path|-p)
      PATH_ARG="${2:?missing --path value}"
      shift 2
      ;;
    --workspace|-w)
      WORKSPACE="${2:?missing --workspace value}"
      shift 2
      ;;
    --run-id)
      RUN_ID="${2:?missing --run-id value}"
      RUN_ID_WAS_SET=1
      shift 2
      ;;
    --artifact-dir)
      ARTIFACT_DIR="${2:?missing --artifact-dir value}"
      ARTIFACT_DIR_WAS_SET=1
      shift 2
      ;;
    --ci)
      CI_MODE=1
      shift
      ;;
    --require-external)
      REQUIRE_EXTERNAL=1
      shift
      ;;
    --skip-tflint)
      SKIP_TFLINT=1
      shift
      ;;
    --skip-tfsec)
      SKIP_TFSEC=1
      shift
      ;;
    --exception-file)
      EXCEPTION_FILE="${2:?missing --exception-file value}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:?missing --profile value}"
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

if [[ "$CI_MODE" != "0" && "$CI_MODE" != "1" ]]; then
  echo "error: --ci/OPENTOFU_CI must resolve to 0 or 1" >&2
  exit 2
fi

if [[ "$CI_MODE" == "1" ]]; then
  if [[ "$RUN_ID_WAS_SET" -ne 1 ]]; then
    echo "error: --ci requires --run-id or OPENTOFU_POLICY_RUN_ID/OPENTOFU_RUN_ID" >&2
    exit 2
  fi
  if [[ "$ARTIFACT_DIR_WAS_SET" -ne 1 ]]; then
    echo "error: --ci requires --artifact-dir or OPENTOFU_POLICY_ARTIFACT_DIR/OPENTOFU_ARTIFACT_DIR" >&2
    exit 2
  fi
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
fi

mkdir -p "$ARTIFACT_DIR"
POLICY_JSONL="${ARTIFACT_DIR%/}/policy-${RUN_ID}.jsonl"
ensure_can_write_artifact "$POLICY_JSONL"
: > "$POLICY_JSONL"

if [[ ! -d "$PATH_ARG" ]]; then
  fail_check "path" "path '$PATH_ARG' does not exist" "$POLICY_JSONL"
fi

TOFU_DIR="$(cd "$PATH_ARG" && pwd)"
emit_record "path" "passed" "policy path resolved to $TOFU_DIR" "$POLICY_JSONL"

if [[ -z "$PROFILE" ]]; then
  fail_check "profile" "--profile is required and must be dev, stg, or prod" "$POLICY_JSONL"
fi

case "$PROFILE" in
  dev|stg|prod)
    emit_record "profile" "passed" "profile=$PROFILE" "$POLICY_JSONL"
    ;;
  *)
    fail_check "profile" "--profile must be dev, stg, or prod; got '$PROFILE'" "$POLICY_JSONL"
    ;;
esac

if [[ -n "$EXCEPTION_FILE" && ! -s "$EXCEPTION_FILE" ]]; then
  fail_check "exception_file" "exception file is missing or empty: $EXCEPTION_FILE" "$POLICY_JSONL"
fi
if [[ -n "$EXCEPTION_FILE" ]]; then
  emit_record "exception_file" "passed" "exception file accepted for external-tool policy exceptions" "$EXCEPTION_FILE"
fi

if ! command -v "$TOFU_BIN" >/dev/null 2>&1; then
  fail_check "tofu_binary" "'$TOFU_BIN' is not installed or not on PATH" "$POLICY_JSONL"
fi
emit_record "tofu_binary" "passed" "using tofu binary: $TOFU_BIN" "$POLICY_JSONL"

if [[ -n "$WORKSPACE" ]]; then
  run_required_check "workspace_select" "workspace selected: $WORKSPACE" "tofu workspace select failed for $WORKSPACE" \
    "$TOFU_BIN" -chdir="$TOFU_DIR" workspace select "$WORKSPACE"
fi

run_required_check "tofu_fmt" "tofu fmt -recursive -check passed" "tofu fmt -recursive -check failed" \
  "$TOFU_BIN" -chdir="$TOFU_DIR" fmt -recursive -check

run_required_check "tofu_init" "tofu init -input=false passed" "tofu init -input=false failed" \
  "$TOFU_BIN" -chdir="$TOFU_DIR" init -input=false

run_required_check "tofu_validate" "tofu validate passed" "tofu validate failed" \
  "$TOFU_BIN" -chdir="$TOFU_DIR" validate

run_external_tool "tflint" "tflint"
run_external_tool "tfsec" "tfsec" "$TOFU_DIR"

emit_record "policy_chain" "passed" "policy chain complete" "$POLICY_JSONL"
