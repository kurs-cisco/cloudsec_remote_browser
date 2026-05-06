#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infra/terraform/aws-standalone-rbi"
DEFAULT_CONFIG="${TF_ROOT}/configs/development-ap-south-1.env"

CONFIG_FILE="${DEFAULT_CONFIG}"
CONFIG_FILE_SET=0
WARN_ONLY=0

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<'EOF'
Run standalone RBI AWS preflight validation.

Usage:
  scripts/rbi-preflight.sh [config-file] [options]

Options:
  config-file       Shell env config path to source. May be absolute, relative
                    to the current directory, relative to this repo, or relative
                    to the parent workspace.
  --config <path>   Shell env config to source.
  --warn-only       Report failures as warnings and exit zero.
  -h, --help        Show help.

Checks:
  AWS caller identity, pre-existing Terraform backend, Route53 hosted zone,
  configured IAM principals, AMI placeholders and promoted SSM AMI parameters,
  ECR repositories and image artifacts, promoted SSM image digest parameters,
  and IPv4 CIDR sanity.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[PASS] %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  if [[ "${WARN_ONLY}" == "1" ]]; then
    warn "$*"
    return
  fi
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$*" >&2
}

skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  printf '[SKIP] %s\n' "$*"
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
    --warn-only)
      WARN_ONLY=1
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

EXPECTED_ACCOUNT_ID="${AWS_ACCOUNT_ID:-${RBI_ACCOUNT_ID:-}}"
ENVIRONMENT="${TF_VAR_environment:-${RBI_ENVIRONMENT:-dev}}"
PROJECT_NAME="${TF_VAR_project_name:-${RBI_PROJECT_NAME:-cloudsec-rbi}}"
ECR_REPO_PREFIX="${RBI_ECR_REPO_PREFIX:-${PROJECT_NAME}-${ENVIRONMENT}}"
IMAGE_SSM_PREFIX="${RBI_IMAGE_SSM_PREFIX:-/cloudsec-rbi/${ENVIRONMENT}/${AWS_REGION:-unknown}/images}"
TURN_AMI_PARAM="${RBI_TURN_AMI_ID_SSM_PARAMETER:-/cloudsec-rbi/${ENVIRONMENT}/${AWS_REGION:-unknown}/images/turn-ami-id}"
KATA_AMI_PARAM="${RBI_KATA_WORKER_AMI_ID_SSM_PARAMETER:-/cloudsec-rbi/${ENVIRONMENT}/${AWS_REGION:-unknown}/images/kata-worker-ami-id}"
REQUIRE_PROMOTED="${RBI_REQUIRE_PROMOTED_ARTIFACTS:-1}"
BACKEND_MODE="${TF_BACKEND_MODE:-s3}"
BACKEND_BUCKET="${RBI_TF_STATE_BUCKET:-${TF_STATE_BUCKET:-}}"
BACKEND_LOCK_TABLE="${RBI_TF_LOCK_TABLE:-${TF_LOCK_TABLE:-}}"

printf 'Config: %s\n' "${CONFIG_FILE}"
printf 'AWS profile: %s\n' "${AWS_PROFILE:-<unset>}"
printf 'AWS region: %s\n' "${AWS_REGION:-<unset>}"
printf 'Environment: %s\n\n' "${ENVIRONMENT}"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

artifact_problem() {
  if [[ "${REQUIRE_PROMOTED}" == "1" ]]; then
    fail "$*"
  else
    warn "$*"
  fi
}

aws_text() {
  aws "$@" --output text 2>/dev/null
}

is_placeholder_ami() {
  local value="${1:-}"
  [[ -z "${value}" || "${value}" == "null" || "${value}" == "ami-00000000000000000" || "${value}" == "ami-0123456789abcdef0" ]]
}

is_valid_ami_format() {
  [[ "${1:-}" =~ ^ami-[0-9a-fA-F]{8,17}$ ]]
}

is_digest_image() {
  [[ "${1:-}" == *@sha256:* ]]
}

image_repo_from_uri() {
  local uri="$1"
  local after_slash repo
  [[ "${uri}" == */* ]] || return 1
  after_slash="${uri#*/}"
  repo="${after_slash%%@*}"
  repo="${repo%%:*}"
  [[ -n "${repo}" ]] || return 1
  printf '%s\n' "${repo}"
}

image_tag_from_uri() {
  local uri="$1"
  [[ "${uri}" != *@* && "${uri}" == *:* ]] || return 1
  printf '%s\n' "${uri##*:}"
}

image_digest_from_uri() {
  local uri="$1"
  [[ "${uri}" == *@sha256:* ]] || return 1
  printf '%s\n' "${uri##*@}"
}

json_object_keys() {
  printf '%s' "${1:-}" |
    tr ',' '\n' |
    sed -nE 's/^[[:space:]]*"([^"]+)"[[:space:]]*:.*/\1/p'
}

json_list_values() {
  printf '%s' "${1:-}" |
    tr '[],' '\n\n\n' |
    sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' |
    sed '/^$/d'
}

get_ssm_parameter() {
  local name="$1"
  [[ -n "${name}" ]] || return 1
  aws ssm get-parameter \
    --name "${name}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text 2>/dev/null
}

check_aws_identity() {
  local account arn

  if ! command_exists aws; then
    fail "aws CLI is required for preflight"
    return
  fi

  if [[ -z "${AWS_REGION:-}" ]]; then
    fail "AWS_REGION, AWS_DEFAULT_REGION, or RBI_REGION is required"
    return
  fi

  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"

  if [[ -z "${account}" || "${account}" == "None" ]]; then
    fail "AWS caller identity unavailable"
    return
  fi

  if [[ -n "${EXPECTED_ACCOUNT_ID}" && "${account}" != "${EXPECTED_ACCOUNT_ID}" ]]; then
    fail "AWS account mismatch: expected ${EXPECTED_ACCOUNT_ID}, got ${account} (${arn})"
  else
    pass "AWS caller identity account=${account} arn=${arn}"
  fi

  CURRENT_ACCOUNT_ID="${account}"
}

check_backend() {
  local bucket="${BACKEND_BUCKET}"
  local lock_table="${BACKEND_LOCK_TABLE}"
  local table_status

  case "${BACKEND_MODE}" in
    s3) ;;
    local)
      skip "Terraform backend mode is local; S3 backend checks skipped"
      return
      ;;
    *)
      fail "unsupported TF_BACKEND_MODE: ${BACKEND_MODE}"
      return
      ;;
  esac

  if [[ -z "${bucket}" ]]; then
    fail "TF_STATE_BUCKET or RBI_TF_STATE_BUCKET is required when TF_BACKEND_MODE=s3"
  elif aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
    pass "Terraform state bucket exists and is accessible: ${bucket}"
  else
    fail "Terraform state bucket is missing or inaccessible: ${bucket}"
  fi

  if [[ -z "${lock_table}" ]]; then
    fail "TF_LOCK_TABLE or RBI_TF_LOCK_TABLE is required when TF_BACKEND_MODE=s3"
  elif table_status="$(aws dynamodb describe-table --table-name "${lock_table}" --query 'Table.TableStatus' --output text 2>/dev/null)" && [[ -n "${table_status}" && "${table_status}" != "None" ]]; then
    pass "Terraform lock table exists and is accessible: ${lock_table} status=${table_status}"
  else
    fail "Terraform lock table is missing or inaccessible: ${lock_table}"
  fi
}

check_route53() {
  local zone_id="${RBI_ROUTE53_ZONE_ID:-${TF_VAR_public_certificate_hosted_zone_id:-}}"
  local domain="${RBI_DOMAIN:-${TF_VAR_public_endpoint_hostname:-}}"
  local zone_name normalized_zone normalized_domain

  if [[ -z "${zone_id}" ]]; then
    fail "Route53 hosted zone ID is required for public certificate validation"
    return
  fi

  zone_name="$(aws route53 get-hosted-zone --id "${zone_id}" --query 'HostedZone.Name' --output text 2>/dev/null || true)"
  if [[ -z "${zone_name}" || "${zone_name}" == "None" ]]; then
    fail "Route53 hosted zone not found or inaccessible: ${zone_id}"
    return
  fi

  normalized_zone="${zone_name%.}"
  normalized_domain="${domain%.}"
  if [[ -n "${normalized_domain}" && "${normalized_domain}" != "${normalized_zone}" && "${normalized_domain}" != *".${normalized_zone}" ]]; then
    fail "RBI domain ${normalized_domain} is not within Route53 zone ${normalized_zone}"
  else
    pass "Route53 hosted zone ${zone_id} resolves to ${zone_name}"
  fi
}

emit_configured_iam_arns() {
  {
    printf '%s\n' "${TF_VAR_kms_admin_principal_arns:-}"
    printf '%s\n' "${TF_VAR_swg_read_role_arns:-}"
    printf '%s\n' "${TF_VAR_privatelink_allowed_principals:-}"
  } | grep -Eo 'arn:[A-Za-z0-9_-]+:iam::[0-9]{12}:(role/[^" ,]+|root)' | sort -u || true
}

check_iam_principals() {
  local arn account resource role_name found
  found=0

  while IFS= read -r arn; do
    [[ -n "${arn}" ]] || continue
    found=1
    account="$(printf '%s\n' "${arn}" | sed -E 's#arn:[^:]+:iam::([0-9]{12}):.*#\1#')"
    resource="$(printf '%s\n' "${arn}" | sed -E 's#arn:[^:]+:iam::[0-9]{12}:(.*)#\1#')"

    if [[ "${resource}" == "root" ]]; then
      pass "IAM account root principal configured: ${arn}"
      continue
    fi

    if [[ "${account}" != "${CURRENT_ACCOUNT_ID:-}" ]]; then
      warn "cross-account IAM role cannot be validated from this caller: ${arn}"
      continue
    fi

    role_name="${resource##*/}"
    if aws iam get-role --role-name "${role_name}" --query 'Role.Arn' --output text >/dev/null 2>&1; then
      pass "IAM role exists: ${arn}"
    else
      fail "IAM role missing or inaccessible: ${arn}"
    fi
  done < <(emit_configured_iam_arns)

  if [[ "${found}" == "0" ]]; then
    warn "no IAM principal ARNs found in kms, SWG read, or PrivateLink config"
  fi
}

describe_ami() {
  local ami_id="$1"
  local label="$2"
  local state

  if ! is_valid_ami_format "${ami_id}"; then
    fail "${label} AMI has invalid format: ${ami_id}"
    return
  fi

  state="$(aws ec2 describe-images --image-ids "${ami_id}" --query 'Images[0].State' --output text 2>/dev/null || true)"
  if [[ "${state}" == "available" ]]; then
    pass "${label} AMI exists and is available: ${ami_id}"
  else
    fail "${label} AMI not available in ${AWS_REGION}: ${ami_id}"
  fi
}

check_ami_with_ssm() {
  local var_name="$1"
  local param_name="$2"
  local label="$3"
  local current_value="${!var_name:-}"
  local promoted_value

  if [[ "${label}" == "TURN" && "${RBI_TURN_USE_STANDARD_AL2023_AMI:-0}" == "1" ]]; then
    skip "TURN custom AMI disabled; Terraform will select latest AL2023 and bootstrap TURN through user data"
    return
  fi

  promoted_value="$(get_ssm_parameter "${param_name}" || true)"

  if [[ -n "${promoted_value}" && "${promoted_value}" != "None" ]]; then
    if is_placeholder_ami "${promoted_value}" || ! is_valid_ami_format "${promoted_value}"; then
      fail "${label} SSM parameter is not a valid AMI ID: ${param_name}"
    else
      pass "${label} SSM AMI parameter is populated: ${param_name}"
      describe_ami "${promoted_value}" "${label} promoted"
    fi
  elif is_placeholder_ami "${current_value}"; then
    artifact_problem "${label} AMI is placeholder and SSM parameter is missing: ${param_name}"
  else
    warn "${label} SSM AMI parameter missing; config AMI will be used: ${param_name}"
  fi

  if is_placeholder_ami "${current_value}"; then
    warn "${label} config AMI is a placeholder: ${var_name}"
  else
    describe_ami "${current_value}" "${label} config"
  fi
}

check_ecr_repo() {
  local repo="$1"
  if aws ecr describe-repositories --repository-names "${repo}" --query 'repositories[0].repositoryName' --output text >/dev/null 2>&1; then
    pass "ECR repository exists: ${repo}"
  else
    fail "ECR repository missing or inaccessible: ${repo}"
  fi
}

check_ecr_image_uri() {
  local image_uri="$1"
  local label="$2"
  local repo digest tag

  repo="$(image_repo_from_uri "${image_uri}" || true)"
  if [[ -z "${repo}" ]]; then
    fail "${label} image URI is invalid: ${image_uri}"
    return
  fi

  check_ecr_repo "${repo}"

  digest="$(image_digest_from_uri "${image_uri}" || true)"
  tag="$(image_tag_from_uri "${image_uri}" || true)"

  if [[ -n "${digest}" ]]; then
    if aws ecr describe-images --repository-name "${repo}" --image-ids imageDigest="${digest}" --query 'imageDetails[0].imageDigest' --output text >/dev/null 2>&1; then
      pass "${label} image digest exists in ECR: ${repo}@${digest}"
    else
      fail "${label} image digest missing from ECR: ${repo}@${digest}"
    fi
  elif [[ -n "${tag}" ]]; then
    if aws ecr describe-images --repository-name "${repo}" --image-ids imageTag="${tag}" --query 'imageDetails[0].imageDigest' --output text >/dev/null 2>&1; then
      pass "${label} image tag exists in ECR: ${repo}:${tag}"
    else
      warn "${label} image tag missing from ECR: ${repo}:${tag}"
    fi
  else
    fail "${label} image URI is neither tag nor digest pinned: ${image_uri}"
  fi
}

check_image_with_ssm() {
  local var_name="$1"
  local param_name="$2"
  local label="$3"
  local current_value="${!var_name:-}"
  local promoted_value

  if [[ -z "${current_value}" ]]; then
    fail "${label} image variable is unset: ${var_name}"
  else
    check_ecr_image_uri "${current_value}" "${label} config"
  fi

  promoted_value="$(get_ssm_parameter "${param_name}" || true)"
  if [[ -n "${promoted_value}" && "${promoted_value}" != "None" ]]; then
    if is_digest_image "${promoted_value}"; then
      pass "${label} SSM image digest parameter is populated: ${param_name}"
      check_ecr_image_uri "${promoted_value}" "${label} promoted"
    else
      fail "${label} SSM parameter must contain an ECR digest URI: ${param_name}"
    fi
  elif is_digest_image "${current_value}"; then
    warn "${label} SSM image parameter missing; config image is already digest-pinned: ${param_name}"
  else
    artifact_problem "${label} image is not digest-pinned and SSM parameter is missing: ${param_name}"
  fi
}

check_ecr_repositories() {
  local key repo

  for key in \
    control-plane \
    session-authority \
    media-gateway \
    worker \
    file-broker \
    clipboard-broker; do
    [[ -n "${key}" ]] || continue
    repo="${ECR_REPO_PREFIX}-${key}"
    check_ecr_repo "${repo}"
  done
}

CIDR_NET=0
CIDR_BCAST=0
CIDR_MASK=0
CIDR_ALIGNED=0

cidr_to_globals() {
  local cidr="$1"
  local o1 o2 o3 o4 mask octet ip_int mask_int host_mask

  if [[ ! "${cidr}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
    return 1
  fi

  IFS='./' read -r o1 o2 o3 o4 mask <<< "${cidr}"
  for octet in "${o1}" "${o2}" "${o3}" "${o4}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    (( 10#${octet} <= 255 )) || return 1
  done

  ip_int=$(( (10#${o1} << 24) + (10#${o2} << 16) + (10#${o3} << 8) + 10#${o4} ))
  if (( mask == 0 )); then
    mask_int=0
  else
    mask_int=$(( (0xffffffff << (32 - mask)) & 0xffffffff ))
  fi
  host_mask=$(( 0xffffffff ^ mask_int ))

  CIDR_NET=$(( ip_int & mask_int ))
  CIDR_BCAST=$(( CIDR_NET | host_mask ))
  CIDR_MASK="${mask}"
  if (( ip_int == CIDR_NET )); then
    CIDR_ALIGNED=1
  else
    CIDR_ALIGNED=0
  fi
  return 0
}

cidr_contains() {
  local parent_net="$1"
  local parent_bcast="$2"
  local child_net="$3"
  local child_bcast="$4"
  (( parent_net <= child_net && parent_bcast >= child_bcast ))
}

cidr_overlaps() {
  local a_net="$1"
  local a_bcast="$2"
  local b_net="$3"
  local b_bcast="$4"
  (( a_net <= b_bcast && b_net <= a_bcast ))
}

is_documentation_cidr() {
  case "${1:-}" in
    192.0.2.*|198.51.100.*|203.0.113.*) return 0 ;;
    *) return 1 ;;
  esac
}

check_external_cidr_list() {
  local label="$1"
  local values="$2"
  local cidr

  while IFS= read -r cidr; do
    [[ -n "${cidr}" ]] || continue
    if ! cidr_to_globals "${cidr}"; then
      fail "${label} contains invalid CIDR: ${cidr}"
      continue
    fi
    if [[ "${cidr}" == "0.0.0.0/0" && "${RBI_ALLOW_OPEN_INGRESS:-0}" != "1" ]]; then
      fail "${label} must not be open to 0.0.0.0/0 without RBI_ALLOW_OPEN_INGRESS=1"
    elif is_documentation_cidr "${cidr}"; then
      fail "${label} still uses documentation/test CIDR: ${cidr}"
    else
      pass "${label} CIDR is syntactically valid: ${cidr}"
    fi
  done < <(json_list_values "${values}")
}

check_cidr_sanity() {
  local vpc="${TF_VAR_vpc_cidr:-}"
  local names=()
  local cidrs=()
  local nets=()
  local bcasts=()
  local subnet_list label cidr i j
  local vpc_net vpc_bcast

  if [[ -z "${vpc}" ]]; then
    fail "TF_VAR_vpc_cidr is required"
    return
  fi

  if ! cidr_to_globals "${vpc}"; then
    fail "VPC CIDR is invalid: ${vpc}"
    return
  fi
  vpc_net="${CIDR_NET}"
  vpc_bcast="${CIDR_BCAST}"
  [[ "${CIDR_ALIGNED}" == "1" ]] || fail "VPC CIDR is not network-aligned: ${vpc}"
  pass "VPC CIDR is valid: ${vpc}"

  for subnet_list in \
    "public:${TF_VAR_public_subnet_cidrs:-}" \
    "private:${TF_VAR_private_subnet_cidrs:-}" \
    "data:${TF_VAR_data_subnet_cidrs:-}"; do
    label="${subnet_list%%:*}"
    while IFS= read -r cidr; do
      [[ -n "${cidr}" ]] || continue
      if ! cidr_to_globals "${cidr}"; then
        fail "${label} subnet CIDR is invalid: ${cidr}"
        continue
      fi
      if [[ "${CIDR_ALIGNED}" != "1" ]]; then
        fail "${label} subnet CIDR is not network-aligned: ${cidr}"
      elif ! cidr_contains "${vpc_net}" "${vpc_bcast}" "${CIDR_NET}" "${CIDR_BCAST}"; then
        fail "${label} subnet CIDR is outside VPC ${vpc}: ${cidr}"
      else
        pass "${label} subnet CIDR is inside VPC: ${cidr}"
      fi
      names+=("${label}:${cidr}")
      cidrs+=("${cidr}")
      nets+=("${CIDR_NET}")
      bcasts+=("${CIDR_BCAST}")
    done < <(json_list_values "${subnet_list#*:}")
  done

  for (( i = 0; i < ${#cidrs[@]}; i++ )); do
    for (( j = i + 1; j < ${#cidrs[@]}; j++ )); do
      if cidr_overlaps "${nets[$i]}" "${bcasts[$i]}" "${nets[$j]}" "${bcasts[$j]}"; then
        fail "subnet CIDRs overlap: ${names[$i]} and ${names[$j]}"
      fi
    done
  done

  check_external_cidr_list "viewer ingress" "${TF_VAR_viewer_ingress_cidrs:-}"
  check_external_cidr_list "TURN client" "${TF_VAR_turn_client_cidrs:-}"
  check_external_cidr_list "EKS public access" "${TF_VAR_public_access_cidrs:-}"
}

if ! command_exists aws; then
  fail "aws CLI is required"
else
  check_aws_identity
  check_backend
  check_route53
  check_iam_principals
  check_ami_with_ssm TF_VAR_turn_ami_id "${TURN_AMI_PARAM}" "TURN"
  check_ami_with_ssm TF_VAR_kata_worker_ami_id "${KATA_AMI_PARAM}" "Kata worker"
  check_ecr_repositories
  check_image_with_ssm TF_VAR_runtime_image "${IMAGE_SSM_PREFIX}/control-plane-image-digest" "control-plane"
  check_image_with_ssm TF_VAR_session_authority_image "${IMAGE_SSM_PREFIX}/session-authority-image-digest" "session-authority"
  check_image_with_ssm TF_VAR_media_gateway_image "${IMAGE_SSM_PREFIX}/media-gateway-image-digest" "media-gateway"
  check_image_with_ssm TF_VAR_file_broker_image "${IMAGE_SSM_PREFIX}/file-broker-image-digest" "file-broker"
  check_image_with_ssm TF_VAR_clipboard_broker_image "${IMAGE_SSM_PREFIX}/clipboard-broker-image-digest" "clipboard-broker"
  check_image_with_ssm TF_VAR_worker_image "${IMAGE_SSM_PREFIX}/worker-image-digest" "worker"
fi

check_cidr_sanity

printf '\nPreflight summary: pass=%s warn=%s fail=%s skip=%s\n' "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
