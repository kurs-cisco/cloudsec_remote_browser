#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infra/terraform/aws-standalone-rbi"
DEFAULT_CONFIG="${TF_ROOT}/configs/development-ap-south-1.env"

CONFIG_FILE="${DEFAULT_CONFIG}"
CONFIG_FILE_SET=0
WARN_ONLY=0
USE_TEMP_KUBECONFIG=1

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

TMP_DIR=""

usage() {
  cat <<'EOF'
Run standalone RBI post-deploy proof checks.

Usage:
  scripts/rbi-postdeploy-proof.sh [config-file] [options]

Options:
  config-file              Shell env config path to source. May be absolute,
                           relative to the current directory, relative to this
                           repo, or relative to the parent workspace.
  --config <path>          Shell env config to source.
  --no-temp-kubeconfig     Do not create a temporary EKS kubeconfig for kubectl.
  --warn-only              Report failures as warnings and exit zero.
  -h, --help               Show help.

Checks:
  DNS resolution, public TLS certificate handshake, ACM certificate status,
  PrivateLink endpoint service state, TURN DNS/TCP/AWS target health, EKS
  cluster and nodegroup status, and Kubernetes/Kata RuntimeClass readiness when
  aws and kubectl are available.
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

cleanup() {
  if [[ -n "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

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
    --no-temp-kubeconfig)
      USE_TEMP_KUBECONFIG=0
      shift
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

REGIONAL_ROOT="${RBI_TF_REGIONAL_ROOT:-${TF_ROOT}/envs/prod/us-east-1}"
ROOT_NETWORK="${REGIONAL_ROOT}/network"
ROOT_DATA="${REGIONAL_ROOT}/data"
ROOT_EKS="${REGIONAL_ROOT}/eks"
ROOT_APPS="${REGIONAL_ROOT}/apps"

RBI_HOST="${RBI_DOMAIN:-${TF_VAR_public_endpoint_hostname:-}}"
TURN_HOST="${TF_VAR_turn_hostname:-turn.${RBI_HOST}}"
CLUSTER_NAME="${TF_VAR_cluster_name:-${RBI_PROJECT_NAME:-cloudsec-rbi}-${AWS_REGION:-unknown}}"
RUNTIME_CLASS="${TF_VAR_runtime_class_name:-kata-clh}"
CONTROL_NAMESPACE="${TF_VAR_control_namespace:-cloudsec-rbi-control}"
WORKER_NAMESPACE="${TF_VAR_worker_namespace:-cloudsec-rbi-workers}"
KATA_DESIRED="${TF_VAR_kata_node_desired_size:-1}"
POOL_REPLICAS="${TF_VAR_pool_replicas:-2}"

printf 'Config: %s\n' "${CONFIG_FILE}"
printf 'AWS profile: %s\n' "${AWS_PROFILE:-<unset>}"
printf 'AWS region: %s\n' "${AWS_REGION:-<unset>}"
printf 'Cluster: %s\n\n' "${CLUSTER_NAME}"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

terraform_output_raw() {
  local root_dir="$1"
  local output_name="$2"

  command_exists terraform || return 1
  [[ -d "${root_dir}" ]] || return 1
  terraform -chdir="${root_dir}" output -raw "${output_name}" 2>/dev/null
}

terraform_output_map_value() {
  local root_dir="$1"
  local output_name="$2"
  local key="$3"
  local raw

  command_exists terraform || return 1
  [[ -d "${root_dir}" ]] || return 1
  if ! raw="$(terraform -chdir="${root_dir}" output -json "${output_name}" 2>/dev/null)"; then
    return 1
  fi
  printf '%s' "${raw}" |
    tr ',' '\n' |
    sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" |
    head -n 1
}

resolve_host() {
  local host="$1"
  local answer

  if [[ -z "${host}" ]]; then
    skip "DNS host unset"
    return
  fi

  if command_exists dig; then
    answer="$(dig +short "${host}" 2>/dev/null | sed '/^$/d' | head -n 1 || true)"
  elif command_exists nslookup; then
    answer="$(nslookup "${host}" 2>/dev/null | awk '/^Address: / {print $2}' | tail -n 1 || true)"
  else
    skip "DNS resolver tool not available for ${host}"
    return
  fi

  if [[ -n "${answer}" ]]; then
    pass "DNS resolves ${host} -> ${answer}"
  else
    fail "DNS does not resolve: ${host}"
  fi
}

check_tls_certificate() {
  local host="$1"

  if [[ -z "${host}" ]]; then
    skip "TLS host unset"
    return
  fi

  if command_exists curl; then
    if curl --head --silent --show-error --connect-timeout 5 --max-time 15 "https://${host}/" >/dev/null 2>&1; then
      pass "TLS certificate handshake succeeded for ${host}:443"
    else
      fail "TLS certificate handshake failed for ${host}:443"
    fi
    return
  fi

  if command_exists openssl && openssl s_client -connect "${host}:443" -servername "${host}" -verify_return_error </dev/null >/dev/null 2>&1; then
    pass "TLS certificate handshake succeeded for ${host}:443"
  else
    fail "TLS certificate handshake failed for ${host}:443"
  fi
}

check_acm_certificate() {
  local cert_arn="${TF_VAR_viewer_certificate_arn:-}"
  local status

  command_exists aws || {
    skip "aws CLI not available for ACM certificate check"
    return
  }

  if [[ -z "${cert_arn}" ]]; then
    cert_arn="$(terraform_output_raw "${ROOT_DATA}" public_viewer_certificate_arn || true)"
  fi

  if [[ -z "${cert_arn}" || "${cert_arn}" == "null" ]]; then
    skip "viewer ACM certificate ARN unavailable"
    return
  fi

  status="$(aws acm describe-certificate --certificate-arn "${cert_arn}" --query 'Certificate.Status' --output text 2>/dev/null || true)"
  if [[ "${status}" == "ISSUED" ]]; then
    pass "ACM viewer certificate is ISSUED: ${cert_arn}"
  else
    fail "ACM viewer certificate is not ISSUED: ${cert_arn} status=${status:-unknown}"
  fi
}

check_privatelink() {
  local service_name service_id state private_dns_state target_group_arn target_states

  command_exists aws || {
    skip "aws CLI not available for PrivateLink check"
    return
  }

  service_name="$(terraform_output_raw "${ROOT_NETWORK}" privatelink_service_name || true)"
  service_id="$(terraform_output_raw "${ROOT_NETWORK}" privatelink_service_id || true)"
  target_group_arn="$(terraform_output_raw "${ROOT_NETWORK}" privatelink_bootstrap_target_group_arn || true)"

  if [[ -z "${service_name}" || "${service_name}" == "null" ]]; then
    skip "PrivateLink service name unavailable from Terraform output"
    return
  fi

  if aws ec2 describe-vpc-endpoint-services --service-names "${service_name}" --query 'ServiceDetails[0].ServiceName' --output text >/dev/null 2>&1; then
    pass "PrivateLink endpoint service is discoverable: ${service_name}"
  else
    fail "PrivateLink endpoint service is not discoverable: ${service_name}"
  fi

  if [[ -n "${service_id}" && "${service_id}" != "null" ]]; then
    state="$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "${service_id}" --query 'ServiceConfigurations[0].ServiceState' --output text 2>/dev/null || true)"
    if [[ "${state}" == "Available" ]]; then
      pass "PrivateLink endpoint service state is Available: ${service_id}"
    else
      fail "PrivateLink endpoint service state is not Available: ${service_id} state=${state:-unknown}"
    fi

    private_dns_state="$(aws ec2 describe-vpc-endpoint-service-configurations --service-ids "${service_id}" --query 'ServiceConfigurations[0].PrivateDnsNameConfiguration.State' --output text 2>/dev/null || true)"
    if [[ "${private_dns_state}" == "verified" || "${private_dns_state}" == "None" || -z "${private_dns_state}" ]]; then
      pass "PrivateLink private DNS state acceptable: ${private_dns_state:-not-configured}"
    else
      fail "PrivateLink private DNS is not verified: ${private_dns_state}"
    fi
  fi

  if [[ -n "${target_group_arn}" && "${target_group_arn}" != "null" ]]; then
    target_states="$(aws elbv2 describe-target-health --target-group-arn "${target_group_arn}" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text 2>/dev/null || true)"
    if [[ -z "${target_states}" ]]; then
      warn "PrivateLink bootstrap target group has no registered targets yet: ${target_group_arn}"
    elif [[ " ${target_states} " == *" healthy "* ]]; then
      pass "PrivateLink bootstrap target group has healthy targets"
    else
      fail "PrivateLink bootstrap target group has no healthy targets: ${target_states}"
    fi
  fi
}

check_tcp_port() {
  local host="$1"
  local port="$2"
  local label="$3"

  if [[ -z "${host}" ]]; then
    skip "${label} host unset"
    return
  fi

  if command_exists nc; then
    if nc -G 5 -z "${host}" "${port}" >/dev/null 2>&1 || nc -w 5 -z "${host}" "${port}" >/dev/null 2>&1; then
      pass "${label} TCP ${port} is reachable on ${host}"
    else
      fail "${label} TCP ${port} is not reachable on ${host}"
    fi
  elif command_exists curl; then
    if curl --silent --show-error --connect-timeout 5 --max-time 10 "telnet://${host}:${port}" >/dev/null 2>&1; then
      pass "${label} TCP ${port} is reachable on ${host}"
    else
      fail "${label} TCP ${port} is not reachable on ${host}"
    fi
  else
    skip "curl/nc not available for ${label} TCP check"
  fi
}

check_lb_target_health_by_dns() {
  local lb_dns="$1"
  local label="$2"
  local lb_arn target_groups target_group states healthy_count

  command_exists aws || {
    skip "aws CLI not available for ${label} load balancer target health"
    return
  }

  if [[ -z "${lb_dns}" || "${lb_dns}" == "null" ]]; then
    skip "${label} load balancer DNS unavailable"
    return
  fi

  lb_arn="$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='${lb_dns}'].LoadBalancerArn | [0]" --output text 2>/dev/null || true)"
  if [[ -z "${lb_arn}" || "${lb_arn}" == "None" ]]; then
    fail "${label} load balancer not found for DNS ${lb_dns}"
    return
  fi

  target_groups="$(aws elbv2 describe-target-groups --load-balancer-arn "${lb_arn}" --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || true)"
  if [[ -z "${target_groups}" ]]; then
    fail "${label} load balancer has no target groups: ${lb_dns}"
    return
  fi

  healthy_count=0
  for target_group in ${target_groups}; do
    states="$(aws elbv2 describe-target-health --target-group-arn "${target_group}" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text 2>/dev/null || true)"
    if [[ " ${states} " == *" healthy "* ]]; then
      healthy_count=$((healthy_count + 1))
    elif [[ -z "${states}" ]]; then
      warn "${label} target group has no registered targets: ${target_group}"
    else
      warn "${label} target group unhealthy states: ${states}"
    fi
  done

  if [[ "${healthy_count}" -gt 0 ]]; then
    pass "${label} load balancer has ${healthy_count} target group(s) with healthy targets"
  else
    fail "${label} load balancer has no healthy target groups"
  fi
}

check_turn() {
  local turn_nlb_dns worker_turn_nlb_dns worker_turn_host

  resolve_host "${TURN_HOST}"
  check_tcp_port "${TURN_HOST}" 443 "TURN TLS"

  turn_nlb_dns="$(terraform_output_raw "${ROOT_NETWORK}" turn_nlb_dns_name || true)"
  check_lb_target_health_by_dns "${turn_nlb_dns}" "TURN NLB"

  worker_turn_host="$(terraform_output_raw "${ROOT_NETWORK}" worker_turn_hostname || true)"
  worker_turn_nlb_dns="$(terraform_output_raw "${ROOT_NETWORK}" turn_internal_nlb_dns_name || true)"
  if [[ -n "${worker_turn_host}" && "${worker_turn_host}" != "null" ]]; then
    pass "Worker TURN endpoint is configured: ${worker_turn_host}"
  else
    fail "Worker TURN endpoint is not configured"
  fi
  check_lb_target_health_by_dns "${worker_turn_nlb_dns}" "internal worker TURN NLB"
}

check_eks_aws() {
  local cluster_status nodegroups nodegroup status standard_node_group kata_node_group

  command_exists aws || {
    skip "aws CLI not available for EKS checks"
    return
  }

  if [[ -z "${CLUSTER_NAME}" ]]; then
    skip "EKS cluster name unset"
    return
  fi

  cluster_status="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.status' --output text 2>/dev/null || true)"
  if [[ "${cluster_status}" == "ACTIVE" ]]; then
    pass "EKS cluster is ACTIVE: ${CLUSTER_NAME}"
  else
    fail "EKS cluster is not ACTIVE: ${CLUSTER_NAME} status=${cluster_status:-unknown}"
    return
  fi

  standard_node_group="$(terraform_output_raw "${ROOT_EKS}" standard_node_group_name || true)"
  kata_node_group="$(terraform_output_raw "${ROOT_EKS}" kata_node_group_name || true)"

  if [[ -n "${standard_node_group}" || -n "${kata_node_group}" ]]; then
    nodegroups="${standard_node_group} ${kata_node_group}"
  else
    nodegroups="$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups[]' --output text 2>/dev/null || true)"
  fi

  if [[ -z "${nodegroups}" ]]; then
    fail "EKS cluster has no nodegroups: ${CLUSTER_NAME}"
    return
  fi

  for nodegroup in ${nodegroups}; do
    [[ -n "${nodegroup}" && "${nodegroup}" != "null" ]] || continue
    status="$(aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${nodegroup}" --query 'nodegroup.status' --output text 2>/dev/null || true)"
    if [[ "${status}" == "ACTIVE" ]]; then
      pass "EKS nodegroup is ACTIVE: ${nodegroup}"
    else
      fail "EKS nodegroup is not ACTIVE: ${nodegroup} status=${status:-unknown}"
    fi
  done
}

kubectl_base_args=()

prepare_kubectl() {
  if ! command_exists kubectl; then
    skip "kubectl not available for Kubernetes/Kata checks"
    return 1
  fi

  if [[ "${USE_TEMP_KUBECONFIG}" == "1" ]]; then
    if ! command_exists aws; then
      skip "aws CLI not available to create temporary kubeconfig"
      return 1
    fi
    [[ -n "${TMP_DIR}" ]] || TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rbi-postdeploy-proof.XXXXXX")"
    local kubeconfig="${TMP_DIR}/kubeconfig"
    if aws eks update-kubeconfig \
      --name "${CLUSTER_NAME}" \
      --region "${AWS_REGION}" \
      --alias "${CLUSTER_NAME}-proof" \
      --kubeconfig "${kubeconfig}" >/dev/null 2>&1; then
      kubectl_base_args=(--kubeconfig "${kubeconfig}")
    else
      warn "could not create temporary kubeconfig for ${CLUSTER_NAME}; trying current kubectl context"
      kubectl_base_args=()
    fi
  fi

  if kubectl "${kubectl_base_args[@]}" cluster-info >/dev/null 2>&1; then
    pass "kubectl can reach the cluster API"
    return 0
  fi

  fail "kubectl cannot reach the cluster API"
  return 1
}

check_kubernetes_kata() {
  local handler kata_nodes control_pods pool_deployment session_job pool_available

  prepare_kubectl || return

  handler="$(kubectl "${kubectl_base_args[@]}" get runtimeclass "${RUNTIME_CLASS}" -o jsonpath='{.handler}' 2>/dev/null || true)"
  if [[ "${handler}" == "kata-clh" ]]; then
    pass "RuntimeClass ${RUNTIME_CLASS} uses handler kata-clh"
  else
    fail "RuntimeClass ${RUNTIME_CLASS} handler mismatch or missing: ${handler:-missing}"
  fi

  if kubectl "${kubectl_base_args[@]}" get namespace "${CONTROL_NAMESPACE}" >/dev/null 2>&1; then
    pass "control namespace exists: ${CONTROL_NAMESPACE}"
  else
    fail "control namespace missing: ${CONTROL_NAMESPACE}"
  fi

  if kubectl "${kubectl_base_args[@]}" get namespace "${WORKER_NAMESPACE}" >/dev/null 2>&1; then
    pass "worker namespace exists: ${WORKER_NAMESPACE}"
  else
    fail "worker namespace missing: ${WORKER_NAMESPACE}"
  fi

  control_pods="$(kubectl "${kubectl_base_args[@]}" -n "${CONTROL_NAMESPACE}" get pods -l cloudsec.cisco.com/rbi-plane=control --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
  if [[ "${control_pods:-0}" -gt 0 ]]; then
    pass "control-plane pods are present in ${CONTROL_NAMESPACE}: ${control_pods}"
  else
    fail "no control-plane pods found in ${CONTROL_NAMESPACE}"
  fi

  kata_nodes="$(kubectl "${kubectl_base_args[@]}" get nodes -l 'cloudsec.cisco.com/rbi-worker-plane=true,cloudsec.cisco.com/node-pool=rbi-workers' --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)"
  if [[ "${KATA_DESIRED}" -gt 0 ]]; then
    if [[ "${kata_nodes:-0}" -gt 0 ]]; then
      pass "Kata worker nodes are registered: ${kata_nodes}"
    else
      fail "Kata worker desired size is ${KATA_DESIRED}, but no labeled Kata nodes are registered"
    fi
  else
    skip "Kata node desired size is zero; node registration proof not required"
  fi

  pool_deployment="$(terraform_output_raw "${ROOT_APPS}" worker_pool_deployment_name || true)"
  pool_deployment="${pool_deployment:-rbi-worker-pool-template}"
  if kubectl "${kubectl_base_args[@]}" -n "${WORKER_NAMESPACE}" get deployment "${pool_deployment}" >/dev/null 2>&1; then
    pool_available="$(kubectl "${kubectl_base_args[@]}" -n "${WORKER_NAMESPACE}" get deployment "${pool_deployment}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    if [[ "${POOL_REPLICAS}" -gt 0 && "${pool_available:-0}" -lt 1 ]]; then
      fail "worker pool deployment exists but has no available replicas: ${pool_deployment}"
    else
      pass "worker pool deployment exists: ${pool_deployment}"
    fi
  else
    fail "worker pool deployment missing: ${pool_deployment}"
  fi

  session_job="$(terraform_output_raw "${ROOT_APPS}" session_worker_job_name || true)"
  session_job="${session_job:-rbi-session-worker-template}"
  if kubectl "${kubectl_base_args[@]}" -n "${WORKER_NAMESPACE}" get job "${session_job}" >/dev/null 2>&1; then
    pass "suspended session worker Job template exists: ${session_job}"
  else
    fail "session worker Job template missing: ${session_job}"
  fi
}

if [[ -n "${RBI_HOST}" ]]; then
  resolve_host "${RBI_HOST}"
  check_tls_certificate "${RBI_HOST}"
else
  skip "RBI public host is unset"
fi

check_acm_certificate
check_privatelink
check_turn
check_eks_aws
check_kubernetes_kata

printf '\nPostdeploy proof summary: pass=%s warn=%s fail=%s skip=%s\n' "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}" "${SKIP_COUNT}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
