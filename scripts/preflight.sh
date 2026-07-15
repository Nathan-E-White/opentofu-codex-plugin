#!/usr/bin/env bash
set -euo pipefail

TOFU_BIN="${TOFU_BIN:-tofu}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SOURCE_CHECK_SCRIPT="${SCRIPT_DIR}/module-source-check.sh"
WORKSPACE=""
WORKSPACE_CHECK=1
CHECK_ONLY=0
PATH_ARG="."
MODE="readonly"
BACKEND_HINT=""
PROFILE=""
RUN_ID="${OPENTOFU_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$$}"
ARTIFACT_DIR="${OPENTOFU_ARTIFACT_DIR:-.tofu-artifacts}"
ALLOW_STATE_WRITE="${ALLOW_STATE_WRITE:-0}"
STATE_COMMAND=""
EXPECTED_WORKSPACE="${OPENTOFU_EXPECTED_WORKSPACE:-}"
EXPECTED_BACKEND_HINT="${OPENTOFU_EXPECTED_BACKEND_HINT:-}"
MODULE_SOURCE_CHECK="${OPENTOFU_MODULE_SOURCE_CHECK:-1}"
MODULE_EXCEPTION_FILE="${OPENTOFU_MODULE_EXCEPTION_FILE:-}"
MODULE_CHECKSUM_FILE="${OPENTOFU_MODULE_CHECKSUM_FILE:-}"
DEPRECATED_MODULE_SOURCE_FILE="${OPENTOFU_DEPRECATED_MODULE_SOURCE_FILE:-}"

print_usage() {
  cat <<'USAGE'
Usage: preflight.sh [--path <dir>] [--workspace <name>] [--no-workspace-check] [--backend-config <file>] [--state-command <command>] [--expected-workspace <name>] [--expected-backend <path>] [--check-only] [--mode readonly|mutating] [--profile dev|stg|prod] [--run-id <id>] [--artifact-dir <dir>] [--module-exception-file <path>] [--module-checksum-file <path>] [--deprecated-module-source-file <path>]
Runs checks before OpenTofu operations.
USAGE
}

has_remote_backend_decl() {
  local search_dir="$1"
  local remote

  remote="$(grep -R -n --include='*.tf' --include='*.tf.json' -E 'backend\\s+"(s3|gcs|azurerm|consul|etcd|http|pg|remote)"' "$search_dir" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$remote" ]]; then
    return 0
  fi
  return 1
}

state_profile_is_strict() {
  if [[ "$PROFILE" == "stg" || "$PROFILE" == "prod" || "${OPENTOFU_MODE:-}" == "enterprise" ]]; then
    return 0
  fi
  return 1
}

state_op_is_mutating() {
  local cmd="$1"

  case "$cmd" in
    state\ rm|state\ rm\ *|rm|rm\ *)
      return 0
      ;;
    state\ mv|state\ mv\ *|mv|mv\ *)
      return 0
      ;;
    state\ show|state\ show\ *|show|show\ *)
      if state_profile_is_strict; then
        return 0
      fi
      ;;
  esac
  return 1
}

enforce_state_write_rules() {
  if [[ -z "$STATE_COMMAND" ]]; then
    return 0
  fi

  if ! state_op_is_mutating "$STATE_COMMAND"; then
    return 0
  fi

  if [[ "$ALLOW_STATE_WRITE" != "1" ]]; then
    echo "error: state command '$STATE_COMMAND' requires explicit write approval in profile='${PROFILE:-dev}'." >&2
    echo "error: set ALLOW_STATE_WRITE=1 to continue (or set OPENTOFU_APPROVAL_TOKEN and route through documented approval workflow)." >&2
    echo "error: required context: workspace=${WORKSPACE:-unset}, backend=${BACKEND_HINT:-unset}." >&2
    return 1
  fi

  if [[ -n "$EXPECTED_WORKSPACE" ]]; then
    if [[ -z "$WORKSPACE" ]]; then
      echo "error: expected workspace '${EXPECTED_WORKSPACE}' but no workspace was provided." >&2
      return 1
    fi
    if [[ "$WORKSPACE" != "$EXPECTED_WORKSPACE" ]]; then
      echo "error: workspace context mismatch (expected='${EXPECTED_WORKSPACE}', actual='${WORKSPACE}')." >&2
      return 1
    fi
  fi

  if [[ -n "$EXPECTED_BACKEND_HINT" ]]; then
    if [[ -z "$BACKEND_HINT" ]]; then
      echo "error: expected backend context '${EXPECTED_BACKEND_HINT}' but no backend config was provided." >&2
      return 1
    fi
    if [[ "$BACKEND_HINT" != "$EXPECTED_BACKEND_HINT" ]]; then
      echo "error: backend context mismatch (expected='${EXPECTED_BACKEND_HINT}', actual='${BACKEND_HINT}')." >&2
      return 1
    fi
  fi
}

run_module_source_check() {
  local module_profile="${PROFILE:-dev}"
  local module_cmd=(bash "$MODULE_SOURCE_CHECK_SCRIPT" --path "$TOFU_DIR" --profile "$module_profile" --mode "$MODE" --run-id "$RUN_ID" --artifact-dir "$ARTIFACT_DIR")

  if [[ "$MODULE_SOURCE_CHECK" == "0" ]]; then
    echo "preflight: module source check disabled"
    return 0
  fi

  if [[ ! -f "$MODULE_SOURCE_CHECK_SCRIPT" ]]; then
    echo "warning: module source check script missing: $MODULE_SOURCE_CHECK_SCRIPT"
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

  echo "preflight: module source sanity check"
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
      BACKEND_HINT="${2:?missing --backend value}"
      shift 2
      ;;
    --no-workspace-check)
      WORKSPACE_CHECK=0
      shift
      ;;
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    --mode)
      MODE="${2:?missing --mode value}"
      shift 2
      ;;
    --profile)
      PROFILE="${2:?missing --profile value}"
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
    --state-command)
      STATE_COMMAND="${2:?missing --state-command value}"
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
  echo "Install OpenTofu and re-run." >&2
  exit 127
fi

TOFU_DIR="$(cd "$PATH_ARG" && pwd)"
printf 'preflight: path=%s\n' "$TOFU_DIR"
printf 'preflight: tofu=%s\n' "$TOFU_BIN"
"$TOFU_BIN" version

if [[ -n "$WORKSPACE" ]]; then
  echo "preflight: requested workspace=$WORKSPACE"
else
  echo "preflight: no workspace requested"
fi

if [[ -n "$BACKEND_HINT" ]]; then
  echo "preflight: backend hint=$BACKEND_HINT"
fi

if [[ -n "$STATE_COMMAND" ]]; then
  echo "preflight: state-command=$STATE_COMMAND"
fi
if [[ -n "$EXPECTED_WORKSPACE" ]]; then
  echo "preflight: expected workspace=$EXPECTED_WORKSPACE"
fi
if [[ -n "$EXPECTED_BACKEND_HINT" ]]; then
  echo "preflight: expected backend=$EXPECTED_BACKEND_HINT"
fi
echo "preflight: run_id=$RUN_ID"
echo "preflight: artifact_dir=$ARTIFACT_DIR"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "preflight: check-only mode enabled"
fi

if [[ "$MODE" == "mutating" ]]; then
  echo "preflight: mutation mode enabled"
else
  echo "preflight: mutation mode = readonly"
fi

if [[ ! -w "$TOFU_DIR" ]]; then
  echo "warning: '$TOFU_DIR' is not writable; writes may fail later"
fi

if [[ -n "$PROFILE" && "$PROFILE" != "dev" && "$PROFILE" != "stg" && "$PROFILE" != "prod" ]]; then
  echo "error: --profile must be one of dev, stg, or prod" >&2
  exit 2
fi

run_module_source_check

if [[ "$MODE" == "mutating" ]]; then
  enforce_state_write_rules
  echo "preflight: safety envelope for mutating operation enabled"
  if has_remote_backend_decl "$TOFU_DIR"; then
    if [[ -z "$BACKEND_HINT" ]]; then
      echo "error: mutating command with remote backend detected; pass --backend-config with workspace target context." >&2
      exit 1
    fi
    if [[ -z "$WORKSPACE" ]]; then
      echo "warning: remote backend detected but no workspace was provided. Use --workspace when mutating remote state."
    fi
  fi
fi

if [[ -f "$TOFU_DIR/.terraform-version" ]]; then
  echo "warning: legacy .terraform-version file detected"
fi

if [[ -f "$TOFU_DIR/.opentofu-version" ]]; then
  echo "note: .opentofu-version file exists"
fi

if [[ -f "$TOFU_DIR/.terraform.lock.hcl" || -f "$TOFU_DIR/terraform.lock.hcl" ]]; then
  echo "note: lock file exists; verify it matches target providers."
fi

if ! (find "$TOFU_DIR" -maxdepth 1 -type f \( -name '*.tf' -o -name '*.tf.json' \) -print -quit | read -r _); then
  echo "warning: no obvious terraform files in '$TOFU_DIR'"
fi

if [[ "$WORKSPACE_CHECK" -eq 1 && -n "$WORKSPACE" ]]; then
  if WORKSPACE_LIST=$("$TOFU_BIN" -chdir="$TOFU_DIR" workspace list 2>/dev/null); then
    if printf '%s\n' "$WORKSPACE_LIST" | sed 's/^\* //;s/[[:space:]]*$//' | grep -Fxq "$WORKSPACE"; then
      echo "preflight: workspace '$WORKSPACE' exists"
    else
      echo "warning: workspace '$WORKSPACE' not found in current state"
    fi
  else
    echo "warning: could not read workspace list (state may not be initialized)"
  fi
fi

if [[ "$MODE" == "mutating" ]]; then
  echo "preflight: mutating-mode lockfile check"
  if ! "$TOFU_BIN" fmt -recursive -check >/tmp/opentofu-fmt.$$ 2>&1; then
    cat /tmp/opentofu-fmt.$$ >&2
    rm -f /tmp/opentofu-fmt.$$
    echo "preflight: lockfile-style formatting drift found" >&2
    exit 1
  fi
  rm -f /tmp/opentofu-fmt.$$
  if ! "$TOFU_BIN" init -input=false >/tmp/opentofu-init.$$ 2>&1; then
    cat /tmp/opentofu-init.$$ >&2
    rm -f /tmp/opentofu-init.$$
    echo "preflight: init failed in mutating mode" >&2
    exit 1
  fi
  rm -f /tmp/opentofu-init.$$
fi

echo "preflight: complete"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  exit 0
fi
