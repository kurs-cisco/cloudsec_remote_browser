import { usesGatewaySignaling } from "./gateway-signaling.js";

const VALID_CANDIDATE_TYPES = ["host", "srflx", "relay"];

export function normalizeCandidateTypes(values, fallback = VALID_CANDIDATE_TYPES) {
  const items = Array.isArray(values) ? values : fallback;
  const normalized = items
    .map((value) => String(value || "").trim().toLowerCase())
    .filter((value) => VALID_CANDIDATE_TYPES.includes(value));
  return normalized.length ? [...new Set(normalized)] : [...fallback];
}

export function resolveSessionAllowedCandidateTypes(sessionOrPlacement, configuredTypes) {
  if (usesGatewaySignaling(sessionOrPlacement)) {
    return ["relay"];
  }
  return normalizeCandidateTypes(configuredTypes);
}

export function resolveSessionIceTransportPolicy(
  sessionOrPlacement,
  configuredPolicy,
  configuredTypes,
) {
  const allowedCandidateTypes = resolveSessionAllowedCandidateTypes(
    sessionOrPlacement,
    configuredTypes,
  );
  if (allowedCandidateTypes.length === 1 && allowedCandidateTypes[0] === "relay") {
    return "relay";
  }
  return String(configuredPolicy || "all").trim().toLowerCase() || "all";
}
