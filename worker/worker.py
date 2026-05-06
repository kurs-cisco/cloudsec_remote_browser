import asyncio
import audioop
import base64
import html
import io
import json
import os
import re
import shutil
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from fractions import Fraction
from typing import Dict, List, Optional, Tuple

import av
import websockets
from websockets.exceptions import ConnectionClosed
from av import AudioFrame, VideoFrame
from aiortc import (
    RTCConfiguration,
    RTCIceServer,
    RTCPeerConnection,
    RTCRtpSender,
    RTCSessionDescription,
    MediaStreamTrack,
)
from aiortc.contrib.media import MediaPlayer
from aiortc.mediastreams import MediaStreamError
from aiortc.sdp import candidate_from_sdp, candidate_to_sdp
from PIL import Image
from Xlib import X, XK, display as xdisplay
from Xlib.ext import xtest


WORKER_MODE = os.environ.get("WORKER_MODE", "session")
DISPLAY = os.environ.get("DISPLAY", ":99")
DISPLAY_WIDTH = int(os.environ.get("DISPLAY_WIDTH", "1280"))
DISPLAY_HEIGHT = int(os.environ.get("DISPLAY_HEIGHT", "720"))
SIGNALING_URL = os.environ.get("SIGNALING_URL", "")
SIGNALING_CONNECT_HOST = os.environ.get("SIGNALING_CONNECT_HOST", "")
MEDIA_RELAY_URL = os.environ.get("MEDIA_RELAY_URL", "").strip()
MEDIA_RELAY_CONNECT_HOST = os.environ.get("MEDIA_RELAY_CONNECT_HOST", "").strip()
MEDIA_GATEWAY_URL = os.environ.get("MEDIA_GATEWAY_URL", "").strip()
MEDIA_PLANE_MODE = os.environ.get("MEDIA_PLANE_MODE", "").strip().lower()
MEDIA_RELAY_PROTOCOL = os.environ.get("MEDIA_RELAY_PROTOCOL", "").strip().lower()
POOL_WS_URL = os.environ.get("POOL_WS_URL", SIGNALING_URL)
POOL_WS_CONNECT_HOST = os.environ.get("POOL_WS_CONNECT_HOST", SIGNALING_CONNECT_HOST)
POOL_SHARED_SECRET = os.environ.get("POOL_SHARED_SECRET", "")
WORKER_REGION = os.environ.get("WORKER_REGION", "").strip()
WORKER_RUNTIME_CLASS = os.environ.get("WORKER_RUNTIME_CLASS", "").strip()
WORKER_MEDIA_MODE = os.environ.get("WORKER_MEDIA_MODE", "gateway-webrtc-relay").strip()
WORKER_IMAGE_DIGEST = os.environ.get("WORKER_IMAGE_DIGEST", "").strip()
POOL_RECYCLE_AFTER_SESSION = os.environ.get("POOL_RECYCLE_AFTER_SESSION", "0").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}
CHROMIUM_BIN = os.environ.get("CHROMIUM_BIN", "/usr/bin/chromium")
CHROME_PROFILE_DIR = os.environ.get("CHROME_PROFILE_DIR", "/home/rbi/chromium-profile")
REMOTE_DEBUGGING_PORT = int(os.environ.get("REMOTE_DEBUGGING_PORT", "9222"))
START_URL = os.environ.get("START_URL", "about:blank")
SIGNALING_HEARTBEAT_INTERVAL = float(os.environ.get("SIGNALING_HEARTBEAT_INTERVAL_SEC", "20"))
MEDIA_RELAY_STATE_INTERVAL_SEC = max(
    5.0, float(os.environ.get("MEDIA_RELAY_STATE_INTERVAL_SEC", "10"))
)
PAGE_STATE_SYNC_INTERVAL_SEC = max(
    0.5, float(os.environ.get("PAGE_STATE_SYNC_INTERVAL_SEC", "1.0"))
)
MEDIA_RELAY_RECONNECT_DELAY_SEC = max(
    0.5, float(os.environ.get("MEDIA_RELAY_RECONNECT_DELAY_SEC", "2"))
)
POINTER_FLUSH_INTERVAL_SEC = float(os.environ.get("POINTER_FLUSH_INTERVAL_SEC", "0.004"))
INPUT_ACK_INTERVAL_SEC = max(
    0.025, float(os.environ.get("INPUT_ACK_INTERVAL_SEC", "0.050"))
)
INPUT_ACK_MAX_BATCH = 64
INPUT_POINTER_CHANNEL_NAME = os.environ.get("INPUT_POINTER_CHANNEL_NAME", "input-pointer").strip() or "input-pointer"
INPUT_CONTROL_CHANNEL_NAME = os.environ.get("INPUT_CONTROL_CHANNEL_NAME", "input-control").strip() or "input-control"
INPUT_DATA_CHANNEL_LABELS = {"input", INPUT_POINTER_CHANNEL_NAME, INPUT_CONTROL_CHANNEL_NAME}
INPUT_CHANNEL_CREATE_ORDER = (INPUT_POINTER_CHANNEL_NAME, INPUT_CONTROL_CHANNEL_NAME, "input")
INPUT_ACK_CHANNEL_PRIORITY = (INPUT_CONTROL_CHANNEL_NAME, "input", INPUT_POINTER_CHANNEL_NAME)
GATEWAY_WEBRTC_RELAY_MODE = "gateway-webrtc-relay"
GATEWAY_WEBRTC_SRTP_PROTOCOL = "webrtc-srtp"
MEDIA_GATEWAY_REQUEST_TIMEOUT_SEC = max(
    1.0, float(os.environ.get("MEDIA_GATEWAY_REQUEST_TIMEOUT_SEC", "10"))
)
PULSE_SOURCE_NAME = os.environ.get("PULSE_SOURCE_NAME", "auto_null.monitor")
PULSE_AUDIO_RATE = os.environ.get("PULSE_AUDIO_RATE", "48000")
PULSE_AUDIO_CHANNELS = os.environ.get("PULSE_AUDIO_CHANNELS", "2")
PULSE_CAPTURE_LATENCY_MSEC = max(
    5,
    min(
        250,
        int(
            os.environ.get(
                "PULSE_CAPTURE_LATENCY_MSEC",
                os.environ.get("PULSE_LATENCY_MSEC", "20"),
            )
        ),
    ),
)
EXPERIMENTAL_AUDIO_STARTUP_SYNC = os.environ.get(
    "EXPERIMENTAL_AUDIO_STARTUP_SYNC",
    "0",
).strip().lower() in {"1", "true", "yes", "on", "audio-ready"}
EXPERIMENTAL_AUDIO_SYNC_MAX_DELAY_MS = 60
EXPERIMENTAL_AUDIO_CAPTURE_LATENCY_MSEC = 10
EXPERIMENTAL_AUDIO_MAX_BACKLOG_SEC = 0.12
EXPERIMENTAL_AUDIO_RESYNC_MAX_BACKLOG_SEC = 0.06
EXPERIMENTAL_AUDIO_RESYNC_WINDOW_SEC = 1.5
EXPERIMENTAL_AUDIO_MAX_DROP_FRAMES_PER_RECV = 250
EXPERIMENTAL_AUDIO_READY_MIN_RMS = 120
EXPERIMENTAL_AUDIO_READY_CONSECUTIVE_FRAMES = 5
EXPERIMENTAL_SOURCE_COUPLED_AV = os.environ.get(
    "EXPERIMENTAL_SOURCE_COUPLED_AV",
    "0",
).strip().lower() in {"1", "true", "yes", "on", "source-coupled-av"}
SOURCE_COUPLED_AV_VIDEO_QUEUE_MAX_FRAMES = 12
SOURCE_COUPLED_AV_AUDIO_QUEUE_MAX_FRAMES = 48
SOURCE_COUPLED_AV_VIDEO_TIME_BASE = Fraction(1, 90000)
STEALTH_USER_AGENT = os.environ.get(
    "STEALTH_USER_AGENT",
    (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
    ),
)
DISABLE_CHROMIUM_SANDBOX = os.environ.get("DISABLE_CHROMIUM_SANDBOX", "0") == "1"

DEFAULT_SESSION = {
    "sessionId": os.environ.get("SESSION_ID", ""),
    "targetUrl": os.environ.get("TARGET_URL", ""),
    "signalingUrl": SIGNALING_URL,
    "signalingConnectHost": SIGNALING_CONNECT_HOST,
    "mediaRelayUrl": MEDIA_RELAY_URL,
    "mediaRelayConnectHost": MEDIA_RELAY_CONNECT_HOST,
    "mediaGatewayUrl": MEDIA_GATEWAY_URL,
    "workerToken": os.environ.get("WORKER_TOKEN", ""),
    "displayWidth": DISPLAY_WIDTH,
    "displayHeight": DISPLAY_HEIGHT,
    "turnUsername": os.environ.get("TURN_USERNAME", ""),
    "turnPassword": os.environ.get("TURN_PASSWORD", ""),
    "workerIceUrls": [
        item.strip()
        for item in os.environ.get("WORKER_ICE_URLS", "").split(",")
        if item.strip()
    ],
    "allowedCandidateTypes": [
        item.strip().lower()
        for item in os.environ.get("ALLOWED_CANDIDATE_TYPES", "host,srflx,relay").split(",")
        if item.strip()
    ],
    "transport": {
        "mediaPlaneMode": MEDIA_PLANE_MODE,
        "protocol": MEDIA_RELAY_PROTOCOL,
        "inputPointerName": INPUT_POINTER_CHANNEL_NAME,
        "inputControlName": INPUT_CONTROL_CHANNEL_NAME,
    },
    "workerBridge": {
        "mediaGatewayUrl": MEDIA_GATEWAY_URL,
        "protocol": MEDIA_RELAY_PROTOCOL,
        "inputPointerName": INPUT_POINTER_CHANNEL_NAME,
        "inputControlName": INPUT_CONTROL_CHANNEL_NAME,
    },
    "experiments": {
        "audioStartupSync": EXPERIMENTAL_AUDIO_STARTUP_SYNC,
        "sourceCoupledAv": EXPERIMENTAL_SOURCE_COUPLED_AV,
    },
}

DISPLAY_ENV = {
    **os.environ,
    "DISPLAY": DISPLAY,
}

SHUTDOWN = asyncio.Event()
POINTER_MOVE_TASK: Optional[asyncio.Task] = None
PENDING_POINTER_POSITION: Optional[Tuple[int, int]] = None
XINPUT = None
LAST_BROWSER_FOCUS_AT = 0.0
RUNTIME_METADATA_LOGGED = False
MIN_STREAM_WIDTH = 320
MIN_STREAM_HEIGHT = 180
INITIAL_STREAM_SCALE = max(0.25, min(1.0, float(os.environ.get("INITIAL_STREAM_SCALE", "1.0"))))
CAPTURE_FRAMERATE = max(8, min(30, int(os.environ.get("CAPTURE_FRAMERATE", "20"))))
VIDEO_CAPTURE_BACKEND = (
    str(os.environ.get("VIDEO_CAPTURE_BACKEND", "x11grab")).strip().lower() or "x11grab"
)
CDP_SCREENSHOT_QUALITY = max(
    40, min(95, int(os.environ.get("CDP_SCREENSHOT_QUALITY", "70")))
)
CHROMIUM_USE_DEV_SHM = str(os.environ.get("CHROMIUM_USE_DEV_SHM", "1")).strip().lower() not in {
    "0",
    "false",
    "no",
    "off",
}
INPUT_FOCUS_REFRESH_INTERVAL_SEC = max(
    0.0, float(os.environ.get("INPUT_FOCUS_REFRESH_INTERVAL_SEC", "0.75"))
)
VIDEO_CODEC_PREFERENCES = [
    item.strip().upper()
    for item in os.environ.get("VIDEO_CODEC_PREFERENCES", "VP8").split(",")
    if item.strip()
]
VIDEO_MIN_BITRATE_BPS = max(200_000, int(os.environ.get("VIDEO_MIN_BITRATE_BPS", "600000")))
VIDEO_START_BITRATE_BPS = max(
    VIDEO_MIN_BITRATE_BPS, int(os.environ.get("VIDEO_START_BITRATE_BPS", "1500000"))
)
VIDEO_MAX_BITRATE_BPS = max(
    VIDEO_START_BITRATE_BPS, int(os.environ.get("VIDEO_MAX_BITRATE_BPS", "3000000"))
)
INTERACTION_MODE_HOLD_SEC = max(
    0.25, float(os.environ.get("INTERACTION_MODE_HOLD_SEC", "2"))
)
INTERACTION_CAPTURE_FRAMERATE = max(
    4,
    min(
        CAPTURE_FRAMERATE,
        int(os.environ.get("INTERACTION_CAPTURE_FRAMERATE", str(max(8, min(CAPTURE_FRAMERATE, 12))))),
    ),
)
INTERACTION_VIDEO_TARGET_BITRATE_BPS = max(
    VIDEO_MIN_BITRATE_BPS,
    min(
        VIDEO_START_BITRATE_BPS,
        int(
            os.environ.get(
                "INTERACTION_VIDEO_TARGET_BITRATE_BPS",
                str(max(VIDEO_MIN_BITRATE_BPS, min(VIDEO_START_BITRATE_BPS, 800_000))),
            )
        ),
    ),
)
AUDIO_SYNC_DELAY_MS = max(0, min(1000, int(os.environ.get("AUDIO_SYNC_DELAY_MS", "0"))))
HYBRID_DOM_BRIDGE_ENABLED = str(
    os.environ.get("HYBRID_DOM_BRIDGE_ENABLED", "0")
).strip().lower() in {"1", "true", "yes", "on"}
NAVIGATION_PAGE_STATE_TIMEOUT_SEC = float(
    os.environ.get("NAVIGATION_PAGE_STATE_TIMEOUT_SEC", "6")
)
NAVIGATION_MAX_ATTEMPTS = max(1, int(os.environ.get("NAVIGATION_MAX_ATTEMPTS", "2")))
CAPTURE_STATS_INTERVAL_SEC = max(
    5.0, float(os.environ.get("CAPTURE_STATS_INTERVAL_SEC", "10"))
)
CAPTURE_STALL_THRESHOLD_SEC = max(
    2.0, float(os.environ.get("CAPTURE_STALL_THRESHOLD_SEC", "4"))
)
CAPTURE_RECOVERY_COOLDOWN_SEC = max(
    3.0, float(os.environ.get("CAPTURE_RECOVERY_COOLDOWN_SEC", "8"))
)
HYBRID_DOM_SNAPSHOT_TIMEOUT_SEC = max(
    1.0, float(os.environ.get("HYBRID_DOM_SNAPSHOT_TIMEOUT_SEC", "4"))
)
HYBRID_DOM_INITIAL_SNAPSHOT_TIMEOUT_SEC = max(
    HYBRID_DOM_SNAPSHOT_TIMEOUT_SEC,
    float(os.environ.get("HYBRID_DOM_INITIAL_SNAPSHOT_TIMEOUT_SEC", "8")),
)
HYBRID_DOM_SNAPSHOT_CACHE_MS = max(
    100, int(os.environ.get("HYBRID_DOM_SNAPSHOT_CACHE_MS", "1200"))
)
WHEEL_PIXEL_DELTA_PER_CLICK = max(
    40.0, float(os.environ.get("WHEEL_PIXEL_DELTA_PER_CLICK", "160"))
)
WHEEL_LINE_DELTA_PER_CLICK = max(
    1.0, float(os.environ.get("WHEEL_LINE_DELTA_PER_CLICK", "3"))
)
WHEEL_PAGE_TO_CLICK_MULTIPLIER = max(
    1.0, float(os.environ.get("WHEEL_PAGE_TO_CLICK_MULTIPLIER", "3"))
)
WHEEL_SCROLL_REMAINDER_Y = 0.0


def log(*parts: object) -> None:
    print("[worker]", *parts, flush=True)


def truncate_for_log(value: object, limit: int = 96) -> str:
    text = str(value or "")
    if len(text) <= limit:
        return text
    return f"{text[: limit - 3]}..."


def read_command_output(*args: str) -> str:
    try:
        result = subprocess.run(
            args,
            env=os.environ.copy(),
            check=False,
            capture_output=True,
            text=True,
        )
    except Exception as error:
        return f"error:{type(error).__name__}"

    output = (result.stdout or result.stderr or "").strip()
    if not output:
        return f"exit:{result.returncode}"
    return output.replace("\n", " | ")


def log_runtime_metadata_once() -> None:
    global RUNTIME_METADATA_LOGGED
    if RUNTIME_METADATA_LOGGED:
        return

    package_info = ""
    for candidate in (
        "/opt/chromium-package-info.txt",
        "/opt/chromium-version.txt",
    ):
        try:
            with open(candidate, "r", encoding="utf-8") as handle:
                payload = handle.read().strip()
            if payload:
                package_info = f"{package_info} | {payload}".strip(" |")
        except FileNotFoundError:
            continue
        except Exception as error:
            package_info = f"{package_info} | {candidate}:error:{type(error).__name__}".strip(" |")

    version = read_command_output(CHROMIUM_BIN, "--version")
    sandbox = read_command_output("dpkg-query", "-W", "chromium-sandbox")
    log(
        "runtime-metadata",
        f"chromium={truncate_for_log(version, 160)}",
        f"packageInfo={truncate_for_log(package_info or 'unknown', 240)}",
        f"sandbox={truncate_for_log(sandbox, 160)}",
        f"captureBackend={VIDEO_CAPTURE_BACKEND}",
        f"useDevShm={CHROMIUM_USE_DEV_SHM}",
        f"captureFramerate={CAPTURE_FRAMERATE}",
        f"pulseCaptureLatencyMsec={PULSE_CAPTURE_LATENCY_MSEC}",
        f"initialStreamScale={INITIAL_STREAM_SCALE}",
        f"videoBitrateBps={VIDEO_MIN_BITRATE_BPS}/{VIDEO_START_BITRATE_BPS}/{VIDEO_MAX_BITRATE_BPS}",
        f"interactionHoldSec={INTERACTION_MODE_HOLD_SEC}",
        f"interactionTarget={INTERACTION_CAPTURE_FRAMERATE}fps/{INTERACTION_VIDEO_TARGET_BITRATE_BPS}bps",
        f"experimentalAudioStartupSync={EXPERIMENTAL_AUDIO_STARTUP_SYNC}",
        f"experimentalSourceCoupledAv={EXPERIMENTAL_SOURCE_COUPLED_AV}",
    )
    RUNTIME_METADATA_LOGGED = True


def is_blank_or_error_url(value: object) -> bool:
    href = str(value or "").strip().lower()
    return href in {"", "about:blank"} or href.startswith("chrome-error://")


def is_probable_media_page(value: object) -> bool:
    href = str(value or "").strip()
    if not href:
        return False
    try:
        parsed = urllib.parse.urlparse(href)
    except Exception:
        return False
    host = (parsed.hostname or "").lower()
    path = parsed.path or "/"
    if host == "youtu.be":
        return True
    if host == "youtube.com" or host.endswith(".youtube.com"):
        return path == "/watch" or path.startswith("/watch") or path.startswith("/shorts")
    return False


def clamp_dimension(value: object, fallback: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(round(float(value)))
    except (TypeError, ValueError):
        return fallback
    return max(minimum, min(maximum, parsed))


def run_cmd(*args: str) -> None:
    subprocess.run(
        args,
        env=DISPLAY_ENV,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def build_websocket_connect_kwargs(connect_host: str, websocket_url: str) -> Dict:
    host = str(connect_host or "").strip()
    if not host:
        return {}
    server_hostname = urllib.parse.urlparse(str(websocket_url or "")).hostname or None
    kwargs = {"host": host}
    if server_hostname:
        kwargs["server_hostname"] = server_hostname
    return kwargs


# Worker gateway WebRTC helpers BEGIN
def normalize_gateway_value(value: object) -> str:
    return str(value or "").strip()


def normalize_gateway_mode(value: object) -> str:
    return normalize_gateway_value(value).lower()


def is_gateway_webrtc_relay_config(
    media_gateway_url: object,
    media_plane_mode: object,
    protocol: object,
) -> bool:
    return bool(
        build_media_gateway_offer_url(media_gateway_url)
        and normalize_gateway_mode(media_plane_mode) == GATEWAY_WEBRTC_RELAY_MODE
        and normalize_gateway_mode(protocol) == GATEWAY_WEBRTC_SRTP_PROTOCOL
    )


def build_media_gateway_offer_url(media_gateway_url: object) -> str:
    raw = normalize_gateway_value(media_gateway_url)
    if not raw:
        return ""
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return ""
    path = parsed.path.rstrip("/")
    if not path.endswith("/offer"):
        path = f"{path}/offer" if path else "/offer"
    return urllib.parse.urlunparse(
        parsed._replace(path=path, params="", fragment="")
    )


def extract_gateway_answer_sdp(payload: object) -> str:
    if not isinstance(payload, dict):
        return ""

    def sdp_value(value: object) -> str:
        text = str(value or "")
        return text if text.strip() else ""

    for key in ("sdp", "answerSdp"):
        value = sdp_value(payload.get(key))
        if value:
            return value
    for key in ("answer", "description"):
        nested = payload.get(key)
        if isinstance(nested, dict):
            value = sdp_value(nested.get("sdp"))
            if value:
                return value
    return ""


def gateway_video_codec_preferences(preferences) -> List[str]:
    return ["VP8"]
# Worker gateway WebRTC helpers END


async def run_input_cmd(*args: str) -> None:
    await asyncio.to_thread(run_cmd, *args)


class XInputController:
    def __init__(self):
        self.display = xdisplay.Display(DISPLAY)
        self.root = self.display.screen().root

    def get_pointer_position(self) -> Tuple[int, int]:
        pointer = self.root.query_pointer()
        return int(pointer.root_x), int(pointer.root_y)

    def move_pointer(self, x: int, y: int) -> None:
        self.root.warp_pointer(int(x), int(y))
        self.display.sync()

    def button(self, button: int, pressed: bool) -> None:
        xtest.fake_input(self.display, X.ButtonPress if pressed else X.ButtonRelease, int(button))
        self.display.sync()

    def wheel(self, button: int, repeats: int) -> None:
        for _ in range(max(1, repeats)):
            xtest.fake_input(self.display, X.ButtonPress, int(button))
            xtest.fake_input(self.display, X.ButtonRelease, int(button))
        self.display.sync()

    def key(self, key_name: str, pressed: bool) -> bool:
        keysym = XK.string_to_keysym(key_name)
        if not keysym:
            return False
        keycode = self.display.keysym_to_keycode(keysym)
        if not keycode:
            return False
        xtest.fake_input(self.display, X.KeyPress if pressed else X.KeyRelease, keycode)
        self.display.sync()
        return True

    def close(self) -> None:
        try:
            self.display.close()
        except Exception:
            pass


def get_xinput() -> XInputController:
    global XINPUT
    if XINPUT is None:
        XINPUT = XInputController()
    return XINPUT


async def flush_pointer_moves() -> None:
    global POINTER_MOVE_TASK, PENDING_POINTER_POSITION

    while PENDING_POINTER_POSITION is not None and not SHUTDOWN.is_set():
        x, y = PENDING_POINTER_POSITION
        PENDING_POINTER_POSITION = None
        get_xinput().move_pointer(x, y)
        await asyncio.sleep(POINTER_FLUSH_INTERVAL_SEC)

    POINTER_MOVE_TASK = None
    if PENDING_POINTER_POSITION is not None and not SHUTDOWN.is_set():
        POINTER_MOVE_TASK = asyncio.create_task(flush_pointer_moves())


def queue_pointer_move(x: int, y: int) -> None:
    global POINTER_MOVE_TASK, PENDING_POINTER_POSITION

    PENDING_POINTER_POSITION = (int(x), int(y))
    if POINTER_MOVE_TASK is None or POINTER_MOVE_TASK.done():
        POINTER_MOVE_TASK = asyncio.create_task(flush_pointer_moves())


def current_time_ms() -> int:
    return int(time.time() * 1000)


def data_channel_label(channel) -> str:
    return str(getattr(channel, "label", "") or "")


def is_data_channel_open(channel) -> bool:
    return str(getattr(channel, "readyState", "") or "") == "open"


def is_interaction_input_message(message: Dict) -> bool:
    msg_type = str(message.get("type") or "")
    if msg_type in {"pointer.move", "pointer.button", "pointer.sync", "wheel", "key", "text.insert"}:
        return True
    return msg_type.startswith("input.") and msg_type != "input.ack"


def pointer_coordinates_from_message(
    message: Dict,
    default_width: int,
    default_height: int,
) -> Optional[Tuple[int, int]]:
    if "x" not in message or "y" not in message:
        return None

    try:
        x = int(float(message["x"]))
        y = int(float(message["y"]))
    except (TypeError, ValueError, OverflowError):
        return None

    max_x = max(0, int(default_width) - 1)
    max_y = max(0, int(default_height) - 1)
    return max(0, min(max_x, x)), max(0, min(max_y, y))


def sync_pointer_position(x: int, y: int) -> None:
    global PENDING_POINTER_POSITION

    PENDING_POINTER_POSITION = None
    get_xinput().move_pointer(x, y)


async def insert_text_with_fallback(
    text: str,
    browser: Optional["ChromiumController"] = None,
) -> None:
    if not text:
        return

    cdp_error: Optional[Exception] = None
    if browser is not None:
        try:
            await browser.send_cdp("Input.insertText", {"text": text})
            return
        except Exception as error:
            cdp_error = error

        try:
            result = await browser.evaluate_cdp(
                f"""
(() => {{
  const text = {json.dumps(text)};
  try {{
    if (
      typeof document.execCommand === "function" &&
      document.queryCommandSupported?.("insertText") &&
      document.execCommand("insertText", false, text)
    ) {{
      return {{ ok: true, fallback: "execCommand" }};
    }}
  }} catch (error) {{
    return {{ ok: false, error: String(error?.message || error) }};
  }}
  return {{ ok: false, error: "insertText fallback was not accepted" }};
}})()
                """.strip(),
                return_by_value=True,
                user_gesture=True,
            )
            if isinstance(result, dict) and result.get("ok"):
                return
        except Exception as error:
            cdp_error = error

    await focus_browser_async()
    try:
        await run_input_cmd("xdotool", "type", "--clearmodifiers", "--delay", "0", "--", text)
    except Exception as error:
        if cdp_error is not None:
            raise RuntimeError(
                f"CDP Input.insertText failed: {cdp_error}; xdotool fallback failed: {error}"
            ) from error
        raise


class MediaSyncController:
    def __init__(self, base_audio_delay_ms: int = 0, max_audio_delay_ms: int = 200):
        self.base_audio_delay_sec = max(0.0, float(base_audio_delay_ms) / 1000.0)
        self.max_audio_delay_sec = max(
            self.base_audio_delay_sec,
            min(1.0, float(max_audio_delay_ms) / 1000.0),
        )
        self.current_audio_delay_sec = self.base_audio_delay_sec
        self.last_video_gap_ms = 0.0
        self.last_video_fps = 0.0
        self.last_video_frame_age_ms = 0.0
        self.last_update_at = 0.0

    def observe_video(
        self,
        *,
        gap_ms: float = 0.0,
        fps: float = 0.0,
        frame_age_ms: Optional[float] = None,
    ) -> None:
        now = time.monotonic()
        nominal_gap_ms = 1000 / max(1, CAPTURE_FRAMERATE)
        measured_gap_ms = max(0.0, float(gap_ms or 0.0))
        measured_fps = max(0.0, float(fps or 0.0))
        measured_frame_age_ms = (
            max(0.0, float(frame_age_ms))
            if isinstance(frame_age_ms, (int, float))
            else 0.0
        )

        gap_pressure_ms = max(0.0, measured_gap_ms - (nominal_gap_ms * 1.15))
        fps_pressure_ms = 0.0
        if 0.0 < measured_fps < CAPTURE_FRAMERATE:
            fps_pressure_ms = min(140.0, (CAPTURE_FRAMERATE - measured_fps) * 8.0)
        age_pressure_ms = max(0.0, measured_frame_age_ms - 24.0)

        target_audio_delay_sec = min(
            self.max_audio_delay_sec,
            self.base_audio_delay_sec
            + (max(gap_pressure_ms, fps_pressure_ms, age_pressure_ms) / 1000.0),
        )

        # Clamp audio holdback only when video is demonstrably lagging, and decay quickly once it recovers.
        if target_audio_delay_sec > self.current_audio_delay_sec:
            self.current_audio_delay_sec = min(
                target_audio_delay_sec,
                self.current_audio_delay_sec + 0.012,
            )
        else:
            self.current_audio_delay_sec = max(
                target_audio_delay_sec,
                self.current_audio_delay_sec - 0.03,
            )

        self.last_video_gap_ms = measured_gap_ms
        self.last_video_fps = measured_fps
        self.last_video_frame_age_ms = measured_frame_age_ms
        self.last_update_at = now

    def get_audio_delay_sec(self) -> float:
        if self.last_update_at and (time.monotonic() - self.last_update_at) > (
            CAPTURE_STATS_INTERVAL_SEC * 1.5
        ):
            self.current_audio_delay_sec = max(
                self.base_audio_delay_sec,
                self.current_audio_delay_sec - 0.03,
            )
            self.last_update_at = time.monotonic()
        return self.current_audio_delay_sec


class PulseAudioTrack(MediaStreamTrack):
    kind = "audio"

    def __init__(
        self,
        source_name: str,
        sample_rate: int,
        channels: int,
        sync_delay_ms: int = 0,
        capture_latency_msec: int = 20,
        sync_controller: Optional[MediaSyncController] = None,
        freshness_guard_enabled: bool = False,
        activity_callback=None,
    ):
        super().__init__()
        self.source_name = source_name
        self.sample_rate = sample_rate
        self.channels = channels
        self.layout = "mono" if channels == 1 else "stereo"
        self.samples_per_frame = int(sample_rate * 0.02)
        self.frame_duration_sec = self.samples_per_frame / self.sample_rate
        self.bytes_per_frame = self.samples_per_frame * channels * 2
        self.timestamp = 0
        self.base_sync_delay_sec = max(0.0, float(sync_delay_ms) / 1000.0)
        self.sync_delay_sec = self.base_sync_delay_sec
        self.capture_latency_msec = max(5, min(250, int(capture_latency_msec)))
        self.sync_controller = sync_controller
        self.freshness_guard_enabled = bool(freshness_guard_enabled)
        self.activity_callback = activity_callback
        self.started_at = 0.0
        self.frames_read = 0
        self.frames_emitted = 0
        self.dropped_frames = 0
        self.last_frame_at = 0.0
        self.last_gap_ms = 0.0
        self.max_gap_ms = 0.0
        self.last_backlog_ms = 0.0
        self.max_backlog_ms = 0.0
        self.last_drop_count = 0
        self.resync_requests = 0
        self.last_resync_reason = ""
        self.last_resync_at = 0.0
        self.resync_until = 0.0
        self.audio_ready = False
        self.audio_ready_notified = False
        self.audio_active_frames = 0
        self.last_rms = 0
        self.max_rms = 0
        self.process = subprocess.Popen(
            [
                "parec",
                "--raw",
                "--format=s16le",
                f"--rate={sample_rate}",
                f"--channels={channels}",
                f"--device={source_name}",
                f"--latency-msec={self.capture_latency_msec}",
            ],
            env=os.environ.copy(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def request_resync(self, reason: str = "") -> None:
        if not self.freshness_guard_enabled:
            return
        now = time.monotonic()
        self.resync_requests += 1
        self.last_resync_reason = str(reason or "")
        self.last_resync_at = now
        self.resync_until = max(self.resync_until, now + EXPERIMENTAL_AUDIO_RESYNC_WINDOW_SEC)
        self.audio_ready = False
        self.audio_ready_notified = False
        self.audio_active_frames = 0

    def observe_audio_activity(self, payload: bytes) -> None:
        rms = int(audioop.rms(payload, 2)) if payload else 0
        self.last_rms = rms
        self.max_rms = max(self.max_rms, rms)
        if rms >= EXPERIMENTAL_AUDIO_READY_MIN_RMS:
            self.audio_active_frames += 1
        else:
            self.audio_active_frames = 0
            if not self.freshness_guard_enabled:
                self.audio_ready = False

        if self.audio_active_frames >= EXPERIMENTAL_AUDIO_READY_CONSECUTIVE_FRAMES:
            self.audio_ready = True

    def _estimate_backlog_sec(self, now: float) -> float:
        if not self.started_at:
            return 0.0
        capture_elapsed_sec = self.frames_read * self.frame_duration_sec
        wall_elapsed_sec = max(0.0, now - self.started_at)
        return max(0.0, wall_elapsed_sec - capture_elapsed_sec)

    async def _consume_freshest_payload(
        self,
        payload: bytes,
        now: float,
    ) -> Tuple[bytes, float]:
        backlog_sec = self._estimate_backlog_sec(now)
        backlog_ms = backlog_sec * 1000
        self.last_backlog_ms = backlog_ms
        self.max_backlog_ms = max(self.max_backlog_ms, backlog_ms)

        if not self.freshness_guard_enabled:
            return payload, now

        dropped = 0
        while dropped < EXPERIMENTAL_AUDIO_MAX_DROP_FRAMES_PER_RECV:
            resync_active = now < self.resync_until
            backlog_limit_sec = (
                EXPERIMENTAL_AUDIO_RESYNC_MAX_BACKLOG_SEC
                if resync_active
                else EXPERIMENTAL_AUDIO_MAX_BACKLOG_SEC
            )
            if backlog_sec <= backlog_limit_sec:
                break

            next_payload = await asyncio.to_thread(self.process.stdout.read, self.bytes_per_frame)
            if len(next_payload) < self.bytes_per_frame:
                raise MediaStreamError

            payload = next_payload
            self.frames_read += 1
            self.dropped_frames += 1
            dropped += 1
            now = time.monotonic()
            backlog_sec = self._estimate_backlog_sec(now)
            backlog_ms = backlog_sec * 1000
            self.last_backlog_ms = backlog_ms
            self.max_backlog_ms = max(self.max_backlog_ms, backlog_ms)

        if dropped:
            self.last_drop_count = dropped
        elif now >= self.resync_until:
            self.last_drop_count = 0

        if now >= self.resync_until:
            self.resync_until = 0.0

        return payload, now

    async def recv(self) -> AudioFrame:
        if self.process.stdout is None:
            raise MediaStreamError

        if self.process.poll() is not None:
            raise MediaStreamError

        payload = await asyncio.to_thread(self.process.stdout.read, self.bytes_per_frame)
        if len(payload) < self.bytes_per_frame:
            raise MediaStreamError

        now = time.monotonic()
        if not self.started_at:
            self.started_at = now
        self.frames_read += 1
        payload, now = await self._consume_freshest_payload(payload, now)

        dynamic_delay_sec = (
            self.sync_controller.get_audio_delay_sec()
            if self.sync_controller is not None
            else self.base_sync_delay_sec
        )
        self.sync_delay_sec = max(0.0, dynamic_delay_sec)
        target_emit_at = (
            self.started_at
            + self.sync_delay_sec
            + (self.frames_emitted * self.frame_duration_sec)
        )
        delay = target_emit_at - now
        if delay > 0:
            await asyncio.sleep(delay)

        emitted_at = time.monotonic()
        if self.last_frame_at:
            gap_ms = (emitted_at - self.last_frame_at) * 1000
            self.last_gap_ms = gap_ms
            self.max_gap_ms = max(self.max_gap_ms, gap_ms)
        self.last_frame_at = emitted_at

        frame = AudioFrame(format="s16", layout=self.layout, samples=self.samples_per_frame)
        frame.planes[0].update(payload)
        frame.sample_rate = self.sample_rate
        frame.pts = self.timestamp
        frame.time_base = Fraction(1, self.sample_rate)
        self.timestamp += self.samples_per_frame
        self.observe_audio_activity(payload)
        if (
            self.audio_ready
            and not self.audio_ready_notified
            and self.activity_callback is not None
        ):
            self.audio_ready_notified = True
            try:
                self.activity_callback(
                    {
                        "audioReady": True,
                        "rms": self.last_rms,
                        "maxRms": self.max_rms,
                        "activeFrames": self.audio_active_frames,
                    }
                )
            except Exception:
                pass
        self.frames_emitted += 1
        return frame

    def snapshot_stats(self) -> Dict[str, object]:
        now = time.monotonic()
        active_window_sec = max(0.001, now - self.started_at) if self.started_at else 0.0
        emitted_fps = (self.frames_emitted / active_window_sec) if active_window_sec else 0.0
        frame_age_ms = (
            round((now - self.last_frame_at) * 1000, 1)
            if self.last_frame_at
            else None
        )
        return {
            "freshnessGuardEnabled": self.freshness_guard_enabled,
            "framesRead": self.frames_read,
            "framesEmitted": self.frames_emitted,
            "droppedFrames": self.dropped_frames,
            "emittedFps": round(emitted_fps, 2),
            "frameAgeMs": frame_age_ms,
            "lastGapMs": round(self.last_gap_ms, 1),
            "maxGapMs": round(self.max_gap_ms, 1),
            "backlogMs": round(self.last_backlog_ms, 1),
            "maxBacklogMs": round(self.max_backlog_ms, 1),
            "lastDropCount": self.last_drop_count,
            "resyncRequests": self.resync_requests,
            "lastResyncReason": truncate_for_log(self.last_resync_reason, 120),
            "syncDelayMs": round(self.sync_delay_sec * 1000),
            "captureLatencyMsec": self.capture_latency_msec,
            "audioReady": self.audio_ready,
            "audioActiveFrames": self.audio_active_frames,
            "rms": self.last_rms,
            "maxRms": self.max_rms,
            "source": self.source_name,
        }

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
        super().stop()


class SourceCoupledAVCapture:
    def __init__(
        self,
        session_id: str,
        display_width: int,
        display_height: int,
        *,
        framerate: int,
        sample_rate: int,
        channels: int,
        source_name: str,
        activity_callback=None,
    ):
        self.session_id = session_id
        self.display_width = display_width
        self.display_height = display_height
        self.framerate = max(1, int(framerate))
        self.sample_rate = max(8000, int(sample_rate))
        self.channels = max(1, int(channels))
        self.source_name = source_name
        self.activity_callback = activity_callback

        self.loop = None
        self.process = None
        self.container = None
        self.reader_thread = None
        self.stderr_thread = None
        self.started_event = None
        self.stop_event = threading.Event()
        self.failure: Optional[str] = None

        self.video_queue: Optional[asyncio.Queue] = None
        self.audio_queue: Optional[asyncio.Queue] = None

        self.origin_ts_sec: Optional[float] = None
        self.video_source_frames = 0
        self.audio_source_frames = 0
        self.video_dropped_frames = 0
        self.audio_dropped_frames = 0
        self.flush_count = 0
        self.recovery_count = 0
        self.last_recovery_reason = ""

        self.started_at = 0.0
        self.last_video_frame_at = 0.0
        self.last_audio_frame_at = 0.0
        self.last_video_gap_ms = 0.0
        self.last_audio_gap_ms = 0.0
        self.max_video_gap_ms = 0.0
        self.max_audio_gap_ms = 0.0

        self.last_video_pts_sec = 0.0
        self.last_audio_pts_sec = 0.0
        self.first_video_pts_sec: Optional[float] = None
        self.first_audio_pts_sec: Optional[float] = None

        self.audio_ready = False
        self.audio_ready_notified = False
        self.audio_active_frames = 0
        self.last_rms = 0
        self.max_rms = 0

    def _build_ffmpeg_command(self) -> List[str]:
        display_input = f"{DISPLAY}.0+0,0"
        return [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "warning",
            "-fflags",
            "nobuffer",
            "-flags",
            "low_delay",
            "-flush_packets",
            "1",
            "-thread_queue_size",
            "512",
            "-use_wallclock_as_timestamps",
            "1",
            "-f",
            "x11grab",
            "-framerate",
            str(self.framerate),
            "-video_size",
            f"{self.display_width}x{self.display_height}",
            "-draw_mouse",
            "0",
            "-i",
            display_input,
            "-thread_queue_size",
            "512",
            "-use_wallclock_as_timestamps",
            "1",
            "-f",
            "pulse",
            "-sample_rate",
            str(self.sample_rate),
            "-channels",
            str(self.channels),
            "-i",
            self.source_name,
            "-map",
            "0:v:0",
            "-map",
            "1:a:0",
            "-vsync",
            "passthrough",
            "-af",
            "aresample=async=1:first_pts=0",
            "-c:v",
            "rawvideo",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "pcm_s16le",
            "-ar",
            str(self.sample_rate),
            "-ac",
            str(self.channels),
            "-f",
            "nut",
            "pipe:1",
        ]

    async def start(self, timeout_sec: float = 8.0) -> None:
        if self.process is not None:
            return

        self.loop = asyncio.get_running_loop()
        self.started_event = asyncio.Event()
        self.video_queue = asyncio.Queue(maxsize=SOURCE_COUPLED_AV_VIDEO_QUEUE_MAX_FRAMES)
        self.audio_queue = asyncio.Queue(maxsize=SOURCE_COUPLED_AV_AUDIO_QUEUE_MAX_FRAMES)
        self.process = subprocess.Popen(
            self._build_ffmpeg_command(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=os.environ.copy(),
            bufsize=0,
        )
        self.stderr_thread = threading.Thread(
            target=self._stderr_loop,
            name=f"ffmpeg-stderr:{self.session_id}",
            daemon=True,
        )
        self.reader_thread = threading.Thread(
            target=self._reader_loop,
            name=f"ffmpeg-reader:{self.session_id}",
            daemon=True,
        )
        self.stderr_thread.start()
        self.reader_thread.start()

        try:
            await asyncio.wait_for(self.started_event.wait(), timeout=timeout_sec)
        except Exception:
            self.stop()
            raise RuntimeError(
                self.failure or "source-coupled capture did not become ready"
            )

        if self.failure:
            self.stop()
            raise RuntimeError(self.failure)

    def _stderr_loop(self) -> None:
        if self.process is None or self.process.stderr is None:
            return
        try:
            while not self.stop_event.is_set():
                line = self.process.stderr.readline()
                if not line:
                    break
                message = line.decode("utf-8", errors="replace").strip()
                if not message:
                    continue
                lowered = message.lower()
                if any(token in lowered for token in ("error", "failed", "invalid", "unable")):
                    log(self.session_id, "source-coupled-ffmpeg", truncate_for_log(message, 240))
        except Exception:
            pass

    def _set_started(self) -> None:
        if self.started_event is not None and not self.started_event.is_set():
            self.started_event.set()

    def _set_failure(self, error: str) -> None:
        self.failure = str(error)
        if self.started_event is not None and not self.started_event.is_set():
            self.loop.call_soon_threadsafe(self.started_event.set)
        self._signal_end_of_stream()

    def _signal_end_of_stream(self) -> None:
        if self.loop is None:
            return
        self.loop.call_soon_threadsafe(self._enqueue_end_of_stream)

    def _enqueue_end_of_stream(self) -> None:
        for queue in (self.video_queue, self.audio_queue):
            if queue is None:
                continue
            try:
                while queue.full():
                    queue.get_nowait()
            except asyncio.QueueEmpty:
                pass
            try:
                queue.put_nowait(None)
            except asyncio.QueueFull:
                pass

    def _normalize_timestamp_sec(self, raw_ts_sec: float) -> float:
        if self.origin_ts_sec is None:
            self.origin_ts_sec = raw_ts_sec
        return max(0.0, raw_ts_sec - self.origin_ts_sec)

    def _frame_timestamp_sec(
        self,
        frame,
        *,
        fallback_step_sec: float,
        fallback_index: int,
    ) -> float:
        try:
            if frame.pts is not None and frame.time_base is not None:
                return float(frame.pts * frame.time_base)
        except Exception:
            pass
        return fallback_index * fallback_step_sec

    def _queue_depth_ms(self, queue: Optional[asyncio.Queue], frame_duration_sec: float) -> float:
        if queue is None:
            return 0.0
        return round(queue.qsize() * frame_duration_sec * 1000, 1)

    def _observe_audio_activity(self, frame: AudioFrame) -> None:
        try:
            payload = bytes(frame.planes[0])
        except Exception:
            payload = b""
        rms = int(audioop.rms(payload, 2)) if payload else 0
        self.last_rms = rms
        self.max_rms = max(self.max_rms, rms)
        if rms >= EXPERIMENTAL_AUDIO_READY_MIN_RMS:
            self.audio_active_frames += 1
        else:
            self.audio_active_frames = 0
        if self.audio_active_frames >= EXPERIMENTAL_AUDIO_READY_CONSECUTIVE_FRAMES:
            self.audio_ready = True

    def _notify_audio_ready(self) -> None:
        if not self.audio_ready or self.audio_ready_notified or self.activity_callback is None:
            return
        self.audio_ready_notified = True
        payload = {
            "audioReady": True,
            "rms": self.last_rms,
            "maxRms": self.max_rms,
            "activeFrames": self.audio_active_frames,
        }
        self.loop.call_soon_threadsafe(self.activity_callback, payload)

    def _enqueue_video_frame(self, frame: VideoFrame) -> None:
        if self.video_queue is None:
            return
        try:
            while self.video_queue.full():
                self.video_queue.get_nowait()
                self.video_dropped_frames += 1
        except asyncio.QueueEmpty:
            pass
        try:
            self.video_queue.put_nowait(frame)
        except asyncio.QueueFull:
            self.video_dropped_frames += 1

    def _enqueue_audio_frame(self, frame: AudioFrame) -> None:
        if self.audio_queue is None:
            return
        try:
            while self.audio_queue.full():
                self.audio_queue.get_nowait()
                self.audio_dropped_frames += 1
        except asyncio.QueueEmpty:
            pass
        try:
            self.audio_queue.put_nowait(frame)
        except asyncio.QueueFull:
            self.audio_dropped_frames += 1

    def _reader_loop(self) -> None:
        if self.process is None or self.process.stdout is None:
            self._set_failure("source-coupled capture missing stdout pipe")
            return

        try:
            self.container = av.open(self.process.stdout, mode="r", format="nut")
            self.loop.call_soon_threadsafe(self._set_started)
            for frame in self.container.decode():
                if self.stop_event.is_set():
                    break
                captured_at = time.monotonic()
                if not self.started_at:
                    self.started_at = captured_at

                if isinstance(frame, VideoFrame):
                    self.video_source_frames += 1
                    if self.last_video_frame_at:
                        gap_ms = (captured_at - self.last_video_frame_at) * 1000
                        self.last_video_gap_ms = gap_ms
                        self.max_video_gap_ms = max(self.max_video_gap_ms, gap_ms)
                    self.last_video_frame_at = captured_at
                    raw_ts_sec = self._frame_timestamp_sec(
                        frame,
                        fallback_step_sec=(1 / max(1, self.framerate)),
                        fallback_index=self.video_source_frames - 1,
                    )
                    rel_sec = self._normalize_timestamp_sec(raw_ts_sec)
                    self.last_video_pts_sec = rel_sec
                    if self.first_video_pts_sec is None:
                        self.first_video_pts_sec = rel_sec
                    frame.pts = int(round(rel_sec / float(SOURCE_COUPLED_AV_VIDEO_TIME_BASE)))
                    frame.time_base = SOURCE_COUPLED_AV_VIDEO_TIME_BASE
                    self.loop.call_soon_threadsafe(self._enqueue_video_frame, frame)
                    continue

                if isinstance(frame, AudioFrame):
                    self.audio_source_frames += 1
                    if self.last_audio_frame_at:
                        gap_ms = (captured_at - self.last_audio_frame_at) * 1000
                        self.last_audio_gap_ms = gap_ms
                        self.max_audio_gap_ms = max(self.max_audio_gap_ms, gap_ms)
                    self.last_audio_frame_at = captured_at
                    fallback_step_sec = (
                        (float(frame.samples) / self.sample_rate)
                        if getattr(frame, "samples", 0)
                        else 0.02
                    )
                    raw_ts_sec = self._frame_timestamp_sec(
                        frame,
                        fallback_step_sec=fallback_step_sec,
                        fallback_index=self.audio_source_frames - 1,
                    )
                    rel_sec = self._normalize_timestamp_sec(raw_ts_sec)
                    self.last_audio_pts_sec = rel_sec
                    if self.first_audio_pts_sec is None:
                        self.first_audio_pts_sec = rel_sec
                    frame.pts = int(round(rel_sec * self.sample_rate))
                    frame.time_base = Fraction(1, self.sample_rate)
                    frame.sample_rate = self.sample_rate
                    self._observe_audio_activity(frame)
                    if self.audio_ready and not self.audio_ready_notified:
                        self._notify_audio_ready()
                    self.loop.call_soon_threadsafe(self._enqueue_audio_frame, frame)
        except Exception as error:
            self._set_failure(f"source-coupled capture failed: {error!r}")
        finally:
            try:
                if self.container is not None:
                    self.container.close()
            except Exception:
                pass
            self._signal_end_of_stream()

    async def recv_video_frame(self) -> VideoFrame:
        if self.video_queue is None:
            raise MediaStreamError
        frame = await self.video_queue.get()
        if frame is None:
            raise MediaStreamError
        return frame

    async def recv_audio_frame(self) -> AudioFrame:
        if self.audio_queue is None:
            raise MediaStreamError
        frame = await self.audio_queue.get()
        if frame is None:
            raise MediaStreamError
        return frame

    def request_resync(self, reason: str = "") -> None:
        self.flush_count += 1
        self.last_recovery_reason = str(reason or "")
        self.audio_ready = False
        self.audio_ready_notified = False
        self.audio_active_frames = 0
        if self.loop is None:
            return
        self.loop.call_soon_threadsafe(self._flush_queues)

    def mark_recovery(self, reason: str) -> None:
        self.recovery_count += 1
        self.last_recovery_reason = str(reason or "")

    def _flush_queues(self) -> None:
        for queue in (self.video_queue, self.audio_queue):
            if queue is None:
                continue
            try:
                while True:
                    queue.get_nowait()
            except asyncio.QueueEmpty:
                pass

    def snapshot_video_stats(self) -> Dict[str, object]:
        now = time.monotonic()
        active_window_sec = max(0.001, now - self.started_at) if self.started_at else 0.0
        source_fps = (self.video_source_frames / active_window_sec) if active_window_sec else 0.0
        return {
            "sourceBackend": "source-coupled-av",
            "sourceFrames": self.video_source_frames,
            "deliveredFrames": None,
            "droppedFrames": self.video_dropped_frames,
            "sourceFps": round(source_fps, 2),
            "deliveredFps": None,
            "sourceFrameAgeMs": round((now - self.last_video_frame_at) * 1000, 1)
            if self.last_video_frame_at
            else None,
            "deliveredFrameAgeMs": None,
            "lastSourceGapMs": round(self.last_video_gap_ms, 1),
            "maxSourceGapMs": round(self.max_video_gap_ms, 1),
            "largeGapCount": 0,
            "recvErrors": 0,
            "lastError": truncate_for_log(self.failure or "", 160),
            "targetWidth": self.display_width,
            "targetHeight": self.display_height,
            "recoveryCount": self.recovery_count,
            "lastRecoveryReason": truncate_for_log(self.last_recovery_reason, 120),
            "queueDepthMs": self._queue_depth_ms(self.video_queue, 1 / max(1, self.framerate)),
            "captureSkewMs": round((self.last_audio_pts_sec - self.last_video_pts_sec) * 1000, 1),
        }

    def snapshot_audio_stats(self) -> Dict[str, object]:
        now = time.monotonic()
        active_window_sec = max(0.001, now - self.started_at) if self.started_at else 0.0
        emitted_fps = (self.audio_source_frames / active_window_sec) if active_window_sec else 0.0
        frame_duration_sec = 0.02
        return {
            "freshnessGuardEnabled": True,
            "framesRead": self.audio_source_frames,
            "framesEmitted": self.audio_source_frames,
            "droppedFrames": self.audio_dropped_frames,
            "emittedFps": round(emitted_fps, 2),
            "frameAgeMs": round((now - self.last_audio_frame_at) * 1000, 1)
            if self.last_audio_frame_at
            else None,
            "lastGapMs": round(self.last_audio_gap_ms, 1),
            "maxGapMs": round(self.max_audio_gap_ms, 1),
            "backlogMs": self._queue_depth_ms(self.audio_queue, frame_duration_sec),
            "maxBacklogMs": self._queue_depth_ms(self.audio_queue, frame_duration_sec),
            "lastDropCount": 0,
            "resyncRequests": self.flush_count,
            "lastResyncReason": truncate_for_log(self.last_recovery_reason, 120),
            "syncDelayMs": 0,
            "captureLatencyMsec": 0,
            "audioReady": self.audio_ready,
            "audioActiveFrames": self.audio_active_frames,
            "rms": self.last_rms,
            "maxRms": self.max_rms,
            "source": "source-coupled-av",
            "captureSkewMs": round((self.last_audio_pts_sec - self.last_video_pts_sec) * 1000, 1),
        }

    def stop(self) -> None:
        self.stop_event.set()
        try:
            self._signal_end_of_stream()
        except Exception:
            pass
        try:
            if self.process is not None and self.process.stdout is not None:
                self.process.stdout.close()
        except Exception:
            pass
        try:
            if self.process is not None and self.process.stderr is not None:
                self.process.stderr.close()
        except Exception:
            pass
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
        for thread in (self.reader_thread, self.stderr_thread):
            if thread is not None and thread.is_alive():
                thread.join(timeout=0.5)
        self.reader_thread = None
        self.stderr_thread = None
        self.container = None
        self.process = None


class SourceCoupledAudioTrack(MediaStreamTrack):
    kind = "audio"
    freshness_guard_enabled = True

    def __init__(self, capture: SourceCoupledAVCapture):
        super().__init__()
        self.capture = capture

    async def recv(self) -> AudioFrame:
        return await self.capture.recv_audio_frame()

    def request_resync(self, reason: str = "") -> None:
        self.capture.request_resync(reason)

    def snapshot_stats(self) -> Dict[str, object]:
        return self.capture.snapshot_audio_stats()


class SourceCoupledVideoTrack(MediaStreamTrack):
    kind = "video"
    capture_backend = "source-coupled-av"

    def __init__(
        self,
        capture: SourceCoupledAVCapture,
        desktop_width: int,
        desktop_height: int,
    ):
        super().__init__()
        self.capture = capture
        self.desktop_width = desktop_width
        self.desktop_height = desktop_height
        self.target_width = desktop_width
        self.target_height = desktop_height
        self.output_framerate = max(1, CAPTURE_FRAMERATE)
        self.output_time_base = Fraction(1, self.output_framerate)
        self.output_frame_interval_sec = 1 / self.output_framerate
        self.output_pts = 0
        self.next_delivery_at = 0.0
        self.delivered_frames = 0
        self.pacing_dropped_frames = 0
        self.last_delivered_frame_at = 0.0
        self.recovery_count = 0
        self.last_recovery_reason = ""
        self.set_target_size(
            int(round(self.desktop_width * INITIAL_STREAM_SCALE)),
            int(round(self.desktop_height * INITIAL_STREAM_SCALE)),
        )

    def set_target_size(self, width: int, height: int) -> bool:
        requested_width = clamp_dimension(width, self.desktop_width, MIN_STREAM_WIDTH, self.desktop_width)
        requested_height = clamp_dimension(
            height,
            self.desktop_height,
            MIN_STREAM_HEIGHT,
            self.desktop_height,
        )
        width_scale = requested_width / max(1, self.desktop_width)
        height_scale = requested_height / max(1, self.desktop_height)
        scale = max(
            MIN_STREAM_WIDTH / max(1, self.desktop_width),
            MIN_STREAM_HEIGHT / max(1, self.desktop_height),
            min(1.0, width_scale, height_scale),
        )
        next_width = clamp_dimension(
            int(round(self.desktop_width * scale)),
            self.desktop_width,
            MIN_STREAM_WIDTH,
            self.desktop_width,
        )
        next_height = clamp_dimension(
            int(round(self.desktop_height * scale)),
            self.desktop_height,
            MIN_STREAM_HEIGHT,
            self.desktop_height,
        )
        if next_width % 2 != 0:
            next_width = max(MIN_STREAM_WIDTH, next_width - 1)
        if next_height % 2 != 0:
            next_height = max(MIN_STREAM_HEIGHT, next_height - 1)
        changed = next_width != self.target_width or next_height != self.target_height
        self.target_width = next_width
        self.target_height = next_height
        return changed

    def set_output_framerate(self, framerate: int) -> bool:
        next_framerate = max(1, min(CAPTURE_FRAMERATE, int(framerate)))
        if next_framerate == self.output_framerate:
            return False
        self.output_framerate = next_framerate
        self.output_time_base = Fraction(1, self.output_framerate)
        self.output_frame_interval_sec = 1 / self.output_framerate
        self.next_delivery_at = 0.0
        return True

    def mark_recovery(self, reason: str) -> None:
        self.recovery_count += 1
        self.last_recovery_reason = str(reason or "")
        self.capture.mark_recovery(reason)

    def snapshot_stats(self) -> Dict[str, object]:
        stats = dict(self.capture.snapshot_video_stats())
        now = time.monotonic()
        active_window_sec = max(0.001, now - self.capture.started_at) if self.capture.started_at else 0.0
        stats["deliveredFrames"] = self.delivered_frames
        stats["deliveredFps"] = round((self.delivered_frames / active_window_sec), 2) if active_window_sec else 0.0
        stats["deliveredFrameAgeMs"] = (
            round((now - self.last_delivered_frame_at) * 1000, 1)
            if self.last_delivered_frame_at
            else None
        )
        stats["targetWidth"] = self.target_width
        stats["targetHeight"] = self.target_height
        stats["targetFramerate"] = self.output_framerate
        stats["pacingDroppedFrames"] = self.pacing_dropped_frames
        stats["recoveryCount"] = self.recovery_count
        stats["lastRecoveryReason"] = truncate_for_log(self.last_recovery_reason, 120)
        return stats

    async def recv(self) -> VideoFrame:
        while True:
            frame = await self.capture.recv_video_frame()
            now = time.monotonic()
            if not self.next_delivery_at:
                self.next_delivery_at = now
            if now + 0.001 >= self.next_delivery_at:
                self.next_delivery_at = now + self.output_frame_interval_sec
                break
            self.pacing_dropped_frames += 1
        if frame.width != self.target_width or frame.height != self.target_height:
            reformatted = frame.reformat(width=self.target_width, height=self.target_height)
            reformatted.pts = frame.pts
            reformatted.time_base = frame.time_base
            frame = reformatted
        frame.pts = self.output_pts
        frame.time_base = self.output_time_base
        self.output_pts += 1
        self.delivered_frames += 1
        self.last_delivered_frame_at = time.monotonic()
        return frame


class AdaptiveVideoTrack(MediaStreamTrack):
    kind = "video"

    def __init__(
        self,
        source_track: MediaStreamTrack,
        desktop_width: int,
        desktop_height: int,
        sync_controller: Optional[MediaSyncController] = None,
    ):
        super().__init__()
        self.source_track = source_track
        self.desktop_width = desktop_width
        self.desktop_height = desktop_height
        self.sync_controller = sync_controller
        self.output_framerate = max(1, CAPTURE_FRAMERATE)
        self.output_time_base = Fraction(1, self.output_framerate)
        self.output_pts = 0
        self.output_frame_interval_sec = 1 / self.output_framerate
        self.next_delivery_at = 0.0
        self.target_width = desktop_width
        self.target_height = desktop_height
        self.source_frames = 0
        self.delivered_frames = 0
        self.dropped_frames = 0
        self.source_started_at = 0.0
        self.last_source_frame_at = 0.0
        self.last_delivered_frame_at = 0.0
        self.last_source_gap_ms = 0.0
        self.max_source_gap_ms = 0.0
        self.large_gap_count = 0
        self.recv_errors = 0
        self.last_error = ""
        self.last_error_at = 0.0
        self.recovery_count = 0
        self.last_recovery_reason = ""
        self.last_recovery_at = 0.0
        # Start at a usable floor so early frames remain legible while transport settles.
        self.set_target_size(
            int(round(self.desktop_width * INITIAL_STREAM_SCALE)),
            int(round(self.desktop_height * INITIAL_STREAM_SCALE)),
        )

    def set_target_size(self, width: int, height: int) -> bool:
        requested_width = clamp_dimension(width, self.desktop_width, MIN_STREAM_WIDTH, self.desktop_width)
        requested_height = clamp_dimension(
            height,
            self.desktop_height,
            MIN_STREAM_HEIGHT,
            self.desktop_height,
        )

        width_scale = requested_width / max(1, self.desktop_width)
        height_scale = requested_height / max(1, self.desktop_height)
        scale = max(
            MIN_STREAM_WIDTH / max(1, self.desktop_width),
            MIN_STREAM_HEIGHT / max(1, self.desktop_height),
            min(1.0, width_scale, height_scale),
        )

        next_width = clamp_dimension(
            int(round(self.desktop_width * scale)),
            self.desktop_width,
            MIN_STREAM_WIDTH,
            self.desktop_width,
        )
        next_height = clamp_dimension(
            int(round(self.desktop_height * scale)),
            self.desktop_height,
            MIN_STREAM_HEIGHT,
            self.desktop_height,
        )

        if next_width % 2 != 0:
            next_width = max(MIN_STREAM_WIDTH, next_width - 1)
        if next_height % 2 != 0:
            next_height = max(MIN_STREAM_HEIGHT, next_height - 1)

        changed = next_width != self.target_width or next_height != self.target_height
        self.target_width = next_width
        self.target_height = next_height
        return changed

    def set_output_framerate(self, framerate: int) -> bool:
        next_framerate = max(1, min(CAPTURE_FRAMERATE, int(framerate)))
        if next_framerate == self.output_framerate:
            return False
        self.output_framerate = next_framerate
        self.output_time_base = Fraction(1, self.output_framerate)
        self.output_frame_interval_sec = 1 / self.output_framerate
        self.next_delivery_at = 0.0
        return True

    def mark_recovery(self, reason: str) -> None:
        self.recovery_count += 1
        self.last_recovery_reason = str(reason or "")
        self.last_recovery_at = time.monotonic()

    def snapshot_stats(self) -> Dict[str, object]:
        now = time.monotonic()
        active_window_sec = max(0.001, now - self.source_started_at) if self.source_started_at else 0.0
        source_fps = (self.source_frames / active_window_sec) if active_window_sec else 0.0
        delivered_fps = (self.delivered_frames / active_window_sec) if active_window_sec else 0.0
        source_frame_age_ms = (
            round((now - self.last_source_frame_at) * 1000, 1)
            if self.last_source_frame_at
            else None
        )
        delivered_frame_age_ms = (
            round((now - self.last_delivered_frame_at) * 1000, 1)
            if self.last_delivered_frame_at
            else None
        )
        return {
            "sourceFrames": self.source_frames,
            "deliveredFrames": self.delivered_frames,
            "droppedFrames": self.dropped_frames,
            "sourceFps": round(source_fps, 2),
            "deliveredFps": round(delivered_fps, 2),
            "sourceFrameAgeMs": source_frame_age_ms,
            "deliveredFrameAgeMs": delivered_frame_age_ms,
            "lastSourceGapMs": round(self.last_source_gap_ms, 1),
            "maxSourceGapMs": round(self.max_source_gap_ms, 1),
            "largeGapCount": self.large_gap_count,
            "recvErrors": self.recv_errors,
            "lastError": truncate_for_log(self.last_error, 160),
            "sourceBackend": getattr(self.source_track, "capture_backend", "unknown"),
            "targetWidth": self.target_width,
            "targetHeight": self.target_height,
            "targetFramerate": self.output_framerate,
            "pacingDroppedFrames": self.dropped_frames,
            "recoveryCount": self.recovery_count,
            "lastRecoveryReason": truncate_for_log(self.last_recovery_reason, 120),
        }

    async def recv(self) -> VideoFrame:
        delivered_at = 0.0
        while True:
            try:
                frame = await self.source_track.recv()
            except MediaStreamError as error:
                self.recv_errors += 1
                self.last_error = repr(error)
                self.last_error_at = time.monotonic()
                raise

            now = time.monotonic()
            source_stats = None
            if hasattr(self.source_track, "snapshot_source_stats"):
                try:
                    source_stats = self.source_track.snapshot_source_stats()
                except Exception:
                    source_stats = None
            if isinstance(source_stats, dict):
                self.source_frames = int(source_stats.get("sourceFrames", self.source_frames))
                self.source_started_at = float(
                    source_stats.get("sourceStartedAt", self.source_started_at or now)
                )
                self.last_source_frame_at = float(
                    source_stats.get("lastSourceFrameAt", self.last_source_frame_at or now)
                )
                self.last_source_gap_ms = float(
                    source_stats.get("lastSourceGapMs", self.last_source_gap_ms)
                )
                self.max_source_gap_ms = float(
                    source_stats.get("maxSourceGapMs", self.max_source_gap_ms)
                )
                self.large_gap_count = int(
                    source_stats.get("largeGapCount", self.large_gap_count)
                )
                self.recv_errors = max(
                    self.recv_errors,
                    int(source_stats.get("recvErrors", self.recv_errors)),
                )
                source_last_error = str(source_stats.get("lastError", "") or "")
                if source_last_error:
                    self.last_error = source_last_error
            else:
                if not self.source_started_at:
                    self.source_started_at = now
                if self.last_source_frame_at:
                    gap_ms = (now - self.last_source_frame_at) * 1000
                    self.last_source_gap_ms = gap_ms
                    self.max_source_gap_ms = max(self.max_source_gap_ms, gap_ms)
                    if gap_ms > ((1000 / max(1, CAPTURE_FRAMERATE)) * 2.5):
                        self.large_gap_count += 1
                self.last_source_frame_at = now
                self.source_frames += 1

            if not self.next_delivery_at:
                self.next_delivery_at = now

            if now + 0.001 >= self.next_delivery_at:
                delivered_at = now
                self.next_delivery_at = delivered_at + self.output_frame_interval_sec
                break

            self.dropped_frames += 1

        target_width = self.target_width
        target_height = self.target_height

        if frame.width == target_width and frame.height == target_height:
            output_frame = frame
        else:
            output_frame = frame.reformat(width=target_width, height=target_height)

        output_frame.pts = self.output_pts
        output_frame.time_base = self.output_time_base
        self.output_pts += 1
        self.delivered_frames += 1
        self.last_delivered_frame_at = delivered_at
        if self.sync_controller is not None:
            source_window_sec = max(0.001, delivered_at - (self.source_started_at or delivered_at))
            self.sync_controller.observe_video(
                gap_ms=self.last_source_gap_ms,
                fps=(self.delivered_frames / source_window_sec) if self.source_started_at else 0.0,
                frame_age_ms=max(0.0, (delivered_at - self.last_source_frame_at) * 1000)
                if self.last_source_frame_at
                else 0.0,
            )
        return output_frame

    def stop(self) -> None:
        try:
            if self.source_track is not None:
                self.source_track.stop()
        finally:
            super().stop()


def extract_candidate_type(candidate_line: str) -> str:
    normalized = candidate_line.strip()
    if normalized.startswith("a="):
        normalized = normalized[2:]
    if normalized.startswith("candidate:"):
        normalized = normalized[len("candidate:") :]
    parts = normalized.split()
    for index, part in enumerate(parts[:-1]):
        if part == "typ":
            return parts[index + 1].lower()
    return ""


def is_allowed_candidate(candidate_line: str, allowed_types) -> bool:
    if not allowed_types:
        return True
    candidate_type = extract_candidate_type(candidate_line)
    if not candidate_type:
        return True
    return candidate_type in allowed_types


def filter_sdp_candidates(sdp: str, allowed_types) -> str:
    if not sdp:
        return sdp

    filtered_lines = []
    for line in sdp.splitlines():
        if line.startswith("a=candidate:") and not is_allowed_candidate(line, allowed_types):
            continue
        filtered_lines.append(line)

    return "\r\n".join(filtered_lines) + "\r\n"


def codec_name_from_mime_type(mime_type: object) -> str:
    value = str(mime_type or "").strip()
    if "/" in value:
        value = value.split("/", 1)[1]
    return value.strip().upper()


def append_fmtp_parameter(existing: str, name: str, value: int) -> str:
    normalized_name = name.strip().lower()
    parts = [
        part.strip()
        for part in str(existing or "").split(";")
        if part.strip()
    ]
    updated = False
    for index, part in enumerate(parts):
        if "=" not in part:
            continue
        key, _current = part.split("=", 1)
        if key.strip().lower() == normalized_name:
            parts[index] = f"{name}={value}"
            updated = True
            break
    if not updated:
        parts.append(f"{name}={value}")
    return ";".join(parts)


def apply_video_bitrate_hints_to_sdp(sdp: str) -> str:
    if not sdp:
        return sdp

    sections: List[List[str]] = []
    current_section: List[str] = []
    for raw_line in sdp.splitlines():
        line = raw_line.rstrip("\r")
        if line.startswith("m=") and current_section:
            sections.append(current_section)
            current_section = [line]
        else:
            current_section.append(line)
    if current_section:
        sections.append(current_section)

    tuned_sections: List[List[str]] = []
    for section in sections:
        if not section or not section[0].startswith("m=video "):
            tuned_sections.append(section)
            continue

        codec_by_payload: Dict[str, str] = {}
        fmtp_lines: Dict[str, str] = {}
        ordered_lines: List[str] = []
        for line in section:
            if line.startswith("b=AS:") or line.startswith("b=TIAS:"):
                continue
            if line.startswith("a=rtpmap:"):
                payload = line[len("a=rtpmap:") :].split(" ", 1)[0].strip()
                mime = line.split(" ", 1)[1].split("/", 1)[0] if " " in line else ""
                codec_by_payload[payload] = codec_name_from_mime_type(mime)
            elif line.startswith("a=fmtp:"):
                payload = line[len("a=fmtp:") :].split(" ", 1)[0].strip()
                params = line.split(" ", 1)[1] if " " in line else ""
                fmtp_lines[payload] = params
                continue
            ordered_lines.append(line)

        insert_at = 1
        for index, line in enumerate(ordered_lines[1:], start=1):
            if line.startswith("i=") or line.startswith("c="):
                insert_at = index + 1
        ordered_lines[insert_at:insert_at] = [
            f"b=AS:{max(1, VIDEO_MAX_BITRATE_BPS // 1000)}",
            f"b=TIAS:{VIDEO_MAX_BITRATE_BPS}",
        ]

        for payload, codec_name in codec_by_payload.items():
            if codec_name in {"H264", "VP8"}:
                params = append_fmtp_parameter(fmtp_lines.get(payload, ""), "x-google-min-bitrate", VIDEO_MIN_BITRATE_BPS // 1000)
                params = append_fmtp_parameter(params, "x-google-start-bitrate", VIDEO_START_BITRATE_BPS // 1000)
                params = append_fmtp_parameter(params, "x-google-max-bitrate", VIDEO_MAX_BITRATE_BPS // 1000)
                fmtp_lines[payload] = params

        rebuilt_section: List[str] = []
        inserted_payloads = set()
        for line in ordered_lines:
            rebuilt_section.append(line)
            if line.startswith("a=rtpmap:"):
                payload = line[len("a=rtpmap:") :].split(" ", 1)[0].strip()
                if payload in fmtp_lines and payload not in inserted_payloads:
                    rebuilt_section.append(f"a=fmtp:{payload} {fmtp_lines[payload]}")
                    inserted_payloads.add(payload)
        tuned_sections.append(rebuilt_section)

    return "\r\n".join(line for section in tuned_sections for line in section) + "\r\n"


def order_video_codec_preferences(codecs, preferences=None, strict: bool = False) -> List:
    codec_preferences = VIDEO_CODEC_PREFERENCES if preferences is None else preferences
    if not codec_preferences:
        return list(codecs or [])

    preferred = []
    remainder = []
    retransmission = []
    for codec in codecs or []:
        codec_name = codec_name_from_mime_type(getattr(codec, "mimeType", ""))
        if codec_name == "RTX":
            retransmission.append(codec)
        elif codec_name in codec_preferences:
            preferred.append(codec)
        elif not strict:
            remainder.append(codec)

    ordered: List = []
    for codec_name in codec_preferences:
        for codec in preferred:
            if codec_name_from_mime_type(getattr(codec, "mimeType", "")) == codec_name:
                ordered.append(codec)
    if strict:
        return ordered
    ordered.extend(remainder)
    ordered.extend(retransmission)
    return ordered


def find_browser_window() -> Optional[str]:
    for klass in ("chromium", "Chromium"):
        result = subprocess.run(
            ["xdotool", "search", "--onlyvisible", "--class", klass],
            env=DISPLAY_ENV,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip().splitlines()[0]
    return None


async def wait_for_browser_window(timeout: float = 10.0) -> Optional[str]:
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        window_id = find_browser_window()
        if window_id:
            return window_id
        await asyncio.sleep(0.1)
    return None


def focus_browser(force: bool = False, wait: bool = False) -> None:
    global LAST_BROWSER_FOCUS_AT

    now = time.monotonic()
    if (
        not force
        and INPUT_FOCUS_REFRESH_INTERVAL_SEC > 0
        and now - LAST_BROWSER_FOCUS_AT < INPUT_FOCUS_REFRESH_INTERVAL_SEC
    ):
        return

    window_id = find_browser_window()
    if window_id:
        args = ["xdotool", "windowactivate"]
        if wait:
            args.append("--sync")
        args.append(window_id)
        run_cmd(*args)
        LAST_BROWSER_FOCUS_AT = now


async def focus_browser_async(force: bool = False, wait: bool = False) -> None:
    await asyncio.to_thread(focus_browser, force, wait)


def nudge_browser_window_geometry(width: int, height: int) -> None:
    window_id = find_browser_window()
    if not window_id:
        return

    resized_width = max(1, width - 1)
    resized_height = max(1, height - 1)
    run_cmd("xdotool", "windowactivate", "--sync", window_id)
    run_cmd("xdotool", "windowsize", window_id, str(resized_width), str(resized_height))
    run_cmd("xdotool", "windowsize", window_id, str(width), str(height))
    run_cmd("xdotool", "windowmove", window_id, "0", "0")


def map_key(code: str, key: str) -> Optional[str]:
    mapping = {
        "Enter": "Return",
        "Escape": "Escape",
        "Backspace": "BackSpace",
        "Tab": "Tab",
        "Space": "space",
        "ArrowLeft": "Left",
        "ArrowRight": "Right",
        "ArrowUp": "Up",
        "ArrowDown": "Down",
        "ShiftLeft": "Shift_L",
        "ShiftRight": "Shift_R",
        "ControlLeft": "Control_L",
        "ControlRight": "Control_R",
        "AltLeft": "Alt_L",
        "AltRight": "Alt_R",
        "MetaLeft": "Super_L",
        "MetaRight": "Super_R",
        "Delete": "Delete",
        "Home": "Home",
        "End": "End",
        "PageUp": "Page_Up",
        "PageDown": "Page_Down",
        "CapsLock": "Caps_Lock",
        "Backquote": "grave",
        "Minus": "minus",
        "Equal": "equal",
        "BracketLeft": "bracketleft",
        "BracketRight": "bracketright",
        "Backslash": "backslash",
        "IntlBackslash": "backslash",
        "Semicolon": "semicolon",
        "Quote": "apostrophe",
        "Comma": "comma",
        "Period": "period",
        "Slash": "slash",
        "NumpadDecimal": "KP_Decimal",
        "NumpadAdd": "KP_Add",
        "NumpadSubtract": "KP_Subtract",
        "NumpadMultiply": "KP_Multiply",
        "NumpadDivide": "KP_Divide",
    }
    punctuation = {
        "`": "grave",
        "~": "grave",
        "-": "minus",
        "_": "minus",
        "=": "equal",
        "+": "equal",
        "[": "bracketleft",
        "{": "bracketleft",
        "]": "bracketright",
        "}": "bracketright",
        "\\": "backslash",
        "|": "backslash",
        ";": "semicolon",
        ":": "semicolon",
        "'": "apostrophe",
        "\"": "apostrophe",
        ",": "comma",
        "<": "comma",
        ".": "period",
        ">": "period",
        "/": "slash",
        "?": "slash",
    }
    if code in mapping:
        return mapping[code]
    if code.startswith("Key") and len(code) == 4:
        return code[-1].lower()
    if code.startswith("Digit") and len(code) == 6:
        return code[-1]
    if len(key) == 1:
        if key == " ":
            return "space"
        if key in punctuation:
            return punctuation[key]
        return key
    return None


async def handle_input(
    message: Dict,
    default_width: int,
    default_height: int,
    video_track: Optional[MediaStreamTrack] = None,
    audio_track: Optional[MediaStreamTrack] = None,
    browser: Optional["ChromiumController"] = None,
) -> None:
    msg_type = message.get("type")
    if msg_type == "pointer.sync":
        coordinates = pointer_coordinates_from_message(message, default_width, default_height)
        if coordinates is not None:
            sync_pointer_position(*coordinates)
        return

    if msg_type == "pointer.move":
        coordinates = pointer_coordinates_from_message(message, default_width, default_height)
        if coordinates is not None:
            queue_pointer_move(*coordinates)
        return

    if msg_type == "pointer.button":
        button_map = {0: 1, 1: 2, 2: 3}
        button = button_map.get(int(message.get("button", 0)))
        if not button:
            return
        await focus_browser_async()
        coordinates = pointer_coordinates_from_message(message, default_width, default_height)
        if coordinates is not None:
            sync_pointer_position(*coordinates)
        get_xinput().button(button, message.get("action") == "down")
        return

    if msg_type == "text.insert":
        text = message.get("text")
        if text is None:
            text = message.get("data")
        if text is None:
            text = message.get("value", "")
        await insert_text_with_fallback(str(text), browser)
        return

    if msg_type == "wheel":
        global WHEEL_SCROLL_REMAINDER_Y
        delta_y = float(message.get("deltaY", 0))
        if delta_y == 0:
            return
        delta_mode = int(message.get("deltaMode", 0))
        if delta_mode == 1:
            wheel_units = delta_y / WHEEL_LINE_DELTA_PER_CLICK
        elif delta_mode == 2:
            wheel_units = delta_y * WHEEL_PAGE_TO_CLICK_MULTIPLIER
        else:
            wheel_units = delta_y / WHEEL_PIXEL_DELTA_PER_CLICK
        if wheel_units == 0:
            return
        if WHEEL_SCROLL_REMAINDER_Y and ((WHEEL_SCROLL_REMAINDER_Y > 0) != (wheel_units > 0)):
            WHEEL_SCROLL_REMAINDER_Y = 0.0
        WHEEL_SCROLL_REMAINDER_Y += wheel_units
        clicks = min(8, int(abs(WHEEL_SCROLL_REMAINDER_Y)))
        if clicks < 1:
            return
        button = 5 if WHEEL_SCROLL_REMAINDER_Y > 0 else 4
        await focus_browser_async()
        get_xinput().wheel(button, clicks)
        if WHEEL_SCROLL_REMAINDER_Y > 0:
            WHEEL_SCROLL_REMAINDER_Y -= clicks
        else:
            WHEEL_SCROLL_REMAINDER_Y += clicks
        return

    if msg_type == "key":
        key_name = map_key(message.get("code", ""), message.get("key", ""))
        if not key_name:
            return
        await focus_browser_async()
        get_xinput().key(key_name, message.get("action") == "down")
        return

    if msg_type == "browser.history":
        if browser is None:
            return
        direction = str(message.get("action") or "").strip().lower()
        if direction not in {"back", "forward"}:
            return
        if audio_track is not None and audio_track.freshness_guard_enabled:
            await browser.pause_media_playback(f"history-{direction}:before")
        if audio_track is not None:
            audio_track.request_resync(f"history-{direction}:before")
        await browser.navigate_history(direction)
        if audio_track is not None:
            audio_track.request_resync(f"history-{direction}:after")
        return

    if msg_type == "browser.reload":
        if browser is None:
            return
        if audio_track is not None and audio_track.freshness_guard_enabled:
            await browser.pause_media_playback("reload:before")
        if audio_track is not None:
            audio_track.request_resync("reload:before")
        await browser.reload()
        if audio_track is not None:
            audio_track.request_resync("reload:after")
        return

    if msg_type == "stream.configure":
        if video_track is None:
            return

        width = clamp_dimension(
            message.get("width", default_width),
            default_width,
            MIN_STREAM_WIDTH,
            default_width,
        )
        height = clamp_dimension(
            message.get("height", default_height),
            default_height,
            MIN_STREAM_HEIGHT,
            default_height,
        )
        video_track.set_target_size(width, height)


def detect_pool_worker_identity() -> Tuple[str, Optional[str]]:
    configured_id = os.environ.get("POOL_WORKER_ID", "").strip()
    if configured_id:
        return configured_id, None

    metadata_url = os.environ.get("ECS_CONTAINER_METADATA_URI_V4", "").strip()
    if metadata_url:
        try:
            with urllib.request.urlopen(f"{metadata_url}/task", timeout=2) as response:
                payload = json.loads(response.read().decode("utf-8"))
            task_arn = payload.get("TaskARN")
            if task_arn:
                return task_arn.rsplit("/", 1)[-1], task_arn
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            pass

    fallback_id = f"pool-{uuid.uuid4().hex}"
    return fallback_id, None


class ChromiumController:
    def __init__(self, width: int, height: int):
        self.width = clamp_dimension(width, DISPLAY_WIDTH, 640, DISPLAY_WIDTH)
        self.height = clamp_dimension(height, DISPLAY_HEIGHT, 480, DISPLAY_HEIGHT)
        self.process: Optional[subprocess.Popen] = None
        self.cdp_ws = None
        self.cdp_lock = asyncio.Lock()
        self.cdp_message_id = 0
        self.cdp_target_id: Optional[str] = None
        self.profile_dir: Optional[str] = None
        self.media_playback_tasks: List[asyncio.Task] = []
        self.last_page_state: Dict[str, object] = {}

    @property
    def devtools_base_url(self) -> str:
        return f"http://127.0.0.1:{REMOTE_DEBUGGING_PORT}"

    def create_profile_dir(self) -> str:
        profile_dir = f"{CHROME_PROFILE_DIR}-{uuid.uuid4().hex}"
        os.makedirs(profile_dir, exist_ok=True)
        return profile_dir

    def _fetch_json(self, endpoint: str):
        request = urllib.request.Request(
            f"{self.devtools_base_url}{endpoint}",
            headers={"Cache-Control": "no-store"},
        )
        with urllib.request.urlopen(request, timeout=2) as response:
            return json.loads(response.read().decode("utf-8"))

    async def _poll_json(self, endpoint: str):
        return await asyncio.to_thread(self._fetch_json, endpoint)

    async def stop(self) -> None:
        for task in self.media_playback_tasks:
            task.cancel()
        self.media_playback_tasks.clear()

        if self.cdp_ws is not None:
            try:
                await self.cdp_ws.close()
            except Exception:
                pass
            self.cdp_ws = None
            self.cdp_target_id = None

        if self.process and self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                await asyncio.to_thread(self.process.wait, 5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    await asyncio.to_thread(self.process.wait, 5)
                except subprocess.TimeoutExpired:
                    pass

        self.process = None
        if self.profile_dir:
            subprocess.run(
                ["pkill", "-f", self.profile_dir],
                env=DISPLAY_ENV,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            shutil.rmtree(self.profile_dir, ignore_errors=True)
            self.profile_dir = None

    async def _wait_for_target(self, timeout: float = 15.0) -> Dict:
        deadline = asyncio.get_running_loop().time() + timeout
        while asyncio.get_running_loop().time() < deadline:
            if self.process and self.process.poll() is not None:
                raise RuntimeError("Chromium exited during startup")
            try:
                targets = await self._poll_json("/json/list")
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
                await asyncio.sleep(0.1)
                continue

            for target in targets:
                if (
                    target.get("type") == "page"
                    and target.get("webSocketDebuggerUrl")
                ):
                    return target
            await asyncio.sleep(0.1)
        raise RuntimeError("Timed out waiting for Chromium DevTools target")

    async def _connect_cdp(self) -> None:
        target = await self._wait_for_target()
        self.cdp_target_id = target.get("id")
        self.cdp_ws = await websockets.connect(
            target["webSocketDebuggerUrl"],
            max_size=4 * 1024 * 1024,
        )
        await self._send_cdp_on_open_socket(
            "Emulation.setUserAgentOverride",
            {
                "userAgent": STEALTH_USER_AGENT,
                "acceptLanguage": "en-US,en",
                "platform": "Linux x86_64",
            },
        )
        await self._send_cdp_on_open_socket(
            "Page.addScriptToEvaluateOnNewDocument",
            {
                "source": """
Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
Object.defineProperty(navigator, 'language', { get: () => 'en-US' });
Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
Object.defineProperty(navigator, 'platform', { get: () => 'Linux x86_64' });
Object.defineProperty(navigator, 'vendor', { get: () => 'Google Inc.' });
Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3, 4, 5] });
window.chrome = window.chrome || { runtime: {} };
""",
            },
        )
        await self._send_cdp_on_open_socket(
            "Page.addScriptToEvaluateOnNewDocument",
            {
                "source": """
(() => {
  if (window.__rbiYouTubeMediaUnlockInstalled) {
    return;
  }
  window.__rbiYouTubeMediaUnlockInstalled = true;

  const isYouTubeHost = () => {
    const host = String(window.location?.hostname || "").toLowerCase();
    return (
      host === "youtube.com" ||
      host.endsWith(".youtube.com") ||
      host === "youtu.be"
    );
  };

  let nudgeTimer = 0;
  let keepAliveInterval = 0;

  const isMediaSurface = () => {
    if (!isYouTubeHost()) {
      return false;
    }
    const pathname = String(window.location?.pathname || "");
    return (
      window.location?.hostname === "youtu.be" ||
      pathname === "/watch" ||
      pathname.startsWith("/watch") ||
      pathname.startsWith("/shorts")
    );
  };

  const getPlayerApi = () =>
    window.ytplayer?.player_ || window.movie_player || document.getElementById("movie_player");

  const getPrimaryMediaElement = () => {
    const player = document.getElementById("movie_player");
    const playerVideo =
      player?.querySelector?.("video.html5-main-video") ||
      player?.querySelector?.("video") ||
      null;
    if (playerVideo instanceof HTMLMediaElement) {
      return playerVideo;
    }

    const visibleMedia = Array.from(document.querySelectorAll("video, audio"))
      .filter((element) => element instanceof HTMLMediaElement)
      .map((element) => {
        const rect = element.getBoundingClientRect?.();
        const area = rect ? Math.max(0, rect.width) * Math.max(0, rect.height) : 0;
        return { element, area };
      })
      .filter(({ area }) => area > 0);

    visibleMedia.sort((left, right) => right.area - left.area);
    return visibleMedia[0]?.element || null;
  };

  const silenceBrowseSurface = () => {
    for (const media of document.querySelectorAll("video, audio")) {
      try {
        media.defaultMuted = true;
      } catch {}
      try {
        media.muted = true;
      } catch {}
      try {
        media.volume = 0;
      } catch {}
      if (media instanceof HTMLAudioElement) {
        try {
          media.pause();
        } catch {}
      }
    }

    const player = getPlayerApi();
    if (player) {
      try {
        if (typeof player.pauseVideo === "function") {
          player.pauseVideo();
        }
      } catch {}
      try {
        if (typeof player.mute === "function") {
          player.mute();
        }
      } catch {}
      try {
        if (typeof player.setVolume === "function") {
          player.setVolume(0);
        }
      } catch {}
    }

    const miniPlayerCloseButton = document.querySelector(
      ".ytd-miniplayer button[aria-label*='Close'], .ytp-miniplayer-close-button, button.ytp-miniplayer-close-button",
    );
    if (miniPlayerCloseButton instanceof HTMLElement) {
      try {
        miniPlayerCloseButton.click();
      } catch {}
    }
  };

  const nudge = () => {
    if (!isYouTubeHost()) {
      return;
    }

    if (!isMediaSurface()) {
      silenceBrowseSurface();
      return;
    }

    const primaryMedia = getPrimaryMediaElement();

    for (const media of document.querySelectorAll("video, audio")) {
      const isPrimary = media === primaryMedia;
      if (!isPrimary) {
        try {
          media.defaultMuted = true;
        } catch {}
        try {
          media.muted = true;
        } catch {}
        try {
          media.volume = 0;
        } catch {}
        try {
          media.pause();
        } catch {}
        continue;
      }
      try {
        media.defaultMuted = false;
      } catch {}
      try {
        media.muted = false;
      } catch {}
      try {
        media.volume = 1;
      } catch {}
      try {
        media.autoplay = true;
      } catch {}
      try {
        media.preload = "auto";
      } catch {}
      try {
        media.playsInline = true;
      } catch {}
      try {
        const playPromise = media.play();
        if (playPromise && typeof playPromise.catch === "function") {
          playPromise.catch(() => {});
        }
      } catch {}
    }

    const player = document.getElementById("movie_player");
    if (player) {
      try {
        if (typeof player.unMute === "function") {
          player.unMute();
        }
      } catch {}
      try {
        if (typeof player.setVolume === "function") {
          player.setVolume(100);
        }
      } catch {}
      try {
        if (typeof player.playVideo === "function") {
          player.playVideo();
        }
      } catch {}
    }
  };

  const scheduleNudge = (delayMs = 0) => {
    if (delayMs <= 0) {
      nudge();
      return;
    }
    window.clearTimeout(nudgeTimer);
    nudgeTimer = window.setTimeout(() => {
      nudgeTimer = 0;
      nudge();
    }, delayMs);
  };

  const burst = () => {
    if (!isYouTubeHost()) {
      return;
    }
    for (const delayMs of [0, 200, 800, 1600, 3200, 6400, 12000, 20000, 30000]) {
      window.setTimeout(nudge, delayMs);
    }
    if (!keepAliveInterval) {
      let remainingTicks = 45;
      keepAliveInterval = window.setInterval(() => {
        if (!isYouTubeHost() || remainingTicks <= 0) {
          window.clearInterval(keepAliveInterval);
          keepAliveInterval = 0;
          return;
        }
        remainingTicks -= 1;
        nudge();
      }, 1000);
    }
  };

  const historyMethods = ["pushState", "replaceState"];
  for (const methodName of historyMethods) {
    const original = history[methodName];
    if (typeof original !== "function") {
      continue;
    }
    history[methodName] = function (...args) {
      const result = original.apply(this, args);
      scheduleNudge(0);
      burst();
      return result;
    };
  }

  window.addEventListener("popstate", burst, { passive: true });
  window.addEventListener("hashchange", burst, { passive: true });
  window.addEventListener("yt-navigate-finish", burst, { passive: true });
  window.addEventListener("load", burst, { passive: true });
  document.addEventListener("DOMContentLoaded", burst, { passive: true });

    const observer = new MutationObserver((mutations) => {
    if (!isYouTubeHost()) {
      return;
    }
    for (const mutation of mutations) {
      if (mutation.type !== "childList" || mutation.addedNodes.length === 0) {
        continue;
      }
      for (const node of mutation.addedNodes) {
        if (!(node instanceof Element)) {
          continue;
        }
        if (
          node.matches?.("video, audio") ||
          node.querySelector?.("video, audio")
        ) {
          scheduleNudge(50);
          return;
        }
      }
    }
  });

  const observeWhenReady = () => {
    const root = document.documentElement || document.body;
    if (!root) {
      window.setTimeout(observeWhenReady, 50);
      return;
    }
    observer.observe(root, { childList: true, subtree: true });
  };

  observeWhenReady();
  burst();
})();
""",
            },
        )
        await self._send_cdp_on_open_socket("Page.enable")
        await self._send_cdp_on_open_socket("DOM.enable")

    async def _close_cdp_socket(self) -> None:
        if self.cdp_ws is None:
            self.cdp_target_id = None
            return
        ws = self.cdp_ws
        self.cdp_ws = None
        self.cdp_target_id = None
        try:
            await ws.close()
        except Exception:
            pass

    async def reset_cdp_connection(self) -> None:
        async with self.cdp_lock:
            await self._close_cdp_socket()
            await self._connect_cdp()

    async def _send_cdp_on_open_socket(
        self, method: str, params: Optional[Dict] = None
    ) -> Dict:
        if self.cdp_ws is None:
            raise RuntimeError("CDP socket is not connected")

        self.cdp_message_id += 1
        message_id = self.cdp_message_id
        try:
            await self.cdp_ws.send(
                json.dumps(
                    {
                        "id": message_id,
                        "method": method,
                        "params": params or {},
                    }
                )
            )

            while True:
                raw = await self.cdp_ws.recv()
                payload = json.loads(raw)
                if payload.get("id") != message_id:
                    continue
                if payload.get("error"):
                    raise RuntimeError(payload["error"].get("message", f"CDP {method} failed"))
                return payload.get("result", {})
        except ConnectionClosed:
            await self._close_cdp_socket()
            raise

    async def send_cdp(self, method: str, params: Optional[Dict] = None) -> Dict:
        async with self.cdp_lock:
            if self.cdp_ws is None:
                await self._connect_cdp()
            return await self._send_cdp_on_open_socket(method, params)

    async def capture_screenshot_bytes(
        self,
        *,
        screenshot_format: str = "jpeg",
        quality: int = CDP_SCREENSHOT_QUALITY,
    ) -> bytes:
        result = await self.send_cdp(
            "Page.captureScreenshot",
            {
                "format": screenshot_format,
                "quality": quality,
                "fromSurface": True,
                "captureBeyondViewport": False,
                "optimizeForSpeed": True,
            },
        )
        data = str(result.get("data") or "")
        if not data:
            raise RuntimeError("CDP screenshot capture returned no data")
        return base64.b64decode(data)

    async def get_dom_outer_html(self) -> str:
        result = await self.send_cdp("DOM.getDocument", {"depth": 0, "pierce": True})
        root = result.get("root") or {}
        node_id = root.get("nodeId")
        if not node_id:
            raise RuntimeError("CDP DOM.getDocument returned no root node id")
        payload = await self.send_cdp("DOM.getOuterHTML", {"nodeId": node_id})
        outer_html = str(payload.get("outerHTML") or "")
        if not outer_html:
            raise RuntimeError("CDP DOM.getOuterHTML returned no html")
        return outer_html

    async def get_hybrid_dom_metadata(self) -> Dict[str, object]:
        metadata = await self.evaluate_cdp(
            """
(() => {
  const editableSelector = "[contenteditable=''], [contenteditable='true']";
  return {
    url: String(location.href || ""),
    title: String(document.title || ""),
    scrollX: Number(window.scrollX || 0),
    scrollY: Number(window.scrollY || 0),
    viewport: {
      width: Number(window.innerWidth || 0),
      height: Number(window.innerHeight || 0),
    },
    formState: {
      inputs: Array.from(document.querySelectorAll("input")).map((input) => {
        const type = String(input.type || "text").toLowerCase();
        return {
          type,
          value: type === "password" ? "" : String(input.value || ""),
          checked: Boolean(input.checked),
          disabled: Boolean(input.disabled),
          readOnly: Boolean(input.readOnly),
        };
      }),
      textareas: Array.from(document.querySelectorAll("textarea")).map((textarea) => ({
        value: String(textarea.value || ""),
        disabled: Boolean(textarea.disabled),
        readOnly: Boolean(textarea.readOnly),
      })),
      selects: Array.from(document.querySelectorAll("select")).map((select) => ({
        selectedIndex: Number(select.selectedIndex ?? -1),
        selectedOptions: Array.from(select.options || [])
          .map((option, optionIndex) => (option.selected ? optionIndex : -1))
          .filter((optionIndex) => optionIndex >= 0),
        disabled: Boolean(select.disabled),
      })),
      editable: Array.from(document.querySelectorAll(editableSelector)).map((element) => ({
        html: String(element.innerHTML || ""),
      })),
    },
  };
})()
            """.strip(),
            return_by_value=True,
        )
        if isinstance(metadata, dict):
            return metadata
        raise RuntimeError("Hybrid DOM metadata payload was not an object")

    async def capture_hybrid_dom_snapshot_via_cdp(self) -> Dict[str, object]:
        raw_html = await self.get_dom_outer_html()
        metadata = await self.get_hybrid_dom_metadata()
        sanitized_html = re.sub(
            r"<script\\b[\\s\\S]*?<\\/script>",
            "",
            raw_html,
            flags=re.IGNORECASE,
        )
        if not sanitized_html.lower().lstrip().startswith("<!doctype"):
            sanitized_html = f"<!doctype html>{sanitized_html}"
        return {
            "url": str(metadata.get("url") or ""),
            "title": str(metadata.get("title") or ""),
            "html": sanitized_html,
            "scrollX": float(metadata.get("scrollX") or 0),
            "scrollY": float(metadata.get("scrollY") or 0),
            "viewport": metadata.get("viewport") or {"width": 0, "height": 0},
            "formState": metadata.get("formState") or {},
            "backend": "rbi-worker",
        }

    async def evaluate_cdp(
        self,
        expression: str,
        *,
        await_promise: bool = False,
        return_by_value: bool = True,
        user_gesture: bool = False,
    ):
        result = await self.send_cdp(
            "Runtime.evaluate",
            {
                "expression": expression,
                "awaitPromise": await_promise,
                "returnByValue": return_by_value,
                "userGesture": user_gesture,
            },
        )
        return result.get("result", {}).get("value")

    async def wait_for_document_ready(self, timeout: float = 8.0) -> str:
        deadline = asyncio.get_running_loop().time() + timeout
        while asyncio.get_running_loop().time() < deadline:
            try:
                ready_state = await self.evaluate_cdp("document.readyState")
            except Exception:
                await asyncio.sleep(0.1)
                continue
            if ready_state in {"interactive", "complete"}:
                return str(ready_state)
            await asyncio.sleep(0.1)
        return "loading"

    async def get_page_state(self) -> Dict[str, object]:
        state = await self.evaluate_cdp(
            """
(() => ({
  href: String(window.location?.href || ""),
  title: String(document.title || ""),
  readyState: String(document.readyState || ""),
  visibilityState: String(document.visibilityState || ""),
  hasBody: Boolean(document.body),
  bodyTextLength: Number((document.body?.innerText || "").trim().length),
  bodyHtmlLength: Number((document.body?.innerHTML || "").length),
}))()
            """.strip()
        )
        if isinstance(state, dict):
            self.last_page_state = dict(state)
            return state
        return {}

    async def wait_for_page_commit(
        self, timeout: float = NAVIGATION_PAGE_STATE_TIMEOUT_SEC
    ) -> Dict[str, object]:
        deadline = asyncio.get_running_loop().time() + timeout
        last_state: Dict[str, object] = {}
        while asyncio.get_running_loop().time() < deadline:
            try:
                state = await self.get_page_state()
            except Exception:
                await asyncio.sleep(0.15)
                continue
            last_state = state
            if not is_blank_or_error_url(state.get("href")):
                return state
            await asyncio.sleep(0.15)
        return last_state

    async def navigate_history(self, direction: str) -> bool:
        action = str(direction or "").strip().lower()
        if action not in {"back", "forward"}:
            return False

        history = await self.send_cdp("Page.getNavigationHistory")
        entries = history.get("entries") or []
        current_index = int(history.get("currentIndex") or 0)
        step = -1 if action == "back" else 1
        target_index = current_index + step
        target_entry = {}
        skipped_entries = 0
        while 0 <= target_index < len(entries):
            candidate_entry = entries[target_index] or {}
            candidate_url = str(candidate_entry.get("url") or "")
            if not is_blank_or_error_url(candidate_url):
                target_entry = candidate_entry
                break
            skipped_entries += 1
            target_index += step
        if not target_entry:
            if skipped_entries:
                log(
                    "history-navigation-skip",
                    f"direction={action}",
                    f"skipped={skipped_entries}",
                    "target=<none>",
                )
            return False

        entry_id = target_entry.get("id")
        if not entry_id:
            return False

        await self.send_cdp("Page.bringToFront")
        await self.send_cdp("Page.navigateToHistoryEntry", {"entryId": entry_id})
        page_state = await self.wait_for_page_commit()
        if isinstance(page_state, dict):
            self.last_page_state = dict(page_state)
            if not is_probable_media_page(page_state.get("href")):
                await self.pause_media_playback(f"history-{action}:landed")
            log(
                "history-navigation",
                f"direction={action}",
                f"skipped={skipped_entries}",
                f"url={truncate_for_log(page_state.get('href'), 160)}",
                f"title={truncate_for_log(page_state.get('title'), 120)}",
            )
        self.schedule_media_playback_nudges(f"history-{action}")
        return True

    async def reload(self) -> bool:
        await self.send_cdp("Page.bringToFront")
        await self.send_cdp("Page.reload", {"ignoreCache": False})
        page_state = await self.wait_for_page_commit()
        if isinstance(page_state, dict):
            self.last_page_state = dict(page_state)
            if not is_probable_media_page(page_state.get("href")):
                await self.pause_media_playback("reload:landed")
            log(
                "page-reload",
                f"url={truncate_for_log(page_state.get('href'), 160)}",
                f"title={truncate_for_log(page_state.get('title'), 120)}",
            )
        self.schedule_media_playback_nudges("reload")
        return True

    async def resize_viewport(self, width: int, height: int) -> bool:
        next_width = clamp_dimension(width, self.width, 640, DISPLAY_WIDTH)
        next_height = clamp_dimension(height, self.height, 480, DISPLAY_HEIGHT)
        if next_width == self.width and next_height == self.height:
            return False

        self.width = next_width
        self.height = next_height
        nudge_browser_window_geometry(self.width, self.height)
        await self.send_cdp("Page.bringToFront")
        await self.send_cdp(
            "Emulation.setDeviceMetricsOverride",
            {
                "width": self.width,
                "height": self.height,
                "deviceScaleFactor": 1,
                "mobile": False,
                "screenWidth": DISPLAY_WIDTH,
                "screenHeight": DISPLAY_HEIGHT,
            },
        )
        try:
            await self.evaluate_cdp("window.dispatchEvent(new Event('resize'))")
        except Exception:
            pass
        try:
            self.last_page_state = dict(await self.get_page_state())
        except Exception:
            pass
        log("viewport-resize", f"{self.width}x{self.height}")
        return True

    async def nudge_first_paint(self) -> None:
        try:
            await self.send_cdp("Page.bringToFront")
            await self.ensure_fullscreen()
            focus_browser(force=True)
            await self.evaluate_cdp(
                """
(() => new Promise((resolve) => {
  const root = document.scrollingElement || document.documentElement || document.body;
  const repaint = () => {
    try {
      window.focus();
      if (document.body) {
        document.body.getBoundingClientRect();
      }
      if (root) {
        const currentX = Number(root.scrollLeft || 0);
        const currentY = Number(root.scrollTop || 0);
        root.scrollTo(currentX + 1, currentY + 1);
        root.scrollTo(currentX, currentY);
      }
      window.dispatchEvent(new Event("resize"));
      document.dispatchEvent(new Event("visibilitychange"));
    } catch (error) {
      // Ignore page-specific script errors. The nudge is best-effort only.
    }
    resolve(true);
  };
  requestAnimationFrame(() => requestAnimationFrame(repaint));
}))()
                """.strip(),
                await_promise=True,
            )
            center_x = max(1, self.width // 2)
            center_y = max(1, self.height // 2)
            await self.send_cdp(
                "Input.dispatchMouseEvent",
                {
                    "type": "mouseMoved",
                    "x": center_x,
                    "y": center_y,
                    "buttons": 0,
                },
            )
            try:
                pointer_x, pointer_y = get_xinput().get_pointer_position()
                pointer_x = max(1, min(self.width - 2, pointer_x))
                pointer_y = max(1, min(self.height - 2, pointer_y))
                get_xinput().move_pointer(pointer_x + 1, pointer_y + 1)
                get_xinput().move_pointer(pointer_x, pointer_y)
            except Exception:
                get_xinput().move_pointer(center_x, center_y)
            nudge_browser_window_geometry(self.width, self.height)
        except Exception as error:
            log("first-paint-nudge-failed", repr(error))

    async def dispatch_cdp_click(self, x: float, y: float) -> None:
        x = max(1.0, min(float(self.width - 2), float(x)))
        y = max(1.0, min(float(self.height - 2), float(y)))
        await self.send_cdp(
            "Input.dispatchMouseEvent",
            {
                "type": "mouseMoved",
                "x": x,
                "y": y,
                "button": "none",
                "buttons": 0,
            },
        )
        await self.send_cdp(
            "Input.dispatchMouseEvent",
            {
                "type": "mousePressed",
                "x": x,
                "y": y,
                "button": "left",
                "buttons": 1,
                "clickCount": 1,
            },
        )
        await self.send_cdp(
            "Input.dispatchMouseEvent",
            {
                "type": "mouseReleased",
                "x": x,
                "y": y,
                "button": "left",
                "buttons": 0,
                "clickCount": 1,
            },
        )

    async def dispatch_cdp_key(self, key: str, code: str, text: str = "") -> None:
        await self.send_cdp(
            "Input.dispatchKeyEvent",
            {
                "type": "keyDown",
                "key": key,
                "code": code,
                "text": text,
                "unmodifiedText": text,
            },
        )
        await self.send_cdp(
            "Input.dispatchKeyEvent",
            {
                "type": "keyUp",
                "key": key,
                "code": code,
            },
        )

    async def dispatch_x11_click(self, x: float, y: float) -> None:
        await focus_browser_async(force=True, wait=True)
        target_x = max(1, min(self.width - 2, int(round(x))))
        target_y = max(1, min(self.height - 2, int(round(y))))
        await asyncio.to_thread(get_xinput().move_pointer, target_x, target_y)
        await asyncio.to_thread(get_xinput().button, 1, True)
        await asyncio.sleep(0.03)
        await asyncio.to_thread(get_xinput().button, 1, False)

    async def dispatch_x11_key(self, key_name: str) -> bool:
        await focus_browser_async(force=True, wait=True)
        pressed = await asyncio.to_thread(get_xinput().key, key_name, True)
        await asyncio.sleep(0.03)
        released = await asyncio.to_thread(get_xinput().key, key_name, False)
        return bool(pressed and released)

    async def nudge_media_playback(self, reason: str = "") -> Dict[str, object]:
        try:
            result = await self.evaluate_cdp(
                """
(async () => {
  const href = String(window.location?.href || "");
  const host = String(window.location?.hostname || "").toLowerCase();
  const pathname = String(window.location?.pathname || "");
  const isYouTube =
    host === "youtube.com" ||
    host.endsWith(".youtube.com") ||
    host === "youtu.be";
  const isMediaSurface =
    host === "youtu.be" ||
    pathname === "/watch" ||
    pathname.startsWith("/watch") ||
    pathname.startsWith("/shorts");
  const summary = {
    href,
    isYouTube,
    isMediaSurface,
    mediaCount: 0,
    playAttempts: 0,
    lastPlayError: "",
    playerApi: false,
    unmuteClicks: 0,
    signInGate: false,
    playerState: null,
    playerCurrentTime: null,
    playerMuted: null,
    playerVolume: null,
    playerCenter: null,
    playButtonCenter: null,
    unmuteButtonCenter: null,
    mediaReadyState: 0,
    mediaCurrentTime: 0,
    mediaPaused: true,
    mediaMuted: false,
    needsGesture: false,
    needsUnmute: false,
  };

  const getPrimaryMediaElement = () => {
    const player = document.getElementById("movie_player");
    const playerVideo =
      player?.querySelector?.("video.html5-main-video") ||
      player?.querySelector?.("video") ||
      null;
    if (playerVideo instanceof HTMLMediaElement) {
      return playerVideo;
    }
    const visibleMedia = Array.from(document.querySelectorAll("video, audio"))
      .filter((element) => element instanceof HTMLMediaElement)
      .map((element) => {
        const rect = element.getBoundingClientRect?.();
        const area = rect ? Math.max(0, rect.width) * Math.max(0, rect.height) : 0;
        return { element, area };
      })
      .filter(({ area }) => area > 0);
    visibleMedia.sort((left, right) => right.area - left.area);
    return visibleMedia[0]?.element || null;
  };

  if (!isYouTube) {
    return summary;
  }

  const mediaNodes = Array.from(document.querySelectorAll("video, audio"));
  summary.mediaCount = mediaNodes.length;
  if (!isMediaSurface) {
    return summary;
  }

  const primaryMedia = getPrimaryMediaElement();
  for (const media of mediaNodes) {
    if (media === primaryMedia) {
      continue;
    }
    try {
      media.defaultMuted = true;
    } catch {}
    try {
      media.muted = true;
    } catch {}
    try {
      media.volume = 0;
    } catch {}
    try {
      media.pause();
    } catch {}
  }
  if (primaryMedia) {
    try {
      primaryMedia.defaultMuted = false;
    } catch {}
    try {
      primaryMedia.muted = false;
    } catch {}
    try {
      primaryMedia.volume = 1;
    } catch {}
    try {
      primaryMedia.autoplay = true;
    } catch {}
    try {
      primaryMedia.preload = "auto";
    } catch {}
    try {
      primaryMedia.playsInline = true;
    } catch {}
    try {
      const playPromise = primaryMedia.play();
      summary.playAttempts += 1;
      if (playPromise && typeof playPromise.then === "function") {
        await playPromise.catch((error) => {
          summary.lastPlayError = String(error?.message || error || "");
        });
      }
    } catch (error) {
      summary.lastPlayError = String(error?.message || error || "");
    }
  }

  const player = document.getElementById("movie_player");
  if (player) {
    summary.playerApi = true;
    try {
      if (typeof player.getPlayerState === "function") {
        summary.playerState = player.getPlayerState();
      }
    } catch {}
    try {
      if (typeof player.getCurrentTime === "function") {
        summary.playerCurrentTime = player.getCurrentTime();
      }
    } catch {}
    try {
      if (typeof player.isMuted === "function") {
        summary.playerMuted = Boolean(player.isMuted());
      }
    } catch {}
    try {
      if (typeof player.getVolume === "function") {
        summary.playerVolume = Number(player.getVolume());
      }
    } catch {}
    try {
      const rect = player.getBoundingClientRect();
      if (rect && rect.width > 0 && rect.height > 0) {
        summary.playerCenter = {
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
        };
      }
    } catch {}
    try {
      if (typeof player.unMute === "function") {
        player.unMute();
      }
    } catch {}
    try {
      if (typeof player.setVolume === "function") {
        player.setVolume(100);
      }
    } catch {}
    try {
      if (typeof player.playVideo === "function") {
        player.playVideo();
      }
    } catch {}
  }

  const playButton = document.querySelector(
    ".ytp-large-play-button, .ytp-play-button",
  );
  if (playButton instanceof HTMLElement) {
    try {
      const rect = playButton.getBoundingClientRect();
      if (rect && rect.width > 0 && rect.height > 0) {
        summary.playButtonCenter = {
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
        };
      }
      playButton.click();
    } catch {}
  }

  const unmuteButton = Array.from(
    document.querySelectorAll('button, [role="button"]'),
  ).find((element) => {
    const label = String(
      element.getAttribute("aria-label") ||
        element.getAttribute("title") ||
        element.textContent ||
        "",
    ).toLowerCase();
    return label.includes("unmute");
  });
  if (unmuteButton instanceof HTMLElement) {
    try {
      const rect = unmuteButton.getBoundingClientRect();
      if (rect && rect.width > 0 && rect.height > 0) {
        summary.unmuteButtonCenter = {
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
        };
      }
    } catch {}
    try {
      unmuteButton.click();
      summary.unmuteClicks += 1;
    } catch {}
  }

  const bodyText = String(document.body?.innerText || "").toLowerCase();
  summary.signInGate =
    /sign in to confirm you.?re not a bot/i.test(bodyText) ||
    bodyText.includes("this browser or app may not be secure") ||
    bodyText.includes("confirm you are not a bot");

  const mediaReadyState = primaryMedia ? Number(primaryMedia.readyState || 0) : 0;
  const mediaCurrentTime = primaryMedia ? Number(primaryMedia.currentTime || 0) : 0;
  const mediaPaused = primaryMedia ? Boolean(primaryMedia.paused) : true;
  const mediaMuted = primaryMedia
    ? Boolean(primaryMedia.muted) || Number(primaryMedia.volume || 0) <= 0
    : false;
  summary.mediaReadyState = mediaReadyState;
  summary.mediaCurrentTime = mediaCurrentTime;
  summary.mediaPaused = mediaPaused;
  summary.mediaMuted = mediaMuted;
  summary.needsGesture = Boolean(
    !summary.signInGate &&
      (
        summary.playerState === -1 ||
        summary.playerState === 5 ||
        (summary.playerState !== 1 && mediaCurrentTime < 0.75 && (mediaPaused || mediaReadyState <= 1))
      )
  );
  summary.needsUnmute = Boolean(
    !summary.signInGate &&
      (
        summary.playerMuted === true ||
        summary.playerVolume === 0 ||
        mediaMuted
      )
  );

  return summary;
})()
                """.strip(),
                await_promise=True,
                return_by_value=True,
                user_gesture=True,
            )
        except Exception as error:
            log("media-playback-nudge-failed", truncate_for_log(reason, 96), repr(error))
            return {}

        if isinstance(result, dict) and result.get("isYouTube"):
            log(
                "media-playback-nudge",
                truncate_for_log(reason, 96),
                f"mediaCount={result.get('mediaCount')}",
                f"playAttempts={result.get('playAttempts')}",
                f"playerApi={bool(result.get('playerApi'))}",
                f"playerState={result.get('playerState')}",
                f"playerCurrentTime={result.get('playerCurrentTime')}",
                f"playerMuted={result.get('playerMuted')}",
                f"playerVolume={result.get('playerVolume')}",
                f"mediaCurrentTime={result.get('mediaCurrentTime')}",
                f"mediaPaused={bool(result.get('mediaPaused'))}",
                f"mediaMuted={bool(result.get('mediaMuted'))}",
                f"needsGesture={bool(result.get('needsGesture'))}",
                f"needsUnmute={bool(result.get('needsUnmute'))}",
                f"signInGate={bool(result.get('signInGate'))}",
                f"unmuteClicks={result.get('unmuteClicks')}",
                f"playError={truncate_for_log(result.get('lastPlayError'), 120)}",
                f"url={truncate_for_log(result.get('href'), 160)}",
            )
            if result.get("needsGesture") and not result.get("signInGate"):
                try:
                    await self.send_cdp("Page.bringToFront")
                except Exception:
                    pass
                gesture_target = result.get("playButtonCenter") or result.get("playerCenter") or {}
                gesture_x = float(gesture_target.get("x") or max(1, self.width // 2))
                gesture_y = float(gesture_target.get("y") or max(1, self.height // 2))
                try:
                    if gesture_target:
                        await self.dispatch_x11_click(gesture_x, gesture_y)
                        await asyncio.sleep(0.12)
                    await self.dispatch_x11_key("k")
                    log(
                        "media-playback-gesture",
                        truncate_for_log(reason, 96),
                        f"x={round(gesture_x, 1)}",
                        f"y={round(gesture_y, 1)}",
                    )
                except Exception as error:
                    log(
                        "media-playback-gesture-failed",
                        truncate_for_log(reason, 96),
                        repr(error),
                    )
            if result.get("needsUnmute") and not result.get("signInGate"):
                try:
                    unmute_target = result.get("unmuteButtonCenter") or {}
                    if unmute_target:
                        await self.dispatch_x11_click(
                            float(unmute_target.get("x") or max(1, self.width // 2)),
                            float(unmute_target.get("y") or max(1, self.height // 2)),
                        )
                    elif result.get("playerMuted") is True or float(result.get("playerVolume") or 0) <= 0:
                        await self.dispatch_x11_key("m")
                    log(
                        "media-playback-unmute",
                        truncate_for_log(reason, 96),
                        f"button={bool(unmute_target)}",
                        f"playerMuted={result.get('playerMuted')}",
                        f"playerVolume={result.get('playerVolume')}",
                        f"mediaMuted={bool(result.get('mediaMuted'))}",
                    )
                except Exception as error:
                    log(
                        "media-playback-unmute-failed",
                        truncate_for_log(reason, 96),
                        repr(error),
                    )
        return result if isinstance(result, dict) else {}

    async def pause_media_playback(self, reason: str = "") -> Dict[str, object]:
        try:
            result = await self.evaluate_cdp(
                """
(() => {
  const mediaElements = Array.from(document.querySelectorAll("video, audio"));
  let pausedElements = 0;
  let mutedElements = 0;
  for (const element of mediaElements) {
    try {
      element.pause();
      pausedElements += 1;
    } catch {}
    try {
      if (!element.muted) {
        element.muted = true;
      }
      element.volume = 0;
      mutedElements += 1;
    } catch {}
  }

  let playerApi = false;
  let playerPaused = false;
  try {
    const player = window.ytplayer?.player_ || window.movie_player || document.getElementById("movie_player");
    if (player) {
      playerApi = true;
      try {
        if (typeof player.pauseVideo === "function") {
          player.pauseVideo();
          playerPaused = true;
        }
      } catch {}
      try {
        if (typeof player.mute === "function") {
          player.mute();
        }
      } catch {}
      try {
        if (typeof player.setVolume === "function") {
          player.setVolume(0);
        }
      } catch {}
    }
  } catch {}

  const miniPlayer = document.querySelector(
    ".ytd-miniplayer button[aria-label*='Close'], .ytp-miniplayer-close-button, button.ytp-miniplayer-close-button"
  );
  if (miniPlayer instanceof HTMLElement) {
    try {
      miniPlayer.click();
    } catch {}
  }

  return {
    href: String(location.href || ""),
    mediaCount: mediaElements.length,
    pausedElements,
    mutedElements,
    playerApi,
    playerPaused,
  };
})()
                """.strip(),
                await_promise=True,
                return_by_value=True,
                user_gesture=True,
            )
        except Exception as error:
            log("media-playback-pause-failed", truncate_for_log(reason, 96), repr(error))
            return {}

        if isinstance(result, dict):
            log(
                "media-playback-paused",
                truncate_for_log(reason, 96),
                f"mediaCount={result.get('mediaCount')}",
                f"pausedElements={result.get('pausedElements')}",
                f"mutedElements={result.get('mutedElements')}",
                f"playerApi={bool(result.get('playerApi'))}",
                f"playerPaused={bool(result.get('playerPaused'))}",
                f"url={truncate_for_log(result.get('href'), 160)}",
            )
        return result if isinstance(result, dict) else {}

    def schedule_media_playback_nudges(self, reason: str = "") -> None:
        for task in self.media_playback_tasks:
            task.cancel()
        self.media_playback_tasks.clear()

        current_url = str(self.last_page_state.get("href") or "")
        if not is_probable_media_page(current_url):
            return

        async def run_once(delay_sec: float) -> None:
            try:
                if delay_sec > 0:
                    await asyncio.sleep(delay_sec)
                await self.nudge_media_playback(f"{reason}:{delay_sec:.1f}s")
            except asyncio.CancelledError:
                return

        for delay_sec in (0.0, 0.25, 0.75, 1.5, 3.0, 5.0, 8.0, 12.0, 18.0, 25.0):
            self.media_playback_tasks.append(asyncio.create_task(run_once(delay_sec)))

    async def ensure_fullscreen(self) -> None:
        if self.cdp_target_id is None:
            return

        try:
            target_window = await self.send_cdp(
                "Browser.getWindowForTarget",
                {"targetId": self.cdp_target_id},
            )
            window_id = target_window.get("windowId")
            if not window_id:
                return

            await self.send_cdp(
                "Browser.setWindowBounds",
                {
                    "windowId": window_id,
                    "bounds": {
                        "windowState": "fullscreen",
                    },
                },
            )
        except Exception as error:
            log("window-fullscreen-failed", repr(error))

    async def ensure_started(self, start_url: str = START_URL) -> None:
        if self.process and self.process.poll() is None and self.cdp_ws is not None:
            return

        await self.stop()
        log_runtime_metadata_once()
        self.profile_dir = self.create_profile_dir()

        args = [
            CHROMIUM_BIN,
            f"--user-data-dir={self.profile_dir}",
            "--no-first-run",
            "--no-default-browser-check",
            "--test-type",
            "--disable-sync",
            "--disable-features=Translate,MediaRouter",
            "--disable-blink-features=AutomationControlled",
            "--disable-gpu",
            "--autoplay-policy=no-user-gesture-required",
            "--lang=en-US",
            "--kiosk",
            "--window-position=0,0",
            f"--window-size={self.width},{self.height}",
            "--start-fullscreen",
            f"--remote-debugging-port={REMOTE_DEBUGGING_PORT}",
            "--remote-debugging-address=127.0.0.1",
            start_url,
        ]
        if not CHROMIUM_USE_DEV_SHM:
            args.append("--disable-dev-shm-usage")
        if DISABLE_CHROMIUM_SANDBOX:
            args.append("--no-sandbox")

        log(
            "chromium-launch",
            f"target={truncate_for_log(start_url)}",
            f"useDevShm={CHROMIUM_USE_DEV_SHM}",
            f"profile={truncate_for_log(self.profile_dir, 64)}",
        )

        self.process = subprocess.Popen(
            args,
            env=DISPLAY_ENV,
            stdout=subprocess.DEVNULL,
            stderr=None,
            start_new_session=True,
        )

        await self._connect_cdp()
        await self.ensure_fullscreen()
        window_id = await wait_for_browser_window(timeout=5.0)
        if window_id:
            run_cmd("xdotool", "windowmove", window_id, "0", "0")
            run_cmd("xdotool", "windowsize", window_id, str(self.width), str(self.height))
            focus_browser(force=True, wait=True)
        else:
            print("warning: Chromium DevTools is ready but no visible X11 window was detected yet", flush=True)

    async def _navigate_once(self, target_url: str) -> Dict[str, object]:
        await self.ensure_started()
        await self.send_cdp("Page.bringToFront")
        navigate_result = await self.send_cdp("Page.navigate", {"url": target_url})
        error_text = str(navigate_result.get("errorText") or "").strip()
        if error_text:
            raise RuntimeError(f"Chromium navigation failed: {error_text}")
        await self.ensure_fullscreen()
        window_id = find_browser_window()
        if window_id:
            run_cmd("xdotool", "windowmove", window_id, "0", "0")
            run_cmd("xdotool", "windowsize", window_id, str(self.width), str(self.height))
        focus_browser(force=True)
        ready_state = await self.wait_for_document_ready()
        await self.nudge_first_paint()
        await asyncio.sleep(0.35)
        await self.nudge_first_paint()
        page_state = await self.wait_for_page_commit()
        self.last_page_state = dict(page_state)
        if not is_probable_media_page(page_state.get("href")):
            await self.pause_media_playback("navigate:landed")
        self.schedule_media_playback_nudges("navigate")
        href = str(page_state.get("href") or "")
        if is_blank_or_error_url(href):
            raise RuntimeError(
                "Chromium navigation did not commit a visible page: "
                f"url={href or '<empty>'} readyState={page_state.get('readyState') or ready_state}"
            )
        log(
            "navigation-committed",
            f"url={truncate_for_log(href)}",
            f"title={truncate_for_log(page_state.get('title'))}",
            f"readyState={page_state.get('readyState') or ready_state}",
            f"bodyTextLength={page_state.get('bodyTextLength')}",
            f"bodyHtmlLength={page_state.get('bodyHtmlLength')}",
        )
        return page_state

    async def navigate(self, target_url: str) -> None:
        last_error: Optional[Exception] = None
        for attempt in range(1, NAVIGATION_MAX_ATTEMPTS + 1):
            try:
                await self._navigate_once(target_url)
                return
            except Exception as error:
                last_error = error
                log(
                    "navigation-attempt-failed",
                    f"attempt={attempt}/{NAVIGATION_MAX_ATTEMPTS}",
                    f"target={truncate_for_log(target_url)}",
                    repr(error),
                )
                if attempt >= NAVIGATION_MAX_ATTEMPTS:
                    break
                await self.stop()
                await asyncio.sleep(0.25)
        raise last_error or RuntimeError("Chromium navigation failed")

    async def heal_visible_pipeline(self, reason: str) -> None:
        try:
            await self.send_cdp("Page.bringToFront")
        except Exception as error:
            log("pipeline-heal-bring-to-front-failed", repr(error))
        try:
            await self.ensure_fullscreen()
        except Exception as error:
            log("pipeline-heal-fullscreen-failed", repr(error))
        try:
            focus_browser(force=True, wait=True)
        except Exception as error:
            log("pipeline-heal-focus-failed", repr(error))
        try:
            await self.nudge_first_paint()
            log("pipeline-heal", truncate_for_log(reason, 160))
        except Exception as error:
            log("pipeline-heal-nudge-failed", repr(error))


class CDPScreenshotTrack(MediaStreamTrack):
    kind = "video"
    capture_backend = "cdp-screenshot"

    def __init__(
        self,
        browser: ChromiumController,
        desktop_width: int,
        desktop_height: int,
        *,
        framerate: int = CAPTURE_FRAMERATE,
    ):
        super().__init__()
        self.browser = browser
        self.desktop_width = desktop_width
        self.desktop_height = desktop_height
        self.framerate = max(1, int(framerate))
        self.frame_interval_sec = 1 / self.framerate
        self.source_frames = 0
        self.source_started_at = 0.0
        self.last_source_frame_at = 0.0
        self.last_source_gap_ms = 0.0
        self.max_source_gap_ms = 0.0
        self.large_gap_count = 0
        self.recv_errors = 0
        self.last_error = ""
        self.last_error_at = 0.0
        self.next_pts = 0
        self.time_base = Fraction(1, self.framerate)
        self.next_frame_due_at = 0.0

    async def prime(self) -> None:
        await self._capture_frame()

    async def _capture_frame(self) -> VideoFrame:
        now = time.monotonic()
        if self.next_frame_due_at:
            delay = self.next_frame_due_at - now
            if delay > 0:
                await asyncio.sleep(delay)

        try:
            payload = await self.browser.capture_screenshot_bytes()
            with Image.open(io.BytesIO(payload)) as image:
                frame = VideoFrame.from_image(image.convert("RGB"))
        except Exception as error:
            self.recv_errors += 1
            self.last_error = repr(error)
            self.last_error_at = time.monotonic()
            raise MediaStreamError from error

        captured_at = time.monotonic()
        if not self.source_started_at:
            self.source_started_at = captured_at
        if self.last_source_frame_at:
            gap_ms = (captured_at - self.last_source_frame_at) * 1000
            self.last_source_gap_ms = gap_ms
            self.max_source_gap_ms = max(self.max_source_gap_ms, gap_ms)
            if gap_ms > ((1000 / max(1, self.framerate)) * 2.5):
                self.large_gap_count += 1
        self.last_source_frame_at = captured_at
        self.source_frames += 1
        self.next_frame_due_at = captured_at + self.frame_interval_sec
        return frame

    def snapshot_source_stats(self) -> Dict[str, object]:
        return {
            "sourceFrames": self.source_frames,
            "sourceStartedAt": self.source_started_at,
            "lastSourceFrameAt": self.last_source_frame_at,
            "lastSourceGapMs": self.last_source_gap_ms,
            "maxSourceGapMs": self.max_source_gap_ms,
            "largeGapCount": self.large_gap_count,
            "recvErrors": self.recv_errors,
            "lastError": self.last_error,
        }

    async def recv(self) -> VideoFrame:
        frame = await self._capture_frame()
        frame.pts = self.next_pts
        frame.time_base = self.time_base
        self.next_pts += 1
        return frame


class MediaRelayStateBridge:
    def __init__(self, runtime):
        self.runtime = runtime
        self.websocket = None
        self.last_connected_at = 0.0
        self.last_error = ""

    @property
    def session_id(self) -> str:
        return self.runtime.session_id

    @property
    def relay_url(self) -> str:
        return self.runtime.media_relay_url

    @property
    def connect_host(self) -> str:
        return self.runtime.media_relay_connect_host

    def _relay_host_for_log(self) -> str:
        try:
            parsed = urllib.parse.urlparse(self.relay_url)
            return parsed.netloc or parsed.path or "<unknown>"
        except Exception:
            return "<invalid>"

    def _is_configured(self) -> bool:
        parsed = urllib.parse.urlparse(self.relay_url)
        return parsed.scheme in {"ws", "wss"} and bool(parsed.netloc)

    async def send_json(self, message: Dict) -> None:
        if self.websocket is None:
            return
        try:
            await self.websocket.send(json.dumps(message))
        except ConnectionClosed:
            self.websocket = None

    async def publish_state(self, reason: str) -> None:
        await self.send_json(
            {
                "type": "worker-media-relay-state",
                "sessionId": self.session_id,
                "reason": str(reason or ""),
                "state": self.runtime.build_media_relay_state(),
            }
        )

    async def heartbeat_loop(self) -> None:
        while not SHUTDOWN.is_set():
            await asyncio.sleep(SIGNALING_HEARTBEAT_INTERVAL)
            await self.send_json(
                {
                    "type": "worker-media-relay-heartbeat",
                    "sessionId": self.session_id,
                    "role": "worker",
                    "ts": int(asyncio.get_running_loop().time() * 1000),
                }
            )

    async def state_loop(self) -> None:
        while not SHUTDOWN.is_set():
            await asyncio.sleep(MEDIA_RELAY_STATE_INTERVAL_SEC)
            await self.publish_state("interval")

    async def recv_loop(self) -> None:
        assert self.websocket is not None
        async for raw in self.websocket:
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                log(self.session_id, "media-relay-invalid-json")
                continue

            message_type = str(message.get("type") or "")
            if message_type in {"ping", "heartbeat", "media-relay-ping"}:
                await self.send_json(
                    {
                        "type": "worker-media-relay-pong",
                        "sessionId": self.session_id,
                    }
                )
                continue

            if message_type in {"state-request", "worker-state-request", "media-relay-state-request"}:
                await self.publish_state("request")
                continue

            if message_type in {
                "media-relay-start",
                "pixel-media-relay-start",
                "pixel-relay-start",
                "sdp-offer",
                "ice-candidate",
            }:
                # TODO(gateway-media-relay): implement pixel media relay only after
                # the relay protocol defines frame encoding, timing, backpressure,
                # auth, and input semantics. Until then this sidecar must not
                # mutate WebRTC SDP/ICE or consume the active aiortc media tracks.
                await self.send_json(
                    {
                        "type": "worker-media-relay-unsupported",
                        "sessionId": self.session_id,
                        "requestType": message_type,
                        "reason": "pixel media relay is not implemented in the worker; WebRTC signaling remains authoritative",
                        "capabilities": self.runtime.media_relay_capabilities(),
                    }
                )
                log(self.session_id, "media-relay-unsupported", message_type)
                continue

            log(self.session_id, "media-relay-ignored", truncate_for_log(message_type, 96))

    async def connect_once(self) -> None:
        async with websockets.connect(
            self.relay_url,
            max_size=1024 * 1024,
            ping_interval=None,
            **build_websocket_connect_kwargs(self.connect_host, self.relay_url),
        ) as websocket:
            self.websocket = websocket
            self.last_connected_at = time.monotonic()
            self.last_error = ""
            log(
                self.session_id,
                "media-relay-connected",
                self._relay_host_for_log(),
                f"via={self.connect_host or 'dns'}",
            )
            await self.send_json(
                {
                    "type": "worker-media-relay-register",
                    "role": "worker",
                    "sessionId": self.session_id,
                    "capabilities": self.runtime.media_relay_capabilities(),
                    "state": self.runtime.build_media_relay_state(),
                }
            )

            heartbeat_task = asyncio.create_task(self.heartbeat_loop())
            state_task = asyncio.create_task(self.state_loop())
            try:
                await self.recv_loop()
            finally:
                heartbeat_task.cancel()
                state_task.cancel()
                await asyncio.gather(heartbeat_task, state_task, return_exceptions=True)
                self.websocket = None

    async def run(self) -> None:
        if not self.relay_url:
            return
        if not self._is_configured():
            log(
                self.session_id,
                "media-relay-disabled",
                f"invalidUrl={truncate_for_log(self.relay_url, 160)}",
            )
            return

        while not SHUTDOWN.is_set():
            try:
                await self.connect_once()
            except asyncio.CancelledError:
                raise
            except Exception as error:
                self.last_error = repr(error)
                log(
                    self.session_id,
                    "media-relay-reconnect",
                    self._relay_host_for_log(),
                    repr(error),
                )
                await asyncio.sleep(MEDIA_RELAY_RECONNECT_DELAY_SEC)

    async def close(self) -> None:
        if self.websocket is not None:
            try:
                await self.websocket.close()
            except Exception:
                pass
            self.websocket = None


class SessionRuntime:
    def __init__(self, assignment: Dict, browser: ChromiumController):
        self.session_id = assignment["sessionId"]
        self.target_url = assignment["targetUrl"]
        self.signaling_url = assignment["signalingUrl"]
        self.signaling_connect_host = assignment.get("signalingConnectHost", "")
        transport_config = assignment.get("transport") or {}
        bridge_config = assignment.get("workerBridge") or {}
        self.media_relay_url = str(
            assignment.get("mediaRelayUrl")
            or bridge_config.get("mediaRelayUrl")
            or transport_config.get("mediaRelayUrl")
            or MEDIA_RELAY_URL
            or ""
        ).strip()
        self.media_relay_connect_host = str(
            assignment.get("mediaRelayConnectHost")
            or bridge_config.get("mediaRelayConnectHost")
            or transport_config.get("mediaRelayConnectHost")
            or MEDIA_RELAY_CONNECT_HOST
            or ""
        ).strip()
        media_termination_config = transport_config.get("mediaTermination") or {}
        self.media_gateway_url = str(
            assignment.get("mediaGatewayUrl")
            or bridge_config.get("mediaGatewayUrl")
            or bridge_config.get("mediaGatewayURL")
            or transport_config.get("mediaGatewayUrl")
            or transport_config.get("mediaGatewayURL")
            or MEDIA_GATEWAY_URL
            or ""
        ).strip()
        self.media_plane_mode = str(
            assignment.get("mediaPlaneMode")
            or bridge_config.get("mediaPlaneMode")
            or transport_config.get("mediaPlaneMode")
            or media_termination_config.get("mediaPlaneMode")
            or MEDIA_PLANE_MODE
            or ""
        ).strip().lower()
        self.media_relay_protocol = str(
            assignment.get("mediaRelayProtocol")
            or bridge_config.get("protocol")
            or transport_config.get("protocol")
            or media_termination_config.get("protocol")
            or MEDIA_RELAY_PROTOCOL
            or ""
        ).strip().lower()
        self.input_pointer_channel_name = str(
            assignment.get("inputPointerName")
            or bridge_config.get("inputPointerName")
            or transport_config.get("inputPointerName")
            or INPUT_POINTER_CHANNEL_NAME
        ).strip() or INPUT_POINTER_CHANNEL_NAME
        self.input_control_channel_name = str(
            assignment.get("inputControlName")
            or bridge_config.get("inputControlName")
            or transport_config.get("inputControlName")
            or INPUT_CONTROL_CHANNEL_NAME
        ).strip() or INPUT_CONTROL_CHANNEL_NAME
        self.gateway_offer_url = build_media_gateway_offer_url(self.media_gateway_url)
        self.gateway_webrtc_relay_enabled = is_gateway_webrtc_relay_config(
            self.media_gateway_url,
            self.media_plane_mode,
            self.media_relay_protocol,
        )
        self.video_codec_preferences = (
            gateway_video_codec_preferences(VIDEO_CODEC_PREFERENCES)
            if self.gateway_webrtc_relay_enabled
            else VIDEO_CODEC_PREFERENCES
        )
        self.worker_token = assignment["workerToken"]
        self.display_width = int(assignment.get("displayWidth", DISPLAY_WIDTH))
        self.display_height = int(assignment.get("displayHeight", DISPLAY_HEIGHT))
        self.turn_username = assignment.get("turnUsername", "")
        self.turn_password = assignment.get("turnPassword", "")
        self.ice_urls = [item for item in assignment.get("workerIceUrls", []) if item]
        self.allowed_candidate_types = {
            item.strip().lower()
            for item in assignment.get("allowedCandidateTypes", [])
            if item
        }
        self.audio_startup_sync_experiment = bool(
            (assignment.get("experiments") or {}).get("audioStartupSync", False)
        )
        requested_source_coupled_av = bool(
            (assignment.get("experiments") or {}).get("sourceCoupledAv", True)
        )
        self.source_coupled_av_experiment = bool(
            EXPERIMENTAL_SOURCE_COUPLED_AV
            and requested_source_coupled_av
        )
        log(
            assignment["sessionId"],
            "session-experiments",
            f"assignmentAudioStartupSync={bool((assignment.get('experiments') or {}).get('audioStartupSync', False))}",
            f"assignmentSourceCoupledAv={requested_source_coupled_av}",
            f"envSourceCoupledAv={EXPERIMENTAL_SOURCE_COUPLED_AV}",
            f"effectiveSourceCoupledAv={self.source_coupled_av_experiment}",
        )
        log(
            assignment["sessionId"],
            "gateway-webrtc-config",
            f"enabled={self.gateway_webrtc_relay_enabled}",
            f"mediaPlaneMode={self.media_plane_mode or '<empty>'}",
            f"protocol={self.media_relay_protocol or '<empty>'}",
            f"offerUrl={truncate_for_log(self.gateway_offer_url, 160) or '<empty>'}",
            f"videoCodecPreferences={','.join(self.video_codec_preferences)}",
        )
        self.browser = browser
        self.browser.width = clamp_dimension(
            self.display_width,
            DISPLAY_WIDTH,
            640,
            DISPLAY_WIDTH,
        )
        self.browser.height = clamp_dimension(
            self.display_height,
            DISPLAY_HEIGHT,
            480,
            DISPLAY_HEIGHT,
        )
        self.pc: Optional[RTCPeerConnection] = None
        self.ws = None
        self.media_relay_bridge: Optional[MediaRelayStateBridge] = None
        self.media_relay_task: Optional[asyncio.Task] = None
        self.last_connection_state = "new"
        self.last_ice_connection_state = "new"
        self.last_ice_gathering_state = "new"
        self.last_signaling_state = "stable"
        self.video_player = None
        self.source_coupled_capture: Optional[SourceCoupledAVCapture] = None
        self.video_track: Optional[MediaStreamTrack] = None
        self.video_transceiver = None
        self.audio_track: Optional[MediaStreamTrack] = None
        self.audio_sender = None
        self.media_sync = MediaSyncController(
            AUDIO_SYNC_DELAY_MS,
            EXPERIMENTAL_AUDIO_SYNC_MAX_DELAY_MS
            if self.audio_startup_sync_experiment
            else 200,
        )
        self.heartbeat_task: Optional[asyncio.Task] = None
        self.post_connect_kick_task: Optional[asyncio.Task] = None
        self.video_sender_tuning_task: Optional[asyncio.Task] = None
        self.media_diagnostics_task: Optional[asyncio.Task] = None
        self.page_state_task: Optional[asyncio.Task] = None
        self.last_emitted_page_state_signature = ""
        self.video_sender_tuned = False
        self.pending_offer_reason: Optional[str] = None
        self.offer_lock = asyncio.Lock()
        self.ice_gathering_complete = asyncio.Event()
        self.capture_recovery_lock = asyncio.Lock()
        self.capture_recovery_attempts = 0
        self.last_capture_recovery_at = 0.0
        self.previous_outbound_video_stats = None
        self.last_peer_stats = None
        self.hybrid_dom_requests = 0
        self.hybrid_dom_snapshot_lock = asyncio.Lock()
        self.hybrid_dom_snapshot_cache: Optional[Dict[str, object]] = None
        self.hybrid_dom_snapshot_cached_at = 0.0
        self.hybrid_dom_snapshot_task: Optional[asyncio.Task] = None
        self.input_channels: List[object] = []
        self.input_message_queue = asyncio.Queue()
        self.input_processor_task: Optional[asyncio.Task] = None
        self.input_ack_queue: List[Dict[str, object]] = []
        self.input_ack_timer_task: Optional[asyncio.Task] = None
        self.input_ack_flush_task: Optional[asyncio.Task] = None
        self.input_ack_lock = asyncio.Lock()
        self.input_ack_sequence = 0
        self.input_ack_total_queued = 0
        self.input_ack_total_sent = 0
        self.last_input_ack_queued_at = 0
        self.last_input_ack_sent_at = 0
        self.last_input_ack_worker_seq = 0
        self.last_input_ack_viewer_ts = None
        self.last_input_ack_receive_ts = 0
        self.last_input_ack_apply_ts = 0
        self.last_input_ack_channel = ""
        self.current_video_target_bitrate_bps = VIDEO_START_BITRATE_BPS
        self.last_applied_video_target_bitrate_bps = None
        self.current_video_target_framerate = CAPTURE_FRAMERATE
        self.interaction_mode = "idle"
        self.interaction_active_until = 0.0
        self.last_interaction_input_at_ms = 0
        self.interaction_restore_task: Optional[asyncio.Task] = None

    async def send_json(self, message: Dict) -> None:
        if self.ws is not None:
            try:
                log(self.session_id, "send", message.get("type"))
                await self.ws.send(json.dumps(message))
            except ConnectionClosed:
                self.ws = None

    async def send_worker_state(self, state: str, reason: str = "", refresh_page: bool = False) -> None:
        if refresh_page:
            try:
                await self.browser.get_page_state()
            except Exception as error:
                log(
                    self.session_id,
                    "worker-state-page-refresh-failed",
                    truncate_for_log(str(error) or repr(error), 160),
                )
        page_state = self.browser.last_page_state or {}
        self.last_emitted_page_state_signature = "|".join(
            [
                str(page_state.get("href") or ""),
                str(page_state.get("title") or ""),
                str(page_state.get("readyState") or ""),
            ]
        )
        await self.send_json(
            {
                "type": "worker-state",
                "sessionId": self.session_id,
                "state": state,
                "reason": reason,
                "page": {
                    "href": str(page_state.get("href") or ""),
                    "title": str(page_state.get("title") or ""),
                    "readyState": str(page_state.get("readyState") or ""),
                },
                "display": {
                    "width": self.display_width,
                    "height": self.display_height,
                },
            }
        )

    async def page_state_loop(self) -> None:
        while not SHUTDOWN.is_set():
            await asyncio.sleep(PAGE_STATE_SYNC_INTERVAL_SEC)
            if self.ws is None:
                return
            try:
                page_state = await self.browser.get_page_state()
            except Exception:
                continue
            signature = "|".join(
                [
                    str(page_state.get("href") or ""),
                    str(page_state.get("title") or ""),
                    str(page_state.get("readyState") or ""),
                ]
            )
            if signature == self.last_emitted_page_state_signature:
                continue
            self.last_emitted_page_state_signature = signature
            await self.send_worker_state(
                "streaming" if self.last_connection_state == "connected" else "ready",
                "page-state-change",
                refresh_page=False,
            )

    def input_data_channel_labels(self):
        return {"input", self.input_pointer_channel_name, self.input_control_channel_name}

    def input_channel_create_order(self):
        if self.gateway_webrtc_relay_enabled:
            return (self.input_pointer_channel_name, self.input_control_channel_name)
        return (self.input_pointer_channel_name, self.input_control_channel_name, "input")

    def input_ack_channel_priority(self):
        return (self.input_control_channel_name, "input", self.input_pointer_channel_name)

    def register_input_channel(self, channel, created_by: str) -> None:
        label = data_channel_label(channel)
        if label not in self.input_data_channel_labels():
            log(
                self.session_id,
                "input-channel-ignored",
                f"label={truncate_for_log(label or '<empty>', 64)}",
                f"createdBy={created_by}",
            )
            return
        if channel in self.input_channels:
            return

        self.input_channels.append(channel)
        log(self.session_id, "input-channel-registered", f"label={label}", f"createdBy={created_by}")

        @channel.on("open")
        def on_open():
            log(self.session_id, "input-channel-open", f"label={label}")
            self.schedule_input_ack_flush(0.0)

        @channel.on("close")
        def on_close():
            if channel in self.input_channels:
                self.input_channels.remove(channel)
            log(self.session_id, "input-channel-closed", f"label={label}")

        @channel.on("message")
        def on_message(message):
            self.receive_input_channel_message(channel, message)

    def receive_input_channel_message(self, channel, raw_message) -> None:
        received_at = current_time_ms()
        try:
            if isinstance(raw_message, bytes):
                raw_message = raw_message.decode("utf-8")
            payload = json.loads(raw_message)
            if not isinstance(payload, dict):
                return
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError):
            return

        self.input_message_queue.put_nowait((payload, channel, received_at))
        self.ensure_input_processor()

    def ensure_input_processor(self) -> None:
        if self.input_processor_task is None or self.input_processor_task.done():
            self.input_processor_task = asyncio.create_task(
                self.process_input_messages(),
                name=f"input-processor:{self.session_id}",
            )

    async def process_input_messages(self) -> None:
        while True:
            payload, channel, received_at = await self.input_message_queue.get()
            try:
                await self.apply_input_message(payload, channel, received_at)
            finally:
                self.input_message_queue.task_done()

    def handle_interaction_mode_message(self, message: Dict) -> bool:
        msg_type = str(message.get("type") or "")
        if msg_type not in {"interaction-mode", "interaction.mode", "interaction.mode.set"}:
            return False

        next_mode = str(
            message.get("mode")
            or message.get("interactionMode")
            or message.get("value")
            or "default"
        ).strip()
        self.interaction_mode = next_mode or "default"
        log(
            self.session_id,
            "interaction-mode",
            truncate_for_log(self.interaction_mode, 80),
        )
        if self.interaction_mode in {"interaction", "active"}:
            self.interaction_mode = "interaction"
            self.interaction_active_until = time.monotonic() + INTERACTION_MODE_HOLD_SEC
            self.set_video_media_targets(
                INTERACTION_CAPTURE_FRAMERATE,
                INTERACTION_VIDEO_TARGET_BITRATE_BPS,
                "viewer-interaction-mode",
            )
            self.ensure_interaction_restore_task()
        else:
            self.interaction_active_until = 0.0
            self.set_video_media_targets(
                CAPTURE_FRAMERATE,
                VIDEO_START_BITRATE_BPS,
                "viewer-interaction-mode",
            )
        return True

    async def apply_viewport_resize_message(self, message: Dict) -> bool:
        width = clamp_dimension(
            message.get("width", self.display_width),
            self.display_width,
            MIN_STREAM_WIDTH,
            DISPLAY_WIDTH,
        )
        height = clamp_dimension(
            message.get("height", self.display_height),
            self.display_height,
            MIN_STREAM_HEIGHT,
            DISPLAY_HEIGHT,
        )
        changed = width != self.display_width or height != self.display_height
        self.display_width = width
        self.display_height = height
        self.browser.width = width
        self.browser.height = height
        if self.video_track is not None:
            for attribute_name, value in (
                ("desktop_width", width),
                ("desktop_height", height),
                ("display_width", width),
                ("display_height", height),
            ):
                if hasattr(self.video_track, attribute_name):
                    setattr(self.video_track, attribute_name, value)
            self.video_track.set_target_size(width, height)
        try:
            await self.browser.resize_viewport(width, height)
        finally:
            if changed:
                self.publish_media_relay_state("viewport-resize")
            await self.send_worker_state(
                "streaming" if self.last_connection_state == "connected" else "ready",
                "viewport-resize",
                refresh_page=True,
            )
        return True

    def set_video_track_framerate(self, framerate: int, reason: str) -> None:
        self.current_video_target_framerate = max(1, min(CAPTURE_FRAMERATE, int(framerate)))
        if self.video_track is None or not hasattr(self.video_track, "set_output_framerate"):
            return
        try:
            changed = self.video_track.set_output_framerate(self.current_video_target_framerate)
        except Exception as error:
            log(self.session_id, "video-framerate-target-failed", reason, repr(error))
            return
        if changed:
            log(
                self.session_id,
                "video-framerate-target",
                f"reason={reason}",
                f"fps={self.current_video_target_framerate}",
            )

    def apply_video_sender_target_bitrate(self, bitrate_bps: int, reason: str) -> bool:
        target_bps = max(VIDEO_MIN_BITRATE_BPS, min(VIDEO_MAX_BITRATE_BPS, int(bitrate_bps)))
        self.current_video_target_bitrate_bps = target_bps
        if self.video_transceiver is None:
            return False
        sender = self.video_transceiver.sender
        encoder = getattr(sender, "_RTCRtpSender__encoder", None)
        if encoder is None or not hasattr(encoder, "target_bitrate"):
            return False
        try:
            encoder.target_bitrate = target_bps
            if self.last_applied_video_target_bitrate_bps != target_bps:
                log(
                    self.session_id,
                    "video-sender-target-bitrate",
                    f"reason={reason}",
                    f"target={target_bps}",
                    f"max={VIDEO_MAX_BITRATE_BPS}",
                )
            self.last_applied_video_target_bitrate_bps = target_bps
            self.video_sender_tuned = True
            return True
        except Exception as error:
            log(self.session_id, "video-sender-target-bitrate-failed", reason, repr(error))
            return False

    def set_video_media_targets(self, framerate: int, bitrate_bps: int, reason: str) -> None:
        self.set_video_track_framerate(framerate, reason)
        applied = self.apply_video_sender_target_bitrate(bitrate_bps, reason)
        if not applied and self.pc is not None and self.pc.connectionState == "connected":
            if self.video_sender_tuning_task is None or self.video_sender_tuning_task.done():
                self.video_sender_tuning_task = asyncio.create_task(
                    self.tune_video_sender(reason),
                    name=f"video-sender-tune:{self.session_id}",
                )

    def ensure_interaction_restore_task(self) -> None:
        if INTERACTION_MODE_HOLD_SEC <= 0:
            return
        if self.interaction_restore_task is not None and not self.interaction_restore_task.done():
            return
        self.interaction_restore_task = asyncio.create_task(
            self.restore_interaction_mode_after_idle(),
            name=f"interaction-restore:{self.session_id}",
        )

    async def restore_interaction_mode_after_idle(self) -> None:
        try:
            while not SHUTDOWN.is_set():
                delay_sec = self.interaction_active_until - time.monotonic()
                if delay_sec <= 0:
                    break
                await asyncio.sleep(min(delay_sec, 0.25))
            if self.interaction_mode in {"interaction", "active"}:
                self.interaction_mode = "idle"
                self.set_video_media_targets(
                    CAPTURE_FRAMERATE,
                    VIDEO_START_BITRATE_BPS,
                    "interaction-idle-restore",
                )
                log(
                    self.session_id,
                    "interaction-mode",
                    "idle",
                    f"targetFps={CAPTURE_FRAMERATE}",
                    f"targetBitrate={VIDEO_START_BITRATE_BPS}",
                )
                self.publish_media_relay_state("interaction-idle-restore")
        finally:
            self.interaction_restore_task = None

    async def note_interaction_activity(self, message: Dict) -> None:
        if INTERACTION_MODE_HOLD_SEC <= 0:
            return
        now = time.monotonic()
        now_ms = current_time_ms()
        self.last_interaction_input_at_ms = now_ms
        self.interaction_active_until = now + INTERACTION_MODE_HOLD_SEC
        if self.interaction_mode != "interaction":
            self.interaction_mode = "interaction"
            self.set_video_media_targets(
                INTERACTION_CAPTURE_FRAMERATE,
                INTERACTION_VIDEO_TARGET_BITRATE_BPS,
                f"input:{str(message.get('type') or '<unknown>')}",
            )
            log(
                self.session_id,
                "interaction-mode",
                "interaction",
                f"targetFps={INTERACTION_CAPTURE_FRAMERATE}",
                f"targetBitrate={INTERACTION_VIDEO_TARGET_BITRATE_BPS}",
            )
            self.publish_media_relay_state("interaction-active")
        self.ensure_interaction_restore_task()

    async def apply_input_message(self, message: Dict, channel, received_at: int) -> None:
        ok = True
        error_message = ""
        try:
            msg_type = str(message.get("type") or "")
            if is_interaction_input_message(message):
                await self.note_interaction_activity(message)
            if msg_type == "viewport.resize":
                await self.apply_viewport_resize_message(message)
            elif not self.handle_interaction_mode_message(message):
                await handle_input(
                    message,
                    self.display_width,
                    self.display_height,
                    self.video_track,
                    self.audio_track,
                    self.browser,
                )
                if msg_type in {"browser.history", "browser.reload"}:
                    await self.send_worker_state(
                        "streaming"
                        if self.last_connection_state == "connected"
                        else "ready",
                        msg_type,
                        refresh_page=True,
                    )
        except Exception as error:
            ok = False
            error_message = truncate_for_log(str(error) or repr(error), 240)
            log(
                self.session_id,
                "input-apply-failed",
                truncate_for_log(str(message.get("type") or "<unknown>"), 80),
                error_message,
            )
        finally:
            applied_at = current_time_ms()
            self.enqueue_input_ack(message, channel, received_at, applied_at, ok, error_message)

    def enqueue_input_ack(
        self,
        message: Dict,
        channel,
        received_at: int,
        applied_at: int,
        ok: bool,
        error_message: str = "",
    ) -> None:
        if message.get("type") == "input.ack":
            return

        self.input_ack_sequence += 1
        ack: Dict[str, object] = {
            "workerSeq": self.input_ack_sequence,
            "type": str(message.get("type") or ""),
            "channel": data_channel_label(channel),
            "ok": ok,
            "workerReceiveTs": received_at,
            "workerApplyTs": applied_at,
            "workerAckQueuedTs": current_time_ms(),
            "workerApplyDelayMs": max(0, applied_at - received_at),
        }
        if "seq" in message:
            ack["seq"] = message.get("seq")
        viewer_ts = message.get("viewerTs")
        if viewer_ts is None:
            viewer_ts = message.get("ts")
        if viewer_ts is not None:
            ack["viewerTs"] = viewer_ts
        if error_message:
            ack["error"] = error_message

        self.input_ack_queue.append(ack)
        self.record_input_ack_queued(ack)
        if len(self.input_ack_queue) >= INPUT_ACK_MAX_BATCH:
            self.schedule_input_ack_flush(0.0)
        else:
            self.schedule_input_ack_flush(INPUT_ACK_INTERVAL_SEC)

    def record_input_ack_queued(self, ack: Dict[str, object]) -> None:
        self.input_ack_total_queued += 1
        self.last_input_ack_queued_at = int(ack.get("workerAckQueuedTs") or current_time_ms())
        self.last_input_ack_worker_seq = int(ack.get("workerSeq") or self.last_input_ack_worker_seq)
        self.last_input_ack_viewer_ts = ack.get("viewerTs", self.last_input_ack_viewer_ts)
        self.last_input_ack_receive_ts = int(ack.get("workerReceiveTs") or 0)
        self.last_input_ack_apply_ts = int(ack.get("workerApplyTs") or 0)

    def record_input_ack_sent(
        self,
        acks: List[Dict[str, object]],
        channel_label: str,
        sent_at: int,
    ) -> None:
        self.input_ack_total_sent += len(acks)
        self.last_input_ack_sent_at = sent_at
        self.last_input_ack_channel = channel_label

    def input_ack_stats_snapshot(self) -> Dict[str, object]:
        return {
            "pending": len(self.input_ack_queue),
            "totalQueued": self.input_ack_total_queued,
            "totalSent": self.input_ack_total_sent,
            "lastQueuedTs": self.last_input_ack_queued_at,
            "lastSentTs": self.last_input_ack_sent_at,
            "lastWorkerSeq": self.last_input_ack_worker_seq,
            "lastViewerTs": self.last_input_ack_viewer_ts,
            "lastReceiveTs": self.last_input_ack_receive_ts,
            "lastApplyTs": self.last_input_ack_apply_ts,
            "lastSentChannel": self.last_input_ack_channel,
        }

    def schedule_input_ack_flush(self, delay_sec: float) -> None:
        if delay_sec <= 0:
            if self.input_ack_timer_task is not None and not self.input_ack_timer_task.done():
                self.input_ack_timer_task.cancel()
            if self.input_ack_flush_task is None or self.input_ack_flush_task.done():
                self.input_ack_flush_task = asyncio.create_task(
                    self.flush_input_acks(),
                    name=f"input-ack-flush:{self.session_id}",
                )
            return

        if self.input_ack_timer_task is not None and not self.input_ack_timer_task.done():
            return
        self.input_ack_timer_task = asyncio.create_task(
            self.delayed_input_ack_flush(delay_sec),
            name=f"input-ack-timer:{self.session_id}",
        )

    async def delayed_input_ack_flush(self, delay_sec: float) -> None:
        task = asyncio.current_task()
        try:
            await asyncio.sleep(delay_sec)
        finally:
            if self.input_ack_timer_task is task:
                self.input_ack_timer_task = None
        await self.flush_input_acks()

    def open_input_ack_channels(self) -> List[object]:
        open_channels = [
            channel
            for channel in self.input_channels
            if data_channel_label(channel) in self.input_data_channel_labels()
            and is_data_channel_open(channel)
        ]

        def channel_priority(channel) -> int:
            label = data_channel_label(channel)
            priority = self.input_ack_channel_priority()
            if label in priority:
                return priority.index(label)
            return len(priority)

        return sorted(open_channels, key=channel_priority)

    async def flush_input_acks(self) -> None:
        async with self.input_ack_lock:
            while self.input_ack_queue:
                channels = self.open_input_ack_channels()
                if not channels:
                    self.schedule_input_ack_flush(INPUT_ACK_INTERVAL_SEC)
                    return

                acks = self.input_ack_queue[:INPUT_ACK_MAX_BATCH]
                del self.input_ack_queue[:INPUT_ACK_MAX_BATCH]
                last_seq = next(
                    (
                        ack.get("seq")
                        for ack in reversed(acks)
                        if ack.get("seq") is not None
                    ),
                    acks[-1].get("workerSeq", 0),
                )

                for channel in channels:
                    worker_ts = current_time_ms()
                    channel_label = data_channel_label(channel)
                    message = json.dumps(
                        {
                            "type": "input.ack",
                            "ackSeq": last_seq,
                            "lastSeq": last_seq,
                            "lastReceivedSeq": last_seq,
                            "channel": channel_label,
                            "count": len(acks),
                            "acks": acks,
                            "workerTs": worker_ts,
                        },
                        separators=(",", ":"),
                    )
                    try:
                        channel.send(message)
                        self.record_input_ack_sent(acks, channel_label, worker_ts)
                        break
                    except Exception as error:
                        log(
                            self.session_id,
                            "input-ack-send-failed",
                            f"label={data_channel_label(channel)}",
                            truncate_for_log(str(error) or repr(error), 160),
                        )
                else:
                    self.input_ack_queue = acks + self.input_ack_queue
                    self.schedule_input_ack_flush(INPUT_ACK_INTERVAL_SEC)
                    return

    def media_relay_capabilities(self) -> Dict[str, object]:
        return {
            "stateBridge": True,
            "mediaStats": True,
            "pixelMediaRelay": False,
            "webrtcSignalingPassthrough": False,
            "inputBridge": False,
            "mode": "state-bridge",
            "todo": (
                "Pixel media relay requires a defined relay protocol for frame "
                "encoding, timing, backpressure, auth, and input semantics."
            ),
        }

    def build_media_relay_state(self) -> Dict[str, object]:
        pc = self.pc
        page_state = self.browser.last_page_state or {}
        state: Dict[str, object] = {
            "sessionId": self.session_id,
            "targetUrl": self.target_url,
            "page": {
                "href": str(page_state.get("href") or ""),
                "title": str(page_state.get("title") or ""),
                "readyState": str(page_state.get("readyState") or ""),
            },
            "display": {
                "width": self.display_width,
                "height": self.display_height,
            },
            "signalingConnected": self.ws is not None,
            "webrtc": {
                "connectionState": getattr(pc, "connectionState", self.last_connection_state)
                if pc is not None
                else self.last_connection_state,
                "iceConnectionState": getattr(pc, "iceConnectionState", self.last_ice_connection_state)
                if pc is not None
                else self.last_ice_connection_state,
                "iceGatheringState": getattr(pc, "iceGatheringState", self.last_ice_gathering_state)
                if pc is not None
                else self.last_ice_gathering_state,
                "signalingState": getattr(pc, "signalingState", self.last_signaling_state)
                if pc is not None
                else self.last_signaling_state,
            },
            "interaction": {
                "mode": self.interaction_mode,
                "targetFramerate": self.current_video_target_framerate,
                "targetBitrateBps": self.current_video_target_bitrate_bps,
                "activeUntilMs": int(self.interaction_active_until * 1000)
                if self.interaction_active_until
                else 0,
                "lastInputTs": self.last_interaction_input_at_ms,
            },
            "inputAck": self.input_ack_stats_snapshot(),
            "peerStats": self.last_peer_stats or {},
            "mediaRelay": {
                "enabled": bool(self.media_relay_url),
                "mode": "state-bridge",
                "pixelMediaRelay": False,
            },
            "capabilities": self.media_relay_capabilities(),
        }

        if self.video_track is not None:
            try:
                state["video"] = self.video_track.snapshot_stats()
            except Exception as error:
                state["video"] = {"error": repr(error)}
        if self.audio_track is not None:
            try:
                state["audio"] = self.audio_track.snapshot_stats()
            except Exception as error:
                state["audio"] = {"error": repr(error)}
        return state

    def start_media_relay_bridge(self) -> None:
        if not self.media_relay_url:
            return
        if self.gateway_webrtc_relay_enabled:
            log(
                self.session_id,
                "media-relay-state-bridge-skipped",
                "reason=gateway-webrtc-relay",
            )
            return
        if self.media_relay_task is not None and not self.media_relay_task.done():
            return
        self.media_relay_bridge = MediaRelayStateBridge(self)
        self.media_relay_task = asyncio.create_task(
            self.media_relay_bridge.run(),
            name=f"media-relay-state-bridge:{self.session_id}",
        )
        log(
            self.session_id,
            "media-relay-enabled",
            "mode=state-bridge",
            "pixelMediaRelay=false",
        )

    def publish_media_relay_state(self, reason: str) -> None:
        if self.media_relay_bridge is None:
            return

        async def notify() -> None:
            try:
                await self.media_relay_bridge.publish_state(reason)
            except Exception as error:
                log(self.session_id, "media-relay-state-send-failed", repr(error))

        asyncio.create_task(notify())

    async def heartbeat_loop(self) -> None:
        while not SHUTDOWN.is_set():
            await asyncio.sleep(SIGNALING_HEARTBEAT_INTERVAL)
            if self.ws is None:
                return
            await self.send_json(
                {
                    "type": "heartbeat",
                    "sessionId": self.session_id,
                    "role": "worker",
                    "ts": int(asyncio.get_running_loop().time() * 1000),
                }
            )

    def invalidate_hybrid_dom_snapshot(self) -> None:
        self.hybrid_dom_snapshot_cache = None
        self.hybrid_dom_snapshot_cached_at = 0.0
        task = self.hybrid_dom_snapshot_task
        if task is not None and not task.done():
            task.cancel()
        self.hybrid_dom_snapshot_task = None

    def _cache_hybrid_dom_snapshot(self, snapshot: Dict[str, object]) -> Dict[str, object]:
        snapshot["backend"] = "rbi-worker"
        self.hybrid_dom_snapshot_cache = snapshot
        self.hybrid_dom_snapshot_cached_at = time.monotonic()
        return dict(snapshot)

    async def _compute_hybrid_dom_snapshot_once(self, timeout_sec: float) -> Dict[str, object]:
        snapshot = await asyncio.wait_for(
            self.browser.capture_hybrid_dom_snapshot_via_cdp(),
            timeout=timeout_sec,
        )
        if not isinstance(snapshot, dict):
            raise RuntimeError("Hybrid DOM snapshot payload was not an object")
        return snapshot

    async def _compute_hybrid_dom_snapshot_fallback(self, timeout_sec: float) -> Dict[str, object]:
        fallback_snapshot = await asyncio.wait_for(
            self.browser.evaluate_cdp(
                """
(() => {
  const sanitizeHtml = (html) =>
    String(html || "").replace(/<script\\b[\\s\\S]*?<\\/script>/gi, "");
  const serializeAttrs = (node) => {
    if (!node || !node.attributes) {
      return "";
    }
    return Array.from(node.attributes)
      .map(({ name, value }) => {
        const escaped = String(value || "")
          .replace(/&/g, "&amp;")
          .replace(/"/g, "&quot;");
        return ` ${name}="${escaped}"`;
      })
      .join("");
  };

  return {
    url: String(location.href || ""),
    title: String(document.title || ""),
    html:
      "<!doctype html><html" +
      serializeAttrs(document.documentElement) +
      "><head>" +
      sanitizeHtml(document.head?.innerHTML || "") +
      "</head><body" +
      serializeAttrs(document.body) +
      ">" +
      sanitizeHtml(document.body?.innerHTML || "") +
      "</body></html>",
    scrollX: Number(window.scrollX || 0),
    scrollY: Number(window.scrollY || 0),
    viewport: {
      width: Number(window.innerWidth || 0),
      height: Number(window.innerHeight || 0),
    },
    backend: "rbi-worker",
    degraded: true,
  };
})()
                """.strip(),
                return_by_value=True,
            ),
            timeout=timeout_sec,
        )
        if not isinstance(fallback_snapshot, dict):
            raise RuntimeError("Hybrid DOM fallback snapshot payload was not an object")
        fallback_snapshot["degraded"] = True
        return fallback_snapshot

    async def _warm_hybrid_dom_snapshot(self) -> None:
        current_task = asyncio.current_task()
        try:
            try:
                snapshot = await self._compute_hybrid_dom_snapshot_once(
                    max(HYBRID_DOM_INITIAL_SNAPSHOT_TIMEOUT_SEC * 3, 25.0)
                )
                self._cache_hybrid_dom_snapshot(snapshot)
                log(
                    self.session_id,
                    "hybrid-snapshot-warmed",
                    f"url={truncate_for_log(snapshot.get('url'), 160)}",
                )
                return
            except Exception as error:
                log(self.session_id, "hybrid-snapshot-warm-failed", repr(error))

            try:
                fallback_snapshot = await self._compute_hybrid_dom_snapshot_fallback(
                    max(HYBRID_DOM_SNAPSHOT_TIMEOUT_SEC * 2, 8.0)
                )
                self._cache_hybrid_dom_snapshot(fallback_snapshot)
                log(
                    self.session_id,
                    "hybrid-snapshot-warmed-fallback",
                    f"url={truncate_for_log(fallback_snapshot.get('url'), 160)}",
                )
            except Exception as fallback_error:
                log(
                    self.session_id,
                    "hybrid-snapshot-warm-fallback-failed",
                    repr(fallback_error),
                )
        except asyncio.CancelledError:
            raise
        finally:
            if self.hybrid_dom_snapshot_task is current_task:
                self.hybrid_dom_snapshot_task = None

    def ensure_hybrid_dom_snapshot_task(self) -> asyncio.Task:
        task = self.hybrid_dom_snapshot_task
        if task is not None and not task.done():
            return task
        task = asyncio.create_task(
            self._warm_hybrid_dom_snapshot(),
            name=f"hybrid-dom-snapshot:{self.session_id}",
        )
        self.hybrid_dom_snapshot_task = task
        return task

    async def build_hybrid_dom_placeholder_snapshot(self) -> Dict[str, object]:
        page_state = dict(self.browser.last_page_state or {})
        if not page_state:
            try:
                state = await asyncio.wait_for(self.browser.get_page_state(), timeout=0.75)
                if isinstance(state, dict):
                    page_state = dict(state)
            except Exception:
                page_state = {}

        url = str(page_state.get("href") or self.target_url or "")
        title = str(page_state.get("title") or "")
        body_text_length = int(page_state.get("bodyTextLength") or 0)
        viewport = {
            "width": int(self.browser.width),
            "height": int(self.browser.height),
        }
        screenshot_data_url = ""
        try:
            screenshot_bytes = await asyncio.wait_for(
                self.browser.capture_screenshot_bytes(
                    screenshot_format="jpeg",
                    quality=max(30, min(60, CDP_SCREENSHOT_QUALITY)),
                ),
                timeout=2.5,
            )
            screenshot_data_url = (
                "data:image/jpeg;base64," + base64.b64encode(screenshot_bytes).decode("ascii")
            )
        except Exception as error:
            log(
                self.session_id,
                "hybrid-placeholder-screenshot-failed",
                repr(error),
            )

        escaped_url = html.escape(url)
        escaped_title = html.escape(title or "Loading page")
        status_label = "Loading mirrored page"
        if body_text_length > 0:
            status_label = "Preparing live DOM mirror"
        screenshot_markup = (
            f'<img src="{screenshot_data_url}" alt="" '
            'style="width:100%;height:100%;object-fit:contain;display:block;background:#eef2ff;" />'
            if screenshot_data_url
            else ""
        )
        placeholder_html = f"""<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>{escaped_title}</title>
    <style>
      :root {{
        color-scheme: light;
        font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }}
      html, body {{
        width: 100%;
        height: 100%;
        margin: 0;
        background: #eef2ff;
        overflow: hidden;
      }}
      .frame {{
        position: relative;
        width: 100%;
        height: 100%;
        background: #eef2ff;
      }}
      .badge {{
        position: absolute;
        top: 16px;
        left: 16px;
        z-index: 2;
        padding: 8px 12px;
        border-radius: 999px;
        background: rgba(15, 23, 42, 0.82);
        color: #f8fafc;
        font-size: 13px;
        line-height: 1;
        backdrop-filter: blur(8px);
      }}
      .url {{
        position: absolute;
        right: 16px;
        bottom: 16px;
        z-index: 2;
        max-width: calc(100% - 32px);
        padding: 8px 12px;
        border-radius: 12px;
        background: rgba(255, 255, 255, 0.92);
        color: #0f172a;
        font-size: 12px;
        line-height: 1.4;
        box-shadow: 0 12px 32px rgba(15, 23, 42, 0.16);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }}
      .empty {{
        position: absolute;
        inset: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        color: #334155;
        font-size: 14px;
        background:
          radial-gradient(circle at top left, rgba(59, 130, 246, 0.18), transparent 36%),
          linear-gradient(180deg, rgba(255,255,255,0.96), rgba(226,232,240,0.92));
      }}
    </style>
  </head>
  <body>
    <div class="frame">
      <div class="badge">{html.escape(status_label)}</div>
      {screenshot_markup or '<div class="empty">Loading page preview...</div>'}
      <div class="url">{escaped_url or html.escape(self.target_url or "about:blank")}</div>
    </div>
  </body>
</html>"""
        return {
            "url": url,
            "title": title,
            "html": placeholder_html,
            "scrollX": 0,
            "scrollY": 0,
            "viewport": viewport,
            "formState": {},
            "backend": "rbi-worker",
            "degraded": True,
            "placeholder": True,
        }

    async def build_hybrid_dom_snapshot(self) -> Dict[str, object]:
        now = time.monotonic()
        cache_age_ms = (now - self.hybrid_dom_snapshot_cached_at) * 1000
        if (
            self.hybrid_dom_snapshot_cache is not None
            and cache_age_ms <= HYBRID_DOM_SNAPSHOT_CACHE_MS
        ):
            return dict(self.hybrid_dom_snapshot_cache)

        async with self.hybrid_dom_snapshot_lock:
            now = time.monotonic()
            cache_age_ms = (now - self.hybrid_dom_snapshot_cached_at) * 1000
            if (
                self.hybrid_dom_snapshot_cache is not None
                and cache_age_ms <= HYBRID_DOM_SNAPSHOT_CACHE_MS
            ):
                return dict(self.hybrid_dom_snapshot_cache)

            background_task = self.ensure_hybrid_dom_snapshot_task()
            wait_budget_sec = 1.5 if self.hybrid_dom_snapshot_cache is None else 0.75
            try:
                await asyncio.wait_for(asyncio.shield(background_task), timeout=wait_budget_sec)
            except asyncio.TimeoutError:
                pass
            except Exception:
                pass

            if self.hybrid_dom_snapshot_cache is not None:
                return dict(self.hybrid_dom_snapshot_cache)

            placeholder_snapshot = await self.build_hybrid_dom_placeholder_snapshot()
            self._cache_hybrid_dom_snapshot(placeholder_snapshot)
            log(
                self.session_id,
                "hybrid-snapshot-placeholder-served",
                f"url={truncate_for_log(placeholder_snapshot.get('url'), 160)}",
            )
            return dict(placeholder_snapshot)

            if self.hybrid_dom_snapshot_cache is not None:
                stale_age_ms = (time.monotonic() - self.hybrid_dom_snapshot_cached_at) * 1000
                stale_snapshot = dict(self.hybrid_dom_snapshot_cache)
                stale_snapshot["stale"] = True
                stale_snapshot["staleAgeMs"] = round(stale_age_ms, 1)
                log(
                    self.session_id,
                    "hybrid-snapshot-serving-stale",
                    f"ageMs={round(stale_age_ms, 1)}",
                )
                return stale_snapshot

            raise RuntimeError(
                "Hybrid DOM snapshot failed"
            )

    async def handle_hybrid_dom_request(self, message: Dict) -> Dict[str, object]:
        if not HYBRID_DOM_BRIDGE_ENABLED:
            raise RuntimeError("Hybrid DOM bridge is disabled on this worker")

        command = str(message.get("command") or "").strip().lower()
        payload = message.get("payload") or {}
        self.hybrid_dom_requests += 1

        if command == "snapshot":
            return await self.build_hybrid_dom_snapshot()

        if command == "navigate":
            target_url = str(payload.get("url") or "").strip()
            if not target_url:
                raise RuntimeError("Hybrid DOM navigate request is missing url")
            self.invalidate_hybrid_dom_snapshot()
            await self.browser.send_cdp("Page.bringToFront")
            await self.browser.send_cdp("Page.navigate", {"url": target_url})
            return {"ok": True, "url": target_url}

        if command == "inspect.point":
            x = max(0, float(payload.get("x") or 0))
            y = max(0, float(payload.get("y") or 0))
            result = await self.browser.evaluate_cdp(
                f"""
(() => {{
  const px = {json.dumps(x)};
  const py = {json.dumps(y)};
  let node = document.elementFromPoint(px, py);
  while (node?.shadowRoot?.elementFromPoint) {{
    const nested = node.shadowRoot.elementFromPoint(px, py);
    if (!nested || nested === node) {{
      break;
    }}
    node = nested;
  }}
  const anchor = node?.closest?.("a[href]");
  return {{
    href: String(anchor?.href || ""),
    tagName: String(node?.tagName || ""),
    text: String((anchor?.textContent || node?.textContent || "").trim()).slice(0, 256),
  }};
}})()
                """.strip(),
                return_by_value=True,
            )
            if not isinstance(result, dict):
                return {"href": ""}
            return result

        if command == "input.click":
            x = max(0, float(payload.get("x") or 0))
            y = max(0, float(payload.get("y") or 0))
            await self.browser.send_cdp(
                "Input.dispatchMouseEvent",
                {
                    "type": "mouseMoved",
                    "x": x,
                    "y": y,
                    "button": "none",
                    "buttons": 0,
                },
            )
            await self.browser.send_cdp(
                "Input.dispatchMouseEvent",
                {
                    "type": "mousePressed",
                    "x": x,
                    "y": y,
                    "button": "left",
                    "buttons": 1,
                    "clickCount": 1,
                },
            )
            await self.browser.send_cdp(
                "Input.dispatchMouseEvent",
                {
                    "type": "mouseReleased",
                    "x": x,
                    "y": y,
                    "button": "left",
                    "buttons": 0,
                    "clickCount": 1,
                },
            )
            return {"ok": True}

        if command == "input.wheel":
            await self.browser.send_cdp(
                "Input.dispatchMouseEvent",
                {
                    "type": "mouseWheel",
                    "x": max(0, float(payload.get("x") or 0)),
                    "y": max(0, float(payload.get("y") or 0)),
                    "deltaX": float(payload.get("deltaX") or 0),
                    "deltaY": float(payload.get("deltaY") or 0),
                },
            )
            return {"ok": True}

        if command == "input.key":
            key = str(payload.get("key") or "")
            code = str(payload.get("code") or "")
            text = str(payload.get("text") or "")
            await self.browser.send_cdp(
                "Input.dispatchKeyEvent",
                {
                    "type": "keyDown",
                    "key": key,
                    "code": code,
                    "text": text,
                    "unmodifiedText": text,
                },
            )
            await self.browser.send_cdp(
                "Input.dispatchKeyEvent",
                {
                    "type": "keyUp",
                    "key": key,
                    "code": code,
                },
            )
            return {"ok": True}

        if command == "input.set_focused_value":
            value = str(payload.get("value") or "")
            result = await self.browser.evaluate_cdp(
                f"""
(() => {{
  const nextValue = {json.dumps(value)};
  let active = document.activeElement;
  while (active?.shadowRoot?.activeElement) {{
    active = active.shadowRoot.activeElement;
  }}
  if (!active) {{
    return {{ ok: false, error: "No active element" }};
  }}

  const dispatchInput = (element) => {{
    try {{
      element.dispatchEvent(
        new InputEvent("input", {{
          bubbles: true,
          composed: true,
          inputType: "insertReplacementText",
          data: null,
        }}),
      );
    }} catch {{
      element.dispatchEvent(new Event("input", {{ bubbles: true, composed: true }}));
    }}
  }};

  const setNativeValue = (element, prop, value) => {{
    let proto = element;
    while (proto) {{
      const descriptor = Object.getOwnPropertyDescriptor(proto, prop);
      if (descriptor?.set) {{
        descriptor.set.call(element, value);
        return true;
      }}
      proto = Object.getPrototypeOf(proto);
    }}
    return false;
  }};

  if (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) {{
    if (!setNativeValue(active, "value", nextValue)) {{
      active.value = nextValue;
    }}
    if (typeof active.setSelectionRange === "function") {{
      const end = String(nextValue).length;
      try {{
        active.setSelectionRange(end, end);
      }} catch {{}}
    }}
    dispatchInput(active);
    return {{
      ok: true,
      tagName: String(active.tagName || ""),
      value: String(active.value || ""),
    }};
  }}

  if (active.isContentEditable) {{
    active.textContent = nextValue;
    dispatchInput(active);
    return {{
      ok: true,
      tagName: String(active.tagName || ""),
      value: String(active.textContent || ""),
    }};
  }}

  return {{
    ok: false,
    error: `Focused element is not editable: ${{String(active.tagName || "<unknown>")}}`,
  }};
}})()
                """.strip(),
                return_by_value=True,
            )
            if not isinstance(result, dict) or not result.get("ok"):
                raise RuntimeError(
                    str((result or {}).get("error") or "Unable to set focused Hybrid DOM value")
                )
            return result

        raise RuntimeError(f"Unknown hybrid DOM command: {command or '<empty>'}")

    async def flush_pending_offer(self) -> None:
        if (
            not self.pending_offer_reason
            or self.pc is None
            or (self.ws is None and not self.gateway_webrtc_relay_enabled)
            or self.offer_lock.locked()
            or self.pc.signalingState != "stable"
        ):
            return

        reason = self.pending_offer_reason
        self.pending_offer_reason = None
        await self.send_offer(reason)

    def configure_video_sender_preferences(self) -> None:
        if self.video_transceiver is None:
            return
        capabilities = RTCRtpSender.getCapabilities("video")
        codecs = order_video_codec_preferences(
            capabilities.codecs,
            self.video_codec_preferences,
            strict=self.gateway_webrtc_relay_enabled,
        )
        if not codecs:
            return
        try:
            self.video_transceiver.setCodecPreferences(codecs)
            log(
                self.session_id,
                "video-codec-preferences",
                ",".join(codec_name_from_mime_type(getattr(codec, "mimeType", "")) for codec in codecs),
            )
        except Exception as error:
            log(self.session_id, "video-codec-preferences-failed", repr(error))

    async def tune_video_sender(self, reason: str = "startup") -> None:
        if self.video_transceiver is None:
            return

        for _attempt in range(40):
            if SHUTDOWN.is_set() or self.pc is None:
                return
            if self.apply_video_sender_target_bitrate(
                self.current_video_target_bitrate_bps,
                reason,
            ):
                return
            await asyncio.sleep(0.1)

    async def build_video_capture_pipeline(self) -> Tuple[Optional[MediaPlayer], AdaptiveVideoTrack]:
        normalized_backend = VIDEO_CAPTURE_BACKEND
        if normalized_backend in {"browser-native", "cdp-screenshot"}:
            source_track = CDPScreenshotTrack(
                self.browser,
                self.display_width,
                self.display_height,
            )
            try:
                await source_track.prime()
                log(self.session_id, "video-capture-backend", source_track.capture_backend)
                return (
                    None,
                    AdaptiveVideoTrack(
                        source_track,
                        self.display_width,
                        self.display_height,
                        self.media_sync,
                    ),
                )
            except Exception as error:
                try:
                    source_track.stop()
                except Exception:
                    pass
                log(
                    self.session_id,
                    "video-capture-backend-failed",
                    f"backend={source_track.capture_backend}",
                    repr(error),
                )
                raise

        video_player = MediaPlayer(
            f"{DISPLAY}.0+0,0",
            format="x11grab",
            options={
                "framerate": str(CAPTURE_FRAMERATE),
                "video_size": f"{self.display_width}x{self.display_height}",
                "draw_mouse": "0",
            },
        )
        if video_player.video is None:
            raise RuntimeError("Unable to capture X11 display")
        log(self.session_id, "video-capture-backend", "x11grab")
        return (
            video_player,
            AdaptiveVideoTrack(
                video_player.video,
                self.display_width,
                self.display_height,
                self.media_sync,
            ),
        )

    async def build_source_coupled_capture_pipeline(
        self,
    ) -> Tuple[SourceCoupledAVCapture, SourceCoupledVideoTrack, SourceCoupledAudioTrack]:
        capture = SourceCoupledAVCapture(
            self.session_id,
            self.display_width,
            self.display_height,
            framerate=CAPTURE_FRAMERATE,
            sample_rate=int(PULSE_AUDIO_RATE),
            channels=int(PULSE_AUDIO_CHANNELS),
            source_name=PULSE_SOURCE_NAME,
            activity_callback=self.on_audio_activity if self.audio_startup_sync_experiment else None,
        )
        await capture.start()
        log(
            self.session_id,
            "source-coupled-capture-backend",
            f"framerate={CAPTURE_FRAMERATE}",
            f"sampleRate={PULSE_AUDIO_RATE}",
            f"channels={PULSE_AUDIO_CHANNELS}",
        )
        return (
            capture,
            SourceCoupledVideoTrack(capture, self.display_width, self.display_height),
            SourceCoupledAudioTrack(capture),
        )

    async def build_media_capture_pipeline(
        self,
    ) -> Tuple[
        Optional[MediaPlayer],
        Optional[SourceCoupledAVCapture],
        MediaStreamTrack,
        Optional[MediaStreamTrack],
    ]:
        log(
            self.session_id,
            "media-capture-selection",
            f"requestedSourceCoupledAv={self.source_coupled_av_experiment}",
            f"videoCaptureBackend={VIDEO_CAPTURE_BACKEND}",
        )
        if self.source_coupled_av_experiment:
            if VIDEO_CAPTURE_BACKEND != "x11grab":
                log(
                    self.session_id,
                    "source-coupled-capture-backend-skipped",
                    f"videoCaptureBackend={VIDEO_CAPTURE_BACKEND}",
                )
                self.source_coupled_av_experiment = False
            else:
                try:
                    coupled_capture, coupled_video_track, coupled_audio_track = (
                        await self.build_source_coupled_capture_pipeline()
                    )
                    return None, coupled_capture, coupled_video_track, coupled_audio_track
                except Exception as error:
                    log(
                        self.session_id,
                        "source-coupled-capture-backend-failed",
                        repr(error),
                    )
                    self.source_coupled_av_experiment = False

        video_player, video_track = await self.build_video_capture_pipeline()
        audio_track = None
        try:
            audio_capture_latency_msec = (
                min(PULSE_CAPTURE_LATENCY_MSEC, EXPERIMENTAL_AUDIO_CAPTURE_LATENCY_MSEC)
                if self.audio_startup_sync_experiment
                else PULSE_CAPTURE_LATENCY_MSEC
            )
            audio_track = PulseAudioTrack(
                PULSE_SOURCE_NAME,
                int(PULSE_AUDIO_RATE),
                int(PULSE_AUDIO_CHANNELS),
                AUDIO_SYNC_DELAY_MS,
                audio_capture_latency_msec,
                self.media_sync,
                freshness_guard_enabled=self.audio_startup_sync_experiment,
                activity_callback=self.on_audio_activity if self.audio_startup_sync_experiment else None,
            )
            log(
                self.session_id,
                "audio-track",
                PULSE_SOURCE_NAME,
                f"syncDelayMs={AUDIO_SYNC_DELAY_MS}",
                f"captureLatencyMsec={audio_capture_latency_msec}",
                f"freshnessGuard={self.audio_startup_sync_experiment}",
            )
        except Exception as error:
            log(self.session_id, "audio-capture-disabled", str(error))
        return video_player, None, video_track, audio_track

    def stop_video_capture_pipeline(
        self,
        *,
        video_player: Optional[MediaPlayer] = None,
        video_track: Optional[MediaStreamTrack] = None,
    ) -> None:
        active_player = video_player if video_player is not None else self.video_player
        active_track = video_track if video_track is not None else self.video_track
        if active_track is not None:
            try:
                active_track.stop()
            except Exception:
                pass
        if active_player is not None:
            for track in (active_player.audio, active_player.video):
                if track is not None:
                    try:
                        track.stop()
                    except Exception:
                        pass

    def stop_media_capture_pipeline(
        self,
        *,
        video_player: Optional[MediaPlayer] = None,
        source_coupled_capture: Optional[SourceCoupledAVCapture] = None,
        video_track: Optional[MediaStreamTrack] = None,
        audio_track: Optional[MediaStreamTrack] = None,
    ) -> None:
        active_capture = (
            source_coupled_capture if source_coupled_capture is not None else self.source_coupled_capture
        )
        if active_capture is not None:
            try:
                active_capture.stop()
            except Exception:
                pass
        if audio_track is not None and audio_track is not self.audio_track:
            try:
                audio_track.stop()
            except Exception:
                pass
        self.stop_video_capture_pipeline(video_player=video_player, video_track=video_track)

    async def replace_media_capture_pipeline(self, reason: str) -> None:
        next_player, next_capture, next_track, next_audio_track = await self.build_media_capture_pipeline()
        if hasattr(next_track, "mark_recovery"):
            next_track.mark_recovery(reason)
        previous_player = self.video_player
        previous_capture = self.source_coupled_capture
        previous_track = self.video_track
        previous_audio_track = self.audio_track

        self.video_player = next_player
        self.source_coupled_capture = next_capture
        self.video_track = next_track
        self.audio_track = next_audio_track
        self.video_sender_tuned = False

        if self.video_transceiver is None:
            assert self.pc is not None
            self.video_transceiver = self.pc.addTransceiver(next_track, direction="sendonly")
            self.configure_video_sender_preferences()
        else:
            self.video_transceiver.sender.replaceTrack(next_track)

        if next_audio_track is not None:
            if self.audio_sender is None:
                assert self.pc is not None
                self.audio_sender = self.pc.addTrack(next_audio_track)
            else:
                self.audio_sender.replaceTrack(next_audio_track)
        elif self.audio_sender is not None:
            self.audio_sender.replaceTrack(None)

        if self.video_sender_tuning_task is None or self.video_sender_tuning_task.done():
            self.video_sender_tuning_task = asyncio.create_task(
                self.tune_video_sender(f"capture-restart:{reason}")
            )

        self.stop_media_capture_pipeline(
            video_player=previous_player,
            source_coupled_capture=previous_capture,
            video_track=previous_track,
            audio_track=previous_audio_track,
        )
        stats = next_track.snapshot_stats()
        log(
            self.session_id,
            "media-capture-replaced",
            f"reason={truncate_for_log(reason, 120)}",
            f"target={stats['targetWidth']}x{stats['targetHeight']}",
            f"backend={truncate_for_log(stats.get('sourceBackend'), 64)}",
        )

    def describe_video_track(self) -> str:
        if self.video_track is None:
            return "videoTrack=missing"
        stats = self.video_track.snapshot_stats()
        return (
            " ".join(
                [
                    f"sourceBackend={stats['sourceBackend']}",
                    f"sourceFrames={stats['sourceFrames']}",
                    f"deliveredFrames={stats['deliveredFrames']}",
                    f"sourceFps={stats['sourceFps']}",
                    f"deliveredFps={stats['deliveredFps']}",
                    f"sourceFrameAgeMs={stats['sourceFrameAgeMs']}",
                    f"deliveredFrameAgeMs={stats['deliveredFrameAgeMs']}",
                    f"lastSourceGapMs={stats['lastSourceGapMs']}",
                    f"maxSourceGapMs={stats['maxSourceGapMs']}",
                    f"largeGapCount={stats['largeGapCount']}",
                    f"recvErrors={stats['recvErrors']}",
                    f"target={stats['targetWidth']}x{stats['targetHeight']}",
                    f"targetFps={stats.get('targetFramerate', CAPTURE_FRAMERATE)}",
                    f"recoveryCount={stats['recoveryCount']}",
                    f"lastRecoveryReason={truncate_for_log(stats['lastRecoveryReason'], 80)}",
                    f"pacingDroppedFrames={stats.get('pacingDroppedFrames', 0)}",
                ]
            )
        )

    def describe_audio_track(self) -> str:
        if self.audio_track is None:
            return "audioTrack=missing"
        stats = self.audio_track.snapshot_stats()
        return (
            " ".join(
                [
                    f"source={truncate_for_log(stats['source'], 80)}",
                    f"freshnessGuard={stats['freshnessGuardEnabled']}",
                    f"framesRead={stats['framesRead']}",
                    f"framesEmitted={stats['framesEmitted']}",
                    f"droppedFrames={stats['droppedFrames']}",
                    f"emittedFps={stats['emittedFps']}",
                    f"frameAgeMs={stats['frameAgeMs']}",
                    f"lastGapMs={stats['lastGapMs']}",
                    f"maxGapMs={stats['maxGapMs']}",
                    f"backlogMs={stats['backlogMs']}",
                    f"maxBacklogMs={stats['maxBacklogMs']}",
                    f"lastDropCount={stats['lastDropCount']}",
                    f"resyncRequests={stats['resyncRequests']}",
                    f"lastResyncReason={truncate_for_log(stats['lastResyncReason'], 80)}",
                    f"syncDelayMs={stats['syncDelayMs']}",
                    f"audioReady={stats['audioReady']}",
                    f"audioActiveFrames={stats['audioActiveFrames']}",
                    f"rms={stats['rms']}",
                    f"maxRms={stats['maxRms']}",
                ]
            )
        )

    def on_audio_activity(self, payload: Dict[str, object]) -> None:
        if self.ws is None:
            return
        self.publish_media_relay_state("audio-activity")
        async def notify() -> None:
            try:
                await self.send_json(
                    {
                        "type": "worker-media",
                        "sessionId": self.session_id,
                        "audioReady": bool(payload.get("audioReady")),
                        "rms": int(payload.get("rms") or 0),
                        "maxRms": int(payload.get("maxRms") or 0),
                        "activeFrames": int(payload.get("activeFrames") or 0),
                    }
                )
            except Exception as error:
                log(self.session_id, "worker-media-send-failed", repr(error))

        asyncio.create_task(notify())

    @staticmethod
    def stat_value(stat: object, name: str, default=None):
        if isinstance(stat, dict):
            return stat.get(name, default)
        return getattr(stat, name, default)

    @classmethod
    def stat_timestamp_ms(cls, stat: object) -> Optional[float]:
        value = cls.stat_value(stat, "timestamp")
        if value is None:
            return None
        if hasattr(value, "timestamp"):
            return float(value.timestamp() * 1000)
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    async def log_peer_stats(self) -> None:
        if self.pc is None:
            return
        try:
            report = await self.pc.getStats()
        except Exception as error:
            log(self.session_id, "peer-stats-failed", repr(error))
            return

        values = list(report.values()) if hasattr(report, "values") else list(report)
        outbound_video = None
        remote_inbound_video = None
        selected_pair = None
        stats_by_id = {}
        for stat in values:
            stat_id = self.stat_value(stat, "id", "")
            if stat_id:
                stats_by_id[str(stat_id)] = stat
            stat_type = self.stat_value(stat, "type", "")
            media_kind = self.stat_value(stat, "kind", self.stat_value(stat, "mediaType", ""))
            if stat_type == "outbound-rtp" and str(media_kind).lower() == "video":
                outbound_video = stat
            elif stat_type == "remote-inbound-rtp" and str(media_kind).lower() == "video":
                remote_inbound_video = stat
            elif stat_type == "candidate-pair" and self.stat_value(stat, "state") == "succeeded":
                if self.stat_value(stat, "selected", False) or self.stat_value(
                    stat,
                    "nominated",
                    False,
                ):
                    selected_pair = stat

        def as_float(value, default=None):
            try:
                return float(value)
            except (TypeError, ValueError):
                return default

        def as_int(value, default=None):
            try:
                return int(value)
            except (TypeError, ValueError):
                return default

        def rtt_ms(value):
            parsed = as_float(value)
            return None if parsed is None else round(parsed * 1000, 1)

        def candidate_detail(candidate) -> str:
            if candidate is None:
                return "unknown"
            candidate_type = (
                self.stat_value(candidate, "candidateType", "")
                or self.stat_value(candidate, "relayProtocol", "")
                or "unknown"
            )
            protocol = self.stat_value(candidate, "protocol", "unknown")
            address = (
                self.stat_value(candidate, "ip", "")
                or self.stat_value(candidate, "address", "")
                or self.stat_value(candidate, "host", "")
                or "unknown"
            )
            port = self.stat_value(candidate, "port", "")
            suffix = f":{port}" if port not in {"", None} else ""
            return f"{candidate_type}/{protocol}/{address}{suffix}"

        parts = []
        snapshot: Dict[str, object] = {
            "interactionMode": self.interaction_mode,
            "targetFramerate": self.current_video_target_framerate,
            "targetBitrateBps": self.current_video_target_bitrate_bps,
            "inputAck": self.input_ack_stats_snapshot(),
        }
        if outbound_video is not None:
            current_bytes = self.stat_value(outbound_video, "bytesSent")
            current_ts_ms = self.stat_timestamp_ms(outbound_video)
            bitrate_bps = None
            previous = self.previous_outbound_video_stats
            if (
                previous
                and current_bytes is not None
                and current_ts_ms is not None
                and previous.get("bytesSent") is not None
                and previous.get("timestampMs") is not None
                and current_ts_ms > previous["timestampMs"]
            ):
                bitrate_bps = int(
                    ((current_bytes - previous["bytesSent"]) * 8 * 1000)
                    / (current_ts_ms - previous["timestampMs"])
                )
            self.previous_outbound_video_stats = {
                "bytesSent": current_bytes,
                "timestampMs": current_ts_ms,
            }
            packets_sent = as_int(self.stat_value(outbound_video, "packetsSent"))
            frames_encoded = as_int(self.stat_value(outbound_video, "framesEncoded"))
            frames_per_second = self.stat_value(outbound_video, "framesPerSecond", "unknown")
            nack_count = as_int(self.stat_value(outbound_video, "nackCount"))
            pli_count = as_int(self.stat_value(outbound_video, "pliCount"))
            snapshot.update(
                {
                    "bitrateBps": bitrate_bps,
                    "bytesSent": current_bytes,
                    "packetsSent": packets_sent,
                    "framesEncoded": frames_encoded,
                    "framesPerSecond": frames_per_second,
                    "nackCount": nack_count,
                    "pliCount": pli_count,
                    "qualityLimitationReason": self.stat_value(
                        outbound_video,
                        "qualityLimitationReason",
                        "none",
                    ),
                }
            )
            parts.extend(
                [
                    f"bitrateBps={bitrate_bps if bitrate_bps is not None else 'unknown'}",
                    f"bytesSent={current_bytes}",
                    f"packetsSent={packets_sent if packets_sent is not None else 'unknown'}",
                    f"framesEncoded={frames_encoded if frames_encoded is not None else 'unknown'}",
                    f"framesPerSecond={frames_per_second}",
                    f"qualityLimitationReason={snapshot['qualityLimitationReason']}",
                    f"nackCount={nack_count if nack_count is not None else 'unknown'}",
                    f"pliCount={pli_count if pli_count is not None else 'unknown'}",
                ]
            )

        if remote_inbound_video is not None:
            packets_lost = as_int(self.stat_value(remote_inbound_video, "packetsLost"))
            fraction_lost = self.stat_value(remote_inbound_video, "fractionLost", "unknown")
            remote_rtt_ms = rtt_ms(self.stat_value(remote_inbound_video, "roundTripTime"))
            snapshot.update(
                {
                    "remotePacketsLost": packets_lost,
                    "remoteFractionLost": fraction_lost,
                    "remoteRttMs": remote_rtt_ms,
                }
            )
            parts.extend(
                [
                    f"remotePacketsLost={packets_lost if packets_lost is not None else 'unknown'}",
                    f"remoteFractionLost={fraction_lost}",
                    f"remoteRttMs={remote_rtt_ms if remote_rtt_ms is not None else 'unknown'}",
                ]
            )

        if selected_pair is not None:
            local_id = self.stat_value(selected_pair, "localCandidateId", "")
            remote_id = self.stat_value(selected_pair, "remoteCandidateId", "")
            local_candidate = stats_by_id.get(str(local_id))
            remote_candidate = stats_by_id.get(str(remote_id))
            selected_rtt_ms = rtt_ms(self.stat_value(selected_pair, "currentRoundTripTime"))
            available_outgoing_bitrate = self.stat_value(
                selected_pair,
                "availableOutgoingBitrate",
                "unknown",
            )
            local_detail = candidate_detail(local_candidate)
            remote_detail = candidate_detail(remote_candidate)
            snapshot.update(
                {
                    "selectedIceLocal": local_detail,
                    "selectedIceRemote": remote_detail,
                    "selectedIcePath": f"{local_detail}->{remote_detail}",
                    "candidatePairRttMs": selected_rtt_ms,
                    "availableOutgoingBitrate": available_outgoing_bitrate,
                }
            )
            parts.extend(
                [
                    f"selectedIcePath={local_detail}->{remote_detail}",
                    f"candidatePair={local_id or '?'}->{remote_id or '?'}",
                    f"rttMs={selected_rtt_ms if selected_rtt_ms is not None else 'unknown'}",
                    f"availableOutgoingBitrate={available_outgoing_bitrate}",
                ]
            )

        if self.video_track is not None and hasattr(self.video_track, "snapshot_stats"):
            try:
                video_stats = self.video_track.snapshot_stats()
                snapshot["videoDrops"] = video_stats.get("droppedFrames")
                snapshot["videoPacingDrops"] = video_stats.get("pacingDroppedFrames", 0)
                snapshot["videoDeliveredFps"] = video_stats.get("deliveredFps")
                snapshot["videoTarget"] = (
                    f"{video_stats.get('targetWidth')}x{video_stats.get('targetHeight')}"
                )
                parts.extend(
                    [
                        f"videoDrops={snapshot['videoDrops']}",
                        f"videoPacingDrops={snapshot['videoPacingDrops']}",
                        f"videoDeliveredFps={snapshot['videoDeliveredFps']}",
                        f"videoTarget={snapshot['videoTarget']}",
                    ]
                )
            except Exception as error:
                snapshot["videoStatsError"] = repr(error)

        input_ack = snapshot["inputAck"]
        parts.extend(
            [
                f"inputAckPending={input_ack.get('pending')}",
                f"inputAckLastQueuedTs={input_ack.get('lastQueuedTs')}",
                f"inputAckLastSentTs={input_ack.get('lastSentTs')}",
                f"inputAckLastApplyTs={input_ack.get('lastApplyTs')}",
            ]
        )
        self.last_peer_stats = snapshot
        if parts:
            log(self.session_id, "peer-stats", *parts)

    async def attempt_local_media_recovery(self, reason: str) -> bool:
        if self.video_track is None:
            return False

        now = time.monotonic()
        if (
            self.last_capture_recovery_at
            and now - self.last_capture_recovery_at < CAPTURE_RECOVERY_COOLDOWN_SEC
        ):
            log(
                self.session_id,
                "capture-recovery-skipped",
                f"reason={truncate_for_log(reason, 120)}",
                f"cooldownSec={CAPTURE_RECOVERY_COOLDOWN_SEC}",
            )
            return False

        if self.capture_recovery_lock.locked():
            log(self.session_id, "capture-recovery-skipped", "reason=in-progress")
            return False

        async with self.capture_recovery_lock:
            self.capture_recovery_attempts += 1
            self.last_capture_recovery_at = time.monotonic()
            self.video_track.mark_recovery(reason)
            log(
                self.session_id,
                "capture-recovery-start",
                f"reason={truncate_for_log(reason, 160)}",
                f"attempt={self.capture_recovery_attempts}",
                self.describe_video_track(),
            )
            try:
                await self.browser.heal_visible_pipeline(reason)
            except Exception as error:
                log(self.session_id, "capture-recovery-browser-heal-failed", repr(error))
            try:
                await self.replace_media_capture_pipeline(reason)
            except Exception as error:
                log(self.session_id, "capture-recovery-capture-restart-failed", repr(error))
                return False

            log(
                self.session_id,
                "capture-recovery-complete",
                f"reason={truncate_for_log(reason, 160)}",
                self.describe_video_track(),
            )
            return True

    async def media_diagnostics_loop(self) -> None:
        while not SHUTDOWN.is_set():
            await asyncio.sleep(CAPTURE_STATS_INTERVAL_SEC)
            if self.video_track is None:
                continue

            log(self.session_id, "video-capture-stats", self.describe_video_track())
            if self.audio_track is not None:
                log(self.session_id, "audio-capture-stats", self.describe_audio_track())
            await self.log_peer_stats()
            self.publish_media_relay_state("media-diagnostics")

            stats = self.video_track.snapshot_stats()
            self.media_sync.observe_video(
                gap_ms=stats.get("lastSourceGapMs", 0.0),
                fps=stats.get("deliveredFps", 0.0),
                frame_age_ms=stats.get("deliveredFrameAgeMs"),
            )

            if self.pc is None or self.pc.connectionState != "connected":
                continue

            frame_age_ms = stats.get("sourceFrameAgeMs")
            if (
                stats.get("sourceFrames", 0) > 0
                and isinstance(frame_age_ms, (int, float))
                and frame_age_ms >= CAPTURE_STALL_THRESHOLD_SEC * 1000
            ):
                await self.attempt_local_media_recovery(
                    f"capture-stall frameAgeMs={frame_age_ms}"
                )

    def post_gateway_offer_sync(self, sdp: str) -> Dict[str, object]:
        if not self.gateway_offer_url:
            raise RuntimeError("Gateway WebRTC relay is missing an offer URL")
        body = json.dumps(
            {
                "type": "offer",
                "role": "worker",
                "sessionId": self.session_id,
                "token": self.worker_token,
                "sdp": sdp,
            }
        ).encode("utf-8")
        request = urllib.request.Request(
            self.gateway_offer_url,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self.worker_token}",
            },
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=MEDIA_GATEWAY_REQUEST_TIMEOUT_SEC,
            ) as response:
                response_body = response.read(1024 * 1024).decode("utf-8")
        except urllib.error.HTTPError as error:
            response_body = error.read(64 * 1024).decode("utf-8", errors="replace")
            raise RuntimeError(
                f"Gateway offer failed status={error.code}: {truncate_for_log(response_body, 240)}"
            ) from error

        if not response_body.strip():
            return {}
        try:
            parsed = json.loads(response_body)
        except json.JSONDecodeError as error:
            raise RuntimeError("Gateway offer response was not JSON") from error
        if not isinstance(parsed, dict):
            raise RuntimeError("Gateway offer response was not an object")
        return parsed

    async def post_gateway_offer(self, sdp: str) -> Dict[str, object]:
        return await asyncio.to_thread(self.post_gateway_offer_sync, sdp)

    async def send_offer(self, reason: str) -> None:
        if self.pc is None or (self.ws is None and not self.gateway_webrtc_relay_enabled):
            self.pending_offer_reason = reason
            return

        if self.offer_lock.locked():
            self.pending_offer_reason = reason
            log(self.session_id, "queue-offer", reason)
            return

        if self.pc.signalingState != "stable":
            self.pending_offer_reason = reason
            log(self.session_id, "defer-offer", f"{reason} signalingState={self.pc.signalingState}")
            return

        async with self.offer_lock:
            self.ice_gathering_complete.clear()
            offer = await self.pc.createOffer()
            await self.pc.setLocalDescription(offer)
            try:
                await asyncio.wait_for(self.ice_gathering_complete.wait(), timeout=5)
            except asyncio.TimeoutError:
                log(self.session_id, "ice-gathering-timeout", reason)
            filtered_offer = filter_sdp_candidates(
                self.pc.localDescription.sdp or "",
                self.allowed_candidate_types,
            )
            filtered_offer = apply_video_bitrate_hints_to_sdp(filtered_offer)
            candidate_count = sum(
                1 for line in filtered_offer.splitlines() if line.startswith("a=candidate:")
            )
            log(self.session_id, "created-offer", f"{reason} candidates={candidate_count}")
            if self.gateway_webrtc_relay_enabled:
                response = await self.post_gateway_offer(filtered_offer)
                answer_sdp = extract_gateway_answer_sdp(response)
                if not answer_sdp:
                    raise RuntimeError("Gateway offer response did not include an SDP answer")
                await self.pc.setRemoteDescription(
                    RTCSessionDescription(
                        sdp=filter_sdp_candidates(answer_sdp, self.allowed_candidate_types),
                        type="answer",
                    )
                )
                log(self.session_id, "gateway-webrtc-answer-applied", reason)
            else:
                await self.send_json(
                    {
                        "type": "sdp-offer",
                        "sessionId": self.session_id,
                        "sdp": filtered_offer,
                    }
                )

        await self.flush_pending_offer()

    async def kick_visible_repaint_after_connect(self) -> None:
        try:
            for delay in (0.0, 0.35, 1.0, 2.0):
                if delay > 0:
                    await asyncio.sleep(delay)
                if SHUTDOWN.is_set() or self.pc is None or self.pc.connectionState != "connected":
                    return
                try:
                    await self.browser.ensure_fullscreen()
                except Exception as error:
                    log(self.session_id, "post-connect-fullscreen-failed", repr(error))
                try:
                    await self.browser.nudge_first_paint()
                    log(self.session_id, "post-connect-repaint-kick", f"delay={delay}")
                except Exception as error:
                    log(self.session_id, "post-connect-repaint-kick-failed", repr(error))
        finally:
            self.post_connect_kick_task = None

    async def setup_peer_connection(self) -> RTCPeerConnection:
        ice_servers = []
        for url in self.ice_urls:
            if url.startswith("turn:") or url.startswith("turns:"):
                ice_servers.append(
                    RTCIceServer(
                        urls=[url],
                        username=self.turn_username,
                        credential=self.turn_password,
                    )
                )
            elif url.startswith("stun:") or url.startswith("stuns:"):
                ice_servers.append(RTCIceServer(urls=[url]))

        log(
            self.session_id,
            "ice-config",
            f"servers={len(ice_servers)}",
            f"urls={self.ice_urls}",
            f"username={self.turn_username[:8]}..." if self.turn_username else "no-username",
        )

        pc = RTCPeerConnection(configuration=RTCConfiguration(iceServers=ice_servers))

        @pc.on("icecandidate")
        async def on_icecandidate(candidate):
            if candidate is None:
                log(self.session_id, "local-ice", "gathering-complete")
                self.ice_gathering_complete.set()
                return

            candidate_sdp = candidate_to_sdp(candidate)
            candidate_type = getattr(candidate, "type", "") or extract_candidate_type(candidate_sdp)
            log(
                self.session_id,
                "local-ice-candidate",
                f"type={candidate_type or 'unknown'}",
                f"component={candidate.component}",
                f"protocol={getattr(candidate, 'protocol', '?')}",
                f"address={getattr(candidate, 'host', '?')}:{getattr(candidate, 'port', '?')}",
            )
            if not is_allowed_candidate(candidate_sdp, self.allowed_candidate_types):
                log(self.session_id, "skip-local-ice", candidate_type or "unknown")
                return

            if self.gateway_webrtc_relay_enabled:
                log(self.session_id, "local-ice-gateway-mode", candidate_type, candidate.component)
                return

            log(self.session_id, "local-ice", candidate_type, candidate.component)
            await self.send_json(
                {
                    "type": "ice-candidate",
                    "sessionId": self.session_id,
                    "candidate": {
                        "candidate": candidate_sdp,
                        "sdpMid": candidate.sdpMid,
                        "sdpMLineIndex": candidate.sdpMLineIndex,
                        "type": candidate_type,
                    },
                }
            )

        @pc.on("connectionstatechange")
        async def on_connectionstatechange():
            state = pc.connectionState
            self.last_connection_state = state
            self.last_signaling_state = pc.signalingState
            log(self.session_id, "connection-state", state)
            if state == "connected":
                if self.video_sender_tuning_task is None or self.video_sender_tuning_task.done():
                    self.video_sender_tuning_task = asyncio.create_task(
                        self.tune_video_sender("connected")
                    )
                if self.post_connect_kick_task is None or self.post_connect_kick_task.done():
                    self.post_connect_kick_task = asyncio.create_task(
                        self.kick_visible_repaint_after_connect()
                    )
                self.browser.schedule_media_playback_nudges("connected")
            await self.send_worker_state(
                "streaming" if state == "connected" else state,
                f"connection-state:{state}",
                refresh_page=True,
            )
            self.publish_media_relay_state(f"connection-state:{state}")

        @pc.on("icegatheringstatechange")
        async def on_icegatheringstatechange():
            state = pc.iceGatheringState
            self.last_ice_gathering_state = state
            log(self.session_id, "ice-gathering-state", state)
            if state == "complete":
                self.ice_gathering_complete.set()
            self.publish_media_relay_state(f"ice-gathering-state:{state}")

        @pc.on("iceconnectionstatechange")
        async def on_iceconnectionstatechange():
            state = pc.iceConnectionState
            self.last_ice_connection_state = state
            self.last_signaling_state = pc.signalingState
            log(self.session_id, "ice-connection-state", state)
            self.publish_media_relay_state(f"ice-connection-state:{state}")
            if state in {"disconnected", "failed"}:
                await self.attempt_local_media_recovery(f"ice-state:{state}")

        for label in self.input_channel_create_order():
            if label == self.input_pointer_channel_name:
                channel = pc.createDataChannel(label, ordered=False, maxRetransmits=0)
            else:
                channel = pc.createDataChannel(label)
            self.register_input_channel(channel, "local")

        @pc.on("datachannel")
        def on_datachannel(channel):
            self.register_input_channel(channel, "remote")

        (
            self.video_player,
            self.source_coupled_capture,
            self.video_track,
            self.audio_track,
        ) = await self.build_media_capture_pipeline()
        self.video_transceiver = pc.addTransceiver(self.video_track, direction="sendonly")
        self.configure_video_sender_preferences()

        if self.audio_track is not None:
            self.audio_sender = pc.addTrack(self.audio_track)
        else:
            log(self.session_id, "audio-track-missing", PULSE_SOURCE_NAME)
        return pc

    async def signaling_loop(self) -> None:
        await self.browser.navigate(self.target_url)
        self.pc = await self.setup_peer_connection()
        self.start_media_relay_bridge()

        try:
            async with websockets.connect(
                self.signaling_url,
                max_size=4 * 1024 * 1024,
                ping_interval=None,
                **build_websocket_connect_kwargs(
                    self.signaling_connect_host, self.signaling_url
                ),
            ) as websocket:
                self.ws = websocket
                self.heartbeat_task = asyncio.create_task(self.heartbeat_loop())
                self.media_diagnostics_task = asyncio.create_task(self.media_diagnostics_loop())
                self.page_state_task = asyncio.create_task(self.page_state_loop())
                log(
                    self.session_id,
                    "connected-signaling",
                    self.signaling_url,
                    f"via={self.signaling_connect_host or 'dns'}",
                )
                await self.send_json(
                    {
                        "type": "register",
                        "role": "worker",
                        "sessionId": self.session_id,
                        "token": self.worker_token,
                    }
                )

                focus_browser(force=True)
                await self.send_worker_state("ready", "registered", refresh_page=True)
                self.publish_media_relay_state("ready")

                await self.send_offer("initial")

                async for raw in websocket:
                    message = json.loads(raw)
                    message_type = message.get("type")
                    log(self.session_id, "recv", message_type)

                    if message_type == "registered":
                        continue

                    if message_type == "heartbeat-ack":
                        continue

                    if message_type == "session-terminated":
                        return

                    if self.gateway_webrtc_relay_enabled and message_type in {
                        "sdp-offer",
                        "sdp-answer",
                        "ice-candidate",
                    }:
                        log(self.session_id, "ignore-legacy-webrtc-signal", message_type)
                        continue

                    if message_type == "sdp-offer":
                        self.ice_gathering_complete.clear()
                        await self.pc.setRemoteDescription(
                            RTCSessionDescription(
                                sdp=filter_sdp_candidates(message["sdp"], self.allowed_candidate_types),
                                type="offer",
                            )
                        )
                        answer = await self.pc.createAnswer()
                        await self.pc.setLocalDescription(answer)
                        try:
                            await asyncio.wait_for(self.ice_gathering_complete.wait(), timeout=5)
                        except asyncio.TimeoutError:
                            log(self.session_id, "ice-gathering-timeout", "answer")
                        filtered_answer = filter_sdp_candidates(
                            self.pc.localDescription.sdp or answer.sdp or "",
                            self.allowed_candidate_types,
                        )
                        filtered_answer = apply_video_bitrate_hints_to_sdp(filtered_answer)
                        await self.send_json(
                            {
                                "type": "sdp-answer",
                                "sessionId": self.session_id,
                                "sdp": filtered_answer,
                            }
                        )
                        log(self.session_id, "set-remote-description", "offer")
                        await self.flush_pending_offer()
                        continue

                    if message_type == "sdp-answer":
                        await self.pc.setRemoteDescription(
                            RTCSessionDescription(
                                sdp=filter_sdp_candidates(message["sdp"], self.allowed_candidate_types),
                                type="answer",
                            )
                        )
                        log(self.session_id, "set-remote-description", "answer")
                        await self.flush_pending_offer()
                        continue

                    if message_type == "ice-restart-request":
                        requested_reason = truncate_for_log(
                            message.get("reason") or "viewer-request",
                            160,
                        )
                        log(self.session_id, "ice-restart-request-reason", requested_reason)
                        await self.attempt_local_media_recovery(
                            f"viewer-ice-restart:{requested_reason}"
                        )
                        await self.send_offer("ice-restart-request")
                        continue

                    if message_type == "ice-candidate":
                        candidate_data = message.get("candidate")
                        if not candidate_data or not candidate_data.get("candidate"):
                            continue
                        raw_candidate = candidate_data["candidate"]
                        if not is_allowed_candidate(raw_candidate, self.allowed_candidate_types):
                            log(
                                self.session_id,
                                "skip-remote-ice",
                                candidate_data.get("type") or extract_candidate_type(raw_candidate),
                            )
                            continue
                        if raw_candidate.startswith("candidate:"):
                            raw_candidate = raw_candidate[len("candidate:") :]
                        candidate = candidate_from_sdp(raw_candidate)
                        candidate.sdpMid = candidate_data.get("sdpMid")
                        candidate.sdpMLineIndex = candidate_data.get("sdpMLineIndex")
                        await self.pc.addIceCandidate(candidate)
                        log(self.session_id, "added-remote-ice", candidate.type, candidate.component)
                        continue

                    if message_type == "hybrid-dom-request":
                        request_id = str(message.get("requestId") or "")
                        try:
                            payload = await self.handle_hybrid_dom_request(message)
                            await self.send_json(
                                {
                                    "type": "hybrid-dom-response",
                                    "sessionId": self.session_id,
                                    "requestId": request_id,
                                    "ok": True,
                                    "payload": payload,
                                }
                            )
                        except Exception as error:
                            await self.send_json(
                                {
                                    "type": "hybrid-dom-response",
                                    "sessionId": self.session_id,
                                    "requestId": request_id,
                                    "ok": False,
                                    "error": str(error),
                                }
                            )
                        continue

                    if message_type == "error":
                        raise RuntimeError(message.get("message", "Signaling error"))
        except ConnectionClosed as error:
            log(
                self.session_id,
                "signaling-closed",
                f"code={getattr(error, 'code', 'unknown')}",
                f"reason={getattr(error, 'reason', '') or 'none'}",
            )
            raise

    async def close(self) -> None:
        if self.media_relay_task is not None:
            self.media_relay_task.cancel()
            await asyncio.gather(self.media_relay_task, return_exceptions=True)
            self.media_relay_task = None
        if self.media_relay_bridge is not None:
            await self.media_relay_bridge.close()
            self.media_relay_bridge = None
        if self.hybrid_dom_snapshot_task is not None:
            self.hybrid_dom_snapshot_task.cancel()
            await asyncio.gather(self.hybrid_dom_snapshot_task, return_exceptions=True)
            self.hybrid_dom_snapshot_task = None
        if self.heartbeat_task is not None:
            self.heartbeat_task.cancel()
            await asyncio.gather(self.heartbeat_task, return_exceptions=True)
            self.heartbeat_task = None
        if self.video_sender_tuning_task is not None:
            self.video_sender_tuning_task.cancel()
            await asyncio.gather(self.video_sender_tuning_task, return_exceptions=True)
            self.video_sender_tuning_task = None
        if self.media_diagnostics_task is not None:
            self.media_diagnostics_task.cancel()
            await asyncio.gather(self.media_diagnostics_task, return_exceptions=True)
            self.media_diagnostics_task = None
        if self.page_state_task is not None:
            self.page_state_task.cancel()
            await asyncio.gather(self.page_state_task, return_exceptions=True)
            self.page_state_task = None
        await self.flush_input_acks()
        for task_name in (
            "input_ack_timer_task",
            "input_ack_flush_task",
            "input_processor_task",
            "interaction_restore_task",
        ):
            task = getattr(self, task_name)
            if task is not None:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
                setattr(self, task_name, None)
        self.input_channels.clear()
        if self.pc is not None:
            await self.pc.close()
            self.pc = None
        self.audio_sender = None
        if self.audio_track is not None:
            self.audio_track.stop()
            self.audio_track = None
        self.stop_media_capture_pipeline()
        self.video_track = None
        self.video_transceiver = None
        self.video_sender_tuned = False
        self.video_player = None
        self.source_coupled_capture = None

    async def run(self) -> None:
        try:
            await self.signaling_loop()
        finally:
            await self.close()


async def run_pool_worker() -> None:
    global XINPUT
    worker_id, task_arn = detect_pool_worker_identity()
    browser = ChromiumController(DISPLAY_WIDTH, DISPLAY_HEIGHT)
    await browser.ensure_started()

    metadata = {
        "mode": "warm-pool",
        "taskArn": task_arn,
        "region": WORKER_REGION,
        "runtimeClass": WORKER_RUNTIME_CLASS,
        "mediaMode": WORKER_MEDIA_MODE,
        "imageDigest": WORKER_IMAGE_DIGEST,
        "displayClass": f"{DISPLAY_WIDTH}x{DISPLAY_HEIGHT}",
        "displayWidth": DISPLAY_WIDTH,
        "displayHeight": DISPLAY_HEIGHT,
    }

    try:
        while not SHUTDOWN.is_set():
            try:
                async with websockets.connect(
                    POOL_WS_URL,
                    max_size=4 * 1024 * 1024,
                    ping_interval=None,
                    **build_websocket_connect_kwargs(POOL_WS_CONNECT_HOST, POOL_WS_URL),
                ) as websocket:
                    async def pool_heartbeat_loop() -> None:
                        while not SHUTDOWN.is_set():
                            await asyncio.sleep(SIGNALING_HEARTBEAT_INTERVAL)
                            await websocket.send(
                                json.dumps(
                                    {
                                        "type": "heartbeat",
                                        "workerId": worker_id,
                                        "role": "pool-worker",
                                        "ts": int(asyncio.get_running_loop().time() * 1000),
                                    }
                                )
                            )

                    heartbeat_task = asyncio.create_task(pool_heartbeat_loop())
                    log(
                        "pool-connected",
                        POOL_WS_URL,
                        f"via={POOL_WS_CONNECT_HOST or 'dns'}",
                        worker_id,
                    )
                    await websocket.send(
                        json.dumps(
                            {
                                "type": "pool-register",
                                "workerId": worker_id,
                                "secret": POOL_SHARED_SECRET,
                                "taskArn": task_arn,
                                "metadata": metadata,
                            }
                        )
                    )
                    await websocket.send(
                        json.dumps(
                            {
                                "type": "pool-state",
                                "workerId": worker_id,
                                "state": "idle",
                                "metadata": metadata,
                            }
                        )
                    )
                    try:
                        async for raw in websocket:
                            message = json.loads(raw)
                            message_type = message.get("type")
                            log("pool-recv", message_type)

                            if message_type == "registered":
                                continue

                            if message_type == "heartbeat-ack":
                                continue

                            if message_type == "session-assignment":
                                session_assignment = {
                                    "sessionId": message["sessionId"],
                                    "targetUrl": message["targetUrl"],
                                    "signalingUrl": message["signalingUrl"],
                                    "signalingConnectHost": message.get(
                                        "signalingConnectHost",
                                        POOL_WS_CONNECT_HOST or SIGNALING_CONNECT_HOST,
                                    ),
                                    "mediaRelayUrl": message.get("mediaRelayUrl", MEDIA_RELAY_URL),
                                    "mediaRelayConnectHost": message.get(
                                        "mediaRelayConnectHost",
                                        MEDIA_RELAY_CONNECT_HOST,
                                    ),
                                    "mediaGatewayUrl": message.get("mediaGatewayUrl", MEDIA_GATEWAY_URL),
                                    "mediaPlaneMode": message.get("mediaPlaneMode", MEDIA_PLANE_MODE),
                                    "mediaRelayProtocol": message.get(
                                        "mediaRelayProtocol",
                                        MEDIA_RELAY_PROTOCOL,
                                    ),
                                    "workerToken": message["workerToken"],
                                    "displayWidth": message.get("displayWidth", DISPLAY_WIDTH),
                                    "displayHeight": message.get("displayHeight", DISPLAY_HEIGHT),
                                    "turnUsername": message.get("turnUsername", ""),
                                    "turnPassword": message.get("turnPassword", ""),
                                    "workerIceUrls": message.get("workerIceUrls", []),
                                    "allowedCandidateTypes": message.get("allowedCandidateTypes", []),
                                    "iceTransportPolicy": message.get("iceTransportPolicy", ""),
                                    "transport": message.get("transport", {}),
                                    "workerBridge": message.get("workerBridge", {}),
                                    "experiments": message.get("experiments", {}),
                                }
                                await websocket.send(
                                    json.dumps(
                                        {
                                            "type": "pool-state",
                                            "workerId": worker_id,
                                            "state": "busy",
                                            "sessionId": session_assignment["sessionId"],
                                            "metadata": metadata,
                                        }
                                    )
                                )
                                runtime = SessionRuntime(session_assignment, browser)
                                last_session_id = session_assignment["sessionId"]
                                try:
                                    await runtime.run()
                                except Exception as exc:
                                    log(last_session_id, "session-runtime-error", repr(exc))
                                if SHUTDOWN.is_set():
                                    return
                                await browser.stop()
                                if POOL_RECYCLE_AFTER_SESSION:
                                    log(last_session_id, "pool-recycle-after-session", worker_id)
                                    return
                                await browser.ensure_started()
                                await websocket.send(
                                    json.dumps(
                                        {
                                            "type": "pool-state",
                                            "workerId": worker_id,
                                            "state": "idle",
                                            "lastSessionId": last_session_id,
                                            "metadata": metadata,
                                        }
                                    )
                                )
                                continue

                            if message_type == "error":
                                raise RuntimeError(message.get("message", "Pool worker error"))
                    finally:
                        heartbeat_task.cancel()
                        await asyncio.gather(heartbeat_task, return_exceptions=True)
            except Exception as exc:
                if SHUTDOWN.is_set():
                    break
                log("pool-reconnect", worker_id, repr(exc))
                await asyncio.sleep(2)
    finally:
        await browser.stop()
        if XINPUT is not None:
            XINPUT.close()
            XINPUT = None


async def run_single_session() -> None:
    global XINPUT
    browser = ChromiumController(
        int(DEFAULT_SESSION.get("displayWidth", DISPLAY_WIDTH)),
        int(DEFAULT_SESSION.get("displayHeight", DISPLAY_HEIGHT)),
    )
    try:
        await browser.ensure_started()
        runtime = SessionRuntime(DEFAULT_SESSION, browser)
        await runtime.run()
    finally:
        await browser.stop()
        if XINPUT is not None:
            XINPUT.close()
            XINPUT = None


async def main() -> None:
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, SHUTDOWN.set)

    if WORKER_MODE == "pool":
        await run_pool_worker()
    else:
        await run_single_session()


if __name__ == "__main__":
    asyncio.run(main())
