#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
TF_ROOT="${REPO_ROOT}/infra/terraform/aws-standalone-rbi"
DEFAULT_CONFIG="${TF_ROOT}/configs/development-ap-south-1.env"

CONFIG_FILE="${DEFAULT_CONFIG}"
STAGE="full"
AUTO_APPROVE=0
SKIP_PREFLIGHT=0

usage() {
  cat <<'EOF'
Run the standalone RBI bootstrap CI sequence.

Usage:
  scripts/rbi-bootstrap-ci.sh [config-file] [options]

Options:
  --config <path>      Env config file to source.
  --stage <name>       Stage to run: full, preflight, bootstrap, identity, global,
                       images, data, secrets, amis, network, eks, apps, proof.
                       Default: full.
  --auto-approve       Pass --auto-approve to Terraform deploy steps.
  --skip-preflight     Skip preflight during full stage.
  -h, --help           Show help.

The script is CI-provider-neutral. Jenkins, GitHub Actions, or a local operator
shell can call the same entrypoint.

When RBI_MANAGE_TF_BACKEND=0, the bootstrap stage is skipped and the script uses
the pre-existing TF_STATE_BUCKET/TF_LOCK_TABLE backend from the config.
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
    --config)
      [[ $# -ge 2 ]] || die "--config requires a path"
      CONFIG_FILE="$(resolve_config_file "$2")"
      shift 2
      ;;
    --stage)
      [[ $# -ge 2 ]] || die "--stage requires a value"
      STAGE="$2"
      shift 2
      ;;
    --auto-approve)
      AUTO_APPROVE=1
      shift
      ;;
    --skip-preflight)
      SKIP_PREFLIGHT=1
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
      CONFIG_FILE="$(resolve_config_file "$1")"
      shift
      ;;
  esac
done

[[ -f "${CONFIG_FILE}" ]] || die "config file not found: ${CONFIG_FILE}"

set -a
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
set +a

MANAGE_TF_BACKEND="${RBI_MANAGE_TF_BACKEND:-0}"
case "${MANAGE_TF_BACKEND}" in
  0|1) ;;
  *) die "unsupported RBI_MANAGE_TF_BACKEND: ${MANAGE_TF_BACKEND}. Expected 0 or 1." ;;
esac

TF_AUTO_APPROVE_ARGS=()
if [[ "${AUTO_APPROVE}" == "1" ]]; then
  TF_AUTO_APPROVE_ARGS+=(--auto-approve)
fi

run_script() {
  local script_name="$1"
  shift

  local script_path="${SCRIPT_DIR}/${script_name}"
  [[ -f "${script_path}" ]] || die "required script is missing: ${script_path}"

  log "${script_name}"
  bash "${script_path}" "${CONFIG_FILE}" "$@"
}

run_script_if_present() {
  local script_name="$1"
  shift

  local script_path="${SCRIPT_DIR}/${script_name}"
  if [[ ! -f "${script_path}" ]]; then
    warn "optional script is missing, skipping: ${script_path}"
    return 0
  fi

  log "${script_name}"
  bash "${script_path}" "${CONFIG_FILE}" "$@"
}

deploy_root() {
  local root="$1"

  log "terraform deploy root=${root}"
  bash "${SCRIPT_DIR}/manage-rbi-env.sh" deploy "${CONFIG_FILE}" --root "${root}" "${TF_AUTO_APPROVE_ARGS[@]}"
}

run_preflight() {
  run_script rbi-preflight.sh "$@"
}

run_bootstrap() {
  if [[ "${MANAGE_TF_BACKEND}" != "1" ]]; then
    log "skip bootstrap/remote-state"
    printf 'Using pre-existing Terraform backend bucket=%s lock_table=%s\n' \
      "${RBI_TF_STATE_BUCKET:-${TF_STATE_BUCKET:-<unset>}}" \
      "${RBI_TF_LOCK_TABLE:-${TF_LOCK_TABLE:-<unset>}}"
    return 0
  fi

  deploy_root bootstrap
}

run_identity() {
  local identity_root="${TF_ROOT}/bootstrap/identity"
  if [[ -d "${identity_root}" ]]; then
    deploy_root identity
  else
    warn "identity root is not present yet, skipping: ${identity_root}"
  fi
}

run_global() {
  deploy_root global
}

run_images() {
  run_script rbi-build-images.sh --build-promote
}

run_data() {
  deploy_root data
}

run_secrets() {
  run_script rbi-bootstrap-secrets.sh
}

run_amis() {
  run_script rbi-build-amis.sh --build-promote
}

run_network() {
  deploy_root network
}

run_eks() {
  deploy_root eks
}

run_apps() {
  if [[ "${RBI_INSTALL_AWS_LOAD_BALANCER_CONTROLLER:-1}" == "1" ]]; then
    run_script rbi-install-aws-load-balancer-controller.sh
  else
    warn "skipping AWS Load Balancer Controller install because RBI_INSTALL_AWS_LOAD_BALANCER_CONTROLLER=0"
  fi

  deploy_root apps

  if [[ "${RBI_SYNC_K8S_SECRETS:-1}" == "1" ]]; then
    run_script rbi-sync-k8s-secrets.sh
  else
    warn "skipping Kubernetes secret sync because RBI_SYNC_K8S_SECRETS=0"
  fi
}

run_proof() {
  run_script_if_present rbi-postdeploy-proof.sh
}

case "${STAGE}" in
  preflight) run_preflight ;;
  bootstrap) run_bootstrap ;;
  identity) run_identity ;;
  global) run_global ;;
  images) run_images ;;
  data) run_data ;;
  secrets) run_secrets ;;
  amis) run_amis ;;
  network) run_network ;;
  eks) run_eks ;;
  apps) run_apps ;;
  proof) run_proof ;;
  full)
    if [[ "${SKIP_PREFLIGHT}" != "1" ]]; then
      run_preflight --warn-only
    fi
    run_bootstrap
    run_identity
    run_global
    run_images
    run_data
    run_secrets
    run_amis
    run_preflight
    run_network
    run_eks
    run_apps
    run_proof
    ;;
  *)
    die "unsupported stage: ${STAGE}"
    ;;
esac
