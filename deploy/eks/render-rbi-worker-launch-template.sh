#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NODE_BOOTSTRAP_DIR="${SCRIPT_DIR}/../node-bootstrap"
USER_DATA_TEMPLATE="${NODE_BOOTSTRAP_DIR}/user-data/al2023-kata-worker-user-data.mime"
LAUNCH_TEMPLATE_TEMPLATE="${SCRIPT_DIR}/rbi-worker-launch-template-data.json"
NODEGROUP_TEMPLATE="${SCRIPT_DIR}/rbi-worker-nodegroup.eksctl.yaml"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/rendered}"

RENDERED_USER_DATA_PATH="${OUTPUT_DIR}/rbi-worker-user-data.mime"
RENDERED_LAUNCH_TEMPLATE_PATH="${OUTPUT_DIR}/rbi-worker-launch-template-data.json"
RENDERED_NODEGROUP_PATH="${OUTPUT_DIR}/rbi-worker-nodegroup.eksctl.yaml"

required_env_vars=(
  AWS_REGION
  EKS_CLUSTER_NAME
  EKS_API_SERVER_ENDPOINT
  EKS_CERTIFICATE_AUTHORITY_B64
  EKS_SERVICE_IPV4_CIDR
  RBI_AMI_ID
  RBI_INSTANCE_TYPE
  RBI_SECURITY_GROUP_IDS_JSON
)

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

require_env() {
  local var_name
  for var_name in "${required_env_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
      printf 'missing required environment variable: %s\n' "${var_name}" >&2
      exit 1
    fi
  done
}

render_template() {
  local src="$1"
  local dest="$2"

  sed \
    -e "s|__AWS_REGION__|$(escape_sed_replacement "${AWS_REGION}")|g" \
    -e "s|__EKS_CLUSTER_NAME__|$(escape_sed_replacement "${EKS_CLUSTER_NAME}")|g" \
    -e "s|__EKS_API_SERVER_ENDPOINT__|$(escape_sed_replacement "${EKS_API_SERVER_ENDPOINT}")|g" \
    -e "s|__EKS_CERTIFICATE_AUTHORITY_B64__|$(escape_sed_replacement "${EKS_CERTIFICATE_AUTHORITY_B64}")|g" \
    -e "s|__EKS_SERVICE_IPV4_CIDR__|$(escape_sed_replacement "${EKS_SERVICE_IPV4_CIDR}")|g" \
    -e "s|__RBI_NODE_LABELS__|$(escape_sed_replacement "${RBI_NODE_LABELS}")|g" \
    -e "s|__RBI_NODE_TAINTS__|$(escape_sed_replacement "${RBI_NODE_TAINTS}")|g" \
    -e "s|__HOST_BOOTSTRAP_SCRIPT_PATH__|$(escape_sed_replacement "${HOST_BOOTSTRAP_SCRIPT_PATH}")|g" \
    -e "s|__RBI_LAUNCH_TEMPLATE_NAME__|$(escape_sed_replacement "${RBI_LAUNCH_TEMPLATE_NAME}")|g" \
    -e "s|__RBI_LAUNCH_TEMPLATE_VERSION__|$(escape_sed_replacement "${RBI_LAUNCH_TEMPLATE_VERSION}")|g" \
    -e "s|__RBI_LAUNCH_TEMPLATE_VERSION_DESCRIPTION__|$(escape_sed_replacement "${RBI_LAUNCH_TEMPLATE_VERSION_DESCRIPTION}")|g" \
    -e "s|__RBI_AMI_ID__|$(escape_sed_replacement "${RBI_AMI_ID}")|g" \
    -e "s|__RBI_INSTANCE_TYPE__|$(escape_sed_replacement "${RBI_INSTANCE_TYPE}")|g" \
    -e "s|__RBI_SECURITY_GROUP_IDS_JSON__|$(escape_sed_replacement "${RBI_SECURITY_GROUP_IDS_JSON}")|g" \
    -e "s|__RBI_USER_DATA_BASE64__|$(escape_sed_replacement "${RBI_USER_DATA_BASE64:-}")|g" \
    -e "s|__RBI_ROOT_VOLUME_SIZE_GIB__|$(escape_sed_replacement "${RBI_ROOT_VOLUME_SIZE_GIB}")|g" \
    -e "s|__RBI_ROOT_VOLUME_IOPS__|$(escape_sed_replacement "${RBI_ROOT_VOLUME_IOPS}")|g" \
    -e "s|__RBI_ROOT_VOLUME_THROUGHPUT__|$(escape_sed_replacement "${RBI_ROOT_VOLUME_THROUGHPUT}")|g" \
    "${src}" >"${dest}"
}

main() {
  export RBI_NODE_LABELS="${RBI_NODE_LABELS:-cloudsec.cisco.com/rbi-worker-plane=true,cloudsec.cisco.com/node-pool=rbi-workers}"
  export RBI_NODE_TAINTS="${RBI_NODE_TAINTS:-cloudsec.cisco.com/rbi-worker-plane=true:NoSchedule}"
  export HOST_BOOTSTRAP_SCRIPT_PATH="${HOST_BOOTSTRAP_SCRIPT_PATH:-/opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh}"
  export RBI_LAUNCH_TEMPLATE_NAME="${RBI_LAUNCH_TEMPLATE_NAME:-cloudsec-rbi-workers}"
  export RBI_LAUNCH_TEMPLATE_VERSION="${RBI_LAUNCH_TEMPLATE_VERSION:-1}"
  export RBI_LAUNCH_TEMPLATE_VERSION_DESCRIPTION="${RBI_LAUNCH_TEMPLATE_VERSION_DESCRIPTION:-wave3-kata-worker-v1}"
  export RBI_ROOT_VOLUME_SIZE_GIB="${RBI_ROOT_VOLUME_SIZE_GIB:-80}"
  export RBI_ROOT_VOLUME_IOPS="${RBI_ROOT_VOLUME_IOPS:-6000}"
  export RBI_ROOT_VOLUME_THROUGHPUT="${RBI_ROOT_VOLUME_THROUGHPUT:-500}"

  require_env
  mkdir -p "${OUTPUT_DIR}"

  render_template "${USER_DATA_TEMPLATE}" "${RENDERED_USER_DATA_PATH}"

  local user_data_base64
  user_data_base64="$(base64 <"${RENDERED_USER_DATA_PATH}" | tr -d '\n')"
  export RBI_USER_DATA_BASE64="${user_data_base64}"

  render_template "${LAUNCH_TEMPLATE_TEMPLATE}" "${RENDERED_LAUNCH_TEMPLATE_PATH}"
  render_template "${NODEGROUP_TEMPLATE}" "${RENDERED_NODEGROUP_PATH}"

  printf 'Rendered user data: %s\n' "${RENDERED_USER_DATA_PATH}"
  printf 'Rendered launch template input: %s\n' "${RENDERED_LAUNCH_TEMPLATE_PATH}"
  printf 'Rendered eksctl nodegroup config: %s\n' "${RENDERED_NODEGROUP_PATH}"
}

main "$@"
