#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infra/terraform/aws-standalone-rbi"
DEFAULT_CONFIG="${TF_ROOT}/configs/development-ap-south-1.env"

CONFIG_FILE="${DEFAULT_CONFIG}"

usage() {
  cat <<'EOF'
Validate SWG-to-RBI signing secret access without printing secret values.

Usage:
  scripts/rbi-validate-swg-secret-access.sh [--config <path>]

The script checks:
  - SWG-side credential secret is readable by the configured operator/profile.
  - Credential secret JSON contains AccessKeyId and SecretAccessKey.
  - Credentials stored in that secret can read the RBI handoff signing secret.
  - Handoff signing secret JSON contains kid and hmac_secret.

No access keys, HMACs, full payloads, or SecretString values are printed.
EOF
}

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

pass() {
  printf '[PASS] %s\n' "$*"
}

resolve_config_file() {
  local candidate="$1"
  local workspace_root
  workspace_root="$(cd -- "${REPO_ROOT}/.." && pwd)"

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
      shift 2
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

[[ -f "${CONFIG_FILE}" ]] || die "config file not found: ${CONFIG_FILE}"
command -v aws >/dev/null 2>&1 || die "aws CLI is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

set -a
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set +a

CREDENTIAL_PROFILE="${TF_VAR_swg_credential_secret_aws_profile:-${SWG_CREDENTIAL_SECRET_AWS_PROFILE:-}}"
CREDENTIAL_REGION="${RBI_AUTH_SIGN_AWS_CREDENTIAL_SECRET_REGION:-${TF_VAR_swg_credential_secret_region:-}}"
CREDENTIAL_SECRET_NAME="${RBI_AUTH_SIGN_AWS_CREDENTIAL_SECRET_NAME:-${TF_VAR_swg_credential_secret_name:-}}"
TARGET_REGION="${RBI_AUTH_SIGN_SECRET_REGION:-${RBI_SWG_AUTH_SIGN_SECRET_REGION:-${TF_VAR_aws_region:-}}}"
TARGET_SECRET_NAME="${RBI_AUTH_SIGN_SECRET_NAME:-${RBI_SWG_AUTH_SIGN_SECRET_NAME:-}}"

[[ -n "${CREDENTIAL_PROFILE}" ]] || die "credential secret profile is not configured"
[[ -n "${CREDENTIAL_REGION}" ]] || die "credential secret region is not configured"
[[ -n "${CREDENTIAL_SECRET_NAME}" ]] || die "credential secret name is not configured"
[[ -n "${TARGET_REGION}" ]] || die "target handoff secret region is not configured"
[[ -n "${TARGET_SECRET_NAME}" ]] || die "target handoff secret name is not configured"

printf 'Config: %s\n' "${CONFIG_FILE}"
printf 'Credential secret profile: %s\n' "${CREDENTIAL_PROFILE}"
printf 'Credential secret region: %s\n' "${CREDENTIAL_REGION}"
printf 'Credential secret name: %s\n' "${CREDENTIAL_SECRET_NAME}"
printf 'Target handoff secret region: %s\n' "${TARGET_REGION}"
printf 'Target handoff secret name: %s\n\n' "${TARGET_SECRET_NAME}"

credential_secret_json="$(
  aws secretsmanager get-secret-value \
    --profile "${CREDENTIAL_PROFILE}" \
    --region "${CREDENTIAL_REGION}" \
    --secret-id "${CREDENTIAL_SECRET_NAME}" \
    --query SecretString \
    --output text
)" || die "credential secret is not readable"

credential_fields="$(
  SECRET_JSON="${credential_secret_json}" python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ["SECRET_JSON"])
except Exception:
    print("credential secret is not valid JSON", file=sys.stderr)
    sys.exit(1)

missing = [field for field in ("AccessKeyId", "SecretAccessKey") if not payload.get(field)]
if missing:
    print("credential secret missing required field(s): " + ",".join(missing), file=sys.stderr)
    sys.exit(1)

print("has_session_token=%s" % ("yes" if payload.get("SessionToken") else "no"))
PY
)" || die "credential secret schema validation failed"
pass "credential secret is readable and has required credential fields (${credential_fields})"

embedded_access_key_id="$(
  SECRET_JSON="${credential_secret_json}" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["SECRET_JSON"])["AccessKeyId"])
PY
)"
embedded_secret_access_key="$(
  SECRET_JSON="${credential_secret_json}" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["SECRET_JSON"])["SecretAccessKey"])
PY
)"
embedded_session_token="$(
  SECRET_JSON="${credential_secret_json}" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["SECRET_JSON"]).get("SessionToken", ""))
PY
)"

if [[ -n "${embedded_session_token}" ]]; then
  target_secret_json="$(
    AWS_ACCESS_KEY_ID="${embedded_access_key_id}" \
    AWS_SECRET_ACCESS_KEY="${embedded_secret_access_key}" \
    AWS_SESSION_TOKEN="${embedded_session_token}" \
    aws secretsmanager get-secret-value \
      --region "${TARGET_REGION}" \
      --secret-id "${TARGET_SECRET_NAME}" \
      --query SecretString \
      --output text
  )" || die "embedded credentials cannot read target handoff secret"
else
  target_secret_json="$(
    AWS_ACCESS_KEY_ID="${embedded_access_key_id}" \
    AWS_SECRET_ACCESS_KEY="${embedded_secret_access_key}" \
    aws secretsmanager get-secret-value \
      --region "${TARGET_REGION}" \
      --secret-id "${TARGET_SECRET_NAME}" \
      --query SecretString \
      --output text
  )" || die "embedded credentials cannot read target handoff secret"
fi

SECRET_JSON="${target_secret_json}" python3 - <<'PY' || die "target handoff secret schema validation failed"
import json
import os
import sys

try:
    payload = json.loads(os.environ["SECRET_JSON"])
except Exception:
    print("target handoff secret is not valid JSON", file=sys.stderr)
    sys.exit(1)

missing = [field for field in ("kid", "hmac_secret") if not payload.get(field)]
if missing:
    print("target handoff secret missing required field(s): " + ",".join(missing), file=sys.stderr)
    sys.exit(1)
PY
pass "embedded credentials can read target handoff secret and required fields exist"
pass "SWG RBI signing secret access preflight passed without printing secret values"
