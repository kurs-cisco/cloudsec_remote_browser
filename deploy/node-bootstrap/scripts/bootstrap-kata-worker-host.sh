#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${LOG_FILE:-/var/log/cloudsec-rbi-node-bootstrap.log}"
STATE_DIR="${STATE_DIR:-/var/lib/cloudsec-rbi-node-bootstrap}"
MODULES_FILE="${MODULES_FILE:-/etc/modules-load.d/cloudsec-rbi-kata.conf}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/95-cloudsec-rbi-worker.conf}"
KATA_RUNTIME_CLASS="${KATA_RUNTIME_CLASS:-kata-clh}"
KATA_EXPECTED_RUNTIME_TYPES="${KATA_EXPECTED_RUNTIME_TYPES:-io.containerd.kata-clh.v2 io.containerd.kata.v2}"

mkdir -p "$(dirname "${LOG_FILE}")" "${STATE_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fatal() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fatal "run as root"
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || fatal "missing required command: ${cmd}"
  done
}

detect_vendor_module() {
  if grep -q 'AuthenticAMD' /proc/cpuinfo; then
    printf 'kvm_amd\n'
    return
  fi
  printf 'kvm_intel\n'
}

load_module() {
  local module="$1"
  if lsmod | awk '{print $1}' | grep -qx "${module}"; then
    return
  fi
  modprobe "${module}" || fatal "failed to load kernel module ${module}"
}

persist_modules() {
  local vendor_module
  vendor_module="$(detect_vendor_module)"
  cat >"${MODULES_FILE}" <<EOF
overlay
br_netfilter
kvm
${vendor_module}
vhost_vsock
EOF
}

apply_host_sysctls() {
  cat >"${SYSCTL_FILE}" <<'EOF'
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.unprivileged_bpf_disabled = 1
kernel.unprivileged_userns_clone = 0
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
vm.unprivileged_userfaultfd = 0
EOF
  sysctl --system >/dev/null
}

verify_arch() {
  local arch
  arch="$(uname -m)"
  if [[ "${arch}" != "x86_64" ]]; then
    log "WARN: expected x86_64 for the current RBI worker image/tooling, got ${arch}"
  fi
}

verify_kvm() {
  [[ -c /dev/kvm ]] || fatal "/dev/kvm is missing; use a bare-metal node group with hardware virtualization available"
}

verify_runtime_artifacts() {
  local found=0
  local candidate
  for candidate in \
    /usr/bin/containerd-shim-kata-v2 \
    /usr/local/bin/containerd-shim-kata-v2 \
    /opt/kata/bin/containerd-shim-kata-v2 \
    /usr/bin/containerd-shim-kata-clh-v2 \
    /usr/local/bin/containerd-shim-kata-clh-v2 \
    /opt/kata/bin/containerd-shim-kata-clh-v2
  do
    if [[ -x "${candidate}" ]]; then
      log "found Kata shim: ${candidate}"
      found=1
      break
    fi
  done
  [[ "${found}" -eq 1 ]] || fatal "no Kata shim binary found in standard locations"

  found=0
  for candidate in /usr/bin/cloud-hypervisor /usr/local/bin/cloud-hypervisor /opt/kata/bin/cloud-hypervisor; do
    if [[ -x "${candidate}" ]]; then
      log "found Cloud Hypervisor: ${candidate}"
      found=1
      break
    fi
  done
  [[ "${found}" -eq 1 ]] || fatal "cloud-hypervisor not found in standard locations"
}

copy_runtime_binary() {
  local source="$1"
  local target="$2"

  if [[ "${target}" -ef "${source}" ]]; then
    chmod 0755 "${target}"
    return
  fi

  if [[ -L "${target}" ]]; then
    rm -f "${target}"
  fi

  install -m 0755 "${source}" "${target}"
  log "installed ${target} from ${source}"
}

copy_runtime_artifacts() {
  local shim_path=""
  local clh_path=""
  local candidate
  local target

  for candidate in \
    /usr/bin/containerd-shim-kata-v2 \
    /usr/local/bin/containerd-shim-kata-v2 \
    /opt/kata/bin/containerd-shim-kata-v2 \
    /usr/bin/containerd-shim-kata-clh-v2 \
    /usr/local/bin/containerd-shim-kata-clh-v2 \
    /opt/kata/bin/containerd-shim-kata-clh-v2
  do
    if [[ -x "${candidate}" ]]; then
      shim_path="${candidate}"
      break
    fi
  done

  for candidate in /usr/bin/cloud-hypervisor /usr/local/bin/cloud-hypervisor /opt/kata/bin/cloud-hypervisor; do
    if [[ -x "${candidate}" ]]; then
      clh_path="${candidate}"
      break
    fi
  done

  [[ -n "${shim_path}" ]] || fatal "Kata shim binary not found for runtime links"
  [[ -n "${clh_path}" ]] || fatal "Cloud Hypervisor binary not found for runtime links"

  install -d -m 0755 /usr/local/bin
  for target in \
    /usr/local/bin/containerd-shim-kata-v2 \
    /usr/local/bin/containerd-shim-kata-clh-v2 \
    /usr/bin/containerd-shim-kata-v2 \
    /usr/bin/containerd-shim-kata-clh-v2
  do
    copy_runtime_binary "${shim_path}" "${target}"
  done

  for target in /usr/local/bin/cloud-hypervisor /usr/bin/cloud-hypervisor; do
    copy_runtime_binary "${clh_path}" "${target}"
  done
}

wait_for_service() {
  local service="$1"
  local attempts="${2:-30}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if systemctl is-active --quiet "${service}"; then
      return
    fi
    sleep 2
  done
  fatal "${service} did not become active"
}

configure_containerd_cri_runtime() {
  mkdir -p /etc/containerd/conf.d
  cat >/etc/containerd/conf.d/99-cloudsec-rbi-kata-grpc-cri.toml <<'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = false
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh.options]
    ConfigPath = "/etc/kata-containers/configuration-clh.toml"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = false
EOF
  systemctl restart containerd
}

wait_for_runtime_registration() {
  local attempts="${1:-30}"
  local i
  local runtime_hits
  local expected_type

  for ((i = 1; i <= attempts; i++)); do
    runtime_hits="$(grep -R -n "runtimes\\.${KATA_RUNTIME_CLASS}\\|runtimes\\.kata" /etc/containerd 2>/dev/null || true)"
    if [[ -n "${runtime_hits}" ]]; then
      log "containerd runtime registration found:"
      printf '%s\n' "${runtime_hits}"

      for expected_type in ${KATA_EXPECTED_RUNTIME_TYPES}; do
        if grep -R -q "${expected_type}" /etc/containerd 2>/dev/null; then
          log "containerd runtime type present: ${expected_type}"
          return
        fi
      done
    fi
    sleep 2
  done

  fatal "containerd config missing expected runtime types: ${KATA_EXPECTED_RUNTIME_TYPES}"
}

main() {
  log "starting Cloudsec RBI Kata host bootstrap"
  require_root
  require_cmd awk chmod grep install lsmod modprobe rm sysctl systemctl tee uname

  verify_arch
  persist_modules
  load_module overlay
  load_module br_netfilter
  load_module kvm
  load_module "$(detect_vendor_module)"
  load_module vhost_vsock

  apply_host_sysctls
  verify_kvm
  verify_runtime_artifacts
  copy_runtime_artifacts
  wait_for_service containerd 45
  configure_containerd_cri_runtime
  wait_for_service containerd 45
  wait_for_runtime_registration 45

  touch "${STATE_DIR}/bootstrap-complete"
  log "Cloudsec RBI Kata host bootstrap complete"
}

main "$@"
