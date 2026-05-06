#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
KUBECTL_CONTEXT="${KUBECTL_CONTEXT:-}"
NODE_SELECTOR="${RBI_WORKER_NODE_SELECTOR:-cloudsec.cisco.com/rbi-worker-plane=true}"
EXPECTED_WORKER_LABEL_KEY="${EXPECTED_WORKER_LABEL_KEY:-cloudsec.cisco.com/rbi-worker-plane}"
EXPECTED_WORKER_LABEL_VALUE="${EXPECTED_WORKER_LABEL_VALUE:-true}"
EXPECTED_POOL_LABEL_KEY="${EXPECTED_POOL_LABEL_KEY:-cloudsec.cisco.com/node-pool}"
EXPECTED_POOL_LABEL_VALUE="${EXPECTED_POOL_LABEL_VALUE:-rbi-workers}"
EXPECTED_TAINT_KEY="${EXPECTED_TAINT_KEY:-cloudsec.cisco.com/rbi-worker-plane}"
EXPECTED_TAINT_VALUE="${EXPECTED_TAINT_VALUE:-true}"
EXPECTED_TAINT_EFFECT="${EXPECTED_TAINT_EFFECT:-NoSchedule}"

log() {
  printf '%s\n' "$*"
}

fatal() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

kubectl_cmd() {
  if [[ -n "${KUBECTL_CONTEXT}" ]]; then
    "${KUBECTL}" --context "${KUBECTL_CONTEXT}" "$@"
  else
    "${KUBECTL}" "$@"
  fi
}

node_label() {
  local node="$1"
  local key="$2"
  kubectl_cmd get node "${node}" -o "go-template={{ index .metadata.labels \"${key}\" }}"
}

node_taints() {
  local node="$1"
  kubectl_cmd get node "${node}" -o 'go-template={{ range .spec.taints }}{{ .key }}={{ .value }}:{{ .effect }} {{ end }}'
}

main() {
  command -v "${KUBECTL}" >/dev/null 2>&1 || fatal "kubectl is not installed or not in PATH"

  local nodes
  nodes="$(kubectl_cmd get nodes -l "${NODE_SELECTOR}" -o 'go-template={{ range .items }}{{ .metadata.name }}{{ "\n" }}{{ end }}')"
  [[ -n "${nodes}" ]] || fatal "no nodes matched selector ${NODE_SELECTOR}"

  log "RBI worker node contract proof"
  log "selector=${NODE_SELECTOR}"

  local node
  local worker_label
  local pool_label
  local taints
  local expected_taint="${EXPECTED_TAINT_KEY}=${EXPECTED_TAINT_VALUE}:${EXPECTED_TAINT_EFFECT}"

  while IFS= read -r node; do
    [[ -n "${node}" ]] || continue
    worker_label="$(node_label "${node}" "${EXPECTED_WORKER_LABEL_KEY}")"
    pool_label="$(node_label "${node}" "${EXPECTED_POOL_LABEL_KEY}")"
    taints="$(node_taints "${node}")"

    [[ "${worker_label}" == "${EXPECTED_WORKER_LABEL_VALUE}" ]] || \
      fatal "${node} missing ${EXPECTED_WORKER_LABEL_KEY}=${EXPECTED_WORKER_LABEL_VALUE}; got ${worker_label:-<empty>}"
    [[ "${pool_label}" == "${EXPECTED_POOL_LABEL_VALUE}" ]] || \
      fatal "${node} missing ${EXPECTED_POOL_LABEL_KEY}=${EXPECTED_POOL_LABEL_VALUE}; got ${pool_label:-<empty>}"
    [[ " ${taints} " == *" ${expected_taint} "* ]] || \
      fatal "${node} missing taint ${expected_taint}; got ${taints:-<none>}"

    log "PASS ${node} labels ${EXPECTED_WORKER_LABEL_KEY}=${worker_label} ${EXPECTED_POOL_LABEL_KEY}=${pool_label} taints=${taints}"
  done <<<"${nodes}"

  log "PASS all RBI worker nodes satisfy label and taint contract"
}

main "$@"
