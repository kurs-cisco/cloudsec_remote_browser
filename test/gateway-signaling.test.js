import test from "node:test";
import assert from "node:assert/strict";

import {
  buildGatewaySignalingUrl,
  buildGatewayViewerUrl,
  parseGatewaySignalingPath,
  parseGatewayViewerPath,
  usesGatewaySignaling,
} from "../shared/gateway-signaling.js";

test("gateway signaling URL derives from ws base path", () => {
  const url = buildGatewaySignalingUrl(
    "wss://gateway.example.com/rbi/ws",
    "sess_123",
    "viewer",
    { relay: "gateway-relay" },
  );
  assert.equal(
    url,
    "wss://gateway.example.com/rbi/gateway/signaling/sess_123/viewer?relay=gateway-relay",
  );
});

test("gateway viewer URL derives from base path", () => {
  const url = buildGatewayViewerUrl("https://gateway.example.com/rbi", "sess_123");
  assert.equal(url, "https://gateway.example.com/rbi/gateway/viewer/sess_123");
});

test("gateway path parsers recognize viewer and worker routes", () => {
  assert.deepEqual(parseGatewaySignalingPath("/gateway/signaling/sess_123/viewer"), {
    sessionId: "sess_123",
    role: "viewer",
  });
  assert.deepEqual(parseGatewaySignalingPath("/gateway/signaling/sess_123/worker"), {
    sessionId: "sess_123",
    role: "worker",
  });
  assert.deepEqual(parseGatewayViewerPath("/gateway/viewer/sess_123"), {
    sessionId: "sess_123",
  });
});

test("usesGatewaySignaling checks assignment presence", () => {
  assert.equal(
    usesGatewaySignaling({
      sessionPlacement: {
        gatewayAssignment: { gatewayId: "gateway-us-east-1-01" },
      },
    }),
    true,
  );
  assert.equal(usesGatewaySignaling({ sessionPlacement: {} }), false);
});
