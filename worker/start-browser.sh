#!/usr/bin/env bash
set -euo pipefail

export DISPLAY="${DISPLAY:-:99}"
export DISPLAY_WIDTH="${DISPLAY_WIDTH:-1280}"
export DISPLAY_HEIGHT="${DISPLAY_HEIGHT:-720}"
export CAPTURE_FRAMERATE="${CAPTURE_FRAMERATE:-20}"
export VIDEO_MIN_BITRATE_BPS="${VIDEO_MIN_BITRATE_BPS:-600000}"
export VIDEO_START_BITRATE_BPS="${VIDEO_START_BITRATE_BPS:-1500000}"
export VIDEO_MAX_BITRATE_BPS="${VIDEO_MAX_BITRATE_BPS:-3000000}"
export INTERACTION_MODE_HOLD_SEC="${INTERACTION_MODE_HOLD_SEC:-2}"
export INTERACTION_CAPTURE_FRAMERATE="${INTERACTION_CAPTURE_FRAMERATE:-12}"
export INTERACTION_VIDEO_TARGET_BITRATE_BPS="${INTERACTION_VIDEO_TARGET_BITRATE_BPS:-800000}"
export CHROMIUM_BIN="${CHROMIUM_BIN:-/usr/bin/chromium}"
export CHROME_PROFILE_DIR="${CHROME_PROFILE_DIR:-/home/rbi/chromium-profile}"
export DISABLE_CHROMIUM_SANDBOX="${DISABLE_CHROMIUM_SANDBOX:-0}"
export REMOTE_DEBUGGING_PORT="${REMOTE_DEBUGGING_PORT:-9222}"
export MEDIA_RELAY_URL="${MEDIA_RELAY_URL:-}"
export MEDIA_RELAY_CONNECT_HOST="${MEDIA_RELAY_CONNECT_HOST:-}"
export MEDIA_RELAY_STATE_INTERVAL_SEC="${MEDIA_RELAY_STATE_INTERVAL_SEC:-10}"
export MEDIA_RELAY_RECONNECT_DELAY_SEC="${MEDIA_RELAY_RECONNECT_DELAY_SEC:-2}"
export VIRTUAL_ENV="${VIRTUAL_ENV:-/opt/venv}"
export PATH="${VIRTUAL_ENV}/bin:${PATH}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/rbi-runtime}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-${XDG_RUNTIME_DIR}/pulse}"
export PULSE_STATE_PATH="${PULSE_STATE_PATH:-/home/rbi/.config/pulse}"
export PULSE_SINK_NAME="${PULSE_SINK_NAME:-}"
export PULSE_SOURCE_NAME="${PULSE_SOURCE_NAME:-}"
export PULSE_CAPTURE_LATENCY_MSEC="${PULSE_CAPTURE_LATENCY_MSEC:-20}"
export PULSE_LATENCY_MSEC="${PULSE_LATENCY_MSEC:-${PULSE_CAPTURE_LATENCY_MSEC}}"
export PULSE_SERVER="${PULSE_SERVER:-unix:${PULSE_RUNTIME_PATH}/native}"

mkdir -p "${CHROME_PROFILE_DIR}"
mkdir -p "${XDG_RUNTIME_DIR}" "${PULSE_STATE_PATH}"
chmod 700 "${XDG_RUNTIME_DIR}"

cleanup() {
  pulseaudio --kill >/dev/null 2>&1 || true
  pkill -TERM -P $$ || true
  pkill -f "${CHROME_PROFILE_DIR}" || true
  wait || true
}

trap cleanup EXIT

DISPLAY_NUMBER="${DISPLAY#:}"
pkill -TERM -f "Xvfb ${DISPLAY}" >/dev/null 2>&1 || true
rm -f "/tmp/.X${DISPLAY_NUMBER}-lock"

Xvfb "${DISPLAY}" -screen 0 "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}x24" -ac +extension RANDR &
XVFB_PID=$!

for _ in $(seq 1 40); do
  if DISPLAY="${DISPLAY}" xdpyinfo >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

openbox >/tmp/openbox.log 2>&1 &
OPENBOX_PID=$!

pulseaudio --daemonize=yes --exit-idle-time=-1 --log-target=stderr >/tmp/pulseaudio.log 2>&1

for _ in $(seq 1 40); do
  if PULSE_SERVER="${PULSE_SERVER}" pactl info >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if [[ -z "${PULSE_SINK_NAME}" ]]; then
  PULSE_SINK_NAME="$(PULSE_SERVER="${PULSE_SERVER}" pactl info | awk -F': ' '/Default Sink/ {print $2; exit}')"
fi

if [[ -z "${PULSE_SOURCE_NAME}" && -n "${PULSE_SINK_NAME}" ]]; then
  PULSE_SOURCE_NAME="${PULSE_SINK_NAME}.monitor"
fi

if [[ -n "${PULSE_SINK_NAME}" ]]; then
  PULSE_SERVER="${PULSE_SERVER}" pactl set-default-sink "${PULSE_SINK_NAME}" >/dev/null 2>&1 || true
fi

if [[ -n "${PULSE_SOURCE_NAME}" ]]; then
  export PULSE_SOURCE_NAME
  PULSE_SERVER="${PULSE_SERVER}" pactl set-default-source "${PULSE_SOURCE_NAME}" >/dev/null 2>&1 || true
fi

"${VIRTUAL_ENV}/bin/python3" /app/worker.py
