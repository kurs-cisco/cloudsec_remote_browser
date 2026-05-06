import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

async function loadWorkerGatewayHelperBlock() {
  const source = await readFile(
    fileURLToPath(new URL("../worker/worker.py", import.meta.url)),
    "utf8",
  );
  const match = source.match(
    /# Worker gateway WebRTC helpers BEGIN\n(?<helpers>[\s\S]*?)# Worker gateway WebRTC helpers END/,
  );
  assert.ok(match?.groups?.helpers, "worker gateway helper block must be present");
  return match.groups.helpers;
}

test("worker gateway helpers normalize offer URL, answer SDP, and VP8 preference", async () => {
  const helpers = await loadWorkerGatewayHelperBlock();
  const script = `
import json
import urllib.parse
from typing import List

GATEWAY_WEBRTC_RELAY_MODE = "gateway-webrtc-relay"
GATEWAY_WEBRTC_SRTP_PROTOCOL = "webrtc-srtp"

${helpers}

assert build_media_gateway_offer_url("https://gateway.example.com/gateway/webrtc/sess_123/worker") == "https://gateway.example.com/gateway/webrtc/sess_123/worker/offer"
assert build_media_gateway_offer_url("https://gateway.example.com/gateway/webrtc/sess_123/worker/offer") == "https://gateway.example.com/gateway/webrtc/sess_123/worker/offer"
assert is_gateway_webrtc_relay_config("https://gateway.example.com/gateway/webrtc/sess_123/worker", "gateway-webrtc-relay", "webrtc-srtp")
assert not is_gateway_webrtc_relay_config("wss://gateway.example.com/gateway/webrtc/sess_123/worker", "gateway-webrtc-relay", "webrtc-srtp")
assert extract_gateway_answer_sdp({"answer": {"sdp": "v=0\\r\\n"}}) == "v=0\\r\\n"
assert gateway_video_codec_preferences(["H264", "VP8"]) == ["VP8"]
print(json.dumps({"ok": True}))
	`;

  const { stdout } = await execFileAsync("python3", ["-c", script]);
  assert.deepEqual(JSON.parse(stdout), { ok: true });
});

test("worker media tuning defaults stay env-compatible", async () => {
  const workerSource = await readFile(
    fileURLToPath(new URL("../worker/worker.py", import.meta.url)),
    "utf8",
  );
  const startScript = await readFile(
    fileURLToPath(new URL("../worker/start-browser.sh", import.meta.url)),
    "utf8",
  );

  assert.match(workerSource, /CAPTURE_FRAMERATE = .*os\.environ\.get\("CAPTURE_FRAMERATE", "20"\)/);
  assert.match(workerSource, /INITIAL_STREAM_SCALE = .*os\.environ\.get\("INITIAL_STREAM_SCALE", "1\.0"\)/);
  assert.match(workerSource, /os\.environ\.get\("VIDEO_CODEC_PREFERENCES", "VP8"\)/);
  assert.match(workerSource, /VIDEO_MIN_BITRATE_BPS = .*os\.environ\.get\("VIDEO_MIN_BITRATE_BPS", "600000"\)/);
  assert.match(workerSource, /"VIDEO_START_BITRATE_BPS", "1500000"/);
  assert.match(workerSource, /"VIDEO_MAX_BITRATE_BPS", "3000000"/);
  assert.ok(workerSource.includes('float(os.environ.get("INTERACTION_MODE_HOLD_SEC", "2"))'));
  assert.ok(workerSource.includes('int(os.environ.get("INTERACTION_CAPTURE_FRAMERATE", str(max(8, min(CAPTURE_FRAMERATE, 12)))))'));
  assert.ok(workerSource.includes("min(VIDEO_START_BITRATE_BPS, 800_000)"));

  assert.match(startScript, /export DISPLAY_WIDTH="\$\{DISPLAY_WIDTH:-1280\}"/);
  assert.match(startScript, /export DISPLAY_HEIGHT="\$\{DISPLAY_HEIGHT:-720\}"/);
  assert.match(startScript, /export CAPTURE_FRAMERATE="\$\{CAPTURE_FRAMERATE:-20\}"/);
  assert.match(startScript, /export VIDEO_MIN_BITRATE_BPS="\$\{VIDEO_MIN_BITRATE_BPS:-600000\}"/);
  assert.match(startScript, /export VIDEO_START_BITRATE_BPS="\$\{VIDEO_START_BITRATE_BPS:-1500000\}"/);
  assert.match(startScript, /export VIDEO_MAX_BITRATE_BPS="\$\{VIDEO_MAX_BITRATE_BPS:-3000000\}"/);
});
