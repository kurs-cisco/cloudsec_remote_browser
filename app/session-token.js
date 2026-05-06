import crypto from "node:crypto";

import { verifyToken } from "./token.js";

function timingSafeEqualString(left, right) {
  const leftValue = Buffer.from(String(left || ""), "utf8");
  const rightValue = Buffer.from(String(right || ""), "utf8");
  if (!leftValue.length || leftValue.length !== rightValue.length) {
    return false;
  }
  return crypto.timingSafeEqual(leftValue, rightValue);
}

function getStoredToken(session, role) {
  if (role === "viewer") {
    return String(session?.viewerToken || "");
  }
  if (role === "worker") {
    return String(session?.workerToken || "");
  }
  return "";
}

export function verifySessionToken({ token, session, role, secret }) {
  const normalizedToken = String(token || "");
  if (!normalizedToken) {
    throw new Error("Missing token");
  }

  const sessionId = String(session?.id || "");
  if (!sessionId) {
    throw new Error("Session not found");
  }

  const storedToken = getStoredToken(session, role);
  if (storedToken && timingSafeEqualString(normalizedToken, storedToken)) {
    return {
      role,
      sessionId,
      exp: session?.expiresAt || null,
      source: "stored-session-token",
    };
  }

  const payload = verifyToken(normalizedToken, secret);
  if (payload.role !== role || payload.sessionId !== sessionId) {
    throw new Error("Invalid session token");
  }
  if (role === "worker") {
    const sessionGeneration = Number(session?.generation || 1);
    const payloadGeneration = Number(payload.generation);
    if (!Number.isFinite(payloadGeneration)) {
      if (sessionGeneration !== 1) {
        throw new Error("Stale worker token");
      }
    } else if (payloadGeneration !== sessionGeneration) {
      throw new Error("Stale worker token");
    }
  }
  return {
    ...payload,
    source: "signed-token",
  };
}
