import crypto from "node:crypto";
import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import { URL } from "node:url";

import { WebSocket, WebSocketServer } from "ws";

import { config } from "./config.js";
import { verifySessionToken } from "./session-token.js";
import { SessionStore } from "./session-store.js";
import { SignalBus } from "./signal-bus.js";
import { signToken } from "./token.js";
import { buildTurnRestCredentials } from "./turn-credentials.js";
import { WorkerPoolBus } from "./worker-pool-bus.js";
import { WorkerPoolStore } from "./worker-pool-store.js";
import { WorkerRuntime } from "./worker-runtime.js";
import { validateSwgRequestEnvelope as validateSwgRequestEnvelopeWithPolicy } from "./swg-bootstrap-policy.js";
import { normalizeTargetUrl } from "../shared/target-url.js";
import {
  buildGatewaySignalingUrl,
  parseGatewaySignalingPath,
  parseGatewayViewerPath,
  usesGatewaySignaling,
} from "../shared/gateway-signaling.js";
import {
  resolveSessionAllowedCandidateTypes,
  resolveSessionIceTransportPolicy,
} from "../shared/session-transport.js";
import {
  SWG_HANDOFF_QUERY,
  buildSwgHandoffQuery,
  buildSwgHandoffCanonicalString,
  decryptSwgHandoffToken,
  extractSwgHeaders,
  extractSwgHandoffQuery,
  signSwgRequest,
  signSwgHandoffRequest,
  verifySwgRequest,
  verifySwgHandoffRequest,
} from "../shared/swg-handoff.js";

const CONTROL_PLANE_INSTANCE_ID = crypto.randomUUID();
const sessionStore = new SessionStore(config);
const signalBus = new SignalBus(config);
const workerPoolStore = new WorkerPoolStore(config);
const workerPoolBus = new WorkerPoolBus(config);
const workerRuntime = new WorkerRuntime(config);
const wss = new WebSocketServer({ noServer: true });
const localSockets = new Map();
const localPoolSockets = new Map();
const disconnectTimers = new Map();
const swgReplayMemory = new Map();
const swgBootstrapIdempotencyMemory = new Map();
const WARM_POOL_POLL_INTERVAL_MS = 150;
const SWG_BOOTSTRAP_IDEMPOTENCY_POLL_MS = 50;

function httpError(statusCode, message, debugPayload = {}) {
  const error = new Error(message);
  error.statusCode = statusCode;
  error.debugPayload = debugPayload;
  return error;
}

function structuredLog(level, context, message, fields = {}) {
  const payload = {
    ts: new Date().toISOString(),
    level,
    message,
    instanceId: CONTROL_PLANE_INSTANCE_ID,
    ...context,
    ...fields,
  };
  console[level === "error" ? "error" : "log"](JSON.stringify(payload));
}

function debugLog(message, fields = {}) {
  if (config.debug) {
    structuredLog("info", { component: "debug" }, message, fields);
  }
}

function fingerprintValue(value) {
  if (!value) {
    return "";
  }
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 12);
}

function stableStringify(value) {
  if (Array.isArray(value)) {
    return `[${value.map((entry) => stableStringify(entry)).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function fingerprintObject(value) {
  return crypto.createHash("sha256").update(stableStringify(value)).digest("hex");
}

function isRedisBackend(backend) {
  return String(backend || "").toLowerCase() === "redis";
}

async function pingRedisClient(client) {
  if (!client) {
    return {
      ok: false,
      error: "not-initialized",
    };
  }
  try {
    const response = await client.ping();
    return {
      ok: response === "PONG" || response === "pong",
      response,
    };
  } catch (error) {
    return {
      ok: false,
      error: error.message || String(error),
    };
  }
}

async function buildBackendReadiness() {
  const definitions = {
    sessionStore: {
      backend: config.sessionStoreBackend,
      client: sessionStore.impl?.client || null,
    },
    signalBus: {
      backend: config.signalBusBackend,
      client: signalBus.publisher || null,
    },
    workerPoolStore: {
      backend: config.workerPoolStoreBackend,
      client: workerPoolStore.impl?.client || null,
    },
    workerPoolBus: {
      backend: config.workerPoolBusBackend,
      client: workerPoolBus.publisher || null,
    },
  };

  const backends = {};
  const redisChecks = {};
  for (const [name, definition] of Object.entries(definitions)) {
    if (!isRedisBackend(definition.backend)) {
      backends[name] = {
        backend: definition.backend,
        ready: true,
      };
      continue;
    }

    const ping = await pingRedisClient(definition.client);
    redisChecks[name] = ping;
    backends[name] = {
      backend: definition.backend,
      ready: ping.ok,
      redis: ping,
    };
  }

  const ok = Object.values(backends).every((entry) => entry.ready);
  const redisCheckValues = Object.values(redisChecks);
  return {
    ok,
    backends,
    redis: {
      keyPrefix: config.redisKeyPrefix,
      required: config.productionRedisOnly,
      ok: redisCheckValues.length ? redisCheckValues.every((entry) => entry.ok) : null,
      checks: redisChecks,
    },
  };
}

function writeResponse(res, statusCode, headers = {}, body = "") {
  res.writeHead(statusCode, {
    "Cache-Control": "no-store",
    ...headers,
  });
  res.end(body);
}

function json(res, statusCode, payload, headers = {}) {
  writeResponse(
    res,
    statusCode,
    {
      "Content-Type": "application/json; charset=utf-8",
      ...headers,
    },
    JSON.stringify(payload),
  );
}

function redirect(res, location, headers = {}) {
  writeResponse(res, 302, { Location: location, ...headers });
}

async function parseJsonBody(req, { maxBytes = 1 << 20 } = {}) {
  const chunks = [];
  let totalBytes = 0;
  for await (const chunk of req) {
    totalBytes += chunk.length;
    if (totalBytes > maxBytes) {
      throw httpError(413, "JSON request body is too large");
    }
    chunks.push(chunk);
  }
  if (!chunks.length) {
    return {};
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw httpError(400, "Invalid JSON request body");
  }
}

function parseSessionSubresourcePath(pathname = "", suffix = "") {
  const escapedSuffix = String(suffix || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = String(pathname || "").match(
    new RegExp(`^/api/sessions/([^/]+)/${escapedSuffix}/?$`),
  );
  if (!match) {
    return "";
  }
  return decodeURIComponent(match[1]);
}

function normalizeHeaderValue(value) {
  return Array.isArray(value) ? String(value[0] || "") : String(value || "");
}

function normalizeObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function requireOrgBoundaryContext(fields) {
  if (String(fields.boundaryType || "").trim().toLowerCase() !== "org") {
    throw httpError(422, "Unsupported SWG boundary type");
  }
  if (String(fields.orgId || "") !== String(fields.boundaryId || "")) {
    throw httpError(422, "SWG org boundary mismatch");
  }
  if (String(fields.tenantId || "") !== String(fields.orgId || "")) {
    throw httpError(422, "SWG tenant boundary mismatch");
  }
}

function requireRbiInternalSecret(req) {
  if (!config.rbiInternalSharedSecret) {
    throw httpError(503, "RBI internal secret is not configured");
  }
  const provided = normalizeHeaderValue(req.headers["x-rbi-internal-secret"]);
  if (!provided || provided !== config.rbiInternalSharedSecret) {
    throw httpError(403, "Invalid RBI internal secret");
  }
}

function getRequestHost(req) {
  return normalizeHeaderValue(req.headers["x-forwarded-host"] || req.headers.host);
}

function getRequestProto(req) {
  return normalizeHeaderValue(req.headers["x-forwarded-proto"]) || "http";
}

function buildRequestBaseUrl(req, fallback = config.publicBaseUrl) {
  const host = getRequestHost(req);
  if (!host) {
    return fallback.replace(/\/+$/, "");
  }
  return `${getRequestProto(req)}://${host}`.replace(/\/+$/, "");
}

function buildRequestWsUrl(req, wsPath = "/ws", fallback = config.publicWsUrl) {
  const base = buildRequestBaseUrl(req, "");
  if (!base) {
    return fallback;
  }
  const parsed = new URL(base);
  parsed.protocol = parsed.protocol === "https:" ? "wss:" : "ws:";
  parsed.pathname = wsPath;
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString();
}

function appendBaseUrlPath(baseUrl, suffix) {
  const parsed = new URL(baseUrl);
  parsed.pathname = `${parsed.pathname.replace(/\/+$/, "")}/${String(suffix || "").replace(/^\/+/, "")}`;
  parsed.search = "";
  parsed.hash = "";
  return parsed.toString();
}

function parseInternalSessionEventPath(pathname = "") {
  const match = String(pathname || "").match(/^\/api\/internal\/sessions\/([^/]+)\/events\/?$/);
  if (!match) {
    return null;
  }
  return decodeURIComponent(match[1]);
}

function parseInternalSessionPath(pathname = "") {
  const match = String(pathname || "").match(/^\/api\/internal\/sessions\/([^/]+)\/?$/);
  if (!match) {
    return null;
  }
  return decodeURIComponent(match[1]);
}

function resolveSwgBootstrapTargetUrl(req, body = {}) {
  const bodyTarget = normalizeHeaderValue(body?.targetUrl);
  if (bodyTarget) {
    return validateTargetUrl(bodyTarget);
  }
  const headerTarget = normalizeHeaderValue(req.headers["x-cisco-target-url"]);
  if (headerTarget) {
    return validateTargetUrl(headerTarget);
  }
  throw httpError(400, "Missing targetUrl");
}

function wantsSwgBootstrapRedirectResponse(req) {
  return normalizeHeaderValue(req.headers["x-cisco-bootstrap-response"]).toLowerCase() === "redirect";
}

function redactSensitiveRequestUrl(rawUrl) {
  const value = normalizeHeaderValue(rawUrl);
  if (!value) {
    return value;
  }
  try {
    const parsed = new URL(value, config.publicBaseUrl);
    if (parsed.pathname !== "/swg/handoff") {
      return value;
    }
    for (const key of Object.values(SWG_HANDOFF_QUERY)) {
      if (parsed.searchParams.has(key)) {
        parsed.searchParams.set(key, "[redacted]");
      }
    }
    return `${parsed.pathname}${parsed.search}`;
  } catch {
    return value;
  }
}

function isLocalRequest(req) {
  const address = req.socket.remoteAddress || "";
  return ["127.0.0.1", "::1", "::ffff:127.0.0.1"].includes(address);
}

function validateTargetUrl(value) {
  try {
    return normalizeTargetUrl(value);
  } catch (error) {
    throw httpError(400, error.message || "Invalid targetUrl");
  }
}

function parseCookies(req) {
  const raw = normalizeHeaderValue(req.headers.cookie);
  const cookies = {};
  for (const part of raw.split(";")) {
    const separator = part.indexOf("=");
    if (separator <= 0) {
      continue;
    }
    const key = part.slice(0, separator).trim();
    const value = part.slice(separator + 1).trim();
    if (key) {
      cookies[key] = decodeURIComponent(value);
    }
  }
  return cookies;
}

function appendSetCookie(headers, value) {
  if (!headers["Set-Cookie"]) {
    headers["Set-Cookie"] = value;
    return;
  }
  headers["Set-Cookie"] = Array.isArray(headers["Set-Cookie"])
    ? [...headers["Set-Cookie"], value]
    : [headers["Set-Cookie"], value];
}

function buildCookie(name, value, options = {}) {
  const parts = [`${name}=${encodeURIComponent(value)}`, "Path=/", "HttpOnly"];
  if (options.maxAge !== undefined) {
    parts.push(`Max-Age=${Math.max(0, Math.floor(options.maxAge))}`);
  }
  if (options.domain) {
    parts.push(`Domain=${options.domain}`);
  }
  parts.push(`SameSite=${options.sameSite || "Lax"}`);
  if (options.secure) {
    parts.push("Secure");
  }
  return parts.join("; ");
}

function viewerCookieName(sessionId) {
  return `rbi_viewer_${sessionId}`;
}

const ACTIVE_VIEWER_SESSION_COOKIE_NAME = "rbi_active_viewer_session";

function buildViewerCookieHeaders(session, domain = "") {
  const headers = {};
  appendSetCookie(
    headers,
    buildCookie(viewerCookieName(session.id), session.viewerToken, {
      maxAge: Math.floor(config.sessionTtlMs / 1000),
      domain,
      secure: config.publicBaseUrl.startsWith("https://"),
    }),
  );
  appendSetCookie(
    headers,
    buildCookie(ACTIVE_VIEWER_SESSION_COOKIE_NAME, session.id, {
      maxAge: Math.floor(config.sessionTtlMs / 1000),
      domain,
      secure: config.publicBaseUrl.startsWith("https://"),
    }),
  );
  return headers;
}

function clearViewerCookieHeaders(sessionId) {
  const headers = {};
  appendSetCookie(
    headers,
    buildCookie(viewerCookieName(sessionId), "", {
      maxAge: 0,
      secure: config.publicBaseUrl.startsWith("https://"),
    }),
  );
  return headers;
}

function buildViewerCookieDescriptor(session, domain = "") {
  return {
    name: viewerCookieName(session.id),
    value: session.viewerToken,
    maxAge: Math.floor(config.sessionTtlMs / 1000),
    path: "/",
    domain,
    sameSite: "Lax",
    secure: config.publicBaseUrl.startsWith("https://"),
    httpOnly: true,
  };
}

function getViewerCookieToken(req, sessionId) {
  return parseCookies(req)[viewerCookieName(sessionId)] || "";
}

function getSessionToken(req, sessionId, role, tokenOverride = "") {
  if (tokenOverride) {
    return String(tokenOverride);
  }
  if (role === "viewer") {
    return getViewerCookieToken(req, sessionId);
  }
  return "";
}

function validateSessionToken(req, session, role, tokenOverride = "") {
  const token = getSessionToken(req, session?.id, role, tokenOverride);
  return verifySessionToken({
    token,
    session,
    role,
    secret: config.tokenSecret,
  });
}

function validateViewerAccess(req, session) {
  if (!session) {
    throw httpError(404, "Session not found");
  }
  if (session.state === "terminated") {
    throw httpError(410, "Session is terminated");
  }
  if (Date.now() > session.expiresAt) {
    throw httpError(410, "Session has expired");
  }
  validateSessionToken(req, session, "viewer");
  return buildViewerCookieHeaders(session);
}

function hasValidViewerCookieForSession(req, session) {
  try {
    validateSessionToken(req, session, "viewer");
    return true;
  } catch {
    return false;
  }
}

function isSwgAuthMode(value) {
  return String(value || "").toLowerCase() === "swg";
}

function shouldRedirectSwgViewerEntry(req, session) {
  return isSwgAuthMode(session?.client?.authMode) && !getViewerCookieToken(req, session.id);
}

function makeViewerToken(sessionId, expiresAt) {
  return signToken({ role: "viewer", sessionId, exp: expiresAt }, config.tokenSecret);
}

function makeWorkerToken(sessionId, expiresAt, generation = 1) {
  return signToken({ role: "worker", sessionId, generation, exp: expiresAt }, config.tokenSecret);
}

function redactViewerEventValue(value, depth = 0) {
  if (depth > 4) {
    return "[truncated]";
  }
  if (typeof value === "string") {
    return value.length > 512 ? `${value.slice(0, 512)}...` : value;
  }
  if (Array.isArray(value)) {
    return value.slice(0, 20).map((entry) => redactViewerEventValue(entry, depth + 1));
  }
  if (value && typeof value === "object") {
    const redacted = {};
    for (const [key, entry] of Object.entries(value)) {
      if (/token|cookie|authorization|secret|password|credential|signature/i.test(key)) {
        redacted[key] = "[redacted]";
        continue;
      }
      if (/url|href/i.test(key) && typeof entry === "string") {
        try {
          const parsed = new URL(entry);
          parsed.search = "";
          parsed.hash = "";
          redacted[key] = parsed.toString();
        } catch {
          redacted[key] = redactViewerEventValue(entry, depth + 1);
        }
        continue;
      }
      redacted[key] = redactViewerEventValue(entry, depth + 1);
    }
    return redacted;
  }
  return value;
}

function sanitizeViewerEventPayload(body = {}) {
  const allowed = {};
  for (const key of [
    "type",
    "event",
    "state",
    "reason",
    "ts",
    "viewport",
    "stream",
    "media",
    "error",
    "metrics",
    "session",
    "events",
  ]) {
    if (Object.prototype.hasOwnProperty.call(body, key)) {
      allowed[key] = redactViewerEventValue(body[key]);
    }
  }
  const encoded = JSON.stringify(allowed);
  if (Buffer.byteLength(encoded) > config.viewerEventMaxBytes) {
    throw httpError(413, "Viewer event payload is too large");
  }
  return allowed;
}

function normalizeViewerTelemetryExportLimit(value) {
  const parsed = Math.round(Number(value));
  if (Number.isFinite(parsed) && parsed > 0) {
    return Math.min(parsed, config.viewerTelemetryMaxEvents);
  }
  return Math.min(50, config.viewerTelemetryMaxEvents);
}

function summarizeViewerTelemetryPayload(payload = {}) {
  const events = Array.isArray(payload.events) ? payload.events : [];
  if (!events.length) {
    return null;
  }

  const summary = {
    milestoneCount: 0,
    milestones: [],
  };

  for (const event of events) {
    if (!event || typeof event !== "object") {
      continue;
    }
    const name = normalizeHeaderValue(event.name || event.type || event.event);
    const fields = event.fields && typeof event.fields === "object" ? event.fields : {};
    const elapsedMs = Math.max(0, Math.round(Number(event.viewerElapsedMs || fields.viewerElapsedMs || 0) || 0));

    if (name === "viewer.milestone" && fields.milestone) {
      const milestone = normalizeHeaderValue(fields.milestone);
      summary.milestoneCount += 1;
      summary.milestones.push(milestone);
      switch (milestone) {
        case "page.loaded":
          summary.handoffLoadedMs = elapsedMs;
          break;
        case "session.fetch":
          summary.sessionFetchMs = elapsedMs;
          break;
        case "worker.ready":
          summary.workerReadyMs = elapsedMs;
          break;
        case "signaling.open":
          summary.signalingOpenMs = elapsedMs;
          break;
        case "signaling.registered":
          summary.signalingRegisteredMs = elapsedMs;
          break;
        case "peer.connected":
          summary.iceConnectedMs = elapsedMs;
          break;
        case "input.channel.open":
          summary.inputChannelOpenMs = elapsedMs;
          break;
        case "track.video":
          summary.videoTrackMs = elapsedMs;
          break;
        case "video.loadedmetadata":
          summary.videoMetadataMs = elapsedMs;
          break;
        case "video.first_frame":
          summary.firstDecodedFrameMs = elapsedMs;
          summary.ttfvMs = elapsedMs;
          break;
        case "video.first_rendered":
          summary.firstRenderedFrameMs = elapsedMs;
          summary.ttfvMs = summary.ttfvMs || elapsedMs;
          break;
        case "viewer.live":
          summary.liveMs = elapsedMs;
          break;
        default:
          break;
      }
    }

    if (name === "viewer.input_slo") {
      const byClass = fields.byClass && typeof fields.byClass === "object" ? fields.byClass : {};
      let maxAckP95 = 0;
      for (const bucket of Object.values(byClass)) {
        const p95 = Number(bucket?.ackMs?.p95 || 0);
        if (Number.isFinite(p95) && p95 > maxAckP95) {
          maxAckP95 = p95;
        }
      }
      summary.inputAckP95Ms = Math.round(maxAckP95);
      summary.clickToApplyP95Ms = Math.round(Number(fields.clickToApplyMs?.p95 || 0) || 0);
      summary.controlBacklogBytes = Math.round(Number(fields.controlBacklog?.bufferedAmount || 0) || 0);
      summary.inputViolations = Array.isArray(fields.violations) ? fields.violations.length : 0;
    }
  }

  if (!summary.milestoneCount && summary.inputAckP95Ms === undefined) {
    return null;
  }
  summary.milestones = [...new Set(summary.milestones)].slice(0, 16);
  return summary;
}

function viewerEventDisconnectReason(payload = {}) {
  const candidates = [
    payload.type,
    payload.event,
    payload.state,
    payload.reason,
  ]
    .map((value) => normalizeHeaderValue(value).toLowerCase())
    .filter(Boolean);

  if (
    candidates.some((value) =>
      [
        "unload",
        "viewer.unload",
        "pagehide",
        "beforeunload",
        "closed",
        "viewer.closed",
        "viewer.disconnect",
        "viewer.disconnected",
      ].includes(value),
    )
  ) {
    return normalizeHeaderValue(payload.reason) || "viewer unload";
  }

  for (const event of Array.isArray(payload.events) ? payload.events : []) {
    if (!event || typeof event !== "object") {
      continue;
    }
    const name = normalizeHeaderValue(event.name || event.type || event.event).toLowerCase();
    const reason = normalizeHeaderValue(event.reason || event.fields?.reason);
    if (name === "viewer.unload" || name === "pagehide" || reason.toLowerCase() === "unload") {
      return reason || "viewer unload";
    }
  }

  return "";
}

function buildTurnCredentialBundle(session) {
  return {
    viewer: buildTurnRestCredentials({
      sessionId: session.id,
      role: "viewer",
      secret: config.turnSharedSecret,
      ttlSeconds: config.turnCredentialTtlSeconds,
    }),
    worker: buildTurnRestCredentials({
      sessionId: session.id,
      role: "worker",
      secret: config.turnSharedSecret,
      ttlSeconds: config.turnCredentialTtlSeconds,
    }),
  };
}

function buildIceConfigPayload(session) {
  const allowedCandidateTypes = resolveSessionAllowedCandidateTypes(
    session,
    config.allowedIceCandidateTypes,
  );
  return {
    iceServers: [
      {
        urls: config.viewerIceUrls,
        username: session.turnCredentials.viewer.username,
        credential: session.turnCredentials.viewer.credential,
      },
    ],
    iceTransportPolicy: resolveSessionIceTransportPolicy(
      session,
      config.viewerIceTransportPolicy,
      config.allowedIceCandidateTypes,
    ),
    allowedCandidateTypes,
  };
}

function buildSessionAssignmentPayload(session) {
  const allowedCandidateTypes = resolveSessionAllowedCandidateTypes(
    session,
    config.allowedIceCandidateTypes,
  );
  const signalingUrl = buildSessionSignalingUrl(session, "worker", config.workerWsUrl);
  return {
    type: "session-assignment",
    sessionId: session.id,
    targetUrl: session.targetUrl,
    generation: session.generation || 1,
    workerToken: session.workerToken,
    viewerToken: session.viewerToken,
    signalingUrl,
    signalingMode: usesGatewaySignaling(session) ? "gateway" : "direct",
    signalingConnectHost: buildWorkerSignalingConnectHost(signalingUrl),
    displayWidth: session.viewport.width || config.displayWidth,
    displayHeight: session.viewport.height || config.displayHeight,
    turnUsername: session.turnCredentials.worker.username,
    turnPassword: session.turnCredentials.worker.credential,
    workerIceUrls: config.workerIceUrls,
    iceServers: config.workerIceUrls,
    iceTransportPolicy: resolveSessionIceTransportPolicy(
      session,
      config.viewerIceTransportPolicy,
      config.allowedIceCandidateTypes,
    ),
    allowedCandidateTypes,
    experiments: session.experiments || {},
    gatewayAssignment: session.sessionPlacement?.gatewayAssignment || null,
    workerAssignment: session.sessionPlacement?.workerAssignment || null,
    transport: session.transport || null,
    workerBridge: session.workerBridge || null,
  };
}

function viewerSnapshot(session) {
  return sessionStore.snapshot(session);
}

async function assignSessionWorker(session) {
  let worker = null;

  if (config.warmPoolEnabled) {
    const pooledWorker = await allocateWarmWorker(
      session.id,
      buildSessionAssignmentPayload(session),
      buildWarmPoolWorkerFilters(session),
    );
    if (pooledWorker) {
      worker = {
        launchMode: "warm-pool",
        workerId: pooledWorker.workerId,
        taskArn: pooledWorker.taskArn || null,
        jobName: pooledWorker.jobName || null,
        namespace: pooledWorker.namespace || null,
        poolWorkerId: pooledWorker.workerId,
      };
      await workerPoolBus.notifyPendingAssignment(pooledWorker.workerId);
    }
  }

  if (!worker) {
    worker = await workerRuntime.launch(session);
  }

  session.worker = worker;
  await sessionStore.setWorker(session.id, worker);
  structuredLog("info", { sessionId: session.id, component: "session" }, "worker-assigned", {
    launchMode: worker.launchMode || null,
    workerId: worker.workerId || null,
    taskArn: worker.taskArn || null,
    jobName: worker.jobName || null,
    namespace: worker.namespace || null,
    poolWorkerId: worker.poolWorkerId || null,
    generation: session.generation || 1,
    mediaPlaneMode: session.transport?.mediaPlaneMode || null,
    protocol: session.transport?.protocol || null,
  });
  return worker;
}

function getGatewayAssignmentValue(session, key) {
  const assignment = session?.sessionPlacement?.gatewayAssignment || {};
  return normalizeHeaderValue(assignment[key] || assignment[`${key[0].toLowerCase()}${key.slice(1)}`]);
}

function getGatewayWsBaseUrl(session, fallbackWsUrl = config.publicWsUrl) {
  return (
    getGatewayAssignmentValue(session, "publicWsURL") ||
    normalizeHeaderValue(fallbackWsUrl) ||
    config.publicWsUrl
  );
}

function buildSessionSignalingUrl(session, role = "viewer", fallbackWsUrl = config.publicWsUrl) {
  if (!usesGatewaySignaling(session)) {
    return role === "worker" ? config.workerWsUrl : fallbackWsUrl;
  }
  const transportSignalingUrl =
    role === "viewer" ? normalizeHeaderValue(session?.transport?.signalingUrl) : "";
  if (transportSignalingUrl) {
    return transportSignalingUrl;
  }
  return buildGatewaySignalingUrl(getGatewayWsBaseUrl(session, fallbackWsUrl), session.id, role, {
    relay: getGatewayAssignmentValue(session, "relayMode"),
  });
}

function buildDisplayClass(viewport = {}) {
  const width = Number(viewport.width) || config.displayWidth;
  const height = Number(viewport.height) || config.displayHeight;
  return `${Math.round(width)}x${Math.round(height)}`;
}

function resolveSessionMediaMode(session) {
  return normalizeHeaderValue(
    session?.transport?.mediaPlaneMode ||
      session?.transport?.mediaTermination?.mediaPlaneMode ||
      session?.workerBridge?.relayMode ||
      session?.sessionPlacement?.gatewayAssignment?.relayMode ||
      "",
  );
}

function buildWarmPoolWorkerFilters(session) {
  const workerAssignment = session?.sessionPlacement?.workerAssignment || {};
  return {
    region: normalizeHeaderValue(workerAssignment.region),
    runtimeClass: normalizeHeaderValue(workerAssignment.runtimeClass),
    mediaMode: resolveSessionMediaMode(session),
    imageDigest: normalizeHeaderValue(config.workerImageDigest),
    displayClass: buildDisplayClass(session?.viewport),
  };
}

function isGatewayMediaRelaySession(session) {
  return (
    normalizeHeaderValue(session?.sessionPlacement?.gatewayAssignment?.relayMode) ===
      "gateway-media-relay" ||
    normalizeHeaderValue(session?.workerBridge?.relayMode) === "gateway-media-relay" ||
    normalizeHeaderValue(session?.transport?.mediaTermination?.relayMode) === "gateway-media-relay"
  );
}

function isGatewayWebRtcReady(session) {
  return (
    normalizeHeaderValue(session?.transport?.mediaPlaneMode) === "gateway-webrtc-relay" &&
    normalizeHeaderValue(session?.transport?.protocol) === "webrtc-srtp" &&
    normalizeHeaderValue(session?.transport?.mediaGatewayUrl) &&
    normalizeHeaderValue(session?.workerBridge?.mediaGatewayUrl)
  );
}

function shouldDeferWorkerLaunch(session) {
  return isGatewayMediaRelaySession(session) && !isGatewayWebRtcReady(session);
}

function normalizePoolWorkerRegistration(message, ws) {
  const metadata = normalizeObject(message.metadata);
  const displayWidth = Number(metadata.displayWidth || message.displayWidth || config.displayWidth);
  const displayHeight = Number(metadata.displayHeight || message.displayHeight || config.displayHeight);
  const displayClass =
    normalizeHeaderValue(message.displayClass || metadata.displayClass) ||
    buildDisplayClass({ width: displayWidth, height: displayHeight });
  const normalizedMetadata = {
    ...metadata,
    displayClass,
  };
  return {
    workerId: normalizeHeaderValue(message.workerId),
    taskArn: message.taskArn || metadata.taskArn || null,
    runtimeId: message.runtimeId || metadata.runtimeId || null,
    region: normalizeHeaderValue(message.region || metadata.region),
    runtimeClass: normalizeHeaderValue(message.runtimeClass || metadata.runtimeClass),
    mediaMode: normalizeHeaderValue(message.mediaMode || metadata.mediaMode),
    imageDigest: normalizeHeaderValue(message.imageDigest || metadata.imageDigest),
    displayClass,
    metadata: normalizedMetadata,
    socketOwner: buildSocketOwner(ws),
  };
}

function buildRuntimeSessionPayload(session, options = {}) {
  const publicBaseUrl = options.publicBaseUrl || config.publicBaseUrl;
  const publicWsUrl = options.publicWsUrl || config.publicWsUrl;
  const swgSessionContext = deriveSwgSessionContext(session?.client, session?.targetUrl);
  const handoffUrl = swgSessionContext ? buildSwgHandoffUrl(session, swgSessionContext, publicBaseUrl) : "";
  const viewerUrl =
    normalizeHeaderValue(session?.transport?.viewerUrl) ||
    handoffUrl ||
    `${publicBaseUrl}/viewer?sessionId=${encodeURIComponent(session.id)}`;
  return {
    sessionId: session.id,
    state: session.state,
    handoffUrl,
    viewerUrl,
    signalingUrl: buildSessionSignalingUrl(session, "viewer", publicWsUrl),
    viewerEntryMode: swgSessionContext ? "swg-handoff" : "direct-viewer",
    viewerSignalingToken: usesGatewaySignaling(session) ? session.viewerToken : "",
    gatewayAssignment: session.sessionPlacement?.gatewayAssignment || null,
    workerAssignment: session.sessionPlacement?.workerAssignment || null,
    transport: session.transport || null,
    workerBridge: session.workerBridge || null,
    ...buildIceConfigPayload(session),
  };
}

function buildInternalSessionResponse(session, options = {}) {
  const payload = buildRuntimeSessionPayload(session, options);
  return {
    ...payload,
    viewerToken: session?.viewerToken || "",
    workerToken: session?.workerToken || "",
    generation: session?.generation || 1,
    viewerSignalingToken: payload.viewerSignalingToken || session?.viewerToken || "",
    viewerCookie: buildViewerCookieDescriptor(session),
    session: viewerSnapshot(session),
  };
}

function buildWorkerSignalingConnectHost(signalingUrl) {
  const fallback = normalizeHeaderValue(config.workerWsConnectHost);
  if (!fallback) {
    return "";
  }
  try {
    const direct = new URL(config.workerWsUrl);
    const current = new URL(signalingUrl);
    return direct.host === current.host ? fallback : "";
  } catch {
    return fallback;
  }
}

function getPoolRegistrationPaths() {
  const paths = new Set(["/ws/worker"]);
  try {
    paths.add(new URL(config.poolWsUrl || config.workerWsUrl).pathname || "/ws/worker");
  } catch {
    // Keep the worker path fallback for malformed optional pool URLs.
  }
  return paths;
}

function isPoolRegistrationPath(pathname) {
  return getPoolRegistrationPaths().has(pathname);
}

function normalizeSessionPlacement(sessionPlacement = {}) {
  const placement = normalizeObject(sessionPlacement);
  const gatewayAssignment = normalizeObject(placement.gatewayAssignment);
  const workerAssignment = normalizeObject(placement.workerAssignment);
  if (!Object.keys(gatewayAssignment).length && !Object.keys(workerAssignment).length) {
    return null;
  }
  return {
    gatewayAssignment: Object.keys(gatewayAssignment).length ? gatewayAssignment : null,
    workerAssignment: Object.keys(workerAssignment).length ? workerAssignment : null,
  };
}

function normalizeGatewayTransport(transport = {}) {
  const normalized = normalizeObject(transport);
  return Object.keys(normalized).length ? normalized : null;
}

function normalizeWorkerBridge(workerBridge = {}) {
  const normalized = normalizeObject(workerBridge);
  return Object.keys(normalized).length ? normalized : null;
}

function buildSessionAuthorityBootstrapRequest(body, targetUrl, swgContext, requestBaseUrl, requestWsUrl) {
  return {
    transactionId: swgContext.transactionId,
    targetUrl,
    orgId: swgContext.orgId,
    boundaryType: swgContext.boundaryType,
    boundaryId: swgContext.boundaryId,
    originId: swgContext.originId,
    originType: swgContext.originType,
    tenantId: swgContext.tenantId,
    profileId: swgContext.profileId,
    policy: swgContext.policy,
    contractVersion: swgContext.contractVersion,
    requestKind: swgContext.requestKind,
    originalMethod: swgContext.originalMethod,
    provider: swgContext.provider,
    providerCategory: swgContext.providerCategory,
    fallbackProvider: swgContext.fallbackProvider,
    fallbackReason: swgContext.fallbackReason,
    nonce: swgContext.nonce,
    keyId: swgContext.keyId,
    upstreamHost: swgContext.upstreamHost,
    upstreamScheme: swgContext.upstreamScheme,
    upstreamPort: swgContext.upstreamPort,
    viewport: normalizeObject(body.viewport),
    experiments: normalizeObject(body.experiments),
    client: normalizeObject(body.client),
    publicBaseUrl: requestBaseUrl,
    publicWsUrl: requestWsUrl,
  };
}

function buildSessionAuthorityResponsePayload(payload) {
  const response = normalizeObject(payload);
  const handoffUrl = normalizeHeaderValue(response.handoffUrl || response.viewerUrl);
  const sessionId = normalizeHeaderValue(response.sessionId);
  if (!handoffUrl || !sessionId) {
    throw httpError(502, "Session authority returned an invalid bootstrap response");
  }
  const normalized = {
    ...response,
    sessionId,
    handoffUrl,
    viewerUrl: handoffUrl,
    viewerEntryMode: normalizeHeaderValue(response.viewerEntryMode) || "swg-handoff",
    gatewayAssignment: normalizeObject(response.gatewayAssignment),
    workerAssignment: normalizeObject(response.workerAssignment),
    transport: normalizeGatewayTransport(response.transport),
    workerBridge: normalizeWorkerBridge(response.workerBridge),
  };
  return normalized;
}

async function delegateSwgBootstrapToSessionAuthority(body, targetUrl, swgContext, options) {
  if (!config.sessionAuthorityBootstrapUrl) {
    return null;
  }
  const payload = buildSessionAuthorityBootstrapRequest(
    body,
    targetUrl,
    swgContext,
    options.publicBaseUrl,
    options.publicWsUrl,
  );
  const headers = { "Content-Type": "application/json" };
  if (config.rbiInternalSharedSecret) {
    headers["X-RBI-Internal-Secret"] = config.rbiInternalSharedSecret;
  }

  let response;
  try {
    response = await fetch(config.sessionAuthorityBootstrapUrl, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(config.sessionAuthorityTimeoutMs),
    });
  } catch (error) {
    structuredLog("error", { component: "session-authority" }, "bootstrap-request-failed", {
      error: error.message || String(error),
      url: config.sessionAuthorityBootstrapUrl,
    });
    throw httpError(502, "Session authority bootstrap failed");
  }

  let responseBody = {};
  try {
    responseBody = await response.json();
  } catch {
    responseBody = {};
  }

  if (!response.ok) {
    structuredLog("warn", { component: "session-authority" }, "bootstrap-request-rejected", {
      statusCode: response.status,
      url: config.sessionAuthorityBootstrapUrl,
      error: responseBody.error || null,
    });
    throw httpError(502, "Session authority rejected bootstrap", {
      authorityStatusCode: response.status,
      authorityError: responseBody.error || null,
    });
  }

  return buildSessionAuthorityResponsePayload(responseBody);
}

function deriveUpstreamContext(headersOrQuery, targetUrl) {
  const url = new URL(targetUrl);
  const scheme = String(headersOrQuery.upstreamScheme || url.protocol.replace(":", "")).toLowerCase();
  return {
    upstreamHost: String(headersOrQuery.upstreamHost || url.hostname),
    upstreamScheme: scheme,
    upstreamPort: String(headersOrQuery.upstreamPort || url.port || (scheme === "https" ? "443" : "80")),
  };
}

function requireSwgFields(fields, required) {
  const missing = required.filter((name) => !String(fields[name] || "").trim());
  if (missing.length) {
    throw httpError(400, `Missing SWG fields: ${missing.join(", ")}`);
  }
}

function validateSwgRequestEnvelope(headers) {
  return validateSwgRequestEnvelopeWithPolicy(headers, {
    allowedContractVersions: config.swgBootstrapAllowedContractVersions,
    allowedRequestKinds: config.swgBootstrapAllowedRequestKinds,
    allowedOriginalMethods: config.swgBootstrapAllowedOriginalMethods,
    allowedProviders: config.swgBootstrapAllowedProviders,
    allowedProviderCategories: config.swgBootstrapAllowedProviderCategories,
    fallbackProvider: config.rbiFallbackProvider,
  });
}

async function rememberReplay(key, ttlMs = config.swgReplayTtlMs) {
  const redisClient = sessionStore.impl?.client;
  if (redisClient) {
    const result = await redisClient.set(`${config.swgReplayKeyPrefix}:${key}`, "1", {
      NX: true,
      PX: ttlMs,
    });
    return result === "OK";
  }

  const now = Date.now();
  for (const [entry, seenAt] of swgReplayMemory.entries()) {
    if (now - seenAt > ttlMs) {
      swgReplayMemory.delete(entry);
    }
  }
  if (swgReplayMemory.has(key)) {
    return false;
  }
  swgReplayMemory.set(key, now);
  return true;
}

function swgBootstrapIdempotencyKey(transactionId) {
  return `transaction:${transactionId}`;
}

async function getSwgBootstrapIdempotencyRecord(key) {
  const redisClient = sessionStore.impl?.client;
  if (redisClient) {
    const raw = await redisClient.get(`${config.swgBootstrapIdempotencyKeyPrefix}:${key}`);
    return raw ? JSON.parse(raw) : null;
  }

  const record = swgBootstrapIdempotencyMemory.get(key);
  if (!record) {
    return null;
  }
  if (Date.now() - record.updatedAt > config.swgBootstrapIdempotencyTtlMs) {
    swgBootstrapIdempotencyMemory.delete(key);
    return null;
  }
  return record;
}

async function setSwgBootstrapIdempotencyRecord(key, record, { nx = false } = {}) {
  const redisClient = sessionStore.impl?.client;
  const payload = JSON.stringify(record);
  if (redisClient) {
    const result = await redisClient.set(`${config.swgBootstrapIdempotencyKeyPrefix}:${key}`, payload, {
      NX: nx,
      PX: config.swgBootstrapIdempotencyTtlMs,
    });
    return nx ? result === "OK" : true;
  }

  if (nx && swgBootstrapIdempotencyMemory.has(key)) {
    return false;
  }
  swgBootstrapIdempotencyMemory.set(key, record);
  return true;
}

async function deleteSwgBootstrapIdempotencyRecord(key) {
  const redisClient = sessionStore.impl?.client;
  if (redisClient) {
    await redisClient.del(`${config.swgBootstrapIdempotencyKeyPrefix}:${key}`);
    return;
  }
  swgBootstrapIdempotencyMemory.delete(key);
}

async function beginSwgBootstrapIdempotency(swgContext) {
  const key = swgBootstrapIdempotencyKey(swgContext.transactionId);
  const now = Date.now();
  const record = {
    state: "creating",
    fingerprint: swgContext.requestFingerprint,
    createdAt: now,
    updatedAt: now,
  };

  if (await setSwgBootstrapIdempotencyRecord(key, record, { nx: true })) {
    return { acquired: true, key };
  }

  const deadline = now + Math.max(0, config.swgBootstrapIdempotencyWaitMs);
  while (true) {
    const existing = await getSwgBootstrapIdempotencyRecord(key);
    if (!existing) {
      if (await setSwgBootstrapIdempotencyRecord(key, record, { nx: true })) {
        return { acquired: true, key };
      }
      continue;
    }
    if (existing.fingerprint !== swgContext.requestFingerprint) {
      throw httpError(409, "SWG transaction id was reused with different bootstrap input");
    }
    if (existing.state === "ready" && existing.response) {
      return {
        acquired: false,
        key,
        response: existing.response,
        statusCode: existing.statusCode || 200,
      };
    }
    if (existing.state === "failed") {
      await deleteSwgBootstrapIdempotencyRecord(key);
      if (await setSwgBootstrapIdempotencyRecord(key, record, { nx: true })) {
        return { acquired: true, key };
      }
      continue;
    }
    if (Date.now() >= deadline) {
      throw httpError(409, "SWG bootstrap transaction is already in progress");
    }
    await new Promise((resolve) => {
      setTimeout(resolve, SWG_BOOTSTRAP_IDEMPOTENCY_POLL_MS);
    });
  }
}

async function completeSwgBootstrapIdempotency(key, fingerprint, response, statusCode = 201) {
  await setSwgBootstrapIdempotencyRecord(key, {
    state: "ready",
    fingerprint,
    response,
    statusCode,
    updatedAt: Date.now(),
  });
}

async function failSwgBootstrapIdempotency(key, fingerprint, error) {
  await setSwgBootstrapIdempotencyRecord(key, {
    state: "failed",
    fingerprint,
    error: error.message || String(error),
    updatedAt: Date.now(),
  });
}

async function validateSwgBootstrapRequest(req, targetUrl) {
  if (!config.enableSwgBootstrap) {
    throw httpError(404, "SWG bootstrap is disabled");
  }
  if (config.swgBootstrapLocalOnly && !isLocalRequest(req)) {
    throw httpError(403, "SWG bootstrap is restricted to local callers");
  }

  const headers = extractSwgHeaders(req.headers);
  requireSwgFields(headers, [
    "signature",
    "timestamp",
    "transactionId",
    "contractVersion",
    "requestKind",
    "originalMethod",
    "orgId",
    "boundaryType",
    "boundaryId",
    "originId",
    "originType",
    "tenantId",
    "profileId",
    "policy",
    "provider",
    "providerCategory",
    "fallbackProvider",
    "nonce",
    "keyId",
  ]);
  requireOrgBoundaryContext(headers);

  const timestamp = Number(headers.timestamp);
  if (!Number.isFinite(timestamp)) {
    throw httpError(400, "Invalid SWG timestamp");
  }
  if (Math.abs(Date.now() - timestamp) > config.swgTimestampToleranceMs) {
    throw httpError(401, "Stale SWG request");
  }

  const upstream = deriveUpstreamContext(headers, targetUrl);
  const envelope = validateSwgRequestEnvelope(headers);
  const canonicalInput = {
    method: "POST",
    contractVersion: envelope.contractVersion,
    requestKind: envelope.requestKind,
    originalMethod: envelope.originalMethod,
    targetUrl,
    timestamp: headers.timestamp,
    transactionId: headers.transactionId,
    orgId: headers.orgId,
    boundaryType: headers.boundaryType,
    boundaryId: headers.boundaryId,
    originId: headers.originId,
    originType: headers.originType,
    tenantId: headers.tenantId,
    profileId: headers.profileId,
    policy: headers.policy,
    provider: envelope.canonicalProvider || envelope.provider,
    providerCategory: envelope.canonicalProviderCategory || envelope.providerCategory,
    fallbackProvider: envelope.canonicalFallbackProvider || envelope.fallbackProvider,
    fallbackReason: envelope.fallbackReason,
    nonce: headers.nonce,
    keyId: headers.keyId,
    ...upstream,
  };

  if (!verifySwgRequest(canonicalInput, config.swgSharedSecret, headers.signature)) {
    const expectedSignature = signSwgRequest(canonicalInput, config.swgSharedSecret);
    structuredLog("warn", { component: "swg" }, "swg-bootstrap-invalid-signature", {
      transactionId: headers.transactionId,
      expectedSignatureFingerprint: fingerprintValue(expectedSignature),
      receivedSignatureFingerprint: fingerprintValue(headers.signature),
    });
    throw httpError(401, "Invalid SWG signature");
  }

  return {
    mode: "swg",
    identity: `swg:${headers.orgId}:${headers.profileId}`,
    transactionId: headers.transactionId,
    orgId: headers.orgId,
    boundaryType: headers.boundaryType,
    boundaryId: headers.boundaryId,
    originId: headers.originId,
    originType: headers.originType,
    tenantId: headers.tenantId,
    profileId: headers.profileId,
    policy: headers.policy,
    nonce: headers.nonce,
    keyId: headers.keyId,
    requestFingerprint: fingerprintObject(canonicalInput),
    ...envelope,
    ...upstream,
  };
}

function buildSwgHandoffUrl(session, swgContext, publicBaseUrl = config.publicBaseUrl) {
  const url = new URL("/swg/handoff", publicBaseUrl);
  const query = buildSwgHandoffQuery(
    {
      sessionId: session.id,
      targetUrl: session.targetUrl,
      contractVersion: swgContext.contractVersion,
      requestKind: swgContext.requestKind,
      originalMethod: swgContext.originalMethod,
      transactionId: swgContext.transactionId,
      orgId: swgContext.orgId,
      boundaryType: swgContext.boundaryType,
      boundaryId: swgContext.boundaryId,
      originId: swgContext.originId,
      originType: swgContext.originType,
      tenantId: swgContext.tenantId,
      profileId: swgContext.profileId,
      policy: swgContext.policy,
      provider: swgContext.provider,
      providerCategory: swgContext.providerCategory,
      fallbackProvider: swgContext.fallbackProvider,
      fallbackReason: swgContext.fallbackReason,
      nonce: swgContext.nonce,
      keyId: swgContext.keyId,
      upstreamHost: swgContext.upstreamHost,
      upstreamScheme: swgContext.upstreamScheme,
      upstreamPort: swgContext.upstreamPort,
    },
    config.swgSharedSecret,
  );
  for (const [key, value] of Object.entries(query)) {
    url.searchParams.set(key, value);
  }
  return url.toString();
}

function deriveSwgSessionContext(client, targetUrl) {
  if (!isSwgAuthMode(client?.authMode)) {
    return null;
  }
  const swg = client?.swg || {};
  if (!swg.transactionId || !swg.tenantId || !swg.profileId || !swg.policy) {
    return null;
  }
  return {
    mode: "swg",
    transactionId: swg.transactionId,
    orgId: swg.orgId || swg.tenantId || "",
    boundaryType: swg.boundaryType || "",
    boundaryId: swg.boundaryId || "",
    originId: swg.originId || "",
    originType: swg.originType || "",
    tenantId: swg.tenantId,
    profileId: swg.profileId,
    policy: swg.policy,
    contractVersion: swg.contractVersion || "",
    requestKind: swg.requestKind || "http-document",
    originalMethod: swg.originalMethod || "GET",
    provider: swg.provider || "",
    providerCategory: swg.providerCategory || "",
    fallbackProvider: swg.fallbackProvider || config.rbiFallbackProvider,
    fallbackReason: swg.fallbackReason || "",
    nonce: swg.nonce || "",
    keyId: swg.keyId || "",
    ...deriveUpstreamContext(swg, targetUrl),
  };
}

async function validateSwgHandoffRequest(searchParams, req = null) {
  if (!config.enableSwgBootstrap) {
    throw httpError(404, "SWG handoff is disabled");
  }

  const extractedHandoff = extractSwgHandoffQuery(searchParams);
  const handoffTransport = extractedHandoff.token ? "opaque" : "legacy";
  let handoff = extractedHandoff;

  if (handoffTransport === "opaque") {
    try {
      handoff = decryptSwgHandoffToken(extractedHandoff.token, config.swgSharedSecret);
    } catch (error) {
      structuredLog("warn", { component: "swg" }, "swg-handoff-invalid-token", {
        error: error.message || String(error),
      });
      throw httpError(401, "Invalid SWG handoff token");
    }
    requireSwgFields(handoff, [
      "timestamp",
      "transactionId",
      "sessionId",
      "targetUrl",
      "contractVersion",
      "requestKind",
      "originalMethod",
      "orgId",
      "boundaryType",
      "boundaryId",
      "originId",
      "originType",
      "tenantId",
      "profileId",
      "policy",
      "provider",
      "providerCategory",
      "fallbackProvider",
      "nonce",
      "keyId",
    ]);
  } else {
    requireSwgFields(handoff, [
      "signature",
      "timestamp",
      "transactionId",
      "sessionId",
      "targetUrl",
      "contractVersion",
      "requestKind",
      "originalMethod",
      "orgId",
      "boundaryType",
      "boundaryId",
      "originId",
      "originType",
      "tenantId",
      "profileId",
      "policy",
      "provider",
      "providerCategory",
      "fallbackProvider",
      "nonce",
      "keyId",
    ]);
  }
  requireOrgBoundaryContext(handoff);

  const session = await sessionStore.get(handoff.sessionId);
  if (!session) {
    throw httpError(404, "Session not found");
  }
  if (!isSwgAuthMode(session.client?.authMode)) {
    throw httpError(403, "Session is not eligible for SWG handoff");
  }
  if (String(handoff.method || "GET").trim().toUpperCase() !== "GET") {
    throw httpError(400, "Invalid SWG handoff method");
  }
  if (handoff.sessionId !== session.id) {
    throw httpError(400, "SWG handoff session mismatch");
  }
  if (handoff.targetUrl !== session.targetUrl) {
    throw httpError(400, "SWG handoff target mismatch");
  }

  const timestamp = Number(handoff.timestamp);
  if (!Number.isFinite(timestamp)) {
    throw httpError(400, "Invalid SWG handoff timestamp");
  }
  if (Math.abs(Date.now() - timestamp) > config.swgTimestampToleranceMs) {
    throw httpError(401, "Stale SWG handoff");
  }

  const upstream = deriveUpstreamContext(handoff, session.targetUrl);
  const storedSwg = deriveSwgSessionContext(session.client, session.targetUrl);
  const mismatches = [];
  for (const key of [
    "transactionId",
    "orgId",
    "boundaryType",
    "boundaryId",
    "originId",
    "originType",
    "tenantId",
    "profileId",
    "policy",
    "contractVersion",
    "requestKind",
    "originalMethod",
    "provider",
    "providerCategory",
    "fallbackProvider",
    "fallbackReason",
    "nonce",
    "keyId",
    "upstreamHost",
    "upstreamScheme",
    "upstreamPort",
  ]) {
    if (String(storedSwg?.[key] || "") !== String((key in upstream ? upstream : handoff)[key] || "")) {
      mismatches.push(key);
    }
  }
  if (mismatches.length) {
    throw httpError(400, `SWG handoff context mismatch: ${mismatches.join(", ")}`);
  }

  const canonicalInput = {
    method: "GET",
    sessionId: session.id,
    targetUrl: session.targetUrl,
    timestamp: handoff.timestamp,
    transactionId: handoff.transactionId,
    orgId: handoff.orgId,
    boundaryType: handoff.boundaryType,
    boundaryId: handoff.boundaryId,
    originId: handoff.originId,
    originType: handoff.originType,
    tenantId: handoff.tenantId,
    profileId: handoff.profileId,
    policy: handoff.policy,
    contractVersion: handoff.contractVersion,
    requestKind: handoff.requestKind,
    originalMethod: handoff.originalMethod,
    provider: handoff.provider,
    providerCategory: handoff.providerCategory,
    fallbackProvider: handoff.fallbackProvider,
    fallbackReason: handoff.fallbackReason,
    nonce: handoff.nonce,
    keyId: handoff.keyId,
    ...upstream,
  };
  if (
    handoffTransport === "legacy" &&
    !verifySwgHandoffRequest(canonicalInput, config.swgSharedSecret, handoff.signature)
  ) {
    const expectedSignature = signSwgHandoffRequest(canonicalInput, config.swgSharedSecret);
    structuredLog("warn", { sessionId: session.id, component: "swg" }, "swg-handoff-invalid-signature", {
      canonicalFingerprint: fingerprintValue(buildSwgHandoffCanonicalString(canonicalInput)),
      expectedSignatureFingerprint: fingerprintValue(expectedSignature),
      receivedSignatureFingerprint: fingerprintValue(handoff.signature),
    });
    throw httpError(401, "Invalid SWG handoff signature");
  }

  const replayKey = `handoff:${handoff.sessionId}:${handoff.transactionId}:${handoff.timestamp}:${handoff.nonce}`;
  if (!(await rememberReplay(replayKey))) {
    if (!req || !hasValidViewerCookieForSession(req, session)) {
      throw httpError(409, "Replayed SWG handoff");
    }
    structuredLog("info", { sessionId: session.id, component: "swg" }, "swg-handoff-replay-resumed", {
      transactionId: handoff.transactionId,
      tenantId: handoff.tenantId,
      profileId: handoff.profileId,
    });
    return {
      session,
      swgContext: { ...storedSwg, ...upstream },
      handoffTransport,
      handoffReplay: true,
    };
  }

  return {
    session,
    swgContext: { ...storedSwg, ...upstream },
    handoffTransport,
    handoffReplay: false,
  };
}

function clampViewportDimension(rawValue, fallback, minimum, maximum) {
  const value = Number(rawValue);
  if (!Number.isFinite(value)) {
    return fallback;
  }
  return Math.max(minimum, Math.min(maximum, Math.round(value)));
}

function normalizeSessionExperiments(experiments = {}) {
  return {
    sourceCoupledAv: experiments.sourceCoupledAv !== false,
  };
}

async function createRemoteSession(body, requestContext, options = {}) {
  const targetUrl = validateTargetUrl(body.targetUrl);
  const sessionPlacement = normalizeSessionPlacement(body.sessionPlacement);
  const transport = normalizeGatewayTransport(body.transport);
  const workerBridge = normalizeWorkerBridge(body.workerBridge);
  const viewport = {
    width: clampViewportDimension(body.viewport?.width, config.displayWidth, 640, config.displayWidth),
    height: clampViewportDimension(body.viewport?.height, config.displayHeight, 480, config.displayHeight),
    deviceScaleFactor: Number(body.viewport?.deviceScaleFactor) || 1,
  };

  if (config.singleActiveSessionMode) {
    for (const existing of await sessionStore.listSessions(500)) {
      if (existing.state !== "terminated") {
        await terminateSession(existing, "replaced by new session in single-session mode");
      }
    }
  }

  const session = await sessionStore.createSession({
    targetUrl,
    viewport,
    client: body.client || {},
    experiments: normalizeSessionExperiments(body.experiments || {}),
    viewerToken: "",
    workerToken: "",
    requestContext: requestContext || null,
    sessionPlacement,
    transport,
    workerBridge,
  });

  session.viewerToken = makeViewerToken(session.id, session.expiresAt);
  session.workerToken = makeWorkerToken(session.id, session.expiresAt, session.generation || 1);
  session.turnCredentials = buildTurnCredentialBundle(session);
  await sessionStore.update(session.id, {
    viewerToken: session.viewerToken,
    workerToken: session.workerToken,
    turnCredentials: session.turnCredentials,
  });

  const swgSessionContext = deriveSwgSessionContext(session.client, session.targetUrl);
  structuredLog("info", { sessionId: session.id, component: "session" }, "created", {
    targetUrl,
    authMode: requestContext?.mode || null,
    tenantId: requestContext?.tenantId || null,
    profileId: requestContext?.profileId || null,
    gatewayRegion: sessionPlacement?.gatewayAssignment?.region || null,
    gatewayId: sessionPlacement?.gatewayAssignment?.gatewayId || null,
    runtimeClass: sessionPlacement?.workerAssignment?.runtimeClass || null,
  });

  if (shouldDeferWorkerLaunch(session)) {
    structuredLog("info", { sessionId: session.id, component: "session" }, "worker-launch-deferred", {
      reason: "waiting for gateway webrtc transport",
      relayMode: sessionPlacement?.gatewayAssignment?.relayMode || null,
    });
  } else {
    try {
      await assignSessionWorker(session);
    } catch (error) {
      await sessionStore.remove(session.id);
      structuredLog("error", { sessionId: session.id, component: "session" }, "worker-launch-failed", {
        error: error.message || String(error),
      });
      throw error;
    }
  }

  return buildRuntimeSessionPayload(session, options);
}

function getLocalSocketRecord(sessionId) {
  if (!localSockets.has(sessionId)) {
    localSockets.set(sessionId, { viewer: null, worker: null });
  }
  return localSockets.get(sessionId);
}

function setLocalSocket(sessionId, role, ws) {
  getLocalSocketRecord(sessionId)[role] = ws;
}

function getLocalSocket(sessionId, role) {
  return getLocalSocketRecord(sessionId)[role];
}

function clearLocalSocket(sessionId, role, ws = null) {
  const record = localSockets.get(sessionId);
  if (!record) {
    return;
  }
  if (!ws || record[role] === ws) {
    record[role] = null;
  }
  if (!record.viewer && !record.worker) {
    localSockets.delete(sessionId);
  }
}

function setLocalPoolSocket(workerId, ws) {
  const existing = localPoolSockets.get(workerId);
  if (existing && existing !== ws) {
    closeSocket(existing, 1000, "superseded by a newer pool connection");
  }
  localPoolSockets.set(workerId, ws);
}

function getLocalPoolSocket(workerId) {
  return localPoolSockets.get(workerId) || null;
}

function clearLocalPoolSocket(workerId, ws = null) {
  const current = localPoolSockets.get(workerId);
  if (!current) {
    return;
  }
  if (!ws || current === ws) {
    localPoolSockets.delete(workerId);
  }
}

function buildSocketOwner(ws) {
  return {
    instanceId: CONTROL_PLANE_INSTANCE_ID,
    connectionId: String(ws?.connectionId || ""),
  };
}

function socketOwnerMatches(owner, ws) {
  return (
    String(owner?.instanceId || "") === CONTROL_PLANE_INSTANCE_ID &&
    String(owner?.connectionId || "") === String(ws?.connectionId || "")
  );
}

async function claimSessionSocketOwnership(sessionId, role, ws) {
  return sessionStore.claimSocketOwnership(sessionId, role, buildSocketOwner(ws));
}

async function isCurrentSessionSocketOwner(sessionId, role, ws) {
  const owner = await sessionStore.getSocketOwner(sessionId, role);
  return socketOwnerMatches(owner, ws);
}

async function releaseSessionSocketOwnership(sessionId, role, ws) {
  return sessionStore.releaseSocketOwnership(sessionId, role, buildSocketOwner(ws));
}

async function isCurrentPoolSocketOwner(workerId, ws) {
  const owner = await workerPoolStore.getSocketOwner(workerId);
  return socketOwnerMatches(owner, ws);
}

async function releasePoolSocketOwnership(workerId, ws) {
  return workerPoolStore.releaseSocketOwnership(workerId, buildSocketOwner(ws));
}

function timerKey(sessionId, role) {
  return `${sessionId}:${role}`;
}

function clearDisconnectTimer(sessionId, role) {
  const key = timerKey(sessionId, role);
  const timer = disconnectTimers.get(key);
  if (timer) {
    clearTimeout(timer);
    disconnectTimers.delete(key);
  }
}

function setDisconnectTimer(sessionId, role, delayMs, fn) {
  clearDisconnectTimer(sessionId, role);
  const timer = setTimeout(fn, delayMs);
  timer.unref();
  disconnectTimers.set(timerKey(sessionId, role), timer);
}

function scheduleViewerIdleTimeout(sessionId) {
  setDisconnectTimer(sessionId, "viewer", config.idleTimeoutMs, () => {
    void (async () => {
      const current = await sessionStore.get(sessionId);
      if (current && (await sessionStore.shouldIdleTerminate(sessionId))) {
        await terminateSession(current, "viewer idle timeout");
      }
    })();
  });
}

async function markViewerDisconnectedAndSchedule(sessionId, reason = "viewer disconnected") {
  const session = await sessionStore.get(sessionId);
  if (!session || session.state === "terminated") {
    return;
  }
  await sessionStore.markViewerDisconnected(sessionId, reason);
  await sessionStore.setState(sessionId, "idle");
  structuredLog("info", { sessionId, component: "session" }, "viewer-disconnected", {
    reason,
    idleTimeoutMs: config.idleTimeoutMs,
    workerId: session.worker?.workerId || session.worker?.jobName || null,
    launchMode: session.worker?.launchMode || null,
  });
  scheduleViewerIdleTimeout(sessionId);
}

function scheduleWorkerDisconnectTermination(sessionId, generation = null) {
  setDisconnectTimer(sessionId, "worker", 3000, () => {
    void (async () => {
      const current = await sessionStore.get(sessionId);
      if (!current || current.state === "terminated") {
        return;
      }
      if (generation !== null && current.generation !== generation) {
        return;
      }
      const workerSocket = getLocalSocket(sessionId, "worker");
      if (workerSocket?.readyState === WebSocket.OPEN) {
        return;
      }
      await terminateSession(current, "worker disconnected");
    })();
  });
}

async function recordGatewayViewerConnected(sessionId) {
  clearDisconnectTimer(sessionId, "viewer");
  await sessionStore.markViewerConnected(sessionId);
}

async function recordGatewayViewerSeen(sessionId) {
  await sessionStore.markViewerSeen(sessionId);
}

async function recordGatewayViewerDisconnected(sessionId) {
  await markViewerDisconnectedAndSchedule(sessionId, "gateway viewer disconnected");
}

async function recordGatewayWorkerReady(sessionId) {
  clearDisconnectTimer(sessionId, "worker");
  await sessionStore.setState(sessionId, "ready");
}

async function recordGatewayWorkerState(sessionId, state) {
  await sessionStore.setState(sessionId, state);
}

async function recordGatewayWorkerDisconnected(sessionId, generation = null) {
  scheduleWorkerDisconnectTermination(sessionId, generation);
}

function closeSocket(ws, code = 1000, reason = "") {
  try {
    ws?.close(code, reason);
  } catch {
    // Ignore close races.
  }
}

async function sendSignal(sessionId, role, payload) {
  const target = getLocalSocket(sessionId, role);
  if (
    target?.readyState === WebSocket.OPEN &&
    (await isCurrentSessionSocketOwner(sessionId, role, target))
  ) {
    target.send(JSON.stringify(payload));
    return;
  }
  await sessionStore.addPendingSignal(sessionId, role, payload);
  await signalBus.notifyPendingSignal(sessionId, role);
}

async function flushSignals(sessionId, role) {
  const target = getLocalSocket(sessionId, role);
  if (!target || target.readyState !== WebSocket.OPEN) {
    return;
  }
  if (!(await isCurrentSessionSocketOwner(sessionId, role, target))) {
    return;
  }
  for (const payload of await sessionStore.drainPendingSignals(sessionId, role)) {
    if (target.readyState !== WebSocket.OPEN) {
      await sessionStore.addPendingSignal(sessionId, role, payload);
      await signalBus.notifyPendingSignal(sessionId, role);
      return;
    }
    target.send(JSON.stringify(payload));
  }
}

async function flushPoolAssignments(workerId) {
  const target = getLocalPoolSocket(workerId);
  if (!target || target.readyState !== WebSocket.OPEN) {
    return;
  }
  if (!(await isCurrentPoolSocketOwner(workerId, target))) {
    return;
  }
  const messages = await workerPoolStore.drainPendingAssignments(workerId);
  for (let index = 0; index < messages.length; index += 1) {
    const payload = messages[index];
    if (target.readyState !== WebSocket.OPEN) {
      for (const pending of messages.slice(index)) {
        await workerPoolStore.addPendingAssignment(workerId, pending);
      }
      await workerPoolBus.notifyPendingAssignment(workerId);
      return;
    }
    if (!(await isCurrentPoolSocketOwner(workerId, target))) {
      for (const pending of messages.slice(index)) {
        await workerPoolStore.addPendingAssignment(workerId, pending);
      }
      await workerPoolBus.notifyPendingAssignment(workerId);
      return;
    }
    target.send(JSON.stringify(payload));
  }
}

async function allocateWarmWorker(sessionId, assignmentPayload, filters = {}) {
  const deadline = Date.now() + Math.max(0, config.warmPoolAllocationWaitMs);

  while (true) {
    const worker = await workerPoolStore.allocateWorkerWithAssignment(
      sessionId,
      assignmentPayload,
      filters,
    );
    if (worker) {
      const poolSocket = getLocalPoolSocket(worker.workerId);
      const hasLocalOwnerSocket =
        poolSocket?.readyState === WebSocket.OPEN &&
        (await isCurrentPoolSocketOwner(worker.workerId, poolSocket));
      const poolOwner = hasLocalOwnerSocket
        ? buildSocketOwner(poolSocket)
        : await workerPoolStore.getSocketOwner(worker.workerId);
      if (!poolOwner) {
        structuredLog("warn", { sessionId, component: "pool" }, "skip-stale-pool-worker", {
          workerId: worker.workerId,
          state: worker.state || "unknown",
          hasSocket: Boolean(poolSocket),
          socketState: poolSocket?.readyState ?? null,
        });
        await workerPoolStore.unregisterWorker(worker.workerId);
        continue;
      }
      return worker;
    }

    if (!config.warmPoolEnabled || Date.now() >= deadline) {
      return null;
    }

    await new Promise((resolve) => {
      setTimeout(resolve, WARM_POOL_POLL_INTERVAL_MS);
    });
  }
}

async function fallbackWarmPoolSession(sessionId, poolWorkerId, reason) {
  const session = await sessionStore.get(sessionId);
  if (!session || session.state === "terminated") {
    return;
  }
  if (session.state !== "allocating") {
    return;
  }
  if (
    session.worker?.launchMode !== "warm-pool" ||
    session.worker?.poolWorkerId !== poolWorkerId ||
    getLocalSocket(sessionId, "worker")?.readyState === WebSocket.OPEN
  ) {
    return;
  }

  structuredLog("warn", { sessionId, component: "session" }, "warm-pool-fallback-start", {
    poolWorkerId,
    reason,
    state: session.state,
  });

  try {
    const nextGeneration = await sessionStore.incrementGeneration(sessionId);
    if (!nextGeneration) {
      return;
    }
    const workerToken = makeWorkerToken(
      sessionId,
      nextGeneration.expiresAt,
      nextGeneration.generation || 1,
    );
    const replacementSession = await sessionStore.update(sessionId, { workerToken });
    if (!replacementSession) {
      return;
    }
    replacementSession.workerToken = workerToken;
    await sessionStore.setState(sessionId, "allocating");
    await sendSignal(sessionId, "viewer", {
      type: "worker-state",
      state: "allocating",
      reason: "warm-pool fallback",
    });

    const replacement = await workerRuntime.launch(replacementSession);
    replacementSession.worker = replacement;
    await sessionStore.setWorker(sessionId, replacement);
    structuredLog("info", { sessionId, component: "session" }, "worker-assigned", {
      launchMode: replacement.launchMode || null,
      workerId: replacement.workerId || null,
      taskArn: replacement.taskArn || null,
      jobName: replacement.jobName || null,
      namespace: replacement.namespace || null,
      generation: replacementSession.generation || 1,
      replacementReason: reason,
    });
  } catch (error) {
    structuredLog("error", { sessionId, component: "session" }, "warm-pool-fallback-failed", {
      poolWorkerId,
      reason,
      error: error.message || String(error),
    });
    await terminateSession(sessionId, "worker launch failed after warm-pool fallback");
  }
}

async function terminateSession(sessionOrId, reason = "session ended") {
  const session = typeof sessionOrId === "string" ? await sessionStore.get(sessionOrId) : sessionOrId;
  if (!session || session.state === "terminated") {
    return;
  }
  const acquired = await sessionStore.acquireTerminationLock(session.id, 30_000);
  if (!acquired) {
    return;
  }
  structuredLog("info", { sessionId: session.id, component: "session" }, "terminate", {
    reason,
    state: session.state,
  });
  await sessionStore.setState(session.id, "terminated");
  if (usesGatewaySignaling(session)) {
    await notifyGatewaySessionTermination(session, reason);
  }
  await sendSignal(session.id, "viewer", { type: "session-terminated", sessionId: session.id, reason });
  await sendSignal(session.id, "worker", { type: "session-terminated", sessionId: session.id, reason });
  closeSocket(getLocalSocket(session.id, "viewer"), 1000, reason);
  closeSocket(getLocalSocket(session.id, "worker"), 1000, reason);
  clearLocalSocket(session.id, "viewer");
  clearLocalSocket(session.id, "worker");
  if (session.worker?.launchMode !== "warm-pool") {
    await workerRuntime.stop(session.worker);
  }
}

async function notifyGatewaySessionTermination(session, reason) {
  const gatewayBaseUrl = getGatewayAssignmentValue(session, "publicBaseURL");
  if (!gatewayBaseUrl || !config.rbiInternalSharedSecret) {
    return;
  }
  const endpoint = appendBaseUrlPath(
    gatewayBaseUrl,
    `/v1/sessions/${encodeURIComponent(session.id)}/terminate`,
  );
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-RBI-Internal-Secret": config.rbiInternalSharedSecret,
      },
      body: JSON.stringify({ reason }),
      signal: AbortSignal.timeout(config.gatewayControlTimeoutMs),
    });
    if (!response.ok) {
      structuredLog("warn", { sessionId: session.id, component: "gateway" }, "gateway-terminate-rejected", {
        statusCode: response.status,
        endpoint,
      });
    }
  } catch (error) {
    structuredLog("warn", { sessionId: session.id, component: "gateway" }, "gateway-terminate-failed", {
      endpoint,
      error: error.message || String(error),
    });
  }
}

async function applyInternalSessionEvent(sessionId, body = {}) {
  const session = await sessionStore.get(sessionId);
  if (!session) {
    throw httpError(404, "Session not found");
  }

  const action = normalizeHeaderValue(body.action).toLowerCase();
  const state = normalizeHeaderValue(body.state);
  const reason = normalizeHeaderValue(body.reason);
  const generation = Number.isFinite(Number(body.generation)) ? Number(body.generation) : null;

  if (session.state === "terminated") {
    return { sessionId, state: "terminated", reason: reason || "session already terminated" };
  }

  switch (action) {
    case "viewer-connected":
      await recordGatewayViewerConnected(sessionId);
      break;
    case "viewer-seen":
      await recordGatewayViewerSeen(sessionId);
      break;
    case "viewer-disconnected":
      await recordGatewayViewerDisconnected(sessionId);
      break;
    case "worker-ready":
      await recordGatewayWorkerReady(sessionId);
      break;
    case "worker-state":
      if (!state) {
        throw httpError(400, "worker-state requires state");
      }
      await recordGatewayWorkerState(sessionId, state);
      break;
    case "worker-disconnected":
      await recordGatewayWorkerDisconnected(sessionId, generation);
      break;
    case "media-terminated":
      await terminateSession(session, reason || "gateway media terminated");
      break;
    default:
      throw httpError(400, "Unsupported internal session event");
  }

  const updated = await sessionStore.get(sessionId);
  return {
    sessionId,
    action,
    state: updated?.state || session.state,
    generation: updated?.generation || session.generation || 1,
  };
}

async function applyInternalSessionUpdate(sessionId, body = {}) {
  const session = await sessionStore.get(sessionId);
  if (!session) {
    throw httpError(404, "Session not found");
  }

  const patch = {};
  if (Object.prototype.hasOwnProperty.call(body, "sessionPlacement")) {
    patch.sessionPlacement = normalizeSessionPlacement(body.sessionPlacement);
  }
  if (Object.prototype.hasOwnProperty.call(body, "transport")) {
    patch.transport = normalizeGatewayTransport(body.transport);
  }
  if (Object.prototype.hasOwnProperty.call(body, "workerBridge")) {
    patch.workerBridge = normalizeWorkerBridge(body.workerBridge);
  }
  if (!Object.keys(patch).length) {
    throw httpError(400, "No internal session update fields provided");
  }

  const updated = await sessionStore.update(sessionId, patch);
  if (!updated) {
    throw httpError(404, "Session not found");
  }
  if (!updated.worker && updated.state !== "terminated" && !shouldDeferWorkerLaunch(updated)) {
    try {
      await assignSessionWorker(updated);
      return (await sessionStore.get(sessionId)) || updated;
    } catch (error) {
      structuredLog("error", { sessionId, component: "session" }, "worker-launch-failed", {
        error: error.message || String(error),
        phase: "internal-session-update",
      });
      await terminateSession(updated, "worker launch failed after gateway transport update");
      throw error;
    }
  }
  return updated;
}

function staticMime(filePath) {
  if (filePath.endsWith(".html")) {
    return "text/html; charset=utf-8";
  }
  if (filePath.endsWith(".js")) {
    return "text/javascript; charset=utf-8";
  }
  if (filePath.endsWith(".css")) {
    return "text/css; charset=utf-8";
  }
  if (filePath.endsWith(".json")) {
    return "application/json; charset=utf-8";
  }
  return "application/octet-stream";
}

async function sendFile(res, rootDir, relativePath, headers = {}) {
  const root = path.resolve(rootDir);
  const fullPath = path.resolve(root, relativePath.replace(/^\/+/, ""));
  if (!fullPath.startsWith(`${root}${path.sep}`) && fullPath !== root) {
    throw httpError(404, "Not found");
  }
  const body = await fs.readFile(fullPath);
  writeResponse(
    res,
    200,
    {
      "Content-Type": staticMime(fullPath),
      ...headers,
    },
    body,
  );
}

function enforceSameOrigin(req) {
  const origin = normalizeHeaderValue(req.headers.origin);
  if (origin && origin !== config.publicOrigin) {
    throw httpError(403, "Invalid origin");
  }
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "OPTIONS") {
      writeResponse(res, 204, { Allow: "GET, HEAD, POST, PATCH, DELETE, OPTIONS" });
      return;
    }

    const requestUrl = new URL(req.url, config.publicBaseUrl);

    if (req.method === "GET" && requestUrl.pathname === "/api/health") {
      const readiness = await buildBackendReadiness();
      json(res, readiness.ok ? 200 : 503, {
        ok: readiness.ok,
        service: "cloudsec_remote_browser",
        store: config.sessionStoreBackend,
        signalBus: config.signalBusBackend,
        workerPoolStore: config.workerPoolStoreBackend,
        workerPoolBus: config.workerPoolBusBackend,
        workerLaunchMode: config.workerLaunchMode,
        sessionAuthorityBootstrapUrl: config.sessionAuthorityBootstrapUrl || null,
        backends: readiness.backends,
        redis: readiness.redis,
      });
      return;
    }

    if (req.method === "POST" && requestUrl.pathname === "/api/internal/sessions") {
      requireRbiInternalSecret(req);
      const body = await parseJsonBody(req);
      const options = {
        publicBaseUrl: normalizeHeaderValue(body.publicBaseUrl) || buildRequestBaseUrl(req, config.publicBaseUrl),
        publicWsUrl: normalizeHeaderValue(body.publicWsUrl) || buildRequestWsUrl(req, "/ws", config.publicWsUrl),
      };
      const payload = await createRemoteSession(
        body,
        normalizeObject(body.requestContext),
        options,
      );
      const session = await sessionStore.get(payload.sessionId);
      json(res, 201, buildInternalSessionResponse(session, options));
      return;
    }

    const internalSessionId = req.method === "PATCH" ? parseInternalSessionPath(requestUrl.pathname) : null;
    if (req.method === "PATCH" && internalSessionId) {
      requireRbiInternalSecret(req);
      const body = await parseJsonBody(req);
      const options = {
        publicBaseUrl: normalizeHeaderValue(body.publicBaseUrl) || buildRequestBaseUrl(req, config.publicBaseUrl),
        publicWsUrl: normalizeHeaderValue(body.publicWsUrl) || buildRequestWsUrl(req, "/ws", config.publicWsUrl),
      };
      const session = await applyInternalSessionUpdate(internalSessionId, body);
      json(res, 200, buildInternalSessionResponse(session, options));
      return;
    }

    const internalSessionEventId = req.method === "POST" ? parseInternalSessionEventPath(requestUrl.pathname) : null;
    if (req.method === "POST" && internalSessionEventId) {
      requireRbiInternalSecret(req);
      const body = await parseJsonBody(req);
      const payload = await applyInternalSessionEvent(internalSessionEventId, body);
      json(res, 200, payload);
      return;
    }

    if (req.method === "POST" && requestUrl.pathname === "/api/swg/sessions") {
      const body = await parseJsonBody(req);
      const targetUrl = resolveSwgBootstrapTargetUrl(req, body);
      const swgContext = await validateSwgBootstrapRequest(req, targetUrl);
      const idempotency = await beginSwgBootstrapIdempotency(swgContext);
      if (!idempotency.acquired) {
        const payload = idempotency.response;
        if (wantsSwgBootstrapRedirectResponse(req)) {
          writeResponse(res, 303, {
            Location: payload.handoffUrl || payload.viewerUrl,
            "Content-Type": "application/json; charset=utf-8",
            "X-RBI-Session-Id": payload.sessionId,
            "X-RBI-Viewer-Entry-Mode": payload.viewerEntryMode,
            "X-RBI-Idempotent-Replay": "true",
          });
          return;
        }
        json(res, idempotency.statusCode || 200, {
          ...payload,
          idempotentReplay: true,
        });
        return;
      }

      const sessionRequestBody = {
        ...body,
        targetUrl,
        client: {
          ...(body.client || {}),
          identity: swgContext.identity,
          authMode: swgContext.mode,
          swg: {
            transactionId: swgContext.transactionId,
            orgId: swgContext.orgId,
            boundaryType: swgContext.boundaryType,
            boundaryId: swgContext.boundaryId,
            originId: swgContext.originId,
            originType: swgContext.originType,
            tenantId: swgContext.tenantId,
            profileId: swgContext.profileId,
            policy: swgContext.policy,
            contractVersion: swgContext.contractVersion,
            requestKind: swgContext.requestKind,
            originalMethod: swgContext.originalMethod,
            provider: swgContext.provider,
            providerCategory: swgContext.providerCategory,
            fallbackProvider: swgContext.fallbackProvider,
            fallbackReason: swgContext.fallbackReason,
            nonce: swgContext.nonce,
            keyId: swgContext.keyId,
            upstreamHost: swgContext.upstreamHost,
            upstreamScheme: swgContext.upstreamScheme,
            upstreamPort: swgContext.upstreamPort,
          },
        },
      };
      const requestOptions = {
        publicBaseUrl: buildRequestBaseUrl(req, config.publicBaseUrl),
        publicWsUrl: buildRequestWsUrl(req, "/ws", config.publicWsUrl),
      };
      let responsePayload;
      try {
        const payload = config.sessionAuthorityBootstrapUrl
          ? await delegateSwgBootstrapToSessionAuthority(
              sessionRequestBody,
              targetUrl,
              swgContext,
              requestOptions,
            )
          : await createRemoteSession(sessionRequestBody, swgContext, requestOptions);
        const session = payload.sessionId ? await sessionStore.get(payload.sessionId) : null;
        responsePayload = {
          ...payload,
          handoffUrl: payload.handoffUrl || payload.viewerUrl,
          viewerCookie: session ? buildViewerCookieDescriptor(session) : null,
          swgContext: {
            transactionId: swgContext.transactionId,
            tenantId: swgContext.tenantId,
            profileId: swgContext.profileId,
            policy: swgContext.policy,
            upstreamHost: swgContext.upstreamHost,
            upstreamScheme: swgContext.upstreamScheme,
            upstreamPort: swgContext.upstreamPort,
          },
        };
        await completeSwgBootstrapIdempotency(
          idempotency.key,
          swgContext.requestFingerprint,
          responsePayload,
          200,
        );
      } catch (error) {
        await failSwgBootstrapIdempotency(idempotency.key, swgContext.requestFingerprint, error);
        throw error;
      }
      if (wantsSwgBootstrapRedirectResponse(req)) {
        writeResponse(res, 303, {
          Location: responsePayload.handoffUrl || responsePayload.viewerUrl,
          "Content-Type": "application/json; charset=utf-8",
          "X-RBI-Session-Id": responsePayload.sessionId,
          "X-RBI-Viewer-Entry-Mode": responsePayload.viewerEntryMode,
        });
        return;
      }
      json(res, 201, responsePayload);
      return;
    }

    if ((req.method === "GET" || req.method === "HEAD") && requestUrl.pathname === "/swg/handoff") {
      const { session, swgContext, handoffTransport, handoffReplay } = await validateSwgHandoffRequest(
        requestUrl.searchParams,
        req,
      );
      structuredLog("info", { sessionId: session.id, component: "swg" }, "swg-handoff-issued", {
        transactionId: swgContext.transactionId,
        tenantId: swgContext.tenantId,
        profileId: swgContext.profileId,
        policy: swgContext.policy,
        handoffTransport,
        replay: Boolean(handoffReplay),
      });
      redirect(
        res,
        normalizeHeaderValue(session?.transport?.viewerUrl) ||
          `${buildRequestBaseUrl(req, config.publicBaseUrl)}/viewer?sessionId=${encodeURIComponent(session.id)}`,
        buildViewerCookieHeaders(session),
      );
      return;
    }

    const viewerEventSessionId =
      req.method === "POST" ? parseSessionSubresourcePath(requestUrl.pathname, "viewer-events") : "";
    if (req.method === "POST" && viewerEventSessionId) {
      enforceSameOrigin(req);
      const session = await sessionStore.get(viewerEventSessionId);
      const extraHeaders = validateViewerAccess(req, session);
      const body = await parseJsonBody(req);
      const eventPayload = sanitizeViewerEventPayload(body);
      structuredLog("info", { sessionId: viewerEventSessionId, component: "viewer" }, "viewer-event", {
        event: normalizeHeaderValue(eventPayload.type || eventPayload.event || "viewer-event"),
        payload: eventPayload,
      });
      const telemetrySummary = summarizeViewerTelemetryPayload(eventPayload);
      if (telemetrySummary) {
        structuredLog("info", { sessionId: viewerEventSessionId, component: "viewer" }, "viewer-telemetry-summary", {
          summary: telemetrySummary,
        });
      }
      await sessionStore.appendViewerTelemetry(
        viewerEventSessionId,
        {
          ...eventPayload,
          summary: telemetrySummary,
        },
        { maxEvents: config.viewerTelemetryMaxEvents },
      );
      const disconnectReason = viewerEventDisconnectReason(eventPayload);
      if (disconnectReason) {
        await markViewerDisconnectedAndSchedule(viewerEventSessionId, disconnectReason);
      } else {
        await sessionStore.markViewerSeen(viewerEventSessionId);
      }
      json(res, 202, { ok: true, sessionId: viewerEventSessionId }, extraHeaders);
      return;
    }

    const viewerTelemetryExportSessionId =
      req.method === "GET" ? parseSessionSubresourcePath(requestUrl.pathname, "viewer-events") : "";
    if (req.method === "GET" && viewerTelemetryExportSessionId) {
      enforceSameOrigin(req);
      const session = await sessionStore.get(viewerTelemetryExportSessionId);
      const extraHeaders = validateViewerAccess(req, session);
      const limit = normalizeViewerTelemetryExportLimit(requestUrl.searchParams.get("limit"));
      const events = await sessionStore.listViewerTelemetry(viewerTelemetryExportSessionId, {
        limit,
      });
      await sessionStore.markViewerSeen(viewerTelemetryExportSessionId);
      json(
        res,
        200,
        {
          sessionId: viewerTelemetryExportSessionId,
          count: events.length,
          events,
        },
        extraHeaders,
      );
      return;
    }

    if (
      req.method === "POST" &&
      requestUrl.pathname.startsWith("/api/sessions/") &&
      requestUrl.pathname.endsWith("/refresh")
    ) {
      enforceSameOrigin(req);
      const sessionId = requestUrl.pathname.split("/").filter(Boolean).at(-2);
      const session = sessionId ? await sessionStore.get(sessionId) : null;
      validateViewerAccess(req, session);
      if (isSwgAuthMode(session.client?.authMode) && !session.viewerConnectedAt) {
        throw httpError(409, "SWG viewer handoff has not connected yet");
      }
      if (
        !session.viewerConnectedAt &&
        Date.now() - Number(session.createdAt || 0) < config.viewerRefreshMinSessionAgeMs
      ) {
        throw httpError(409, "Session is still in initial viewer handoff");
      }
      const body = await parseJsonBody(req);
      const payload = await createRemoteSession(
        {
          targetUrl: session.targetUrl,
          viewport: body.viewport,
          experiments: { ...(session.experiments || {}), ...(body.experiments || {}) },
          sessionPlacement: session.sessionPlacement || undefined,
          transport: session.transport || undefined,
          workerBridge: session.workerBridge || undefined,
          client: {
            ...(session.client || {}),
            ...(body.client || {}),
            sourceSessionId: session.id,
            refreshOfSessionId: session.id,
          },
        },
        deriveSwgSessionContext(session.client, session.targetUrl) || session.client,
        {
          publicBaseUrl: buildRequestBaseUrl(req, config.publicBaseUrl),
          publicWsUrl: buildRequestWsUrl(req, "/ws", config.publicWsUrl),
        },
      );
      const replacementSession = await sessionStore.get(payload.sessionId);
      json(res, 201, payload, buildViewerCookieHeaders(replacementSession));
      return;
    }

    if (req.method === "GET" && requestUrl.pathname.startsWith("/api/sessions/")) {
      const sessionId = requestUrl.pathname.split("/").pop();
      const session = await sessionStore.get(sessionId);
      const extraHeaders = validateViewerAccess(req, session);
      await sessionStore.markViewerSeen(sessionId);
      json(
        res,
        200,
        {
          ...viewerSnapshot(session),
          signalingUrl: buildSessionSignalingUrl(
            session,
            "viewer",
            buildRequestWsUrl(req, "/ws", config.publicWsUrl),
          ),
          signalingMode: usesGatewaySignaling(session) ? "gateway" : "direct",
          viewerSignalingToken: usesGatewaySignaling(session) ? session.viewerToken : "",
          ...buildIceConfigPayload(session),
        },
        extraHeaders,
      );
      return;
    }

    if (req.method === "DELETE" && requestUrl.pathname.startsWith("/api/sessions/")) {
      enforceSameOrigin(req);
      const sessionId = requestUrl.pathname.split("/").pop();
      const session = await sessionStore.get(sessionId);
      validateViewerAccess(req, session);
      await terminateSession(session, "viewer ended session");
      json(res, 200, { sessionId, state: "terminated" }, clearViewerCookieHeaders(sessionId));
      return;
    }

    if (
      (req.method === "GET" || req.method === "HEAD") &&
      parseGatewayViewerPath(requestUrl.pathname)
    ) {
      const gatewayViewer = parseGatewayViewerPath(requestUrl.pathname);
      redirect(
        res,
        `${buildRequestBaseUrl(req, config.publicBaseUrl)}/viewer?sessionId=${encodeURIComponent(gatewayViewer.sessionId)}`,
      );
      return;
    }

    if (
      (req.method === "GET" || req.method === "HEAD") &&
      (requestUrl.pathname === "/viewer" ||
        requestUrl.pathname === "/viewer/" ||
        requestUrl.pathname === "/viewer.html")
    ) {
      const sessionId = requestUrl.searchParams.get("sessionId");
      if (sessionId) {
        const session = await sessionStore.get(sessionId);
        if (session && shouldRedirectSwgViewerEntry(req, session)) {
          const swgContext = deriveSwgSessionContext(session.client, session.targetUrl);
          if (swgContext) {
            redirect(res, buildSwgHandoffUrl(session, swgContext, buildRequestBaseUrl(req, config.publicBaseUrl)));
            return;
          }
        }
        if (session) {
          validateViewerAccess(req, session);
          await sessionStore.markViewerSeen(sessionId);
        }
      }
      await sendFile(res, config.staticDir, "index.html");
      return;
    }

    if ((req.method === "GET" || req.method === "HEAD") && ["/viewer.js", "/viewer.css"].includes(requestUrl.pathname)) {
      await sendFile(res, config.staticDir, requestUrl.pathname);
      return;
    }

    if (req.method === "GET" && requestUrl.pathname.startsWith("/shared/")) {
      await sendFile(res, config.sharedStaticDir, requestUrl.pathname.replace(/^\/shared\//, ""));
      return;
    }

    json(res, 404, { error: "Not found" });
  } catch (error) {
    structuredLog("error", { component: "http" }, "request-failed", {
      method: req.method,
      url: redactSensitiveRequestUrl(req.url),
      statusCode: error.statusCode || 500,
      error: error.message || String(error),
    });
    json(res, error.statusCode || 500, {
      error: error.message || "Unexpected error",
      ...(error.debugPayload || {}),
    });
  }
});

signalBus.onPendingSignal(({ sessionId, role }) => {
  flushSignals(sessionId, role).catch((error) => {
    structuredLog("error", { sessionId, role, component: "signal" }, "flush-pending-signals-failed", {
      error: error.message,
    });
  });
});

workerPoolBus.onPendingAssignment(({ workerId }) => {
  flushPoolAssignments(workerId).catch((error) => {
    structuredLog("error", { component: "pool" }, "flush-pool-assignment-failed", {
      workerId,
      error: error.message,
    });
  });
});

wss.on("connection", (ws, req) => {
  const requestUrl = new URL(req.url, config.publicBaseUrl);
  const requestPath = requestUrl.pathname;
  const gatewaySignalRoute = parseGatewaySignalingPath(requestPath);
  ws.connectionId = crypto.randomUUID();
  let registeredSessionId = null;
  let registeredRole = null;
  let registeredGeneration = null;
  let registeredPoolWorkerId = null;

  ws.on("message", (raw) => {
    void (async () => {
      try {
        const message = JSON.parse(String(raw));
        if (message.type === "pool-register") {
          if (!isPoolRegistrationPath(requestPath)) {
            throw new Error("Pool worker registration is not allowed on this WebSocket path");
          }
          if (!config.warmPoolEnabled) {
            throw new Error("Warm pool is not enabled");
          }
          if (config.poolWorkerSecret && message.secret !== config.poolWorkerSecret) {
            throw new Error("Invalid pool worker registration");
          }
          const workerId = normalizeHeaderValue(message.workerId);
          if (!workerId) {
            throw new Error("Pool worker registration requires workerId");
          }

          registeredPoolWorkerId = workerId;
          const workerRegistration = normalizePoolWorkerRegistration(message, ws);
          await workerPoolStore.registerWorker(workerRegistration);
          setLocalPoolSocket(workerId, ws);
          structuredLog("info", { component: "pool" }, "pool-worker-registered", {
            workerId,
            taskArn: workerRegistration.taskArn || null,
            runtimeId: workerRegistration.runtimeId || null,
            region: workerRegistration.region || null,
            runtimeClass: workerRegistration.runtimeClass || null,
            mediaMode: workerRegistration.mediaMode || null,
            imageDigest: workerRegistration.imageDigest || null,
            displayClass: workerRegistration.displayClass || null,
          });
          ws.send(JSON.stringify({ type: "registered", role: "pool-worker", workerId }));
          await flushPoolAssignments(workerId);
          return;
        }

        if (message.type === "register") {
          if (gatewaySignalRoute) {
            if (message.role !== gatewaySignalRoute.role) {
              throw new Error("Socket role does not match gateway signaling path");
            }
            if (String(message.sessionId || "") !== gatewaySignalRoute.sessionId) {
              throw new Error("Socket sessionId does not match gateway signaling path");
            }
          } else {
            if (message.role === "viewer" && requestPath !== "/ws") {
              throw new Error("Viewer registration is not allowed on this WebSocket path");
            }
            if (message.role === "worker" && requestPath !== "/ws/worker") {
              throw new Error("Worker registration is not allowed on this WebSocket path");
            }
          }
          const session = await sessionStore.get(message.sessionId);
          if (!session) {
            throw new Error("Session not found");
          }
          if (session.state === "terminated") {
            throw new Error("Session is terminated");
          }
          if (Date.now() > session.expiresAt) {
            throw new Error("Session has expired");
          }
          if (usesGatewaySignaling(session) && !gatewaySignalRoute) {
            throw new Error("Session requires gateway signaling");
          }
          if (!usesGatewaySignaling(session) && gatewaySignalRoute) {
            throw new Error("Session does not support gateway signaling");
          }

          const token =
            message.role === "viewer"
              ? getSessionToken(req, message.sessionId, message.role, message.token)
              : message.token;
          const payload = verifySessionToken({
            token,
            session,
            role: message.role,
            secret: config.tokenSecret,
          });

          registeredSessionId = message.sessionId;
          registeredRole = message.role;
          registeredGeneration = session.generation || 1;
          await claimSessionSocketOwnership(message.sessionId, message.role, ws);
          clearDisconnectTimer(message.sessionId, message.role);
          setLocalSocket(message.sessionId, message.role, ws);

          if (message.role === "worker") {
            await sessionStore.setState(message.sessionId, "ready");
          } else {
            await sessionStore.markViewerConnected(message.sessionId);
          }
          structuredLog("info", { sessionId: message.sessionId, role: message.role, component: "signal" }, "registered", {
            generation: registeredGeneration,
            tokenSource: payload.source,
          });
          ws.send(JSON.stringify({ type: "registered", role: message.role }));
          await flushSignals(message.sessionId, message.role);
          return;
        }

        if (registeredPoolWorkerId) {
          const ownsPoolSocket = await isCurrentPoolSocketOwner(registeredPoolWorkerId, ws);
          if (!ownsPoolSocket) {
            structuredLog("info", { component: "pool" }, "ignore-stale-pool-socket-message", {
              workerId: registeredPoolWorkerId,
              type: message.type,
            });
            closeSocket(ws, 1000, "superseded by a newer pool connection");
            return;
          }
        }

        if (message.type === "heartbeat") {
          if (registeredSessionId && registeredRole === "viewer") {
            await sessionStore.markViewerSeen(registeredSessionId);
          }
          if (registeredPoolWorkerId) {
            await workerPoolStore.heartbeatWorker(registeredPoolWorkerId, {
              metadata: message.metadata || {},
            });
          }
          ws.send(
            JSON.stringify({
              type: "heartbeat-ack",
              sessionId: registeredSessionId,
              workerId: registeredPoolWorkerId,
              ts: Date.now(),
            }),
          );
          return;
        }

        if (registeredPoolWorkerId && message.type === "pool-state") {
          if (message.state === "idle") {
            const lastSessionId = message.lastSessionId || null;
            await workerPoolStore.markWorkerIdle(registeredPoolWorkerId, {
              metadata: message.metadata || {},
              lastSessionId,
              region: message.region || null,
              runtimeClass: message.runtimeClass || null,
              mediaMode: message.mediaMode || null,
              imageDigest: message.imageDigest || null,
              displayClass: message.displayClass || null,
            });
            if (lastSessionId) {
              await fallbackWarmPoolSession(
                lastSessionId,
                registeredPoolWorkerId,
                "pool worker returned idle before session worker registration",
              );
            }
          } else {
            await workerPoolStore.markWorkerBusy(registeredPoolWorkerId, {
              state: message.state || "assigned",
              sessionId: message.sessionId || null,
              metadata: message.metadata || {},
              region: message.region || null,
              runtimeClass: message.runtimeClass || null,
              mediaMode: message.mediaMode || null,
              imageDigest: message.imageDigest || null,
              displayClass: message.displayClass || null,
            });
          }
          return;
        }

        if (!registeredSessionId || !registeredRole) {
          throw new Error("Socket not registered");
        }

        if (!(await isCurrentSessionSocketOwner(registeredSessionId, registeredRole, ws))) {
          closeSocket(ws, 1000, "superseded by a newer connection");
          return;
        }

        if (message.type === "worker-state") {
          const session = await sessionStore.get(registeredSessionId);
          if (!session || (registeredRole === "worker" && session.generation !== registeredGeneration)) {
            return;
          }
          await sessionStore.setState(registeredSessionId, message.state);
          await sendSignal(registeredSessionId, "viewer", message);
          return;
        }

        const targetRole = registeredRole === "worker" ? "viewer" : "worker";
        if (registeredRole === "viewer") {
          await sessionStore.markViewerSeen(registeredSessionId);
        }
        if (registeredRole === "worker") {
          const session = await sessionStore.get(registeredSessionId);
          if (!session || session.generation !== registeredGeneration) {
            return;
          }
        }
        await sendSignal(registeredSessionId, targetRole, message);
      } catch (error) {
        debugLog("websocket-error", { error: error.message || String(error) });
        ws.send(JSON.stringify({ type: "error", message: error.message || "WebSocket error" }));
      }
    })();
  });

  ws.on("close", () => {
    void (async () => {
      if (registeredPoolWorkerId) {
        clearLocalPoolSocket(registeredPoolWorkerId, ws);
        const released = await releasePoolSocketOwnership(registeredPoolWorkerId, ws);
        if (!released) {
          return;
        }
        const worker = await workerPoolStore.getWorker(registeredPoolWorkerId);
        await workerPoolStore.unregisterWorker(registeredPoolWorkerId);
        if (worker?.sessionId) {
          structuredLog("warn", { sessionId: worker.sessionId, component: "session" }, "pool-socket-closed", {
            poolWorkerId: registeredPoolWorkerId,
            state: worker.state || "unknown",
          });
          await fallbackWarmPoolSession(
            worker.sessionId,
            registeredPoolWorkerId,
            "pool worker disconnected during session bootstrap",
          );
        }
        return;
      }

      if (!registeredSessionId || !registeredRole) {
        return;
      }
      clearLocalSocket(registeredSessionId, registeredRole, ws);
      const released = await releaseSessionSocketOwnership(registeredSessionId, registeredRole, ws);
      if (!released) {
        return;
      }
      const session = await sessionStore.get(registeredSessionId);
      if (!session) {
        return;
      }
      if (registeredRole === "viewer") {
        await markViewerDisconnectedAndSchedule(registeredSessionId, "viewer websocket closed");
        return;
      }

      setDisconnectTimer(registeredSessionId, "worker", 3000, () => {
        void (async () => {
          const current = await sessionStore.get(registeredSessionId);
          if (!current || current.state === "terminated") {
            return;
          }
          if (registeredGeneration !== null && current.generation !== registeredGeneration) {
            return;
          }
          const workerSocket = getLocalSocket(registeredSessionId, "worker");
          if (workerSocket?.readyState === WebSocket.OPEN) {
            return;
          }
          await terminateSession(current, "worker disconnected");
        })();
      });
    })();
  });
});

server.on("upgrade", (req, socket, head) => {
  const requestUrl = new URL(req.url, config.publicBaseUrl);
  const isViewerSocket = requestUrl.pathname === "/ws";
  const isWorkerSocket = requestUrl.pathname === "/ws/worker";
  const isPoolSocket = isPoolRegistrationPath(requestUrl.pathname);
  const gatewaySignalRoute = parseGatewaySignalingPath(requestUrl.pathname);
  const isGatewayViewerSocket = gatewaySignalRoute?.role === "viewer";
  const isGatewayWorkerSocket = gatewaySignalRoute?.role === "worker";
  if (
    !isViewerSocket &&
    !isWorkerSocket &&
    !isPoolSocket &&
    !isGatewayViewerSocket &&
    !isGatewayWorkerSocket
  ) {
    socket.destroy();
    return;
  }
  if (isViewerSocket) {
    try {
      enforceSameOrigin(req);
    } catch {
      socket.destroy();
      return;
    }
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    wss.emit("connection", ws, req);
  });
});

const tombstoneGcTimer = setInterval(() => {
  void (async () => {
    for (const session of await sessionStore.listTerminated(60_000)) {
      await sessionStore.remove(session.id);
    }
  })();
}, 30_000);
tombstoneGcTimer.unref();

const expiryTimer = setInterval(() => {
  void (async () => {
    const now = Date.now();
    for (const session of await sessionStore.listExpired(now)) {
      await terminateSession(session, "session expired");
    }
    if (config.viewerConnectTimeoutMs > 0) {
      for (const session of await sessionStore.listSessions(500)) {
        if (
          session.state !== "terminated" &&
          session.viewerConnectedAt === null &&
          session.createdAt + config.viewerConnectTimeoutMs <= now
        ) {
          await terminateSession(session, "viewer never connected");
        }
      }
    }
})();
}, 10_000);
expiryTimer.unref();

async function reapIdleSessions() {
  const now = Date.now();
  for (const session of await sessionStore.listSessions(500)) {
    if (!session || session.state === "terminated") {
      continue;
    }
    if (await sessionStore.shouldIdleTerminate(session.id, now)) {
      await terminateSession(session, "viewer idle timeout");
    }
  }
}

async function reapOrphanSessionWorkers() {
  if (
    !config.kubernetesOrphanReaperEnabled ||
    typeof workerRuntime.listSessionWorkers !== "function"
  ) {
    return;
  }
  const now = Date.now();
  const workers = await workerRuntime.listSessionWorkers();
  for (const worker of workers) {
    const session = worker.sessionId ? await sessionStore.get(worker.sessionId) : null;
    if (session && session.state !== "terminated") {
      if (await sessionStore.shouldIdleTerminate(session.id, now)) {
        await terminateSession(session, "viewer idle timeout");
      }
      continue;
    }

    const createdAtMs = Number(worker.createdAtMs || 0);
    const workerAgeMs = createdAtMs > 0 ? now - createdAtMs : Number.POSITIVE_INFINITY;
    if (workerAgeMs < config.kubernetesOrphanWorkerGraceMs) {
      continue;
    }

    structuredLog("warn", { component: "worker-runtime" }, "orphan-session-worker-reaped", {
      sessionId: worker.sessionId || null,
      jobName: worker.jobName,
      namespace: worker.namespace,
      reason: session?.state === "terminated" ? "terminated-session" : "missing-session",
      workerAgeMs: Number.isFinite(workerAgeMs) ? Math.round(workerAgeMs) : null,
    });
    await workerRuntime.stop({
      launchMode: "kubernetes",
      jobName: worker.jobName,
      workerId: worker.jobName,
      namespace: worker.namespace,
    });
  }
}

const idleReaperTimer =
  config.idleReaperIntervalMs > 0
    ? setInterval(() => {
        void reapIdleSessions().catch((error) => {
          structuredLog("warn", { component: "session" }, "idle-reaper-failed", {
            error: error.message || String(error),
          });
        });
      }, config.idleReaperIntervalMs)
    : null;
idleReaperTimer?.unref();

const orphanWorkerReaperTimer =
  config.kubernetesOrphanReaperEnabled && config.kubernetesOrphanReaperIntervalMs > 0
    ? setInterval(() => {
        void reapOrphanSessionWorkers().catch((error) => {
          structuredLog("warn", { component: "worker-runtime" }, "orphan-worker-reaper-failed", {
            error: error.message || String(error),
          });
        });
      }, config.kubernetesOrphanReaperIntervalMs)
    : null;
orphanWorkerReaperTimer?.unref();

async function start() {
  await sessionStore.initialize();
  await signalBus.initialize();
  await workerPoolStore.initialize();
  await workerPoolBus.initialize();
  try {
    await workerRuntime.ensureReady();
  } catch (error) {
    structuredLog("warn", { component: "worker-runtime" }, "worker-runtime-not-ready", {
      error: error.message || String(error),
    });
  }

  server.listen(config.port, config.host, () => {
    structuredLog("info", { component: "server" }, "server-started", {
      url: config.publicBaseUrl,
      port: config.port,
      workerLaunchMode: config.workerLaunchMode,
      warmPoolEnabled: config.warmPoolEnabled,
      workerPoolBus: config.workerPoolBusBackend,
      tokenSecretFingerprint: fingerprintValue(config.tokenSecret),
      swgSecretFingerprint: fingerprintValue(config.swgSharedSecret),
    });
  });
}

async function shutdown(signal) {
  structuredLog("info", { component: "server" }, "shutdown", { signal });
  clearInterval(tombstoneGcTimer);
  clearInterval(expiryTimer);
  if (idleReaperTimer) {
    clearInterval(idleReaperTimer);
  }
  if (orphanWorkerReaperTimer) {
    clearInterval(orphanWorkerReaperTimer);
  }
  await workerPoolBus.close();
  await signalBus.close();
  await workerPoolStore.close();
  await sessionStore.close();
  server.close(() => {
    process.exit(0);
  });
}

process.on("SIGINT", () => {
  void shutdown("SIGINT");
});

process.on("SIGTERM", () => {
  void shutdown("SIGTERM");
});

start().catch((error) => {
  console.error(error);
  process.exit(1);
});
