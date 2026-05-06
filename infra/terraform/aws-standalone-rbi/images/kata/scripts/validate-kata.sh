#!/usr/bin/env bash
set -euo pipefail

KATA_VALIDATE_KVM="${KATA_VALIDATE_KVM:-true}"
BOOTSTRAP_SCRIPT="${BOOTSTRAP_SCRIPT:-/opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh}"

fatal() {
  printf '[validate-kata] ERROR: %s\n' "$*" >&2
  exit 1
}

find_executable() {
  local binary="$1"
  local candidate
  for candidate in "/usr/bin/${binary}" "/usr/local/bin/${binary}" "/opt/kata/bin/${binary}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
  return 1
}

[[ "${EUID}" -eq 0 ]] || fatal "run as root"
[[ -x "${BOOTSTRAP_SCRIPT}" ]] || fatal "host bootstrap script missing: ${BOOTSTRAP_SCRIPT}"
bash -n "${BOOTSTRAP_SCRIPT}"

if [[ "${KATA_VALIDATE_KVM}" == "true" ]]; then
  [[ -c /dev/kvm ]] || fatal "/dev/kvm missing during AMI validation; build on a bare-metal instance or set validate_kvm=false for scaffold-only builds"
fi

find_executable cloud-hypervisor >/dev/null || fatal "cloud-hypervisor missing"
find_executable containerd-shim-kata-v2 >/dev/null || find_executable containerd-shim-kata-clh-v2 >/dev/null || fatal "Kata shim missing"

systemctl is-enabled containerd >/dev/null 2>&1 || fatal "containerd is not enabled"
systemctl is-active containerd >/dev/null 2>&1 || fatal "containerd is not active"
grep -R -q 'io.containerd.kata-clh.v2' /etc/containerd || fatal "containerd missing kata-clh runtime registration"
grep -R -q 'io.containerd.kata.v2' /etc/containerd || fatal "containerd missing kata runtime registration"

cloud-hypervisor --version >/dev/null 2>&1 || /opt/kata/bin/cloud-hypervisor --version >/dev/null 2>&1 || fatal "cloud-hypervisor does not execute"

printf '[validate-kata] PASS Kata worker AMI prerequisites validated\n'
