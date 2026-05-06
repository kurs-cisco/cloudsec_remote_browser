import test from "node:test";
import assert from "node:assert/strict";

import { buildSessionStoreKeys } from "../app/session-store.js";
import { buildSignalBusChannel, SignalBus } from "../app/signal-bus.js";
import { buildWorkerPoolKeyPrefix, buildWorkerPoolKeys } from "../app/worker-pool-store.js";
import { WorkerPoolBus } from "../app/worker-pool-bus.js";

test("REDIS_KEY_PREFIX namespaces session, signal, and worker pool keys", () => {
  const redisKeyPrefix = "tenant-a:rbi";
  const sessionKeys = buildSessionStoreKeys(redisKeyPrefix);
  const poolKeyPrefix = buildWorkerPoolKeyPrefix(redisKeyPrefix);
  const poolKeys = buildWorkerPoolKeys(poolKeyPrefix);

  assert.equal(sessionKeys.session("sess_1"), "tenant-a:rbi:session:sess_1");
  assert.equal(sessionKeys.pending("sess_1", "viewer"), "tenant-a:rbi:session:sess_1:pending:viewer");
  assert.equal(sessionKeys.viewerTelemetry("sess_1"), "tenant-a:rbi:session:sess_1:viewer-telemetry");
  assert.equal(sessionKeys.sessionsExpires, "tenant-a:rbi:sessions:expires");
  assert.equal(sessionKeys.sessionsCreated, "tenant-a:rbi:sessions:created");
  assert.equal(sessionKeys.terminationLock("sess_1"), "tenant-a:rbi:session:sess_1:terminating");
  assert.equal(sessionKeys.singleSessionGuard, "tenant-a:rbi:locks:single-active-session");

  assert.equal(buildSignalBusChannel(redisKeyPrefix), "tenant-a:rbi:signals:pending");
  assert.equal(new SignalBus({ signalBusBackend: "memory", redisKeyPrefix }).channel, "tenant-a:rbi:signals:pending");

  assert.equal(poolKeyPrefix, "tenant-a:rbi:pool");
  assert.equal(poolKeys.workersIndex, "tenant-a:rbi:pool:workers");
  assert.equal(poolKeys.idleIndex, "tenant-a:rbi:pool:idle");
  assert.equal(poolKeys.worker("worker-a"), "tenant-a:rbi:pool:worker:worker-a");
  assert.equal(poolKeys.pendingAssignment("worker-a"), "tenant-a:rbi:pool:worker:worker-a:pending");
  assert.equal(new WorkerPoolBus({ workerPoolBusBackend: "memory", redisKeyPrefix }).channel, "tenant-a:rbi:pool:pending");
});

test("explicit Redis channels override derived REDIS_KEY_PREFIX channels", () => {
  const signalBus = new SignalBus({
    signalBusBackend: "memory",
    redisKeyPrefix: "tenant-a:rbi",
    signalBusChannel: "custom:signals",
  });
  const workerPoolBus = new WorkerPoolBus({
    workerPoolBusBackend: "memory",
    redisKeyPrefix: "tenant-a:rbi",
    workerPoolPendingChannel: "custom:pool:pending",
  });

  assert.equal(signalBus.channel, "custom:signals");
  assert.equal(workerPoolBus.channel, "custom:pool:pending");
});
