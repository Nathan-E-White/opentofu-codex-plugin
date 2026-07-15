#!/usr/bin/env bash
set -euo pipefail

TOFU_BIN="${TOFU_BIN:-tofu}"
PATH_ARG="."
WORKSPACE=""
APPROVAL_TOKEN="${OPENTOFU_APPROVAL_TOKEN:-}"
BACKEND_HINT="${OPENTOFU_BACKEND_HINT:-}"
EXPECTED_WORKSPACE="${OPENTOFU_EXPECTED_WORKSPACE:-}"
EXPECTED_BACKEND_HINT="${OPENTOFU_EXPECTED_BACKEND_HINT:-}"
MIGRATION_SOURCE_URI="${OPENTOFU_BACKEND_SOURCE_URI:-}"
MIGRATION_TARGET_URI="${OPENTOFU_BACKEND_TARGET_URI:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_SCRIPT="${SCRIPT_DIR}/opentofu-runner.sh"
MODULE_SOURCE_CHECK_SCRIPT="${SCRIPT_DIR}/module-source-check.sh"
RUNNER_INVOKE=(bash "$RUNNER_SCRIPT")
RUN_ID="${OPENTOFU_RUN_ID:-}"
RUN_ID_WAS_SET=0
PROFILE="${OPENTOFU_PROFILE:-}"
ARTIFACT_DIR="${OPENTOFU_PLAN_ARTIFACT_DIR:-${OPENTOFU_ARTIFACT_DIR:-.tofu-artifacts}}"
ARTIFACT_DIR_WAS_SET=0
RUNNER_TIMEOUT="${OPENTOFU_RUNNER_TIMEOUT_SECONDS:-900}"
CI_MODE="${OPENTOFU_CI:-0}"
ROLLBACK_BACKUP_PATH="${OPENTOFU_ROLLBACK_BACKUP_PATH:-}"
ROLLBACK_PRECHECK_PATH=""
MODULE_SOURCE_CHECK="${OPENTOFU_MODULE_SOURCE_CHECK:-1}"
MODULE_EXCEPTION_FILE="${OPENTOFU_MODULE_EXCEPTION_FILE:-}"
MODULE_CHECKSUM_FILE="${OPENTOFU_MODULE_CHECKSUM_FILE:-}"
DEPRECATED_MODULE_SOURCE_FILE="${OPENTOFU_DEPRECATED_MODULE_SOURCE_FILE:-}"

if [[ -n "$RUN_ID" ]]; then
  RUN_ID_WAS_SET=1
fi
if [[ -n "${OPENTOFU_PLAN_ARTIFACT_DIR:-}${OPENTOFU_ARTIFACT_DIR:-}" ]]; then
  ARTIFACT_DIR_WAS_SET=1
fi

print_usage() {
  cat <<'USAGE'
Usage: run-plan.sh --path <dir> [options] <command> [args...]
Supported commands: init, validate, plan, apply, destroy, refresh, import, state
State-specific options:
  --backend-config <file>   backend hint for mutation audit
  --expected-workspace <name>  required workspace context for state mutations
  --expected-backend <path>    required backend hint for state mutations
  --approval-token <token>     explicit approval token for gated apply/state flows
  --backend-source-uri <uri>  migration source backend URI when using -migrate-state
  --backend-target-uri <uri>  migration target backend URI when using -migrate-state
  --run-id <id>            stable run id for artifacts
  --artifact-dir <dir>     artifact output directory
  --ci                     require explicit run id/artifact dir and immutable outputs
  --module-exception-file <path>  exception file for deprecated module sources
  --module-checksum-file <path>   module source checksum expectation file
  --deprecated-module-source-file <path> deprecated module source patterns
Other commands are passed through directly.
USAGE
}

json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r/\\r/g' -e 's/\n/\\n/g'
}

quote_args() {
  local arg
  local out=()
  for arg in "$@"; do
    out+=( "$(printf '%q' "$arg")" )
  done
  printf '%s\n' "${out[*]}"
}

run_tofu() {
  "${TOFU_BIN}" -chdir="$TOFU_DIR" "$@"
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

has_arg() {
  local needle="$1"
  local arg
  shift
  for arg in "$@"; do
    if [ "$arg" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

has_arg_prefix() {
  local needle_prefix="$1"
  local arg
  shift
  for arg in "$@"; do
    if [[ "$arg" == "${needle_prefix}"* ]]; then
      return 0
    fi
  done
  return 1
}

plan_output_path() {
  local default_path="$1"
  local previous_flag=0
  local arg
  shift
  for arg in "$@"; do
    if [[ "$previous_flag" -eq 1 ]]; then
      printf '%s' "$arg"
      return 0
    fi
    if [[ "$arg" == -out=* ]]; then
      printf '%s' "${arg#-out=}"
      return 0
    fi
    if [[ "$arg" == "-out" ]]; then
      previous_flag=1
    fi
  done
  printf '%s' "$default_path"
}

enforce_apply_prechecks() {
  local precheck_failed=0
  echo "run-plan: apply precheck -> tofu fmt"
  if ! run_tofu fmt -recursive -check >/tmp/opentofu-run-plan-fmt.$$ 2>&1; then
    cat /tmp/opentofu-run-plan-fmt.$$ >&2
    rm -f /tmp/opentofu-run-plan-fmt.$$
    echo "run-plan: tofu fmt -recursive -check failed" >&2
    precheck_failed=1
  else
    rm -f /tmp/opentofu-run-plan-fmt.$$
  fi

  echo "run-plan: apply precheck -> tofu init"
  if ! run_tofu init -input=false >/tmp/opentofu-run-plan-init.$$ 2>&1; then
    cat /tmp/opentofu-run-plan-init.$$ >&2
    rm -f /tmp/opentofu-run-plan-init.$$
    echo "run-plan: tofu init failed" >&2
    precheck_failed=1
  else
    rm -f /tmp/opentofu-run-plan-init.$$
  fi

  echo "run-plan: apply precheck -> tofu validate"
  if ! run_tofu validate >/tmp/opentofu-run-plan-validate.$$ 2>&1; then
    cat /tmp/opentofu-run-plan-validate.$$ >&2
    rm -f /tmp/opentofu-run-plan-validate.$$
    echo "run-plan: tofu validate failed" >&2
    precheck_failed=1
  else
    rm -f /tmp/opentofu-run-plan-validate.$$
  fi

  if [[ "$precheck_failed" -ne 0 ]]; then
    return 1
  fi
}

emit_plan_artifacts() {
  local plan_exit_code="$1"
  local plan_file="$2"
  local args_rendered="$3"
  local plan_json_path
  local summary_path
  local lock_meta="[]"
  local state_meta="[]"
  local lock_entries=()
  local state_entries=()
  local lock_file
  local -a state_paths
  local lock_entry=""
  local state_entry=""
  local status="failed"
  local hash
  local size
  local rel
  local lock_line
  local state_line

  mkdir -p "$ARTIFACT_DIR"
  plan_json_path="${ARTIFACT_DIR%/}/plan-${RUN_ID}.json"
  summary_path="${ARTIFACT_DIR%/}/plan-${RUN_ID}.summary.txt"

  ci_refuse_existing "$plan_json_path"
  ci_refuse_existing "$summary_path"

  case "$plan_exit_code" in
    0) status="no_changes" ;;
    2) status="changes_detected" ;;
  esac

  for lock_file in "${TOFU_DIR}/.terraform.lock.hcl" "${TOFU_DIR}/terraform.lock.hcl"; do
    if [ -f "$lock_file" ]; then
      hash="$(file_hash "$lock_file")"
      size="$(wc -c < "$lock_file")"
      rel="${lock_file#"$TOFU_DIR/"}"
      lock_entry="{\"path\":\"$(json_escape "$rel")\",\"sha256\":\"$hash\",\"bytes\":$size}"
      lock_entries+=("$lock_entry")
    fi
  done
  if [ "${#lock_entries[@]}" -gt 0 ]; then
    lock_line="$(IFS=,; printf '%s' "${lock_entries[*]}")"
    lock_meta="[${lock_line}]"
  fi

  state_paths=("${TOFU_DIR}/.terraform/terraform.tfstate" "${TOFU_DIR}/terraform.tfstate")
  for state_file in "${state_paths[@]}"; do
    if [ -f "$state_file" ]; then
      hash="$(file_hash "$state_file")"
      size="$(wc -c < "$state_file")"
      rel="${state_file#"$TOFU_DIR/"}"
      state_entry="{\"path\":\"$(json_escape "$rel")\",\"sha256\":\"$hash\",\"bytes\":$size}"
      state_entries+=("$state_entry")
    fi
  done
  if [ "${#state_entries[@]}" -gt 0 ]; then
    state_line="$(IFS=,; printf '%s' "${state_entries[*]}")"
    state_meta="[${state_line}]"
  fi

  if [ -f "$plan_file" ]; then
    if ! run_tofu show -json "$plan_file" > "$plan_json_path" 2>/dev/null; then
      printf '%s\n' '{"status":"unavailable","reason":"tofu show -json failed"}' > "$plan_json_path"
    fi
  else
    printf '%s\n' '{"status":"unavailable","reason":"plan file missing"}' > "$plan_json_path"
  fi

  {
    echo "run_id: ${RUN_ID}"
    echo "command: plan"
    echo "arguments: ${args_rendered}"
    echo "working_dir: ${TOFU_DIR}"
    echo "workspace: ${WORKSPACE}"
    echo "profile: ${PROFILE:-}"
    echo "status: ${status}"
    echo "exit_code: ${plan_exit_code}"
    echo "plan_file: ${plan_file}"
    echo "plan_json: ${plan_json_path}"
    echo "lock_metadata: ${lock_meta}"
    echo "state_metadata: ${state_meta}"
  } > "$summary_path"

  echo "run-plan: emitted deterministic plan summary -> $summary_path"
  echo "run-plan: emitted deterministic plan JSON -> $plan_json_path"
}

ci_refuse_existing() {
  local path="$1"
  if [[ "$CI_MODE" == "1" && -e "$path" ]]; then
    echo "run-plan: CI mode refuses to overwrite existing artifact: $path" >&2
    exit 1
  fi
}

ci_require_output_file() {
  local path="$1"
  local label="$2"
  if [[ "$CI_MODE" != "1" ]]; then
    return 0
  fi
  if [[ ! -s "$path" ]]; then
    echo "run-plan: CI mode required output missing or empty: ${label}=${path}" >&2
    exit 1
  fi
}

find_previous_plan() {
  local current_plan="$1"
  local candidate
  for candidate in "${ARTIFACT_DIR%/}"/open-tofu-*.tfplan; do
    [[ -e "$candidate" ]] || continue
    [[ "$candidate" == "$current_plan" ]] && continue
    printf '%s' "$candidate"
    return 0
  done
  printf 'none'
}

emit_rollback_precheck() {
  local plan_exit_code="$1"
  local plan_file="$2"
  local rollback_path
  local previous_plan
  local state_marker="missing"

  if [[ "$PROFILE" != "prod" || "$plan_exit_code" -ne 2 ]]; then
    return 0
  fi

  rollback_path="${ARTIFACT_DIR%/}/rollback-precheck-${RUN_ID}.txt"
  ci_refuse_existing "$rollback_path"
  previous_plan="$(find_previous_plan "$plan_file")"

  if [[ -f "$TOFU_DIR/.terraform/terraform.tfstate" ]]; then
    state_marker=".terraform/terraform.tfstate"
  elif [[ -f "$TOFU_DIR/terraform.tfstate" ]]; then
    state_marker="terraform.tfstate"
  fi

  {
    echo "run_id: ${RUN_ID}"
    echo "command: rollback-precheck"
    echo "profile: ${PROFILE}"
    echo "working_dir: ${TOFU_DIR}"
    echo "plan_file: ${plan_file}"
    echo "plan_json: ${ARTIFACT_DIR%/}/plan-${RUN_ID}.json"
    echo "plan_summary: ${ARTIFACT_DIR%/}/plan-${RUN_ID}.summary.txt"
    echo "current_state_marker: ${state_marker}"
    echo "backup_path: ${ROLLBACK_BACKUP_PATH:-unset}"
    echo "previous_plan: ${previous_plan}"
    echo "fallback_docs: plugins/opentofu/skills/opentofu-gitops/SKILL.md#rollback-preparedness"
    echo "status: ready_for_review"
  } > "$rollback_path"

  ROLLBACK_PRECHECK_PATH="$rollback_path"
  echo "run-plan: emitted rollback pre-check -> $rollback_path"
}

sanitize_slug() {
  local raw="$1"
  echo "$raw" | tr -c 'A-Za-z0-9._-' '_'
}

init_migration_requested() {
  local arg
  for arg in "${ARGS[@]+"${ARGS[@]}"}"; do
    if [[ "$arg" == "-migrate-state" || "$arg" == "--migrate-state" || "$arg" == "-migrate-state="* || "$arg" == "--migrate-state="* ]]; then
      return 0
    fi
  done
  return 1
}

capture_state_artifacts() {
  local artifact_path="$1"
  local phase="$2"
  local op="$3"
  local state_file
  local rel
  local hash
  local size

  mkdir -p "$ARTIFACT_DIR"
  {
    echo "run_id: ${RUN_ID}"
    echo "phase: ${phase}"
    echo "operation: ${op}"
    echo "command: state ${op}"
    echo "working_dir: ${TOFU_DIR}"
    echo "workspace: ${WORKSPACE}"
    echo "backend_hint: ${BACKEND_HINT}"
    echo "expected_workspace: ${EXPECTED_WORKSPACE}"
    echo "expected_backend_hint: ${EXPECTED_BACKEND_HINT}"
    echo "profile: ${PROFILE:-}"
    echo "run_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "state_file_metadata:"
    for state_file in "${TOFU_DIR}/.terraform/terraform.tfstate" "${TOFU_DIR}/terraform.tfstate"; do
      if [ -f "$state_file" ]; then
        hash="$(file_hash "$state_file")"
        size="$(wc -c < "$state_file")"
        rel="${state_file#"$TOFU_DIR/"}"
        echo "  - path: ${rel}"
        echo "    sha256: ${hash}"
        echo "    bytes: ${size}"
      else
        rel="${state_file#"$TOFU_DIR/"}"
        echo "  - path: ${rel}"
        echo "    status: missing"
      fi
    done
  } > "$artifact_path"
}

capture_backend_migration_artifacts() {
  local artifact_path="$1"
  local phase="$2"
  local migration_status="$3"
  local migration_args="${4:-}"
  local state_file
  local rel
  local hash
  local size

  mkdir -p "$ARTIFACT_DIR"
  {
    echo "run_id: ${RUN_ID}"
    echo "phase: ${phase}"
    echo "command: init -migrate-state"
    echo "command_args: ${migration_args}"
    echo "status: ${migration_status}"
    echo "working_dir: ${TOFU_DIR}"
    echo "workspace: ${WORKSPACE}"
    echo "backend_hint: ${BACKEND_HINT}"
    echo "backend_migration_source_uri: ${MIGRATION_SOURCE_URI}"
    echo "backend_migration_target_uri: ${MIGRATION_TARGET_URI}"
    echo "expected_workspace: ${EXPECTED_WORKSPACE}"
    echo "expected_backend_hint: ${EXPECTED_BACKEND_HINT}"
    echo "profile: ${PROFILE:-}"
    echo "run_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "lockfile_metadata:"
    for state_file in "${TOFU_DIR}/.terraform.lock.hcl" "${TOFU_DIR}/terraform.lock.hcl"; do
      if [ -f "$state_file" ]; then
        hash="$(file_hash "$state_file")"
        size="$(wc -c < "$state_file")"
        rel="${state_file#"$TOFU_DIR/"}"
        echo "  - path: ${rel}"
        echo "    sha256: ${hash}"
        echo "    bytes: ${size}"
      fi
    done
  } > "$artifact_path"
}

require_backend_migration_metadata() {
  if ! init_migration_requested; then
    return 0
  fi

  if [[ -z "$MIGRATION_SOURCE_URI" || -z "$MIGRATION_TARGET_URI" ]]; then
    {
      echo "run-plan: blocked: migrate-state requires both --backend-source-uri and --backend-target-uri."
      echo "run-plan: expected both source and target backend URIs for deterministic migration evidence."
      echo "run-plan: run_id=${RUN_ID} profile=${PROFILE:-dev} workspace=${WORKSPACE:-unset} backend_hint=${BACKEND_HINT:-unset}"
    } >&2
    return 1
  fi
}

require_enterprise_apply_approval() {
  if [[ "${OPENTOFU_MODE:-}" != "enterprise" ]]; then
    return 0
  fi

  if [[ -n "$APPROVAL_TOKEN" ]]; then
    return 0
  fi

  {
    echo "run-plan: blocked: enterprise mode apply requires approval token."
    echo "run-plan: set OPENTOFU_APPROVAL_TOKEN and rerun without changing run context."
    echo "run-plan: run_id=${RUN_ID} profile=${PROFILE:-dev} workspace=${WORKSPACE:-unset} backend_hint=${BACKEND_HINT:-unset} path=${TOFU_DIR}"
  } >&2
  return 1
}

state_requires_approval_token() {
  local op="$1"
  case "$op" in
    rm|mv)
      if [[ "${OPENTOFU_MODE:-}" == "enterprise" || "$PROFILE" == "stg" || "$PROFILE" == "prod" ]]; then
        return 0
      fi
      ;;
    show)
      if [[ "$PROFILE" == "stg" || "$PROFILE" == "prod" || "${OPENTOFU_MODE:-}" == "enterprise" ]]; then
        return 0
      fi
      ;;
  esac
  return 1
}

require_state_approval_token() {
  local op="$1"
  if ! state_requires_approval_token "$op"; then
    return 0
  fi

  if [[ -n "$APPROVAL_TOKEN" ]]; then
    return 0
  fi

  {
    echo "run-plan: blocked: state ${op} requires OPENTOFU_APPROVAL_TOKEN for current mode/profile."
    echo "run-plan: set OPENTOFU_APPROVAL_TOKEN and rerun with the same context."
    echo "run-plan: run_id=${RUN_ID} profile=${PROFILE:-dev} workspace=${WORKSPACE:-unset} backend_hint=${BACKEND_HINT:-unset}"
  } >&2
  return 1
}

run_module_source_check() {
  local mode="$1"
  local module_profile="${PROFILE:-dev}"
  local module_cmd=(bash "$MODULE_SOURCE_CHECK_SCRIPT" --path "$TOFU_DIR" --profile "$module_profile" --mode "$mode" --run-id "$RUN_ID" --artifact-dir "$ARTIFACT_DIR")

  if [[ "$MODULE_SOURCE_CHECK" == "0" ]]; then
    echo "run-plan: module source check disabled"
    return 0
  fi

  if [[ ! -f "$MODULE_SOURCE_CHECK_SCRIPT" ]]; then
    echo "run-plan: warning: module source check script missing: $MODULE_SOURCE_CHECK_SCRIPT"
    return 0
  fi

  if [[ -n "$MODULE_EXCEPTION_FILE" ]]; then
    module_cmd+=(--exception-file "$MODULE_EXCEPTION_FILE")
  fi
  if [[ -n "$MODULE_CHECKSUM_FILE" ]]; then
    module_cmd+=(--checksum-file "$MODULE_CHECKSUM_FILE")
  fi
  if [[ -n "$DEPRECATED_MODULE_SOURCE_FILE" ]]; then
    module_cmd+=(--deprecated-source-file "$DEPRECATED_MODULE_SOURCE_FILE")
  fi
  if [[ "$CI_MODE" == "1" ]]; then
    module_cmd+=(--ci)
  fi

  echo "run-plan: module source sanity check mode=$mode"
  "${module_cmd[@]}"
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
    --backend-config|--backend)
      BACKEND_HINT="${2:?missing backend value}"
      shift 2
      ;;
    --expected-workspace)
      EXPECTED_WORKSPACE="${2:?missing --expected-workspace value}"
      shift 2
      ;;
    --expected-backend)
      EXPECTED_BACKEND_HINT="${2:?missing --expected-backend value}"
      shift 2
      ;;
    --backend-source-uri)
      MIGRATION_SOURCE_URI="${2:?missing --backend-source-uri value}"
      shift 2
      ;;
    --backend-target-uri)
      MIGRATION_TARGET_URI="${2:?missing --backend-target-uri value}"
      shift 2
      ;;
    --approval-token)
      APPROVAL_TOKEN="${2:?missing --approval-token value}"
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
    --module-exception-file)
      MODULE_EXCEPTION_FILE="${2:?missing --module-exception-file value}"
      shift 2
      ;;
    --module-checksum-file)
      MODULE_CHECKSUM_FILE="${2:?missing --module-checksum-file value}"
      shift 2
      ;;
    --deprecated-module-source-file)
      DEPRECATED_MODULE_SOURCE_FILE="${2:?missing --deprecated-module-source-file value}"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 1 ]]; then
  echo "error: missing command" >&2
  print_usage
  exit 2
fi

if [[ "$CI_MODE" != "0" && "$CI_MODE" != "1" ]]; then
  echo "error: --ci/OPENTOFU_CI must resolve to 0 or 1" >&2
  exit 2
fi

if [[ "$CI_MODE" == "1" ]]; then
  if [[ "$RUN_ID_WAS_SET" -ne 1 ]]; then
    echo "error: --ci requires --run-id or OPENTOFU_RUN_ID" >&2
    exit 2
  fi
  if [[ "$ARTIFACT_DIR_WAS_SET" -ne 1 ]]; then
    echo "error: --ci requires --artifact-dir or OPENTOFU_PLAN_ARTIFACT_DIR/OPENTOFU_ARTIFACT_DIR" >&2
    exit 2
  fi
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
fi

TOFU_CMD="$1"
shift
ARGS=("$@")

if [[ ! -d "$PATH_ARG" ]]; then
  echo "error: path '$PATH_ARG' does not exist" >&2
  exit 1
fi

if ! command -v "$TOFU_BIN" >/dev/null 2>&1; then
  echo "error: '$TOFU_BIN' is not installed or not on PATH" >&2
  exit 127
fi

TOFU_DIR="$(cd "$PATH_ARG" && pwd)"
printf 'run-plan: command=%s path=%s\n' "$TOFU_CMD" "$TOFU_DIR"

if [[ -n "$WORKSPACE" ]]; then
  echo "run-plan: selecting workspace=$WORKSPACE"
  run_tofu workspace select "$WORKSPACE"
fi

case "$TOFU_CMD" in
  init)
    run_module_source_check "readonly"
    require_backend_migration_metadata || exit 1
    if init_migration_requested; then
      migration_before="${ARTIFACT_DIR%/}/backend-migration-${RUN_ID}-before.txt"
      migration_after="${ARTIFACT_DIR%/}/backend-migration-${RUN_ID}-after.txt"
      capture_backend_migration_artifacts "$migration_before" "before" "pending" "${ARGS[*]}"
    fi

    set +e
    "${RUNNER_INVOKE[@]}" --mode execute --label "run-plan:init" --run-id "$RUN_ID" --timeout "$RUNNER_TIMEOUT" -- "$TOFU_BIN" -chdir="$TOFU_DIR" init -input=false "${ARGS[@]+"${ARGS[@]}"}"
    init_exit_code=$?
    set -e

    if init_migration_requested; then
      migration_after_status="failed"
      if [[ "${init_exit_code:-0}" -eq 0 ]]; then
        migration_after_status="completed"
      fi
      capture_backend_migration_artifacts "$migration_after" "after" "$migration_after_status" "${ARGS[*]}"
    fi

    if [[ "${init_exit_code:-0}" -ne 0 ]]; then
      exit "$init_exit_code"
    fi
    ;;
  validate)
    "${RUNNER_INVOKE[@]}" --mode execute --label "run-plan:validate" --run-id "$RUN_ID" --timeout "$RUNNER_TIMEOUT" -- "$TOFU_BIN" -chdir="$TOFU_DIR" init -input=false
    "${RUNNER_INVOKE[@]}" --mode execute --label "run-plan:validate" --run-id "$RUN_ID" --timeout "$RUNNER_TIMEOUT" -- "$TOFU_BIN" -chdir="$TOFU_DIR" validate "${ARGS[@]+"${ARGS[@]}"}"
    ;;
plan)
    run_module_source_check "readonly"
    mkdir -p "$ARTIFACT_DIR"
    default_plan_path="${ARTIFACT_DIR%/}/open-tofu-${RUN_ID}.tfplan"
    PLAN_PATH="$(plan_output_path "$default_plan_path" "${ARGS[@]+"${ARGS[@]}"}")"
    ci_refuse_existing "$PLAN_PATH"
    plan_args=("${ARGS[@]+"${ARGS[@]}"}")

    if ! has_arg "-input=false" "${plan_args[@]+"${plan_args[@]}"}" && ! has_arg "-input=true" "${plan_args[@]+"${plan_args[@]}"}"; then
      plan_args=(-input=false "${plan_args[@]+"${plan_args[@]}"}")
    fi
    if ! has_arg "-no-color" "${plan_args[@]+"${plan_args[@]}"}"; then
      plan_args=(-no-color "${plan_args[@]+"${plan_args[@]}"}")
    fi
    if ! has_arg "-detailed-exitcode" "${plan_args[@]+"${plan_args[@]}"}"; then
      plan_args=(-detailed-exitcode "${plan_args[@]+"${plan_args[@]}"}")
    fi
    if ! has_arg_prefix "-out=" "${plan_args[@]+"${plan_args[@]}"}" && ! has_arg "-out" "${plan_args[@]+"${plan_args[@]}"}"; then
      plan_args=(-out "$PLAN_PATH" "${plan_args[@]+"${plan_args[@]}"}")
    fi

    if "${RUNNER_INVOKE[@]}" --mode execute --label "run-plan:plan" --run-id "$RUN_ID" --timeout "$RUNNER_TIMEOUT" --success-exit-codes "0,2" -- "$TOFU_BIN" -chdir="$TOFU_DIR" plan "${plan_args[@]}"; then
      plan_exit=0
    else
      plan_exit=$?
    fi
    PLAN_PATH="$(plan_output_path "$default_plan_path" "${plan_args[@]+"${plan_args[@]}"}")"
    emit_plan_artifacts "$plan_exit" "$PLAN_PATH" "$(quote_args "${plan_args[@]+"${plan_args[@]}"}")"
    emit_rollback_precheck "$plan_exit" "$PLAN_PATH"
    ci_require_output_file "$PLAN_PATH" "plan_file"
    ci_require_output_file "${ARTIFACT_DIR%/}/plan-${RUN_ID}.json" "plan_json"
    ci_require_output_file "${ARTIFACT_DIR%/}/plan-${RUN_ID}.summary.txt" "plan_summary"
    if [[ -n "$ROLLBACK_PRECHECK_PATH" ]]; then
      ci_require_output_file "$ROLLBACK_PRECHECK_PATH" "rollback_precheck"
    fi
    if [[ "$plan_exit" -ne 0 ]]; then
      exit "$plan_exit"
    fi
    ;;
  apply|destroy|refresh)
    if [[ "$TOFU_CMD" == "apply" || "$TOFU_CMD" == "destroy" ]]; then
      run_module_source_check "mutating"
    else
      run_module_source_check "readonly"
    fi
    if [[ "$TOFU_CMD" == "apply" ]]; then
      require_enterprise_apply_approval || exit 1
      enforce_apply_prechecks
    fi
    "${RUNNER_INVOKE[@]}" --mode execute --label "run-plan:${TOFU_CMD}" --run-id "$RUN_ID" --timeout "$RUNNER_TIMEOUT" -- "$TOFU_BIN" -chdir="$TOFU_DIR" "$TOFU_CMD" -input=false "${ARGS[@]+"${ARGS[@]}"}"
    ;;
  import)
    run_module_source_check "mutating"
    "${RUNNER_INVOKE[@]}" --mode execute --label "run-plan:import" --run-id "$RUN_ID" --timeout "$RUNNER_TIMEOUT" -- "$TOFU_BIN" -chdir="$TOFU_DIR" init -input=false
    "${RUNNER_INVOKE[@]}" --mode execute --label "run-plan:import" --run-id "$RUN_ID" --timeout "$RUNNER_TIMEOUT" -- "$TOFU_BIN" -chdir="$TOFU_DIR" import "${ARGS[@]+"${ARGS[@]}"}"
    ;;
  state)
    if [[ "${#ARGS[@]}" -lt 1 ]]; then
      echo "run-plan: state command missing subcommand" >&2
      exit 2
    fi
    STATE_OP="${ARGS[0]}"
    STATE_OP_SLUG="$(sanitize_slug "$STATE_OP")"
    STATE_BEFORE_PATH="${ARTIFACT_DIR%/}/state-${RUN_ID}-${STATE_OP_SLUG}-before.txt"
    STATE_AFTER_PATH="${ARTIFACT_DIR%/}/state-${RUN_ID}-${STATE_OP_SLUG}-after.txt"

    if [[ "$STATE_OP" == "rm" || "$STATE_OP" == "mv" || "$STATE_OP" == "show" ]]; then
      require_state_approval_token "$STATE_OP" || exit 1
      capture_state_artifacts "$STATE_BEFORE_PATH" "before" "$STATE_OP"
    fi

    set +e
    "${RUNNER_INVOKE[@]}" --mode execute --label "run-plan:${TOFU_CMD}" --run-id "$RUN_ID" --timeout "$RUNNER_TIMEOUT" -- "$TOFU_BIN" -chdir="$TOFU_DIR" "$TOFU_CMD" "${ARGS[@]+"${ARGS[@]}"}"
    STATE_EXIT_CODE=$?
    set -e

    if [[ "$STATE_OP" == "rm" || "$STATE_OP" == "mv" || "$STATE_OP" == "show" ]]; then
      capture_state_artifacts "$STATE_AFTER_PATH" "after" "$STATE_OP"
      echo "run-plan: emitted state artifacts before=${STATE_BEFORE_PATH} after=${STATE_AFTER_PATH}"
      echo "run-plan: expected_workspace=${EXPECTED_WORKSPACE:-unset} expected_backend=${EXPECTED_BACKEND_HINT:-unset}"
    fi

    if [[ "$STATE_EXIT_CODE" -ne 0 ]]; then
      exit "$STATE_EXIT_CODE"
    fi
    ;;
  *)
    "${RUNNER_INVOKE[@]}" --mode execute --label "run-plan:$TOFU_CMD" --run-id "$RUN_ID" --timeout "$RUNNER_TIMEOUT" -- "$TOFU_BIN" -chdir="$TOFU_DIR" "$TOFU_CMD" "${ARGS[@]+"${ARGS[@]}"}"
    ;;
esac

echo "run-plan: completed"
