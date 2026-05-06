import test from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";

import {
  buildSwgCanonicalString,
  buildSwgHandoffCanonicalString,
  buildSwgHandoffQuery,
  buildOpaqueSwgHandoffToken,
  buildSwgHeaders,
  decryptSwgHandoffToken,
  extractSwgHeaders,
  extractSwgHandoffQuery,
  signSwgRequest,
  timingSafeEqualHex,
  verifySwgHandoffRequest,
  verifySwgRequest,
} from "../shared/swg-handoff.js";

test("SWG handoff signature verifies for canonical request", () => {
  const secret = "local-swg-shared-secret";
  const headers = buildSwgHeaders(
    {
      method: "POST",
      targetUrl: "https://webex.com/",
      tenantId: "tenant-local-dev",
      profileId: "default-browser",
      policy: "isolate-webex",
      upstreamHost: "webex.com",
      upstreamScheme: "https",
      upstreamPort: "443",
      timestamp: "1234567890",
      transactionId: "txn-123",
    },
    secret,
  );

  const extracted = extractSwgHeaders(headers);
  assert.equal(extracted.targetUrl, "https://webex.com/");
  assert.equal(
    verifySwgRequest(
      {
        method: "POST",
        targetUrl: "https://webex.com/",
        timestamp: extracted.timestamp,
        transactionId: extracted.transactionId,
        tenantId: extracted.tenantId,
        profileId: extracted.profileId,
        policy: extracted.policy,
        upstreamHost: extracted.upstreamHost,
        upstreamScheme: extracted.upstreamScheme,
        upstreamPort: extracted.upstreamPort,
      },
      secret,
      extracted.signature,
    ),
    true,
  );
});

test("SWG handoff signature rejects tampered target URL", () => {
  const secret = "local-swg-shared-secret";
  const headers = buildSwgHeaders(
    {
      method: "POST",
      targetUrl: "https://webex.com/",
      tenantId: "tenant-local-dev",
      profileId: "default-browser",
      policy: "isolate-webex",
      upstreamHost: "webex.com",
      upstreamScheme: "https",
      upstreamPort: "443",
      timestamp: "1234567890",
      transactionId: "txn-123",
    },
    secret,
  );

  const extracted = extractSwgHeaders(headers);
  assert.equal(
    verifySwgRequest(
      {
        method: "POST",
        targetUrl: "https://example.com/",
        timestamp: extracted.timestamp,
        transactionId: extracted.transactionId,
        tenantId: extracted.tenantId,
        profileId: extracted.profileId,
        policy: extracted.policy,
        upstreamHost: extracted.upstreamHost,
        upstreamScheme: extracted.upstreamScheme,
        upstreamPort: extracted.upstreamPort,
      },
      secret,
      extracted.signature,
    ),
    false,
  );
});

test("SWG canonical string is stable", () => {
  const canonical = buildSwgCanonicalString({
    method: "POST",
    targetUrl: "https://webex.com/",
    timestamp: "1234567890",
    transactionId: "txn-123",
    tenantId: "tenant-local-dev",
    profileId: "default-browser",
    policy: "isolate-webex",
    upstreamHost: "webex.com",
    upstreamScheme: "https",
    upstreamPort: "443",
  });

  assert.match(canonical, /^method:POST\n/);
  assert.match(canonical, /targetUrl:https:\/\/webex\.com\//);
  assert.match(canonical, /transactionId:txn-123/);
  assert.match(canonical, /profileId:default-browser/);
});

test("SWG signature uses decoded base64 key material when secret syncer stores base64", () => {
  const keyMaterial = Buffer.alloc(32, 17);
  const secret = keyMaterial.toString("base64");
  const input = {
    method: "POST",
    targetUrl: "https://webex.com/",
    timestamp: "1234567890",
    transactionId: "txn-123",
    tenantId: "tenant-local-dev",
    profileId: "default-browser",
    policy: "isolate-webex",
    upstreamHost: "webex.com",
    upstreamScheme: "https",
    upstreamPort: "443",
  };

  const expected = crypto
    .createHmac("sha256", keyMaterial)
    .update(buildSwgCanonicalString(input))
    .digest("hex");

  assert.equal(signSwgRequest(input, secret), expected);
  assert.equal(verifySwgRequest(input, secret, expected), true);
});

test("SWG v2 canonical string includes browser parity envelope", () => {
  const canonical = buildSwgCanonicalString({
    method: "POST",
    contractVersion: "v2",
    requestKind: "https-decrypted-document",
    originalMethod: "GET",
    targetUrl: "https://webex.com/",
    timestamp: "1234567890",
    transactionId: "txn-123",
    tenantId: "tenant-local-dev",
    profileId: "default-browser",
    policy: "isolate-webex",
    provider: "in_house",
    providerCategory: "cat-b",
    fallbackProvider: "menlo",
    fallbackReason: "",
    upstreamHost: "webex.com",
    upstreamScheme: "https",
    upstreamPort: "443",
  });

  assert.match(canonical, /contractVersion:v2/);
  assert.match(canonical, /requestKind:https-decrypted-document/);
  assert.match(canonical, /originalMethod:GET/);
  assert.match(canonical, /provider:in_house/);
  assert.match(canonical, /providerCategory:cat-b/);
  assert.match(canonical, /fallbackProvider:menlo/);
});

test("SWG handoff query defaults to opaque token", () => {
  const secret = "local-swg-shared-secret";
  const params = buildSwgHandoffQuery(
    {
      method: "GET",
      sessionId: "sess_demo123",
      targetUrl: "https://webex.com/",
      tenantId: "tenant-local-dev",
      profileId: "default-browser",
      policy: "isolate-webex",
      upstreamHost: "webex.com",
      upstreamScheme: "https",
      upstreamPort: "443",
      timestamp: "1234567890",
      transactionId: "txn-123",
    },
    secret,
  );

  assert.deepEqual(Object.keys(params), ["token"]);

  const extracted = extractSwgHandoffQuery(params);
  assert.equal(extracted.token, params.token);
  assert.equal(extracted.sessionId, "");
  assert.equal(extracted.targetUrl, "");
  assert.equal(extracted.tenantId, "");

  const decrypted = decryptSwgHandoffToken(extracted.token, secret);
  assert.deepEqual(decrypted, {
    method: "GET",
    sessionId: "sess_demo123",
    targetUrl: "https://webex.com/",
    timestamp: "1234567890",
    transactionId: "txn-123",
    tenantId: "tenant-local-dev",
    profileId: "default-browser",
    policy: "isolate-webex",
    upstreamHost: "webex.com",
    upstreamScheme: "https",
    upstreamPort: "443",
  });
});

test("SWG handoff opaque token rejects tampering", () => {
  const secret = "local-swg-shared-secret";
  const token = buildOpaqueSwgHandoffToken(
    {
      method: "GET",
      sessionId: "sess_demo123",
      targetUrl: "https://webex.com/",
      tenantId: "tenant-local-dev",
      profileId: "default-browser",
      policy: "isolate-webex",
      upstreamHost: "webex.com",
      upstreamScheme: "https",
      upstreamPort: "443",
      timestamp: "1234567890",
      transactionId: "txn-123",
    },
    secret,
  );
  const parts = token.split(".");
  const tamperedCiphertext =
    parts[2].slice(0, -1) + (parts[2].endsWith("A") ? "B" : "A");
  const tampered = [parts[0], parts[1], tamperedCiphertext, parts[3]].join(".");

  assert.throws(() => decryptSwgHandoffToken(tampered, secret), /Invalid SWG handoff token/);
});

test("SWG handoff signature verifies for legacy signed query", () => {
  const secret = "local-swg-shared-secret";
  const params = buildSwgHandoffQuery(
    {
      method: "GET",
      sessionId: "sess_demo123",
      targetUrl: "https://webex.com/",
      tenantId: "tenant-local-dev",
      profileId: "default-browser",
      policy: "isolate-webex",
      upstreamHost: "webex.com",
      upstreamScheme: "https",
      upstreamPort: "443",
      timestamp: "1234567890",
      transactionId: "txn-123",
    },
    secret,
    { opaque: false },
  );

  const extracted = extractSwgHandoffQuery(params);
  assert.equal(
    verifySwgHandoffRequest(
      {
        method: "GET",
        sessionId: extracted.sessionId,
        targetUrl: extracted.targetUrl,
        timestamp: extracted.timestamp,
        transactionId: extracted.transactionId,
        tenantId: extracted.tenantId,
        profileId: extracted.profileId,
        policy: extracted.policy,
        upstreamHost: extracted.upstreamHost,
        upstreamScheme: extracted.upstreamScheme,
        upstreamPort: extracted.upstreamPort,
      },
      secret,
      extracted.signature,
    ),
    true,
  );
  assert.equal(extracted.token, "");
});

test("SWG bootstrap headers carry target URL for header-only bootstrap callers", () => {
  const secret = "local-swg-shared-secret";
  const headers = buildSwgHeaders(
    {
      method: "POST",
      targetUrl: "https://example.com/path?q=1",
      tenantId: "tenant-local-dev",
      profileId: "default-browser",
      policy: "isolate-example",
      timestamp: "1234567890",
      transactionId: "txn-123",
    },
    secret,
  );

  const extracted = extractSwgHeaders(headers);
  assert.equal(extracted.targetUrl, "https://example.com/path?q=1");
  assert.equal(
    verifySwgRequest(
      {
        method: "POST",
        targetUrl: extracted.targetUrl,
        timestamp: extracted.timestamp,
        transactionId: extracted.transactionId,
        tenantId: extracted.tenantId,
        profileId: extracted.profileId,
        policy: extracted.policy,
        upstreamHost: "example.com",
        upstreamScheme: "https",
        upstreamPort: "443",
      },
      secret,
      extracted.signature,
    ),
    true,
  );
});

test("SWG handoff canonical string is stable", () => {
  const canonical = buildSwgHandoffCanonicalString({
    method: "GET",
    sessionId: "sess_demo123",
    targetUrl: "https://webex.com/",
    timestamp: "1234567890",
    transactionId: "txn-123",
    tenantId: "tenant-local-dev",
    profileId: "default-browser",
    policy: "isolate-webex",
    upstreamHost: "webex.com",
    upstreamScheme: "https",
    upstreamPort: "443",
  });

  assert.match(canonical, /^method:GET\n/);
  assert.match(canonical, /sessionId:sess_demo123/);
  assert.match(canonical, /targetUrl:https:\/\/webex\.com\//);
  assert.match(canonical, /transactionId:txn-123/);
});

test("timingSafeEqualHex returns true for equal hex strings", () => {
  const sig = signSwgRequest(
    {
      method: "POST",
      targetUrl: "https://webex.com/",
      timestamp: "1234567890",
      transactionId: "txn-123",
      tenantId: "tenant-local-dev",
      profileId: "default-browser",
      policy: "isolate-webex",
      upstreamHost: "webex.com",
      upstreamScheme: "https",
      upstreamPort: "443",
    },
    "test-secret",
  );
  assert.equal(timingSafeEqualHex(sig, sig), true);
});

test("timingSafeEqualHex returns false for different-length strings without early exit timing leak", () => {
  assert.equal(timingSafeEqualHex("abc", "abcd"), false);
  assert.equal(timingSafeEqualHex("abcdef", "abc"), false);
  assert.equal(timingSafeEqualHex("", "a"), false);
});

test("timingSafeEqualHex returns false for same-length but different strings", () => {
  assert.equal(timingSafeEqualHex("abc", "abd"), false);
  assert.equal(timingSafeEqualHex("000", "001"), false);
});

test("timingSafeEqualHex handles empty strings", () => {
  assert.equal(timingSafeEqualHex("", ""), true);
  assert.equal(timingSafeEqualHex(null, ""), true);
  assert.equal(timingSafeEqualHex(undefined, null), true);
});

test("SWG signature rejects wrong secret", () => {
  const headers = buildSwgHeaders(
    {
      method: "POST",
      targetUrl: "https://webex.com/",
      tenantId: "tenant-local-dev",
      profileId: "default-browser",
      policy: "isolate-webex",
      upstreamHost: "webex.com",
      upstreamScheme: "https",
      upstreamPort: "443",
    },
    "correct-secret",
  );
  const extracted = extractSwgHeaders(headers);
  assert.equal(
    verifySwgRequest(
      {
        method: "POST",
        targetUrl: "https://webex.com/",
        timestamp: extracted.timestamp,
        transactionId: extracted.transactionId,
        tenantId: extracted.tenantId,
        profileId: extracted.profileId,
        policy: extracted.policy,
        upstreamHost: extracted.upstreamHost,
        upstreamScheme: extracted.upstreamScheme,
        upstreamPort: extracted.upstreamPort,
      },
      "wrong-secret",
      extracted.signature,
    ),
    false,
  );
});
