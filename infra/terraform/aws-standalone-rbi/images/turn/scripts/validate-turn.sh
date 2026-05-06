#!/usr/bin/env bash
set -euo pipefail

fatal() {
  printf '[validate-turn] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || fatal "run as root"

command -v docker >/dev/null 2>&1 || fatal "docker is not installed"
command -v aws >/dev/null 2>&1 || fatal "aws CLI is not installed"
[[ -x /opt/cloudsec/turn/start-coturn.sh ]] || fatal "TURN startup script missing"
[[ -f /etc/systemd/system/cloudsec-rbi-turn.service ]] || fatal "systemd unit missing"
timeout 20s systemctl is-enabled docker >/dev/null 2>&1 || fatal "docker is not enabled"
timeout 20s systemctl is-enabled cloudsec-rbi-turn.service >/dev/null 2>&1 || fatal "TURN service is not enabled"

if grep -R --exclude='turn.env.example' -n 'static-auth-secret=\|TURN_SHARED_SECRET=' /opt/cloudsec /etc/cloudsec-rbi /etc/systemd 2>/dev/null; then
  fatal "secret material appears to be baked into the image"
fi

bash -n /opt/cloudsec/turn/start-coturn.sh
timeout 30s docker image inspect "${COTURN_IMAGE:-coturn/coturn:4.6}" >/dev/null 2>&1 || fatal "coturn image was not pre-pulled or Docker is unresponsive"

printf '[validate-turn] PASS TURN AMI prerequisites validated\n'
