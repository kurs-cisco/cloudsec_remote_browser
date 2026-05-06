import crypto from "node:crypto";

import { createClient } from "redis";

export const DEFAULT_REDIS_KEY_PREFIX = "cloudsec-rbi";
export const DEFAULT_VIEWER_TELEMETRY_MAX_EVENTS = 200;

function normalizeRedisKeyPrefix(prefix = DEFAULT_REDIS_KEY_PREFIX) {
  const value = String(prefix || DEFAULT_REDIS_KEY_PREFIX).trim().replace(/:+$/g, "");
  return value || DEFAULT_REDIS_KEY_PREFIX;
}

export function buildSessionStoreKeys(redisKeyPrefix = DEFAULT_REDIS_KEY_PREFIX) {
  const prefix = normalizeRedisKeyPrefix(redisKeyPrefix);
  return {
    session: (id) => `${prefix}:session:${id}`,
    pending: (id, role) => `${prefix}:session:${id}:pending:${role}`,
    viewerTelemetry: (id) => `${prefix}:session:${id}:viewer-telemetry`,
    sessionsExpires: `${prefix}:sessions:expires`,
    sessionsCreated: `${prefix}:sessions:created`,
    terminationLock: (id) => `${prefix}:session:${id}:terminating`,
    singleSessionGuard: `${prefix}:locks:single-active-session`,
  };
}

function makeId(prefix) {
  return `${prefix}_${crypto.randomUUID().replaceAll("-", "")}`;
}

function fingerprintLabel(value, prefix = "id") {
  const text = String(value || "").trim();
  if (!text) {
    return "";
  }
  return `${prefix}-${crypto.createHash("sha256").update(text).digest("hex").slice(0, 8)}`;
}

function normalizeViewerTelemetryLimit(value, fallback = DEFAULT_VIEWER_TELEMETRY_MAX_EVENTS) {
  const parsed = Math.round(Number(value));
  if (Number.isFinite(parsed) && parsed > 0) {
    return Math.min(parsed, 1000);
  }
  const fallbackValue = Math.round(Number(fallback));
  return Number.isFinite(fallbackValue) && fallbackValue > 0
    ? Math.min(fallbackValue, 1000)
    : DEFAULT_VIEWER_TELEMETRY_MAX_EVENTS;
}

function buildViewerTelemetryEntry(payload = {}) {
  return {
    receivedAt: new Date().toISOString(),
    payload,
  };
}

function getWorkerId(worker) {
  return (
    worker?.containerName ||
    worker?.taskArn ||
    worker?.jobName ||
    worker?.workerId ||
    worker?.id ||
    null
  );
}

function buildSession({
  sessionTtlMs,
  targetUrl,
  viewport,
  client,
  experiments,
  viewerToken,
  workerToken,
  requestContext,
  sessionPlacement,
  transport,
  workerBridge,
}) {
  const now = Date.now();
  return {
    id: makeId("sess"),
    targetUrl,
    targetOrigin: new URL(targetUrl).origin,
    viewport,
    client,
    experiments,
    viewerToken,
    workerToken,
    requestContext: requestContext || null,
    sessionPlacement: sessionPlacement || null,
    transport: transport || null,
    workerBridge: workerBridge || null,
    state: "allocating",
    generation: 1,
    createdAt: now,
    updatedAt: now,
    expiresAt: now + sessionTtlMs,
    viewerConnectedAt: null,
    viewerDisconnectedAt: null,
    viewerDisconnectReason: null,
    lastViewerAt: null,
    terminatedAt: null,
    worker: null,
    socketOwners: {
      viewer: null,
      worker: null,
    },
  };
}

function isSwgSession(session) {
  const authMode = String(session?.client?.authMode || "").trim().toLowerCase();
  return authMode === "swg";
}

function deriveViewerEntryMode(session) {
  return isSwgSession(session) ? "swg-handoff" : "direct-viewer";
}

function buildSwgSnapshot(session) {
  if (!isSwgSession(session)) {
    return null;
  }
  const swg = session?.client?.swg || {};
  const snapshot = {
    transactionId: swg.transactionId || null,
    tenantId: swg.tenantId || null,
    profileId: swg.profileId || null,
    policy: swg.policy || null,
    upstreamHost: swg.upstreamHost || null,
    upstreamScheme: swg.upstreamScheme || null,
    upstreamPort: swg.upstreamPort || null,
  };
  for (const key of [
    "contractVersion",
    "requestKind",
    "originalMethod",
    "provider",
    "providerCategory",
    "fallbackProvider",
    "fallbackReason",
  ]) {
    if (swg[key]) {
      snapshot[key] = swg[key];
    }
  }
  return snapshot;
}

function getWorkerLaunchMode(session) {
  return session?.worker?.launchMode || null;
}

function getWorkerRuntimeKind(session) {
  return session?.worker?.runtimeKind || null;
}

function getWorkerRegion(session) {
  return session?.worker?.region || null;
}

function getWorkerAvailabilityZone(session) {
  return session?.worker?.availabilityZone || null;
}

function getGatewayAssignment(session) {
  const placement = session?.sessionPlacement || {};
  return placement.gatewayAssignment || null;
}

function buildViewerPolicySummary(session) {
  const client = session?.client || {};
  const swg = client.swg || {};
  const gateway = getGatewayAssignment(session) || {};
  let targetHost = swg.upstreamHost || "";
  if (!targetHost) {
    try {
      targetHost = new URL(session?.targetUrl || "").host;
    } catch {
      targetHost = "";
    }
  }
  const tenantLabel =
    client.tenantLabel ||
    client.organizationName ||
    client.orgName ||
    (swg.tenantId ? `Tenant ${fingerprintLabel(swg.tenantId, "t")}` : "Enterprise tenant");
  const profileLabel =
    client.profileLabel ||
    client.profileName ||
    (swg.profileId ? `Profile ${fingerprintLabel(swg.profileId, "p")}` : "");
  const dataControlLabels = Array.isArray(client.dataControlLabels)
    ? client.dataControlLabels.map((value) => String(value || "").trim()).filter(Boolean).slice(0, 4)
    : [];
  return {
    tenantLabel,
    profileLabel,
    targetHost,
    policyReason: swg.policy || client.policyLabel || "Enterprise policy",
    isolationMode: isSwgSession(session) ? "SWG isolated browser" : "Isolated browser",
    clipboardPolicy: client.clipboardPolicy || "Clipboard governed by policy",
    filePolicy: client.filePolicy || "File transfer governed by policy",
    dataControlLabels,
    regionLabel: getWorkerRegion(session) || gateway.region || "",
    gatewayLabel: gateway.gatewayId || gateway.gatewayID || "",
    supportId: String(session?.id || "").slice(-12),
  };
}

function getWorkerAssignment(session) {
  const placement = session?.sessionPlacement || {};
  return placement.workerAssignment || null;
}

function getGatewayTransport(session) {
  return session?.transport || null;
}

function getWorkerBridge(session) {
  return session?.workerBridge || null;
}

function toIso(value) {
  return value ? new Date(value).toISOString() : null;
}

function socketOwnerMatches(current, expected) {
  return (
    String(current?.instanceId || "") === String(expected?.instanceId || "") &&
    String(current?.connectionId || "") === String(expected?.connectionId || "")
  );
}

class MemorySessionStoreImpl {
  constructor({ sessionTtlMs, idleTimeoutMs, viewerTelemetryMaxEvents }) {
    this.sessionTtlMs = sessionTtlMs;
    this.idleTimeoutMs = idleTimeoutMs;
    this.viewerTelemetryMaxEvents =
      Number.isFinite(Number(viewerTelemetryMaxEvents)) && Number(viewerTelemetryMaxEvents) > 0
        ? Math.round(Number(viewerTelemetryMaxEvents))
        : DEFAULT_VIEWER_TELEMETRY_MAX_EVENTS;
    this.sessions = new Map();
    this.pendingSignals = new Map();
    this.viewerTelemetry = new Map();
    this.terminationLocks = new Map();
    this.singleSessionGuard = null;
  }

  async initialize() {}

  async createSession({
    targetUrl,
    viewport,
    client,
    experiments,
    viewerToken,
    workerToken,
    requestContext,
    sessionPlacement,
    transport,
    workerBridge,
  }) {
    const session = buildSession({
      sessionTtlMs: this.sessionTtlMs,
      targetUrl,
      viewport,
      client,
      experiments,
      viewerToken,
      workerToken,
      requestContext,
      sessionPlacement,
      transport,
      workerBridge,
    });
    this.sessions.set(session.id, session);
    return session;
  }

  async get(id) {
    return this.sessions.get(id) || null;
  }

  async update(id, patch) {
    const session = this.sessions.get(id);
    if (!session) {
      return null;
    }
    Object.assign(session, patch, { updatedAt: Date.now() });
    return session;
  }

  async markViewerSeen(id) {
    const session = this.sessions.get(id);
    if (!session) {
      return null;
    }
    const now = Date.now();
    session.lastViewerAt = now;
    session.viewerDisconnectedAt = null;
    session.viewerDisconnectReason = null;
    session.updatedAt = now;
    return session;
  }

  async markViewerConnected(id) {
    const session = this.sessions.get(id);
    if (!session) {
      return null;
    }
    const now = Date.now();
    if (session.viewerConnectedAt === null) {
      session.viewerConnectedAt = now;
    }
    session.lastViewerAt = now;
    session.viewerDisconnectedAt = null;
    session.viewerDisconnectReason = null;
    session.updatedAt = now;
    return session;
  }

  async markViewerDisconnected(id, reason = "viewer disconnected") {
    const session = this.sessions.get(id);
    if (!session) {
      return null;
    }
    const now = Date.now();
    session.viewerDisconnectedAt = now;
    session.viewerDisconnectReason = String(reason || "viewer disconnected").slice(0, 160);
    session.updatedAt = now;
    return session;
  }

  async setState(id, state) {
    const patch = { state };
    if (state === "terminated") {
      patch.terminatedAt = Date.now();
    }
    return this.update(id, patch);
  }

  async setWorker(id, worker) {
    return this.update(id, { worker });
  }

  async incrementGeneration(id) {
    const session = this.sessions.get(id);
    if (!session) {
      return null;
    }
    session.generation = (session.generation || 1) + 1;
    session.updatedAt = Date.now();
    return session;
  }

  async claimSocketOwnership(id, role, owner) {
    const session = this.sessions.get(id);
    if (!session) {
      return null;
    }
    session.socketOwners = session.socketOwners || { viewer: null, worker: null };
    session.socketOwners[role] = owner;
    session.updatedAt = Date.now();
    return session;
  }

  async getSocketOwner(id, role) {
    const session = this.sessions.get(id);
    if (!session) {
      return null;
    }
    return session.socketOwners?.[role] || null;
  }

  async releaseSocketOwnership(id, role, owner) {
    const session = this.sessions.get(id);
    if (!session) {
      return false;
    }
    if (!socketOwnerMatches(session.socketOwners?.[role], owner)) {
      return false;
    }
    session.socketOwners[role] = null;
    session.updatedAt = Date.now();
    return true;
  }

  async addPendingSignal(id, role, payload) {
    const key = `${id}:${role}`;
    const existing = this.pendingSignals.get(key) || [];
    existing.push(payload);
    this.pendingSignals.set(key, existing);
  }

  async drainPendingSignals(id, role) {
    const key = `${id}:${role}`;
    const existing = this.pendingSignals.get(key) || [];
    this.pendingSignals.delete(key);
    return existing;
  }

  async appendViewerTelemetry(id, payload, options = {}) {
    const session = this.sessions.get(id);
    if (!session) {
      return null;
    }
    const maxEvents = normalizeViewerTelemetryLimit(
      options.maxEvents,
      this.viewerTelemetryMaxEvents,
    );
    const entry = buildViewerTelemetryEntry(payload);
    const existing = this.viewerTelemetry.get(id) || [];
    existing.push(entry);
    if (existing.length > maxEvents) {
      existing.splice(0, existing.length - maxEvents);
    }
    this.viewerTelemetry.set(id, existing);
    return entry;
  }

  async listViewerTelemetry(id, options = {}) {
    const limit = normalizeViewerTelemetryLimit(
      options.limit,
      this.viewerTelemetryMaxEvents,
    );
    return (this.viewerTelemetry.get(id) || []).slice(-limit);
  }

  async listExpired(now = Date.now()) {
    return [...this.sessions.values()].filter((session) => session.expiresAt <= now);
  }

  async listTerminated(olderThanMs, now = Date.now()) {
    return [...this.sessions.values()].filter(
      (session) =>
        session.state === "terminated" &&
        session.terminatedAt !== null &&
        now - session.terminatedAt > olderThanMs,
    );
  }

  async listSessions(limit = 100) {
    return [...this.sessions.values()]
      .sort((left, right) => right.createdAt - left.createdAt)
      .slice(0, limit);
  }

  async shouldIdleTerminate(id, now = Date.now()) {
    const session = this.sessions.get(id);
    if (!session) {
      return false;
    }
    const idleReference = session.viewerDisconnectedAt || session.lastViewerAt;
    if (idleReference === null || idleReference === undefined) {
      return false;
    }
    return now - idleReference > this.idleTimeoutMs;
  }

  async acquireTerminationLock(id, ttlMs) {
    const now = Date.now();
    const lockUntil = this.terminationLocks.get(id);
    if (lockUntil && lockUntil > now) {
      return false;
    }
    this.terminationLocks.set(id, now + ttlMs);
    return true;
  }

  async acquireSingleSessionGuard(ttlMs) {
    const now = Date.now();
    if (this.singleSessionGuard && this.singleSessionGuard.expiresAt > now) {
      return null;
    }
    const token = crypto.randomUUID();
    this.singleSessionGuard = {
      token,
      expiresAt: now + ttlMs,
    };
    return token;
  }

  async releaseSingleSessionGuard(token) {
    if (!this.singleSessionGuard || this.singleSessionGuard.token !== token) {
      return false;
    }
    this.singleSessionGuard = null;
    return true;
  }

  async remove(id) {
    this.pendingSignals.delete(`${id}:viewer`);
    this.pendingSignals.delete(`${id}:worker`);
    this.viewerTelemetry.delete(id);
    this.terminationLocks.delete(id);
    return this.sessions.delete(id);
  }

  snapshot(session) {
    return {
      sessionId: session.id,
      state: session.state,
      sessionMode: isSwgSession(session) ? "swg" : "standard",
      viewerEntryMode: deriveViewerEntryMode(session),
      generation: session.generation || 1,
      targetUrl: session.targetUrl,
      targetOrigin: session.targetOrigin,
      viewport: session.viewport,
	      client: session.client,
	      viewerPolicySummary: buildViewerPolicySummary(session),
	      experiments: session.experiments || {},
      swgContext: buildSwgSnapshot(session),
      gatewayAssignment: getGatewayAssignment(session),
      workerAssignment: getWorkerAssignment(session),
      transport: getGatewayTransport(session),
      workerBridge: getWorkerBridge(session),
      workerId: getWorkerId(session.worker),
      workerLaunchMode: getWorkerLaunchMode(session),
      workerRuntimeKind: getWorkerRuntimeKind(session),
      workerRegion: getWorkerRegion(session),
      workerAvailabilityZone: getWorkerAvailabilityZone(session),
      createdAt: toIso(session.createdAt),
      updatedAt: toIso(session.updatedAt),
      expiresAt: toIso(session.expiresAt),
      viewerConnectedAt: toIso(session.viewerConnectedAt),
      viewerDisconnectedAt: toIso(session.viewerDisconnectedAt),
      viewerDisconnectReason: session.viewerDisconnectReason || null,
      lastViewerAt: toIso(session.lastViewerAt),
      terminatedAt: toIso(session.terminatedAt),
    };
  }

  async close() {}
}

const DRAIN_LIST_SCRIPT = `
local values = redis.call("LRANGE", KEYS[1], 0, -1)
if #values > 0 then
  redis.call("DEL", KEYS[1])
end
return values
`;

const SAVE_SESSION_CHANGES = `
redis.call("SET", KEYS[1], cjson.encode(session))
redis.call("PEXPIREAT", KEYS[1], session.expiresAt)
redis.call("ZADD", KEYS[2], session.expiresAt, session.id)
redis.call("ZADD", KEYS[3], session.createdAt, session.id)
return cjson.encode(session)
`;

const UPDATE_SESSION_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local session = cjson.decode(raw)
local patch = cjson.decode(ARGV[2])
for key, value in pairs(patch) do
  session[key] = value
end
session.updatedAt = tonumber(ARGV[1])
${SAVE_SESSION_CHANGES}
`;

const MARK_VIEWER_SEEN_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local session = cjson.decode(raw)
local now = tonumber(ARGV[1])
session.lastViewerAt = now
session.viewerDisconnectedAt = cjson.null
session.viewerDisconnectReason = cjson.null
session.updatedAt = now
${SAVE_SESSION_CHANGES}
`;

const MARK_VIEWER_CONNECTED_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local session = cjson.decode(raw)
local now = tonumber(ARGV[1])
if session.viewerConnectedAt == nil or session.viewerConnectedAt == cjson.null then
  session.viewerConnectedAt = now
end
session.lastViewerAt = now
session.viewerDisconnectedAt = cjson.null
session.viewerDisconnectReason = cjson.null
session.updatedAt = now
${SAVE_SESSION_CHANGES}
`;

const MARK_VIEWER_DISCONNECTED_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local session = cjson.decode(raw)
local now = tonumber(ARGV[1])
session.viewerDisconnectedAt = now
if ARGV[2] ~= nil and ARGV[2] ~= "" then
  session.viewerDisconnectReason = ARGV[2]
else
  session.viewerDisconnectReason = cjson.null
end
session.updatedAt = now
${SAVE_SESSION_CHANGES}
`;

const SET_STATE_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local session = cjson.decode(raw)
local now = tonumber(ARGV[1])
session.state = ARGV[2]
if ARGV[2] == "terminated" then
  session.terminatedAt = now
end
session.updatedAt = now
${SAVE_SESSION_CHANGES}
`;

const SET_WORKER_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local session = cjson.decode(raw)
session.worker = cjson.decode(ARGV[2])
session.updatedAt = tonumber(ARGV[1])
${SAVE_SESSION_CHANGES}
`;

const INCREMENT_GENERATION_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local session = cjson.decode(raw)
session.generation = (tonumber(session.generation) or 1) + 1
session.updatedAt = tonumber(ARGV[1])
${SAVE_SESSION_CHANGES}
`;

const CLAIM_SOCKET_OWNER_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local session = cjson.decode(raw)
local role = ARGV[2]
if session.socketOwners == nil or session.socketOwners == cjson.null then
  session.socketOwners = {}
end
session.socketOwners[role] = cjson.decode(ARGV[3])
session.updatedAt = tonumber(ARGV[1])
${SAVE_SESSION_CHANGES}
`;

const RELEASE_SOCKET_OWNER_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local session = cjson.decode(raw)
local role = ARGV[2]
local owner = cjson.decode(ARGV[3])
local current = nil
if session.socketOwners ~= nil and session.socketOwners ~= cjson.null then
  current = session.socketOwners[role]
end

local currentInstanceId = ""
local currentConnectionId = ""
if current ~= nil and current ~= cjson.null then
  currentInstanceId = tostring(current.instanceId or "")
  currentConnectionId = tostring(current.connectionId or "")
end

if currentInstanceId ~= tostring(owner.instanceId or "") or currentConnectionId ~= tostring(owner.connectionId or "") then
  return cjson.encode({ released = false, session = session })
end

session.socketOwners[role] = cjson.null
session.updatedAt = tonumber(ARGV[1])
redis.call("SET", KEYS[1], cjson.encode(session))
redis.call("PEXPIREAT", KEYS[1], session.expiresAt)
redis.call("ZADD", KEYS[2], session.expiresAt, session.id)
redis.call("ZADD", KEYS[3], session.createdAt, session.id)
return cjson.encode({ released = true })
`;

const RELEASE_LOCK_SCRIPT = `
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("DEL", KEYS[1])
end
return 0
`;

class RedisSessionStoreImpl {
  constructor(config) {
    this.config = config;
    this.sessionTtlMs = config.sessionTtlMs;
    this.idleTimeoutMs = config.idleTimeoutMs;
    this.viewerTelemetryMaxEvents =
      Number.isFinite(Number(config.viewerTelemetryMaxEvents)) &&
      Number(config.viewerTelemetryMaxEvents) > 0
        ? Math.round(Number(config.viewerTelemetryMaxEvents))
        : DEFAULT_VIEWER_TELEMETRY_MAX_EVENTS;
    this.client = null;
    this.keys = buildSessionStoreKeys(config.redisKeyPrefix);
  }

  sessionKey(id) {
    return this.keys.session(id);
  }

  pendingKey(id, role) {
    return this.keys.pending(id, role);
  }

  viewerTelemetryKey(id) {
    return this.keys.viewerTelemetry(id);
  }

  expiryIndexKey() {
    return this.keys.sessionsExpires;
  }

  createdIndexKey() {
    return this.keys.sessionsCreated;
  }

  terminationLockKey(id) {
    return this.keys.terminationLock(id);
  }

  singleSessionGuardKey() {
    return this.keys.singleSessionGuard;
  }

  #sessionMutationKeys(id) {
    return [this.sessionKey(id), this.expiryIndexKey(), this.createdIndexKey()];
  }

  #parseMutationResult(raw) {
    return raw ? JSON.parse(raw) : null;
  }

  async #runSessionMutation(id, script, args = []) {
    if (!this.client) {
      return null;
    }
    const raw = await this.client.eval(script, {
      keys: this.#sessionMutationKeys(id),
      arguments: args,
    });
    return this.#parseMutationResult(raw);
  }

  async initialize() {
    this.client = createClient({
      url: this.config.redisUrl,
      socket: {
        tls: this.config.redisTls,
      },
    });
    this.client.on("error", (error) => {
      console.error("[redis]", error);
    });
    await this.client.connect();
  }

  async #saveSession(session) {
    const sessionKey = this.sessionKey(session.id);
    const multi = this.client.multi();
    multi.set(sessionKey, JSON.stringify(session));
    multi.pExpireAt(sessionKey, session.expiresAt);
    multi.zAdd(this.expiryIndexKey(), [{ score: session.expiresAt, value: session.id }]);
    multi.zAdd(this.createdIndexKey(), [{ score: session.createdAt, value: session.id }]);
    await multi.exec();
    return session;
  }

  async #loadSession(id) {
    if (!this.client) {
      return null;
    }
    const raw = await this.client.get(this.sessionKey(id));
    return raw ? JSON.parse(raw) : null;
  }

  async createSession({
    targetUrl,
    viewport,
    client,
    experiments,
    viewerToken,
    workerToken,
    requestContext,
    sessionPlacement,
    transport,
    workerBridge,
  }) {
    const session = buildSession({
      sessionTtlMs: this.sessionTtlMs,
      targetUrl,
      viewport,
      client,
      experiments,
      viewerToken,
      workerToken,
      requestContext,
      sessionPlacement,
      transport,
      workerBridge,
    });
    await this.#saveSession(session);
    return session;
  }

  async get(id) {
    return this.#loadSession(id);
  }

  async update(id, patch) {
    return this.#runSessionMutation(id, UPDATE_SESSION_SCRIPT, [
      String(Date.now()),
      JSON.stringify(patch),
    ]);
  }

  async markViewerSeen(id) {
    return this.#runSessionMutation(id, MARK_VIEWER_SEEN_SCRIPT, [String(Date.now())]);
  }

  async markViewerConnected(id) {
    return this.#runSessionMutation(id, MARK_VIEWER_CONNECTED_SCRIPT, [String(Date.now())]);
  }

  async markViewerDisconnected(id, reason = "viewer disconnected") {
    return this.#runSessionMutation(id, MARK_VIEWER_DISCONNECTED_SCRIPT, [
      String(Date.now()),
      String(reason || "viewer disconnected").slice(0, 160),
    ]);
  }

  async setState(id, state) {
    return this.#runSessionMutation(id, SET_STATE_SCRIPT, [String(Date.now()), String(state)]);
  }

  async setWorker(id, worker) {
    return this.#runSessionMutation(id, SET_WORKER_SCRIPT, [
      String(Date.now()),
      JSON.stringify(worker),
    ]);
  }

  async incrementGeneration(id) {
    return this.#runSessionMutation(id, INCREMENT_GENERATION_SCRIPT, [String(Date.now())]);
  }

  async claimSocketOwnership(id, role, owner) {
    return this.#runSessionMutation(id, CLAIM_SOCKET_OWNER_SCRIPT, [
      String(Date.now()),
      String(role),
      JSON.stringify(owner),
    ]);
  }

  async getSocketOwner(id, role) {
    const session = await this.#loadSession(id);
    if (!session) {
      return null;
    }
    return session.socketOwners?.[role] || null;
  }

  async releaseSocketOwnership(id, role, owner) {
    if (!this.client) {
      return false;
    }
    const raw = await this.client.eval(RELEASE_SOCKET_OWNER_SCRIPT, {
      keys: this.#sessionMutationKeys(id),
      arguments: [String(Date.now()), String(role), JSON.stringify(owner)],
    });
    if (!raw) {
      return false;
    }
    const result = JSON.parse(raw);
    return Boolean(result?.released);
  }

  async addPendingSignal(id, role, payload) {
    const session = await this.#loadSession(id);
    if (!session) {
      return;
    }
    const key = this.pendingKey(id, role);
    const multi = this.client.multi();
    multi.rPush(key, JSON.stringify(payload));
    multi.pExpireAt(key, session.expiresAt);
    await multi.exec();
  }

  async drainPendingSignals(id, role) {
    const rawValues = await this.client.eval(DRAIN_LIST_SCRIPT, {
      keys: [this.pendingKey(id, role)],
      arguments: [],
    });
    return (rawValues || []).map((value) => JSON.parse(value));
  }

  async appendViewerTelemetry(id, payload, options = {}) {
    const session = await this.#loadSession(id);
    if (!session) {
      return null;
    }
    const maxEvents = normalizeViewerTelemetryLimit(
      options.maxEvents,
      this.viewerTelemetryMaxEvents,
    );
    const entry = buildViewerTelemetryEntry(payload);
    const key = this.viewerTelemetryKey(id);
    const multi = this.client.multi();
    multi.rPush(key, JSON.stringify(entry));
    multi.lTrim(key, -maxEvents, -1);
    multi.pExpireAt(key, session.expiresAt);
    await multi.exec();
    return entry;
  }

  async listViewerTelemetry(id, options = {}) {
    const limit = normalizeViewerTelemetryLimit(
      options.limit,
      this.viewerTelemetryMaxEvents,
    );
    const values = await this.client.lRange(this.viewerTelemetryKey(id), -limit, -1);
    return (values || []).map((value) => JSON.parse(value));
  }

  async listExpired(now = Date.now()) {
    const ids = await this.client.zRangeByScore(this.expiryIndexKey(), 0, now);
    if (!ids.length) {
      return [];
    }
    const sessions = await Promise.all(ids.map((id) => this.#loadSession(id)));
    return sessions.filter(Boolean);
  }

  async listTerminated(olderThanMs, now = Date.now()) {
    const ids = await this.client.zRange(this.createdIndexKey(), 0, -1);
    if (!ids.length) {
      return [];
    }
    const sessions = await Promise.all(ids.map((id) => this.#loadSession(id)));
    return sessions.filter(
      (session) =>
        session &&
        session.state === "terminated" &&
        session.terminatedAt !== null &&
        now - session.terminatedAt > olderThanMs,
    );
  }

  async listSessions(limit = 100) {
    const stop = Math.max(limit - 1, 0);
    const ids = await this.client.zRange(this.createdIndexKey(), 0, stop, {
      REV: true,
    });
    if (!ids.length) {
      return [];
    }
    const sessions = await Promise.all(ids.map((id) => this.#loadSession(id)));
    return sessions.filter(Boolean);
  }

  async shouldIdleTerminate(id, now = Date.now()) {
    const session = await this.#loadSession(id);
    if (!session) {
      return false;
    }
    const idleReference = session.viewerDisconnectedAt || session.lastViewerAt;
    if (idleReference === null || idleReference === undefined) {
      return false;
    }
    return now - idleReference > this.idleTimeoutMs;
  }

  async acquireTerminationLock(id, ttlMs) {
    const result = await this.client.set(this.terminationLockKey(id), "1", {
      PX: ttlMs,
      NX: true,
    });
    return result === "OK";
  }

  async acquireSingleSessionGuard(ttlMs) {
    if (!this.client) {
      return null;
    }
    const token = crypto.randomUUID();
    const result = await this.client.set(this.singleSessionGuardKey(), token, {
      PX: ttlMs,
      NX: true,
    });
    return result === "OK" ? token : null;
  }

  async releaseSingleSessionGuard(token) {
    if (!this.client) {
      return false;
    }
    const result = await this.client.eval(RELEASE_LOCK_SCRIPT, {
      keys: [this.singleSessionGuardKey()],
      arguments: [token],
    });
    return Number(result || 0) > 0;
  }

  async remove(id) {
    const multi = this.client.multi();
    multi.del(this.sessionKey(id));
    multi.del(this.pendingKey(id, "viewer"));
    multi.del(this.pendingKey(id, "worker"));
    multi.del(this.viewerTelemetryKey(id));
    multi.del(this.terminationLockKey(id));
    multi.zRem(this.expiryIndexKey(), id);
    multi.zRem(this.createdIndexKey(), id);
    await multi.exec();
    return true;
  }

  snapshot(session) {
    return {
      sessionId: session.id,
      state: session.state,
      sessionMode: isSwgSession(session) ? "swg" : "standard",
      viewerEntryMode: deriveViewerEntryMode(session),
      generation: session.generation || 1,
      targetUrl: session.targetUrl,
      targetOrigin: session.targetOrigin,
      viewport: session.viewport,
	      client: session.client,
	      viewerPolicySummary: buildViewerPolicySummary(session),
	      experiments: session.experiments || {},
      swgContext: buildSwgSnapshot(session),
      gatewayAssignment: getGatewayAssignment(session),
      workerAssignment: getWorkerAssignment(session),
      transport: getGatewayTransport(session),
      workerBridge: getWorkerBridge(session),
      workerId: getWorkerId(session.worker),
      workerLaunchMode: getWorkerLaunchMode(session),
      workerRuntimeKind: getWorkerRuntimeKind(session),
      workerRegion: getWorkerRegion(session),
      workerAvailabilityZone: getWorkerAvailabilityZone(session),
      createdAt: toIso(session.createdAt),
      updatedAt: toIso(session.updatedAt),
      expiresAt: toIso(session.expiresAt),
      viewerConnectedAt: toIso(session.viewerConnectedAt),
      viewerDisconnectedAt: toIso(session.viewerDisconnectedAt),
      viewerDisconnectReason: session.viewerDisconnectReason || null,
      lastViewerAt: toIso(session.lastViewerAt),
      terminatedAt: toIso(session.terminatedAt),
    };
  }

  async close() {
    if (this.client) {
      await this.client.quit();
      this.client = null;
    }
  }
}

export class SessionStore {
  constructor(config) {
    this.impl =
      config.sessionStoreBackend === "redis"
        ? new RedisSessionStoreImpl(config)
        : new MemorySessionStoreImpl(config);
  }

  async initialize() {
    await this.impl.initialize();
  }

  async createSession(input) {
    return this.impl.createSession(input);
  }

  async get(id) {
    return this.impl.get(id);
  }

  async update(id, patch) {
    return this.impl.update(id, patch);
  }

  async markViewerSeen(id) {
    return this.impl.markViewerSeen(id);
  }

  async markViewerConnected(id) {
    return this.impl.markViewerConnected(id);
  }

  async markViewerDisconnected(id, reason) {
    return this.impl.markViewerDisconnected(id, reason);
  }

  async setState(id, state) {
    return this.impl.setState(id, state);
  }

  async setWorker(id, worker) {
    return this.impl.setWorker(id, worker);
  }

  async incrementGeneration(id) {
    return this.impl.incrementGeneration(id);
  }

  async claimSocketOwnership(id, role, owner) {
    return this.impl.claimSocketOwnership(id, role, owner);
  }

  async getSocketOwner(id, role) {
    return this.impl.getSocketOwner(id, role);
  }

  async releaseSocketOwnership(id, role, owner) {
    return this.impl.releaseSocketOwnership(id, role, owner);
  }

  async listTerminated(olderThanMs, now) {
    return this.impl.listTerminated(olderThanMs, now);
  }

  async addPendingSignal(id, role, payload) {
    return this.impl.addPendingSignal(id, role, payload);
  }

  async drainPendingSignals(id, role) {
    return this.impl.drainPendingSignals(id, role);
  }

  async appendViewerTelemetry(id, payload, options) {
    return this.impl.appendViewerTelemetry(id, payload, options);
  }

  async listViewerTelemetry(id, options) {
    return this.impl.listViewerTelemetry(id, options);
  }

  async listExpired(now) {
    return this.impl.listExpired(now);
  }

  async listSessions(limit) {
    return this.impl.listSessions(limit);
  }

  async shouldIdleTerminate(id, now) {
    return this.impl.shouldIdleTerminate(id, now);
  }

  async acquireTerminationLock(id, ttlMs) {
    return this.impl.acquireTerminationLock(id, ttlMs);
  }

  async acquireSingleSessionGuard(ttlMs) {
    return this.impl.acquireSingleSessionGuard(ttlMs);
  }

  async releaseSingleSessionGuard(token) {
    return this.impl.releaseSingleSessionGuard(token);
  }

  async remove(id) {
    return this.impl.remove(id);
  }

  snapshot(session) {
    return this.impl.snapshot(session);
  }

  async close() {
    return this.impl.close();
  }
}
