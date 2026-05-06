#!/usr/bin/env bash
set -euo pipefail

KATA_RPM_URLS="${KATA_RPM_URLS:-}"
KATA_STATIC_TARBALL_URL="${KATA_STATIC_TARBALL_URL:-}"
CLOUD_HYPERVISOR_RPM_URL="${CLOUD_HYPERVISOR_RPM_URL:-}"
CLOUD_HYPERVISOR_BINARY_URL="${CLOUD_HYPERVISOR_BINARY_URL:-}"
BOOTSTRAP_DST="${BOOTSTRAP_DST:-/opt/cloudsec/node-bootstrap/bootstrap-kata-worker-host.sh}"

log() {
  printf '[install-kata] %s\n' "$*"
}

fatal() {
  printf '[install-kata] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || fatal "run as root"

wait_for_bootstrap_package_activity() {
  if command -v cloud-init >/dev/null 2>&1; then
    log "waiting for cloud-init to finish"
    cloud-init status --wait || fatal "cloud-init did not finish cleanly"
  fi

  log "waiting for package manager locks"
  for _ in $(seq 1 60); do
    if ! pgrep -x dnf >/dev/null 2>&1 && ! pgrep -x rpm >/dev/null 2>&1 && ! pgrep -x yum >/dev/null 2>&1; then
      return
    fi
    sleep 5
  done

  fatal "package manager lock did not clear"
}

install_packages() {
  dnf install -y \
    awscli \
    containerd \
    gzip \
    iproute \
    iptables \
    jq \
    kmod \
    tar \
    xz \
    zstd
}

install_cloud_hypervisor() {
  if command -v cloud-hypervisor >/dev/null 2>&1 || [[ -x /opt/kata/bin/cloud-hypervisor ]]; then
    return
  fi

  if dnf install -y cloud-hypervisor; then
    return
  fi

  if [[ -n "${CLOUD_HYPERVISOR_RPM_URL}" ]]; then
    dnf install -y "${CLOUD_HYPERVISOR_RPM_URL}"
    return
  fi

  if [[ -n "${CLOUD_HYPERVISOR_BINARY_URL}" ]]; then
    curl -fsSL "${CLOUD_HYPERVISOR_BINARY_URL}" -o /usr/local/bin/cloud-hypervisor
    chmod 0755 /usr/local/bin/cloud-hypervisor
    return
  fi

  fatal "Cloud Hypervisor is not available; set CLOUD_HYPERVISOR_RPM_URL or CLOUD_HYPERVISOR_BINARY_URL"
}

install_kata() {
  if command -v containerd-shim-kata-v2 >/dev/null 2>&1 || [[ -x /opt/kata/bin/containerd-shim-kata-v2 ]]; then
    return
  fi

  if dnf install -y kata-containers; then
    return
  fi

  if [[ -n "${KATA_RPM_URLS}" ]]; then
    # shellcheck disable=SC2086
    dnf install -y ${KATA_RPM_URLS}
    return
  fi

  if [[ -n "${KATA_STATIC_TARBALL_URL}" ]]; then
    install -d -m 0755 /opt/kata
    case "${KATA_STATIC_TARBALL_URL}" in
      *.tar.zst|*.tzst)
        curl -fsSL "${KATA_STATIC_TARBALL_URL}" -o /tmp/kata-static.tar.zst
        tar -C / --zstd -xf /tmp/kata-static.tar.zst
        ;;
      *.tar.xz|*.txz)
        curl -fsSL "${KATA_STATIC_TARBALL_URL}" -o /tmp/kata-static.tar.xz
        tar -C / -xJf /tmp/kata-static.tar.xz
        ;;
      *)
        curl -fsSL "${KATA_STATIC_TARBALL_URL}" -o /tmp/kata-static.tar
        tar -C / -xf /tmp/kata-static.tar
        ;;
    esac
    return
  fi

  fatal "Kata Containers is not available; set KATA_RPM_URLS or KATA_STATIC_TARBALL_URL"
}

install_bootstrap_script() {
  install -d -m 0755 "$(dirname "${BOOTSTRAP_DST}")"
  install -m 0755 /tmp/bootstrap-kata-worker-host.sh "${BOOTSTRAP_DST}"
}

runtime_binary_path() {
  local binary="$1"
  local candidate
  for candidate in "/usr/bin/${binary}" "/usr/local/bin/${binary}" "/opt/kata/bin/${binary}"; do
    if [[ -x "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
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
}

configure_containerd() {
  local shim_path clh_path
  shim_path="$(runtime_binary_path containerd-shim-kata-clh-v2 || true)"
  if [[ -z "${shim_path}" ]]; then
    shim_path="$(runtime_binary_path containerd-shim-kata-v2 || true)"
  fi
  clh_path="$(runtime_binary_path cloud-hypervisor || true)"

  [[ -n "${shim_path}" ]] || fatal "Kata shim binary not found after install"
  [[ -n "${clh_path}" ]] || fatal "Cloud Hypervisor binary not found after install"

  install -d -m 0755 /usr/local/bin
  copy_runtime_binary "${shim_path}" /usr/local/bin/containerd-shim-kata-v2
  copy_runtime_binary "${shim_path}" /usr/local/bin/containerd-shim-kata-clh-v2
  copy_runtime_binary "${shim_path}" /usr/bin/containerd-shim-kata-v2
  copy_runtime_binary "${shim_path}" /usr/bin/containerd-shim-kata-clh-v2
  copy_runtime_binary "${clh_path}" /usr/local/bin/cloud-hypervisor
  copy_runtime_binary "${clh_path}" /usr/bin/cloud-hypervisor

  install -d -m 0755 /etc/containerd
  if [[ ! -f /etc/containerd/config.toml ]]; then
    containerd config default >/etc/containerd/config.toml
  fi

  cat >>/etc/containerd/config.toml <<EOF

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = false
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh.options]
    ConfigPath = "/etc/kata-containers/configuration-clh.toml"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = false
EOF

  install -d -m 0755 /etc/containerd/conf.d
  cat >/etc/containerd/conf.d/99-cloudsec-rbi-kata-grpc-cri.toml <<EOF
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = false
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-clh.options]
    ConfigPath = "/etc/kata-containers/configuration-clh.toml"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
  privileged_without_host_devices = false
EOF

  if [[ ! -f /etc/kata-containers/configuration-clh.toml && -f /opt/kata/share/defaults/kata-containers/configuration-clh.toml ]]; then
    install -d -m 0755 /etc/kata-containers
    cp /opt/kata/share/defaults/kata-containers/configuration-clh.toml /etc/kata-containers/configuration-clh.toml
  fi

  if [[ -f /etc/kata-containers/configuration-clh.toml ]]; then
    sed -i "s|^hypervisor_path = .*|hypervisor_path = \"${clh_path}\"|" /etc/kata-containers/configuration-clh.toml || true
  fi

  systemctl enable containerd
  systemctl restart containerd
}

main() {
  log "installing AL2023 Kata worker prerequisites"
  wait_for_bootstrap_package_activity
  install_packages
  install_kata
  install_cloud_hypervisor
  install_bootstrap_script
  configure_containerd
  log "Kata worker AMI install complete"
}

main "$@"
