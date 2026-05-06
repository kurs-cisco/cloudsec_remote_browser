import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";
import net from "node:net";

import { SessionStore } from "../app/session-store.js";
import { SignalBus } from "../app/signal-bus.js";
import { WorkerPoolStore } from "../app/worker-pool-store.js";
import { WorkerPoolBus } from "../app/worker-pool-bus.js";

async function findFreePort() {
  const server = net.createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  return port;
}

async function waitForRedis(port, deadlineMs = 4000) {
  const deadline = Date.now() + deadlineMs;
  while (Date.now() < deadline) {
    try {
      await new Promise((resolve, reject) => {
        const socket = net.connect(port, "127.0.0.1");
        socket.setTimeout(250);
        socket.once("connect", () => {
          socket.end();
          resolve();
        });
        socket.once("timeout", () => {
          socket.destroy();
          reject(new Error("timeout"));
        });
        socket.once("error", reject);
      });
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
  throw new Error("redis-server did not become ready");
}

async function startRedis() {
  const port = await findFreePort();
  const dir = await mkdtemp(join(tmpdir(), "cloudsec-rbi-redis-"));
  const child = spawn("redis-server", [
    "--bind",
    "127.0.0.1",
    "--port",
    String(port),
    "--save",
    "",
    "--appendonly",
    "no",
    "--dir",
    dir,
  ], {
    stdio: "ignore",
  });
  await waitForRedis(port);
  return {
    url: `redis://127.0.0.1:${port}/0`,
    async close() {
    child.kill("SIGTERM");
    await Promise.race([
      once(child, "exit"),
      new Promise((resolve) => setTimeout(resolve, 1000)),
    ]);
    await rm(dir, { recursive: true, force: true });
    },
  };
}

function redisConfig(redisUrl, suffix = "default") {
  return {
    redisUrl,
    redisTls: false,
    redisKeyPrefix: `cloudsec-rbi:test:${process.pid}:${suffix}`,
    sessionStoreBackend: "redis",
    signalBusBackend: "redis",
    workerPoolStoreBackend: "redis",
    workerPoolBusBackend: "redis",
    sessionTtlMs: 60_000,
    idleTimeoutMs: 10_000,
  };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function pttl(client, key) {
  return Number(await client.sendCommand(["PTTL", key]));
}

test("Redis-backed runtime state works across store and bus instances", async (t) => {
  const redis = await startRedis();
  const config = { ...redisConfig(redis.url, "runtime"), viewerTelemetryMaxEvents: 2 };
  const sessionStoreA = new SessionStore(config);
  const sessionStoreB = new SessionStore(config);
  const signalBusA = new SignalBus(config);
  const signalBusB = new SignalBus(config);
  t.after(async () => {
    await signalBusA.close();
    await signalBusB.close();
    await sessionStoreA.close();
    await sessionStoreB.close();
    await redis.close();
  });

  await sessionStoreA.initialize();
  await sessionStoreB.initialize();
  await signalBusA.initialize();
  await signalBusB.initialize();

  const session = await sessionStoreA.createSession({
    targetUrl: "https://example.com/",
    viewport: { width: 1280, height: 720 },
    client: {},
    viewerToken: "viewer-token",
    workerToken: "worker-token",
  });
  assert.equal((await sessionStoreB.get(session.id)).targetUrl, "https://example.com/");

  await sessionStoreB.addPendingSignal(session.id, "viewer", { type: "worker-state", state: "ready" });
  const pendingEvent = oncePendingSignal(signalBusA);
  await signalBusB.notifyPendingSignal(session.id, "viewer");
  assert.deepEqual(await pendingEvent, { sessionId: session.id, role: "viewer" });

  const drained = await sessionStoreA.drainPendingSignals(session.id, "viewer");
  assert.equal(drained.length, 1);
  assert.equal(drained[0].type, "worker-state");
  assert.equal((await sessionStoreB.drainPendingSignals(session.id, "viewer")).length, 0);

  await sessionStoreA.appendViewerTelemetry(session.id, { reason: "one" });
  await sessionStoreA.appendViewerTelemetry(session.id, { reason: "two" });
  await sessionStoreA.appendViewerTelemetry(session.id, { reason: "three" });
  const exported = await sessionStoreB.listViewerTelemetry(session.id);
  assert.equal(exported.length, 2);
  assert.equal(exported[0].payload.reason, "two");
  assert.equal(exported[1].payload.reason, "three");
});

test("Redis-backed worker pool allocates and drains assignment across instances", async (t) => {
  const redis = await startRedis();
  const config = redisConfig(redis.url, "pool");
  const poolA = new WorkerPoolStore(config);
  const poolB = new WorkerPoolStore(config);
  const busA = new WorkerPoolBus(config);
  const busB = new WorkerPoolBus(config);
  t.after(async () => {
    await busA.close();
    await busB.close();
    await poolA.close();
    await poolB.close();
    await redis.close();
  });

  await poolA.initialize();
  await poolB.initialize();
  await busA.initialize();
  await busB.initialize();

  await poolA.registerWorker({
    workerId: "pool-worker-east",
    state: "idle",
    metadata: {
      region: "us-east-1",
      runtimeClass: "kata-clh",
      mediaMode: "gateway-webrtc-relay",
      imageDigest: "sha256:abc",
      displayClass: "1280x720",
    },
    socketOwner: { instanceId: "runtime-a", connectionId: "socket-east" },
  });
  await new Promise((resolve) => setTimeout(resolve, 5));

  await poolA.registerWorker({
    workerId: "pool-worker-a",
    state: "idle",
    metadata: {
      region: "us-west-2",
      runtimeClass: "kata-clh",
      mediaMode: "gateway-webrtc-relay",
      imageDigest: "sha256:abc",
      displayClass: "1280x720",
    },
    socketOwner: { instanceId: "runtime-a", connectionId: "socket-a" },
  });

  const assignment = { sessionId: "sess_redis_pool" };
  const allocated = await poolB.allocateWorkerWithAssignment("sess_redis_pool", assignment, {
    region: "us-west-2",
    runtimeClass: "kata-clh",
    mediaMode: "gateway-webrtc-relay",
    imageDigest: "sha256:abc",
    displayClass: "1280x720",
  });
  assert.equal(allocated.workerId, "pool-worker-a");
  assert.equal(allocated.state, "assigned");
  assert.equal(allocated.sessionId, "sess_redis_pool");

  const pendingEvent = oncePendingAssignment(busA);
  await busB.notifyPendingAssignment("pool-worker-a");
  assert.deepEqual(await pendingEvent, { workerId: "pool-worker-a" });

  const assignments = await poolA.drainPendingAssignments("pool-worker-a");
  assert.deepEqual(assignments, [assignment]);
  assert.equal((await poolB.drainPendingAssignments("pool-worker-a")).length, 0);

  const eastWorker = await poolA.allocateWorker("sess_redis_pool_east", {
    region: "us-east-1",
    runtimeClass: "kata-clh",
    mediaMode: "gateway-webrtc-relay",
    imageDigest: "sha256:abc",
    displayClass: "1280x720",
  });
  assert.equal(eastWorker.workerId, "pool-worker-east");
  assert.equal(eastWorker.sessionId, "sess_redis_pool_east");
});

test("Redis-backed worker pool records carry Redis TTLs aligned to expiresAt", async (t) => {
  const redis = await startRedis();
  const config = {
    ...redisConfig(redis.url, "pool-ttl"),
    workerPoolLeaseTtlMs: 1_000,
  };
  const pool = new WorkerPoolStore(config);
  t.after(async () => {
    await pool.close();
    await redis.close();
  });

  await pool.initialize();

  const workerExpiresAt = Date.now() + 1_000;
  const worker = await pool.registerWorker({
    workerId: "pool-worker-ttl",
    expiresAt: workerExpiresAt,
    socketOwner: { instanceId: "runtime-a", connectionId: "socket-ttl" },
  });
  assert.equal(worker.expiresAt, workerExpiresAt);

  const workerKey = pool.impl.keys.worker("pool-worker-ttl");
  const initialWorkerTtl = await pttl(pool.impl.client, workerKey);
  assert.ok(initialWorkerTtl > 0, `expected positive worker TTL, got ${initialWorkerTtl}`);
  assert.ok(initialWorkerTtl <= 1_000, `expected worker TTL to follow expiresAt, got ${initialWorkerTtl}`);

  const assignment = { sessionId: "sess_pool_ttl" };
  await pool.allocateWorkerWithAssignment("sess_pool_ttl", assignment);
  const pendingKey = pool.impl.keys.pendingAssignment("pool-worker-ttl");
  const pendingTtl = await pttl(pool.impl.client, pendingKey);
  assert.ok(pendingTtl > 0, `expected positive pending assignment TTL, got ${pendingTtl}`);
  assert.ok(pendingTtl <= 1_000, `expected pending assignment TTL to follow worker lease, got ${pendingTtl}`);

  const refreshedExpiresAt = Date.now() + 120;
  const refreshed = await pool.heartbeatWorker("pool-worker-ttl", { expiresAt: refreshedExpiresAt });
  assert.equal(refreshed.expiresAt, refreshedExpiresAt);
  const refreshedWorkerTtl = await pttl(pool.impl.client, workerKey);
  assert.ok(refreshedWorkerTtl > 0, `expected refreshed worker TTL, got ${refreshedWorkerTtl}`);
  assert.ok(refreshedWorkerTtl <= 500, `expected shortened worker TTL, got ${refreshedWorkerTtl}`);

  await sleep(180);
  assert.equal(await pool.getWorker("pool-worker-ttl"), null);
  assert.equal(await pttl(pool.impl.client, workerKey), -2);

  const legacyUpdatedAt = Date.now();
  const legacyKey = pool.impl.keys.worker("pool-worker-legacy");
  await pool.impl.client.set(legacyKey, JSON.stringify({
    workerId: "pool-worker-legacy",
    state: "idle",
    updatedAt: legacyUpdatedAt,
    socketOwner: { instanceId: "runtime-a", connectionId: "socket-legacy" },
    region: "us-east-1",
  }));
  await pool.impl.client.sendCommand(["SADD", pool.impl.keys.workersIndex, "pool-worker-legacy"]);
  await pool.impl.client.sendCommand([
    "ZADD",
    pool.impl.keys.idleIndex,
    String(legacyUpdatedAt),
    "pool-worker-legacy",
  ]);

  assert.equal(await pool.allocateWorker("sess_legacy", { region: "us-west-2" }), null);
  const legacy = await pool.getWorker("pool-worker-legacy");
  assert.ok(legacy.expiresAt > Date.now(), "expected legacy worker to receive logical expiresAt");
  const legacyTtl = await pttl(pool.impl.client, legacyKey);
  assert.ok(legacyTtl > 0, `expected legacy worker to receive Redis TTL, got ${legacyTtl}`);
});

function oncePendingSignal(bus) {
  return new Promise((resolve) => {
    const off = bus.onPendingSignal((event) => {
      off();
      resolve(event);
    });
  });
}

function oncePendingAssignment(bus) {
  return new Promise((resolve) => {
    const off = bus.onPendingAssignment((event) => {
      off();
      resolve(event);
    });
  });
}
