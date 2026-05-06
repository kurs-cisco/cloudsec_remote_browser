#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EKS_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="$(cd -- "${EKS_DIR}/.." && pwd)"
NODE_BOOTSTRAP_DIR="${DEPLOY_DIR}/node-bootstrap"
PROOF_DIR="${EKS_DIR}/proof"
PROOF_EGRESS_DIR="${PROOF_DIR}/egress"
KUBECTL="${KUBECTL:-kubectl}"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"
MODE="${1:-offline}"
RENDER_TMP_DIR=""
LIVE_CHECK_TMP_DIR=""

log() {
  printf '%s\n' "$*"
}

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || fatal "missing required command: ${cmd}"
  done
}

require_kubectl() {
  command -v "${KUBECTL}" >/dev/null 2>&1 || fatal "missing required command: ${KUBECTL}"
}

kubectl_cmd() {
  if [[ -n "${KUBECTL_CONTEXT}" ]]; then
    "${KUBECTL}" --context "${KUBECTL_CONTEXT}" "$@"
  else
    "${KUBECTL}" "$@"
  fi
}

check_no_placeholders() {
  local file="$1"
  if grep -q '__[A-Z0-9_][A-Z0-9_]*__' "${file}"; then
    fatal "rendered file still contains template placeholders: ${file}"
  fi
}

require_static_value() {
  local file="$1"
  local needle="$2"
  local message="$3"
  grep -Fq -- "${needle}" "${file}" || fatal "${message}"
}

syntax_checks() {
  require_cmd bash python3
  log "Checking shell syntax"
  bash -n "${EKS_DIR}/render-rbi-worker-launch-template.sh"
  bash -n "${SCRIPT_DIR}/prove-rbi-worker-node-contract.sh"
  bash -n "${SCRIPT_DIR}/validate-wave3-kata-eks.sh"
  bash -n "${NODE_BOOTSTRAP_DIR}/scripts/bootstrap-kata-worker-host.sh"
  bash -n "${NODE_BOOTSTRAP_DIR}/scripts/rbi-worker-ami-image-pipeline.sh"
  python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
    "${PROOF_EGRESS_DIR}/scripts/rbi_worker_egress_proof.py"
}

kustomize_checks() {
  require_kubectl
  log "Checking kubectl kustomize for worker manifests"
  kubectl_cmd kustomize "${EKS_DIR}" >/dev/null
  log "Checking kubectl kustomize for live proof manifests"
  kubectl_cmd kustomize "${PROOF_DIR}" >/dev/null
  log "Checking kubectl kustomize for worker egress proof manifests"
  kubectl_cmd kustomize "${PROOF_EGRESS_DIR}" >/dev/null
}

render_checks() {
  log "Checking launch-template render path with placeholder inputs"

  RENDER_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloudsec-rbi-wave3-render.XXXXXX")"
  trap 'rm -rf "${RENDER_TMP_DIR}"' EXIT

  AWS_REGION="us-east-1" \
  EKS_CLUSTER_NAME="wave3-render-check" \
  EKS_API_SERVER_ENDPOINT="https://example.invalid" \
  EKS_CERTIFICATE_AUTHORITY_B64="LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCg==" \
  EKS_SERVICE_IPV4_CIDR="10.100.0.0/16" \
  RBI_AMI_ID="ami-0123456789abcdef0" \
  RBI_INSTANCE_TYPE="c5.metal" \
  RBI_SECURITY_GROUP_IDS_JSON='["sg-0123456789abcdef0"]' \
  OUTPUT_DIR="${RENDER_TMP_DIR}" \
    "${EKS_DIR}/render-rbi-worker-launch-template.sh" >/dev/null

  check_no_placeholders "${RENDER_TMP_DIR}/rbi-worker-user-data.mime"
  check_no_placeholders "${RENDER_TMP_DIR}/rbi-worker-launch-template-data.json"
  check_no_placeholders "${RENDER_TMP_DIR}/rbi-worker-nodegroup.eksctl.yaml"

  grep -q 'cloudsec.cisco.com/rbi-worker-plane=true' "${RENDER_TMP_DIR}/rbi-worker-user-data.mime" || \
    fatal "rendered user-data missing worker-plane node label"
  grep -q 'cloudsec.cisco.com/rbi-worker-plane=true:NoSchedule' "${RENDER_TMP_DIR}/rbi-worker-user-data.mime" || \
    fatal "rendered user-data missing worker-plane taint"
  grep -q '"HttpTokens": "required"' "${RENDER_TMP_DIR}/rbi-worker-launch-template-data.json" || \
    fatal "rendered launch template missing IMDSv2 requirement"
  grep -q 'launchTemplate:' "${RENDER_TMP_DIR}/rbi-worker-nodegroup.eksctl.yaml" || \
    fatal "rendered nodegroup missing launchTemplate block"
}

worker_egress_lockdown_checks() {
  local policy="${EKS_DIR}/rbi-worker-network-policy.yaml"
  local shared_config="${EKS_DIR}/rbi-worker-shared-configmap.yaml"

  log "Checking worker egress lockdown contracts"

  if grep -Eq '^[[:space:]]*cidr:[[:space:]]*0\.0\.0\.0/0([[:space:]]|$)' "${policy}"; then
    fatal "worker NetworkPolicy must not allow broad 0.0.0.0/0 direct egress"
  fi
  if grep -Eq '^[[:space:]]*ipBlock:' "${policy}"; then
    fatal "worker NetworkPolicy egress must use label selectors instead of ipBlock CIDRs"
  fi

  require_static_value "${policy}" 'k8s-app: kube-dns' \
    "worker NetworkPolicy missing CoreDNS pod selector"
  require_static_value "${policy}" 'port: 53' \
    "worker NetworkPolicy missing DNS port allowance"
  require_static_value "${policy}" 'cloudsec.cisco.com/rbi-plane: control' \
    "worker NetworkPolicy missing labeled control-plane egress selector"
  require_static_value "${policy}" 'cloudsec.cisco.com/rbi-plane: media' \
    "worker NetworkPolicy missing labeled media-plane egress selector"
  require_static_value "${policy}" 'app.kubernetes.io/component: media-gateway' \
    "worker NetworkPolicy missing media-gateway pod selector"
  require_static_value "${policy}" 'app.kubernetes.io/component: turn' \
    "worker NetworkPolicy missing TURN pod selector"
  require_static_value "${policy}" 'cloudsec.cisco.com/egress-plane: swg' \
    "worker NetworkPolicy missing SWG egress namespace selector"
  require_static_value "${policy}" 'app.kubernetes.io/component: swg-proxy' \
    "worker NetworkPolicy missing SWG proxy pod selector"
  require_static_value "${policy}" 'port: 3478' \
    "worker NetworkPolicy missing TURN port allowance"
  require_static_value "${policy}" 'port: 3128' \
    "worker NetworkPolicy missing SWG proxy port allowance"

  require_static_value "${shared_config}" 'SWG_EGRESS_PROXY_URL:' \
    "worker shared config missing SWG proxy placeholder"
  require_static_value "${shared_config}" 'media-gateway.cloudsec-rbi-media.svc.cluster.local' \
    "worker shared config missing media gateway service placeholder"
  require_static_value "${shared_config}" 'turn.cloudsec-rbi-media.svc.cluster.local' \
    "worker shared config missing TURN service placeholder"
  require_static_value "${shared_config}" 'HTTPS_PROXY:' \
    "worker shared config missing HTTPS_PROXY default"
  require_static_value "${shared_config}" 'NO_PROXY:' \
    "worker shared config missing NO_PROXY default"
}

egress_proof_static_checks() {
  local proof_script="${PROOF_EGRESS_DIR}/scripts/rbi_worker_egress_proof.py"
  local proof_kustomization="${PROOF_EGRESS_DIR}/kustomization.yaml"
  local proof_job="${PROOF_EGRESS_DIR}/rbi-worker-egress-proof-job.yaml"

  log "Checking worker egress proof contracts"

  require_static_value "${proof_kustomization}" 'namespace: cloudsec-rbi-workers' \
    "egress proof must run in the worker namespace to exercise worker NetworkPolicy"
  require_static_value "${proof_kustomization}" 'rbi-worker-egress-proof-script' \
    "egress proof missing script ConfigMap generator"
  require_static_value "${proof_kustomization}" 'rbi_worker_egress_proof.py=scripts/rbi_worker_egress_proof.py' \
    "egress proof missing Python script source"
  require_static_value "${proof_kustomization}" 'cloudsec-remote-browser-worker' \
    "egress proof kustomization missing worker image transformer"

  require_static_value "${proof_job}" 'kind: Job' \
    "egress proof must run as a one-shot Job"
  require_static_value "${proof_job}" 'runtimeClassName: kata-clh' \
    "egress proof Job must use Kata RuntimeClass"
  require_static_value "${proof_job}" 'serviceAccountName: rbi-worker' \
    "egress proof Job must use the worker ServiceAccount"
  require_static_value "${proof_job}" 'automountServiceAccountToken: false' \
    "egress proof Job must not mount a Kubernetes service account token"
  require_static_value "${proof_job}" 'image: cloudsec-remote-browser-worker:latest' \
    "egress proof Job must use the worker image"
  require_static_value "${proof_job}" '/proof/rbi_worker_egress_proof.py' \
    "egress proof Job must execute the mounted Python script"
  require_static_value "${proof_job}" 'rbi-worker-shared-config' \
    "egress proof Job must inherit worker proxy/media config"
  require_static_value "${proof_job}" 'EGRESS_PROOF_PUBLIC_URL' \
    "egress proof Job missing public HTTPS proof target"
  require_static_value "${proof_job}" '169.254.169.254' \
    "egress proof Job missing metadata deny target"
  require_static_value "${proof_job}" 'kubernetes.default.svc:443' \
    "egress proof Job missing Kubernetes API deny target"
  require_static_value "${proof_job}" 'redis.cloudsec-rbi-control.svc.cluster.local:6379' \
    "egress proof Job missing Redis deny target"
  require_static_value "${proof_job}" '8.8.8.8:53' \
    "egress proof Job missing public DNS deny target"

  require_static_value "${proof_script}" 'urllib.request.ProxyHandler({})' \
    "egress proof script must disable proxy env for direct probes"
  require_static_value "${proof_script}" 'proxied_public_https' \
    "egress proof script missing proxied public HTTPS assertion"
  require_static_value "${proof_script}" 'direct_public_https' \
    "egress proof script missing direct public HTTPS assertion"
  require_static_value "${proof_script}" 'direct_metadata_http' \
    "egress proof script missing direct metadata assertion"
  require_static_value "${proof_script}" 'direct_kube_api' \
    "egress proof script missing direct Kubernetes API assertion"
  require_static_value "${proof_script}" 'direct_redis' \
    "egress proof script missing direct Redis assertion"
  require_static_value "${proof_script}" 'direct_public_dns_8_8_8_8_53' \
    "egress proof script missing public DNS deny assertion"
  require_static_value "${proof_script}" 'proxied_internal_deny_' \
    "egress proof script missing proxied internal deny assertion"
  require_static_value "${proof_script}" 'control_wss' \
    "egress proof script missing control WSS assertion"
  require_static_value "${proof_script}" 'media_gateway_wss' \
    "egress proof script missing media gateway WSS assertion"
  require_static_value "${proof_script}" 'turn_udp' \
    "egress proof script missing TURN UDP assertion"
  require_static_value "${proof_script}" 'STUN_MAGIC_COOKIE' \
    "egress proof script missing STUN/TURN UDP proof"
}

static_contract_checks() {
  log "Checking static Wave 3 contracts"

  grep -q 'handler: kata-clh' "${EKS_DIR}/kata-runtimeclass.yaml" || \
    fatal "RuntimeClass handler is not kata-clh"
  grep -q 'cloudsec.cisco.com/rbi-worker-plane: "true"' "${EKS_DIR}/kata-runtimeclass.yaml" || \
    fatal "RuntimeClass scheduling missing worker-plane selector"
  grep -q -- '--register-with-taints=__RBI_NODE_TAINTS__' "${NODE_BOOTSTRAP_DIR}/user-data/al2023-kata-worker-user-data.mime" || \
    fatal "user-data template missing taint placeholder flow"
  grep -q 'runtimeClassName: kata-clh' "${EKS_DIR}/rbi-worker-pool-deployment.yaml" || \
    fatal "worker pool does not use kata-clh"
  grep -q 'runtimeClassName: kata-clh' "${EKS_DIR}/rbi-session-worker-job.yaml" || \
    fatal "session worker does not use kata-clh"
  worker_egress_lockdown_checks
  egress_proof_static_checks
}

live_checks() {
  require_kubectl
  log "Checking live cluster RuntimeClass"
  kubectl_cmd get runtimeclass kata-clh

  log "Checking live cluster RBI worker node labels and taints"
  KUBECTL="${KUBECTL}" KUBECTL_CONTEXT="${KUBECTL_CONTEXT}" \
    "${SCRIPT_DIR}/prove-rbi-worker-node-contract.sh"
}

proof_apply() {
  require_kubectl
  log "Applying live proof manifests"
  kubectl_cmd apply -k "${PROOF_DIR}"
  kubectl_cmd -n cloudsec-rbi-kata-proof wait --for=jsonpath='{.status.phase}'=Succeeded pod/kata-runtimeclass-proof --timeout=240s
  kubectl_cmd -n cloudsec-rbi-kata-proof logs pod/kata-runtimeclass-proof
}

live_egress_prereq_checks() {
  require_kubectl

  LIVE_CHECK_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloudsec-rbi-wave3-live.XXXXXX")"
  trap 'rm -rf "${RENDER_TMP_DIR:-}" "${LIVE_CHECK_TMP_DIR:-}"' EXIT

  local live_policy="${LIVE_CHECK_TMP_DIR}/worker-network-policy.yaml"
  local live_config="${LIVE_CHECK_TMP_DIR}/worker-shared-config.yaml"

  log "Checking live worker egress proof prerequisites"
  kubectl_cmd get namespace cloudsec-rbi-workers >/dev/null
  kubectl_cmd -n cloudsec-rbi-workers get serviceaccount rbi-worker >/dev/null
  kubectl_cmd -n cloudsec-rbi-workers get configmap rbi-worker-shared-config -o yaml >"${live_config}"
  kubectl_cmd -n cloudsec-rbi-workers get networkpolicy cloudsec-rbi-worker-egress -o yaml >"${live_policy}"

  if grep -Eq '^[[:space:]]*cidr:[[:space:]]*0\.0\.0\.0/0([[:space:]]|$)' "${live_policy}"; then
    fatal "live worker NetworkPolicy still allows broad 0.0.0.0/0 direct egress; apply the locked-down worker policy before apply-egress-proof"
  fi
  if grep -Eq '^[[:space:]]*ipBlock:' "${live_policy}"; then
    fatal "live worker NetworkPolicy still uses ipBlock CIDRs; apply the label-selector worker policy before apply-egress-proof"
  fi

  require_static_value "${live_policy}" 'k8s-app: kube-dns' \
    "live worker NetworkPolicy missing CoreDNS egress allowance"
  require_static_value "${live_policy}" 'cloudsec.cisco.com/rbi-plane: control' \
    "live worker NetworkPolicy missing control-plane selector"
  require_static_value "${live_policy}" 'app.kubernetes.io/component: media-gateway' \
    "live worker NetworkPolicy missing media-gateway selector"
  require_static_value "${live_policy}" 'app.kubernetes.io/component: turn' \
    "live worker NetworkPolicy missing TURN selector"
  require_static_value "${live_policy}" 'app.kubernetes.io/component: swg-proxy' \
    "live worker NetworkPolicy missing SWG proxy selector"

  require_static_value "${live_config}" 'POOL_WS_URL:' \
    "live worker shared config missing POOL_WS_URL"
  require_static_value "${live_config}" 'SIGNALING_URL:' \
    "live worker shared config missing SIGNALING_URL"
  require_static_value "${live_config}" 'WORKER_ICE_URLS:' \
    "live worker shared config missing WORKER_ICE_URLS"
  require_static_value "${live_config}" 'transport=udp' \
    "live worker shared config must prefer UDP TURN"
  require_static_value "${live_config}" 'SWG_EGRESS_PROXY_URL:' \
    "live worker shared config missing SWG_EGRESS_PROXY_URL"
  require_static_value "${live_config}" 'HTTP_PROXY:' \
    "live worker shared config missing HTTP_PROXY"
  require_static_value "${live_config}" 'HTTPS_PROXY:' \
    "live worker shared config missing HTTPS_PROXY"
}

egress_proof_apply() {
  require_kubectl
  log "Applying worker egress proof manifests"
  kubectl_cmd -n cloudsec-rbi-workers delete job/rbi-worker-egress-proof --ignore-not-found
  kubectl_cmd apply -k "${PROOF_EGRESS_DIR}"
  if ! kubectl_cmd -n cloudsec-rbi-workers wait --for=condition=Complete job/rbi-worker-egress-proof --timeout=420s; then
    kubectl_cmd -n cloudsec-rbi-workers describe job/rbi-worker-egress-proof || true
    kubectl_cmd -n cloudsec-rbi-workers logs job/rbi-worker-egress-proof --all-containers=true || true
    fatal "worker egress proof Job did not complete successfully"
  fi
  kubectl_cmd -n cloudsec-rbi-workers logs job/rbi-worker-egress-proof --all-containers=true
}

usage() {
  cat <<'EOF'
Usage: validate-wave3-kata-eks.sh [offline|live|apply-proof|preflight-egress|apply-egress-proof]

Modes:
  offline             Run shell/Python syntax, kubectl kustomize, static contract, and render checks.
  live                Run offline checks plus RuntimeClass and node label/taint proof against the current kubeconfig.
  apply-proof         Run live checks, apply RuntimeClass proof manifests, wait for the Kata pod, and print proof logs.
  preflight-egress    Run live checks plus live worker NetworkPolicy/config checks required by the egress proof.
  apply-egress-proof  Run live checks, apply worker-image egress proof Job, wait for completion, and print proof logs.

Environment:
  KUBECTL              kubectl executable path. Defaults to kubectl.
  KUBECTL_CONTEXT      optional kube context passed as --context to every kubectl call.
EOF
}

main() {
  case "${MODE}" in
    -h|--help)
      usage
      ;;
    offline)
      syntax_checks
      kustomize_checks
      static_contract_checks
      render_checks
      log "PASS offline Wave 3 Kata/EKS validation"
      ;;
    live)
      syntax_checks
      kustomize_checks
      static_contract_checks
      render_checks
      live_checks
      log "PASS live Wave 3 Kata/EKS validation"
      ;;
    apply-proof)
      syntax_checks
      kustomize_checks
      static_contract_checks
      render_checks
      live_checks
      proof_apply
      log "PASS live Wave 3 Kata RuntimeClass proof"
      ;;
    preflight-egress)
      syntax_checks
      kustomize_checks
      static_contract_checks
      render_checks
      live_checks
      live_egress_prereq_checks
      log "PASS live Wave 3 Kata worker egress preflight"
      ;;
    apply-egress-proof)
      syntax_checks
      kustomize_checks
      static_contract_checks
      render_checks
      live_checks
      live_egress_prereq_checks
      egress_proof_apply
      log "PASS live Wave 3 Kata worker egress proof"
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
