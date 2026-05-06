#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Accept pending SWG PrivateLink endpoint connections in the RBI provider account.

Usage:
  scripts/rbi-accept-privatelink-connections.sh <config-file> [--service-id vpce-svc-...] [--endpoint-id vpce-...] [--dry-run]

The config file provides AWS_PROFILE and AWS_REGION for the RBI provider account.
If --endpoint-id is omitted, all pending endpoint connections for the service are accepted.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 ]] || {
  usage
  exit 1
}

CONFIG_FILE="$1"
shift

[[ -f "${CONFIG_FILE}" ]] || die "config file not found: ${CONFIG_FILE}"

SERVICE_ID="${RBI_PRIVATELINK_SERVICE_ID:-}"
ENDPOINT_ID=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-id)
      [[ $# -ge 2 ]] || die "--service-id requires a value"
      SERVICE_ID="$2"
      shift 2
      ;;
    --endpoint-id)
      [[ $# -ge 2 ]] || die "--endpoint-id requires a value"
      ENDPOINT_ID="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

set -a
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set +a

SERVICE_ID="${SERVICE_ID:-${TF_VAR_privatelink_service_id:-}}"
SERVICE_ID="${SERVICE_ID:-vpce-svc-0de0480bb25d09fbf}"

[[ -n "${AWS_REGION:-}" ]] || die "AWS_REGION is required"
[[ -n "${SERVICE_ID}" ]] || die "service ID is required"

if [[ -n "${ENDPOINT_ID}" ]]; then
  endpoint_ids=("${ENDPOINT_ID}")
else
  mapfile -t endpoint_ids < <(
    aws ec2 describe-vpc-endpoint-connections \
      --region "${AWS_REGION}" \
      --filters "Name=service-id,Values=${SERVICE_ID}" "Name=vpc-endpoint-state,Values=pendingAcceptance" \
      --query 'VpcEndpointConnections[].VpcEndpointId' \
      --output text | tr '\t' '\n' | sed '/^$/d'
  )
fi

if [[ "${#endpoint_ids[@]}" -eq 0 ]]; then
  printf 'No pending endpoint connections for service %s in %s.\n' "${SERVICE_ID}" "${AWS_REGION}"
  exit 0
fi

printf 'Pending endpoint connections for %s: %s\n' "${SERVICE_ID}" "${endpoint_ids[*]}"

if [[ "${DRY_RUN}" == "1" ]]; then
  printf 'Dry run only; not accepting endpoint connections.\n'
  exit 0
fi

aws ec2 accept-vpc-endpoint-connections \
  --region "${AWS_REGION}" \
  --service-id "${SERVICE_ID}" \
  --vpc-endpoint-ids "${endpoint_ids[@]}"

printf 'Accepted endpoint connections: %s\n' "${endpoint_ids[*]}"
