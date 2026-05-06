import { createClient } from "redis";

export const DEFAULT_REDIS_KEY_PREFIX = "cloudsec-rbi";

function normalizeRedisKeyPrefix(prefix = DEFAULT_REDIS_KEY_PREFIX) {
  const value = String(prefix || DEFAULT_REDIS_KEY_PREFIX).trim().replace(/:+$/g, "");
  return value || DEFAULT_REDIS_KEY_PREFIX;
}

export function buildWorkerPoolKeyPrefix(redisKeyPrefix = DEFAULT_REDIS_KEY_PREFIX) {
  return `${normalizeRedisKeyPrefix(redisKeyPrefix)}:pool`;
}

export const CLOUDSEC_WORKER_POOL_KEY_PREFIX = buildWorkerPoolKeyPrefix();

const DRAIN_LIST_SCRIPT = `
local values = redis.call("LRANGE", KEYS[1], 0, -1)
if #values > 0 then
  redis.call("DEL", KEYS[1])
end
return values
`;

const ADD_PENDING_ASSIGNMENT_SCRIPT = `
redis.call("RPUSH", KEYS[1], ARGV[1])
local raw = redis.call("GET", KEYS[2])
if raw then
  local worker = cjson.decode(raw)
  if worker.expiresAt ~= nil and worker.expiresAt ~= cjson.null then
    local worker_expires_at = tonumber(worker.expiresAt)
    if worker_expires_at ~= nil then
      redis.call("PEXPIREAT", KEYS[1], worker_expires_at)
      return 1
    end
  end
end
redis.call("PEXPIRE", KEYS[1], tonumber(ARGV[2]))
return 1
`;

const ALLOCATE_WORKER_SCRIPT = `
local now = tonumber(ARGV[2])
local filters = cjson.decode(ARGV[3])
local fallback_expires_at = tonumber(ARGV[4])
local skipped = {}

local function matches_filter(worker, key)
  local want = filters[key]
  if want == nil or want == cjson.null or tostring(want) == "" then
    return true
  end
  local got = worker[key]
  if got == nil or got == cjson.null then
    return false
  end
  return tostring(got) == tostring(want)
end

while true do
  local worker_id = redis.call("ZRANGE", KEYS[1], 0, 0)[1]
  if not worker_id then
    for _, skipped_worker in ipairs(skipped) do
      redis.call("ZADD", KEYS[1], skipped_worker.updatedAt or now, skipped_worker.workerId)
    end
    return nil
  end

  redis.call("ZREM", KEYS[1], worker_id)

  local worker_key = KEYS[2] .. worker_id
  local raw = redis.call("GET", worker_key)
  if raw then
    local worker = cjson.decode(raw)
    local worker_expires_at = nil
    local assigned_fallback_expiry = false
    if worker.expiresAt ~= nil and worker.expiresAt ~= cjson.null then
      worker_expires_at = tonumber(worker.expiresAt)
    elseif fallback_expires_at ~= nil then
      worker_expires_at = fallback_expires_at
      worker.expiresAt = fallback_expires_at
      assigned_fallback_expiry = true
    end
    if worker_expires_at ~= nil and worker_expires_at <= now then
      redis.call("DEL", worker_key)
      redis.call("SREM", KEYS[3], worker_id)
    elseif worker.socketOwner == nil or worker.socketOwner == cjson.null then
      redis.call("DEL", worker_key)
      redis.call("SREM", KEYS[3], worker_id)
    elseif worker.state == "idle" and
      matches_filter(worker, "region") and
      matches_filter(worker, "runtimeClass") and
      matches_filter(worker, "mediaMode") and
      matches_filter(worker, "imageDigest") and
      matches_filter(worker, "displayClass")
    then
      worker.state = "assigned"
      worker.sessionId = ARGV[1]
      worker.updatedAt = now
      worker.lastHeartbeatAt = now
      redis.call("SET", worker_key, cjson.encode(worker))
      if worker_expires_at ~= nil then
        redis.call("PEXPIREAT", worker_key, worker_expires_at)
      end
      for _, skipped_worker in ipairs(skipped) do
        redis.call("ZADD", KEYS[1], skipped_worker.updatedAt or now, skipped_worker.workerId)
      end
      return cjson.encode(worker)
    elseif worker.state == "idle" then
      if assigned_fallback_expiry then
        redis.call("SET", worker_key, cjson.encode(worker))
        redis.call("PEXPIREAT", worker_key, worker_expires_at)
      end
      table.insert(skipped, worker)
    elseif assigned_fallback_expiry then
      redis.call("SET", worker_key, cjson.encode(worker))
      redis.call("PEXPIREAT", worker_key, worker_expires_at)
    end
  else
    redis.call("SREM", KEYS[3], worker_id)
  end
end
`;

const ALLOCATE_AND_QUEUE_WORKER_SCRIPT = `
local now = tonumber(ARGV[2])
local assignment = ARGV[3]
local filters = cjson.decode(ARGV[4])
local fallback_expires_at = tonumber(ARGV[5])
local skipped = {}

local function matches_filter(worker, key)
  local want = filters[key]
  if want == nil or want == cjson.null or tostring(want) == "" then
    return true
  end
  local got = worker[key]
  if got == nil or got == cjson.null then
    return false
  end
  return tostring(got) == tostring(want)
end

while true do
  local worker_id = redis.call("ZRANGE", KEYS[1], 0, 0)[1]
  if not worker_id then
    for _, skipped_worker in ipairs(skipped) do
      redis.call("ZADD", KEYS[1], skipped_worker.updatedAt or now, skipped_worker.workerId)
    end
    return nil
  end

  redis.call("ZREM", KEYS[1], worker_id)

  local worker_key = KEYS[2] .. worker_id
  local raw = redis.call("GET", worker_key)
  if raw then
    local worker = cjson.decode(raw)
    local worker_expires_at = nil
    local assigned_fallback_expiry = false
    if worker.expiresAt ~= nil and worker.expiresAt ~= cjson.null then
      worker_expires_at = tonumber(worker.expiresAt)
    elseif fallback_expires_at ~= nil then
      worker_expires_at = fallback_expires_at
      worker.expiresAt = fallback_expires_at
      assigned_fallback_expiry = true
    end
    local expired = worker_expires_at ~= nil and worker_expires_at <= now
    local missing_owner = worker.socketOwner == nil or worker.socketOwner == cjson.null
    if expired or missing_owner then
      redis.call("DEL", worker_key)
      redis.call("SREM", KEYS[3], worker_id)
    elseif worker.state == "idle" and
      matches_filter(worker, "region") and
      matches_filter(worker, "runtimeClass") and
      matches_filter(worker, "mediaMode") and
      matches_filter(worker, "imageDigest") and
      matches_filter(worker, "displayClass")
    then
      worker.state = "assigned"
      worker.sessionId = ARGV[1]
      worker.updatedAt = now
      worker.lastHeartbeatAt = now
      redis.call("SET", worker_key, cjson.encode(worker))
      if worker_expires_at ~= nil then
        redis.call("PEXPIREAT", worker_key, worker_expires_at)
      end
      redis.call("SADD", KEYS[3], worker.workerId)
      redis.call("RPUSH", KEYS[4] .. worker.workerId .. ":pending", assignment)
      if worker_expires_at ~= nil then
        redis.call("PEXPIREAT", KEYS[4] .. worker.workerId .. ":pending", worker_expires_at)
      end
      for _, skipped_worker in ipairs(skipped) do
        redis.call("ZADD", KEYS[1], skipped_worker.updatedAt or now, skipped_worker.workerId)
      end
      return cjson.encode(worker)
    else
      if worker.state == "idle" then
        if assigned_fallback_expiry then
          redis.call("SET", worker_key, cjson.encode(worker))
          redis.call("PEXPIREAT", worker_key, worker_expires_at)
        end
        table.insert(skipped, worker)
      elseif assigned_fallback_expiry then
        redis.call("SET", worker_key, cjson.encode(worker))
        redis.call("PEXPIREAT", worker_key, worker_expires_at)
      end
    end
  else
    redis.call("SREM", KEYS[3], worker_id)
  end
end
`;

const SAVE_WORKER_CHANGES = `
local now = tonumber(ARGV[2])
local worker_expires_at = nil
if worker.expiresAt ~= nil and worker.expiresAt ~= cjson.null then
  worker_expires_at = tonumber(worker.expiresAt)
elseif ARGV[3] ~= nil and tostring(ARGV[3]) ~= "" then
  worker_expires_at = tonumber(ARGV[3])
  worker.expiresAt = worker_expires_at
end
local encoded_worker = cjson.encode(worker)
if worker_expires_at ~= nil and worker_expires_at <= now then
  redis.call("DEL", KEYS[1])
  redis.call("SREM", KEYS[2], worker.workerId)
  redis.call("ZREM", KEYS[3], worker.workerId)
  return encoded_worker
end
redis.call("SET", KEYS[1], encoded_worker)
if worker_expires_at ~= nil then
  redis.call("PEXPIREAT", KEYS[1], worker_expires_at)
end
redis.call("SADD", KEYS[2], worker.workerId)
if worker.state == "idle" and (worker_expires_at == nil or worker_expires_at > now) then
  redis.call("ZADD", KEYS[3], worker.updatedAt, worker.workerId)
else
  redis.call("ZREM", KEYS[3], worker.workerId)
end
return encoded_worker
`;

const REGISTER_WORKER_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
local existing = nil
if raw then
  existing = cjson.decode(raw)
end
local input = cjson.decode(ARGV[1])
local worker = {
  workerId = input.workerId,
  mode = input.mode or (existing and existing.mode) or "warm-pool",
  state = "idle",
  taskArn = input.taskArn or (existing and existing.taskArn) or cjson.null,
  runtimeId = input.runtimeId or (existing and existing.runtimeId) or cjson.null,
  region = input.region or (existing and existing.region) or cjson.null,
  runtimeClass = input.runtimeClass or (existing and existing.runtimeClass) or cjson.null,
  mediaMode = input.mediaMode or (existing and existing.mediaMode) or cjson.null,
  imageDigest = input.imageDigest or (existing and existing.imageDigest) or cjson.null,
  displayClass = input.displayClass or (existing and existing.displayClass) or cjson.null,
  connectedAt = (existing and existing.connectedAt) or tonumber(ARGV[2]),
  updatedAt = tonumber(ARGV[2]),
  lastHeartbeatAt = tonumber(ARGV[2]),
  expiresAt = input.expiresAt or tonumber(ARGV[3]),
  sessionId = cjson.null,
  metadata = input.metadata or (existing and existing.metadata) or {},
  socketOwner = input.socketOwner or (existing and existing.socketOwner) or cjson.null,
}
${SAVE_WORKER_CHANGES}
`;

const MARK_WORKER_IDLE_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local worker = cjson.decode(raw)
local patch = cjson.decode(ARGV[1])
for key, value in pairs(patch) do
  worker[key] = value
end
worker.state = "idle"
worker.sessionId = cjson.null
worker.updatedAt = tonumber(ARGV[2])
worker.lastHeartbeatAt = tonumber(ARGV[2])
worker.expiresAt = tonumber(ARGV[3])
${SAVE_WORKER_CHANGES}
`;

const MARK_WORKER_BUSY_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local worker = cjson.decode(raw)
local patch = cjson.decode(ARGV[1])
for key, value in pairs(patch) do
  worker[key] = value
end
worker.state = patch.state or "assigned"
worker.updatedAt = tonumber(ARGV[2])
worker.lastHeartbeatAt = tonumber(ARGV[2])
worker.expiresAt = tonumber(ARGV[3])
${SAVE_WORKER_CHANGES}
`;

const HEARTBEAT_WORKER_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local worker = cjson.decode(raw)
local patch = cjson.decode(ARGV[1])
for key, value in pairs(patch) do
  worker[key] = value
end
worker.lastHeartbeatAt = tonumber(ARGV[2])
worker.updatedAt = tonumber(ARGV[2])
worker.expiresAt = tonumber(ARGV[3])
${SAVE_WORKER_CHANGES}
`;

const CLAIM_POOL_SOCKET_OWNER_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local worker = cjson.decode(raw)
worker.socketOwner = cjson.decode(ARGV[1])
worker.updatedAt = tonumber(ARGV[2])
${SAVE_WORKER_CHANGES}
`;

const RELEASE_POOL_SOCKET_OWNER_SCRIPT = `
local raw = redis.call("GET", KEYS[1])
if not raw then
  return nil
end
local worker = cjson.decode(raw)
local owner = cjson.decode(ARGV[1])
local current = worker.socketOwner
local currentInstanceId = ""
local currentConnectionId = ""
if current ~= nil and current ~= cjson.null then
  currentInstanceId = tostring(current.instanceId or "")
  currentConnectionId = tostring(current.connectionId or "")
end
if currentInstanceId ~= tostring(owner.instanceId or "") or currentConnectionId ~= tostring(owner.connectionId or "") then
  return cjson.encode({ released = false, worker = worker })
end
worker.socketOwner = cjson.null
worker.updatedAt = tonumber(ARGV[2])
local worker_expires_at = nil
if worker.expiresAt ~= nil and worker.expiresAt ~= cjson.null then
  worker_expires_at = tonumber(worker.expiresAt)
elseif ARGV[3] ~= nil and tostring(ARGV[3]) ~= "" then
  worker_expires_at = tonumber(ARGV[3])
  worker.expiresAt = worker_expires_at
end
if worker_expires_at ~= nil and worker_expires_at <= tonumber(ARGV[2]) then
  redis.call("DEL", KEYS[1])
  redis.call("SREM", KEYS[2], worker.workerId)
  redis.call("ZREM", KEYS[3], worker.workerId)
  return cjson.encode({ released = true })
end
redis.call("SET", KEYS[1], cjson.encode(worker))
if worker_expires_at ~= nil then
  redis.call("PEXPIREAT", KEYS[1], worker_expires_at)
end
redis.call("SADD", KEYS[2], worker.workerId)
if worker.state == "idle" and (worker_expires_at == nil or worker_expires_at > tonumber(ARGV[2])) then
  redis.call("ZADD", KEYS[3], worker.updatedAt, worker.workerId)
else
  redis.call("ZREM", KEYS[3], worker.workerId)
end
return cjson.encode({ released = true })
`;

export function buildWorkerPoolKeys(prefix = CLOUDSEC_WORKER_POOL_KEY_PREFIX) {
  return {
    workersIndex: `${prefix}:workers`,
    idleIndex: `${prefix}:idle`,
    workerPrefix: `${prefix}:worker:`,
    pendingAssignmentPrefix: `${prefix}:worker:`,
    worker: (workerId) => `${prefix}:worker:${workerId}`,
    pendingAssignment: (workerId) => `${prefix}:worker:${workerId}:pending`,
  };
}

function getStoreBackend(config) {
  return config.workerPoolStoreBackend || config.sessionStoreBackend || "memory";
}

function buildWorkerRecord(input, existing = null) {
  const now = Date.now();
  const metadata = input.metadata || existing?.metadata || {};
  const leaseTtlMs = Number(input.leaseTtlMs || input.workerPoolLeaseTtlMs || 45_000);
  const expiresAt = Number(input.expiresAt) || now + leaseTtlMs;
  return {
    workerId: input.workerId,
    mode: input.mode || existing?.mode || "warm-pool",
    state: "idle",
    taskArn: input.taskArn || existing?.taskArn || null,
    runtimeId: input.runtimeId || existing?.runtimeId || null,
    region: input.region || metadata.region || existing?.region || null,
    runtimeClass: input.runtimeClass || metadata.runtimeClass || existing?.runtimeClass || null,
    mediaMode: input.mediaMode || metadata.mediaMode || existing?.mediaMode || null,
    imageDigest: input.imageDigest || metadata.imageDigest || existing?.imageDigest || null,
    displayClass: input.displayClass || metadata.displayClass || existing?.displayClass || null,
    connectedAt: existing?.connectedAt || input.connectedAt || now,
    updatedAt: now,
    lastHeartbeatAt: now,
    expiresAt,
    sessionId: null,
    metadata,
    socketOwner: input.socketOwner || existing?.socketOwner || null,
  };
}

function stripEmptyValues(input) {
  return Object.fromEntries(
    Object.entries(input).filter(([, value]) => value !== undefined && value !== null && value !== ""),
  );
}

function buildWorkerInput(input = {}, config = {}) {
  const now = Date.now();
  const metadata = input.metadata || {};
  const leaseTtlMs = Number(config.workerPoolLeaseTtlMs || input.workerPoolLeaseTtlMs || 45_000);
  return stripEmptyValues({
    ...input,
    region: input.region || metadata.region || null,
    runtimeClass: input.runtimeClass || metadata.runtimeClass || null,
    mediaMode: input.mediaMode || metadata.mediaMode || null,
    imageDigest: input.imageDigest || metadata.imageDigest || null,
    displayClass: input.displayClass || metadata.displayClass || null,
    expiresAt: Number(input.expiresAt) || now + leaseTtlMs,
  });
}

function normalizeWorkerPatch(patch = {}, now = Date.now(), leaseTtlMs = 45_000) {
  const metadata = patch.metadata || {};
  return stripEmptyValues({
    ...patch,
    region: patch.region || metadata.region,
    runtimeClass: patch.runtimeClass || metadata.runtimeClass,
    mediaMode: patch.mediaMode || metadata.mediaMode,
    imageDigest: patch.imageDigest || metadata.imageDigest,
    displayClass: patch.displayClass || metadata.displayClass,
    lastHeartbeatAt: now,
    expiresAt: Number(patch.expiresAt) || now + leaseTtlMs,
  });
}

function workerMatchesFilters(worker, filters = {}) {
  for (const key of ["region", "runtimeClass", "mediaMode", "imageDigest", "displayClass"]) {
    if (filters[key] && String(worker?.[key] || "") !== String(filters[key])) {
      return false;
    }
  }
  return true;
}

function socketOwnerMatches(current, expected) {
  return (
    String(current?.instanceId || "") === String(expected?.instanceId || "") &&
    String(current?.connectionId || "") === String(expected?.connectionId || "")
  );
}

class MemoryWorkerPoolStoreImpl {
  constructor(config = {}) {
    this.config = config;
    this.workers = new Map();
    this.pendingAssignments = new Map();
  }

  async initialize() {}

  async registerWorker(input) {
    const worker = buildWorkerRecord(
      { workerPoolLeaseTtlMs: this.config.workerPoolLeaseTtlMs, ...input },
      this.workers.get(input.workerId),
    );
    this.workers.set(worker.workerId, worker);
    return worker;
  }

  async getWorker(workerId) {
    return this.workers.get(workerId) || null;
  }

  async listWorkers(limit = 100) {
    return [...this.workers.values()]
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, limit);
  }

  async allocateWorker(sessionId, filters = {}) {
    const now = Date.now();
    const idleWorkers = [...this.workers.values()]
      .filter((worker) => {
        if (worker.expiresAt && worker.expiresAt <= now) {
          this.workers.delete(worker.workerId);
          return false;
        }
        return worker.state === "idle" && worker.socketOwner && workerMatchesFilters(worker, filters);
      })
      .sort((left, right) => left.updatedAt - right.updatedAt);
    const worker = idleWorkers[0];
    if (!worker) {
      return null;
    }
    worker.state = "assigned";
    worker.sessionId = sessionId;
    worker.updatedAt = Date.now();
    return worker;
  }

  async allocateWorkerWithAssignment(sessionId, payload, filters = {}) {
    const worker = await this.allocateWorker(sessionId, filters);
    if (!worker) {
      return null;
    }
    await this.addPendingAssignment(worker.workerId, payload);
    return worker;
  }

  async markWorkerIdle(workerId, patch = {}) {
    const worker = this.workers.get(workerId);
    if (!worker) {
      return null;
    }
    const now = Date.now();
    Object.assign(worker, normalizeWorkerPatch(patch, now, this.config.workerPoolLeaseTtlMs), {
      state: "idle",
      sessionId: null,
      updatedAt: now,
    });
    return worker;
  }

  async markWorkerBusy(workerId, patch = {}) {
    const worker = this.workers.get(workerId);
    if (!worker) {
      return null;
    }
    const now = Date.now();
    Object.assign(worker, normalizeWorkerPatch(patch, now, this.config.workerPoolLeaseTtlMs), {
      state: patch.state || "assigned",
      updatedAt: now,
    });
    return worker;
  }

  async heartbeatWorker(workerId, patch = {}) {
    const worker = this.workers.get(workerId);
    if (!worker) {
      return null;
    }
    Object.assign(worker, normalizeWorkerPatch(patch, Date.now(), this.config.workerPoolLeaseTtlMs));
    return worker;
  }

  async claimSocketOwnership(workerId, owner) {
    const worker = this.workers.get(workerId);
    if (!worker) {
      return null;
    }
    worker.socketOwner = owner;
    worker.updatedAt = Date.now();
    return worker;
  }

  async getSocketOwner(workerId) {
    const worker = this.workers.get(workerId);
    return worker?.socketOwner || null;
  }

  async releaseSocketOwnership(workerId, owner) {
    const worker = this.workers.get(workerId);
    if (!worker) {
      return false;
    }
    if (!socketOwnerMatches(worker.socketOwner, owner)) {
      return false;
    }
    worker.socketOwner = null;
    worker.updatedAt = Date.now();
    return true;
  }

  async unregisterWorker(workerId) {
    this.pendingAssignments.delete(workerId);
    return this.workers.delete(workerId);
  }

  async addPendingAssignment(workerId, payload) {
    const items = this.pendingAssignments.get(workerId) || [];
    items.push(payload);
    this.pendingAssignments.set(workerId, items);
  }

  async drainPendingAssignments(workerId) {
    const items = this.pendingAssignments.get(workerId) || [];
    this.pendingAssignments.delete(workerId);
    return items;
  }

  async close() {}
}

class RedisWorkerPoolStoreImpl {
  constructor(config) {
    this.config = config;
    this.client = null;
    this.keys = buildWorkerPoolKeys(
      config.workerPoolKeyPrefix || buildWorkerPoolKeyPrefix(config.redisKeyPrefix),
    );
  }

  #workerMutationKeys(workerId) {
    return [this.keys.worker(workerId), this.keys.workersIndex, this.keys.idleIndex];
  }

  async initialize() {
    this.client = createClient({
      url: this.config.redisUrl,
      socket: {
        tls: this.config.redisTls,
      },
    });
    this.client.on("error", (error) => {
      console.error("[cloudsec-worker-pool:redis]", error);
    });
    await this.client.connect();
  }

  async #loadWorker(workerId) {
    if (!this.client) {
      return null;
    }
    const raw = await this.client.get(this.keys.worker(workerId));
    return raw ? JSON.parse(raw) : null;
  }

  async registerWorker(input) {
    const now = Date.now();
    const workerInput = buildWorkerInput(input, this.config);
    const raw = await this.client.eval(REGISTER_WORKER_SCRIPT, {
      keys: this.#workerMutationKeys(input.workerId),
      arguments: [JSON.stringify(workerInput), String(now), String(workerInput.expiresAt)],
    });
    return raw ? JSON.parse(raw) : null;
  }

  async getWorker(workerId) {
    return this.#loadWorker(workerId);
  }

  async listWorkers(limit = 100) {
    const ids = await this.client.sMembers(this.keys.workersIndex);
    if (!ids.length) {
      return [];
    }
    const workers = await Promise.all(ids.map((workerId) => this.#loadWorker(workerId)));
    return workers
      .filter(Boolean)
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, limit);
  }

  async allocateWorker(sessionId, filters = {}) {
    const now = Date.now();
    const raw = await this.client.eval(ALLOCATE_WORKER_SCRIPT, {
      keys: [this.keys.idleIndex, this.keys.workerPrefix, this.keys.workersIndex],
      arguments: [
        sessionId,
        String(now),
        JSON.stringify(filters || {}),
        String(now + (Number(this.config.workerPoolLeaseTtlMs) || 45_000)),
      ],
    });
    return raw ? JSON.parse(raw) : null;
  }

  async allocateWorkerWithAssignment(sessionId, payload, filters = {}) {
    const now = Date.now();
    const raw = await this.client.eval(ALLOCATE_AND_QUEUE_WORKER_SCRIPT, {
      keys: [
        this.keys.idleIndex,
        this.keys.workerPrefix,
        this.keys.workersIndex,
        this.keys.pendingAssignmentPrefix,
      ],
      arguments: [
        sessionId,
        String(now),
        JSON.stringify(payload),
        JSON.stringify(filters || {}),
        String(now + (Number(this.config.workerPoolLeaseTtlMs) || 45_000)),
      ],
    });
    return raw ? JSON.parse(raw) : null;
  }

  async markWorkerIdle(workerId, patch = {}) {
    const now = Date.now();
    const normalizedPatch = normalizeWorkerPatch(patch, now, this.config.workerPoolLeaseTtlMs);
    const raw = await this.client.eval(MARK_WORKER_IDLE_SCRIPT, {
      keys: this.#workerMutationKeys(workerId),
      arguments: [JSON.stringify(normalizedPatch), String(now), String(normalizedPatch.expiresAt)],
    });
    return raw ? JSON.parse(raw) : null;
  }

  async markWorkerBusy(workerId, patch = {}) {
    const now = Date.now();
    const normalizedPatch = normalizeWorkerPatch(patch, now, this.config.workerPoolLeaseTtlMs);
    const raw = await this.client.eval(MARK_WORKER_BUSY_SCRIPT, {
      keys: this.#workerMutationKeys(workerId),
      arguments: [JSON.stringify(normalizedPatch), String(now), String(normalizedPatch.expiresAt)],
    });
    return raw ? JSON.parse(raw) : null;
  }

  async heartbeatWorker(workerId, patch = {}) {
    const now = Date.now();
    const normalizedPatch = normalizeWorkerPatch(patch, now, this.config.workerPoolLeaseTtlMs);
    const raw = await this.client.eval(HEARTBEAT_WORKER_SCRIPT, {
      keys: this.#workerMutationKeys(workerId),
      arguments: [JSON.stringify(normalizedPatch), String(now), String(normalizedPatch.expiresAt)],
    });
    return raw ? JSON.parse(raw) : null;
  }

  async claimSocketOwnership(workerId, owner) {
    const now = Date.now();
    const raw = await this.client.eval(CLAIM_POOL_SOCKET_OWNER_SCRIPT, {
      keys: this.#workerMutationKeys(workerId),
      arguments: [
        JSON.stringify(owner),
        String(now),
        String(now + (Number(this.config.workerPoolLeaseTtlMs) || 45_000)),
      ],
    });
    return raw ? JSON.parse(raw) : null;
  }

  async getSocketOwner(workerId) {
    const worker = await this.#loadWorker(workerId);
    return worker?.socketOwner || null;
  }

  async releaseSocketOwnership(workerId, owner) {
    const now = Date.now();
    const raw = await this.client.eval(RELEASE_POOL_SOCKET_OWNER_SCRIPT, {
      keys: this.#workerMutationKeys(workerId),
      arguments: [
        JSON.stringify(owner),
        String(now),
        String(now + (Number(this.config.workerPoolLeaseTtlMs) || 45_000)),
      ],
    });
    if (!raw) {
      return false;
    }
    const result = JSON.parse(raw);
    return Boolean(result?.released);
  }

  async unregisterWorker(workerId) {
    const multi = this.client.multi();
    multi.del(this.keys.worker(workerId));
    multi.del(this.keys.pendingAssignment(workerId));
    multi.sRem(this.keys.workersIndex, workerId);
    multi.zRem(this.keys.idleIndex, workerId);
    await multi.exec();
    return true;
  }

  async addPendingAssignment(workerId, payload) {
    await this.client.eval(ADD_PENDING_ASSIGNMENT_SCRIPT, {
      keys: [this.keys.pendingAssignment(workerId), this.keys.worker(workerId)],
      arguments: [
        JSON.stringify(payload),
        String(Math.max(1, Number(this.config.workerPoolLeaseTtlMs) || 45_000)),
      ],
    });
  }

  async drainPendingAssignments(workerId) {
    const rawValues = await this.client.eval(DRAIN_LIST_SCRIPT, {
      keys: [this.keys.pendingAssignment(workerId)],
      arguments: [],
    });
    return (rawValues || []).map((value) => JSON.parse(value));
  }

  async close() {
    if (this.client) {
      await this.client.quit();
      this.client = null;
    }
  }
}

export class WorkerPoolStore {
  constructor(config = {}) {
    this.impl =
      getStoreBackend(config) === "redis"
        ? new RedisWorkerPoolStoreImpl(config)
        : new MemoryWorkerPoolStoreImpl(config);
  }

  async initialize() {
    return this.impl.initialize();
  }

  async registerWorker(input) {
    return this.impl.registerWorker(input);
  }

  async getWorker(workerId) {
    return this.impl.getWorker(workerId);
  }

  async listWorkers(limit) {
    return this.impl.listWorkers(limit);
  }

  async allocateWorker(sessionId, filters) {
    return this.impl.allocateWorker(sessionId, filters);
  }

  async allocateWorkerWithAssignment(sessionId, payload, filters) {
    return this.impl.allocateWorkerWithAssignment(sessionId, payload, filters);
  }

  async markWorkerIdle(workerId, patch) {
    return this.impl.markWorkerIdle(workerId, patch);
  }

  async markWorkerBusy(workerId, patch) {
    return this.impl.markWorkerBusy(workerId, patch);
  }

  async heartbeatWorker(workerId, patch) {
    return this.impl.heartbeatWorker(workerId, patch);
  }

  async claimSocketOwnership(workerId, owner) {
    return this.impl.claimSocketOwnership(workerId, owner);
  }

  async getSocketOwner(workerId) {
    return this.impl.getSocketOwner(workerId);
  }

  async releaseSocketOwnership(workerId, owner) {
    return this.impl.releaseSocketOwnership(workerId, owner);
  }

  async unregisterWorker(workerId) {
    return this.impl.unregisterWorker(workerId);
  }

  async addPendingAssignment(workerId, payload) {
    return this.impl.addPendingAssignment(workerId, payload);
  }

  async drainPendingAssignments(workerId) {
    return this.impl.drainPendingAssignments(workerId);
  }

  async close() {
    return this.impl.close();
  }
}
