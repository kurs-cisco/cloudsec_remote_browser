import crypto from "node:crypto";

function base64UrlEncode(input) {
  return Buffer.from(input)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function base64UrlDecode(input) {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const padding = normalized.length % 4 === 0 ? "" : "=".repeat(4 - (normalized.length % 4));
  return Buffer.from(normalized + padding, "base64").toString("utf8");
}

export function signToken(payload, secret) {
  const body = base64UrlEncode(JSON.stringify(payload));
  const signature = crypto
    .createHmac("sha256", secret)
    .update(body)
    .digest("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
  return `${body}.${signature}`;
}

export function verifyToken(token, secret) {
  const [body, signature] = String(token || "").split(".");
  if (!body || !signature) {
    throw new Error("Malformed token");
  }

  const expected = crypto
    .createHmac("sha256", secret)
    .update(body)
    .digest("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");

  let left = Buffer.from(signature);
  let right = Buffer.from(expected);
  const maxLen = Math.max(left.length, right.length);
  if (left.length < maxLen) {
    const padded = Buffer.alloc(maxLen, 0);
    left.copy(padded);
    left = padded;
  }
  if (right.length < maxLen) {
    const padded = Buffer.alloc(maxLen, 0);
    right.copy(padded);
    right = padded;
  }
  const lengthMatch = Buffer.from(signature).length === Buffer.from(expected).length;
  if (!lengthMatch || !crypto.timingSafeEqual(left, right)) {
    throw new Error("Invalid token signature");
  }

  const payload = JSON.parse(base64UrlDecode(body));
  if (payload.exp && Date.now() > payload.exp) {
    throw new Error("Token expired");
  }

  return payload;
}

