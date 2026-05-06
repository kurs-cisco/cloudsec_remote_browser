#!/usr/bin/env bash
set -euo pipefail
set +x

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infra/terraform/aws-standalone-rbi"
DEFAULT_CONFIG="${TF_ROOT}/configs/development-ap-south-1.env"

CONFIG_FILE="${DEFAULT_CONFIG}"
CONFIG_FILE_SET=0
FORCE=0
DRY_RUN=0
SKIP_MISSING=0
SECRET_SELECTOR="all"
GENERATE_MTLS_PRIVATE_KEY=1

SECRET_KEYS=(
  session_token_signing
  turn_shared_secret
  pool_worker_shared_secret
  rbi_internal_shared_secret
  host_agent_shared_secret
  swg_handoff_shared_secret
  mtls_client_bootstrap
)

usage() {
  cat <<'EOF'
Bootstrap initial standalone RBI Secrets Manager values outside Terraform.

Usage:
  scripts/rbi-bootstrap-secrets.sh [config-file] [options]

Options:
  config-file          Shell env config path to source. May be absolute, relative
                       to the current directory, relative to this repo, or
                       relative to the parent workspace.
  --config <path>      Shell env config to source.
  --secret <keys>      Comma-separated logical secret keys to bootstrap.
                       Default: all.
  --force              Write a new AWSCURRENT version even if one exists.
  --skip-missing       Warn instead of failing when a secret container is absent.
  --dry-run            Resolve and validate targets, but do not write versions.
  --no-mtls-key        Do not generate a client private key in mtls_client_bootstrap.
  -h, --help           Show help.

Notes:
  Terraform creates the secret containers only. This script creates secret
  versions with AWSCURRENT JSON payloads and top-level kid metadata.
  Secret values are written through temporary files and are never printed.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

log() {
  printf '\n==> %s\n' "$*"
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
    --secret|--secrets)
      [[ $# -ge 2 ]] || die "$1 requires a comma-separated value"
      SECRET_SELECTOR="$2"
      shift 2
      ;;
    --force|--rotate)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-missing)
      SKIP_MISSING=1
      shift
      ;;
    --no-mtls-key)
      GENERATE_MTLS_PRIVATE_KEY=0
      shift
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

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_command aws
require_command openssl
require_command date
require_command mktemp

[[ -n "${AWS_REGION}" ]] || die "AWS_REGION, AWS_DEFAULT_REGION, or RBI_REGION is required"

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "${value}"
}

random_b64url() {
  local bytes="$1"
  openssl rand -base64 "${bytes}" | tr '+/' '-_' | tr -d '=\n'
}

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

kid_for() {
  local key="$1"
  local env_slug key_slug
  env_slug="$(printf '%s' "${TF_VAR_environment:-${RBI_ENVIRONMENT:-env}}" | tr '_' '-' | tr -c 'A-Za-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-8)"
  key_slug="$(printf '%s' "${key}" | tr '_' '-' | tr -c 'A-Za-z0-9-' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-20)"
  env_slug="${env_slug:-env}"
  key_slug="${key_slug:-secret}"
  printf 'rbi-%s-%s-%s-%s\n' \
    "${env_slug}" \
    "${key_slug}" \
    "$(date -u '+%Y%m%d%H%M%S')" \
    "$(openssl rand -hex 6)"
}

terraform_output_map_value() {
  local output_name="$1"
  local key="$2"
  local raw

  command -v terraform >/dev/null 2>&1 || return 1
  [[ -d "${ROOT_DATA}" ]] || return 1

  if ! raw="$(terraform -chdir="${ROOT_DATA}" output -json "${output_name}" 2>/dev/null)"; then
    return 1
  fi

  printf '%s' "${raw}" |
    tr ',' '\n' |
    sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" |
    head -n 1
}

secret_env_var_name() {
  local key="$1"
  printf 'RBI_SECRET_%s_ID\n' "$(printf '%s' "${key}" | tr '[:lower:]-' '[:upper:]_')"
}

default_secret_name() {
  local key="$1"
  printf '%s/%s/data/%s\n' \
    "${TF_VAR_project_name:-${RBI_PROJECT_NAME:-cloudsec-rbi}}" \
    "${TF_VAR_environment:-${RBI_ENVIRONMENT:-dev}}" \
    "${key}"
}

resolve_secret_id() {
  local key="$1"
  local env_name env_value tf_value

  env_name="$(secret_env_var_name "${key}")"
  env_value="${!env_name:-}"
  if [[ -n "${env_value}" ]]; then
    printf '%s\n' "${env_value}"
    return 0
  fi

  tf_value="$(terraform_output_map_value secret_arns "${key}" || true)"
  if [[ -n "${tf_value}" ]]; then
    printf '%s\n' "${tf_value}"
    return 0
  fi

  tf_value="$(terraform_output_map_value secret_names "${key}" || true)"
  if [[ -n "${tf_value}" ]]; then
    printf '%s\n' "${tf_value}"
    return 0
  fi

  default_secret_name "${key}"
}

secret_selected() {
  local key="$1"
  local selector

  if [[ "${SECRET_SELECTOR}" == "all" ]]; then
    return 0
  fi

  IFS=',' read -ra selectors <<< "${SECRET_SELECTOR}"
  for selector in "${selectors[@]}"; do
    if [[ "${selector}" == "${key}" ]]; then
      return 0
    fi
  done

  return 1
}

validate_secret_selector() {
  local selector key found

  if [[ "${SECRET_SELECTOR}" == "all" ]]; then
    return
  fi

  IFS=',' read -ra selectors <<< "${SECRET_SELECTOR}"
  for selector in "${selectors[@]}"; do
    found=0
    for key in "${SECRET_KEYS[@]}"; do
      if [[ "${selector}" == "${key}" ]]; then
        found=1
        break
      fi
    done
    [[ "${found}" == "1" ]] || die "invalid --secret value: ${selector}"
  done
}

secret_exists() {
  local secret_id="$1"
  aws secretsmanager describe-secret \
    --secret-id "${secret_id}" \
    --query 'ARN' \
    --output text >/dev/null 2>&1
}

current_version_id() {
  local secret_id="$1"
  aws secretsmanager get-secret-value \
    --secret-id "${secret_id}" \
    --version-stage AWSCURRENT \
    --query 'VersionId' \
    --output text 2>/dev/null || true
}

write_payload_file() {
  local key="$1"
  local kid="$2"
  local payload_file="$3"
  local created_at="$4"
  local material realm audience private_key_file private_key_b64

  material="$(random_b64url 48)"
  realm="${RBI_TURN_REALM:-${RBI_DOMAIN:-${TF_VAR_public_endpoint_hostname:-rbi.local}}}"
  audience="${RBI_DOMAIN:-${TF_VAR_public_endpoint_hostname:-standalone-rbi}}"
  private_key_b64=""

  if [[ "${key}" == "mtls_client_bootstrap" && "${GENERATE_MTLS_PRIVATE_KEY}" == "1" ]]; then
    private_key_file="${payload_file}.key.pem"
    openssl genpkey \
      -algorithm EC \
      -pkeyopt ec_paramgen_curve:P-256 \
      -out "${private_key_file}" >/dev/null 2>&1
    private_key_b64="$(openssl base64 -A -in "${private_key_file}")"
    rm -f "${private_key_file}"
  fi

  case "${key}" in
    session_token_signing)
      cat > "${payload_file}" <<EOF
{
  "schema": "cloudsec-rbi-secret/v1",
  "kid": "$(json_escape "${kid}")",
  "secret_key": "session_token_signing",
  "use": "session-token-signing",
  "algorithm": "HS256",
  "hmac_secret": "$(json_escape "${material}")",
  "environment": "$(json_escape "${TF_VAR_environment:-${RBI_ENVIRONMENT:-}}")",
  "region": "$(json_escape "${AWS_REGION}")",
  "created_at": "$(json_escape "${created_at}")",
  "created_by": "rbi-bootstrap-secrets.sh"
}
EOF
      ;;
    turn_shared_secret)
      cat > "${payload_file}" <<EOF
{
  "schema": "cloudsec-rbi-secret/v1",
  "kid": "$(json_escape "${kid}")",
  "secret_key": "turn_shared_secret",
  "use": "turn-rest-api",
  "algorithm": "HMAC-SHA1",
  "static_auth_secret": "$(json_escape "${material}")",
  "realm": "$(json_escape "${realm}")",
  "environment": "$(json_escape "${TF_VAR_environment:-${RBI_ENVIRONMENT:-}}")",
  "region": "$(json_escape "${AWS_REGION}")",
  "created_at": "$(json_escape "${created_at}")",
  "created_by": "rbi-bootstrap-secrets.sh"
}
EOF
      ;;
    pool_worker_shared_secret)
      cat > "${payload_file}" <<EOF
{
  "schema": "cloudsec-rbi-secret/v1",
  "kid": "$(json_escape "${kid}")",
  "secret_key": "pool_worker_shared_secret",
  "use": "worker-pool-auth",
  "algorithm": "HS256",
  "shared_secret": "$(json_escape "${material}")",
  "audience": "rbi-worker-pool",
  "environment": "$(json_escape "${TF_VAR_environment:-${RBI_ENVIRONMENT:-}}")",
  "region": "$(json_escape "${AWS_REGION}")",
  "created_at": "$(json_escape "${created_at}")",
  "created_by": "rbi-bootstrap-secrets.sh"
}
EOF
      ;;
    rbi_internal_shared_secret)
      cat > "${payload_file}" <<EOF
{
  "schema": "cloudsec-rbi-secret/v1",
  "kid": "$(json_escape "${kid}")",
  "secret_key": "rbi_internal_shared_secret",
  "use": "rbi-internal-service-auth",
  "algorithm": "HS256",
  "shared_secret": "$(json_escape "${material}")",
  "audience": "rbi-control-plane",
  "environment": "$(json_escape "${TF_VAR_environment:-${RBI_ENVIRONMENT:-}}")",
  "region": "$(json_escape "${AWS_REGION}")",
  "created_at": "$(json_escape "${created_at}")",
  "created_by": "rbi-bootstrap-secrets.sh"
}
EOF
      ;;
    host_agent_shared_secret)
      cat > "${payload_file}" <<EOF
{
  "schema": "cloudsec-rbi-secret/v1",
  "kid": "$(json_escape "${kid}")",
  "secret_key": "host_agent_shared_secret",
  "use": "host-agent-auth",
  "algorithm": "HS256",
  "shared_secret": "$(json_escape "${material}")",
  "audience": "rbi-host-agent",
  "environment": "$(json_escape "${TF_VAR_environment:-${RBI_ENVIRONMENT:-}}")",
  "region": "$(json_escape "${AWS_REGION}")",
  "created_at": "$(json_escape "${created_at}")",
  "created_by": "rbi-bootstrap-secrets.sh"
}
EOF
      ;;
    swg_handoff_shared_secret)
      cat > "${payload_file}" <<EOF
{
  "schema": "cloudsec-rbi-secret/v1",
  "kid": "$(json_escape "${kid}")",
  "secret_key": "swg_handoff_shared_secret",
  "use": "swg-handoff-hmac",
  "algorithm": "HS256",
  "hmac_secret": "$(json_escape "${material}")",
  "audience": "$(json_escape "${audience}")",
  "environment": "$(json_escape "${TF_VAR_environment:-${RBI_ENVIRONMENT:-}}")",
  "region": "$(json_escape "${AWS_REGION}")",
  "created_at": "$(json_escape "${created_at}")",
  "created_by": "rbi-bootstrap-secrets.sh"
}
EOF
      ;;
    mtls_client_bootstrap)
      cat > "${payload_file}" <<EOF
{
  "schema": "cloudsec-rbi-secret/v1",
  "kid": "$(json_escape "${kid}")",
  "secret_key": "mtls_client_bootstrap",
  "use": "mtls-client-bootstrap",
  "algorithm": "ECDSA-P256",
  "bootstrap_secret": "$(json_escape "${material}")",
  "private_key_format": "$(if [[ -n "${private_key_b64}" ]]; then printf 'PKCS8_PEM_BASE64'; else printf 'not-generated'; fi)",
  "private_key_pem_b64": "$(json_escape "${private_key_b64}")",
  "audience": "$(json_escape "${audience}")",
  "environment": "$(json_escape "${TF_VAR_environment:-${RBI_ENVIRONMENT:-}}")",
  "region": "$(json_escape "${AWS_REGION}")",
  "created_at": "$(json_escape "${created_at}")",
  "created_by": "rbi-bootstrap-secrets.sh"
}
EOF
      ;;
    *)
      die "unsupported secret key: ${key}"
      ;;
  esac
}

put_secret_value() {
  local key="$1"
  local secret_id="$2"
  local payload_file="$3"
  local kid="$4"
  local version_id

  version_id="$(aws secretsmanager put-secret-value \
    --secret-id "${secret_id}" \
    --client-request-token "${kid}" \
    --secret-string "file://${payload_file}" \
    --version-stages AWSCURRENT \
    --query 'VersionId' \
    --output text)"

  printf 'WROTE %s secret_id=%s version_id=%s kid=%s\n' "${key}" "${secret_id}" "${version_id}" "${kid}"
}

validate_secret_selector

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rbi-bootstrap-secrets.XXXXXX")"
chmod 700 "${TMP_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

log "secret bootstrap config"
printf 'Config: %s\n' "${CONFIG_FILE}"
printf 'AWS profile: %s\n' "${AWS_PROFILE:-<unset>}"
printf 'AWS region: %s\n' "${AWS_REGION}"
printf 'Environment: %s\n' "${TF_VAR_environment:-${RBI_ENVIRONMENT:-<unset>}}"
printf 'Mode: %s\n' "$(if [[ "${DRY_RUN}" == "1" ]]; then printf 'dry-run'; elif [[ "${FORCE}" == "1" ]]; then printf 'force-write'; else printf 'initial-only'; fi)"

written=0
skipped=0
missing=0

for key in "${SECRET_KEYS[@]}"; do
  secret_selected "${key}" || continue

  secret_id="$(resolve_secret_id "${key}")"
  printf '\nSecret key: %s\n' "${key}"
  printf 'Secret id: %s\n' "${secret_id}"

  if ! secret_exists "${secret_id}"; then
    if [[ "${SKIP_MISSING}" == "1" ]]; then
      warn "secret container missing for ${key}: ${secret_id}"
      missing=$((missing + 1))
      continue
    fi
    die "secret container missing for ${key}: ${secret_id}. Apply the data root first or set $(secret_env_var_name "${key}")."
  fi

  existing_version="$(current_version_id "${secret_id}")"
  if [[ -n "${existing_version}" && "${existing_version}" != "None" && "${FORCE}" != "1" ]]; then
    printf 'SKIP %s existing_awscurrent_version=%s\n' "${key}" "${existing_version}"
    skipped=$((skipped + 1))
    continue
  fi

  kid="$(kid_for "${key}")"
  payload_file="${TMP_DIR}/${key}.json"
  umask 077
  write_payload_file "${key}" "${kid}" "${payload_file}" "$(now_utc)"

  if [[ "${DRY_RUN}" == "1" ]]; then
    printf 'DRY-RUN would write AWSCURRENT payload for %s kid=%s\n' "${key}" "${kid}"
    skipped=$((skipped + 1))
    continue
  fi

  put_secret_value "${key}" "${secret_id}" "${payload_file}" "${kid}"
  written=$((written + 1))
done

printf '\nBootstrap summary: written=%s skipped=%s missing=%s\n' "${written}" "${skipped}" "${missing}"
