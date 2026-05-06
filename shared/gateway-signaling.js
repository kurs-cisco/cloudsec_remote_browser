function joinPath(prefix, suffix) {
  const left = String(prefix || "").replace(/\/+$/, "");
  const right = String(suffix || "").replace(/^\/+/, "");
  if (!left) {
    return `/${right}`.replace(/\/+$/, "") || "/";
  }
  return `${left}/${right}`.replace(/\/+$/, "") || "/";
}

function deriveServiceBasePath(pathname = "") {
  const trimmed = String(pathname || "").replace(/\/+$/, "");
  if (!trimmed || trimmed === "/") {
    return "";
  }
  const segments = trimmed.split("/").filter(Boolean);
  if (!segments.length) {
    return "";
  }
  if (segments.at(-1) === "worker" && segments.at(-2) === "ws") {
    segments.splice(-2, 2);
  } else if (["ws", "viewer", "viewer.html"].includes(segments.at(-1))) {
    segments.pop();
  }
  return segments.length ? `/${segments.join("/")}` : "";
}

function normalizeRole(role) {
  const value = String(role || "").trim().toLowerCase();
  if (!["viewer", "worker"].includes(value)) {
    throw new Error(`Unsupported signaling role: ${role}`);
  }
  return value;
}

export function usesGatewaySignaling(sessionOrPlacement) {
  const placement = sessionOrPlacement?.sessionPlacement || sessionOrPlacement || {};
  return Boolean(
    placement?.gatewayAssignment?.gatewayId ||
      placement?.gatewayAssignment?.publicWsURL ||
      placement?.gatewayAssignment?.publicWsUrl,
  );
}

export function buildGatewayViewerUrl(baseUrl, sessionId) {
  const parsed = new URL(baseUrl);
  parsed.pathname = joinPath(
    deriveServiceBasePath(parsed.pathname),
    `gateway/viewer/${encodeURIComponent(sessionId)}`,
  );
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString();
}

export function buildGatewaySignalingUrl(baseUrl, sessionId, role, query = {}) {
  const parsed = new URL(baseUrl);
  parsed.pathname = joinPath(
    deriveServiceBasePath(parsed.pathname),
    `gateway/signaling/${encodeURIComponent(sessionId)}/${normalizeRole(role)}`,
  );
  parsed.search = "";
  parsed.hash = "";
  for (const [key, value] of Object.entries(query || {})) {
    if (value !== undefined && value !== null && value !== "") {
      parsed.searchParams.set(key, String(value));
    }
  }
  return parsed.toString();
}

export function parseGatewaySignalingPath(pathname = "") {
  const match = String(pathname || "").match(/^\/gateway\/signaling\/([^/]+)\/(viewer|worker)\/?$/);
  if (!match) {
    return null;
  }
  return {
    sessionId: decodeURIComponent(match[1]),
    role: match[2],
  };
}

export function parseGatewayViewerPath(pathname = "") {
  const match = String(pathname || "").match(/^\/gateway\/viewer\/([^/]+)\/?$/);
  if (!match) {
    return null;
  }
  return {
    sessionId: decodeURIComponent(match[1]),
  };
}
