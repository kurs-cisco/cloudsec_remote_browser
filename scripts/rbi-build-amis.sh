#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLOUDSEC_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
WORKSPACE_DIR="$(cd -- "${CLOUDSEC_DIR}/.." && pwd -P)"
IMAGES_DIR="${CLOUDSEC_DIR}/infra/terraform/aws-standalone-rbi/images"
DEFAULT_CONFIG="infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env"

CONFIG_PATH="${RBI_CONFIG_PATH:-${DEFAULT_CONFIG}}"
COMPONENT="all"
MODE="build"
ARTIFACT_DIR="${IMAGES_DIR}/artifacts"
ARTIFACT_ENV=""
TURN_AMI_ID="${RBI_TURN_AMI_ID:-}"
KATA_AMI_ID="${RBI_KATA_WORKER_AMI_ID:-}"
TURN_AMI_SKIPPED=0
PACKER_EXTRA_ARGS=()

log() {
  printf '[rbi-build-amis] %s\n' "$*"
}

fatal() {
  printf '[rbi-build-amis] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: rbi-build-amis.sh [config.env] [options]

Build and/or promote standalone RBI TURN and Kata worker AMIs.

Options:
  --config PATH             Shell env file to source.
  --component all|turn|kata Component to process. Default: all.
  --mode MODE               build, promote, or build-promote. Default: build.
  --build                   Alias for --mode build.
  --promote                 Alias for --mode promote.
  --build-promote           Alias for --mode build-promote.
  --artifact-dir DIR        Directory for build logs and artifact env files.
  --artifact-env FILE       Env file containing/promoted AMI IDs.
  --turn-ami-id AMI         Existing TURN AMI ID for promote mode.
  --kata-ami-id AMI         Existing Kata worker AMI ID for promote mode.
  --packer-var KEY=VALUE    Extra Packer -var value. May be repeated.
  -h, --help                Show this help.

Promotion defaults match manage-rbi-env.sh:
  /cloudsec-rbi/<env>/<region>/images/turn-ami-id
  /cloudsec-rbi/<env>/<region>/images/kata-worker-ami-id
EOF
}

abs_path() {
  local path="$1"
  local dir base
  dir="$(cd -- "$(dirname -- "${path}")" && pwd -P)"
  base="$(basename -- "${path}")"
  printf '%s/%s\n' "${dir}" "${base}"
}

resolve_path() {
  local input="$1"
  local candidate
  for candidate in \
    "${input}" \
    "${CLOUDSEC_DIR}/${input}" \
    "${WORKSPACE_DIR}/${input}"
  do
    if [[ -f "${candidate}" ]]; then
      abs_path "${candidate}"
      return
    fi
  done
  fatal "file not found: ${input}"
}

hcl_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

shell_string() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "${value}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || fatal "--config requires a path"
        CONFIG_PATH="$2"
        shift 2
        ;;
      --component)
        [[ $# -ge 2 ]] || fatal "--component requires a value"
        COMPONENT="$2"
        shift 2
        ;;
      --mode)
        [[ $# -ge 2 ]] || fatal "--mode requires a value"
        MODE="$2"
        shift 2
        ;;
      --build)
        MODE="build"
        shift
        ;;
      --promote)
        MODE="promote"
        shift
        ;;
      --build-promote)
        MODE="build-promote"
        shift
        ;;
      --artifact-dir)
        [[ $# -ge 2 ]] || fatal "--artifact-dir requires a directory"
        ARTIFACT_DIR="$2"
        shift 2
        ;;
      --artifact-env)
        [[ $# -ge 2 ]] || fatal "--artifact-env requires a file"
        ARTIFACT_ENV="$2"
        shift 2
        ;;
      --turn-ami-id)
        [[ $# -ge 2 ]] || fatal "--turn-ami-id requires an AMI ID"
        TURN_AMI_ID="$2"
        shift 2
        ;;
      --kata-ami-id|--kata-worker-ami-id)
        [[ $# -ge 2 ]] || fatal "$1 requires an AMI ID"
        KATA_AMI_ID="$2"
        shift 2
        ;;
      --packer-var)
        [[ $# -ge 2 ]] || fatal "--packer-var requires KEY=VALUE"
        PACKER_EXTRA_ARGS+=("-var" "$2")
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        fatal "unknown option: $1"
        ;;
      *)
        CONFIG_PATH="$1"
        shift
        ;;
    esac
  done
}

validate_selection() {
  case "${COMPONENT}" in
    all|turn|kata) ;;
    *) fatal "--component must be all, turn, or kata" ;;
  esac

  case "${MODE}" in
    build|promote|build-promote) ;;
    *) fatal "--mode must be build, promote, or build-promote" ;;
  esac
}

component_requested() {
  [[ "${COMPONENT}" == "all" || "${COMPONENT}" == "$1" ]]
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || fatal "missing required command: ${cmd}"
  done
}

load_config() {
  local resolved
  resolved="$(resolve_path "${CONFIG_PATH}")"
  log "sourcing config ${resolved}"
  set -a
  # shellcheck source=/dev/null
  source "${resolved}"
  set +a
}

init_context() {
  AWS_REGION="${AWS_REGION:-${RBI_REGION:-${AWS_DEFAULT_REGION:-}}}"
  [[ -n "${AWS_REGION}" ]] || fatal "AWS_REGION or RBI_REGION is required"
  AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
  export AWS_REGION AWS_DEFAULT_REGION

  if [[ -z "${RBI_AMI_BUILD_SECURITY_GROUP_ID:-}" && -z "${RBI_AMI_BUILD_SSH_SOURCE_CIDRS:-}" ]]; then
    [[ -n "${RBI_PUBLIC_INGRESS_CIDR:-}" ]] || fatal "RBI_AMI_BUILD_SSH_SOURCE_CIDRS or RBI_PUBLIC_INGRESS_CIDR is required when Packer creates a temporary SSH security group"
    RBI_AMI_BUILD_SSH_SOURCE_CIDRS="[\"${RBI_PUBLIC_INGRESS_CIDR}\"]"
  fi

  RBI_ENV="${TF_VAR_environment:-${RBI_ENVIRONMENT:-dev}}"
  RBI_PROJECT="${TF_VAR_project_name:-${RBI_PROJECT_NAME:-cloudsec-rbi}}"
  RBI_AMI_BUILD_ID="${RBI_AMI_BUILD_ID:-$(date -u '+%Y%m%d%H%M%S')}"
  RBI_AMI_NAME_PREFIX="${RBI_AMI_NAME_PREFIX:-${RBI_PROJECT}-${AWS_REGION}}"

  TURN_SSM_PARAMETER="${RBI_TURN_AMI_ID_SSM_PARAMETER:-/cloudsec-rbi/${RBI_ENV}/${AWS_REGION}/images/turn-ami-id}"
  KATA_SSM_PARAMETER="${RBI_KATA_WORKER_AMI_ID_SSM_PARAMETER:-/cloudsec-rbi/${RBI_ENV}/${AWS_REGION}/images/kata-worker-ami-id}"

  mkdir -p "${ARTIFACT_DIR}"
  if [[ -z "${ARTIFACT_ENV}" ]]; then
    ARTIFACT_ENV="${ARTIFACT_DIR}/rbi-ami-artifacts.env"
  fi
}

write_packer_vars() {
  local component="$1"
  local file="$2"

  {
    printf 'region = %s\n' "$(hcl_string "${AWS_REGION}")"
    printf 'profile = %s\n' "$(hcl_string "${AWS_PROFILE:-}")"
    printf 'project_name = %s\n' "$(hcl_string "${RBI_PROJECT}")"
    printf 'environment = %s\n' "$(hcl_string "${RBI_ENV}")"
    printf 'build_id = %s\n' "$(hcl_string "${RBI_AMI_BUILD_ID}")"
    printf 'ami_name_prefix = %s\n' "$(hcl_string "${RBI_AMI_NAME_PREFIX}")"
    printf 'subnet_id = %s\n' "$(hcl_string "${RBI_AMI_BUILD_SUBNET_ID:-}")"
    printf 'security_group_id = %s\n' "$(hcl_string "${RBI_AMI_BUILD_SECURITY_GROUP_ID:-}")"
    printf 'temporary_security_group_source_cidrs = %s\n' "${RBI_AMI_BUILD_SSH_SOURCE_CIDRS:-[]}"
    printf 'associate_public_ip_address = %s\n' "${RBI_AMI_BUILD_ASSOCIATE_PUBLIC_IP:-true}"
  } >"${file}"

  case "${component}" in
    turn)
      {
        printf 'instance_type = %s\n' "$(hcl_string "${RBI_TURN_AMI_BUILD_INSTANCE_TYPE:-t3.small}")"
        printf 'source_ami_name_filter = %s\n' "$(hcl_string "${RBI_TURN_SOURCE_AMI_NAME_FILTER:-al2023-ami-2023.*-x86_64}")"
        printf 'coturn_image = %s\n' "$(hcl_string "${RBI_COTURN_IMAGE:-coturn/coturn:4.6}")"
        printf 'turn_default_realm = %s\n' "$(hcl_string "${RBI_TURN_REALM:-${RBI_DOMAIN:-cloudsec-rbi.local}}")"
        printf 'turn_port = %s\n' "${RBI_TURN_PORT:-3478}"
        printf 'turn_tls_port = %s\n' "${RBI_TURN_TLS_PORT:-443}"
        printf 'turn_min_port = %s\n' "${RBI_TURN_MIN_PORT:-49152}"
        printf 'turn_max_port = %s\n' "${RBI_TURN_MAX_PORT:-65535}"
        printf 'output_ssm_parameter = %s\n' "$(hcl_string "${TURN_SSM_PARAMETER}")"
      } >>"${file}"
      ;;
    kata)
      {
        printf 'instance_type = %s\n' "$(hcl_string "${RBI_KATA_AMI_BUILD_INSTANCE_TYPE:-${TF_VAR_kata_worker_instance_type:-c5.metal}}")"
        printf 'eks_version = %s\n' "$(hcl_string "${TF_VAR_cluster_version:-1.31}")"
        printf 'source_ami_name_filter = %s\n' "$(hcl_string "${RBI_KATA_SOURCE_AMI_NAME_FILTER:-}")"
        printf 'kata_rpm_urls = %s\n' "$(hcl_string "${RBI_KATA_RPM_URLS:-}")"
        printf 'kata_static_tarball_url = %s\n' "$(hcl_string "${RBI_KATA_STATIC_TARBALL_URL:-}")"
        printf 'cloud_hypervisor_rpm_url = %s\n' "$(hcl_string "${RBI_CLOUD_HYPERVISOR_RPM_URL:-}")"
        printf 'cloud_hypervisor_binary_url = %s\n' "$(hcl_string "${RBI_CLOUD_HYPERVISOR_BINARY_URL:-}")"
        printf 'validate_kvm = %s\n' "${RBI_KATA_VALIDATE_KVM:-true}"
        printf 'output_ssm_parameter = %s\n' "$(hcl_string "${KATA_SSM_PARAMETER}")"
      } >>"${file}"
      ;;
  esac
}

extract_ami_id() {
  local log_file="$1"
  local artifact_id
  artifact_id="$(awk -F, '/artifact,0,id/ { id=$NF } END { print id }' "${log_file}")"
  artifact_id="${artifact_id##*:}"
  [[ "${artifact_id}" == ami-* ]] || return 1
  printf '%s\n' "${artifact_id}"
}

build_component() {
  local component="$1"
  local template_path
  local var_file="${ARTIFACT_DIR}/${component}.pkrvars.hcl"
  local log_file="${ARTIFACT_DIR}/${component}-packer.log"
  local ami_id

  require_cmd packer
  case "${component}" in
    turn)
      template_path="${IMAGES_DIR}/turn/turn.pkr.hcl"
      ;;
    kata)
      template_path="${IMAGES_DIR}/kata/kata-al2023.pkr.hcl"
      ;;
    *)
      fatal "unsupported AMI component: ${component}"
      ;;
  esac

  write_packer_vars "${component}" "${var_file}"

  log "initializing Packer ${component} template"
  packer init "${template_path}"

  log "building ${component} AMI"
  AWS_POLL_DELAY_SECONDS="${RBI_AMI_AWS_POLL_DELAY_SECONDS:-10}" \
    AWS_MAX_ATTEMPTS="${RBI_AMI_AWS_MAX_ATTEMPTS:-180}" \
    packer build -machine-readable -var-file="${var_file}" "${PACKER_EXTRA_ARGS[@]}" "${template_path}" | tee "${log_file}"

  ami_id="$(extract_ami_id "${log_file}")" || fatal "could not parse AMI ID from ${log_file}"

  case "${component}" in
    turn)
      TURN_AMI_ID="${ami_id}"
      ;;
    kata)
      KATA_AMI_ID="${ami_id}"
      ;;
  esac

  log "${component} AMI built: ${ami_id}"
}

load_artifact_env() {
  [[ -f "${ARTIFACT_ENV}" ]] || return 0
  log "loading artifact env ${ARTIFACT_ENV}"
  set -a
  # shellcheck source=/dev/null
  source "${ARTIFACT_ENV}"
  set +a
  TURN_AMI_ID="${TURN_AMI_ID:-${RBI_TURN_AMI_ID:-}}"
  KATA_AMI_ID="${KATA_AMI_ID:-${RBI_KATA_WORKER_AMI_ID:-}}"
  TURN_SSM_PARAMETER="${RBI_TURN_AMI_ID_SSM_PARAMETER:-${TURN_SSM_PARAMETER}}"
  KATA_SSM_PARAMETER="${RBI_KATA_WORKER_AMI_ID_SSM_PARAMETER:-${KATA_SSM_PARAMETER}}"
}

write_artifact_env() {
  : >"${ARTIFACT_ENV}"

  if component_requested turn && [[ "${TURN_AMI_SKIPPED}" != "1" ]]; then
    {
      printf 'export RBI_TURN_AMI_ID=%s\n' "$(shell_string "${TURN_AMI_ID}")"
      printf 'export RBI_TURN_AMI_ID_SSM_PARAMETER=%s\n' "$(shell_string "${TURN_SSM_PARAMETER}")"
    } >>"${ARTIFACT_ENV}"
  fi

  if component_requested kata; then
    {
      printf 'export RBI_KATA_WORKER_AMI_ID=%s\n' "$(shell_string "${KATA_AMI_ID}")"
      printf 'export RBI_KATA_WORKER_AMI_ID_SSM_PARAMETER=%s\n' "$(shell_string "${KATA_SSM_PARAMETER}")"
    } >>"${ARTIFACT_ENV}"
  fi

  log "wrote artifact env ${ARTIFACT_ENV}"
}

put_ssm() {
  local name="$1"
  local value="$2"
  [[ -n "${value}" ]] || fatal "empty value for ${name}"
  require_cmd aws
  aws ssm put-parameter \
    --name "${name}" \
    --type String \
    --value "${value}" \
    --overwrite >/dev/null
  log "promoted ${value} to ${name}"
}

promote_artifacts() {
  if component_requested turn && [[ "${TURN_AMI_SKIPPED}" != "1" ]]; then
    [[ "${TURN_AMI_ID}" == ami-* ]] || fatal "TURN AMI ID is required for promotion"
    put_ssm "${TURN_SSM_PARAMETER}" "${TURN_AMI_ID}"
  fi

  if component_requested kata; then
    [[ "${KATA_AMI_ID}" == ami-* ]] || fatal "Kata worker AMI ID is required for promotion"
    put_ssm "${KATA_SSM_PARAMETER}" "${KATA_AMI_ID}"
  fi
}

main() {
  parse_args "$@"
  validate_selection
  load_config
  init_context

  if [[ "${MODE}" == "promote" ]]; then
    load_artifact_env
    promote_artifacts
    return
  fi

  : >"${ARTIFACT_ENV}"

  if component_requested turn; then
    if [[ "${RBI_TURN_USE_STANDARD_AL2023_AMI:-0}" == "1" ]]; then
      TURN_AMI_SKIPPED=1
      log "skipping TURN custom AMI build; Terraform will select latest AL2023 and bootstrap TURN through user data"
    else
      build_component turn
    fi
  fi

  if component_requested kata; then
    build_component kata
  fi

  write_artifact_env

  if [[ "${MODE}" == "build-promote" ]]; then
    promote_artifacts
  fi
}

main "$@"
