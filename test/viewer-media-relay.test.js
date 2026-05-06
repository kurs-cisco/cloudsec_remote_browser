import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

async function loadViewerMediaRelayHelpers() {
  const source = await readFile(
    fileURLToPath(new URL("../viewer/viewer.js", import.meta.url)),
    "utf8",
  );
  const match = source.match(
    /\/\/ Viewer media relay helpers BEGIN\n(?<helpers>[\s\S]*?)\/\/ Viewer media relay helpers END/,
  );
  assert.ok(match?.groups?.helpers, "viewer media relay helper block must be present");

  return vm.runInNewContext(
    `
      const VIEWER_MEDIA_RELAY_MODE = "gateway-media-relay";
      const VIEWER_GATEWAY_WEBRTC_RELAY_MODE = "gateway-webrtc-relay";
      const VIEWER_GATEWAY_WEBRTC_SRTP_PROTOCOL = "webrtc-srtp";
      const INPUT_POINTER_CHANNEL_LABEL = "input-pointer";
      const INPUT_CONTROL_CHANNEL_LABEL = "input-control";
      ${match.groups.helpers}
      ({
        buildViewerMediaRelayConfig,
        buildViewerMediaRelayRegisterMessage,
        buildViewerGatewayOfferRequest,
        buildViewerGatewayOfferUrl,
        buildViewerGatewayWebrtcConfig,
        extractViewerGatewayAnswerSdp,
        isViewerMediaRelayCanaryAllowed,
      });
    `,
    { URL },
  );
}

test("viewer media relay config enables only explicit gateway-media-relay canaries", async () => {
  const { buildViewerMediaRelayConfig } = await loadViewerMediaRelayHelpers();
  const config = buildViewerMediaRelayConfig({
    transport: {
      mediaRelayUrl: "wss://gateway.example.com/gateway/media/sess_123/viewer",
      mediaTermination: {
        mode: "gateway-media-relay",
        gatewayTerminatesMedia: true,
      },
    },
  });

  assert.deepEqual(plain(config), {
    enabled: true,
    mode: "gateway-media-relay",
    mediaRelayUrl: "wss://gateway.example.com/gateway/media/sess_123/viewer",
    gatewayTerminatesMedia: true,
    canaryOnly: true,
    replaceWebRtc: false,
    reason: "gateway-media-relay-canary",
  });
});

test("viewer media relay config keeps default signaling-only sessions on WebRTC", async () => {
  const { buildViewerMediaRelayConfig } = await loadViewerMediaRelayHelpers();
  const config = buildViewerMediaRelayConfig({
    transport: {
      mediaRelayUrl: "wss://gateway.example.com/gateway/media/sess_123/viewer",
      mediaTermination: {
        mode: "signaling-relay-only",
        gatewayTerminatesMedia: false,
      },
    },
  });

  assert.equal(config.enabled, false);
  assert.equal(config.reason, "media-termination-not-gateway-media-relay");
  assert.equal(config.replaceWebRtc, false);
});

test("viewer media relay config rejects invalid relay URLs", async () => {
  const { buildViewerMediaRelayConfig } = await loadViewerMediaRelayHelpers();
  const config = buildViewerMediaRelayConfig({
    transport: {
      mediaRelayUrl: "https://gateway.example.com/gateway/media/sess_123/viewer",
      mediaTermination: {
        mode: "gateway-media-relay",
        gatewayTerminatesMedia: true,
      },
    },
  });

  assert.equal(config.enabled, false);
  assert.equal(config.reason, "missing-media-relay-url");
  assert.equal(config.mediaRelayUrl, "");
});

test("viewer media relay canary gate can be disabled from query params", async () => {
  const { buildViewerMediaRelayConfig, isViewerMediaRelayCanaryAllowed } =
    await loadViewerMediaRelayHelpers();
  const searchParams = new URLSearchParams("mediaRelay=off");
  const canaryEnabled = isViewerMediaRelayCanaryAllowed(searchParams);
  const config = buildViewerMediaRelayConfig(
    {
      transport: {
        mediaRelayUrl: "wss://gateway.example.com/gateway/media/sess_123/viewer",
        mediaTermination: {
          mode: "gateway-media-relay",
          gatewayTerminatesMedia: true,
        },
      },
    },
    { canaryEnabled },
  );

  assert.equal(canaryEnabled, false);
  assert.equal(config.enabled, false);
  assert.equal(config.reason, "viewer-media-relay-canary-disabled");
});

test("viewer media relay register message matches gateway websocket contract", async () => {
  const { buildViewerMediaRelayRegisterMessage } = await loadViewerMediaRelayHelpers();

  assert.deepEqual(plain(buildViewerMediaRelayRegisterMessage("sess_123", "viewer-token")), {
    type: "register",
    role: "viewer",
    sessionId: "sess_123",
    token: "viewer-token",
  });
});

test("viewer gateway webrtc config enables only gateway-webrtc-relay over webrtc-srtp", async () => {
  const { buildViewerGatewayWebrtcConfig } = await loadViewerMediaRelayHelpers();
  const config = buildViewerGatewayWebrtcConfig({
    transport: {
      mediaGatewayUrl: "https://gateway.example.com/gateway/webrtc/sess_123/viewer",
      mediaPlaneMode: "gateway-webrtc-relay",
      protocol: "webrtc-srtp",
    },
  });

  assert.deepEqual(plain(config), {
    enabled: true,
    mediaPlaneMode: "gateway-webrtc-relay",
    protocol: "webrtc-srtp",
    mediaGatewayUrl: "https://gateway.example.com/gateway/webrtc/sess_123/viewer",
    offerUrl: "https://gateway.example.com/gateway/webrtc/sess_123/viewer/offer",
    inputPointerName: "input-pointer",
    inputControlName: "input-control",
    reason: "gateway-webrtc-relay",
  });
});

test("viewer gateway webrtc config preserves existing offer URLs", async () => {
  const { buildViewerGatewayOfferUrl } = await loadViewerMediaRelayHelpers();

  assert.equal(
    buildViewerGatewayOfferUrl("https://gateway.example.com/gateway/webrtc/sess_123/viewer/offer"),
    "https://gateway.example.com/gateway/webrtc/sess_123/viewer/offer",
  );
});

test("viewer gateway webrtc config rejects non-gateway media plane sessions", async () => {
  const { buildViewerGatewayWebrtcConfig } = await loadViewerMediaRelayHelpers();
  const config = buildViewerGatewayWebrtcConfig({
    transport: {
      mediaGatewayUrl: "https://gateway.example.com/gateway/webrtc/sess_123/viewer",
      mediaPlaneMode: "gateway-relay",
      protocol: "webrtc-srtp",
    },
  });

  assert.equal(config.enabled, false);
  assert.equal(config.reason, "media-plane-not-gateway-webrtc-relay");
});

test("viewer gateway offer request and response helpers match SDP answer contract", async () => {
  const { buildViewerGatewayOfferRequest, extractViewerGatewayAnswerSdp } =
    await loadViewerMediaRelayHelpers();

  assert.deepEqual(
    plain(buildViewerGatewayOfferRequest("sess_123", "viewer-token", "v=0\\r\\n")),
    {
      type: "offer",
      role: "viewer",
      sessionId: "sess_123",
      token: "viewer-token",
      sdp: "v=0\\r\\n",
    },
  );
  assert.equal(
    extractViewerGatewayAnswerSdp({ answer: { sdp: "v=0\\r\\na=answer\\r\\n" } }),
    "v=0\\r\\na=answer\\r\\n",
  );
});
