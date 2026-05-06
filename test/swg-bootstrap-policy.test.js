import test from "node:test";
import assert from "node:assert/strict";

import {
  normalizeBootstrapProvider,
  validateSwgRequestEnvelope,
} from "../app/swg-bootstrap-policy.js";

const validHeaders = {
  contractVersion: "v2",
  requestKind: "https-decrypted-document",
  originalMethod: "GET",
  provider: "in_house",
  providerCategory: "cat-b",
  fallbackProvider: "menlo",
  fallbackReason: "",
};

test("SWG bootstrap policy normalizes provider aliases at the boundary", () => {
  assert.equal(normalizeBootstrapProvider("cloudsec"), "in_house");
  assert.equal(normalizeBootstrapProvider("in-house"), "in_house");
  assert.equal(normalizeBootstrapProvider("menlosecurity"), "menlo");

  const envelope = validateSwgRequestEnvelope({
    ...validHeaders,
    provider: "cloudsec",
  });
  assert.equal(envelope.provider, "in_house");
});

test("SWG bootstrap policy rejects unsupported contract fields", () => {
  assert.throws(
    () => validateSwgRequestEnvelope({ ...validHeaders, contractVersion: "v1" }),
    /Unsupported SWG contract version/,
  );
  assert.throws(
    () => validateSwgRequestEnvelope({ ...validHeaders, requestKind: "https-connect" }),
    /Unsupported SWG request kind/,
  );
  assert.throws(
    () => validateSwgRequestEnvelope({ ...validHeaders, originalMethod: "POST" }),
    /Unsupported SWG original method/,
  );
  assert.throws(
    () => validateSwgRequestEnvelope({ ...validHeaders, providerCategory: "cat-a" }),
    /Unsupported SWG RBI provider category/,
  );
});

test("SWG bootstrap policy honors service-level allowlists", () => {
  const envelope = validateSwgRequestEnvelope(
    {
      ...validHeaders,
      originalMethod: "POST",
      providerCategory: "enterprise-rbi",
    },
    {
      allowedOriginalMethods: ["GET", "POST"],
      allowedProviderCategories: ["cat-b", "enterprise-rbi"],
    },
  );
  assert.equal(envelope.originalMethod, "POST");
  assert.equal(envelope.providerCategory, "enterprise-rbi");
});
