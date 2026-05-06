export const DEFAULT_SWG_BOOTSTRAP_POLICY = Object.freeze({
  allowedContractVersions: ["v2"],
  allowedRequestKinds: ["http-document", "https-decrypted-document"],
  allowedOriginalMethods: ["GET", "HEAD"],
  allowedProviders: ["in_house"],
  allowedProviderCategories: ["cat-b"],
  fallbackProvider: "menlo",
});

export function normalizeBootstrapProvider(value) {
  const normalized = String(value || "").trim().toLowerCase().replace(/[-_\s]/g, "");
  if (normalized === "inhouse" || normalized === "internal" || normalized === "cloudsec") {
    return "in_house";
  }
  if (normalized === "menlo" || normalized === "menlosecurity") {
    return "menlo";
  }
  return String(value || "").trim().toLowerCase();
}

export function normalizeBootstrapCategory(value) {
  const normalized = String(value || "").trim().toLowerCase().replace(/[_\s]/g, "-");
  if (normalized === "catb" || normalized === "category-b") {
    return "cat-b";
  }
  if (normalized === "cata" || normalized === "category-a") {
    return "cat-a";
  }
  return normalized;
}

export function normalizeSwgBootstrapPolicy(input = {}) {
  const policy = {
    ...DEFAULT_SWG_BOOTSTRAP_POLICY,
    ...input,
  };
  return {
    allowedContractVersions: normalizeSet(policy.allowedContractVersions, (value) =>
      String(value).trim(),
    ),
    allowedRequestKinds: normalizeSet(policy.allowedRequestKinds, (value) =>
      String(value).trim().toLowerCase(),
    ),
    allowedOriginalMethods: normalizeSet(policy.allowedOriginalMethods, (value) =>
      String(value).trim().toUpperCase(),
    ),
    allowedProviders: normalizeSet(policy.allowedProviders, normalizeBootstrapProvider),
    allowedProviderCategories: normalizeSet(
      policy.allowedProviderCategories,
      normalizeBootstrapCategory,
    ),
    fallbackProvider: normalizeBootstrapProvider(policy.fallbackProvider) || "menlo",
  };
}

export function validateSwgRequestEnvelope(headers, options = {}) {
  const policy = normalizeSwgBootstrapPolicy(options);
  const contractVersion = normalizeHeaderValue(headers.contractVersion);
  if (!contractVersion) {
    return {
      contractVersion: "",
      requestKind: "http-document",
      originalMethod: "GET",
      provider: "",
      providerCategory: "",
      fallbackProvider: policy.fallbackProvider,
      fallbackReason: "",
    };
  }

  const missing = [
    "contractVersion",
    "requestKind",
    "originalMethod",
    "provider",
    "providerCategory",
    "fallbackProvider",
  ].filter((name) => !normalizeHeaderValue(headers[name]));
  if (missing.length) {
    throw validationError(400, `Missing SWG fields: ${missing.join(", ")}`);
  }

  if (!policy.allowedContractVersions.has(contractVersion)) {
    throw validationError(422, `Unsupported SWG contract version: ${contractVersion}`, {
      fallbackProvider: policy.fallbackProvider,
      fallbackReason: "unsupported-contract-version",
    });
  }

  const requestKind = normalizeHeaderValue(headers.requestKind).toLowerCase();
  if (!policy.allowedRequestKinds.has(requestKind)) {
    throw validationError(422, `Unsupported SWG request kind: ${requestKind}`, {
      fallbackProvider: policy.fallbackProvider,
      fallbackReason: "unsupported-request-kind",
      requestKind,
    });
  }

  const originalMethod = normalizeHeaderValue(headers.originalMethod).toUpperCase();
  if (!policy.allowedOriginalMethods.has(originalMethod)) {
    throw validationError(422, `Unsupported SWG original method: ${originalMethod}`, {
      fallbackProvider: policy.fallbackProvider,
      fallbackReason: "unsupported-method",
      originalMethod,
    });
  }

  const provider = normalizeBootstrapProvider(headers.provider);
  const canonicalProvider = normalizeHeaderValue(headers.provider);
  if (!policy.allowedProviders.has(provider)) {
    throw validationError(422, `Unsupported SWG RBI provider: ${provider}`, {
      fallbackProvider: policy.fallbackProvider,
      fallbackReason: "unsupported-provider",
      provider,
    });
  }

  const providerCategory = normalizeBootstrapCategory(headers.providerCategory);
  const canonicalProviderCategory = normalizeHeaderValue(headers.providerCategory);
  if (!policy.allowedProviderCategories.has(providerCategory)) {
    throw validationError(422, `Unsupported SWG RBI provider category: ${providerCategory}`, {
      fallbackProvider: policy.fallbackProvider,
      fallbackReason: "unsupported-provider-category",
      providerCategory,
    });
  }

  return {
    contractVersion,
    requestKind,
    originalMethod,
    provider,
    providerCategory,
    canonicalProvider,
    canonicalProviderCategory,
    canonicalFallbackProvider: normalizeHeaderValue(headers.fallbackProvider),
    fallbackProvider: normalizeBootstrapProvider(headers.fallbackProvider) || policy.fallbackProvider,
    fallbackReason: normalizeHeaderValue(headers.fallbackReason),
  };
}

function normalizeHeaderValue(value) {
  return String(value || "").trim();
}

function normalizeSet(values, normalize) {
  return new Set(
    (Array.isArray(values) ? values : [values])
      .map(normalize)
      .filter(Boolean),
  );
}

function validationError(status, message, details = {}) {
  const error = new Error(message);
  error.status = status;
  error.statusCode = status;
  error.details = details;
  error.debugPayload = details;
  return error;
}
