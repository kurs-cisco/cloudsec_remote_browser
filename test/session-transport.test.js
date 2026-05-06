import test from "node:test";
import assert from "node:assert/strict";

import {
  normalizeCandidateTypes,
  resolveSessionAllowedCandidateTypes,
  resolveSessionIceTransportPolicy,
} from "../shared/session-transport.js";

test("normalizeCandidateTypes preserves valid unique candidate types", () => {
  assert.deepEqual(
    normalizeCandidateTypes(["relay", "srflx", "relay", "invalid"]),
    ["relay", "srflx"],
  );
});

test("direct sessions preserve configured candidate types and policy", () => {
  const allowed = resolveSessionAllowedCandidateTypes(
    { sessionPlacement: {} },
    ["host", "srflx", "relay"],
  );
  assert.deepEqual(allowed, ["host", "srflx", "relay"]);
  assert.equal(
    resolveSessionIceTransportPolicy(
      { sessionPlacement: {} },
      "all",
      ["host", "srflx", "relay"],
    ),
    "all",
  );
});

test("gateway sessions force relay-only candidate policy", () => {
  const session = {
    sessionPlacement: {
      gatewayAssignment: {
        gatewayId: "gateway-us-east-1-01",
      },
    },
  };
  assert.deepEqual(
    resolveSessionAllowedCandidateTypes(session, ["host", "srflx", "relay"]),
    ["relay"],
  );
  assert.equal(
    resolveSessionIceTransportPolicy(session, "all", ["host", "srflx", "relay"]),
    "relay",
  );
});
