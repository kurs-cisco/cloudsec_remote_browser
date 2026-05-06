import test from "node:test";
import assert from "node:assert/strict";

import { verifySessionToken } from "../app/session-token.js";
import { signToken, verifyToken } from "../app/token.js";

test("token roundtrip preserves payload", () => {
  const token = signToken(
    {
      sessionId: "sess_123",
      role: "viewer",
      exp: Date.now() + 5_000,
    },
    "secret",
  );

  const payload = verifyToken(token, "secret");
  assert.equal(payload.sessionId, "sess_123");
  assert.equal(payload.role, "viewer");
});

test("token verification rejects invalid signature", () => {
  const token = signToken(
    {
      sessionId: "sess_123",
      role: "viewer",
      exp: Date.now() + 5_000,
    },
    "secret",
  );

  assert.throws(() => verifyToken(`${token}broken`, "secret"));
});

test("token verification rejects token with appended characters (length mismatch)", () => {
  const token = signToken(
    {
      sessionId: "sess_123",
      role: "viewer",
      exp: Date.now() + 5_000,
    },
    "secret",
  );

  const [body, sig] = token.split(".");
  const tampered = `${body}.${sig}extra`;
  assert.throws(() => verifyToken(tampered, "secret"), /Invalid token signature/);
});

test("token verification rejects truncated signature (length mismatch)", () => {
  const token = signToken(
    {
      sessionId: "sess_123",
      role: "viewer",
      exp: Date.now() + 5_000,
    },
    "secret",
  );

  const [body, sig] = token.split(".");
  const tampered = `${body}.${sig.slice(0, -4)}`;
  assert.throws(() => verifyToken(tampered, "secret"), /Invalid token signature/);
});

test("stored session token is accepted even if local secret changed", () => {
  const session = {
    id: "sess_123",
    expiresAt: Date.now() + 5_000,
    workerToken: signToken(
      {
        sessionId: "sess_123",
        role: "worker",
        exp: Date.now() + 5_000,
      },
      "old-secret",
    ),
  };

  const payload = verifySessionToken({
    token: session.workerToken,
    session,
    role: "worker",
    secret: "new-secret",
  });

  assert.equal(payload.sessionId, "sess_123");
  assert.equal(payload.role, "worker");
  assert.equal(payload.source, "stored-session-token");
});

test("signed worker token is rejected when session generation has advanced", () => {
  const token = signToken(
    {
      sessionId: "sess_123",
      role: "worker",
      exp: Date.now() + 5_000,
      generation: 1,
    },
    "secret",
  );

  assert.throws(
    () =>
      verifySessionToken({
        token,
        session: {
          id: "sess_123",
          expiresAt: Date.now() + 5_000,
          generation: 2,
          workerToken: "different-token",
        },
        role: "worker",
        secret: "secret",
      }),
    /Stale worker token/,
  );
});

test("legacy signed worker token without generation is accepted only for generation 1 sessions", () => {
  const token = signToken(
    {
      sessionId: "sess_123",
      role: "worker",
      exp: Date.now() + 5_000,
    },
    "secret",
  );

  const payload = verifySessionToken({
    token,
    session: {
      id: "sess_123",
      expiresAt: Date.now() + 5_000,
      generation: 1,
      workerToken: "different-token",
    },
    role: "worker",
    secret: "secret",
  });

  assert.equal(payload.sessionId, "sess_123");
  assert.equal(payload.role, "worker");
  assert.equal(payload.source, "signed-token");
});
