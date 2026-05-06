import test from "node:test";
import assert from "node:assert/strict";

import {
  buildLegacyRbiHeaders,
  buildProviderNeutralRbiMetadata,
  buildRbiMetadataEnvelope,
  unsupportedFlowFallback,
} from "../shared/rbi-metadata.js";

test("provider-neutral metadata defaults to canonical Cat-B in-house route for OriginTypeId 64", () => {
  assert.deepEqual(buildProviderNeutralRbiMetadata(), {
    provider: "in_house",
    route: "cat-b",
    category: "cat-b",
    originTypeId: "64",
    fallbackProvider: "menlo",
    fallbackReason: "",
    tenantId: "",
    sessionId: "",
    profileId: "",
    policyId: "",
    brokerCapabilities: {
      fileDownloadBroker: false,
      fileUploadBroker: false,
      clipboardBroker: false,
      textClipboardOnly: false,
    },
    unsupportedFlowFallback: "",
  });
});

test("legacy X-SIG-RBI headers preserve downstream compatibility", () => {
  const headers = buildLegacyRbiHeaders({
    provider: "cloudsec",
    route: "cat-b",
    tenantId: "tenant-a",
    sessionId: "sess-a",
    profileId: "profile-a",
    policyId: "policy-a",
    originTypeId: 64,
    fallbackReason: "unsupported-upload",
    brokerCapabilities: {
      fileDownloadBroker: true,
      fileUploadBroker: false,
      clipboardBroker: true,
      textClipboardOnly: true,
    },
  });

  assert.equal(headers["X-SIG-RBI-Provider"], "in_house");
  assert.equal(headers["X-SIG-RBI-Provider-Category"], "cat-b");
  assert.equal(headers["X-SIG-RBI-Tenant-Id"], "tenant-a");
  assert.equal(headers["X-SIG-RBI-Session-Id"], "sess-a");
  assert.equal(headers["X-SIG-RBI-Profile-Id"], "profile-a");
  assert.equal(headers["X-SIG-RBI-Policy-Id"], "policy-a");
  assert.equal(headers["X-SIG-RBI-Origin-Type-Id"], "64");
  assert.equal(headers["X-SIG-RBI-Fallback-Provider"], "menlo");
  assert.equal(headers["X-SIG-RBI-Fallback-Reason"], "unsupported-upload");
  assert.equal(headers["X-SIG-RBI-Broker-File-Download"], "1");
  assert.equal(headers["X-SIG-RBI-Broker-File-Upload"], "0");
  assert.equal(headers["X-SIG-RBI-Broker-Clipboard"], "1");
  assert.equal(headers["X-SIG-RBI-Clipboard-Text-Only"], "1");
});

test("metadata envelope carries neutral contract and legacy headers together", () => {
  const envelope = buildRbiMetadataEnvelope({
    tenantId: "tenant-a",
    sessionId: "sess-a",
    profileId: "profile-a",
    policyId: "policy-a",
    brokerCapabilities: {
      fileDownloadBroker: true,
      fileUploadBroker: true,
      clipboardBroker: true,
    },
  });

  assert.equal(envelope.rbi.tenantId, "tenant-a");
  assert.equal(envelope.rbi.sessionId, "sess-a");
  assert.equal(envelope.rbi.profileId, "profile-a");
  assert.equal(envelope.rbi.policyId, "policy-a");
  assert.equal(envelope.legacyHeaders["X-SIG-RBI-Provider"], "in_house");
});

test("unsupported flow helper pins fallback to Menlo", () => {
  const envelope = unsupportedFlowFallback("unsupported-print", {
    provider: "cloudsec",
    brokerCapabilities: {
      fileDownloadBroker: true,
    },
  });

  assert.equal(envelope.rbi.fallbackProvider, "menlo");
  assert.equal(envelope.rbi.fallbackReason, "unsupported-print");
  assert.equal(envelope.rbi.unsupportedFlowFallback, "menlo");
  assert.equal(envelope.legacyHeaders["X-SIG-RBI-Fallback-Reason"], "unsupported-print");
});
