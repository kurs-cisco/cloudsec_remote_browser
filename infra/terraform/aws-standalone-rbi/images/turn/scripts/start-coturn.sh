#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="${LOG_PREFIX:-cloudsec-rbi-turn}"
COTURN_IMAGE="${COTURN_IMAGE:-coturn/coturn:4.6}"
TURN_REALM="${TURN_REALM:-${RBI_DOMAIN:-cloudsec-rbi.local}}"
TURN_PORT="${TURN_PORT:-3478}"
TURN_TLS_PORT="${TURN_TLS_PORT:-443}"
TURN_MIN_PORT="${TURN_MIN_PORT:-49152}"
TURN_MAX_PORT="${TURN_MAX_PORT:-65535}"
TURN_LISTENING_IP="${TURN_LISTENING_IP:-0.0.0.0}"
TURN_EXTERNAL_IP="${TURN_EXTERNAL_IP:-}"
TURN_SHARED_SECRET="${TURN_SHARED_SECRET:-}"
TURN_SHARED_SECRET_SSM_PARAMETER="${TURN_SHARED_SECRET_SSM_PARAMETER:-}"
TURN_SHARED_SECRET_SECRET_ID="${TURN_SHARED_SECRET_SECRET_ID:-}"
TURN_SHARED_SECRET_JSON_KEY="${TURN_SHARED_SECRET_JSON_KEY:-static_auth_secret}"
TURN_TLS_CERT_PATH="${TURN_TLS_CERT_PATH:-}"
TURN_TLS_KEY_PATH="${TURN_TLS_KEY_PATH:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

log() {
  printf '[%s] %s\n' "${LOG_PREFIX}" "$*"
}

fatal() {
  log "ERROR: $*"
  exit 1
}

metadata_token() {
  curl -fsS -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true
}

metadata_get() {
  local path="$1"
  local token="${2:-}"

  if [[ -n "${token}" ]]; then
    curl -fsS -H "X-aws-ec2-metadata-token: ${token}" "http://169.254.169.254/latest/${path}" 2>/dev/null || true
  else
    curl -fsS "http://169.254.169.254/latest/${path}" 2>/dev/null || true
  fi
}

detect_region() {
  local token="$1"
  local doc
  doc="$(metadata_get dynamic/instance-identity/document "${token}")"
  printf '%s\n' "${doc}" | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

fetch_ssm_parameter() {
  local name="$1"
  aws ssm get-parameter \
    --name "${name}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text
}

fetch_secret_string() {
  local secret_id="$1"
  aws secretsmanager get-secret-value \
    --secret-id "${secret_id}" \
    --query 'SecretString' \
    --output text
}

extract_secret_material() {
  local secret_string="$1"

  if [[ "${secret_string}" == \{* ]]; then
    command -v jq >/dev/null 2>&1 || fatal "jq is required to parse JSON secret payloads"
    printf '%s\n' "${secret_string}" |
      jq -r --arg key "${TURN_SHARED_SECRET_JSON_KEY}" '.[$key] // .static_auth_secret // .secret // .shared_secret // .hmac_secret // empty'
    return
  fi

  printf '%s\n' "${secret_string}"
}

resolve_shared_secret() {
  local secret_string

  if [[ -n "${TURN_SHARED_SECRET}" ]]; then
    log "using TURN_SHARED_SECRET from environment; prefer SSM or Secrets Manager for managed hosts"
    printf '%s\n' "${TURN_SHARED_SECRET}"
    return
  fi

  if [[ -n "${TURN_SHARED_SECRET_SSM_PARAMETER}" ]]; then
    secret_string="$(fetch_ssm_parameter "${TURN_SHARED_SECRET_SSM_PARAMETER}")"
    extract_secret_material "${secret_string}"
    return
  fi

  if [[ -n "${TURN_SHARED_SECRET_SECRET_ID}" ]]; then
    secret_string="$(fetch_secret_string "${TURN_SHARED_SECRET_SECRET_ID}")"
    extract_secret_material "${secret_string}"
    return
  fi

  fatal "set TURN_SHARED_SECRET_SSM_PARAMETER or TURN_SHARED_SECRET_SECRET_ID"
}

resolve_external_ip() {
  local token="$1"
  local public_ip local_ip

  if [[ -n "${TURN_EXTERNAL_IP}" ]]; then
    printf '%s\n' "${TURN_EXTERNAL_IP}"
    return
  fi

  public_ip="$(metadata_get meta-data/public-ipv4 "${token}")"
  local_ip="$(metadata_get meta-data/local-ipv4 "${token}")"
  if [[ -n "${public_ip}" && -n "${local_ip}" && "${public_ip}" != "${local_ip}" ]]; then
    printf '%s/%s\n' "${public_ip}" "${local_ip}"
    return
  fi

  if [[ -z "${public_ip}" ]]; then
    public_ip="${local_ip}"
    log "public IPv4 not present; using local IPv4 for external-ip"
  fi

  [[ -n "${public_ip}" ]] || fatal "could not resolve public or local IPv4 from IMDS"
  printf '%s\n' "${public_ip}"
}

main() {
  local token public_ip shared_secret
  local tls_args=()

  token="$(metadata_token)"
  if [[ -z "${AWS_REGION}" ]]; then
    AWS_REGION="$(detect_region "${token}")"
    export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"
  fi
  [[ -n "${AWS_REGION}" ]] || fatal "AWS_REGION is required to fetch runtime secrets"

  public_ip="$(resolve_external_ip "${token}")"
  shared_secret="$(resolve_shared_secret)"
  [[ -n "${shared_secret}" && "${shared_secret}" != "None" ]] || fatal "resolved TURN shared secret is empty"

  if [[ -n "${TURN_TLS_CERT_PATH}" || -n "${TURN_TLS_KEY_PATH}" ]]; then
    [[ -r "${TURN_TLS_CERT_PATH}" && -r "${TURN_TLS_KEY_PATH}" ]] || fatal "TURN TLS cert/key paths are not readable"
    tls_args=(--tls-listening-port="${TURN_TLS_PORT}" --cert="${TURN_TLS_CERT_PATH}" --pkey="${TURN_TLS_KEY_PATH}")
  else
    tls_args=(--tls-listening-port="${TURN_TLS_PORT}")
  fi

  systemctl start docker
  docker pull "${COTURN_IMAGE}"
  docker rm -f coturn >/dev/null 2>&1 || true

  log "starting coturn image=${COTURN_IMAGE} realm=${TURN_REALM} external_ip=${public_ip} port=${TURN_PORT}"
  docker run --rm \
    --name coturn \
    --network host \
    "${COTURN_IMAGE}" \
    -n \
    --log-file=stdout \
    --external-ip="${public_ip}" \
    --listening-ip="${TURN_LISTENING_IP}" \
    --listening-port="${TURN_PORT}" \
    --realm="${TURN_REALM}" \
    --use-auth-secret \
    --static-auth-secret="${shared_secret}" \
    --fingerprint \
    --stale-nonce \
    "${tls_args[@]}" \
    --min-port="${TURN_MIN_PORT}" \
    --max-port="${TURN_MAX_PORT}" \
    --no-cli
}

main "$@"
