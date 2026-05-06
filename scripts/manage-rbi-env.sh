#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infra/terraform/aws-standalone-rbi"
DEFAULT_CONFIG="${TF_ROOT}/configs/development-ap-south-1.env"

ACTION=""
CONFIG_FILE="${DEFAULT_CONFIG}"
CONFIG_FILE_SET=0
ROOT_SELECTOR="all"
PLAN_DIR="${TF_ROOT}/.terraform-plans"
AUTO_APPROVE=0
CONFIRM_DESTROY=0
INCLUDE_BOOTSTRAP=0
NO_COLOR=0
LOCAL_BACKEND=0
EXTRA_TF_ARGS=()

usage() {
  cat <<'EOF'
Manage standalone RBI Terraform environments.

Usage:
  scripts/manage-rbi-env.sh <plan|deploy|deploy-all|redeploy|destroy> [config-file] [options] [-- terraform-args...]
  scripts/rbi-plan.sh [config-file] [options] [-- terraform-args...]

Options:
  config-file               Optional shell env config path to source. May be absolute,
                            relative to the current directory, relative to this repo,
                            or relative to the parent workspace.
  --config <path>           Shell env config to source.
                            Default: infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env
  --root <name[,name]>      Root(s) to operate on: all, bootstrap, identity, global, data, network, eks, apps.
                            Default: all
  --plan-dir <path>         Directory for saved deploy-all plan files.
                            Default: infra/terraform/aws-standalone-rbi/.terraform-plans
  --auto-approve            Pass -auto-approve to terraform apply/destroy.
                            For deploy-all, skip the per-root confirmation prompt.
  --confirm-destroy         Required for destroy unless RBI_CONFIRM_DESTROY=1 is set.
  --include-bootstrap       Include bootstrap/remote-state in all-root destroy.
  --local-backend           Plan non-bootstrap roots with terraform init -backend=false.
                            Only valid with plan; useful before remote state exists.
  --no-color                Pass -no-color to terraform.
  -h, --help                Show help.

Examples:
  scripts/rbi-plan.sh
  scripts/rbi-plan.sh infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env
  scripts/rbi-plan.sh cloudsec_remote_browser/infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env
  scripts/rbi-deploy.sh --root bootstrap
  scripts/rbi-deploy.sh --root identity
  scripts/rbi-deploy.sh infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env --root global,data,network
  scripts/rbi-deploy.sh --root global,data,network
  scripts/rbi-deploy-all.sh infra/terraform/aws-standalone-rbi/configs/development-ap-south-1.env --auto-approve
  scripts/rbi-redeploy.sh --root apps --auto-approve
  scripts/rbi-destroy.sh --root apps --confirm-destroy --auto-approve

Notes:
  deploy    = terraform init -reconfigure, then terraform apply.
  deploy-all = terraform init, saved plan, and apply only roots with changes in dependency order.
  redeploy  = same as deploy; Terraform reconciles drift and changed inputs.
  destroy   = reverse order for all roots, and skips bootstrap unless --include-bootstrap is provided.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
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
    plan|deploy|deploy-all|redeploy|destroy)
      [[ -z "${ACTION}" ]] || die "action already set to ${ACTION}"
      ACTION="$1"
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || die "--config requires a path"
      CONFIG_FILE="$(resolve_config_file "$2")"
      CONFIG_FILE_SET=1
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || die "--root requires a value"
      ROOT_SELECTOR="$2"
      shift 2
      ;;
    --plan-dir)
      [[ $# -ge 2 ]] || die "--plan-dir requires a path"
      PLAN_DIR="$2"
      shift 2
      ;;
    --auto-approve)
      AUTO_APPROVE=1
      shift
      ;;
    --confirm-destroy)
      CONFIRM_DESTROY=1
      shift
      ;;
    --include-bootstrap)
      INCLUDE_BOOTSTRAP=1
      shift
      ;;
    --local-backend)
      LOCAL_BACKEND=1
      shift
      ;;
    --no-color)
      NO_COLOR=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_TF_ARGS=("$@")
      break
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

[[ -n "${ACTION}" ]] || {
  usage
  exit 1
}

[[ -f "${CONFIG_FILE}" ]] || die "config file not found: ${CONFIG_FILE}"

set -a
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set +a

BACKEND_MODE="${TF_BACKEND_MODE:-s3}"
case "${BACKEND_MODE}" in
  s3|local) ;;
  *) die "unsupported TF_BACKEND_MODE: ${BACKEND_MODE}. Expected s3 or local." ;;
esac
MANAGE_TF_BACKEND="${RBI_MANAGE_TF_BACKEND:-0}"
case "${MANAGE_TF_BACKEND}" in
  0|1) ;;
  *) die "unsupported RBI_MANAGE_TF_BACKEND: ${MANAGE_TF_BACKEND}. Expected 0 or 1." ;;
esac

if [[ -n "${TF_STATE_BUCKET:-}" && -z "${RBI_TF_STATE_BUCKET:-}" ]]; then
  export RBI_TF_STATE_BUCKET="${TF_STATE_BUCKET}"
fi
if [[ -n "${TF_LOCK_TABLE:-}" && -z "${RBI_TF_LOCK_TABLE:-}" ]]; then
  export RBI_TF_LOCK_TABLE="${TF_LOCK_TABLE}"
fi
if [[ -n "${TF_STATE_KEY_PREFIX:-}" && -z "${RBI_TF_STATE_KEY_PREFIX:-}" ]]; then
  export RBI_TF_STATE_KEY_PREFIX="${TF_STATE_KEY_PREFIX}"
elif [[ -n "${TF_STATE_KEY:-}" && -z "${RBI_TF_STATE_KEY_PREFIX:-}" ]]; then
  STATE_KEY_PREFIX_FROM_GENERIC="${TF_STATE_KEY%/*}"
  if [[ "${STATE_KEY_PREFIX_FROM_GENERIC}" == "${TF_STATE_KEY}" ]]; then
    STATE_KEY_PREFIX_FROM_GENERIC="${TF_STATE_KEY%.tfstate}"
  fi
  export RBI_TF_STATE_KEY_PREFIX="${STATE_KEY_PREFIX_FROM_GENERIC}"
fi

if [[ "${BACKEND_MODE}" == "local" ]]; then
  LOCAL_BACKEND=1
fi

REGIONAL_ROOT="${RBI_TF_REGIONAL_ROOT:-${TF_ROOT}/envs/prod/us-east-1}"
STATE_KEY_PREFIX="${RBI_TF_STATE_KEY_PREFIX:-${TF_VAR_environment:-${RBI_ENVIRONMENT:-dev}}/${RBI_REGION:-${AWS_REGION:-unknown}}}"

ROOT_BOOTSTRAP="${TF_ROOT}/bootstrap/remote-state"
ROOT_IDENTITY="${TF_ROOT}/bootstrap/identity"
ROOT_GLOBAL="${TF_ROOT}/envs/prod/global"
ROOT_NETWORK="${REGIONAL_ROOT}/network"
ROOT_DATA="${REGIONAL_ROOT}/data"
ROOT_EKS="${REGIONAL_ROOT}/eks"
ROOT_APPS="${REGIONAL_ROOT}/apps"

ROOTS_IN_ORDER=(bootstrap identity global data network eks apps)
ROOTS_DESTROY_ORDER=(apps eks network data global identity)

root_dir() {
  case "$1" in
    bootstrap) printf '%s\n' "${ROOT_BOOTSTRAP}" ;;
    identity) printf '%s\n' "${ROOT_IDENTITY}" ;;
    global) printf '%s\n' "${ROOT_GLOBAL}" ;;
    network) printf '%s\n' "${ROOT_NETWORK}" ;;
    data) printf '%s\n' "${ROOT_DATA}" ;;
    eks) printf '%s\n' "${ROOT_EKS}" ;;
    apps) printf '%s\n' "${ROOT_APPS}" ;;
    *) die "unsupported root: $1" ;;
  esac
}

root_state_key() {
  printf '%s/%s.tfstate\n' "${STATE_KEY_PREFIX}" "$1"
}

root_local_tf_data_dir() {
  printf '%s/.terraform-local/%s\n' "${TF_ROOT}" "$1"
}

root_plan_file() {
  local root="$1"
  local key_prefix
  key_prefix="${STATE_KEY_PREFIX//\//_}"
  printf '%s/%s-%s.tfplan\n' "${PLAN_DIR}" "${key_prefix}" "${root}"
}

local_root_dir() {
  local root="$1"
  local dry_region="${RBI_REGION:-local}"

  if [[ "${root}" == "global" ]]; then
    printf '%s/.terraform-local/roots/envs/prod/global\n' "${TF_ROOT}"
  else
    printf '%s/.terraform-local/roots/envs/prod/%s/%s\n' "${TF_ROOT}" "${dry_region}" "${root}"
  fi
}

prepare_local_root() {
  local root="$1"
  local source_dir
  source_dir="$(root_dir "${root}")"

  local dry_root_base="${TF_ROOT}/.terraform-local/roots"
  local dry_dir
  dry_dir="$(local_root_dir "${root}")"

  [[ -d "${source_dir}" ]] || die "Terraform root directory not found for ${root}: ${source_dir}"

  rm -rf "${dry_dir}"
  mkdir -p "${dry_dir}"
  ln -sfn "${TF_ROOT}/modules" "${dry_root_base}/modules"

  local file
  for file in "${source_dir}"/*.tf "${source_dir}"/.terraform.lock.hcl; do
    [[ -e "${file}" ]] || continue
    cp "${file}" "${dry_dir}/"
  done

  if [[ -f "${dry_dir}/versions.tf" ]]; then
    awk '
      /^[[:space:]]*backend[[:space:]]+"[^"]+"[[:space:]]*\{\}[[:space:]]*$/ { next }
      /^[[:space:]]*backend[[:space:]]+"[^"]+"[[:space:]]*\{/ { skip = 1; next }
      skip && /^[[:space:]]*\}/ { skip = 0; next }
      skip { next }
      { print }
    ' "${dry_dir}/versions.tf" > "${dry_dir}/versions.tf.tmp"
    mv "${dry_dir}/versions.tf.tmp" "${dry_dir}/versions.tf"
  fi

  printf '%s\n' "${dry_dir}"
}

root_selected() {
  local root="$1"

  if [[ "${ROOT_SELECTOR}" == "all" ]]; then
    return 0
  fi

  local selector
  IFS=',' read -ra selectors <<< "${ROOT_SELECTOR}"
  for selector in "${selectors[@]}"; do
    if [[ "${selector}" == "${root}" ]]; then
      return 0
    fi
  done

  return 1
}

root_available_or_optional() {
  local root="$1"
  local dir

  if [[ "${root}" == "bootstrap" && "${MANAGE_TF_BACKEND}" != "1" ]]; then
    if [[ "${ROOT_SELECTOR}" == "all" ]]; then
      warn "skipped bootstrap root because RBI_MANAGE_TF_BACKEND=0; using pre-existing backend bucket ${RBI_TF_STATE_BUCKET:-<unset>}"
      return 1
    fi
    die "bootstrap root is disabled because RBI_MANAGE_TF_BACKEND=0. Create the backend outside Terraform or set RBI_MANAGE_TF_BACKEND=1 explicitly."
  fi

  dir="$(root_dir "${root}")"
  if [[ -d "${dir}" ]]; then
    return 0
  fi

  if [[ "${root}" == "identity" && "${ROOT_SELECTOR}" == "all" ]]; then
    warn "skipped optional identity root because it is not present: ${dir}"
    return 1
  fi

  die "Terraform root directory not found for ${root}: ${dir}"
}

validate_root_selector() {
  local selector
  if [[ "${ROOT_SELECTOR}" == "all" ]]; then
    return
  fi

  IFS=',' read -ra selectors <<< "${ROOT_SELECTOR}"
  for selector in "${selectors[@]}"; do
    case "${selector}" in
      bootstrap|identity|global|network|data|eks|apps) ;;
      *) die "invalid --root value: ${selector}" ;;
    esac
  done
}

require_backend_env() {
  [[ -n "${RBI_TF_STATE_BUCKET:-}" ]] || die "RBI_TF_STATE_BUCKET is required for non-bootstrap roots"
  [[ -n "${RBI_TF_LOCK_TABLE:-}" ]] || die "RBI_TF_LOCK_TABLE is required for non-bootstrap roots"
  [[ -n "${AWS_REGION:-}" ]] || die "AWS_REGION is required"
}

init_root() {
  local root="$1"
  local dir
  if [[ "${LOCAL_BACKEND}" == "1" && "${root}" != "bootstrap" ]]; then
    dir="$(prepare_local_root "${root}")"
  else
    dir="$(root_dir "${root}")"
  fi
  [[ -d "${dir}" ]] || die "Terraform root directory not found for ${root}: ${dir}"

  local common_args=("-input=false")
  if [[ "${NO_COLOR}" == "1" ]]; then
    common_args+=("-no-color")
  fi

  if [[ "${root}" == "bootstrap" ]]; then
    log "terraform init: ${root}"
    terraform -chdir="${dir}" init "${common_args[@]}"
    return
  fi

  if [[ "${LOCAL_BACKEND}" == "1" ]]; then
    log "terraform init -backend=false: ${root}"
    rm -rf "$(root_local_tf_data_dir "${root}")"
    TF_DATA_DIR="$(root_local_tf_data_dir "${root}")" terraform -chdir="${dir}" init "${common_args[@]}" -backend=false -reconfigure
    return
  fi

  require_backend_env
  log "terraform init -reconfigure: ${root} state_key=$(root_state_key "${root}")"
  terraform -chdir="${dir}" init \
    "${common_args[@]}" \
    -reconfigure \
    -backend-config="bucket=${RBI_TF_STATE_BUCKET}" \
    -backend-config="dynamodb_table=${RBI_TF_LOCK_TABLE}" \
    -backend-config="encrypt=true" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="key=$(root_state_key "${root}")"
}

is_unset_or_placeholder_list() {
  local value="${1:-}"
  [[ -z "${value}" || "${value}" == "[]" || "${value}" == *"subnet-aaaaaaaa"* ]]
}

is_unset_or_placeholder_arn() {
  local value="${1:-}"
  [[ -z "${value}" || "${value}" == "null" || "${value}" == *"00000000-0000-0000-0000-000000000000"* ]]
}

is_unset_or_placeholder_ami() {
  local value="${1:-}"
  [[ -z "${value}" || "${value}" == "null" || "${value}" == "ami-00000000000000000" || "${value}" == "ami-0123456789abcdef0" ]]
}

is_mutable_or_unset_image() {
  local value="${1:-}"
  [[ -z "${value}" || "${value}" != *@sha256:* ]]
}

aws_ssm_parameter_value() {
  local name="$1"

  [[ -n "${name}" ]] || return 1
  aws ssm get-parameter \
    --name "${name}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text 2>/dev/null
}

require_promoted_artifacts() {
  [[ "${RBI_REQUIRE_PROMOTED_ARTIFACTS:-1}" == "1" && ! ("${ACTION}" == "plan" && "${LOCAL_BACKEND}" == "1") ]]
}

hydrate_ami_from_ssm() {
  local var_name="$1"
  local param_name="$2"
  local label="$3"
  local current_value="${!var_name:-}"
  local promoted_value

  is_unset_or_placeholder_ami "${current_value}" || return 0

  if promoted_value="$(aws_ssm_parameter_value "${param_name}")" && ! is_unset_or_placeholder_ami "${promoted_value}"; then
    export "${var_name}=${promoted_value}"
    log "using promoted ${label} AMI from SSM: ${param_name}"
    return 0
  fi

  if require_promoted_artifacts; then
    die "${label} AMI is unset or placeholder and SSM parameter is unavailable: ${param_name}"
  fi

  warn "${label} AMI is unset or placeholder; set ${var_name} or publish ${param_name}"
}

hydrate_image_from_ssm() {
  local var_name="$1"
  local param_name="$2"
  local label="$3"
  local current_value="${!var_name:-}"
  local promoted_value

  is_mutable_or_unset_image "${current_value}" || return 0

  if promoted_value="$(aws_ssm_parameter_value "${param_name}")" && [[ "${promoted_value}" == *@sha256:* ]]; then
    export "${var_name}=${promoted_value}"
    log "using promoted ${label} image digest from SSM: ${param_name}"
    return 0
  fi

  if require_promoted_artifacts; then
    die "${label} image is not digest-pinned and SSM parameter is unavailable: ${param_name}"
  fi

  warn "${label} image is not digest-pinned; set ${var_name} or publish ${param_name}"
}

hydrate_turn_ami_id() {
  if [[ "${RBI_TURN_USE_STANDARD_AL2023_AMI:-0}" == "1" ]]; then
    warn "TURN custom AMI is disabled; network root will use latest AL2023 and bootstrap TURN through user data"
    export TF_VAR_turn_ami_id=""
    return 0
  fi

  hydrate_ami_from_ssm \
    TF_VAR_turn_ami_id \
    "${RBI_TURN_AMI_ID_SSM_PARAMETER:-/cloudsec-rbi/${TF_VAR_environment:-dev}/${AWS_REGION:-unknown}/images/turn-ami-id}" \
    "TURN"
}

hydrate_kata_worker_ami_id() {
  hydrate_ami_from_ssm \
    TF_VAR_kata_worker_ami_id \
    "${RBI_KATA_WORKER_AMI_ID_SSM_PARAMETER:-/cloudsec-rbi/${TF_VAR_environment:-dev}/${AWS_REGION:-unknown}/images/kata-worker-ami-id}" \
    "Kata worker"
}

hydrate_app_images() {
  local image_prefix="${RBI_IMAGE_SSM_PREFIX:-/cloudsec-rbi/${TF_VAR_environment:-dev}/${AWS_REGION:-unknown}/images}"

  hydrate_image_from_ssm TF_VAR_runtime_image "${image_prefix}/control-plane-image-digest" "runtime/control-plane"
  hydrate_image_from_ssm TF_VAR_session_authority_image "${image_prefix}/session-authority-image-digest" "session-authority"
  hydrate_image_from_ssm TF_VAR_media_gateway_image "${image_prefix}/media-gateway-image-digest" "media-gateway"
  hydrate_image_from_ssm TF_VAR_file_broker_image "${image_prefix}/file-broker-image-digest" "file-broker"
  hydrate_image_from_ssm TF_VAR_clipboard_broker_image "${image_prefix}/clipboard-broker-image-digest" "clipboard-broker"
  hydrate_image_from_ssm TF_VAR_worker_image "${image_prefix}/worker-image-digest" "worker"
}

hydrate_apps_network_vars() {
  [[ "${RBI_USE_NETWORK_OUTPUTS:-1}" == "1" ]] || return 0

  local target_group_arns bootstrap_target_group_arn worker_turn_hostname redis_primary_endpoint
  if [[ -z "${TF_VAR_control_plane_target_group_arns:-}" || "${TF_VAR_control_plane_target_group_arns:-}" == "{}" ]]; then
    if target_group_arns="$(terraform -chdir="${ROOT_NETWORK}" output -json ingress_target_group_arns 2>/dev/null)"; then
      export TF_VAR_control_plane_target_group_arns="${target_group_arns}"
      log "using ALB target group ARNs from network output"
    else
      warn "could not read network ingress_target_group_arns output; apps target group bindings may be disabled"
    fi
  fi

  if [[ -z "${TF_VAR_bootstrap_target_group_arn:-}" ]]; then
    if bootstrap_target_group_arn="$(terraform -chdir="${ROOT_NETWORK}" output -raw privatelink_bootstrap_target_group_arn 2>/dev/null)" && [[ -n "${bootstrap_target_group_arn}" && "${bootstrap_target_group_arn}" != "null" ]]; then
      export TF_VAR_bootstrap_target_group_arn="${bootstrap_target_group_arn}"
      log "using bootstrap target group ARN from network output"
    else
      warn "could not read network privatelink_bootstrap_target_group_arn output; PrivateLink TargetGroupBinding may be disabled"
    fi
  fi

  if [[ -z "${TF_VAR_worker_turn_hostname:-}" ]]; then
    if worker_turn_hostname="$(terraform -chdir="${ROOT_NETWORK}" output -raw worker_turn_hostname 2>/dev/null)" && [[ -n "${worker_turn_hostname}" && "${worker_turn_hostname}" != "null" ]]; then
      export TF_VAR_worker_turn_hostname="${worker_turn_hostname}"
      log "using worker TURN hostname from network output"
    else
      warn "could not read network worker_turn_hostname output; apps will fall back to public TURN hostname"
    fi
  fi

  if [[ -z "${TF_VAR_redis_url:-}" ]]; then
    if redis_primary_endpoint="$(terraform -chdir="${ROOT_NETWORK}" output -raw redis_primary_endpoint_address 2>/dev/null)" && [[ -n "${redis_primary_endpoint}" && "${redis_primary_endpoint}" != "null" ]]; then
      export TF_VAR_redis_url="rediss://${redis_primary_endpoint}:6379"
      log "using Redis primary endpoint from network output"
    else
      warn "could not read network redis_primary_endpoint_address output; apps runtime may use its default store backend"
    fi
  fi
}

hydrate_network_certificate_arn() {
  [[ "${RBI_USE_DATA_CERT_OUTPUTS:-1}" == "1" ]] || return 0
  is_unset_or_placeholder_arn "${TF_VAR_viewer_certificate_arn:-}" || return 0

  local cert_arn
  if ! cert_arn="$(terraform -chdir="${ROOT_DATA}" output -raw public_viewer_certificate_arn 2>/dev/null)"; then
    if [[ "${RBI_REQUIRE_VIEWER_CERT:-0}" == "1" && ! ("${ACTION}" == "plan" && "${LOCAL_BACKEND}" == "1") ]]; then
      die "viewer certificate ARN is empty and data root output public_viewer_certificate_arn is unavailable. Deploy data first or set TF_VAR_viewer_certificate_arn."
    fi
    warn "could not read data public_viewer_certificate_arn output; network will plan without HTTPS listener cert"
    return 0
  fi

  if is_unset_or_placeholder_arn "${cert_arn}"; then
    if [[ "${RBI_REQUIRE_VIEWER_CERT:-0}" == "1" && ! ("${ACTION}" == "plan" && "${LOCAL_BACKEND}" == "1") ]]; then
      die "data root did not expose public_viewer_certificate_arn. Set TF_VAR_viewer_certificate_arn or apply data with ACM certificate config."
    fi
    warn "data root has no public endpoint certificate ARN; network will plan without HTTPS listener cert"
    return 0
  fi

  export TF_VAR_viewer_certificate_arn="${cert_arn}"
  log "using viewer ACM certificate from data output: ${cert_arn}"
}

hydrate_eks_network_vars() {
  [[ "${RBI_USE_NETWORK_OUTPUTS:-1}" == "1" ]] || return 0

  local network_dir="${ROOT_NETWORK}"
  local private_subnets kms_key_arn
  if ! private_subnets="$(terraform -chdir="${network_dir}" output -json private_subnet_ids 2>/dev/null)"; then
    warn "could not read network private_subnet_ids output; using subnet variables from config"
  else
    if is_unset_or_placeholder_list "${TF_VAR_cluster_subnet_ids:-}"; then
      export TF_VAR_cluster_subnet_ids="${private_subnets}"
    fi
    if is_unset_or_placeholder_list "${TF_VAR_standard_node_subnet_ids:-}"; then
      export TF_VAR_standard_node_subnet_ids="${private_subnets}"
    fi
    if is_unset_or_placeholder_list "${TF_VAR_kata_node_subnet_ids:-}"; then
      export TF_VAR_kata_node_subnet_ids="${private_subnets}"
    fi
  fi

  if is_unset_or_placeholder_arn "${TF_VAR_cluster_encryption_key_arn:-}" && kms_key_arn="$(terraform -chdir="${ROOT_DATA}" output -raw kms_key_arn 2>/dev/null)" && ! is_unset_or_placeholder_arn "${kms_key_arn}"; then
    export TF_VAR_cluster_encryption_key_arn="${kms_key_arn}"
    log "using EKS secret encryption KMS key from data output"
  fi
}

run_root_action() {
  local root="$1"
  local action="$2"
  local dir

  init_root "${root}"

  if [[ "${LOCAL_BACKEND}" == "1" && "${root}" != "bootstrap" ]]; then
    dir="$(local_root_dir "${root}")"
  else
    dir="$(root_dir "${root}")"
  fi

  local common_args=("-input=false")
  if [[ "${NO_COLOR}" == "1" ]]; then
    common_args+=("-no-color")
  fi

  if [[ "${root}" == "eks" ]]; then
    hydrate_kata_worker_ami_id
    hydrate_eks_network_vars
  fi
  if [[ "${root}" == "network" ]]; then
    hydrate_turn_ami_id
    hydrate_network_certificate_arn
  fi
  if [[ "${root}" == "apps" ]]; then
    hydrate_app_images
    hydrate_apps_network_vars
  fi

  case "${action}" in
    plan)
      log "terraform plan: ${root}"
      set +u
      if [[ "${LOCAL_BACKEND}" == "1" && "${root}" != "bootstrap" ]]; then
        TF_DATA_DIR="$(root_local_tf_data_dir "${root}")" terraform -chdir="${dir}" plan "${common_args[@]}" "${EXTRA_TF_ARGS[@]}"
      else
        terraform -chdir="${dir}" plan "${common_args[@]}" "${EXTRA_TF_ARGS[@]}"
      fi
      set -u
      ;;
    deploy|redeploy)
      local apply_args=()
      if [[ "${AUTO_APPROVE}" == "1" ]]; then
        apply_args+=("-auto-approve")
      fi
      log "terraform apply: ${root}"
      set +u
      terraform -chdir="${dir}" apply "${common_args[@]}" "${apply_args[@]}" "${EXTRA_TF_ARGS[@]}"
      set -u
      ;;
    destroy)
      local destroy_args=()
      if [[ "${AUTO_APPROVE}" == "1" ]]; then
        destroy_args+=("-auto-approve")
      fi
      log "terraform destroy: ${root}"
      set +u
      terraform -chdir="${dir}" destroy "${common_args[@]}" "${destroy_args[@]}" "${EXTRA_TF_ARGS[@]}"
      set -u
      ;;
    *)
      die "unsupported action: ${action}"
      ;;
  esac
}

confirm_deploy_all_apply() {
  local root="$1"

  if [[ "${AUTO_APPROVE}" == "1" ]]; then
    return 0
  fi

  local answer
  printf 'Apply planned changes for %s? Type yes to continue: ' "${root}" >&2
  read -r answer
  [[ "${answer}" == "yes" ]] || die "deploy-all cancelled before applying ${root}"
}

plan_root_for_deploy_all() {
  local root="$1"
  local dir
  local plan_file
  DEPLOY_ALL_ROOT_HAS_CHANGES=0

  init_root "${root}"
  dir="$(root_dir "${root}")"
  plan_file="$(root_plan_file "${root}")"
  mkdir -p "${PLAN_DIR}"

  local common_args=("-input=false")
  if [[ "${NO_COLOR}" == "1" ]]; then
    common_args+=("-no-color")
  fi

  if [[ "${root}" == "eks" ]]; then
    hydrate_kata_worker_ami_id
    hydrate_eks_network_vars
  fi
  if [[ "${root}" == "network" ]]; then
    hydrate_turn_ami_id
    hydrate_network_certificate_arn
  fi
  if [[ "${root}" == "apps" ]]; then
    hydrate_app_images
    hydrate_apps_network_vars
  fi

  log "terraform plan -detailed-exitcode: ${root}"
  set +e +u
  terraform -chdir="${dir}" plan \
    "${common_args[@]}" \
    -detailed-exitcode \
    -out="${plan_file}" \
    "${EXTRA_TF_ARGS[@]}"
  local status=$?
  set -e -u

  case "${status}" in
    0)
      rm -f "${plan_file}"
      printf 'No changes: %s\n' "${root}"
      DEPLOY_ALL_ROOT_HAS_CHANGES=0
      return 0
      ;;
    2)
      printf 'Changes detected: %s\n' "${root}"
      DEPLOY_ALL_ROOT_HAS_CHANGES=1
      return 0
      ;;
    *)
      rm -f "${plan_file}"
      die "terraform plan failed for ${root}"
      ;;
  esac
}

apply_planned_root() {
  local root="$1"
  local dir
  local plan_file

  dir="$(root_dir "${root}")"
  plan_file="$(root_plan_file "${root}")"
  [[ -f "${plan_file}" ]] || die "saved plan file missing for ${root}: ${plan_file}"

  confirm_deploy_all_apply "${root}"

  local common_args=("-input=false")
  if [[ "${NO_COLOR}" == "1" ]]; then
    common_args+=("-no-color")
  fi

  log "terraform apply saved plan: ${root}"
  set +u
  terraform -chdir="${dir}" apply "${common_args[@]}" "${plan_file}"
  set -u
  rm -f "${plan_file}"
}

run_deploy_all() {
  local changed_roots=()
  local skipped_roots=()
  local root

  for root in "${ROOTS_IN_ORDER[@]}"; do
    root_selected "${root}" || continue
    root_available_or_optional "${root}" || continue

    plan_root_for_deploy_all "${root}"

    if [[ "${DEPLOY_ALL_ROOT_HAS_CHANGES}" == "1" ]]; then
      changed_roots+=("${root}")
      apply_planned_root "${root}"
    else
      skipped_roots+=("${root}")
    fi
  done

  printf '\nDeploy-all summary:\n'
  if [[ "${#changed_roots[@]}" -gt 0 ]]; then
    printf '  Applied roots: %s\n' "${changed_roots[*]}"
  else
    printf '  Applied roots: <none>\n'
  fi
  if [[ "${#skipped_roots[@]}" -gt 0 ]]; then
    printf '  No-change roots: %s\n' "${skipped_roots[*]}"
  else
    printf '  No-change roots: <none>\n'
  fi
}

validate_root_selector

if [[ "${LOCAL_BACKEND}" == "1" && "${ACTION}" != "plan" ]]; then
  die "--local-backend is only supported with plan"
fi

if [[ "${ACTION}" == "destroy" && "${CONFIRM_DESTROY}" != "1" && "${RBI_CONFIRM_DESTROY:-0}" != "1" ]]; then
  die "destroy requires --confirm-destroy or RBI_CONFIRM_DESTROY=1"
fi

printf 'Config: %s\n' "${CONFIG_FILE}"
printf 'AWS profile: %s\n' "${AWS_PROFILE:-<unset>}"
printf 'AWS region: %s\n' "${AWS_REGION:-<unset>}"
printf 'Environment: %s\n' "${TF_VAR_environment:-<unset>}"
printf 'State bucket: %s\n' "${RBI_TF_STATE_BUCKET:-<bootstrap-local>}"
printf 'State key prefix: %s\n' "${STATE_KEY_PREFIX}"
printf 'Manage TF backend: %s\n' "${MANAGE_TF_BACKEND}"
printf 'Regional root: %s\n' "${REGIONAL_ROOT}"
if [[ "${LOCAL_BACKEND}" == "1" ]]; then
  printf 'Backend mode: local dry-run (-backend=false)\n'
fi
if [[ "${ACTION}" == "deploy-all" ]]; then
  printf 'Deploy-all plan dir: %s\n' "${PLAN_DIR}"
fi

if [[ "${ACTION}" == "deploy-all" ]]; then
  run_deploy_all
elif [[ "${ACTION}" == "destroy" ]]; then
  for root in "${ROOTS_DESTROY_ORDER[@]}"; do
    root_selected "${root}" || continue
    root_available_or_optional "${root}" || continue
    run_root_action "${root}" "${ACTION}"
  done

  if root_selected bootstrap; then
    run_root_action bootstrap "${ACTION}"
  elif [[ "${ROOT_SELECTOR}" == "all" && "${INCLUDE_BOOTSTRAP}" == "1" ]]; then
    run_root_action bootstrap "${ACTION}"
  elif [[ "${ROOT_SELECTOR}" == "all" ]]; then
    warn "skipped bootstrap destroy; pass --include-bootstrap to destroy the state bucket and lock table"
  fi
else
  for root in "${ROOTS_IN_ORDER[@]}"; do
    root_selected "${root}" || continue
    root_available_or_optional "${root}" || continue
    run_root_action "${root}" "${ACTION}"
  done
fi
