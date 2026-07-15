#!/usr/bin/env bash
set -euo pipefail

TOFU_BIN="${TOFU_BIN:-tofu}"
PATH_ARG="."
WORKSPACE=""
PLAN_PATH=""
RUN_ID="${OPENTOFU_DRIFT_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$$}"
ARTIFACT_DIR=".tofu-artifacts"
EXPECTED_WORKSPACE=""
BACKEND_URI=""
EXPECTED_BACKEND_URI=""
EXPECTED_LOCKFILE_HASH=""
BACKEND_SOURCE_URI=""
BACKEND_TARGET_URI=""
RAW_ARGS=("$@")

print_usage() {
  cat <<'USAGE'
Usage: drift-check.sh --path <dir> [--workspace <name>] [--plan-file <path>]
  [--run-id <id>] [--artifact-dir <dir>] [--expected-workspace <name>]
  [--backend-uri <uri>] [--expected-backend-uri <uri>]
  [--expected-lockfile-hash <sha256>]
  [--backend-source-uri <uri>] [--backend-target-uri <uri>]
Runs refresh + plan and exits with code 2 when drift is detected.
USAGE
}

file_hash() {
  local path="$1"
  if ! [ -f "$path" ]; then
    echo "MISSING"
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

emit_drift_artifact() {
  local path="$1"
  local status="$2"
  local drift_code="$3"
  local selected_workspace="$4"
  local lockfile_metadata="$5"
  local plan_exit_code="$6"
  local args_rendered="$7"

  mkdir -p "$ARTIFACT_DIR"
  {
    echo "run_id: ${RUN_ID}"
    echo "status: ${status}"
    echo "command: drift-check"
    echo "arguments: ${args_rendered}"
    echo "working_dir: ${TOFU_DIR}"
    echo "plan_path: ${PLAN_PATH}"
    echo "plan_exit_code: ${plan_exit_code}"
    echo "drift_code: ${drift_code}"
    echo "workspace_requested: ${WORKSPACE:-unset}"
    echo "workspace_selected: ${selected_workspace:-unset}"
    echo "expected_workspace: ${EXPECTED_WORKSPACE:-unset}"
    echo "backend_uri: ${BACKEND_URI:-unset}"
    echo "expected_backend_uri: ${EXPECTED_BACKEND_URI:-unset}"
    echo "backend_source_uri: ${BACKEND_SOURCE_URI:-unset}"
    echo "backend_target_uri: ${BACKEND_TARGET_URI:-unset}"
    echo "expected_lockfile_hash: ${EXPECTED_LOCKFILE_HASH:-unset}"
    echo "run_at_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "lockfiles:"
    if [ -z "$lockfile_metadata" ]; then
      echo "  - missing"
    else
      echo "$lockfile_metadata"
    fi
  } > "$path"
}

collect_lockfile_metadata() {
  local rel lock_file hash size
  local out=""
  for lock_file in "${TOFU_DIR}/.terraform.lock.hcl" "${TOFU_DIR}/terraform.lock.hcl"; do
    if [ -f "$lock_file" ]; then
      hash="$(file_hash "$lock_file")"
      size="$(wc -c < "$lock_file")"
      rel="${lock_file#"$TOFU_DIR/"}"
      out+=$(printf '  - path: %s\n    sha256: %s\n    bytes: %s\n' "$rel" "$hash" "$size")
    fi
  done
  printf '%s' "$out"
}

collect_selected_workspace() {
  local current
  if ! current="$("$TOFU_BIN" -chdir="$TOFU_DIR" workspace show 2>/dev/null)"; then
    echo ""
    return 0
  fi
  echo "$current" | sed 's/^\* //;s/[[:space:]]*$//'
}

fail_with_artifact() {
  local status="$1"
  local message="$2"
  local code="$3"
  local drift_code="${4:-failure}"
  local args_rendered="${RAW_ARGS[*]-}"

  emit_drift_artifact "${ARTIFACT_DIR%/}/drift-${RUN_ID}.txt" "$status" "$drift_code" "${SELECTED_WORKSPACE:-}" "$(collect_lockfile_metadata)" "" "$args_rendered"
  echo "$message" >&2
  exit "$code"
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
    --plan-file)
      PLAN_PATH="${2:?missing --plan-file value}"
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
    --expected-workspace)
      EXPECTED_WORKSPACE="${2:?missing --expected-workspace value}"
      shift 2
      ;;
    --backend-uri)
      BACKEND_URI="${2:?missing --backend-uri value}"
      shift 2
      ;;
    --expected-backend-uri)
      EXPECTED_BACKEND_URI="${2:?missing --expected-backend-uri value}"
      shift 2
      ;;
    --expected-lockfile-hash)
      EXPECTED_LOCKFILE_HASH="${2:?missing --expected-lockfile-hash value}"
      shift 2
      ;;
    --backend-source-uri)
      BACKEND_SOURCE_URI="${2:?missing --backend-source-uri value}"
      shift 2
      ;;
    --backend-target-uri)
      BACKEND_TARGET_URI="${2:?missing --backend-target-uri value}"
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

if [[ ! -d "$PATH_ARG" ]]; then
  echo "error: path '$PATH_ARG' does not exist" >&2
  exit 1
fi

if ! command -v "$TOFU_BIN" >/dev/null 2>&1; then
  echo "error: '$TOFU_BIN' is not installed or not on PATH" >&2
  exit 127
fi

if [[ -z "$PLAN_PATH" ]]; then
  PLAN_PATH=".tofu.drift.$(date +%s).tfplan"
fi

TOFU_DIR="$(cd "$PATH_ARG" && pwd)"
cd "$TOFU_DIR"
SELECTED_WORKSPACE=""

echo "drift-check: run_id=${RUN_ID}"
echo "drift-check: path=${TOFU_DIR:-$PATH_ARG}"

if [[ -n "$WORKSPACE" ]]; then
  echo "drift-check: selecting workspace=$WORKSPACE"
  "$TOFU_BIN" -chdir="$TOFU_DIR" workspace select "$WORKSPACE"
else
  echo "drift-check: no workspace requested"
fi

SELECTED_WORKSPACE="$(collect_selected_workspace || true)"
echo "drift-check: selected workspace=${SELECTED_WORKSPACE:-unset}"

if [[ -n "$EXPECTED_WORKSPACE" ]]; then
  if [[ -z "$SELECTED_WORKSPACE" ]]; then
    fail_with_artifact "precheck_failed" "error: expected workspace '${EXPECTED_WORKSPACE}' but no active workspace could be resolved." 1 "workspace_context"
  fi
  if [[ "$SELECTED_WORKSPACE" != "$EXPECTED_WORKSPACE" ]]; then
    fail_with_artifact "precheck_failed" "error: workspace context mismatch (expected='${EXPECTED_WORKSPACE}', actual='${SELECTED_WORKSPACE}')." 1 "workspace_context"
  fi
fi

if [[ -n "$BACKEND_URI" ]]; then
  echo "drift-check: backend_uri=${BACKEND_URI}"
else
  echo "drift-check: backend_uri=unset"
fi

if [[ -n "$EXPECTED_BACKEND_URI" ]]; then
  if [[ -z "$BACKEND_URI" ]]; then
    fail_with_artifact "precheck_failed" "error: expected-backend-uri was provided but backend-uri was not." 1 "backend_context"
  fi
  if [[ "$BACKEND_URI" != "$EXPECTED_BACKEND_URI" ]]; then
    fail_with_artifact "precheck_failed" "error: backend URI mismatch (expected='${EXPECTED_BACKEND_URI}', actual='${BACKEND_URI}')." 1 "backend_context"
  fi
fi

if [[ -n "$BACKEND_SOURCE_URI" ]]; then
  echo "drift-check: backend_source_uri=${BACKEND_SOURCE_URI}"
fi
if [[ -n "$BACKEND_TARGET_URI" ]]; then
  echo "drift-check: backend_target_uri=${BACKEND_TARGET_URI}"
fi

if [[ -n "$EXPECTED_LOCKFILE_HASH" ]]; then
  lock_match=0
  lock_matched=0
  for lock_file in "${TOFU_DIR}/.terraform.lock.hcl" "${TOFU_DIR}/terraform.lock.hcl"; do
    if [ -f "$lock_file" ]; then
      lock_match=1
      current_hash="$(file_hash "$lock_file")"
      if [[ "$current_hash" == "$EXPECTED_LOCKFILE_HASH" ]]; then
        lock_matched=1
      fi
    fi
  done
  if [[ "$lock_match" -eq 0 ]]; then
    fail_with_artifact "precheck_failed" "error: expected lockfile hash provided but no lockfile found." 1 "lockfile"
  fi
  if [[ "$lock_matched" -eq 0 ]]; then
    fail_with_artifact "precheck_failed" "error: lockfile hash mismatch with expected_lockfile_hash=${EXPECTED_LOCKFILE_HASH}." 1 "lockfile"
  fi
fi

LOCKFILE_METADATA="$(collect_lockfile_metadata)"
echo "drift-check: lockfiles="
if [ -z "$LOCKFILE_METADATA" ]; then
  echo "  - missing"
else
  printf '%s\n' "$LOCKFILE_METADATA"
fi

echo "drift-check: artifact=${ARTIFACT_DIR%/}/drift-${RUN_ID}.txt"
echo "drift-check: running refresh"
"$TOFU_BIN" refresh -input=false

echo "drift-check: running plan"
set +e
"$TOFU_BIN" plan -input=false -no-color -detailed-exitcode -out "$PLAN_PATH"
PLAN_EXIT=$?
set -e

if [[ $PLAN_EXIT -eq 0 ]]; then
  emit_drift_artifact "${ARTIFACT_DIR%/}/drift-${RUN_ID}.txt" "completed" "no_drift" "$SELECTED_WORKSPACE" "$LOCKFILE_METADATA" "$PLAN_EXIT" "${RAW_ARGS[*]}"
  echo "drift-check: no drift detected"
  rm -f "$PLAN_PATH"
  exit 0
fi

if [[ $PLAN_EXIT -eq 2 ]]; then
  emit_drift_artifact "${ARTIFACT_DIR%/}/drift-${RUN_ID}.txt" "completed" "drift_detected" "$SELECTED_WORKSPACE" "$LOCKFILE_METADATA" "$PLAN_EXIT" "${RAW_ARGS[*]}"
  echo "drift-check: drift detected (exit code 2). review plan at $PLAN_PATH"
  exit 2
fi

emit_drift_artifact "${ARTIFACT_DIR%/}/drift-${RUN_ID}.txt" "completed" "plan_failed" "$SELECTED_WORKSPACE" "$LOCKFILE_METADATA" "$PLAN_EXIT" "${RAW_ARGS[*]}"
echo "drift-check: tofu plan failed with code $PLAN_EXIT" >&2
exit 1
