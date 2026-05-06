#!/usr/bin/env bash
set -euo pipefail

COTURN_IMAGE="${COTURN_IMAGE:-coturn/coturn:4.6}"
TURN_DEFAULT_REALM="${TURN_DEFAULT_REALM:-cloudsec-rbi.local}"
TURN_PORT="${TURN_PORT:-3478}"
TURN_TLS_PORT="${TURN_TLS_PORT:-443}"
TURN_MIN_PORT="${TURN_MIN_PORT:-49152}"
TURN_MAX_PORT="${TURN_MAX_PORT:-65535}"

log() {
  printf '[install-turn] %s\n' "$*"
}

fatal() {
  printf '[install-turn] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || fatal "run as root"

if command -v cloud-init >/dev/null 2>&1; then
  log "waiting for cloud-init to finish"
  cloud-init status --wait || fatal "cloud-init did not finish cleanly"
fi

log "waiting for package manager locks"
for _ in $(seq 1 60); do
  if ! pgrep -x dnf >/dev/null 2>&1 && ! pgrep -x rpm >/dev/null 2>&1 && ! pgrep -x yum >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

if pgrep -x dnf >/dev/null 2>&1 || pgrep -x rpm >/dev/null 2>&1 || pgrep -x yum >/dev/null 2>&1; then
  fatal "package manager lock did not clear"
fi

log "installing Docker, AWS CLI, and JSON parsing dependencies"
dnf install -y docker awscli jq

install -d -m 0755 /opt/cloudsec/turn /etc/cloudsec-rbi
install -m 0755 /tmp/start-coturn.sh /opt/cloudsec/turn/start-coturn.sh
install -m 0644 /tmp/cloudsec-rbi-turn.service /etc/systemd/system/cloudsec-rbi-turn.service

cat >/etc/cloudsec-rbi/turn.env.example <<EOF
# Copy to /etc/cloudsec-rbi/turn.env with environment-specific non-secret values.
# The shared secret should be stored outside Terraform state in SSM SecureString
# or Secrets Manager and fetched at instance boot by name.
TURN_REALM=${TURN_DEFAULT_REALM}
TURN_SHARED_SECRET_SSM_PARAMETER=/cloudsec-rbi/dev/us-east-1/secrets/turn-shared-secret
# TURN_SHARED_SECRET_SECRET_ID=cloudsec-rbi/dev/turn-shared-secret
TURN_PORT=${TURN_PORT}
TURN_TLS_PORT=${TURN_TLS_PORT}
TURN_MIN_PORT=${TURN_MIN_PORT}
TURN_MAX_PORT=${TURN_MAX_PORT}
COTURN_IMAGE=${COTURN_IMAGE}
EOF

systemctl daemon-reload
systemctl enable docker
systemctl enable cloudsec-rbi-turn.service

log "pre-pulling ${COTURN_IMAGE}"
systemctl start docker
docker pull "${COTURN_IMAGE}"

log "TURN AMI install complete"
