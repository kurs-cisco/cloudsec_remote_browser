#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NODE_BOOTSTRAP_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="$(cd -- "${NODE_BOOTSTRAP_DIR}/.." && pwd)"
EKS_DIR="${DEPLOY_DIR}/eks"
MODE="${1:-check}"

log() {
  printf '%s\n' "$*"
}

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_file() {
  local file="$1"
  [[ -f "${file}" ]] || fatal "missing file: ${file}"
}

require_executable() {
  local file="$1"
  [[ -x "${file}" ]] || fatal "not executable: ${file}"
}

check_local_artifacts() {
  log "Checking local AMI/image pipeline artifacts"
  require_file "${NODE_BOOTSTRAP_DIR}/ami-prerequisites-checklist.md"
  require_file "${NODE_BOOTSTRAP_DIR}/security-hardening-notes.md"
  require_file "${NODE_BOOTSTRAP_DIR}/user-data/al2023-kata-worker-user-data.mime"
  require_executable "${NODE_BOOTSTRAP_DIR}/scripts/bootstrap-kata-worker-host.sh"
  require_executable "${EKS_DIR}/render-rbi-worker-launch-template.sh"
  bash -n "${NODE_BOOTSTRAP_DIR}/scripts/bootstrap-kata-worker-host.sh"
  bash -n "${EKS_DIR}/render-rbi-worker-launch-template.sh"
  grep -q 'containerd.runtimes.kata-clh' "${NODE_BOOTSTRAP_DIR}/user-data/al2023-kata-worker-user-data.mime" || \
    fatal "user-data template missing kata-clh containerd runtime registration"
  grep -q 'HttpTokens' "${EKS_DIR}/rbi-worker-launch-template-data.json" || \
    fatal "launch-template template missing IMDSv2 settings"
  log "PASS local artifacts are present and syntactically valid"
}

print_required_inputs() {
  cat <<'EOF'
Required environment for a real promotion:
  AWS_REGION
  EKS_CLUSTER_NAME
  EKS_API_SERVER_ENDPOINT
  EKS_CERTIFICATE_AUTHORITY_B64
  EKS_SERVICE_IPV4_CIDR
  RBI_AMI_ID
  RBI_INSTANCE_TYPE
  RBI_SECURITY_GROUP_IDS_JSON
  RBI_LAUNCH_TEMPLATE_NAME
  RBI_LAUNCH_TEMPLATE_VERSION
  RBI_WORKER_IMAGE

Recommended provenance inputs:
  RBI_AMI_BUILD_ID
  RBI_WORKER_IMAGE_DIGEST
  RBI_SBOM_PATH
  RBI_PROVENANCE_PATH
EOF
}

emit_commands() {
  cat <<'EOF'
# 1. Build the custom AL2023 EKS AMI in your image builder.
#    Bake this file into the image:
#      /opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh
#    Source artifact:
#      cloudsec_remote_browser/deploy/node-bootstrap/scripts/bootstrap-kata-worker-host.sh

# 2. Validate the AMI before promotion.
cloud-hypervisor --version
ls -l /dev/kvm
grep -R "runtimes.kata-clh" /etc/containerd
systemctl status containerd

# 3. Build and publish the worker image from cloudsec_remote_browser.
docker build -t cloudsec-remote-browser-worker ./worker
docker tag cloudsec-remote-browser-worker:latest "$RBI_WORKER_IMAGE"
docker push "$RBI_WORKER_IMAGE"

# 4. Record immutable image provenance before rollout.
docker inspect "$RBI_WORKER_IMAGE" --format='{{index .RepoDigests 0}}'

# 5. Render AL2023 user-data, EC2 launch template input, and eksctl nodegroup config.
cloudsec_remote_browser/deploy/eks/render-rbi-worker-launch-template.sh

# 6. Create or rotate the launch template.
aws ec2 create-launch-template \
  --cli-input-json file://cloudsec_remote_browser/deploy/eks/rendered/rbi-worker-launch-template-data.json

# 7. Create the dedicated managed node group.
eksctl create nodegroup \
  -f cloudsec_remote_browser/deploy/eks/rendered/rbi-worker-nodegroup.eksctl.yaml

# 8. Set the worker image and apply manifests.
cd cloudsec_remote_browser/deploy/eks
kustomize edit set image cloudsec-remote-browser-worker="$RBI_WORKER_IMAGE"
kubectl apply -k .

# 9. Prove RuntimeClass, node labels, taints, and a Kata-backed proof pod.
cloudsec_remote_browser/deploy/eks/scripts/validate-wave3-kata-eks.sh apply-proof
EOF
}

usage() {
  cat <<'EOF'
Usage: rbi-worker-ami-image-pipeline.sh [check|inputs|emit-commands]

Modes:
  check          Validate local AMI/user-data/render artifacts without AWS credentials.
  inputs         Print required and recommended environment inputs for promotion.
  emit-commands  Print the real promotion command sequence for CI/IaC adaptation.
EOF
}

main() {
  case "${MODE}" in
    -h|--help)
      usage
      ;;
    check)
      check_local_artifacts
      ;;
    inputs)
      print_required_inputs
      ;;
    emit-commands)
      check_local_artifacts
      print_required_inputs
      emit_commands
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
