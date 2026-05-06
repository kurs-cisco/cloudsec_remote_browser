#!/usr/bin/env bash
set -euo pipefail
set +x

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infra/terraform/aws-standalone-rbi"
DEFAULT_CONFIG="${TF_ROOT}/configs/development-ap-south-1.env"

CONFIG_FILE="${DEFAULT_CONFIG}"
CONFIG_FILE_SET=0
NAMESPACE="${RBI_CONTROL_NAMESPACE:-cloudsec-rbi-control}"
RUNTIME_SECRET_NAME="${RBI_RUNTIME_SECRET_NAME:-rbi-runtime-secret}"
POOL_SECRET_NAME="${RBI_POOL_SECRET_NAME:-rbi-worker-pool-secret}"

usage() {
  cat <<'EOF'
Sync RBI runtime Kubernetes Secrets from AWS Secrets Manager.

Usage:
  scripts/rbi-sync-k8s-secrets.sh [config-file] [options]

Options:
  --config <path>             Shell env config to source.
  --namespace <name>          Control-plane namespace. Default: cloudsec-rbi-control.
  --runtime-secret-name <n>   Runtime Kubernetes Secret name. Default: rbi-runtime-secret.
  --pool-secret-name <n>      Worker pool Kubernetes Secret name. Default: rbi-worker-pool-secret.
  -h, --help                  Show help.

Secret values are read from AWS Secrets Manager AWSCURRENT versions and written
to Kubernetes Secrets. Values are never printed and are not stored in Terraform
state.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_config_file() {
  local candidate="$1"
  local workspace_root
  workspace_root="$(cd -- "${REPO_ROOT}/.." && pwd)"

  [[ -n "${candidate}" ]] || die "empty config path"

  if [[ "${candidate}" == /* ]]; then
    printf '%s\n' "${candidate}"
  elif [[ -f "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
  elif [[ -f "${REPO_ROOT}/${candidate}" ]]; then
    printf '%s\n' "${REPO_ROOT}/${candidate}"
  elif [[ -f "${workspace_root}/${candidate}" ]]; then
    printf '%s\n' "${workspace_root}/${candidate}"
  else
    printf '%s\n' "${candidate}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || die "--config requires a path"
      CONFIG_FILE="$(resolve_config_file "$2")"
      CONFIG_FILE_SET=1
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || die "--namespace requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    --runtime-secret-name)
      [[ $# -ge 2 ]] || die "--runtime-secret-name requires a value"
      RUNTIME_SECRET_NAME="$2"
      shift 2
      ;;
    --pool-secret-name)
      [[ $# -ge 2 ]] || die "--pool-secret-name requires a value"
      POOL_SECRET_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$1" == -* ]]; then
        die "unknown argument: $1"
      fi
      [[ "${CONFIG_FILE_SET}" == "0" ]] || die "multiple config files provided: ${CONFIG_FILE} and $1"
      CONFIG_FILE="$(resolve_config_file "$1")"
      CONFIG_FILE_SET=1
      shift
      ;;
  esac
done

[[ -f "${CONFIG_FILE}" ]] || die "config file not found: ${CONFIG_FILE}"

set -a
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set +a

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-${RBI_REGION:-}}}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
export AWS_REGION AWS_DEFAULT_REGION

ROOT_DATA="${RBI_TF_REGIONAL_ROOT:-${TF_ROOT}/envs/prod/us-east-1}/data"

require_command aws
require_command base64
require_command jq
require_command kubectl
require_command mktemp
require_command terraform

[[ -n "${AWS_REGION}" ]] || die "AWS_REGION, AWS_DEFAULT_REGION, or RBI_REGION is required"

terraform_secret_arn() {
  local key="$1"
  terraform -chdir="${ROOT_DATA}" output -json secret_arns |
    jq -r --arg key "${key}" '.[$key] // empty'
}

fetch_secret_field() {
  local key="$1"
  local field="$2"
  local secret_arn secret_string value

  secret_arn="$(terraform_secret_arn "${key}")"
  [[ -n "${secret_arn}" ]] || die "missing secret ARN output for ${key}; apply the data root first"

  secret_string="$(aws secretsmanager get-secret-value \
    --profile "${AWS_PROFILE:-default}" \
    --region "${AWS_REGION}" \
    --secret-id "${secret_arn}" \
    --version-stage AWSCURRENT \
    --query SecretString \
    --output text)"

  value="$(printf '%s' "${secret_string}" | jq -r --arg field "${field}" '.[$field] // empty')"
  [[ -n "${value}" ]] || die "secret ${key} is missing required JSON field ${field}"
  printf '%s' "${value}"
}

b64() {
  base64 | tr -d '\n'
}

b64decode() {
  if base64 --decode >/dev/null 2>&1 <<< ""; then
    base64 --decode
  else
    base64 -D
  fi
}

current_runtime_secret_field() {
  local field="$1"
  local encoded

  encoded="$(kubectl -n "${NAMESPACE}" get secret "${RUNTIME_SECRET_NAME}" -o json |
    jq -r --arg field "${field}" '.data[$field] // empty')"
  [[ -n "${encoded}" ]] || return 1
  printf '%s' "${encoded}" | b64decode
}

fetch_secret_field_optional() {
  local key="$1"
  local field="$2"
  local secret_arn secret_string value

  secret_arn="$(terraform_secret_arn "${key}")"
  [[ -n "${secret_arn}" ]] || return 1

  secret_string="$(aws secretsmanager get-secret-value \
    --profile "${AWS_PROFILE:-default}" \
    --region "${AWS_REGION}" \
    --secret-id "${secret_arn}" \
    --version-stage AWSCURRENT \
    --query SecretString \
    --output text)"

  value="$(printf '%s' "${secret_string}" | jq -r --arg field "${field}" '.[$field] // empty')"
  [[ -n "${value}" ]] || return 1
  printf '%s' "${value}"
}

write_secret_manifest() {
  local output_file="$1"
  local token_secret="$2"
  local turn_shared_secret="$3"
  local swg_shared_secret="$4"
  local pool_shared_secret="$5"
  local rbi_internal_shared_secret="$6"

  {
    cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${RUNTIME_SECRET_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: cloudsec-remote-browser
    app.kubernetes.io/component: runtime-secret
    app.kubernetes.io/managed-by: rbi-sync-k8s-secrets
type: Opaque
data:
  TOKEN_SECRET: $(printf '%s' "${token_secret}" | b64)
  TURN_SHARED_SECRET: $(printf '%s' "${turn_shared_secret}" | b64)
  SWG_SHARED_SECRET: $(printf '%s' "${swg_shared_secret}" | b64)
  POOL_WORKER_SECRET: $(printf '%s' "${pool_shared_secret}" | b64)
  RBI_INTERNAL_SHARED_SECRET: $(printf '%s' "${rbi_internal_shared_secret}" | b64)
---
apiVersion: v1
kind: Secret
metadata:
  name: ${POOL_SECRET_NAME}
  namespace: cloudsec-rbi-workers
  labels:
    app.kubernetes.io/name: cloudsec-remote-browser
    app.kubernetes.io/component: worker-pool-secret
    app.kubernetes.io/managed-by: rbi-sync-k8s-secrets
type: Opaque
data:
  pool-shared-secret: $(printf '%s' "${pool_shared_secret}" | b64)
EOF
  } > "${output_file}"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rbi-k8s-secrets.XXXXXX")"
chmod 700 "${TMP_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

log "sync Kubernetes secrets"
printf 'Config: %s\n' "${CONFIG_FILE}"
printf 'AWS profile: %s\n' "${AWS_PROFILE:-<unset>}"
printf 'AWS region: %s\n' "${AWS_REGION}"
printf 'Runtime secret: %s/%s\n' "${NAMESPACE}" "${RUNTIME_SECRET_NAME}"
printf 'Pool secret: cloudsec-rbi-workers/%s\n' "${POOL_SECRET_NAME}"

token_secret="$(fetch_secret_field session_token_signing hmac_secret)"
turn_shared_secret="$(fetch_secret_field turn_shared_secret static_auth_secret)"
swg_shared_secret="$(fetch_secret_field swg_handoff_shared_secret hmac_secret)"
pool_shared_secret="$(fetch_secret_field pool_worker_shared_secret shared_secret)"
if ! rbi_internal_shared_secret="$(fetch_secret_field_optional rbi_internal_shared_secret shared_secret)"; then
  rbi_internal_shared_secret="$(current_runtime_secret_field RBI_INTERNAL_SHARED_SECRET)" ||
    die "missing rbi_internal_shared_secret output and existing ${NAMESPACE}/${RUNTIME_SECRET_NAME} RBI_INTERNAL_SHARED_SECRET"
fi

manifest="${TMP_DIR}/rbi-k8s-secrets.yaml"
write_secret_manifest "${manifest}" "${token_secret}" "${turn_shared_secret}" "${swg_shared_secret}" "${pool_shared_secret}" "${rbi_internal_shared_secret}"

kubectl apply -f "${manifest}" >/dev/null
kubectl -n "${NAMESPACE}" rollout restart deployment/runtime >/dev/null 2>&1 || true

printf 'Synced Kubernetes secrets without printing secret values.\n'
