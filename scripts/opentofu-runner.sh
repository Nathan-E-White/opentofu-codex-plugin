#!/usr/bin/env bash
set -euo pipefail

TOFU_BIN="${TOFU_BIN:-tofu}"
RUNNER_MODE="execute"
RUN_ID="${OPENTOFU_RUNNER_RUN_ID:-}"
LABEL="opentofu-command"
OUTPUT_FORMAT="text"
TIMEOUT_SECONDS="${OPENTOFU_RUNNER_TIMEOUT_SECONDS:-900}"
SUCCESS_EXIT_CODES="${OPENTOFU_RUNNER_SUCCESS_EXIT_CODES:-0}"
EVIDENCE_DIR=""
QUIET=0
REDACT_PLACEHOLDER="${OPENTOFU_RUNNER_REDACT_PLACEHOLDER:=[REDACTED]}"
ALLOWLIST_SPEC="${OPENTOFU_RUNNER_ALLOWLIST:-tofu:fmt,tofu:init,tofu:validate,tofu:plan,tofu:apply,tofu:destroy,tofu:refresh,tofu:import,tofu:state,tofu:workspace,tofu:output,tofu:show,tofu:providers,tofu:graph,tofu:get,tofu:login,tofu:logout,tofu:console,terraform:fmt,terraform:init,terraform:validate,terraform:plan,terraform:apply,terraform:destroy,terraform:refresh,terraform:import,terraform:state}"

usage() {
  cat <<'USAGE'
Usage: opentofu-runner.sh [options] -- <command> [args...]

Execute an OpenTofu-compatible command with allowlist enforcement, timeout control,
redacted stdout/stderr capture, and stable status envelopes.

Options:
  --mode execute|plan        execution mode (default: execute)
  --label TEXT               status label for logging/enrichment
  --run-id TEXT              stable run id (auto-generated if omitted)
  --timeout SECONDS          execution timeout in seconds (default: 900)
  --success-exit-codes LIST  comma-separated successful exit codes (default: 0)
  --format text|json          output format (default: text)
  --allowlist LIST           override command allowlist e.g. "tofu:plan,tofu:apply"
  --evidence-dir DIR         write sanitized evidence bundle to directory
  --quiet                    suppress command output in text format
  --help                     show this help
USAGE
}

json_escape() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/'/\\'/g" -e 's/\r/\\r/g' -e 's/\n/\\n/g'
}

quote_cmd() {
  local token out=()
  for token in "$@"; do
    out+=( "$(printf '%q' "$token")" )
  done
  printf '%s' "${out[*]}"
}

redact_line() {
  sed -E \
    -e "s/([Aa]uthorization:[[:space:]]*)[^[:space:]]+/\1$REDACT_PLACEHOLDER/g" \
    -e "s/([Aa]pi[_-]?[Kk]ey|[Tt]oken|[Ss]ecret|[Pp]assword|[Aa]ccess[_-]?[Tt]oken)[[:space:]]*[:=][[:space:]]*[\"']?[^\"']+[\"']?/\\1=[REDACTED]/g"
}

emit_redacted_file() {
  local file="$1"
  local line
  while IFS= read -r line || [ -n "${line:-}" ]; do
    printf '%s\n' "$line" | redact_line
  done < "$file"
}

emit_status_text() {
  local status="$1"
  local exit_code="$2"
  local command_rendered
  shift 2
  command_rendered="$(quote_cmd "$@")"
  local evidence_part=""
  if [[ -n "${EVIDENCE_PATH:-}" ]]; then
    evidence_part=" evidence=${EVIDENCE_PATH}"
  fi
  echo "OPENTOFU_RUNNER run_id=${RUN_ID} mode=${RUNNER_MODE} label=${LABEL} status=${status} exit_code=${exit_code} command=${command_rendered}${evidence_part}"
}

emit_status_json() {
  local status="$1"
  local exit_code="$2"
  local command_rendered
  shift 2
  command_rendered="$(json_escape "$(quote_cmd "$@")")"
  local run_id_json
  local label_json
  local mode_json
  local status_json
  local evidence_json
  run_id_json="$(json_escape "$RUN_ID")"
  label_json="$(json_escape "$LABEL")"
  mode_json="$(json_escape "$RUNNER_MODE")"
  status_json="$(json_escape "$status")"
  evidence_json="$(json_escape "${EVIDENCE_PATH:-}")"
  printf '%s\n' "{\"run_id\":\"${run_id_json}\",\"label\":\"${label_json}\",\"mode\":\"${mode_json}\",\"status\":\"${status_json}\",\"exit_code\":${exit_code},\"command\":\"${command_rendered}\",\"evidence\":\"${evidence_json}\"}"
}

split_allowlist() {
  IFS=',' read -r -a ALLOWLIST <<< "$ALLOWLIST_SPEC"
}

is_allowed_command() {
  local binary="$1"
  local action="${2:-__none__}"
  local entry
  for entry in "${ALLOWLIST[@]}"; do
    if [[ "$entry" == "$binary:*" ]] || [[ "$entry" == "$binary:$action" ]]; then
      return 0
    fi
  done
  return 1
}

is_success_exit_code() {
  local actual="$1"
  local allowed
  local -a allowed_codes
  IFS=',' read -r -a allowed_codes <<< "$SUCCESS_EXIT_CODES"
  for allowed in "${allowed_codes[@]}"; do
    if [[ "$actual" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

run_command() {
  local -a cmd=("$@")
  local tmp_out
  local tmp_err
  local exit_code
  local start_ts
  local end_ts
  local duration_ms

  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  trap 'rm -f "${tmp_out-}" "${tmp_err-}"' RETURN

  start_ts="$(date +%s)"
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout "${TIMEOUT_SECONDS}s" "${cmd[@]}" >"$tmp_out" 2>"$tmp_err"
    exit_code=$?
  else
    "${cmd[@]}" >"$tmp_out" 2>"$tmp_err"
    exit_code=$?
  fi
  set -e
  end_ts="$(date +%s)"
  duration_ms=$(( (end_ts - start_ts) * 1000 ))

  if [[ "$OUTPUT_FORMAT" != "json" ]] && [[ "$QUIET" -eq 0 ]]; then
    emit_redacted_file "$tmp_out"
    emit_redacted_file "$tmp_err"
  fi

  if [[ -n "${EVIDENCE_DIR:-}" ]]; then
    {
      echo "run_id: ${RUN_ID}"
      echo "label: ${LABEL}"
      echo "mode: ${RUNNER_MODE}"
      echo "command: $(quote_cmd "${cmd[@]}")"
      echo "exit_code: ${exit_code}"
      echo "timeout_seconds: ${TIMEOUT_SECONDS}"
      echo "duration_ms: ${duration_ms}"
      echo
      echo "stdout:"
      emit_redacted_file "$tmp_out"
      echo
      echo "stderr:"
      emit_redacted_file "$tmp_err"
    } > "$EVIDENCE_PATH"
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    if is_success_exit_code "$exit_code"; then
      emit_status_json "success" "$exit_code" "${cmd[@]}"
    else
      emit_status_json "failed" "$exit_code" "${cmd[@]}"
    fi
  else
    if is_success_exit_code "$exit_code"; then
      emit_status_text "success" "$exit_code" "${cmd[@]}"
    else
      emit_status_text "failed" "$exit_code" "${cmd[@]}"
    fi
  fi

  return "$exit_code"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      RUNNER_MODE="${2:?missing --mode value}"
      shift 2
      ;;
    --label)
      LABEL="${2:?missing --label value}"
      shift 2
      ;;
    --run-id)
      RUN_ID="${2:?missing --run-id value}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:?missing --timeout value}"
      shift 2
      ;;
    --success-exit-codes)
      SUCCESS_EXIT_CODES="${2:?missing --success-exit-codes value}"
      shift 2
      ;;
    --format)
      OUTPUT_FORMAT="${2:?missing --format value}"
      shift 2
      ;;
    --allowlist)
      ALLOWLIST_SPEC="${2:?missing --allowlist value}"
      shift 2
      ;;
    --evidence-dir)
      EVIDENCE_DIR="${2:?missing --evidence-dir value}"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --help|-h)
      usage
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

if [[ "$RUNNER_MODE" != "execute" && "$RUNNER_MODE" != "plan" ]]; then
  echo "error: --mode must be execute or plan" >&2
  exit 2
fi

if [[ "$OUTPUT_FORMAT" != "text" && "$OUTPUT_FORMAT" != "json" ]]; then
  echo "error: --format must be text or json" >&2
  exit 2
fi

if [[ $# -eq 0 ]]; then
  echo "error: command is required" >&2
  usage
  exit 2
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(date +%Y%m%dT%H%M%S)-$$"
fi

split_allowlist

if [[ -n "${EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$EVIDENCE_DIR"
  safe_label="$(printf '%s' "$LABEL" | tr '[:space:]' '_' | tr -cd 'A-Za-z0-9._-')"
  EVIDENCE_PATH="${EVIDENCE_DIR%/}/opentofu-runner-${RUN_ID}-${safe_label}.log"
fi

COMMAND=("$@")
COMMAND_BIN="${COMMAND[0]:-}"
COMMAND_ACTION="__none__"
for (( i=1; i<${#COMMAND[@]}; i++ )); do
  if [[ "${COMMAND[i]}" == "--" ]]; then
    break
  fi
  if [[ "${COMMAND[i]}" == -* ]]; then
    continue
  fi
  COMMAND_ACTION="${COMMAND[i]}"
  break
done

if ! is_allowed_command "$COMMAND_BIN" "$COMMAND_ACTION"; then
  echo "error: command '$COMMAND_BIN $COMMAND_ACTION' is not in the allowed list" >&2
  echo "hint: configure OPENTOFU_RUNNER_ALLOWLIST for your explicit allowlist" >&2
  exit 2
fi

if [[ "$RUNNER_MODE" == "plan" ]]; then
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    emit_status_json "planned" "0" "${COMMAND[@]}"
  else
    emit_status_text "planned" "0" "${COMMAND[@]}"
  fi
  exit 0
fi

run_command "${COMMAND[@]}"
