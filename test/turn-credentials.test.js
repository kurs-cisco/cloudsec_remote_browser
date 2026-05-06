import test from "node:test";
import assert from "node:assert/strict";

import { buildTurnRestCredentials } from "../app/turn-credentials.js";

test("buildTurnRestCredentials returns an expiring username and credential", () => {
  const creds = buildTurnRestCredentials({
    sessionId: "sess_123",
    role: "viewer",
    secret: "shared-secret",
    ttlSeconds: 300,
    now: 1_700_000_000_000,
  });

  assert.match(creds.username, /^\d+:viewer\.sess_123$/);
  assert.ok(creds.credential.length > 10);
  assert.equal(creds.expiresAtEpoch, 1_700_000_300);
});
