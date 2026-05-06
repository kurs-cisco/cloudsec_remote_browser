const LEGACY_HEADER_PREFIX = "X-SIG-RBI-";

function normalizeValue(value, fallback = "") {
  const normalized = String(value ?? "").trim();
  return normalized || fallback;
}

function normalizeBoolean(value) {
  return value === true || value === "true" || value === "1" || value === 1;
}

function normalizeProvider(value, fallback = "in_house") {
  const raw = normalizeValue(value, fallback);
  const alias = raw.toLowerCase().replace(/[-_\s]/g, "");
  if (["cloudsec", "inhouse", "internal"].includes(alias)) {
    return "in_house";
  }
  if (["menlo", "menlosecurity"].includes(alias)) {
    return "menlo";
  }
  return raw;
}

function normalizeCapabilities(capabilities = {}) {
  return {
    fileDownloadBroker: normalizeBoolean(capabilities.fileDownloadBroker),
    fileUploadBroker: normalizeBoolean(capabilities.fileUploadBroker),
    clipboardBroker: normalizeBoolean(capabilities.clipboardBroker),
    textClipboardOnly: normalizeBoolean(capabilities.textClipboardOnly),
  };
}

export function buildProviderNeutralRbiMetadata(input = {}) {
  const capabilities = normalizeCapabilities(input.brokerCapabilities);
  const provider = normalizeProvider(input.provider);
  const route = normalizeValue(input.route || input.category, "cat-b");
  const fallbackProvider = normalizeValue(input.fallbackProvider, "menlo");
  const originTypeId = normalizeValue(input.originTypeId, "64");
  const fallbackReason = normalizeValue(input.fallbackReason);

  return {
    provider,
    route,
    category: route,
    originTypeId,
    fallbackProvider,
    fallbackReason,
    tenantId: normalizeValue(input.tenantId),
    sessionId: normalizeValue(input.sessionId),
    profileId: normalizeValue(input.profileId),
    policyId: normalizeValue(input.policyId),
    brokerCapabilities: capabilities,
    unsupportedFlowFallback: fallbackReason ? fallbackProvider : "",
  };
}

export function buildLegacyRbiHeaders(input = {}) {
  const metadata = buildProviderNeutralRbiMetadata(input);
  return {
    [`${LEGACY_HEADER_PREFIX}Provider`]: metadata.provider,
    [`${LEGACY_HEADER_PREFIX}Provider-Category`]: metadata.category,
    [`${LEGACY_HEADER_PREFIX}Tenant-Id`]: metadata.tenantId,
    [`${LEGACY_HEADER_PREFIX}Session-Id`]: metadata.sessionId,
    [`${LEGACY_HEADER_PREFIX}Profile-Id`]: metadata.profileId,
    [`${LEGACY_HEADER_PREFIX}Policy-Id`]: metadata.policyId,
    [`${LEGACY_HEADER_PREFIX}Origin-Type-Id`]: metadata.originTypeId,
    [`${LEGACY_HEADER_PREFIX}Fallback-Provider`]: metadata.fallbackProvider,
    [`${LEGACY_HEADER_PREFIX}Fallback-Reason`]: metadata.fallbackReason,
    [`${LEGACY_HEADER_PREFIX}Broker-File-Download`]: metadata.brokerCapabilities.fileDownloadBroker ? "1" : "0",
    [`${LEGACY_HEADER_PREFIX}Broker-File-Upload`]: metadata.brokerCapabilities.fileUploadBroker ? "1" : "0",
    [`${LEGACY_HEADER_PREFIX}Broker-Clipboard`]: metadata.brokerCapabilities.clipboardBroker ? "1" : "0",
    [`${LEGACY_HEADER_PREFIX}Clipboard-Text-Only`]: metadata.brokerCapabilities.textClipboardOnly ? "1" : "0",
  };
}

export function buildRbiMetadataEnvelope(input = {}) {
  const metadata = buildProviderNeutralRbiMetadata(input);
  return {
    rbi: metadata,
    legacyHeaders: buildLegacyRbiHeaders(metadata),
  };
}

export function unsupportedFlowFallback(reason, input = {}) {
  return buildRbiMetadataEnvelope({
    ...input,
    fallbackProvider: normalizeValue(input.fallbackProvider, "menlo"),
    fallbackReason: normalizeValue(reason, "unsupported-flow"),
  });
}
