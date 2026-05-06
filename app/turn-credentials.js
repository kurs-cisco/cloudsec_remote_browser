import crypto from "node:crypto";

function base64(value) {
  return value.toString("base64");
}

export function buildTurnRestCredentials({
  sessionId,
  role,
  secret,
  ttlSeconds,
  now = Date.now(),
}) {
  if (!secret) {
    throw new Error("TURN shared secret is not configured");
  }
  const expiresAtEpoch = Math.floor(now / 1000) + Math.max(30, Number(ttlSeconds) || 300);
  const opaqueUser = [role, sessionId].filter(Boolean).join(".");
  const username = `${expiresAtEpoch}:${opaqueUser}`;
  const credential = base64(
    crypto.createHmac("sha1", secret).update(username).digest(),
  );
  return {
    username,
    credential,
    expiresAtEpoch,
  };
}
