import crypto from "node:crypto";

export const SWG_HEADERS = {
  signature: "x-cisco-signature",
  timestamp: "x-cisco-timestamp",
  transactionId: "x-cisco-transaction-id",
  contractVersion: "x-cisco-contract-version",
  requestKind: "x-cisco-request-kind",
  originalMethod: "x-cisco-original-method",
  targetUrl: "x-cisco-target-url",
  tenantId: "x-msip-tenant-uuid",
  profileId: "x-msip-profile-id",
  policy: "x-msip-policy",
  provider: "x-cisco-rbi-provider",
  providerCategory: "x-cisco-rbi-provider-category",
  fallbackProvider: "x-cisco-fallback-provider",
  fallbackReason: "x-cisco-fallback-reason",
  upstreamHost: "x-upstream-host",
  upstreamScheme: "x-upstream-scheme",
  upstreamPort: "x-upstream-port",
};

export const SWG_HANDOFF_QUERY = {
  token: "token",
  signature: "signature",
  timestamp: "timestamp",
  transactionId: "transactionId",
  sessionId: "sessionId",
  targetUrl: "targetUrl",
  tenantId: "tenantId",
  profileId: "profileId",
  policy: "policy",
  upstreamHost: "upstreamHost",
  upstreamScheme: "upstreamScheme",
  upstreamPort: "upstreamPort",
};

const SWG_HANDOFF_TOKEN_VERSION = "v1";
const SWG_HANDOFF_AEAD_ALGORITHM = "aes-256-gcm";
const SWG_HANDOFF_AEAD_IV_BYTES = 12;
const SWG_HANDOFF_AEAD_TAG_BYTES = 16;
const SWG_HANDOFF_AEAD_KEY_BYTES = 32;
const SWG_HANDOFF_AEAD_SALT = Buffer.from("cloudsec_remote_browser", "utf8");
const SWG_HANDOFF_AEAD_INFO = Buffer.from("swg-handoff", "utf8");

function normalizeValue(value) {
  return String(value ?? "").trim();
}

function decodeBase64SecretMaterial(secret) {
  const value = normalizeValue(secret);
  if (!value) {
    return null;
  }

  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(normalized) || normalized.length % 4 === 1) {
    return null;
  }

  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
  const decoded = Buffer.from(padded, "base64");
  if (decoded.length < SWG_HANDOFF_AEAD_KEY_BYTES) {
    return null;
  }

  const reencoded = decoded.toString("base64").replace(/=+$/, "");
  if (reencoded !== normalized.replace(/=+$/, "")) {
    return null;
  }

  return decoded;
}

function getSwgSecretMaterial(secret) {
  const value = normalizeValue(secret);
  if (!value) {
    throw new Error("SWG shared secret is required");
  }

  return decodeBase64SecretMaterial(value) || Buffer.from(value, "utf8");
}

function normalizeMethod(value, fallback) {
  return normalizeValue(value || fallback).toUpperCase();
}

function deriveUpstreamDefaults(input) {
  const targetUrl = normalizeValue(input.targetUrl);
  if (!targetUrl) {
    return {
      upstreamHost: "",
      upstreamScheme: "",
      upstreamPort: "",
    };
  }

  try {
    const parsed = new URL(targetUrl);
    const upstreamScheme = parsed.protocol.replace(":", "").toLowerCase();
    return {
      upstreamHost: parsed.hostname,
      upstreamScheme,
      upstreamPort: parsed.port || (upstreamScheme === "https" ? "443" : "80"),
    };
  } catch {
    return {
      upstreamHost: "",
      upstreamScheme: "",
      upstreamPort: "",
    };
  }
}

function normalizeSwgRequestFields(input) {
  const derivedUpstream = deriveUpstreamDefaults(input);
  return {
    method: normalizeMethod(input.method, "POST"),
    contractVersion: normalizeValue(input.contractVersion),
    requestKind: normalizeValue(input.requestKind),
    originalMethod: normalizeMethod(input.originalMethod, ""),
    targetUrl: normalizeValue(input.targetUrl),
    timestamp: normalizeValue(input.timestamp),
    transactionId: normalizeValue(input.transactionId),
    tenantId: normalizeValue(input.tenantId),
    profileId: normalizeValue(input.profileId),
    policy: normalizeValue(input.policy),
    provider: normalizeValue(input.provider),
    providerCategory: normalizeValue(input.providerCategory),
    fallbackProvider: normalizeValue(input.fallbackProvider),
    fallbackReason: normalizeValue(input.fallbackReason),
    upstreamHost: normalizeValue(input.upstreamHost || derivedUpstream.upstreamHost),
    upstreamScheme: normalizeValue(input.upstreamScheme || derivedUpstream.upstreamScheme),
    upstreamPort: normalizeValue(input.upstreamPort || derivedUpstream.upstreamPort),
  };
}

function normalizeSwgHandoffFields(input) {
  const derivedUpstream = deriveUpstreamDefaults(input);
  return {
    method: normalizeMethod(input.method, "GET"),
    sessionId: normalizeValue(input.sessionId),
    targetUrl: normalizeValue(input.targetUrl),
    timestamp: normalizeValue(input.timestamp),
    transactionId: normalizeValue(input.transactionId),
    tenantId: normalizeValue(input.tenantId),
    profileId: normalizeValue(input.profileId),
    policy: normalizeValue(input.policy),
    upstreamHost: normalizeValue(input.upstreamHost || derivedUpstream.upstreamHost),
    upstreamScheme: normalizeValue(input.upstreamScheme || derivedUpstream.upstreamScheme),
    upstreamPort: normalizeValue(input.upstreamPort || derivedUpstream.upstreamPort),
  };
}

function getSwgHandoffAeadKey(secret) {
  return Buffer.from(
    crypto.hkdfSync(
      "sha256",
      getSwgSecretMaterial(secret),
      SWG_HANDOFF_AEAD_SALT,
      SWG_HANDOFF_AEAD_INFO,
      SWG_HANDOFF_AEAD_KEY_BYTES,
    ),
  );
}

function getSwgHandoffAad(version = SWG_HANDOFF_TOKEN_VERSION) {
  return Buffer.from(`swg-handoff:${version}`, "utf8");
}

export function buildSwgCanonicalString(input) {
  const fields = normalizeSwgRequestFields(input);
  const lines = [
    `method:${fields.method}`,
  ];

  if (fields.contractVersion) {
    lines.push(
      `contractVersion:${fields.contractVersion}`,
      `requestKind:${fields.requestKind}`,
      `originalMethod:${fields.originalMethod}`,
    );
  }

  lines.push(
    `targetUrl:${fields.targetUrl}`,
    `timestamp:${fields.timestamp}`,
    `transactionId:${fields.transactionId}`,
    `tenantId:${fields.tenantId}`,
    `profileId:${fields.profileId}`,
    `policy:${fields.policy}`,
  );

  if (fields.contractVersion) {
    lines.push(
      `provider:${fields.provider}`,
      `providerCategory:${fields.providerCategory}`,
      `fallbackProvider:${fields.fallbackProvider}`,
      `fallbackReason:${fields.fallbackReason}`,
    );
  }

  lines.push(
    `upstreamHost:${fields.upstreamHost}`,
    `upstreamScheme:${fields.upstreamScheme}`,
    `upstreamPort:${fields.upstreamPort}`,
  );

  return lines.join("\n");
}

export function buildSwgHandoffCanonicalString(input) {
  const fields = normalizeSwgHandoffFields(input);

  return [
    `method:${fields.method}`,
    `sessionId:${fields.sessionId}`,
    `targetUrl:${fields.targetUrl}`,
    `timestamp:${fields.timestamp}`,
    `transactionId:${fields.transactionId}`,
    `tenantId:${fields.tenantId}`,
    `profileId:${fields.profileId}`,
    `policy:${fields.policy}`,
    `upstreamHost:${fields.upstreamHost}`,
    `upstreamScheme:${fields.upstreamScheme}`,
    `upstreamPort:${fields.upstreamPort}`,
  ].join("\n");
}

export function signSwgRequest(input, secret) {
  return crypto
    .createHmac("sha256", getSwgSecretMaterial(secret))
    .update(buildSwgCanonicalString(input))
    .digest("hex");
}

export function timingSafeEqualHex(left, right) {
  const leftValue = normalizeValue(left);
  const rightValue = normalizeValue(right);
  let leftBuffer = Buffer.from(leftValue, "utf8");
  let rightBuffer = Buffer.from(rightValue, "utf8");
  const maxLen = Math.max(leftBuffer.length, rightBuffer.length);
  if (leftBuffer.length < maxLen) {
    const padded = Buffer.alloc(maxLen, 0);
    leftBuffer.copy(padded);
    leftBuffer = padded;
  }
  if (rightBuffer.length < maxLen) {
    const padded = Buffer.alloc(maxLen, 0);
    rightBuffer.copy(padded);
    rightBuffer = padded;
  }
  if (leftValue.length !== rightValue.length) {
    crypto.timingSafeEqual(leftBuffer, rightBuffer);
    return false;
  }
  return crypto.timingSafeEqual(leftBuffer, rightBuffer);
}

export function verifySwgRequest(input, secret, signature) {
  const expected = signSwgRequest(input, secret);
  return timingSafeEqualHex(expected, signature);
}

export function signSwgHandoffRequest(input, secret) {
  return crypto
    .createHmac("sha256", getSwgSecretMaterial(secret))
    .update(buildSwgHandoffCanonicalString(input))
    .digest("hex");
}

export function verifySwgHandoffRequest(input, secret, signature) {
  const expected = signSwgHandoffRequest(input, secret);
  return timingSafeEqualHex(expected, signature);
}

export function buildOpaqueSwgHandoffToken(input, secret) {
  const fields = normalizeSwgHandoffFields(input);
  const iv = crypto.randomBytes(SWG_HANDOFF_AEAD_IV_BYTES);
  const cipher = crypto.createCipheriv(
    SWG_HANDOFF_AEAD_ALGORITHM,
    getSwgHandoffAeadKey(secret),
    iv,
  );
  cipher.setAAD(getSwgHandoffAad());
  const ciphertext = Buffer.concat([
    cipher.update(JSON.stringify(fields), "utf8"),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();

  return [
    SWG_HANDOFF_TOKEN_VERSION,
    iv.toString("base64url"),
    ciphertext.toString("base64url"),
    tag.toString("base64url"),
  ].join(".");
}

export function decryptSwgHandoffToken(token, secret) {
  const value = normalizeValue(token);
  if (!value) {
    throw new Error("SWG handoff token is required");
  }

  const parts = value.split(".");
  if (parts.length !== 4) {
    throw new Error("Invalid SWG handoff token format");
  }

  const [version, encodedIv, encodedCiphertext, encodedTag] = parts;
  if (version !== SWG_HANDOFF_TOKEN_VERSION) {
    throw new Error(`Unsupported SWG handoff token version: ${version}`);
  }

  const iv = Buffer.from(encodedIv, "base64url");
  const ciphertext = Buffer.from(encodedCiphertext, "base64url");
  const tag = Buffer.from(encodedTag, "base64url");
  if (
    iv.length !== SWG_HANDOFF_AEAD_IV_BYTES ||
    tag.length !== SWG_HANDOFF_AEAD_TAG_BYTES ||
    !ciphertext.length
  ) {
    throw new Error("Invalid SWG handoff token encoding");
  }

  try {
    const decipher = crypto.createDecipheriv(
      SWG_HANDOFF_AEAD_ALGORITHM,
      getSwgHandoffAeadKey(secret),
      iv,
    );
    decipher.setAAD(getSwgHandoffAad(version));
    decipher.setAuthTag(tag);
    const plaintext = Buffer.concat([
      decipher.update(ciphertext),
      decipher.final(),
    ]).toString("utf8");
    return normalizeSwgHandoffFields(JSON.parse(plaintext));
  } catch {
    throw new Error("Invalid SWG handoff token");
  }
}

export function buildSwgHeaders(input, secret) {
  const timestamp = normalizeValue(input.timestamp || Date.now());
  const transactionId =
    normalizeValue(input.transactionId) || crypto.randomUUID().replaceAll("-", "");
  const canonicalInput = {
    ...input,
    timestamp,
    transactionId,
  };

  return {
    [SWG_HEADERS.signature]: signSwgRequest(canonicalInput, secret),
    [SWG_HEADERS.timestamp]: timestamp,
    [SWG_HEADERS.transactionId]: transactionId,
    [SWG_HEADERS.contractVersion]: normalizeValue(input.contractVersion),
    [SWG_HEADERS.requestKind]: normalizeValue(input.requestKind),
    [SWG_HEADERS.originalMethod]: normalizeValue(input.originalMethod),
    [SWG_HEADERS.targetUrl]: normalizeValue(input.targetUrl),
    [SWG_HEADERS.tenantId]: normalizeValue(input.tenantId),
    [SWG_HEADERS.profileId]: normalizeValue(input.profileId),
    [SWG_HEADERS.policy]: normalizeValue(input.policy),
    [SWG_HEADERS.provider]: normalizeValue(input.provider),
    [SWG_HEADERS.providerCategory]: normalizeValue(input.providerCategory),
    [SWG_HEADERS.fallbackProvider]: normalizeValue(input.fallbackProvider),
    [SWG_HEADERS.fallbackReason]: normalizeValue(input.fallbackReason),
    [SWG_HEADERS.upstreamHost]: normalizeValue(input.upstreamHost),
    [SWG_HEADERS.upstreamScheme]: normalizeValue(input.upstreamScheme),
    [SWG_HEADERS.upstreamPort]: normalizeValue(input.upstreamPort),
  };
}

export function extractSwgHeaders(headers = {}) {
  const source = Object.fromEntries(
    Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]),
  );
  return {
    signature: normalizeValue(source[SWG_HEADERS.signature]),
    timestamp: normalizeValue(source[SWG_HEADERS.timestamp]),
    transactionId: normalizeValue(source[SWG_HEADERS.transactionId]),
    contractVersion: normalizeValue(source[SWG_HEADERS.contractVersion]),
    requestKind: normalizeValue(source[SWG_HEADERS.requestKind]),
    originalMethod: normalizeValue(source[SWG_HEADERS.originalMethod]),
    targetUrl: normalizeValue(source[SWG_HEADERS.targetUrl]),
    tenantId: normalizeValue(source[SWG_HEADERS.tenantId]),
    profileId: normalizeValue(source[SWG_HEADERS.profileId]),
    policy: normalizeValue(source[SWG_HEADERS.policy]),
    provider: normalizeValue(source[SWG_HEADERS.provider]),
    providerCategory: normalizeValue(source[SWG_HEADERS.providerCategory]),
    fallbackProvider: normalizeValue(source[SWG_HEADERS.fallbackProvider]),
    fallbackReason: normalizeValue(source[SWG_HEADERS.fallbackReason]),
    upstreamHost: normalizeValue(source[SWG_HEADERS.upstreamHost]),
    upstreamScheme: normalizeValue(source[SWG_HEADERS.upstreamScheme]),
    upstreamPort: normalizeValue(source[SWG_HEADERS.upstreamPort]),
  };
}

export function buildSwgHandoffQuery(input, secret, options = {}) {
  const timestamp = normalizeValue(input.timestamp || Date.now());
  const transactionId =
    normalizeValue(input.transactionId) || crypto.randomUUID().replaceAll("-", "");
  const canonicalInput = {
    ...input,
    timestamp,
    transactionId,
  };

  if (options.opaque !== false) {
    return {
      [SWG_HANDOFF_QUERY.token]: buildOpaqueSwgHandoffToken(canonicalInput, secret),
    };
  }

  return {
    [SWG_HANDOFF_QUERY.signature]: signSwgHandoffRequest(canonicalInput, secret),
    [SWG_HANDOFF_QUERY.timestamp]: timestamp,
    [SWG_HANDOFF_QUERY.transactionId]: transactionId,
    [SWG_HANDOFF_QUERY.sessionId]: normalizeValue(input.sessionId),
    [SWG_HANDOFF_QUERY.targetUrl]: normalizeValue(input.targetUrl),
    [SWG_HANDOFF_QUERY.tenantId]: normalizeValue(input.tenantId),
    [SWG_HANDOFF_QUERY.profileId]: normalizeValue(input.profileId),
    [SWG_HANDOFF_QUERY.policy]: normalizeValue(input.policy),
    [SWG_HANDOFF_QUERY.upstreamHost]: normalizeValue(input.upstreamHost),
    [SWG_HANDOFF_QUERY.upstreamScheme]: normalizeValue(input.upstreamScheme),
    [SWG_HANDOFF_QUERY.upstreamPort]: normalizeValue(input.upstreamPort),
  };
}

export function extractSwgHandoffQuery(searchParams = new URLSearchParams()) {
  const getValue = (key) => {
    if (searchParams && typeof searchParams.get === "function") {
      return normalizeValue(searchParams.get(key));
    }
    return normalizeValue(searchParams?.[key]);
  };

  return {
    token: getValue(SWG_HANDOFF_QUERY.token),
    signature: getValue(SWG_HANDOFF_QUERY.signature),
    timestamp: getValue(SWG_HANDOFF_QUERY.timestamp),
    transactionId: getValue(SWG_HANDOFF_QUERY.transactionId),
    sessionId: getValue(SWG_HANDOFF_QUERY.sessionId),
    targetUrl: getValue(SWG_HANDOFF_QUERY.targetUrl),
    tenantId: getValue(SWG_HANDOFF_QUERY.tenantId),
    profileId: getValue(SWG_HANDOFF_QUERY.profileId),
    policy: getValue(SWG_HANDOFF_QUERY.policy),
    upstreamHost: getValue(SWG_HANDOFF_QUERY.upstreamHost),
    upstreamScheme: getValue(SWG_HANDOFF_QUERY.upstreamScheme),
    upstreamPort: getValue(SWG_HANDOFF_QUERY.upstreamPort),
  };
}
